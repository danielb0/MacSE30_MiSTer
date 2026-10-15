// dbg_rtrace.v - RTRACE, the format $A replay trace (SE30_PLAN.md KNOWN
// ISSUES 20).  Plain Verilog: dbg_probes.sv puts it on JTAG (PRTD, PRTC),
// sim/predec_fault runs it as it is.
//
// WHAT IT ANSWERS
//   On the board the two longs written at a page top after the BlockMove's
//   write fault land as single MSB bytes - byte cycles, or longs of
//   XX000000?  Three levels, for the writes after each format $A replay:
//     R  the frame as the RTE read it back (A/UX's handler never writes
//        it, so as stacked): state1, SSW, fault address, DOB
//     K  each kernel data write as its cycle starts (tg68k.v's dbg_rpk):
//        logical and physical address, SIZ, data, FC, posted, byte lanes
//     S  each CPU write's WRITE pair at the SDRAM pins (se30_sdram.v's
//        dbg_wr): the DQM on A12:11 for each word, bank, row, column, words
//   A replay whose fault address matches (fault ^ match) & mask == 0 logs
//   its R and opens a window for the next KN K and SN S records; a replay
//   that does not match closes the window.
//
// THE RING
//   512 x 128 in block RAM.  Each record {kind[1:0], time[15:0] (clk_sys,
//   wrapping), ...}:
//     R 01: SSW[15:0], state1[15:0], fault address[31:0], DOB[31:0],
//           the replay's number[13:0]
//     K 10: logical[31:0], physical[31:0], data[31:0], SIZ[1:0], FC[2:0],
//           posted, lanes[3:0], 4'b0
//     S 11: DQM high[1:0], DQM low[1:0], bank[1:0], row[12:0], column[8:0],
//           high word[15:0], low word[15:0], 50'b0
//   Logging runs while arm is up; arm low clears the ring and the counts.
//   wrap low stops at 512 records (the earliest kept), high overwrites
//   (the latest kept).

`timescale 1ns/1ps

module dbg_rtrace #(
  parameter KN = 4,                    // K records a window
  parameter SN = 6                     // S records a window
) (
  input             clk,               // clk_sys
  input      [96:0] rpr,               // tg68k.v's dbg_rpr
  input     [106:0] rpk,               // tg68k.v's dbg_rpk
  input      [60:0] sdw,               // se30_sdram.v's dbg_wr (clk_mem, steady between pairs)
  input             arm,
  input             wrap,
  input      [31:0] mask,
  input      [31:0] match,
  input       [8:0] raddr,
  output reg [127:0] rdata,
  output     [63:0] status             // {replays[23:0], matches[15:0], write pointer[8:0], full, arm, 13'b0}
);

  reg [127:0] mem [0:511];
  reg   [8:0] wp = 0;
  reg         full = 0;
  reg  [15:0] t = 0;
  reg  [23:0] n_rpl = 0;
  reg  [15:0] n_hit = 0;
  reg   [2:0] k_left = 0;
  reg   [2:0] s_left = 0;
  reg         rp_q = 0, sw_q = 0;
  reg         s_pend = 0;
  reg  [59:0] s_dat = 0;

  wire        r_rise = rpr[96] && !rp_q;
  wire        hit    = ((rpr[63:32] ^ match) & mask) == 32'd0;
  wire        k_ev   = rpk[106] && (k_left != 0);
  wire        s_new  = (sdw[60] != sw_q) && (s_left != 0);
  wire        r_log  = r_rise && hit;
  wire        s_log  = s_pend && !r_log && !k_ev;
  wire        on     = arm && (wrap || !full);
  wire        we     = on && (r_log || k_ev || s_log);
  wire [127:0] wd    = r_log ? {2'b01, t, rpr[79:64], rpr[95:80], rpr[63:32], rpr[31:0], n_rpl[13:0]} :
                       k_ev  ? {2'b10, t, rpk[105:0], 4'b0} :
                               {2'b11, t, s_dat, 50'b0};

  always @(posedge clk) begin
    t    <= t + 1'd1;
    rp_q <= rpr[96];
    sw_q <= sdw[60];
    if (we) mem[wp] <= wd;
    rdata <= mem[raddr];
    if (!arm) begin
      wp <= 0; full <= 0; n_rpl <= 0; n_hit <= 0; k_left <= 0; s_left <= 0; s_pend <= 0;
    end else begin
      if (we) begin wp <= wp + 1'd1; if (&wp) full <= 1'b1; end
      if (r_rise) begin
        n_rpl <= n_rpl + 1'd1;
        if (hit) begin n_hit <= n_hit + 1'd1; k_left <= KN; s_left <= SN; end
        else begin k_left <= 0; s_left <= 0; end
      end else if (k_ev) k_left <= k_left - 1'd1;
      if (s_new && !r_rise) begin s_pend <= 1'b1; s_dat <= sdw[59:0]; s_left <= s_left - 1'd1; end
      else if (s_log) s_pend <= 1'b0;
    end
  end

  assign status = {n_rpl, n_hit, wp, full, arm, 13'b0};

endmodule
