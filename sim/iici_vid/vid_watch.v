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
    $display("---- held requests overwritten before they went out: %0d", overw);
    if (overw != 0) stuck = stuck + 1;
    if (stuck == 0 && worst > 20) $display("==== VID PASS: the CPU keeps running beside the video's bursts");
    else $display("==== VID FAIL: the CPU was starved");
    $finish;
  end
endmodule
