// se30_pram.v - persistent PRAM: the RTC's 256 bytes kept in an image file

`timescale 1ns/1ps

module se30_pram #(
  parameter integer SETTLE   = 62_668_800,
  parameter integer WD       = 62_668_800,
  parameter integer BACKSTOP = 188_006_400,
  parameter integer RST_LEN  = 64
) (
  input             clk,
  input             reset,

  input             osd_open,
  input             wipe,

  input             img_mounted,
  input             img_present,
  output reg        sd_rd,
  output reg        sd_wr,
  input             sd_ack,
  input       [7:0] sd_buff_addr,
  input      [15:0] sd_buff_dout,
  input             sd_buff_wr,
  output     [15:0] sd_buff_din,

  output reg        h_we,
  output reg  [7:0] h_addr,
  output reg  [7:0] h_wdata,
  output reg  [7:0] h_raddr,
  input       [7:0] h_rdata,
  input             pram_wr,

  output reg        ready,
  output            restart,
  output     [15:0] dbg
);

  localparam [3:0] S_IDLE = 4'd0, S_LD_RD = 4'd1, S_LD_DAT = 4'd2, S_LD_CPY = 4'd3,
                   S_FILL = 4'd4, S_SV_WR = 4'd5, S_SV_DAT = 4'd6, S_CLR = 4'd7, S_LD_KICK = 4'd8,
                   S_LD_FIN = 4'd9;
  reg  [3:0] st;

  reg [15:0] ld_m [0:127];
  reg [15:0] sv_m [0:127];
  reg [15:0] buf_q;
  reg [15:0] hq;
  reg        hpad;
  reg        bw_we;
  reg  [6:0] bw_addr;
  reg [15:0] bw_data;
  always @(posedge clk) begin
    if (st == S_LD_DAT && sd_ack && sd_buff_wr && !sd_buff_addr[7]) ld_m[sd_buff_addr[6:0]] <= sd_buff_dout;
    buf_q <= ld_m[bw_addr];
  end
  always @(posedge clk) begin
    if (bw_we) sv_m[bw_addr] <= bw_data;
    hq <= sv_m[sd_buff_addr[6:0]];
  end
  always @(posedge clk) hpad <= sd_buff_addr[7];
  assign sd_buff_din = hpad ? 16'h0000 : hq;

  reg  [9:0] n;
  reg        ena, dirty, ack_q, osd_q, wipe_q;
  reg        load_pend, flush_pend, wipe_pend, rst_after, restart_after;
  reg [27:0] settle, wd, backstop;
  reg  [1:0] tries;
  reg  [7:0] rst_cnt;
  reg  [2:0] n_loads;
  reg  [5:0] n_saves;

  assign restart = rst_cnt != 8'd0;
  assign dbg = {st, ena, dirty, ready, n_loads, n_saves};

  always @(posedge clk) begin
    if (reset) begin
      st <= S_IDLE; sd_rd <= 0; sd_wr <= 0; h_we <= 0; bw_we <= 0;
      ena <= 0; dirty <= 0; ready <= 0; ack_q <= 0; osd_q <= 0; wipe_q <= 0;
      load_pend <= 0; flush_pend <= 0; wipe_pend <= 0; rst_after <= 0; restart_after <= 0;
      settle <= 0; wd <= 0; backstop <= 0; tries <= 0; rst_cnt <= 0; n <= 0;
      n_loads <= 0; n_saves <= 0; h_addr <= 0; h_wdata <= 0; h_raddr <= 0;
      bw_addr <= 0; bw_data <= 0;
    end else begin
      ack_q <= sd_ack; osd_q <= osd_open; wipe_q <= wipe;
      h_we <= 0; bw_we <= 0;
      if (rst_cnt != 8'd0) rst_cnt <= rst_cnt - 8'd1;

      if (img_mounted) begin
        ena <= img_present;
        if (img_present) load_pend <= 1;
        else ready <= 1;
      end
      if (pram_wr) begin dirty <= 1; settle <= SETTLE; end
      else if (settle > 28'd1) settle <= settle - 28'd1;
      else if (settle == 28'd1) begin settle <= 0; if (dirty && ena) flush_pend <= 1; end
      if (osd_open && !osd_q && dirty && ena) flush_pend <= 1;
      if (wipe && !wipe_q) wipe_pend <= 1;
      if (!ready && st != S_LD_CPY && st != S_LD_FIN) begin
        if (backstop >= BACKSTOP) ready <= 1; else backstop <= backstop + 28'd1;
      end

      case (st)
        S_IDLE:
          if (wipe_pend) begin
            wipe_pend <= 0; n <= 0; st <= S_CLR;
          end else if (load_pend) begin
            load_pend <= 0; sd_rd <= 1; wd <= 0; tries <= 0; st <= S_LD_RD;
          end else if (flush_pend) begin
            flush_pend <= 0; rst_after <= 0; n <= 0; st <= S_FILL;
            if (!pram_wr) dirty <= 0;
          end

        S_LD_RD:
          if (sd_ack) begin sd_rd <= 0; wd <= 0; st <= S_LD_DAT; end
          else if (wd >= WD) begin
            wd <= 0; sd_rd <= 0;
            if (tries == 2'd3) begin ready <= 1; st <= S_IDLE; end
            else begin tries <= tries + 2'd1; st <= S_LD_KICK; end
          end else wd <= wd + 28'd1;
        S_LD_KICK: begin sd_rd <= 1; st <= S_LD_RD; end
        S_LD_DAT:
          if (ack_q && !sd_ack) begin
            restart_after <= ready;
            n <= 0; bw_addr <= 0; st <= S_LD_CPY;
          end else if (wd >= WD) begin wd <= 0; ready <= 1; st <= S_IDLE; end
          else wd <= wd + 28'd1;
        S_LD_CPY: begin
          n <= n + 10'd1;
          case (n[1:0])
            2'd2: begin h_we <= 1; h_addr <= {bw_addr, 1'b0}; h_wdata <= buf_q[7:0]; end
            2'd3: begin
              h_we <= 1; h_addr <= {bw_addr, 1'b1}; h_wdata <= buf_q[15:8];
              if (bw_addr == 7'd127) st <= S_LD_FIN;
              else bw_addr <= bw_addr + 7'd1;
            end
            default: ;
          endcase
        end

        S_LD_FIN: begin
          dirty <= 0; ena <= 1; ready <= 1; n_loads <= n_loads + 3'd1;
          if (restart_after) begin restart_after <= 0; rst_cnt <= RST_LEN; end
          st <= S_IDLE;
        end

        S_FILL: begin
          h_raddr <= n[7:0];
          n <= n + 10'd1;
          if (n >= 10'd2) begin
            if (n[0]) begin
              bw_we <= 1; bw_addr <= n[8:1] - 8'd1; bw_data <= {h_rdata, bw_data[7:0]};
            end else bw_data[7:0] <= h_rdata;
          end
          if (n == 10'd257) st <= S_SV_WR;
        end
        S_SV_WR: begin
          sd_wr <= 1;
          if (sd_ack) begin sd_wr <= 0; st <= S_SV_DAT; end
        end
        S_SV_DAT:
          if (ack_q && !sd_ack) begin
            n_saves <= n_saves + 6'd1;
            if (rst_after) begin rst_after <= 0; rst_cnt <= RST_LEN; end
            st <= S_IDLE;
          end

        S_CLR: begin
          h_we <= 1; h_addr <= n[7:0]; h_wdata <= 8'h00;
          n <= n + 10'd1;
          if (n == 10'd255) begin
            dirty <= 0;
            if (ena) begin rst_after <= 1; n <= 0; st <= S_FILL; end
            else begin rst_cnt <= RST_LEN; st <= S_IDLE; end
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
