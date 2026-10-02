// tb_se30_cache030.v - the MC68030's instruction cache (se30_cache030.v)
// against MC68030 UM section 6 (SE30_PLAN.md 1.16, step 1).
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

  se30_cache030 dut (
    .clk(clk), .reset_n(reset_n), .cacr(cacr), .caar(caar), .cdis(cdis),
    .la(la), .fc(fc), .i_hit(i_hit), .i_q(i_q),
    .i_fill(i_fill), .fill_la(fill_la), .fill_fc(fill_fc), .fill_data(fill_data));

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

  // ------------------------------------------------------------ the run
  integer i, t, bad_hit, bad_q, hits;
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

    if (fails == 0) $display("==== PASS: %0d checks, the instruction cache holds to UM section 6", checks);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

endmodule
