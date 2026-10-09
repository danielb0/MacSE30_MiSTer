// iicx_nuchip.v - the IIcx's NuBus interface (the NuChip, UG8; SE30_PLAN.md
// 14.2 items 3 and 8, 14.3 item 2).
//
// WHAT IT IS
//   The main logic board's side of NuBus, as *Designing Cards and Drivers*
//   (2nd ed., ch. 1-3) and the IIcx schematic (sheet 5) describe it: GLUE
//   raises NUBUS* for any physical address $60000000-$FFFFFFFF; the NuChip
//   synchronises the request to the NuBus clock, runs a transaction - a
//   start cycle, the slave's wait, an acknowledge cycle - and terminates
//   the 68030's cycle itself: DSACK1-0* (a 32-bit port) with the data, or
//   BERR*.  Its own state machine acknowledges a start no slave answers
//   after 256 NuBus clocks (25.6 us) with a timeout status.  $F0xxxxxx, the
//   main board's own slot, is a bus error at once with no transaction.
//   The status of the last transaction goes to VIA2 PB5/PB4 (v2TM0A,
//   v2TM1A; Guide Tables 4-15 and 4-16: 00 no error, 01 error, 10 timeout,
//   11 try again later).
//
// THE CLOCK
//   The NuBus clock is 10 MHz from the board's own 40 MHz crystal (Y3,
//   sheet 5), unrelated to the CPU's 31.3344 MHz, so every transaction
//   waits for its next edge.  Here: one tick per NuBus clock from a
//   fractional accumulator on clk, NB_NUM / NB_DEN of a tick per clock
//   (100,000 / 313,344 on clk_sys).
//
// THE SLOTS
//   The IIcx has slots $9-$B.  Slot $9 holds the card (card_*); it answers
//   its standard slot space $F9xxxxxx only - nothing read so far says the
//   Toby card decodes super slot space, which, with slots $A and $B and
//   every other slot number, times out as an empty slot does.
//
// THE LATCH
//   The address, direction, byte lanes and write data are latched on the
//   first clock NUBUS* is seen - the 68030's write data is valid from then
//   (GLUE's header) - and the card works from these registers.  NuBus
//   multiplexes them onto AD31-AD0 at its start cycle, so a card never saw
//   the processor's pins; and a combinational path from the kernel's
//   address adder into the card's VRAM addressing (300 M10K away) cost a
//   full compile 1.5 hours of routing (plan 14.3).
//
// OPEN: the NuChip's synchronisation latency at either end (the books give
//   none); the card's speed is tuned against a real IIcx in step 3.

`timescale 1ns/1ps

module iicx_nuchip #(
  parameter NB_NUM = 100000,           // NuBus ticks per clk, as a fraction
  parameter NB_DEN = 313344,
  parameter TIMEOUT = 256              // NuBus clocks from START to the timeout acknowledge
) (
  input             clk,
  input             reset_n,

  // GLUE: NUBUS* and the 68030's cycle
  input             sel,               // NUBUS*, active high: AS* with an address in $6-$F
  input      [31:0] addr,
  input             rw,                // 1 = read
  input       [3:0] be,                // byte lanes, be[3] = D31-D24 (UM Table 7-7)
  input      [31:0] wdata,
  output reg [31:0] rdata,
  output      [1:0] dsack_n,           // 00 when the transaction is acknowledged
  output            berr,

  // the transfer status to VIA2: {PB5 v2TM0A, PB4 v2TM1A}
  output reg  [1:0] tm_pb54,

  output reg        nb_tick,           // one clk per NuBus clock

  // slot $9: the card
  output reg        card_sel,
  output reg [19:0] card_addr,
  output reg        card_rw,
  output reg  [3:0] card_be,
  output reg [31:0] card_wdata,
  input      [31:0] card_rdata,
  input             card_ack
);

  // ------------------------------------------------------- the NuBus clock
  reg [18:0] acc;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin acc <= 0; nb_tick <= 0; end
    else if (acc + NB_NUM >= NB_DEN) begin acc <= acc + NB_NUM - NB_DEN; nb_tick <= 1; end
    else begin acc <= acc + NB_NUM; nb_tick <= 0; end

  // ------------------------------------------------------- the transaction
  localparam S_IDLE = 3'd0, S_SYNC = 3'd1, S_WAIT = 3'd2, S_ACK = 3'd3, S_BERR = 3'd4;
  reg  [2:0] st;
  reg  [8:0] nbc;                      // NuBus clocks since START
  wire to_card = (addr[31:24] == 8'hF9);
  wire own_slot = (addr[31:24] == 8'hF0);
  reg  slot9;

  assign dsack_n = (sel && st == S_ACK) ? 2'b00 : 2'b11;
  assign berr    = sel && st == S_BERR;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      st <= S_IDLE; nbc <= 0; card_sel <= 0; rdata <= 0; tm_pb54 <= 2'b00; slot9 <= 0;
      card_addr <= 0; card_rw <= 1; card_be <= 0; card_wdata <= 0;
    end else if (!sel) begin
      st <= S_IDLE; card_sel <= 0;
    end else case (st)
      S_IDLE:
        if (own_slot) st <= S_BERR;                    // the board's slot: no transaction
        else begin
          st <= S_SYNC; slot9 <= to_card;
          card_addr <= addr[19:0]; card_rw <= rw; card_be <= be; card_wdata <= wdata;   // THE LATCH
        end
      S_SYNC:                                          // the next NuBus clock edge starts it
        if (nb_tick) begin st <= S_WAIT; nbc <= 0; card_sel <= slot9; end
      S_WAIT:                                          // the slave's acknowledge, sampled each NuBus clock
        if (nb_tick) begin
          if (card_sel && card_ack) begin
            st <= S_ACK; card_sel <= 0; rdata <= card_rdata; tm_pb54 <= 2'b00;
          end else if (nbc == TIMEOUT - 1) begin
            st <= S_BERR; card_sel <= 0; tm_pb54 <= 2'b01;   // v2TM1A = 1, v2TM0A = 0: bus timeout
          end else nbc <= nbc + 1'b1;
        end
      default: ;                                       // S_ACK, S_BERR: held until AS* rises
    endcase

endmodule
