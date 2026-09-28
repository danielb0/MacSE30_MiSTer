// tb_se30_fdhd.v - the internal FDHD drive held to SE30_PLAN.md 5.12.3
// (rung 2: a disk that turns), item 2 of 5.12.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_fdhd.v is the drive of Apple's 800K ERS (669-0452-A, the
//   sheets quoted from the page images) plus the SuperDrive registers the
//   ROM reads, with a disk in it:
//
//     1. the registers with no disk, and RD at $1/$3 reading 1 (MacLC
//        F12); /WRTPRT 0 with no diskette (3.2.4.9)
//     2. a disk in: /CSTIN, /WRTPRT (every rung-2 disk is protected),
//        $F reading 1 for a double-density medium (MacLC F3)
//     3. /READY for motor-on: 600 ms (3.4.4 T1), not a CLK before
//     4. RD in data mode: an 8-FCLK low pulse at each 1 of the track
//        bitstream, one cell per 32 FCLK, the side SEL picks (3.2.4.5,
//        3.4.1.2 T4); 1 while the track buffers are not the head's
//     5. /STEP low 72 us after a step, a step while it is low not
//        counted, the destination counter, /TK0 (3.2.4.2, 3.4.3.1)
//     6. /READY after a step: at once high, low 36 ms after within a
//        speed group, 152 ms across one (3.4.3.3); the track buffers
//        gate it (5.12.5b)
//     7. each speed group's revolution in cells (74,558 / 68,476 /
//        62,237 / 55,954 / 49,790 at 32 FCLK) and 60 /TACH pulses to it
//        (2.16, 3.2.4.11)
//     8. deselection presets /DIRTN to 0 and /MOTORON high (3.2.2,
//        3.2.4.1, 3.2.4.3)
//     9. /READY high at once when the disk leaves (3.4.4 T2), 1.0 s after
//        a disk-in with the motor on (T3)
//    10. eject: the command sets the latch at $C and asks for the disk
//        out; $3 resets the latch; $7 follows $6/$7 (MacLC F4)
//
// THE BENCH
//   clk is FCLK (c16_en tied high).  The encoder is modelled: two track
//   buffers whose bit at cell a is 1 when a is a multiple of 7 (side 0)
//   or 11 (side 1), read a clock after the address, and a rebuild that
//   takes ENC_T clocks after the head's cylinder changes.  Times are the
//   ERS's in FCLK at C16M (15.6672 MHz): 72 us = 1,128; 36 ms = 564,019;
//   152 ms = 2,381,414; 600 ms = 9,400,320; 1.0 s = 15,667,200.

`timescale 1ns/1ps

module tb_se30_fdhd;

  localparam integer T_STEP = 1128;
  localparam integer T_SET  = 564019;
  localparam integer T_GRP  = 2381414;
  localparam integer T_SPIN = 9400320;
  localparam integer T_DIN  = 15667200;
  localparam integer ENC_T  = 2000;

  reg clk = 0;
  always #32 clk = ~clk;
  reg reset_n = 0;

  reg        enbl_n = 1;
  reg  [3:0] ph = 4'b0000;             // {LSTRB, CA2, CA1, CA0}
  reg        sel = 0;
  reg        disk_in = 0;
  wire       sense, eject;
  wire [6:0] cyl;
  reg  [6:0] trk_cyl = 7'h7F;
  reg        trk_valid = 0;
  wire [16:0] trk_addr;
  wire       trk_side;
  reg        trk_bit = 0;
  wire [15:0] dbg;

  se30_fdhd dut (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .enbl_n(enbl_n), .ph(ph), .sel(sel), .sense(sense),
    .disk_in(disk_in), .eject(eject),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .dbg(dbg));

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ------------------------------------------------ the encoder, modelled
  reg        enc_on = 1;               // 0 holds the rebuild off
  integer    enc_cnt = 0;
  always @(posedge clk) begin
    trk_bit <= trk_side ? (trk_addr % 11 == 0) : (trk_addr % 7 == 0);
    if (!enc_on) begin trk_valid <= 0; enc_cnt <= 0; end
    else if (trk_cyl != cyl) begin
      trk_valid <= 0;
      enc_cnt <= enc_cnt + 1;
      if (enc_cnt == ENC_T) begin trk_cyl <= cyl; trk_valid <= 1; enc_cnt <= 0; end
    end else trk_valid <= 1;
  end

  // ------------------------------------------------ the eject request
  integer ejects = 0;
  always @(posedge clk) if (eject) ejects <= ejects + 1;

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // ------------------------------------------------ the ROM's addressing
  // register number {CA1, CA0, SEL, CA2} ($4082E0EC)
  task addr(input [3:0] n);
    begin #1 ph[1] = n[3]; ph[0] = n[2]; sel = n[1]; ph[2] = n[0]; end
  endtask
  reg sns;
  task rd(input [3:0] n);
    begin addr(n); repeat (4) @(posedge clk); #1 sns = sense; end
  endtask
  // a command: CA2 its value, LSTRB high then low (3.1.2); t_cmd = the rising edge
  integer t_cmd = 0;
  task cmd(input [3:0] n);
    begin
      addr(n); repeat (2) @(posedge clk);
      #1 ph[3] = 1; t_cmd = cyc;
      repeat (4) @(posedge clk);
      #1 ph[3] = 0;
      repeat (2) @(posedge clk);
    end
  endtask
  // clocks from t_cmd until register n reads v (limit clocks)
  integer n_clk;
  task until(input [3:0] n, input v, input integer limit);
    begin
      addr(n); @(posedge clk);
      while (sense !== v && cyc - t_cmd < limit) @(posedge clk);
      n_clk = cyc - t_cmd;
    end
  endtask
  function integer near(input integer got, input integer want);
    near = (got >= want - 8) && (got <= want + 8);
  endfunction

  // falling edges of RD in data mode over `cells` cells: their count,
  // the spacing of the last two, and the width of the last pulse
  integer n_fall, gap, width;
  task watch_rd(input integer cells);
    integer last, prev, t0;
    reg s_d;
    begin
      n_fall = 0; last = -1; prev = -1; width = 0; s_d = sense;
      t0 = cyc;
      while (cyc - t0 < cells * 32) begin
        @(posedge clk); #1;
        if (s_d && !sense) begin n_fall = n_fall + 1; prev = last; last = cyc; end
        if (!s_d && sense && last >= 0) width = cyc - last;
        s_d = sense;
      end
      gap = (prev >= 0) ? last - prev : 0;
    end
  endtask

  // one revolution: the cells between two passes through cell 0, and the
  // falling edges of /TACH ($E) in them
  integer rev_cells, tach_falls;
  task revolution;
    integer t0;
    reg s_d;
    begin
      // bounded at four of the longest revolutions: a drive that never
      // turns reads 0 cells, not a hung bench
      addr(4'hE); t0 = cyc;
      @(posedge clk); while (trk_addr == 0 && cyc - t0 < 4 * 32 * 74558) @(posedge clk);
      while (trk_addr != 0 && cyc - t0 < 4 * 32 * 74558) @(posedge clk);   // entering cell 0
      t0 = cyc; tach_falls = 0; #1 s_d = sense;
      while (trk_addr == 0 && cyc - t0 < 2 * 32 * 74558) begin @(posedge clk); #1; if (s_d && !sense) tach_falls = tach_falls + 1; s_d = sense; end
      while (trk_addr != 0 && cyc - t0 < 2 * 32 * 74558) begin @(posedge clk); #1; if (s_d && !sense) tach_falls = tach_falls + 1; s_d = sense; end
      rev_cells = (trk_addr == 0 && cyc - t0 < 2 * 32 * 74558 && cyc - t0 > 32) ? (cyc - t0) / 32 : 0;
    end
  endtask

  // step to track `to` (the ROM's seek: direction, then /STEP polled high
  // between steps)
  task seek(input integer to);
    begin
      if (to > cyl) cmd(4'h0); else cmd(4'h1);
      while (cyl != to) begin cmd(4'h4); until(4'h4, 1, T_STEP + 64); end
    end
  endtask

  integer i, k, t;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. no disk
    $display("---- 1. no disk: the registers, RD reads 1");
    #1 enbl_n = 0;
    rd(4'h2); check(sns == 1, "$2 /CSTIN: 1, no disk", sns, 1);
    rd(4'h6); check(sns == 0, "$6 /WRTPRT: 0 with no diskette (3.2.4.9)", sns, 0);
    rd(4'hB); check(sns == 1, "$B /READY: 1", sns, 1);
    cmd(4'h8);
    addr(4'h1); watch_rd(40); check(n_fall == 0, "$1 RD with the motor on and no disk: 1, no pulses", n_fall, 0);
    addr(4'h3); watch_rd(40); check(n_fall == 0, "$3 RD likewise", n_fall, 0);
    cmd(4'h9);

    // ---- 2. a disk in, motor off
    $display("---- 2. a disk in, the motor off");
    #1 disk_in = 1;
    repeat (4) @(posedge clk);
    rd(4'h2); check(sns == 0, "$2 /CSTIN: 0, a disk in", sns, 0);
    rd(4'h6); check(sns == 0, "$6 /WRTPRT: 0, protected (rung 2)", sns, 0);
    rd(4'hF); check(sns == 1, "$F: 1, a double-density medium (MacLC F3)", sns, 1);
    rd(4'h8); check(sns == 1, "$8 /MOTORON: 1, off", sns, 1);
    addr(4'h1); watch_rd(40); check(n_fall == 0, "$1 RD with the motor off: 1 (MacLC F12)", n_fall, 0);
    rd(4'hB); check(sns == 1, "$B /READY: 1, the motor off", sns, 1);

    // ---- 3. motor on: /READY at 600 ms
    $display("---- 3. /READY for motor-on (3.4.4 T1)");
    cmd(4'h8);
    rd(4'h8); check(sns == 0, "$8 /MOTORON: 0, on", sns, 0);
    until(4'hB, 0, T_SPIN + 1000);
    check(near(n_clk, T_SPIN), "/READY low 600 ms after the motor-on command (clocks)", n_clk, T_SPIN);

    // ---- 4. RD in data mode
    $display("---- 4. RD: 8-FCLK pulses at the bitstream's 1s, one cell per 32 FCLK");
    addr(4'h1); watch_rd(7 * 20);
    check(n_fall >= 19 && n_fall <= 21, "$1: side 0, a pulse every 7th cell: count in 140 cells", n_fall, 20);
    check(gap == 7 * 32, "$1: the spacing, 7 cells x 32 FCLK", gap, 7 * 32);
    check(width == 8, "$1: each pulse 8 FCLK low (0.51 us, T4 0.3-0.8)", width, 8);
    addr(4'h3); watch_rd(11 * 20);
    check(gap == 11 * 32, "$3: side 1, every 11th cell", gap, 11 * 32);
    check(width == 8, "$3: 8 FCLK low", width, 8);
    #1 enc_on = 0; repeat (4) @(posedge clk);
    addr(4'h1); watch_rd(40); check(n_fall == 0, "the buffers not the head's: RD reads 1", n_fall, 0);
    rd(4'hB); check(sns == 1, "and /READY is high (5.12.5b)", sns, 1);
    #1 enc_on = 1;
    repeat (4) @(posedge clk);
    rd(4'hB); check(sns == 0, "the buffers rebuilt: /READY low again", sns, 0);

    // ---- 5. /STEP
    $display("---- 5. /STEP and the destination counter (3.2.4.2, 3.4.3.1)");
    rd(4'hA); check(sns == 0, "$A /TK0: 0 at track 0", sns, 0);
    cmd(4'h0);                                          // toward the centre
    cmd(4'h4);
    rd(4'h4); check(sns == 0, "$4 /STEP: 0 just after the step", sns, 0);
    check(cyl == 1, "the destination counter: track 1", cyl, 1);
    rd(4'hA); check(sns == 1, "$A /TK0: 1 off track 0", sns, 1);
    t = t_cmd;
    cmd(4'h4);                                          // while /STEP is still low
    check(cyl == 1, "a step while /STEP is low is not counted", cyl, 1);
    t_cmd = t; until(4'h4, 1, 4 * T_STEP);              // /STEP's time runs from the first
    check(near(n_clk, T_STEP), "$4 /STEP high 72 us after the step (clocks)", n_clk, T_STEP);
    cmd(4'h1); cmd(4'h4); until(4'h4, 1, 4 * T_STEP);
    check(cyl == 0, "outward: track 0", cyl, 0);
    cmd(4'h4); until(4'h4, 1, 4 * T_STEP);
    check(cyl == 0, "no step outward past track 0", cyl, 0);

    // ---- 6. /READY after a step
    $display("---- 6. /READY for track access (3.4.3.3)");
    until(4'hB, 0, T_GRP + 1000);
    cmd(4'h0); cmd(4'h4);
    rd(4'hB); check(sns == 1, "/READY high at once after a step", sns, 1);
    until(4'hB, 0, T_GRP + 1000);
    check(near(n_clk, T_SET), "low 36 ms after a step within a group (clocks)", n_clk, T_SET);
    seek(15); until(4'hB, 0, T_GRP + 1000);
    cmd(4'h4); check(cyl == 16, "(track 16: the next group)", cyl, 16);
    until(4'hB, 0, T_GRP + 1000);
    check(near(n_clk, T_GRP), "low 152 ms after a step across a group (clocks)", n_clk, T_GRP);
    // a step across a group, then one within the new group: the later
    // deadline (the 152 ms) holds
    cmd(4'h1); cmd(4'h4); until(4'h4, 1, 4 * T_STEP); t = t_cmd;
    cmd(4'h4); until(4'h4, 1, 4 * T_STEP);
    check(cyl == 14, "(tracks 15, then 14)", cyl, 14);
    t_cmd = t; until(4'hB, 0, T_GRP + 1000);
    check(near(n_clk, T_GRP), "a step after a group change does not shorten its 152 ms", n_clk, T_GRP);

    // ---- 7. the speed groups
    $display("---- 7. the revolution and /TACH by speed group (2.16, 3.2.4.11)");
    for (k = 0; k < 5; k = k + 1) begin
      seek(k * 16 + 3);
      revolution;
      case (k)
        0: check(rev_cells == 74558, "group 0 (394 rpm): cells a revolution", rev_cells, 74558);
        1: check(rev_cells == 68476, "group 1 (429 rpm): cells a revolution", rev_cells, 68476);
        2: check(rev_cells == 62237, "group 2 (472 rpm): cells a revolution", rev_cells, 62237);
        3: check(rev_cells == 55954, "group 3 (525 rpm): cells a revolution", rev_cells, 55954);
        4: check(rev_cells == 49790, "group 4 (590 rpm): cells a revolution", rev_cells, 49790);
      endcase
      check(tach_falls == 60, "  /TACH: 60 pulses to the revolution", tach_falls, 60);
    end
    check(cyl == 67, "(track 67)", cyl, 67);
    seek(79); cmd(4'h0); cmd(4'h4); until(4'h4, 1, 4 * T_STEP);
    check(cyl == 79, "no step inward past track 79", cyl, 79);

    // ---- 8. deselection
    $display("---- 8. deselection presets the latches (3.2.2)");
    cmd(4'h1); rd(4'h0); check(sns == 1, "$0 /DIRTN: 1, outward, as set", sns, 1);
    #1 enbl_n = 1; repeat (8) @(posedge clk);
    rd(4'h0); check(sns == 1, "deselected: the line reads 1", sns, 1);
    #1 enbl_n = 0;
    rd(4'h0); check(sns == 0, "/DIRTN preset to 0 by the deselection", sns, 0);
    rd(4'h8); check(sns == 1, "/MOTORON preset high: the motor off", sns, 1);
    rd(4'hB); check(sns == 1, "/READY high: the motor off", sns, 1);
    cmd(4'h8); until(4'hB, 0, T_SPIN + 1000);
    check(near(n_clk, T_SPIN), "the motor on again: 600 ms to /READY", n_clk, T_SPIN);

    // ---- 9. the disk leaves and returns
    $display("---- 9. /READY for disk-out and disk-in (3.4.4 T2, T3)");
    #1 disk_in = 0; repeat (2) @(posedge clk);
    rd(4'hB); check(sns == 1, "the disk out: /READY high at once", sns, 1);
    rd(4'h2); check(sns == 1, "$2 /CSTIN: 1", sns, 1);
    repeat (100) @(posedge clk);
    #1 disk_in = 1; t_cmd = cyc;
    until(4'hB, 0, T_DIN + 1000);
    check(near(n_clk, T_DIN), "a disk in with the motor on: 1.0 s to /READY", n_clk, T_DIN);

    // ---- 10. eject and the SuperDrive's registers
    $display("---- 10. eject; the SuperDrive's registers (MacLC F4)");
    rd(4'hC); check(sns == 0, "$C the eject latch: 0", sns, 0);
    k = ejects;
    cmd(4'hD);
    repeat (4) @(posedge clk);
    check(ejects == k + 1, "the eject command asks for the disk out, once", ejects - k, 1);
    rd(4'hC); check(sns == 1, "$C: 1 after the eject command", sns, 1);
    cmd(4'h3); rd(4'hC); check(sns == 0, "command $3 resets it", sns, 0);
    rd(4'h5); check(sns == 1, "$5: 1, a SuperDrive", sns, 1);
    cmd(4'h6); rd(4'h7); check(sns == 1, "command $6: $7 reads 1, MFM", sns, 1);
    cmd(4'h7); rd(4'h7); check(sns == 0, "command $7: $7 reads 0, GCR", sns, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the drive holds to plan 5.12.3", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(64.0 * 400000000); $display("==== FAIL: timeout"); $finish; end

endmodule
