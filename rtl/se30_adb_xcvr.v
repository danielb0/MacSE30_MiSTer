// se30_adb_xcvr.v - the ADB transceiver (342S0440-B): a PIC1654S running Apple's program
// (boot2.rom), wired as the logic board wires it; until the program loads it runs NOPs.

`timescale 1ns/1ps

module se30_adb_xcvr (
  input         clk,
  input         c16_en,               // GLUE's clock enables: C16M
  input         c3m_en,               // and C3M, meaningful with it
  input         reset_n,              // RESET*
  // the program, from the boot2.rom download
  input         pm_we,
  input   [8:0] pm_waddr,
  input  [11:0] pm_wdata,
  // VIA1
  input         st0, st1,             // PB4, PB5 pins
  output        int_n,                // to PB3
  output        sclk,                 // to CB1
  input         via_cb2_out,
  input         via_cb2_oe,
  output        dio,                  // the CB2 net, to CB2's input
  // the ADB line
  input         line,                 // its level: everything on it, wired-AND
  output        pull,                 // this chip's part: 1 pulls it low
  output [63:0] dbg
);

  reg  [11:0] pm [0:511];
  integer i;
  initial for (i = 0; i < 512; i = i + 1) pm[i] = 12'o0000;
  always @(posedge clk) if (pm_we) pm[pm_waddr] <= pm_wdata;

  wire  [8:0] pm_addr;
  reg  [11:0] pm_q = 0;
  always @(posedge clk) pm_q <= pm[pm_addr];

  wire  [3:0] ra_latch;
  wire  [7:0] rb_latch;
  wire        dio_net = rb_latch[3] & (via_cb2_oe ? via_cb2_out : 1'b1);
  wire  [3:0] ra_pin  = {ra_latch[3] & line, ra_latch[2], ra_latch[1] & st1, ra_latch[0] & st0};
  wire  [7:0] rb_pin  = {rb_latch[7:4], dio_net, rb_latch[2:0]};

  se30_pic1654 pic (
    .clk(clk), .osc_en(c16_en && c3m_en), .mclr_n(reset_n),
    .pm_addr(pm_addr), .pm_data(pm_q),
    .ra_latch(ra_latch), .ra_pin(ra_pin), .rb_latch(rb_latch), .rb_pin(rb_pin),
    .rtcc_pin(line), .dbg(dbg));

  assign pull  = ra_latch[2] | !ra_latch[3];
  assign sclk  = rb_latch[2];
  assign int_n = rb_latch[4];
  assign dio   = dio_net;

endmodule
