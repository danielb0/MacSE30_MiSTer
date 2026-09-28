// se30_flp_dkmux.v - the SDRAM disk port shared by the image loader and the
// track encoder (SE30_PLAN.md 5.12.5: "the loader while loading (the disk
// is out, so the encoder is idle), the encoder otherwise").
//
// WHAT IT DOES
//   One owner at a time.  The owner follows `loading`, but changes only
//   while the port is quiet - the owner's request down and the
//   controller's acknowledge down - so a request is never taken from under
//   its requester, and an acknowledge never lands on the other side.  The
//   side that does not own the port sees no acknowledge and keeps its
//   request up (both requesters hold a request until acknowledged).
//   The loader only writes and the encoder only reads, so the direction
//   is the owner.  Held to sim/gcrread/tb_se30_gcrread.v.

`timescale 1ns/1ps

module se30_flp_dkmux (
  input             clk,
  input             reset_n,
  input             loading,           // the loader's: a load under way or waiting

  input             ld_req,            // the loader: writes
  input      [23:0] ld_addr,
  input      [15:0] ld_wdata,
  output            ld_ack,

  input             en_req,            // the encoder: reads
  input      [23:0] en_addr,
  output     [15:0] en_rdata,
  output            en_ack,

  output            dk_req,            // se30_sdram's dk_* port
  output            dk_we,
  output     [23:0] dk_addr,
  output     [15:0] dk_wdata,
  input      [15:0] dk_rdata,
  input             dk_ack
);

  reg owner;                           // 0 = the loader, 1 = the encoder

  always @(posedge clk or negedge reset_n)
    if (!reset_n)                  owner <= 1'b1;
    else if (!dk_req && !dk_ack)   owner <= !loading;

  assign dk_req   = owner ? en_req  : ld_req;
  assign dk_we    = !owner;
  assign dk_addr  = owner ? en_addr : ld_addr;
  assign dk_wdata = ld_wdata;
  assign ld_ack   = !owner && dk_ack;
  assign en_ack   =  owner && dk_ack;
  assign en_rdata = dk_rdata;

endmodule
