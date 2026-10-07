// se30_flp_loader.v - floppy image loader: the SD image into SDRAM, and its format

`timescale 1ns/1ps

module se30_flp_loader #(
  parameter [23:0] BASE = 24'h800000
) (
  input             clk,
  input             reset_n,

  input             img_mounted,
  input      [63:0] img_size,
  input             img_readonly,

  output reg [31:0] sd_lba,
  output reg        sd_rd,
  input             sd_ack,
  input       [7:0] sd_buff_addr,
  input      [15:0] sd_buff_dout,
  input             sd_buff_wr,

  output reg        mem_req,
  output reg [23:0] mem_addr,
  output reg [15:0] mem_wdata,
  input             mem_ack,

  input             eject,

  output reg        disk_in,
  output reg        img_ds,
  output reg        img_800k,
  output reg        img_tags,
  output reg        img_mfm,
  output reg        img_hd,
  output reg        readonly,
  output reg        loading,

  input       [5:0] hdr_addr,
  output reg [15:0] hdr_data,
  output            is_dc42,
  output     [12:0] file_blks,

  output     [15:0] dbg
);

  reg [15:0] buf_ram [0:255];
  reg [15:0] buf_q;
  reg  [7:0] buf_idx;
  reg  [7:0] drain_idx;

  wire [15:0] sw_data = {sd_buff_dout[7:0], sd_buff_dout[15:8]};
  always @(posedge clk) begin
    if (sd_buff_wr && sd_ack) buf_ram[sd_buff_addr] <= sw_data;
    buf_q   <= buf_ram[drain_idx];
    buf_idx <= drain_idx;
  end

  localparam S_IDLE  = 3'd0;
  localparam S_RD    = 3'd1;
  localparam S_WAIT  = 3'd2;
  localparam S_DRAIN = 3'd3;
  localparam S_NEXT  = 3'd4;
  localparam S_DONE  = 3'd5;

  reg  [2:0] state;
  reg [31:0] sec_total;
  reg [23:0] file_word;
  reg [63:0] size_l;
  reg        dc42;
  reg        dc42_name_ok;
  reg  [7:0] dc42_fmt;
  reg [31:0] dc42_dsize, dc42_tsize;
  reg        old_ack;

  reg        mount_pending;
  reg [63:0] pend_size;
  reg        pend_ro;

  reg [15:0] hdr_ram [0:63];
  always @(posedge clk) begin
    if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0 && sd_buff_addr < 8'd42)
      hdr_ram[sd_buff_addr[5:0]] <= sw_data;
    hdr_data <= hdr_ram[hdr_addr];
  end

  localparam [23:0] DC42_HDR_WORDS = 24'd42;

  localparam [15:0] MDB_SIG_MFS = 16'hD2D7;
  localparam [15:0] MDB_SIG_HFS = 16'h4244;
  localparam [23:0] SIDEDNESS_THRESHOLD = 24'd1200;

  wire [8:0] mdb_idx = {1'b0, sd_buff_addr} - (dc42 ? 9'd42 : 9'd0);
  wire       mdb_wr  = (state == S_RD) && sd_buff_wr && sd_ack && (sd_lba == 32'd2);

  reg [15:0] mdb_sig;
  reg [15:0] mdb_nalbk;
  reg [15:0] mdb_absz_h;
  reg [15:0] mdb_absz_l;
  reg        mdb_seen;

  wire mdb_ok = mdb_seen &&
                ((mdb_sig == MDB_SIG_MFS) || (mdb_sig == MDB_SIG_HFS)) &&
                (mdb_absz_h == 16'd0) && (mdb_absz_l != 16'd0) &&
                (mdb_absz_l[8:0] == 9'd0) && (mdb_nalbk != 16'd0);

  reg [23:0] vol_blocks;
  reg [23:0] mul_cand;
  reg  [6:0] mul_mult;
  reg  [2:0] mul_step;
  reg        mul_busy;

  wire [31:0] data_size = dc42 ? dc42_dsize : size_l[31:0];
  wire        is800     = (data_size == 32'd819200) && (!dc42 || size_l[63:32] == 0);
  wire        is400     = (data_size == 32'd409600);
  wire        fits      = !dc42 || (size_l >= 64'd84 + data_size);
  wire        gcr       = (is800 || is400) && fits && (!dc42 || dc42_fmt < 8'd2) &&
                          (dc42 || size_l[63:32] == 0);
  wire        is1440    = (data_size == 32'd1474560);
  wire        is720     = (data_size == 32'd737280);
  wire        mfm       = (is1440 || is720) && fits && (!dc42 || dc42_fmt == 8'd2 || dc42_fmt == 8'd3) &&
                          (dc42 || size_l[63:32] == 0);
  wire [31:0] tags_want = is800 ? 32'd19200 : 32'd9600;
  wire        tags_ok   = dc42 && dc42_tsize == tags_want && size_l >= 64'd84 + data_size + tags_want;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      state <= S_IDLE; sd_rd <= 0; sd_lba <= 0; mem_req <= 0; mem_addr <= 0; mem_wdata <= 0;
      loading <= 0; disk_in <= 0; img_ds <= 0; img_800k <= 0; img_tags <= 0; readonly <= 0;
      img_mfm <= 0; img_hd <= 0;
      dc42 <= 0; dc42_name_ok <= 0; dc42_fmt <= 0; dc42_dsize <= 0; dc42_tsize <= 0;
      mount_pending <= 0; pend_size <= 0; pend_ro <= 0; size_l <= 0;
      sec_total <= 0; file_word <= 0; drain_idx <= 0; old_ack <= 0;
      mdb_seen <= 0; mdb_sig <= 0; mdb_nalbk <= 0; mdb_absz_h <= 0; mdb_absz_l <= 0;
      vol_blocks <= 0; mul_cand <= 0; mul_mult <= 0; mul_step <= 0; mul_busy <= 0;
    end else begin
      old_ack <= sd_ack;

      if (img_mounted) begin
        mount_pending <= 1; pend_size <= img_size; pend_ro <= img_readonly;
        disk_in <= 0;
        if (img_size != 64'd0) loading <= 1;
      end
      if (eject) disk_in <= 0;

      if (state == S_RD && sd_buff_wr && sd_ack && sd_lba == 32'd0) begin
        case (sd_buff_addr)
          8'd0:  dc42_name_ok <= (sd_buff_dout[7:0] >= 8'd1) && (sd_buff_dout[7:0] <= 8'd63);
          8'd32: dc42_dsize[31:16] <= sw_data;
          8'd33: dc42_dsize[15:0]  <= sw_data;
          8'd34: dc42_tsize[31:16] <= sw_data;
          8'd35: dc42_tsize[15:0]  <= sw_data;
          8'd40: dc42_fmt <= sd_buff_dout[7:0];
          8'd41: if (dc42_name_ok && sd_buff_dout == 16'h0001) dc42 <= 1;
          default: ;
        endcase
      end

      if (mdb_wr)
        case (mdb_idx)
          9'd0:  mdb_sig    <= sw_data;
          9'd9:  mdb_nalbk  <= sw_data;
          9'd10: mdb_absz_h <= sw_data;
          9'd11: begin mdb_absz_l <= sw_data; mdb_seen <= 1; end
          default: ;
        endcase
      if (mdb_wr && mdb_idx == 9'd11) begin
        vol_blocks <= 0; mul_cand <= {8'd0, mdb_nalbk}; mul_mult <= sw_data[15:9];
        mul_step <= 0; mul_busy <= 1;
      end else if (mul_busy) begin
        if (mul_mult[0]) vol_blocks <= vol_blocks + mul_cand;
        mul_cand <= {mul_cand[22:0], 1'b0};
        mul_mult <= {1'b0, mul_mult[6:1]};
        mul_step <= mul_step + 3'd1;
        if (mul_step == 3'd6) mul_busy <= 0;
      end

      case (state)

        S_IDLE:
          if (mount_pending && !img_mounted) begin
            mount_pending <= 0;
            readonly <= pend_ro;
            size_l   <= pend_size;
            dc42 <= 0; dc42_name_ok <= 0; dc42_fmt <= 0; dc42_dsize <= 0; dc42_tsize <= 0;
            mdb_seen <= 0; mul_busy <= 0; vol_blocks <= 0;
            img_ds <= 0; img_800k <= 0; img_tags <= 0; img_mfm <= 0; img_hd <= 0;
            if (pend_size != 64'd0) begin
              sec_total <= pend_size[40:9] + {31'd0, |pend_size[8:0]};
              sd_lba    <= 32'd0;
              file_word <= 24'd0;
              loading   <= 1;
              sd_rd     <= 1;
              state     <= S_RD;
            end else loading <= 0;
          end

        S_RD: begin
          if (sd_ack) sd_rd <= 0;
          if (old_ack && !sd_ack) begin
            drain_idx <= 8'd0;
            state     <= S_WAIT;
          end
        end

        S_WAIT: state <= S_DRAIN;

        S_DRAIN: begin
          if (!mem_req) begin
            if (dc42 && file_word < DC42_HDR_WORDS) begin
              file_word <= file_word + 24'd1;
              drain_idx <= drain_idx + 8'd1;
              if (drain_idx == 8'd255) state <= S_NEXT;
            end else if (!mem_ack && buf_idx == drain_idx) begin
              mem_addr  <= BASE + (dc42 ? (file_word - DC42_HDR_WORDS) : file_word);
              mem_wdata <= buf_q;
              mem_req   <= 1;
            end
          end else if (mem_ack) begin
            mem_req   <= 0;
            file_word <= file_word + 24'd1;
            drain_idx <= drain_idx + 8'd1;
            if (drain_idx == 8'd255) state <= S_NEXT;
          end
        end

        S_NEXT: begin
          if (mount_pending) state <= S_IDLE;
          else if (sd_lba + 32'd1 >= sec_total) state <= S_DONE;
          else begin
            sd_lba <= sd_lba + 32'd1;
            sd_rd  <= 1;
            state  <= S_RD;
          end
        end

        S_DONE:
          if (!mul_busy && !mem_req && !mem_ack) begin
            img_800k <= is800;
            img_ds   <= is800 && (!mdb_ok || vol_blocks > SIDEDNESS_THRESHOLD);
            img_tags <= tags_ok;
            img_mfm  <= mfm;
            img_hd   <= mfm && is1440;
            disk_in  <= (gcr || mfm) && !mount_pending && !img_mounted;
            if (!mount_pending && !img_mounted) loading <= 0;
            state    <= S_IDLE;
          end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign is_dc42   = dc42;
  assign file_blks = sec_total[12:0];
  assign dbg = {disk_in, loading, img_ds, img_800k, img_tags, dc42, state, sd_lba[6:0]};

endmodule
