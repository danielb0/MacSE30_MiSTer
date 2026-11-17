// vid_watch.v - beside tb_iici_machine (a second top): the CPU's share of
// RAM bank A while the RBV fetches the screen at each depth (SE30_PLAN.md
// "256 COLOURS").  The program in the ROM's place sets the depth and then
// counts in a loop of RAM writes; this counts its bus cycles in each 100 us
// and reports any stretch with none.
`timescale 1ns/1ps
module vid_watch;
  parameter integer STOP_NS = 4000000;
  wire clk  = tb_iici_machine.clk_sys;
  wire as_n = tb_iici_machine.machine.cpu_as_n;
  reg  as_q = 1;
  integer k, top, holes, overw = 0;
  integer cyc = 0, slot = 0, n = 0, worst = 1000000, stuck = 0, vb = 0, first_dead = -1;
  always @(posedge clk) begin
    as_q <= as_n;
    if (as_q && !as_n) cyc = cyc + 1;
    if (tb_iici_machine.machine.cpu.phi1 && tb_iici_machine.machine.cpu.xc_hit) cyc = cyc + 1;   // a cycle the cache card answered: never on the bus
    if (tb_iici_machine.machine.mdu.v_req) vb = vb + 1;
    // a request held behind a posted write's acknowledge (m_hold) must go out before the next cycle's is held
    if (tb_iici_machine.machine.mdu.mem_start && tb_iici_machine.machine.mdu.blocked && tb_iici_machine.machine.mdu.m_hold) begin
      overw = overw + 1;
      if (overw <= 4) $display("      %0t: a held request (%s %06x) overwritten by the next cycle's (%s %08x)", $time,
        tb_iici_machine.machine.mdu.q_we ? "write" : "read", tb_iici_machine.machine.mdu.q_addr,
        tb_iici_machine.machine.cpu_rw_n ? "read" : "write", tb_iici_machine.machine.cpu_addr);
    end
  end
  // the pace (tg68k.v): the largest budget and credits an instruction reached.  p_cnt saturates at 511,
  // so a budget above that is never due and the decode beat is withheld for ever
  integer bmax = 0, rmax = 0, wmax = 0, fmax = 0, xmax = 0, over = 0, hand = 0;
  reg [15:0] bop = 0; reg [31:0] bpc = 0, hq = 0;
  always @(posedge clk) if (tb_iici_machine.machine.cpu.phi1) begin
    if (tb_iici_machine.machine.cpu.p_budget > bmax) begin
      bmax = tb_iici_machine.machine.cpu.p_budget;
      rmax = tb_iici_machine.machine.cpu.p_rcred; wmax = tb_iici_machine.machine.cpu.p_wcred;
      fmax = tb_iici_machine.machine.cpu.p_fcred; xmax = tb_iici_machine.machine.cpu.p_xcred;
      bop = tb_iici_machine.machine.cpu.p_op; bpc = tb_iici_machine.machine.cpu.p_pc;
    end
    if (tb_iici_machine.machine.cpu.k_opcode_pc == 32'h00020000 && hq != 32'h00020000) hand = hand + 1;   // CACHE=5: the trace handler entered
    hq = tb_iici_machine.machine.cpu.k_opcode_pc;
    if (tb_iici_machine.machine.cpu.p_budget > 511) begin
      over = over + 1;
      if (over == 1) $display("      %0t: a budget of %0d clocks (op %04x at %08x; credits r %0d w %0d f %0d x %0d)", $time,
        tb_iici_machine.machine.cpu.p_budget, tb_iici_machine.machine.cpu.p_op, tb_iici_machine.machine.cpu.p_pc,
        tb_iici_machine.machine.cpu.p_rcred, tb_iici_machine.machine.cpu.p_wcred, tb_iici_machine.machine.cpu.p_fcred, tb_iici_machine.machine.cpu.p_xcred);
    end
  end
  // +OVER: at 2 ms the credits are set to their ceilings, as a long run of held cycles and exceptions
  // without a release leaves them - a budget of 765 clocks and more, which the 511-clock count never
  // reaches.  The CPU must carry on (the count's ceiling is due)
  initial if ($test$plusargs("OVER")) begin
    #2000000;
    force tb_iici_machine.machine.cpu.p_rcred = 8'hFF; force tb_iici_machine.machine.cpu.p_wcred = 8'hFF;
    force tb_iici_machine.machine.cpu.p_fcred = 8'hFF;
    #100;
    release tb_iici_machine.machine.cpu.p_rcred; release tb_iici_machine.machine.cpu.p_wcred;
    release tb_iici_machine.machine.cpu.p_fcred;
  end
  // the RBV's FIFO: the fewest and the most longs held while the picture is shown (its own count, clk's side)
  integer fmin = 99, fmaxh = 0;
  always @(posedge clk) begin
    if (tb_iici_machine.machine.rbv.vb_sync[2] == 0 && !tb_iici_machine.machine.rbv.hold && slot >= 14 && tb_iici_machine.machine.rbv.cnt_c < fmin) fmin = tb_iici_machine.machine.rbv.cnt_c;
    if (!tb_iici_machine.machine.rbv.hold && tb_iici_machine.machine.rbv.cnt_c > fmaxh) fmaxh = tb_iici_machine.machine.rbv.cnt_c;
  end
  // each burst: the clocks from the RBV's request to its first long, and the longs held then
  integer lat = 0, latmax = 0, latmin = 999, lat_m = 0, lat_mmax = 0, lvl_at = 99, nover = 0; reg bq = 0, first = 0, wait_m = 0;
  always @(posedge clk) begin
    bq <= tb_iici_machine.machine.rbv.busy;
    if (tb_iici_machine.machine.rbv.busy && !bq) begin lat = 0; first = 1; wait_m = 1; end
    if (wait_m && tb_iici_machine.machine.mdu.v_req) begin wait_m = 0; lat_m = lat; end           // the MDU's burst starts
    else if (tb_iici_machine.machine.rbv.busy) lat = lat + 1;
    if (first && tb_iici_machine.machine.rbv.vid_ld && tb_iici_machine.machine.rbv.busy) begin
      first = 0;
      if (slot >= 14 && !tb_iici_machine.machine.rbv.vb_sync[2]) begin
        if (lat > latmax) begin latmax = lat; lat_mmax = lat_m; end
        if (lat < latmin) latmin = lat;
        if (tb_iici_machine.machine.rbv.cnt_c < lvl_at) begin
          lvl_at = tb_iici_machine.machine.rbv.cnt_c;
          $display("      %0t: a burst's first long after %0d clk, %0d longs held", $time, lat, lvl_at);
        end
      end
    end
    if (!tb_iici_machine.machine.rbv.hold && tb_iici_machine.machine.rbv.cnt_c > 16) begin
      nover = nover + 1;
      if (nover <= 3) $display("      %0t: %0d longs held (wp %0d rp_c %0d busy %b got %0d vblank %b)", $time, tb_iici_machine.machine.rbv.cnt_c,
        tb_iici_machine.machine.rbv.wp, tb_iici_machine.machine.rbv.rp_c, tb_iici_machine.machine.rbv.busy, tb_iici_machine.machine.rbv.got, tb_iici_machine.machine.rbv.vb_sync[2]);
    end
  end
  // THE CACHE CARD (tg68k.v): a hit is two clocks and never on the bus; a miss puts AS* out four CPU
  // clocks late; the counts
  integer xh = 0, xm = 0, xbus = 0, xlat = 0, xlmin = 999, xlmax = 0, xgap = 0, xgmin = 999, xseq = 0, xram = 0;
  reg     xwait = 0, xafter = 0; integer xa = 0;
  always @(posedge clk) begin
    if (xgap < 9999) xgap = xgap + 1;
    if (xafter) begin
      xa = xa + 1;
      if (!as_n) xbus = xbus + 1;                                  // a hit's cycle seen on the bus
      if (xa == 1 && tb_iici_machine.machine.cpu.s != 3'd5) xseq = xseq + 1;
      if (xa == 2 && tb_iici_machine.machine.cpu.s != 3'd0) xseq = xseq + 1;
      if (xa == 3) xafter = 0;
    end
    if (xwait) begin
      xlat = xlat + 1;
      if (!as_n) begin xwait = 0; if (xlat < xlmin) xlmin = xlat; if (xlat > xlmax) xlmax = xlat; end
    end
    if (tb_iici_machine.machine.cpu.phi1 && tb_iici_machine.machine.cpu.xc_hit) begin
      xh = xh + 1; xafter = 1; xa = 0;
      if (xgap < xgmin) xgmin = xgap;
      xgap = 0;
    end
    if (tb_iici_machine.machine.cpu.phi1 && tb_iici_machine.machine.cpu.xc_miss) begin xm = xm + 1; xwait = 1; xlat = 0; end
    // the card's decisions on RAM reads (its tag's ROM bit clear): none when the MMU marks RAM cache-inhibited (CACHE=9)
    if (tb_iici_machine.machine.cpu.phi1 && (tb_iici_machine.machine.cpu.xc_hit || tb_iici_machine.machine.cpu.xc_miss) && !tb_iici_machine.machine.cpu.xc_tagr[12]) xram = xram + 1;
  end
  // +XON: the card enabled from the start, for the programs that do not write the RBV
  initial if ($test$plusargs("XON")) force tb_iici_machine.machine.cenable_n = 1'b0;
  // the bus cycles into bank A while the picture is shown: how long AS* is low (clk, two a CPU clock), and
  // the clk from one cycle's end to the next one's start
  integer awn = 0, awsum = 0, awmax = 0, arn = 0, arsum = 0, armax = 0, alow = 0, wh [0:63], ih;
  reg     awr = 0, abank = 0;
  initial for (ih = 0; ih < 64; ih = ih + 1) wh[ih] = 0;
  always @(posedge clk) begin
    if (!as_n) begin
      if (as_q) begin alow = 0; awr = !tb_iici_machine.machine.cpu_rw_n; abank = (tb_iici_machine.machine.cpu_addr[31:26] == 6'd0); end
      alow = alow + 1;
    end else if (!as_q && abank && slot >= 16 && !tb_iici_machine.machine.rbv.vb_sync[2]) begin
      if (awr) begin awn = awn + 1; awsum = awsum + alow; if (alow > awmax) awmax = alow; wh[(alow > 63) ? 63 : alow] = wh[(alow > 63) ? 63 : alow] + 1; end
      else begin arn = arn + 1; arsum = arsum + alow; if (alow > armax) armax = alow; end
    end
  end
  // the video against a waiting CPU cycle: bursts begun while a bank-A cycle waits, and how many of
  // those cycles had already waited out the burst before (the video twice in a row over the same cycle)
  integer vover = 0, vtwice = 0, vthrice = 0, vall = 0, awaitn = 0;
  always @(posedge clk) begin
    if (as_n) awaitn = 0;
    if (tb_iici_machine.machine.mdu.v_req && slot >= 16) begin
      vall = vall + 1;
      if (!as_n && tb_iici_machine.machine.cpu_addr[31:26] == 6'd0 && tb_iici_machine.machine.mdu.held) begin
        vover = vover + 1; awaitn = awaitn + 1;
        if (awaitn == 2) vtwice = vtwice + 1;
        if (awaitn == 3) vthrice = vthrice + 1;
      end
    end
  end
  // +TRACE: the bus and the video, CPU clock by CPU clock, for a stretch of live video
  //   A = AS* low, w = a write, h = held by the MDU, V = a burst starts, v = the burst's hold, p = a burst pending,
  //   r = the RBV asks
  reg [8*400-1:0] tl; integer tn = 0; reg ton = 0;
  always @(posedge clk) if (ton && tb_iici_machine.machine.cpu.p_release)
    $write("\n[release: op %04x ran %0d clocks, budget %0d; credits r %0d w %0d f %0d x %0d, tail %0d]\n",
      tb_iici_machine.machine.cpu.p_op, tb_iici_machine.machine.cpu.p_cnt, tb_iici_machine.machine.cpu.p_budget,
      tb_iici_machine.machine.cpu.p_rcred, tb_iici_machine.machine.cpu.p_wcred, tb_iici_machine.machine.cpu.p_fcred,
      tb_iici_machine.machine.cpu.p_xcred, tb_iici_machine.machine.cpu.p_tail);
  initial if ($test$plusargs("TRACE")) begin #2000000; ton = 1; end
  always @(posedge clk) if (ton && tb_iici_machine.machine.cpu.phi2) begin
    $write("%s", !as_n ? (tb_iici_machine.machine.mdu.held ? "h" : (!tb_iici_machine.machine.cpu_rw_n ? "w" : "A")) : ".");
    $write("%s", tb_iici_machine.machine.mdu.v_req ? "V" : (tb_iici_machine.machine.mdu.v_hold != 0) ? "v" : tb_iici_machine.machine.mdu.v_pend ? "p" : tb_iici_machine.machine.rbv.vid_req ? "r" : " ");
    tn = tn + 1;
    if (tn % 60 == 0) $write("\n");
    if (tn == 720) begin ton = 0; $write("\n"); end
  end
  initial forever begin
    #100000;
    if (slot >= 14) begin                       // past vertical blanking: the screen is being fetched
      if (cyc < worst) worst = cyc;
      if (cyc == 0) begin stuck = stuck + 1; if (first_dead < 0) first_dead = slot; end
    end
    if (slot % 4 == 0 || cyc == 0) $display("      %0d.%0d ms: %0d CPU bus cycles, %0d video bursts, vblank %b", slot / 10, slot % 10, cyc, vb, tb_iici_machine.machine.rbv.vblank);
    cyc = 0; vb = 0; slot = slot + 1;
  end
  initial begin
    #(STOP_NS);
    $display("---- depth %0d: the fewest CPU bus cycles in 100 us of active video: %0d; %0d slots with none (first at %0d)",
             tb_iici_machine.machine.rbv.monp[1:0], worst, stuck, first_dead);
    // CACHE=2 (the grey fill): every long below the fill's front holds the pattern - a posted write that
    // never reached the memory leaves the model's power-up value there
    if (tb_iici_machine.ram_a[0] === 32'hAAAAAAAA || tb_iici_machine.ram_a[0] === 32'h55555555) begin
      top = -1; holes = 0;
      for (k = 0; k < 65536; k = k + 1)
        if (tb_iici_machine.ram_a[k] === 32'hAAAAAAAA || tb_iici_machine.ram_a[k] === 32'h55555555) top = k;
      for (k = 0; k < top; k = k + 1)
        if (!(tb_iici_machine.ram_a[k] === 32'hAAAAAAAA || tb_iici_machine.ram_a[k] === 32'h55555555)) begin
          holes = holes + 1; if (holes <= 6) $display("      long %0d ($%05x) was never written: %08x", k, k * 4, tb_iici_machine.ram_a[k]);
        end
      $display("---- the fill reached long %0d; %0d longs below it were never written", top, holes);
      if (holes != 0) stuck = stuck + 1;
    end
    $display("---- the pace's largest budget: %0d clocks (op %04x at %08x; credits r %0d w %0d f %0d x %0d); %0d clocks with a budget over 511; the handler at $20000 entered %0d times", bmax, bop, bpc, rmax, wmax, fmax, xmax, over, hand);
    if (over != 0 && !$test$plusargs("OVER")) stuck = stuck + 1;
    $display("---- the RBV's FIFO ran dry on %0d pixels; it held %0d to %0d longs; a burst's first long came %0d to %0d clk after the request (the longest: %0d of them before the MDU began), with as few as %0d held", tb_iici_machine.machine.rbv.dbg_underflow, fmin, fmaxh, latmin, latmax, lat_mmax, lvl_at);
    if (fmaxh > 17) stuck = stuck + 1;   // (17: the read pointer is seen two clk late)
    if (tb_iici_machine.machine.rbv.dbg_underflow != 0) stuck = stuck + 1;
    if (tb_iici_machine.XCARD != 0) begin
      $display("---- the cache card: %0d hits, %0d misses; hits %0d clk apart at the closest (4 = two CPU clocks); a miss's AS* %0d to %0d clk after its P1 (9 = four CPU clocks late); %0d hits seen on the bus, %0d out of sequence",
               xh, xm, xgmin, xlmin, xlmax, xbus, xseq);
      $display("---- the card's program: D6 (passes) %0d, D7 (differences) %0d", tb_iici_machine.machine.cpu.dbg_d6, tb_iici_machine.machine.cpu.dbg_d7);
      $display("---- the card's decisions on RAM reads: %0d%s", xram, $test$plusargs("CICHK") ? " (CIOUT on all of RAM: must be 0)" : "");
      if ($test$plusargs("CICHK") && xram != 0) stuck = stuck + 1;
      // (a program that never reads the bus - the grey fill from the instruction cache - gives the card nothing)
      if (xbus != 0 || xseq != 0 || xgmin < 4 || (xm != 0 && (xlmin != xlmax || xlmin != 9))) stuck = stuck + 1;
      if (tb_iici_machine.machine.cpu.dbg_d6 != 0 && (xh == 0 || xm == 0)) stuck = stuck + 1;
      if (tb_iici_machine.machine.cpu.dbg_d7 != 0) stuck = stuck + 1;
    end
    if (awn != 0) begin
      $display("---- bank A writes in live video: %0d, AS* low %0d clk on average, %0d at most (6 = a four-clock write); reads: %0d, %0d on average, %0d at most (8 = five clocks)",
               awn, awsum / awn, awmax, arn, (arn != 0) ? arsum / arn : 0, armax);
      $write("      writes by AS* low, clk:");
      for (ih = 0; ih < 64; ih = ih + 1) if (wh[ih] != 0) $write(" %0d:%0d", ih, wh[ih]);
      $display("");
    end
    $display("---- video bursts: %0d; begun over a waiting bank-A cycle: %0d; over one that had already waited out a burst: %0d (three in a row: %0d)", vall, vover, vtwice, vthrice);
    $display("---- held requests overwritten before they went out: %0d", overw);
    if (overw != 0) stuck = stuck + 1;
    if (stuck == 0 && worst > 20) $display("==== VID PASS: the CPU keeps running beside the video's bursts");
    else $display("==== VID FAIL: the CPU was starved");
    $finish;
  end
endmodule
