// se30_cache030.v - the MC68030's on-chip instruction and data caches, as
// MC68030 UM section 6 describes them (SE30_PLAN.md 1.16: step 1 the
// instruction cache, 1.16.1; step 2 the data cache, 1.16.2).  Ours;
// upstream's TG68K_Cache_030.vhd is not used (it fills 16-byte lines,
// bursts the SE/30 never does, and leaves WA unimplemented).
//
// THE INSTRUCTION CACHE
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
// THE DATA CACHE
//   The same shape; the tag is A31-A8 and FC2-FC0, so user and supervisor
//   data are different entries.  Write-through (UM 6.1.2, 6.1.2.1, 6.3.1.1,
//   6.3.1.5):
//   - a read the wrapper finds hitting is answered from `d_q`, no cycle;
//   - a cachable read cycle (RMC reads included: they are forced to miss)
//     brings its long to `d_fill`: a matching valid entry is updated, frozen
//     or not; otherwise, unfrozen, the entry is filled and validated, the
//     tag replaced and the other three entries invalidated if it differed;
//   - a cachable write, at the start of its cycle (`d_wr`, the bytes
//     `d_wbe` of the long, byte 0 = D31-D24): a hit writes those bytes,
//     frozen or not.  A miss with WA set and FD clear: an aligned long
//     (`d_wlong`) is written and validated, the tag replaced and the other
//     three invalidated if it differed; any other write clears the entry's
//     valid bit, writes nothing and leaves the tag.  A miss otherwise
//     changes nothing ("if the data cache is disabled or frozen, the WA bit
//     is ignored");
//   - `d_inv` (a write the MMU faulted) clears a matching entry;
//   - CD (CACR bit 11) clears every entry, CED (bit 10) CAAR's, whatever ED
//     and FD say; reset clears.  ED with CDIS* negated enables it, and
//     disabled it neither hits nor changes.
//   Uncachable accesses (the MMU's CI, CPU space, the walker) are the
//   wrapper's to keep away.
//
// THE STORAGE
//   Tags and valid bits are registers, so a hit is known in the clock the
//   wrapper takes the request; the 64 entries of each cache are a block RAM
//   read every clock at the requested entry, so `q` follows the address by
//   one clock.  The data RAM has byte enables (a fill writes all four).

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
  input      [31:0] fill_data,

  // the data cache: the lookup is `la`/`fc` above
  output            d_hit,             // a data read here hits
  output reg [31:0] d_q,               // the entry at last clock's address
  input             d_fill,            // a cachable read cycle's long (`fill_la`, `fill_fc`, `fill_data`)
  input             d_wr,              // a cachable write starting, at `la`/`fc`
  input       [3:0] d_wbe,             // its bytes of the long: [3] = D31-D24 (A1-A0 = 0)
  input      [31:0] d_wdata,           // the long as a 32-bit port sees it
  input             d_wlong,           // an aligned long-word write
  input             d_inv              // a write the MMU faulted, at `la`/`fc`
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

  // ------------------------------------------------------------ the data cache
  wire ed = cacr[8] && !cdis;
  wire fd = cacr[9];
  wire wa = cacr[13];

  reg  [26:0] dtag [0:15];             // {A31-A8, FC2-FC0}
  reg   [3:0] dval [0:15];
  reg   [7:0] dd0 [0:63], dd1 [0:63], dd2 [0:63], dd3 [0:63];   // bytes 0-3 (D31-D24 .. D7-D0)

  wire  [1:0] ent    = la[3:2];
  wire        d_tagm = dtag[line] == {la[31:8], fc};
  wire        d_vhit = d_tagm && dval[line][ent];
  assign d_hit = ed && d_vhit;

  always @(posedge clk) d_q <= {dd0[la[7:2]], dd1[la[7:2]], dd2[la[7:2]], dd3[la[7:2]]};

  // the fill: at fill_la (the cycle's address, latched by the wrapper)
  wire  [1:0] fent   = fill_la[3:2];
  wire        f_tagm = dtag[fline] == {fill_la[31:8], fill_fc};
  wire        f_upd  = d_fill && ed && f_tagm && dval[fline][fent];      // a matching entry: updated, frozen or not
  wire        f_new  = d_fill && ed && !fd && !(f_tagm && dval[fline][fent]);
  // the write: at la, as the cycle starts
  wire        w_hit  = d_wr && ed && d_vhit;
  wire        w_alloc = d_wr && ed && !d_vhit && wa && !fd && d_wlong;
  wire        w_clear = d_wr && ed && !d_vhit && wa && !fd && !d_wlong;

  // one data RAM write port: a fill and a write are never in one clock
  // (a fill ends one cycle, a write starts another)
  wire        dw_any  = f_upd || f_new || w_hit || w_alloc;
  wire  [5:0] dw_a    = (f_upd || f_new) ? fill_la[7:2] : la[7:2];
  wire  [3:0] dw_be   = (f_upd || f_new || w_alloc) ? 4'b1111 : d_wbe;
  wire [31:0] dw_d    = (f_upd || f_new) ? fill_data : d_wdata;
  always @(posedge clk) if (dw_any) begin
    if (dw_be[3]) dd0[dw_a] <= dw_d[31:24];
    if (dw_be[2]) dd1[dw_a] <= dw_d[23:16];
    if (dw_be[1]) dd2[dw_a] <= dw_d[15:8];
    if (dw_be[0]) dd3[dw_a] <= dw_d[7:0];
  end

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      for (n = 0; n < 16; n = n + 1) begin dval[n] <= 4'b0; dtag[n] <= 27'd0; end
    end else begin
      if (f_new) begin
        if (!f_tagm) begin
          dtag[fline] <= {fill_la[31:8], fill_fc};
          dval[fline] <= 4'b0001 << fent;
        end else
          dval[fline][fent] <= 1'b1;
      end
      if (w_alloc) begin
        if (!d_tagm) begin
          dtag[line] <= {la[31:8], fc};
          dval[line] <= 4'b0001 << ent;
        end else
          dval[line][ent] <= 1'b1;
      end
      if (w_clear) dval[line][ent] <= 1'b0;
      if (d_inv && ed && d_tagm) dval[line][ent] <= 1'b0;
      // the clears win
      if (cacr[10]) dval[caar[7:4]][caar[3:2]] <= 1'b0;
      if (cacr[11]) for (n = 0; n < 16; n = n + 1) dval[n] <= 4'b0;
    end

endmodule
