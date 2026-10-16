// dbg_jtrace.v - JTRACE, the jump-to-low-memory trace (SE30_PLAN.md KNOWN
// ISSUES 22, 2026-10-16).  Plain Verilog: dbg_probes.sv puts it on JTAG
// (PJTD, PJTC), sim/predec_fault runs it as it is.
//
// WHAT IT ANSWERS
//   On the board (compiles 71 and 73) A/UX's macgetty returns from its
//   rename() syscall stub to address 0: the stub's RTS loads PC 0 although
//   the core file shows its return address ($10DC) on the stack, and SP has
//   advanced by 4.  Which beat gave the RTS its 0 - the bus, the data cache,
//   the DIB, or a beat released by a PMMU fault - and what came before it.
//
// THE RING
//   512 x 192 in block RAM, one record for every beat the kernel takes
//   (k_clkena with busstate fetch, read or write), wrapping.  The trigger: a
//   user program fetch (FC 2) from a logical address below `limit`; the ring
//   then takes POST more records and freezes, so it holds the beats before
//   the jump and a few after.  Arm low clears it.
//   Record [191:0]:
//     [191:178] time (clk_sys, wrapping)       [177:176] busstate (00 fetch, 10 read, 11 write)
//     [175:173] FC                              [172:171] SIZ
//     [170:139] logical address                [138:107] physical address
//     [106:75]  the data the kernel took (a write: the data it drove)
//     [74:67]   {beat_valid, force-released, cache or DIB hit, data-cache hit,
//               write-only zero, posted write, PMMU fault live, bus error}
//     [66]      the kernel's decode beat (decodeOPC)
//     [65:50]   opcode (the kernel's opcode register)
//     [49:18]   its PC                         [17:0] 0

`timescale 1ns/1ps

module dbg_jtrace #(
  parameter POST = 24                  // records after the trigger
) (
  input             clk,               // clk_sys
  input             beat,              // the kernel takes a beat now (one clk)
  input     [159:0] tap,               // tg68k.v's dbg_jtp: the record's [177:18]
  input             arm,
  input      [31:0] limit,             // the trigger: a user fetch below this logical address
  input       [8:0] raddr,
  output reg [191:0] rdata,
  output     [63:0] status             // {beats[31:0], write pointer[8:0], trigger point[8:0], full, armed, triggered, frozen, 10'b0}
);

  reg [191:0] mem [0:511];
  reg   [8:0] wp = 0, tp = 0;
  reg         full = 0, trig = 0, frozen = 0;
  reg   [5:0] left = 0;
  reg  [13:0] t = 0;
  reg  [31:0] n = 0;

  // the tap's fields (dbg_jtp): busstate [159:158], FC [157:155], logical [152:121]
  wire        u_fetch = tap[159:158] == 2'b00 && tap[157:155] == 3'd2 && tap[152:121] < limit;
  wire        we      = arm && beat && !frozen;

  always @(posedge clk) begin
    t <= t + 1'd1;
    if (we) mem[wp] <= {t, tap, 18'd0};
    rdata <= mem[raddr];
    if (!arm) begin
      wp <= 0; tp <= 0; full <= 0; trig <= 0; frozen <= 0; left <= 0; n <= 0;
    end else if (we) begin
      wp <= wp + 1'd1;
      if (&wp) full <= 1'b1;
      n <= n + 1'd1;
      if (!trig && u_fetch) begin trig <= 1'b1; tp <= wp; left <= POST; end
      else if (trig) begin if (left == 0) frozen <= 1'b1; else left <= left - 1'd1; end
    end
  end

  assign status = {n, wp, tp, full, arm, trig, frozen, 10'b0};

endmodule
