// se30_cache030.v - the MC68030's 256-byte instruction and data caches (UM section 6): direct
// mapped, 16 lines of four longs with a valid bit each, logical tags; single-entry fills (the
// board has no burst), the data cache write-through with WA.

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
