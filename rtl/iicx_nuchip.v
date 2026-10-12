// iicx_nuchip.v - the IIcx's NuBus interface (the NuChip): a 10 MHz NuBus transaction for each
// 68030 cycle to $60000000-$FFFFFFFF, ended by DSACK1-0* (a 32-bit port) or BERR*.
//
// $F0xxxxxx, the board's own slot, is a bus error at once; a start no slave answers in 256 NuBus
// clocks (25.6 us) times out; the last transaction's status goes to VIA2 PB5/PB4 (00 no error,
// 01 error, 10 timeout, 11 try again later). Slot $9 holds the card, which answers its standard
// slot space $F9xxxxxx; every other slot is empty. The address, direction, byte lanes and write
// data are latched on the first clock of the cycle, as NuBus's start cycle carries them.

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
  // 10 MHz from the board's own crystal, unrelated to the CPU's: one tick per NuBus clock from a
  // fractional accumulator, NB_NUM / NB_DEN of a tick per clk
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
          card_addr <= addr[19:0]; card_rw <= rw; card_be <= be; card_wdata <= wdata;   // the latch
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
