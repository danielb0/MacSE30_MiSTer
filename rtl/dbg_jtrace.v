// dbg_jtrace.v - JTRACE, the jump-to-low-memory trace (SE30_PLAN.md KNOWN
// ISSUES 22, 2026-10-16).  Plain Verilog: dbg_probes.sv puts it on JTAG
// (PJTD, PJTC), sim/predec_fault runs it as it is.
//
// WHAT IT ANSWERS
//   On the board (compiles 71, 73, 74) A/UX processes return from a syscall
//   and their next RTS loads PC 0: the return address reads 0 by a clean
//   bus beat from the physical frame the translation gave (compile 74's
//   first trace), while the core file shows the right word there.  Which
//   translation the RTS used - an ATC entry or a walk, and what the tables
//   said - and whether the kernel wrote that word.
//
// THE RING
//   2048 x 192 in block RAM, wrapping.  Two inputs: every beat the kernel
//   takes, and the PMMU's events (tg68k.v's dbg_jte: walker descriptor
//   cycles, PFLUSH as issued).  With the filter on (allbeats low, as at
//   configuration) it keeps only what bears on a user translation: beats in
//   user space (FC 1, 2 - the kernel's MOVES included), the beats of a PMMU
//   instruction (opcode $F0xx: CRP loads), walker cycles for a user access,
//   and every PFLUSH; allbeats keeps everything.  A beat on an event's clock
//   is written the clock after.  The trigger: a user program fetch (FC 2)
//   from a logical address below `limit`; the ring then takes POST more
//   records and freezes.  Arm low clears it.
//   Record [191:0]:
//     [191:178] time (clk_sys, wrapping)       [177:176] kind: 00 fetch, 10 read, 11 write, 01 event
//     [175:173] FC (an event: 0 walker read, 1 walker write, 2 PFLUSH)
//     [172:171] SIZ
//     [170:139] logical address (walker: the descriptor's address; PFLUSH: its EA)
//     [138:107] physical address (an event: the kernel's parked logical access)
//     [106:75]  the data the kernel took or drove (walker: the descriptor)
//     [74:67]   {beat_valid, force-released, cache or DIB hit, data-cache hit,
//               write-only zero, posted write, PMMU fault live, bus error}
//               (walker: [74:72] the parked access's FC; PFLUSH: [74:66]
//               MODE, MASK, FC)
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
  input             ev,                // a PMMU event now (one clk)
  input     [159:0] etap,              // tg68k.v's dbg_jte: the event's record
  input             arm,
  input             allbeats,          // the filter off
  input      [31:0] limit,             // the trigger: a user fetch below this logical address (bit 31: a supervisor one)
  input      [10:0] raddr,
  output reg [191:0] rdata,
  output     [63:0] status             // {records[31:0], write pointer[10:0], trigger row[10:0], full, armed, triggered, frozen, 6'b0}
);

  reg [191:0] mem [0:2047];
  reg  [10:0] wp = 0, tp = 0;
  reg         full = 0, trig = 0, frozen = 0;
  reg   [5:0] left = 0;
  reg  [13:0] t = 0;
  reg  [31:0] n = 0;
  reg         held = 0, held_t = 0;    // a beat that came on an event's clock, and whether it triggers
  reg [173:0] held_r = 0;

  // the beat's fields (the record less 18): FC [157:155], logical [152:121], opcode [47:32]
  wire        b_user  = tap[157:155] == 3'd1 || tap[157:155] == 3'd2;
  wire        b_mmu   = tap[47:40] == 8'hF0;
  wire        b_keep  = beat && (allbeats || b_user || b_mmu);
  // limit[31] set (KNOWN ISSUES 28): a SUPERVISOR program fetch (FC 6) below
  // limit[30:0] instead - user code run in supervisor mode under A/UX
  // limit[31:30] = 01 (MacX on the IIcx, 2026-10-18): a SUPERVISOR data read
  // (FC 5) of the logical address limit[29:0] - an exception's vector fetch,
  // e.g. $10 for vector 4 (illegal) with A/UX's VBR at 0
  wire        u_fetch = limit[31:30] == 2'b01 ?
                          (tap[159:158] == 2'b10 && tap[157:155] == 3'd5 && tap[152:121] == {2'b00, limit[29:0]}) :
                        tap[159:158] == 2'b00 &&
                        (limit[31] ? (tap[157:155] == 3'd6 && tap[152:121] < {1'b0, limit[30:0]})
                                   : (tap[157:155] == 3'd2 && tap[152:121] < limit));
  // the event's: FC field 0/1 walker, 2 PFLUSH; a walk's parked access FC [56:54]
  wire        e_user  = etap[56:54] == 3'd1 || etap[56:54] == 3'd2;
  wire        e_keep  = ev && (allbeats || etap[157:155] == 3'd2 || e_user);

  // one write a clock: the event, else a held beat, else the beat
  wire        we      = arm && !frozen && (e_keep || held || b_keep);
  wire [173:0] wrec   = e_keep ? {t, etap} : held ? held_r : {t, tap};
  wire        w_trig  = !e_keep && (held ? held_t : u_fetch);

  always @(posedge clk) begin
    t <= t + 1'd1;
    if (we) mem[wp] <= {wrec, 18'd0};
    rdata <= mem[raddr];
    if (!arm) begin
      wp <= 0; tp <= 0; full <= 0; trig <= 0; frozen <= 0; left <= 0; n <= 0; held <= 0;
    end else begin
      // the beat not written this clock waits for the next
      if ((e_keep || held) && b_keep) begin held <= 1'b1; held_r <= {t, tap}; held_t <= u_fetch; end
      else if (!e_keep) held <= 1'b0;
      if (we) begin
        wp <= wp + 1'd1;
        if (&wp) full <= 1'b1;
        n <= n + 1'd1;
        if (!trig && w_trig) begin trig <= 1'b1; tp <= wp; left <= POST; end
        else if (trig) begin if (left == 0) frozen <= 1'b1; else left <= left - 1'd1; end
      end
    end
  end

  assign status = {n, wp, tp, full, arm, trig, frozen, 6'b0};

endmodule
