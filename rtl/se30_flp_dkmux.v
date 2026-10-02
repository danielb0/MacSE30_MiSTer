// se30_flp_dkmux.v - the SDRAM disk port shared by the two drives' image
// loaders and track encoders (SE30_PLAN.md 5.12.5, 5.14).
//
// WHAT IT DOES
//   One owner at a time, of four requesters: the internal drive's loader
//   (0) and encoder (1), the external drive's loader (2) and encoder (3).
//   The owner changes only while the port is quiet - the owner's request
//   down and the controller's acknowledge down - so a request is never
//   taken from under its requester and an acknowledge never lands on
//   another; it then passes round robin to the next requester with a
//   request up, after the owner, or stays if none has one.  A requester
//   that does not own the port sees no acknowledge and keeps its request
//   up: every requester holds request, address and data until acknowledged
//   and raises the next only after the acknowledge falls, so a quiet clock
//   comes between any two words and none can hold the port.  With one
//   drive the owner could follow the loader's `loading` (its loader and
//   encoder never want the port at once); with two, one drive's encoder
//   streams while the other's image loads (5.14).  The loaders only write
//   and the encoders only read, so the direction is the owner's kind.
//   Held to sim/flpmux and sim/gcrread.

`timescale 1ns/1ps

module se30_flp_dkmux (
  input             clk,
  input             reset_n,

  input             ld0_req,           // the internal drive's loader: writes
  input      [23:0] ld0_addr,
  input      [15:0] ld0_wdata,
  output            ld0_ack,

  input             en0_req,           // the internal drive's encoder: reads
  input      [23:0] en0_addr,
  output     [15:0] en0_rdata,
  output            en0_ack,

  input             ld1_req,           // the external drive's loader
  input      [23:0] ld1_addr,
  input      [15:0] ld1_wdata,
  output            ld1_ack,

  input             en1_req,           // the external drive's encoder
  input      [23:0] en1_addr,
  output     [15:0] en1_rdata,
  output            en1_ack,

  output            dk_req,            // se30_sdram's dk_* port
  output            dk_we,
  output     [23:0] dk_addr,
  output     [15:0] dk_wdata,
  input      [15:0] dk_rdata,
  input             dk_ack
);

  reg  [1:0] owner;                    // 0 ld0, 1 en0, 2 ld1, 3 en1
  wire [3:0] req = {en1_req, ld1_req, en0_req, ld0_req};

  // the next owner: the first request after the current owner, round
  // robin - rot[i] is requester owner + 1 + i
  reg  [3:0] rot;
  always @*
    case (owner)
      2'd0:    rot = {req[0], req[3], req[2], req[1]};
      2'd1:    rot = {req[1], req[0], req[3], req[2]};
      2'd2:    rot = {req[2], req[1], req[0], req[3]};
      default: rot = {req[3], req[2], req[1], req[0]};
    endcase
  wire [1:0] step = rot[0] ? 2'd1 : rot[1] ? 2'd2 : 2'd3;   // owner + step (rot[2:0] has a request)

  always @(posedge clk or negedge reset_n)
    if (!reset_n)                              owner <= 2'd1;
    else if (!dk_req && !dk_ack && |rot[2:0])  owner <= owner + step;

  assign dk_req   = req[owner];
  assign dk_we    = !owner[0];
  assign dk_addr  = owner == 2'd0 ? ld0_addr : owner == 2'd1 ? en0_addr : owner == 2'd2 ? ld1_addr : en1_addr;
  assign dk_wdata = owner[1] ? ld1_wdata : ld0_wdata;
  assign ld0_ack  = owner == 2'd0 && dk_ack;
  assign en0_ack  = owner == 2'd1 && dk_ack;
  assign ld1_ack  = owner == 2'd2 && dk_ack;
  assign en1_ack  = owner == 2'd3 && dk_ack;
  assign en0_rdata = dk_rdata;
  assign en1_rdata = dk_rdata;

endmodule
