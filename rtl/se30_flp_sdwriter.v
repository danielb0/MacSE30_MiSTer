// se30_flp_sdwriter.v - written floppy blocks back to the SD card

`timescale 1ns/1ps

module se30_flp_sdwriter #(
  parameter [23:0] BASE = 24'h800000,
  parameter ACK_TIMEOUT_BITS = 24,
  parameter QDEPTH_BITS      = 10
) (
  input             clk,
  input             reset_n,

  input             img_mounted,
  input             loading,
  input             write_ok,
  input             dc42,
  input             img_tags,
  input             img_800k,
  input      [12:0] file_blks,

  input             cm_done,
  input      [11:0] cm_blk,
  output            cm_ready,

  input             flush_req,

  output reg  [5:0] hdr_addr,
  input      [15:0] hdr_data,

  output reg        mem_req,
  output reg [23:0] mem_addr,
  input      [15:0] mem_rdata,
  input             mem_ack,

  output reg [31:0] sd_lba,
  output reg        sd_wr,
  input             sd_ack,
  input       [7:0] sd_buff_addr,
  output     [15:0] sd_buff_din,

  output            busy,
  output     [31:0] dbg
);

  reg  [12:0] q_mem [0:(1<<QDEPTH_BITS)-1];
  reg [QDEPTH_BITS:0] wr_ptr, rd_ptr;
  wire [QDEPTH_BITS:0] count = wr_ptr - rd_ptr;
  wire        empty = (count == 0);
  reg  [12:0] q_head;
  reg         empty_d;
  reg         push;
  reg  [12:0] push_blk;
  always @(posedge clk) begin
    if (push) q_mem[wr_ptr[QDEPTH_BITS-1:0]] <= push_blk;
    q_head  <= q_mem[rd_ptr[QDEPTH_BITS-1:0]];
    empty_d <= empty;
  end

  reg   [2:0] ps;
  reg  [11:0] pn;
  reg  [12:0] last_pushed;
  reg         any_pushed;
  wire [19:0] t_off  = (img_800k ? 20'd819200 : 20'd409600) + {pn, 3'b000} + {pn, 2'b00} + 20'd84;
  wire [19:0] t_end  = t_off + 20'd11;
  reg  [12:0] cand;
  reg         cand_ok;
  always @* begin
    case (ps)
      3'd1:    begin cand = {1'b0, pn};           cand_ok = 1'b1;     end
      3'd2:    begin cand = {1'b0, pn} + 13'd1;   cand_ok = dc42;     end
      3'd3:    begin cand = t_off[19:9];          cand_ok = img_tags; end
      default: begin cand = t_end[19:9];          cand_ok = img_tags; end
    endcase
  end
  assign cm_ready = (ps == 3'd0) && !cm_done && (count <= (1 << QDEPTH_BITS) - 4);

  reg  [15:0] blk [0:255];
  reg         blk_we;
  reg   [7:0] blk_wa;
  reg  [15:0] blk_wd;
  reg  [15:0] blk_do;
  always @(posedge clk) begin
    if (blk_we) blk[blk_wa] <= blk_wd;
    blk_do <= blk[sd_buff_addr];
  end
  assign sd_buff_din = {blk_do[7:0], blk_do[15:8]};

  localparam P_IDLE  = 4'd0, P_SKIP  = 4'd1, P_ADDR  = 4'd2, P_HWAIT = 4'd3, P_HDR   = 4'd4,
             P_REQ   = 4'd5, P_TURN  = 4'd6, P_WR    = 4'd7, P_ACK   = 4'd8, P_DONE  = 4'd9,
             F_SZ0   = 4'd10, F_SZ1  = 4'd11, F_SZ2  = 4'd12, F_SZ3  = 4'd13, F_SCAN = 4'd14,
             F_TURN  = 4'd15;
  reg   [3:0] pst;
  reg  [12:0] cur;
  reg   [8:0] w;
  reg         hdr_wr;
  reg         dirty;
  reg         flush_pending;
  reg         abort;
  reg  [31:0] dsum, tsum;
  reg  [31:0] dsize, tsize;
  reg  [20:0] sw;
  reg         s_tags;
  reg  [ACK_TIMEOUT_BITS-1:0] ack_t;
  reg  [15:0] n_blocks;
  reg   [7:0] n_flush, n_retry;

  wire        hdr_src  = dc42 && (cur == 13'd0) && (w < 9'd42);
  wire [23:0] pay_word = {3'd0, cur, w[7:0]} - (dc42 ? 24'd42 : 24'd0);
  wire        head_ok  = (q_head < file_blks);
  wire [31:0] add      = (s_tags ? tsum : dsum) + {16'd0, mem_rdata};
  wire [20:0] d_words  = dsize[21:1];
  wire [20:0] t_words  = (tsize > 32'd12) ? tsize[21:1] - 21'd6 : 21'd0;

  assign busy = (pst != P_IDLE) || !empty || flush_pending || (ps != 3'd0);

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wr_ptr <= 0; rd_ptr <= 0; push <= 0; push_blk <= 0; ps <= 0; pn <= 0;
      last_pushed <= 0; any_pushed <= 0;
      pst <= P_IDLE; cur <= 0; w <= 0; hdr_wr <= 0; dirty <= 0; flush_pending <= 0; abort <= 0;
      dsum <= 0; tsum <= 0; dsize <= 0; tsize <= 0; sw <= 0; s_tags <= 0; ack_t <= 0;
      mem_req <= 0; mem_addr <= 0; hdr_addr <= 0; sd_lba <= 0; sd_wr <= 0;
      blk_we <= 0; blk_wa <= 0; blk_wd <= 0;
      n_blocks <= 0; n_flush <= 0; n_retry <= 0;
    end else begin
      blk_we <= 0;
      push   <= 0;

      if (push) wr_ptr <= wr_ptr + 1'b1;
      if (cm_done && ps == 3'd0 && write_ok) begin pn <= cm_blk; ps <= 3'd1; end
      else if (ps != 3'd0) begin
        if (cand_ok && !(any_pushed && cand == last_pushed && (count != 0 || push))) begin
          push <= 1; push_blk <= cand; last_pushed <= cand; any_pushed <= 1;
        end
        ps <= (ps == 3'd4) ? 3'd0 : ps + 1'b1;
      end

      if (flush_req && dc42 && (dirty || !empty || pst != P_IDLE || ps != 3'd0))
        flush_pending <= 1;

      case (pst)
        P_IDLE:
          if (flush_pending && empty && ps == 3'd0 && !push && !loading) begin
            if (dirty) begin hdr_addr <= 6'd32; pst <= F_SZ0; end
            else flush_pending <= 0;
          end else if (!empty && !empty_d && !loading && !push) begin
            rd_ptr <= rd_ptr + 1'b1;
            if (!head_ok) pst <= P_SKIP;
            else begin cur <= q_head; hdr_wr <= 0; w <= 0; pst <= P_ADDR; end
          end

        P_SKIP: pst <= P_IDLE;

        P_ADDR:
          if (hdr_src) begin hdr_addr <= w[5:0]; pst <= P_HWAIT; end
          else begin mem_addr <= BASE + pay_word; pst <= P_REQ; end
        P_HWAIT: pst <= P_HDR;
        P_HDR: begin
          blk_wa <= w[7:0]; blk_we <= 1;
          blk_wd <= (hdr_wr && w == 9'd36) ? dsum[31:16] : (hdr_wr && w == 9'd37) ? dsum[15:0]
                  : (hdr_wr && w == 9'd38) ? tsum[31:16] : (hdr_wr && w == 9'd39) ? tsum[15:0]
                  : hdr_data;
          w <= w + 1'b1;
          pst <= (w == 9'd255) ? P_WR : P_ADDR;
        end
        P_REQ: begin
          if (!mem_ack) mem_req <= 1;
          if (mem_req && mem_ack) begin
            blk_wa <= w[7:0]; blk_wd <= mem_rdata; blk_we <= 1;
            mem_req <= 0; pst <= P_TURN;
          end
        end
        P_TURN: if (!mem_ack) begin
          w <= w + 1'b1;
          pst <= (w == 9'd255) ? P_WR : P_ADDR;
        end

        P_WR: begin sd_lba <= {19'd0, cur}; sd_wr <= 1; ack_t <= 0; pst <= P_ACK; end
        P_ACK:
          if (sd_ack) begin sd_wr <= 0; pst <= P_DONE; end
          else if (&ack_t) begin
            sd_wr <= 0; n_retry <= n_retry + 1'b1; pst <= P_WR;
          end else ack_t <= ack_t + 1'b1;
        P_DONE:
          if (!sd_ack) begin
            n_blocks <= n_blocks + 1'b1;
            if (abort) abort <= 0;
            else if (hdr_wr) begin hdr_wr <= 0; flush_pending <= 0; dirty <= 0; n_flush <= n_flush + 1'b1; end
            else dirty <= 1;
            pst <= P_IDLE;
          end

        F_SZ0: begin hdr_addr <= 6'd33; pst <= F_SZ1; end
        F_SZ1: begin dsize[31:16] <= hdr_data; hdr_addr <= 6'd34; pst <= F_SZ2; end
        F_SZ2: begin dsize[15:0]  <= hdr_data; hdr_addr <= 6'd35; pst <= F_SZ3; end
        F_SZ3: begin
          tsize[31:16] <= hdr_data;
          dsum <= 0; tsum <= 0; sw <= 0; s_tags <= 0;
          pst <= F_SCAN;
        end
        F_SCAN: begin
          if (sw == 21'd0 && !s_tags) tsize[15:0] <= hdr_data;
          if (!s_tags && sw == d_words) begin
            s_tags <= 1; sw <= 0;
          end else if (s_tags && sw >= t_words) begin
            cur <= 13'd0; w <= 0; hdr_wr <= 1; pst <= P_ADDR;
          end else begin
            if (!mem_ack) mem_req <= 1;
            mem_addr <= s_tags ? BASE + {3'd0, d_words} + 24'd6 + {3'd0, sw} : BASE + {3'd0, sw};
            if (mem_req && mem_ack) begin
              if (s_tags) tsum <= {add[0], add[31:1]};
              else        dsum <= {add[0], add[31:1]};
              mem_req <= 0; pst <= F_TURN;
            end
          end
        end
        F_TURN: if (!mem_ack) begin sw <= sw + 1'b1; pst <= F_SCAN; end

        default: pst <= P_IDLE;
      endcase

      if (abort && !mem_req && !mem_ack && pst != P_DONE && !(pst == P_ACK && sd_ack)) begin
        pst <= P_IDLE; sd_wr <= 0; abort <= 0;
      end
      if (img_mounted) begin
        rd_ptr <= wr_ptr + (push ? 1'b1 : 1'b0); flush_pending <= 0; dirty <= 0; any_pushed <= 0;
        ps <= 0; hdr_wr <= 0;
        if (pst != P_IDLE) abort <= 1;
        if (pst != P_IDLE && pst != P_DONE && !mem_req && !sd_ack) begin
          pst <= P_IDLE; mem_req <= 0; sd_wr <= 0; abort <= 0;
        end
      end
    end
  end

  assign dbg = {n_blocks, n_flush, n_retry[3:0], count[3:0]};

endmodule
