// se30_video.v - the SE/30's pseudo-slot video: the six PALs, the two
// LS393 counters, the LS166 shifter, the 64KB VRAM and the 8KB declaration
// ROM of sheet 5, as one module.
//
// STUB.  This is the port contract only, so that sim/video/tb_se30_video.v
// compiles and fails.  The behaviour is written next, from SE30_PLAN.md
// 2.6, 2.9, 2.10 and 2.11 (row 15), not from Bolle's equations.

`timescale 1ns/1ps

module se30_video #(
  parameter DECLROM_HEX = "",          // $readmemh image of the 8KB declaration ROM
  parameter V_TOTAL     = 370          // lines per frame: the Guide's 370; 372 is the open item of plan 2.9
) (
  input         clk,                   // C16M, 15.6672 MHz: the pixel clock and the PALs' clock
  input         reset_n,

  // CPU side: one slot-$E cycle.  sel is GLUE's NUBUS* qualified by
  // A31-A25 all ones and A24 = 0 (UJ6 + UE7 on the board); the decoder
  // that ignores A23-A17 lives outside, in GLUE (plan 2.10 item 2).
  input         sel,
  input         as_n,
  input         ds_n,
  input         rw,                    // 1 = read
  input  [16:0] addr,                  // A16 = 1 declaration ROM, 0 VRAM; A15-A0
  input   [7:0] din,                   // D31-D24: the slot is an 8-bit port
  output  [7:0] dout,
  output        dsack0_n,              // driven only during an access (UE6)

  // VIA1
  input         page,                  // PA6 vPage2: 1 = page 0 (VRAM $8000 up), 0 = page 1
  input         vsyncen_n,             // PB6 vSyncEnA: 0 = retrace interrupt enabled

  // video
  output        vidout,                // 1 = black
  output        hsync_n,
  output        vsync_n,
  output        hblank,
  output        vblank,
  output        irq6_n                 // slot $E interrupt, UI6's latch
);

  // internal signals the bench watches (names from sheet 5)
  wire hctrrst = 1'b0;                 // horizontal counter clear, once per line
  wire lctrrst = 1'b0;                 // line counter clear, once per frame
  wire fetch   = 1'b0;                 // SC: one VRAM byte fetched (once per 8 pixels in active video)

  assign dout     = 8'h00;
  assign dsack0_n = 1'b1;
  assign vidout   = 1'b1;
  assign hsync_n  = 1'b1;
  assign vsync_n  = 1'b1;
  assign hblank   = 1'b1;
  assign vblank   = 1'b1;
  assign irq6_n   = 1'b1;

endmodule
