// se30_adb_xcvr.v - the SE/30's ADB transceiver (UL11, Apple 342S0440-B):
// a PIC1654S running Apple's program, wired as sheet 4 wires it.
// SE30_PLAN.md 6.2, 6.3.
//
// THE PROGRAM
//   Apple's mask program is not in this repository: it arrives as
//   boot2.rom (plan 6.3.4) and is written here a 12-bit word at a time.
//   Until it arrives the store holds zeros - NOPs: the PIC runs through
//   its memory touching nothing, so its latches keep their reset value, 1.
//   INT*, SCLK and DIO stay released and the machine waits in the ADB
//   Manager's initialisation as it did before the transceiver existed;
//   RA2 at 1 holds the ADB line low, as a blank chip would on the board,
//   and the devices sit in Global Reset.
//
// THE PINS (plan 6.2, 6.3.2) - every PIC line is a latch with a pull-up,
// read back as the wired-AND of its latch and whatever else drives it:
//   RA0, RA1  ST0, ST1 in, from VIA1 PB4, PB5
//   RA2       FDBO*: a 1 turns Q3 on, which pulls the ADB line low
//   RA3       FDBO: on the line itself (its latch at 0 would pull it low)
//   RTCC      FDBI: the line
//   RB2       SCLK out, to VIA1 CB1
//   RB3       DIO, to and from VIA1 CB2: the VIA drives it while it
//             shifts out
//   RB4       INT* out, to VIA1 PB3
//   RB0, RB1, RB5-RB7  unconnected: read 1
//   OSC1      C3M, GLUE's 3.672 MHz: c3m_en qualified by c16_en.  GLUE
//             updates c3m_en only on C16M's enable, so it is high for a
//             whole C16M period (two clk); taken alone it counted twice,
//             ran the PIC at twice its speed and halved every ADB timing -
//             compile 17's mouse that did not move (plan 6.12 item 7)
//   MCLR      RESET*, which the RESET instruction pulses, as the VIAs'
//   With MCLR low the latches are high (the data sheet, p. 4-39), so RA2 turns
//   Q3 on and the line is held low for as long as RESET* is - a long reset
//   is an ADB Global Reset (3 ms or more), as on the board.

`timescale 1ns/1ps

module se30_adb_xcvr (
  input         clk,
  input         c16_en,               // GLUE's clock enables: C16M,
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
