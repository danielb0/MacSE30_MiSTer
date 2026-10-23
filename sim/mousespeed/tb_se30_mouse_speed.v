// tb_se30_mouse_speed.v - se30_mouse_speed (rtl/se30_adb_dev.v), the OSD's
// "Mouse speed".
//
// WHAT THIS PROVES
//   1. speed 0: every packet out equals the packet in, bit for bit, one
//      out for each in
//   2. speeds 1-3, 4,000 random packets each (counts -255..255, a third of
//      them small, random buttons and overflow bits): each packet's count
//      is floor((count + remainder) / divisor); after every packet the
//      counts out times the divisor plus the stage's remainder equal the
//      counts in (the carried remainder included) - nothing lost, nothing
//      invented; the remainder in 0..divisor-1; buttons and overflow bits
//      pass; one packet out for each in
//   3. slow movement: +1 on X and -1 on Y a packet each move one count in
//      every divisor packets - eight steps in 8 x divisor packets (the -1
//      steps first, the +1 last: rounding toward minus infinity)
//   4. a speed change mid-stream: the old remainder is taken modulo the
//      new divisor
//   5. sanity: the bench's own checks, applied to two wrong stages modelled
//      here on the same packets - one dropping the remainder, one
//      truncating toward zero - must find them wrong (3's step count and
//      2's floor check)

`timescale 1ns/1ps
module tb;
  reg clk = 0; always #5 clk = ~clk;
  reg  [1:0] speed = 0;
  reg [24:0] pin = 0;
  wire [24:0] pout;
  se30_mouse_speed dut (.clk(clk), .speed(speed), .ps2_in(pin), .ps2_out(pout));

  integer fails = 0, checks = 0;
  task check(input cond, input [8*80-1:0] what);
    begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end end
  endtask

  integer seed = 1;
  integer d, n, k, packets_out, cx, cy, ox, oy;
  integer tin_x, tin_y, tout_x, tout_y, rem_x, rem_y;
  integer bad_q, bad_inv, bad_rng, bad_btn, moves, movesy, first;
  integer drop_moves, trunc_bad, drop_acc;
  reg strobe = 0;

  task send(input integer x, input integer y, input [2:0] btn, input [1:0] ovf);
    begin
      @(negedge clk);
      strobe = ~strobe;
      pin = {strobe, y[7:0], x[7:0], ovf, y[8], x[8], 1'b1, btn};
      @(posedge clk); #1; @(posedge clk); #1;
      ox = $signed({pout[4], pout[15:8]}); oy = $signed({pout[5], pout[23:16]});
      if (pout[24] == strobe) packets_out = packets_out + 1;
    end
  endtask

  function integer floordiv(input integer a, input integer b);
    floordiv = (a >= 0) ? a / b : -((-a + b - 1) / b);
  endfunction

  initial begin
    // ---- 1. speed 0
    speed = 0; packets_out = 0; bad_q = 0;
    for (k = 0; k < 2000; k = k + 1) begin
      send($random(seed) % 256, $random(seed) % 256, $random(seed), $random(seed));
      if (pout != pin) bad_q = bad_q + 1;
    end
    check(bad_q == 0, "1. speed 0: packet out = packet in");
    check(packets_out == 2000, "1. one packet out for each in");
    $display("---- 1. speed 0: %0d packets out of 2000, %0d differed", packets_out, bad_q);

    // ---- 2. speeds 1-3, random
    for (n = 1; n <= 3; n = n + 1) begin
      speed = n; d = 1 << n;
      rem_x = dut.rx & (d - 1); rem_y = dut.ry & (d - 1);
      tin_x = rem_x; tin_y = rem_y; tout_x = 0; tout_y = 0;      // the carried remainder is input already in
      bad_q = 0; bad_inv = 0; bad_rng = 0; bad_btn = 0; packets_out = 0; trunc_bad = 0;
      for (k = 0; k < 4000; k = k + 1) begin
        cx = $random(seed) % 256; cy = $random(seed) % 256;          // -255..255, a PS/2 count's range
        if (k % 3 == 0) begin cx = cx % 4; cy = cy % 4; end
        send(cx, cy, $random(seed), $random(seed));
        if (ox != floordiv(cx + rem_x, d) || oy != floordiv(cy + rem_y, d)) bad_q = bad_q + 1;
        if ((cx + rem_x) / d != floordiv(cx + rem_x, d)) trunc_bad = trunc_bad + 1;   // 5: truncation would differ here
        rem_x = cx + rem_x - ox * d; rem_y = cy + rem_y - oy * d;
        tin_x = tin_x + cx; tin_y = tin_y + cy; tout_x = tout_x + ox; tout_y = tout_y + oy;
        if (tout_x * d + dut.rx != tin_x || tout_y * d + dut.ry != tin_y) bad_inv = bad_inv + 1;
        if (dut.rx >= d || dut.ry >= d) bad_rng = bad_rng + 1;
        if (pout[7:0] != {pin[7:6], pout[5:4], pin[3:0]}) bad_btn = bad_btn + 1;
      end
      check(bad_q == 0, "2. each count = floor((count + remainder) / divisor)");
      check(bad_inv == 0, "2. out x divisor + remainder = in, after every packet");
      check(bad_rng == 0, "2. the remainder in 0 .. divisor-1");
      check(bad_btn == 0, "2. buttons and overflow bits pass");
      check(packets_out == 4000, "2. one packet out for each in");
      check(trunc_bad > 0, "5. sanity: a truncating stage would fail 2's floor check");
      $display("---- 2. /%0d: in (%0d,%0d), out (%0d,%0d), remainder (%0d,%0d); errors %0d %0d %0d %0d; a truncating stage would differ on %0d packets",
               d, tin_x, tin_y, tout_x, tout_y, dut.rx, dut.ry, bad_q, bad_inv, bad_rng, bad_btn, trunc_bad);
    end

    // ---- 3. slow movement (and 5: a stage dropping the remainder)
    for (n = 1; n <= 3; n = n + 1) begin
      d = 1 << n;
      speed = 0; send(0, 0, 0, 0);
      speed = n; send(0, 0, 0, 0);                  // the remainder is the stage's own, now 0 (speed 0 stored none)
      check(dut.rx == 0 && dut.ry == 0, "3. remainder 0 to start");
      moves = 0; movesy = 0; first = -1; drop_moves = 0;
      for (k = 0; k < 8 * d; k = k + 1) begin
        send(1, -1, 0, 0);
        if (ox != 0) begin moves = moves + 1; if (first < 0) first = k; check(ox == 1, "3. an X step is +1"); end
        if (oy != 0) begin movesy = movesy + 1; check(oy == -1, "3. a Y step is -1"); end
        if (1 / d != 0) drop_moves = drop_moves + 1;          // a stage keeping no remainder: floor(1/d) = 0 always
      end
      check(moves == 8 && movesy == 8, "3. eight steps each way in 8 x divisor packets");
      check(drop_moves != 8, "5. sanity: a stage dropping the remainder would fail 3");
      $display("---- 3. /%0d: +1 X, -1 Y a packet for %0d packets: %0d X steps (the first at packet %0d), %0d Y steps (dropping the remainder: %0d)",
               d, 8 * d, moves, first, movesy, drop_moves);
    end

    // ---- 4. a speed change mid-stream
    speed = 3; send(7, 7, 0, 0);
    check(ox == 0 && dut.rx == 7, "4. /8: 7 counts leave remainder 7");
    speed = 1; send(0, 0, 0, 0);
    check(ox == 0 && dut.rx == 1, "4. /2 takes it modulo 2: remainder 1");
    send(1, 0, 0, 0);
    check(ox == 1 && dut.rx == 0, "4. and the next count steps");
    $display("---- 4. a speed change mid-stream");

    $display("==== %0s: %0d checks, %0d failed", fails ? "FAIL" : "PASS", checks, fails);
    $finish;
  end
endmodule
