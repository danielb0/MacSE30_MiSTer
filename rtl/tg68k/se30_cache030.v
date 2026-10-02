// se30_cache030.v - the MC68030's on-chip instruction cache, as MC68030 UM
// section 6 describes it (SE30_PLAN.md 1.16, step 1; the data cache is step
// 2).  Ours; upstream's TG68K_Cache_030.vhd is not used (it fills 16-byte
// lines, bursts the SE/30 never does).
//
// WHAT IT IS
//   256 bytes, direct-mapped: 16 lines of four long-word entries, each
//   entry with its own valid bit, replaced on its own (UM 6.1, 6.1.1).
//   Index A7-A4, entry A3-A2.  The tag is the LOGICAL address A31-A8 and
//   FC2 (user or supervisor).
//
//   A fetch hits when the cache is enabled (CACR EI), CDIS* is negated, and
//   the line's tag matches with the entry valid - the MMU and its CI are
//   not consulted (UM 6.1: "the MMU is completely ignored").  The wrapper
//   then answers the kernel from `q` a clock later and runs no bus cycle.
//
//   A miss runs the bus cycle; when it was cachable (EI, CDIS* negated, the
//   MMU's CI clear, not CPU space) and the cache is not frozen (FI), the
//   long the cycle brought fills the entry (`fill`): single-entry mode, the
//   only mode on the SE/30 (CBACK* is pulled up and goes nowhere, plan
//   2.11.1) - one long word per miss, which a 32-bit port brings in one
//   cycle.  A new tag replaces the line's and invalidates its other three
//   entries.
//
//   CACR's CI (bit 3) clears every valid bit, CEI (bit 2) the entry CAAR
//   bits 7-2 name, whatever EI and FI say (UM 6.3.1.8-9); the kernel holds
//   those bits until it has consumed them, so a clear may last more than a
//   clock - it is idempotent.  Reset clears every valid bit (UM 6.2); CACR's
//   enables are the kernel's.  Disabling the cache keeps its entries.
//
// THE DATA
//   Tags and valid bits are registers, so a hit is known in the clock the
//   wrapper takes the request; the 64 entries are a block RAM read every
//   clock at the requested entry, so `q` follows the address by one clock.

`timescale 1ns/1ps

module se30_cache030 (
  input             clk,
  input             reset_n,

  input      [13:0] cacr,              // the kernel's CACR (EI 0, FI 1, CEI 2, CI 3, IBE 4; data 8-13)
  input       [7:2] caar,              // CAAR's index field, for CEI
  input             cdis,              // CDIS* asserted: both caches disabled

  // the lookup: the kernel's current request
  input      [31:2] la,                // its logical address
  input       [2:0] fc,
  output            i_hit,             // a fetch here hits
  output reg [31:0] i_q,               // the entry at last clock's address

  // the fill: a cachable fetch cycle's long
  input             i_fill,
  input      [31:2] fill_la,
  input       [2:0] fill_fc,
  input      [31:0] fill_data
);

  wire ei = cacr[0] && !cdis;
  wire fi = cacr[1];

  reg  [24:0] itag [0:15];             // {A31-A8, FC2}
  reg   [3:0] ival [0:15];
  reg  [31:0] idat [0:63];

  wire  [3:0] line = la[7:4];
  assign i_hit = ei && ival[line][la[3:2]] && itag[line] == {la[31:8], fc[2]};

  always @(posedge clk) i_q <= idat[la[7:2]];

  // fills: only when enabled, not frozen; the wrapper checks CI and FC
  wire  [3:0] fline = fill_la[7:4];
  wire        fdo   = i_fill && ei && !fi;
  always @(posedge clk) if (fdo) idat[fill_la[7:2]] <= fill_data;

  integer n;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      for (n = 0; n < 16; n = n + 1) begin ival[n] <= 4'b0; itag[n] <= 25'd0; end
    end else begin
      if (fdo) begin
        if (itag[fline] != {fill_la[31:8], fill_fc[2]}) begin
          itag[fline] <= {fill_la[31:8], fill_fc[2]};
          ival[fline] <= 4'b0001 << fill_la[3:2];
        end else
          ival[fline][fill_la[3:2]] <= 1'b1;
      end
      // the clears win over a fill in the same clock
      if (cacr[2]) ival[caar[7:4]][caar[3:2]] <= 1'b0;
      if (cacr[3]) for (n = 0; n < 16; n = n + 1) ival[n] <= 4'b0;
    end

endmodule
