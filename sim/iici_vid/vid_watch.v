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
    $display("---- held requests overwritten before they went out: %0d", overw);
    if (overw != 0) stuck = stuck + 1;
    if (stuck == 0 && worst > 20) $display("==== VID PASS: the CPU keeps running beside the video's bursts");
    else $display("==== VID FAIL: the CPU was starved");
    $finish;
  end
endmodule
