// tb_se30_cache030.v - the MC68030's instruction and data caches
// (se30_cache030.v) against MC68030 UM section 6 (SE30_PLAN.md 1.16: step 1
// the instruction cache, step 2 the data cache, 1.16.2).
//
// WHAT THIS PROVES
//   Directed, each case a rule of the manual:
//     1. reset: nothing hits (6.2)
//     2. a fill, then the same fetch hits and its long comes a clock later
//     3. the tag is the logical address and FC2: user and supervisor fetches
//        of one address are different entries (6.1.1)
//     4. the four entries of a line are valid independently (6.1)
//     5. a fill with a new tag replaces the line's tag and invalidates its
//        other three entries
//     6. EI clear: no hit, no fill; set again: the entries are still there
//        (6.3.1.11)
//     7. CDIS*: no hit, no fill, whatever CACR says (6.1)
//     8. FI: hits still hit, a miss does not fill (6.3.1.10)
//     9. CI (CACR bit 3) clears every entry (6.3.1.8)
//    10. CEI (bit 2) clears only the entry CAAR names, enabled or not,
//        frozen or not (6.3.1.9)
//   Random: 200,000 clocks of fills, fetches and CACR changes against a
//   reference model of the same rules - every lookup's hit and every hit's
//   long.
//
//   The data cache, directed (UM 6.1.2, 6.1.2.1, 6.1.2.2, 6.3.1.1-6):
//    D1. reset: nothing hits
//    D2. a fill, then a hit with its long a clock later
//    D3. FC2-FC0 are all in the tag: user and supervisor data differ
//    D4. a write hit writes only its bytes, frozen too
//    D5. WA clear: a write miss changes nothing
//    D6. WA set, an aligned long write, tag miss: the tag replaced, only its
//        entry valid, with the long (Figure 6-4 example 4)
//    D7. WA set, an aligned long write, tag match, entry invalid: validated,
//        the others kept (example 3)
//    D8. WA set, a byte, word or misaligned write that misses: the entry's
//        valid bit cleared, nothing written, the tag unaltered (example 5)
//    D9. FD: a write miss allocates nothing even with WA, a read miss does
//        not fill, a write hit still updates
//   D10. a fill over a matching valid entry (the RMC read's case) updates
//        it, frozen too
//   D11. CD clears every entry, CED only CAAR's, enabled or not
//   D12. ED clear: no hit, no fill, no write update - the old entries hit
//        again, stale, when ED is set (UM 6.3.1.6)
//   D13. a write the MMU faulted clears its matching entry
//   D14. CDIS*: no data hits either
//   Random: 200,000 clocks of data fills, writes of every size and offset,
//   faults and CACR changes against a reference model - every lookup's hit
//   and every hit's long.

`timescale 1ns/1ps

module tb_se30_cache030;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;

  reg  [13:0] cacr = 0;
  reg   [7:2] caar = 0;
  reg         cdis = 0;
  reg  [31:2] la = 0;
  reg   [2:0] fc = 3'd6;
  wire        i_hit;
  wire [31:0] i_q;
  reg         i_fill = 0;
  reg  [31:2] fill_la = 0;
  reg   [2:0] fill_fc = 0;
  reg  [31:0] fill_data = 0;
  wire        d_hit;
  wire [31:0] d_q;
  reg         d_fill = 0, d_wr = 0, d_wlong = 0, d_inv = 0;
  reg   [3:0] d_wbe = 0;
  reg  [31:0] d_wdata = 0;

  se30_cache030 dut (
    .clk(clk), .reset_n(reset_n), .cacr(cacr), .caar(caar), .cdis(cdis),
    .la(la), .fc(fc), .i_hit(i_hit), .i_q(i_q),
    .i_fill(i_fill), .fill_la(fill_la), .fill_fc(fill_fc), .fill_data(fill_data),
    .d_hit(d_hit), .d_q(d_q), .d_fill(d_fill), .d_wr(d_wr), .d_wbe(d_wbe), .d_wdata(d_wdata),
    .d_wlong(d_wlong), .d_inv(d_inv));

  integer fails = 0, checks = 0;
  task check(input cond, input [8*80-1:0] what);
    begin
      checks = checks + 1;
      if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end
    end
  endtask

  // one fill, held a clock
  task fill(input [31:2] a, input [2:0] f, input [31:0] d);
    begin
      @(negedge clk); fill_la = a; fill_fc = f; fill_data = d; i_fill = 1;
      @(negedge clk); i_fill = 0;
    end
  endtask
  // a lookup: hit now, and the long a clock later
  reg        l_hit;
  reg [31:0] l_q;
  task look(input [31:2] a, input [2:0] f);
    begin
      @(negedge clk); la = a; fc = f;
      #1 l_hit = i_hit;
      @(negedge clk); l_q = i_q;
    end
  endtask

  // ------------------------------------------------------------ the reference
  reg  [24:0] rtag [0:15];
  reg   [3:0] rval [0:15];
  reg  [31:0] rdat [0:63];
  integer k;
  task ref_reset; begin for (k = 0; k < 16; k = k + 1) begin rval[k] = 0; rtag[k] = 0; end end endtask
  function ref_hit(input [31:2] a, input [2:0] f);
    ref_hit = cacr[0] && !cdis && rval[a[7:4]][a[3:2]] && rtag[a[7:4]] == {a[31:8], f[2]};
  endfunction
  task ref_clock;                        // what the clock's fill and clears do
    begin
      if (i_fill && cacr[0] && !cdis && !cacr[1]) begin
        rdat[fill_la[7:2]] = fill_data;
        if (rtag[fill_la[7:4]] != {fill_la[31:8], fill_fc[2]}) begin
          rtag[fill_la[7:4]] = {fill_la[31:8], fill_fc[2]};
          rval[fill_la[7:4]] = 4'b0001 << fill_la[3:2];
        end else rval[fill_la[7:4]][fill_la[3:2]] = 1'b1;
      end
      if (cacr[2]) rval[caar[7:4]][caar[3:2]] = 1'b0;
      if (cacr[3]) for (k = 0; k < 16; k = k + 1) rval[k] = 0;
    end
  endtask

  // ------------------------------------------------------- the data half
  task dfill(input [31:2] a, input [2:0] f, input [31:0] d);
    begin
      @(negedge clk); fill_la = a; fill_fc = f; fill_data = d; d_fill = 1;
      @(negedge clk); d_fill = 0;
    end
  endtask
  // a write of `n` bytes at byte `off` of the long at `a`: the bytes on the
  // lanes a 32-bit port takes them from
  reg [3:0] wm;
  task dwrite(input [31:2] a, input [1:0] off, input [2:0] n, input [2:0] f, input [31:0] d);
    begin
      wm = (n == 1) ? 4'b1000 : (n == 2) ? 4'b1100 : (n == 3) ? 4'b1110 : 4'b1111;
      @(negedge clk); la = a; fc = f; d_wbe = wm >> off; d_wdata = d; d_wlong = (n == 4) && (off == 0); d_wr = 1;
      @(negedge clk); d_wr = 0;
    end
  endtask
  reg        dl_hit;
  reg [31:0] dl_q;
  task dlook(input [31:2] a, input [2:0] f);
    begin
      @(negedge clk); la = a; fc = f;
      #1 dl_hit = d_hit;
      @(negedge clk); dl_q = d_q;
    end
  endtask
  task cacr_pulse(input [13:0] pulse, input [13:0] after);
    begin @(negedge clk); cacr = pulse; @(negedge clk); cacr = after; end
  endtask

  reg  [26:0] dtag_r [0:15];
  reg   [3:0] dval_r [0:15];
  reg  [31:0] ddat_r [0:63];
  function dref_hit(input [31:2] a, input [2:0] f);
    dref_hit = cacr[8] && !cdis && dval_r[a[7:4]][a[3:2]] && dtag_r[a[7:4]] == {a[31:8], f};
  endfunction
  integer bb;
  reg tm, vv;
  task dref_clock;
    begin
      if (cacr[8] && !cdis) begin
        if (d_fill) begin
          tm = dtag_r[fill_la[7:4]] == {fill_la[31:8], fill_fc}; vv = dval_r[fill_la[7:4]][fill_la[3:2]];
          if (tm && vv) ddat_r[fill_la[7:2]] = fill_data;
          else if (!cacr[9]) begin
            ddat_r[fill_la[7:2]] = fill_data;
            if (!tm) begin dtag_r[fill_la[7:4]] = {fill_la[31:8], fill_fc}; dval_r[fill_la[7:4]] = 4'b0001 << fill_la[3:2]; end
            else dval_r[fill_la[7:4]][fill_la[3:2]] = 1'b1;
          end
        end
        if (d_wr) begin
          tm = dtag_r[la[7:4]] == {la[31:8], fc}; vv = dval_r[la[7:4]][la[3:2]];
          if (tm && vv) begin
            for (bb = 0; bb < 4; bb = bb + 1) if (d_wbe[3-bb]) ddat_r[la[7:2]][31-8*bb -: 8] = d_wdata[31-8*bb -: 8];
          end else if (cacr[13] && !cacr[9]) begin
            if (d_wlong) begin
              ddat_r[la[7:2]] = d_wdata;
              if (!tm) begin dtag_r[la[7:4]] = {la[31:8], fc}; dval_r[la[7:4]] = 4'b0001 << la[3:2]; end
              else dval_r[la[7:4]][la[3:2]] = 1'b1;
            end else dval_r[la[7:4]][la[3:2]] = 1'b0;
          end
        end
        if (d_inv && dtag_r[la[7:4]] == {la[31:8], fc}) dval_r[la[7:4]][la[3:2]] = 1'b0;
      end
      if (cacr[10]) dval_r[caar[7:4]][caar[3:2]] = 1'b0;
      if (cacr[11]) for (k = 0; k < 16; k = k + 1) dval_r[k] = 0;
    end
  endtask

  // ------------------------------------------------------------ the run
  integer i, t, bad_hit, bad_q, hits, r;
  reg   [1:0] roff;
  reg   [2:0] rn;
  reg  [31:2] a0;
  reg         want_hit;
  reg  [31:0] want_q;
  initial begin
    repeat (3) @(posedge clk); reset_n = 1;

    // 1. reset
    cacr = 14'h0001;
    look(30'h1000, 3'd6); check(!l_hit, "1. after reset nothing hits");

    // 2. a fill, then a hit with its long a clock later
    fill({24'h408000, 4'h3, 2'd1}, 3'd6, 32'hCAFEF00D);
    look({24'h408000, 4'h3, 2'd1}, 3'd6);
    check(l_hit, "2. the filled entry hits");
    check(l_q == 32'hCAFEF00D, "2. its long comes a clock later");

    // 3. FC2: supervisor and user are different
    look({24'h408000, 4'h3, 2'd1}, 3'd2); check(!l_hit, "3. a user fetch misses a supervisor entry");
    look({24'h408000, 4'h3, 2'd1}, 3'd5); check(l_hit, "3. FC1-FC0 are not in the tag (FC 5 and 6 share FC2)");

    // 4. entries of a line independent
    look({24'h408000, 4'h3, 2'd2}, 3'd6); check(!l_hit, "4. the line's other entry is not valid");
    fill({24'h408000, 4'h3, 2'd2}, 3'd6, 32'h11112222);
    look({24'h408000, 4'h3, 2'd1}, 3'd6); check(l_hit && l_q == 32'hCAFEF00D, "4. the first entry still hits");
    look({24'h408000, 4'h3, 2'd2}, 3'd6); check(l_hit && l_q == 32'h11112222, "4. the second entry hits");

    // 5. a new tag replaces the line and invalidates the others
    fill({24'h408001, 4'h3, 2'd0}, 3'd6, 32'h33334444);
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(l_hit && l_q == 32'h33334444, "5. the new tag's entry hits");
    look({24'h408001, 4'h3, 2'd1}, 3'd6); check(!l_hit, "5. the new tag's other entries are not valid");
    look({24'h408000, 4'h3, 2'd1}, 3'd6); check(!l_hit, "5. the old tag's entries are gone");

    // 6. EI clear: no hit, no fill; set: the entries still there
    cacr = 14'h0000;
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(!l_hit, "6. EI clear: no hit");
    fill({24'h408001, 4'h3, 2'd3}, 3'd6, 32'h55556666);
    cacr = 14'h0001;
    look({24'h408001, 4'h3, 2'd3}, 3'd6); check(!l_hit, "6. EI clear: the fill did nothing");
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(l_hit && l_q == 32'h33334444, "6. EI set again: the old entry hits");

    // 7. CDIS*
    cdis = 1;
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(!l_hit, "7. CDIS*: no hit");
    fill({24'h408001, 4'h3, 2'd3}, 3'd6, 32'h77778888);
    cdis = 0;
    look({24'h408001, 4'h3, 2'd3}, 3'd6); check(!l_hit, "7. CDIS*: the fill did nothing");

    // 8. FI
    cacr = 14'h0003;
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(l_hit, "8. FI: a hit still hits");
    fill({24'h408001, 4'h3, 2'd3}, 3'd6, 32'h9999AAAA);
    fill({24'h408002, 4'h5, 2'd0}, 3'd6, 32'hBBBBCCCC);
    cacr = 14'h0001;
    look({24'h408001, 4'h3, 2'd3}, 3'd6); check(!l_hit, "8. FI: a miss does not fill");
    look({24'h408002, 4'h5, 2'd0}, 3'd6); check(!l_hit, "8. FI: nor replace a line");

    // 9. CI
    fill({24'h408003, 4'h7, 2'd2}, 3'd6, 32'hDDDDEEEE);
    look({24'h408003, 4'h7, 2'd2}, 3'd6); check(l_hit, "9. (filled)");
    @(negedge clk); cacr = 14'h0009; @(negedge clk); cacr = 14'h0001;
    look({24'h408003, 4'h7, 2'd2}, 3'd6); check(!l_hit, "9. CI clears every entry");
    look({24'h408001, 4'h3, 2'd0}, 3'd6); check(!l_hit, "9. CI: the other line too");

    // 10. CEI: one entry, enabled or not
    fill({24'h408004, 4'h9, 2'd0}, 3'd6, 32'h01010101);
    fill({24'h408004, 4'h9, 2'd1}, 3'd6, 32'h02020202);
    caar = {4'h9, 2'd1};
    @(negedge clk); cacr = 14'h0006; @(negedge clk); cacr = 14'h0001;      // CEI, frozen
    look({24'h408004, 4'h9, 2'd1}, 3'd6); check(!l_hit, "10. CEI clears the entry CAAR names (frozen)");
    look({24'h408004, 4'h9, 2'd0}, 3'd6); check(l_hit && l_q == 32'h01010101, "10. CEI: only that entry");
    caar = {4'h9, 2'd0};
    @(negedge clk); cacr = 14'h0004; @(negedge clk); cacr = 14'h0001;      // CEI, disabled
    look({24'h408004, 4'h9, 2'd0}, 3'd6); check(!l_hit, "10. CEI clears with the cache disabled too");

    // random against the reference
    @(negedge clk); cacr = 14'h0009; @(negedge clk); cacr = 14'h0001;      // clear
    ref_reset;
    bad_hit = 0; bad_q = 0; hits = 0;
    want_hit = 0; want_q = 0;
    for (t = 0; t < 200000; t = t + 1) begin
      @(negedge clk);
      // last clock's lookup: the long arrives now
      if (want_hit && i_q !== want_q) bad_q = bad_q + 1;
      // this clock's inputs: a small address space so lines collide
      la[31:12] = 20'h40800; la[11:10] = $random; la[7:4] = $random; la[3:2] = $random;
      la[9:8] = 0;
      fc = ($random & 1) ? 3'd6 : 3'd2;
      i_fill = ($random % 3) == 0;
      fill_la = la; fill_la[11:10] = $random; fill_la[7:2] = $random;
      fill_fc = ($random & 1) ? 3'd6 : 3'd2;
      fill_data = $random;
      cdis = ($random % 50) == 0;
      cacr = 14'h0001 | ((($random % 40) == 0) ? 14'h0002 : 0) | ((($random % 200) == 0) ? 14'h0008 : 0)
             | ((($random % 100) == 0) ? 14'h0004 : 0);
      if (($random % 60) == 0) cacr[0] = 0;
      caar = $random;
      #1;
      want_hit = ref_hit(la, fc);
      if (i_hit !== want_hit) bad_hit = bad_hit + 1;
      if (want_hit) begin want_q = rdat[la[7:2]]; hits = hits + 1; end
      @(posedge clk); #1 ref_clock;
    end
    @(negedge clk);
    check(bad_hit == 0, "random: every lookup's hit as the reference's");
    check(bad_q == 0, "random: every hit's long as the reference's");
    $display("random: 200000 clocks, %0d hits, %0d hit mismatches, %0d data mismatches", hits, bad_hit, bad_q);

    // ======================================================== the data cache
    @(negedge clk); cdis = 0; i_fill = 0;
    cacr = 14'h0100;                                                       // ED
    // D1
    dlook({24'h000400, 4'h2, 2'd0}, 3'd5); check(!dl_hit, "D1. nothing hits before a fill");
    // D2
    dfill({24'h000400, 4'h2, 2'd0}, 3'd5, 32'h11223344);
    dlook({24'h000400, 4'h2, 2'd0}, 3'd5); check(dl_hit && dl_q == 32'h11223344, "D2. a fill, then a hit with its long");
    #1 check(!i_hit, "D2. the data fill is not in the instruction cache");
    // D3
    dlook({24'h000400, 4'h2, 2'd0}, 3'd1); check(!dl_hit, "D3. user data misses a supervisor entry");
    dlook({24'h000400, 4'h2, 2'd0}, 3'd6); check(!dl_hit, "D3. FC1-FC0 are in the data tag (FC 6 misses an FC 5 entry)");
    // D4
    dwrite({24'h000400, 4'h2, 2'd0}, 2'd2, 3'd1, 3'd5, 32'hAAAAAAAA);    // a byte at offset 2
    dlook({24'h000400, 4'h2, 2'd0}, 3'd5); check(dl_hit && dl_q == 32'h1122AA44, "D4. a byte write hit writes only its byte");
    cacr = 14'h0300;                                                       // ED FD
    dwrite({24'h000400, 4'h2, 2'd0}, 2'd1, 3'd3, 3'd5, 32'h00BBCCDD);    // three bytes at offset 1
    dlook({24'h000400, 4'h2, 2'd0}, 3'd5); check(dl_hit && dl_q == 32'h11BBCCDD, "D4. a write hit updates frozen too");
    cacr = 14'h0100;
    // D5
    dwrite({24'h000400, 4'h2, 2'd1}, 2'd0, 3'd4, 3'd5, 32'h55555555);    // WA clear, entry 1 invalid
    dlook({24'h000400, 4'h2, 2'd1}, 3'd5); check(!dl_hit, "D5. WA clear: a write miss allocates nothing");
    dlook({24'h000400, 4'h2, 2'd0}, 3'd5); check(dl_hit && dl_q == 32'h11BBCCDD, "D5. and disturbs nothing");
    // D6: a tag miss, an aligned long
    cacr = 14'h2100;                                                       // ED WA
    dfill({24'h000400, 4'h3, 2'd1}, 3'd5, 32'h01010101);                  // line 3, tag $000400: entries 1, 2
    dfill({24'h000400, 4'h3, 2'd2}, 3'd5, 32'h02020202);
    dwrite({24'h000500, 4'h3, 2'd1}, 2'd0, 3'd4, 3'd5, 32'hCAFEBABE);
    dlook({24'h000500, 4'h3, 2'd1}, 3'd5); check(dl_hit && dl_q == 32'hCAFEBABE, "D6. WA: an aligned long write miss allocates");
    dlook({24'h000400, 4'h3, 2'd2}, 3'd5); check(!dl_hit, "D6. the old tag's other entries are invalidated");
    // D7: a tag match, the entry invalid, an aligned long
    dwrite({24'h000500, 4'h3, 2'd3}, 2'd0, 3'd4, 3'd5, 32'h33333333);
    dlook({24'h000500, 4'h3, 2'd3}, 3'd5); check(dl_hit && dl_q == 32'h33333333, "D7. WA: tag match, an aligned long validates its entry");
    dlook({24'h000500, 4'h3, 2'd1}, 3'd5); check(dl_hit && dl_q == 32'hCAFEBABE, "D7. the line's other entry is kept");
    // D8: a tag miss, a word write: the entry's valid bit cleared, the tag kept
    dwrite({24'h000600, 4'h3, 2'd1}, 2'd0, 3'd2, 3'd5, 32'h77777777);
    dlook({24'h000600, 4'h3, 2'd1}, 3'd5); check(!dl_hit, "D8. WA: a word write miss allocates nothing");
    dlook({24'h000500, 4'h3, 2'd1}, 3'd5); check(!dl_hit, "D8. the entry's valid bit is cleared");
    dlook({24'h000500, 4'h3, 2'd3}, 3'd5); check(dl_hit && dl_q == 32'h33333333, "D8. the tag is unaltered, the other entry kept");
    dwrite({24'h000500, 4'h3, 2'd2}, 2'd2, 3'd4, 3'd5, 32'h88888888);    // a misaligned long, entry invalid
    dlook({24'h000500, 4'h3, 2'd2}, 3'd5); check(!dl_hit, "D8. WA: a misaligned long write does not validate");
    // D9: frozen
    cacr = 14'h2300;                                                       // ED FD WA
    dwrite({24'h000700, 4'h3, 2'd0}, 2'd0, 3'd4, 3'd5, 32'h99999999);
    dlook({24'h000700, 4'h3, 2'd0}, 3'd5); check(!dl_hit, "D9. FD: WA is ignored, a write miss allocates nothing");
    dlook({24'h000500, 4'h3, 2'd3}, 3'd5); check(dl_hit, "D9. FD: the line is not replaced");
    dfill({24'h000400, 4'h4, 2'd0}, 3'd5, 32'h44444444);
    dlook({24'h000400, 4'h4, 2'd0}, 3'd5); check(!dl_hit, "D9. FD: a read miss does not fill");
    // D10: a fill over a matching valid entry updates it, frozen too
    dfill({24'h000500, 4'h3, 2'd3}, 3'd5, 32'h3A3A3A3A);
    dlook({24'h000500, 4'h3, 2'd3}, 3'd5); check(dl_hit && dl_q == 32'h3A3A3A3A, "D10. a fill over a valid matching entry updates it, frozen");
    // D11
    cacr = 14'h0100;
    dfill({24'h000400, 4'h5, 2'd0}, 3'd5, 32'h50505050);
    dfill({24'h000400, 4'h5, 2'd1}, 3'd5, 32'h51515151);
    caar = {4'h5, 2'd1};
    cacr_pulse(14'h0400, 14'h0000);                                        // CED, disabled
    cacr = 14'h0100;
    dlook({24'h000400, 4'h5, 2'd1}, 3'd5); check(!dl_hit, "D11. CED clears CAAR's entry (disabled)");
    dlook({24'h000400, 4'h5, 2'd0}, 3'd5); check(dl_hit, "D11. CED: only that entry");
    cacr_pulse(14'h0900, 14'h0100);                                        // CD
    dlook({24'h000400, 4'h5, 2'd0}, 3'd5); check(!dl_hit, "D11. CD clears every entry");
    dlook({24'h000500, 4'h3, 2'd3}, 3'd5); check(!dl_hit, "D11. CD: the other line too");
    // D12: disabled keeps the entries and does not update them
    dfill({24'h000400, 4'h6, 2'd0}, 3'd5, 32'h60606060);
    cacr = 14'h2000;                                                       // ED clear (WA set)
    dlook({24'h000400, 4'h6, 2'd0}, 3'd5); check(!dl_hit, "D12. ED clear: no hit");
    dwrite({24'h000400, 4'h6, 2'd0}, 2'd0, 3'd4, 3'd5, 32'h61616161);
    dfill({24'h000400, 4'h6, 2'd1}, 3'd5, 32'h62626262);
    cacr = 14'h0100;
    dlook({24'h000400, 4'h6, 2'd0}, 3'd5); check(dl_hit && dl_q == 32'h60606060, "D12. ED set again: the old entry hits, stale");
    dlook({24'h000400, 4'h6, 2'd1}, 3'd5); check(!dl_hit, "D12. nothing was filled while disabled");
    // D13
    @(negedge clk); la = {24'h000400, 4'h6, 2'd0}; fc = 3'd5; d_inv = 1; @(negedge clk); d_inv = 0;
    dlook({24'h000400, 4'h6, 2'd0}, 3'd5); check(!dl_hit, "D13. a faulted write clears its entry");
    // D14
    dfill({24'h000400, 4'h7, 2'd0}, 3'd5, 32'h70707070);
    cdis = 1;
    dlook({24'h000400, 4'h7, 2'd0}, 3'd5); check(!dl_hit, "D14. CDIS*: no data hit");
    cdis = 0;
    dlook({24'h000400, 4'h7, 2'd0}, 3'd5); check(dl_hit, "D14. CDIS* negated: it hits again");

    // random against the reference
    cacr_pulse(14'h0900, 14'h0100);
    for (k = 0; k < 16; k = k + 1) begin dval_r[k] = 0; dtag_r[k] = 0; end
    bad_hit = 0; bad_q = 0; hits = 0; want_hit = 0;
    for (t = 0; t < 200000; t = t + 1) begin
      @(negedge clk);
      if (want_hit && d_q !== want_q) bad_q = bad_q + 1;
      la[31:12] = 20'h00010; la[11:10] = $random; la[9:8] = 0; la[7:4] = $random; la[3:2] = $random;
      fc = ($random & 1) ? 3'd5 : 3'd1;
      d_fill = 0; d_wr = 0; d_inv = 0;
      r = {$random} % 8;
      if (r < 2) begin
        d_fill = 1; fill_la = la; fill_la[11:10] = $random; fill_la[7:2] = $random;
        fill_fc = ($random & 1) ? 3'd5 : 3'd1; fill_data = $random;
      end else if (r < 5) begin
        roff = $random; rn = 1 + ({$random} % 4);
        wm = (rn == 1) ? 4'b1000 : (rn == 2) ? 4'b1100 : (rn == 3) ? 4'b1110 : 4'b1111;
        d_wr = 1; d_wbe = wm >> roff; d_wdata = $random; d_wlong = (rn == 4) && (roff == 0);
      end else if (r == 5) d_inv = ({$random} % 4) == 0;
      cdis = ({$random} % 50) == 0;
      cacr = 14'h0100 | ((({$random} % 30) == 0) ? 14'h0200 : 14'h0) | ((({$random} % 2) == 0) ? 14'h2000 : 14'h0)
             | ((({$random} % 300) == 0) ? 14'h0800 : 14'h0) | ((({$random} % 100) == 0) ? 14'h0400 : 14'h0);
      if (({$random} % 60) == 0) cacr[8] = 0;
      caar = $random;
      #1;
      want_hit = dref_hit(la, fc);
      if (d_hit !== want_hit) bad_hit = bad_hit + 1;
      if (want_hit) begin want_q = ddat_r[la[7:2]]; hits = hits + 1; end
      @(posedge clk); #1 dref_clock;
    end
    @(negedge clk); d_fill = 0; d_wr = 0; d_inv = 0;
    check(bad_hit == 0, "D random: every lookup's hit as the reference's");
    check(bad_q == 0, "D random: every hit's long as the reference's");
    $display("D random: 200000 clocks, %0d hits, %0d hit mismatches, %0d data mismatches", hits, bad_hit, bad_q);

    if (fails == 0) $display("==== PASS: %0d checks, the instruction and data caches hold to UM section 6", checks);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

endmodule
