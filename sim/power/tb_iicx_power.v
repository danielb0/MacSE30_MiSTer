// tb_iicx_power.v - the IIcx's soft power (rtl/iicx_power.v; SE30_PLAN.md
// 14.2 item 9).
//
// WHAT THIS PROVES
//   1. /POWEROFF held low while the machine runs: off 2 ms later (62,669
//      clk_sys clocks + the clock that acts), and off stays
//   2. the Power key brings the machine back; the OSD's reset does too
//   3. a /POWEROFF shorter than 2 ms does nothing, nor one while held in reset
//   4. the rear switch locked on: a restart pulse of one clock, never off

`timescale 1ns/1ps

module tb_iicx_power;
  reg clk = 0;
  always #15.957 clk = ~clk;              // clk_sys, 31.3344 MHz
  reg running = 1, poweroff_req = 0, locked = 0, power_key = 0, reset_req = 0;
  wire off, restart;
  iicx_power uut (.clk(clk), .running(running), .poweroff_req(poweroff_req), .locked(locked),
                  .power_key(power_key), .reset_req(reset_req), .off(off), .restart(restart));

  integer checks = 0, fails = 0;
  task check(input cond, input [8*72-1:0] what, input integer got);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d", what, got); end
    end
  endtask
  task pulse_key; begin @(posedge clk); #1 power_key = 1; @(posedge clk); #1 power_key = 0; end endtask
  task pulse_reset; begin @(posedge clk); #1 reset_req = 1; @(posedge clk); #1 reset_req = 0; end endtask

  integer n, restarts;
  always @(posedge clk) if (restart) restarts = restarts + 1;

  initial begin
    restarts = 0;
    repeat (4) @(posedge clk);
    // 1.
    #1 poweroff_req = 1; n = 0;
    while (!off && n < 100000) begin @(posedge clk); #1; n = n + 1; end
    check(n == 62670, "1 off this many clocks after /POWEROFF (2 ms)", n);
    #1 poweroff_req = 0; running = 0;                  // off: the top holds the machine
    repeat (1000) @(posedge clk);
    check(off == 1, "1 off stays", off);
    // 2.
    pulse_key; @(posedge clk); #1;
    check(off == 0, "2 the Power key brings it back", off);
    running = 1; poweroff_req = 1;
    while (!off) @(posedge clk);
    #1 poweroff_req = 0; running = 0;
    pulse_reset; @(posedge clk); #1;
    check(off == 0, "2 the OSD's reset brings it back", off);
    running = 1;
    // 3.
    poweroff_req = 1; repeat (31334) @(posedge clk); #1 poweroff_req = 0;   // 1 ms
    repeat (100000) @(posedge clk);
    check(off == 0 && restarts == 0, "3 a 1 ms /POWEROFF does nothing", off);
    running = 0; poweroff_req = 1; repeat (100000) @(posedge clk); #1 poweroff_req = 0; running = 1;
    check(off == 0 && restarts == 0, "3 nor one while held in reset", off);
    // 4.
    locked = 1; poweroff_req = 1; n = 0;
    while (restarts == 0 && n < 100000) begin @(posedge clk); #1; n = n + 1; end
    check(restarts == 1 && off == 0, "4 locked on: a restart, not off", restarts);
    @(posedge clk); #1;
    check(restart == 0, "4 the restart is one clock", restart);
    #1 poweroff_req = 0;

    if (fails == 0) $display("==== PASS: %0d checks, the IIcx's soft power", checks);
    else $display("==== FAIL: %0d of %0d checks failed", fails, checks);
    $finish;
  end
endmodule
