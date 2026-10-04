// tb_se30_sdram.v - the SDRAM controller against a behavioural chip, held
// to GLUE's contract and to the datasheets (SE30_PLAN.md 3.2, 3.3, 3.6
// item 2, 3.8 item 18).
//
// WHAT THIS PROVES
//   rtl/se30_sdram.v, on a 94.0032 MHz clock phase-locked to the 31.3344 MHz
//   clk_sys, driving sim/sdram/sdram_model.v (our model of the W9825G6KH-6 /
//   AS4C32M16SB-7, which checks every datasheet interval and the power-up
//   sequence):
//
//     0. the read-capture training (plan 3.8 item 18): `ready` waits for
//        it; it wrote the pair to the top two words; it chose the capture
//        the pin delays call for - run.sh runs this bench at four delay
//        settings, where both captures work (A chosen), only B, only A,
//        and neither (cap_ok 00, A) - and the first CPU read of the top
//        longword returns the pair through the capture chosen
//     1. power-up: the ladder is accepted by the model and `ready` follows
//     2. a read or a write started at S0 (cpu_start) and confirmed at S1
//        (cpu_req) is acknowledged with its data at GLUE's sampling edge
//        two C16M after S0 - the 68030's one-wait-state cycle, plan 2.11's
//        row 1 - for every address pattern (all four banks, row edges, the
//        top of the 32 MB) and back to back
//     3. byte enables: a write touches only its lanes (Table 7-7's patterns)
//     4. an aborted start (no request): a read's data is discarded and the
//        next cycle is intact; a write never reaches the array
//     5. a late request (GLUE's refresh window, four C16M): the read's data
//        is still right, the write still lands
//     6. the download port: words land as written and read back as
//        longwords, including while CPU cycles run
//     7. refresh: the model sees one AUTO REFRESH inside every 7.8125 us,
//        and it never costs a CPU cycle a wait state - a 100 us run of
//        back-to-back cycles is acknowledged at two C16M throughout
//     8. the raw experiment port (plan 3.8 item 19): its schedule reaches
//        the chip as written - against the model, which masks as the
//        datasheet says, a masked later beat stays unwritten in burst-
//        write mode and is written when unmasked, the two-WRITE form
//        lands both words, and the LOAD MODE round trip (A9 0 and back)
//        leaves the CPU port as it was
//     9. an abandoned read (a start with no request), then 20 us of
//        nothing: refresh goes on (plan 3.8 item 20: the done state used
//        to starve it), and a read shaped as the JTAG peek's - a start
//        for one clk_sys, the request the next, sampled every clk_sys -
//        returns its own data, not the abandoned read's
//    10. raw READs: unmasked, the longword; with DQM on the READ's clock
//        and the next, blanked beats (the mask on the output, two clocks
//        later) - the masked-read test of the chip's DQM inputs
//    11. the model reports no datasheet violation anywhere in the run
//    12. the disk port (plan 5.12.5): words written land and read back
//        as the CPU's longwords, words read (even and odd) are the CPU's;
//        alongside back-to-back CPU cycles it makes progress and no CPU
//        cycle is late (it waits for the window after a start); on an
//        idle bus it runs freely, and a CPU stream that starts into it
//        loses at most one wait state, on its first cycle only
//
// HOW IT DRIVES THE DUT
//   As the wrapper and GLUE do (plan 3.2's timeline): the address, R/W,
//   byte enables and write data appear at the S0 edge with cpu_start high
//   for that clk_sys; cpu_req rises at S1 (AS*) and stays until the
//   acknowledge is sampled, which GLUE does at its C16M edges from two
//   clocks after S0; it then drops the request (mem_done) and the cycle
//   ends two C16M later.  "ack at N" is the C16M edge, counted from S0, at
//   which the acknowledge was first seen: 2 is the contract.
//
// THE PIN DELAYS (parameters; iverilog -P tb_se30_sdram.NAME=x)
//   CLK_TO_PIN  the chip's clock reaches its pin this long after the
//               fabric's edge (the second compile's STA, 2026-09-27: -3.97
//               ns of clock skew on the read-data paths).  4.0.
//   OUT_TO_PIN  our command, address, mask and write-data registers reach
//               the chip this long after our edge, through the same kind
//               of I/O cell as the clock.  4.0.  Before item 18 the bench
//               had no output delay, which bounded CLK_TO_PIN at 5.3 (the
//               chip sampled the next command); now the chip's view of the
//               commands is fixed and only the read data moves.
//   DQ_TO_REG   the chip's data reaches the capture register this long
//               after its pin (the same STA: 2.35 ns of data delay).  2.0.
//   The model drives data with the datasheet's tAC and tOH and X between,
//   so a capture outside the eye reads X and the training must reject it.
//   Where each capture's edge falls in that eye, in the default setting:
//   A (0.266 ns before clk_mem's edge) 3.2 ns in with 4.5 to spare, B
//   (2.261 before) 1.2 in with 6.5 to spare - both pass, A chosen.  run.sh's other settings
//   move the eye until one or both captures fall out of it.  None of this
//   is the hardware's timing (STA at every corner is; MacSE30.sdc and
//   scripts/sta_corners.tcl); it is the training's logic under test.

`timescale 1ns/1ps

module tb_se30_sdram;

  // ------------------------------------------------------------ clocks
  // all from one time base: 5.319 ns half-periods, 3:1, and the two
  // phase-shifted copies of clk_mem the PLL makes (rtl/pll.v)
  reg clk_mem = 0;
  always #5.319 clk_mem = ~clk_mem;
  reg clk_sys = 0;
  always #15.957 clk_sys = ~clk_sys;
  // transport delays (an assign's delay is inertial and would swallow a
  // 5.3 ns pulse behind a delay longer than that)
  reg clk_sdc = 0, clk_capa = 0, clk_capb = 0;
  always @(clk_mem) begin
    clk_sdc  <= #(1.064)  clk_mem;
    clk_capa <= #(10.372) clk_mem;                     // 0.266 ns before the next clk_mem edge
    clk_capb <= #(8.377)  clk_mem;                     // 2.261 ns before
  end
  reg phi = 0;
  always @(posedge clk_sys) phi <= ~phi;
  wire phi1 = !phi;                                // the clk_sys in which C16M rises: S0, S2, S4 begin here
  reg reset_n = 0;

  parameter  real CLK_TO_PIN = 4.0;
  parameter  real OUT_TO_PIN = 4.0;
  parameter  real DQ_TO_REG  = 2.0;
  parameter       EXPECT_OK  = 2'b11;               // the training's expected {A, B} verdict for these delays
  parameter       EXPECT_SEL = 0;                   // and its expected choice, 0 = A
  parameter       TRAIN_ONLY = 0;                   // 1: stop after the training checks

  // --------------------------------------------------------------- DUT
  reg         cpu_start = 0, cpu_req = 0, cpu_we = 0;
  reg  [22:0] cpu_addr = 0;
  reg   [3:0] cpu_be = 4'hF;
  reg  [31:0] cpu_wdata = 0;
  wire [31:0] cpu_rdata;
  wire        cpu_ack, ready, cap_sel;
  wire  [1:0] cap_ok;
  wire [13:0] cap_fail_a, cap_fail_b;
  reg         dl_req = 0;
  reg  [23:0] dl_addr = 0;
  reg  [15:0] dl_data = 0;
  wire        dl_ack;
  reg         raw_req = 0;
  reg  [63:0] raw_ctl = 0;
  reg  [23:0] raw_addr = 0;
  wire        raw_ack;
  reg         dk_req = 0, dk_we = 0;
  reg  [23:0] dk_addr = 0;
  reg  [15:0] dk_wdata = 0;
  wire [15:0] dk_rdata;
  wire        dk_ack;

  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;                               // the DUT's side of the data pins

  se30_sdram #(.TR_READS_LOG2(5)) dut (                 // 32 reads per capture here; 65,536 on the board
    .clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(reset_n),
    .ready(ready), .cap_sel(cap_sel), .cap_ok(cap_ok), .cap_fail_a(cap_fail_a), .cap_fail_b(cap_fail_b),
    .cpu_start(cpu_start), .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_be(cpu_be), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
    .dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
    .raw_req(raw_req), .raw_ctl(raw_ctl), .raw_addr(raw_addr), .raw_ack(raw_ack),
    .dbg_dqm_force(1'b0),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq),
    .sd_dqm(sd_dqm), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));

  // ------------------------------------------------ the board's delays
  // the clock and the outputs to the chip's pins; the data pins split
  // into the chip's side (dq_chip) and the DUT's (sd_dq), each direction
  // with its delay
  wire        sd_clk_chip, cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, oe_c;
  wire [12:0] addr_c;
  wire  [1:0] ba_c, dqm_c;
  wire [15:0] dq_out_c, dq_chip;
  assign #(CLK_TO_PIN) sd_clk_chip = sd_clk;
  assign #(OUT_TO_PIN) {cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, addr_c, ba_c, dqm_c} =
                       {sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_addr, sd_ba, sd_dqm};
  assign #(OUT_TO_PIN) oe_c     = dut.dq_oe;
  assign #(OUT_TO_PIN) dq_out_c = dut.dq_out;
  assign dq_chip = oe_c ? dq_out_c : 16'hzzzz;
  assign #(DQ_TO_REG) sd_dq = dut.dq_oe ? 16'hzzzz : dq_chip;

  sdram_model chip (
    .clk(sd_clk_chip), .cke(cke_c), .cs_n(cs_n_c), .ras_n(ras_n_c), .cas_n(cas_n_c), .we_n(we_n_c),
    // the chip's DQM is the A12/A11 traces, as on the MiSTer modules (the
    // controller header's THE MASK); dqm_c, the FPGA's DQM pins, reaches nothing
    .ba(ba_c), .addr(addr_c), .dqm(addr_c[12:11]), .dq(dq_chip));

  // ------------------------------------------------- bus contention
  // Plan 1.17.5 item 6: our output enable may stay on for a write's whole
  // access, so it must never overlap the chip driving read data (or its
  // tOH/tHZ tail) at the chip's pins.
  integer clashes = 0;
  always @(oe_c or chip.dq_drv)
    if (oe_c === 1'b1 && chip.dq_drv !== 16'hzzzz) begin
      clashes = clashes + 1;
      if (clashes <= 5) $display("CLASH: our DQ driver on while the chip drives, t=%0t", $time);
    end

  // ------------------------------------------------------------ scoring
  integer pass = 0, fails = 0;
  task check(input cond, input [8*96-1:0] what);
    begin
      if (cond) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0s", what); end
    end
  endtask

  // ------------------------------------------------------ the bus driver
  // ack_at: the C16M edge from S0 at which the acknowledge was first seen
  // by a GLUE sampling from edge 2; 99 = never (20 clocks).
  integer bus_cycles = 0, acks_late = 0;
  task bus_cycle(input we, input [22:0] a, input [3:0] be, input [31:0] wd,
                 input abort, input integer req_delay,
                 output [31:0] rd, output integer ack_at);
    integer e;                                      // clk_sys edges since S0
    begin
      @(posedge clk_sys); while (!phi1) @(posedge clk_sys);          // S0
      #1 cpu_addr = a; cpu_we = we; cpu_be = be; cpu_wdata = wd; cpu_start = 1;
      @(posedge clk_sys); #1 cpu_start = 0;                            // S1: AS*
      if (!abort && req_delay == 0) cpu_req = 1;
      e = 1; ack_at = 99; rd = 32'hx;
      if (abort) begin
        repeat (3) @(posedge clk_sys);                                 // the aborted cycle's length
      end else begin
        while (ack_at == 99 && e < 40) begin
          @(posedge clk_sys); e = e + 1;
          if (req_delay != 0 && e == 1 + 2 * req_delay) #1 cpu_req = 1;
          if (phi1 && e >= 4 && cpu_req && cpu_ack) begin              // GLUE's sampling edge
            ack_at = e / 2; rd = cpu_rdata;
            #1 cpu_req = 0;                                            // mem_done
          end
        end
        if (ack_at != 99) repeat (3) @(posedge clk_sys);               // S4, S5 to the next S0
        else begin #1 cpu_req = 0; end
        bus_cycles = bus_cycles + 1;
        if (ack_at != 2) acks_late = acks_late + 1;
      end
    end
  endtask
  task cpu_write(input [22:0] a, input [3:0] be, input [31:0] wd, output integer ack_at);
    reg [31:0] dummy;
    begin bus_cycle(1, a, be, wd, 0, 0, dummy, ack_at); end
  endtask
  task cpu_read(input [22:0] a, output [31:0] rd, output integer ack_at);
    begin bus_cycle(0, a, 4'hF, 32'h0, 0, 0, rd, ack_at); end
  endtask

  // the download handshake, as the shell drives it from ioctl
  task dl_word(input [23:0] a, input [15:0] d);
    begin
      @(posedge clk_sys); #1 dl_addr = a; dl_data = d; dl_req = 1;
      while (!dl_ack) @(posedge clk_sys);
      #1 dl_req = 0;
      while (dl_ack) @(posedge clk_sys);
    end
  endtask

  // a raw experiment (the controller's header): the schedule word and the
  // word address, the same level handshake as the download's
  function [63:0] raw_word(input [15:0] w0, input [15:0] w1, input [7:0] dqm, input [3:0] oe,
                           input [2:0] sel, input rd, input ap, input second, input kind, input [12:0] mode);
    raw_word = {mode, kind, second, ap, rd, sel, oe, dqm, w1, w0};
  endfunction
  // a read shaped as the JTAG peek's (MacSE30.sv): start for one clk_sys,
  // the request from the next, the acknowledge sampled every clk_sys
  task peek_read(input [22:0] a, output [31:0] rd);
    begin
      @(posedge clk_sys); #1 cpu_addr = a; cpu_we = 0; cpu_be = 4'hF; cpu_start = 1;
      @(posedge clk_sys); #1 cpu_start = 0; cpu_req = 1;
      @(posedge clk_sys); while (!cpu_ack) @(posedge clk_sys);
      rd = cpu_rdata; #1 cpu_req = 0;
      while (cpu_ack) @(posedge clk_sys);
    end
  endtask
  // what the chip was doing when each start arrived: 1 a disk word, 2 a
  // refresh (or its tRFC), 0 free - to put a late cycle to its cause
  integer start_blocker = 0;
  always @(posedge clk_mem) #0.1 if (dut.start_rise)
    start_blocker = (dut.state == 3'd7) ? 1 : (dut.busy != 0 && dut.state == 3'd1) ? 2 : 0;
  // every disk ACTIVE against the plan's rule: issued at clocks 10-15 after
  // a start, or on a bus idle 63 clocks.  Seen the edge after it issued:
  // since_start has moved on by one (11-16), stayed at 63, or been reset
  // by a start on that same edge (0)
  integer dk_issues = 0, dk_out_of_window = 0, dk_late_in_window = 0;
  always @(posedge clk_mem) #0.1 if (dut.state == 3'd7 && dut.seq == 4'd1) begin
    dk_issues = dk_issues + 1;
    if (!((dut.since_start >= 11 && dut.since_start <= 16) || dut.since_start == 63 || dut.since_start == 0))
      dk_out_of_window = dk_out_of_window + 1;
    if (dut.since_start >= 15 && dut.since_start <= 16) dk_late_in_window = dk_late_in_window + 1;
  end
  // a disk word, as the loader and the encoder drive the port: the request
  // held to the acknowledge, the next only once the acknowledge has fallen
  integer dk_ops = 0;
  task dk_op(input we, input [23:0] a, input [15:0] d, output [15:0] q);
    begin
      @(posedge clk_sys); #1 dk_addr = a; dk_we = we; dk_wdata = d; dk_req = 1;
      @(posedge clk_sys); #1;
      while (!dk_ack) begin @(posedge clk_sys); #1; end
      q = dk_rdata; dk_req = 0; dk_ops = dk_ops + 1;
      while (dk_ack) begin @(posedge clk_sys); #1; end
    end
  endtask
  task raw_op(input [63:0] ctl, input [23:0] a);
    begin
      @(posedge clk_sys); #1 raw_ctl = ctl; raw_addr = a; raw_req = 1;
      while (!raw_ack) @(posedge clk_sys);
      #1 raw_req = 0;
      while (raw_ack) @(posedge clk_sys);
    end
  endtask

  // ------------------------------------------------------ test vectors
  // 12 longword addresses: all four banks (bit 21 and 22 of the longword
  // address are the bank), a row edge (column wrap at 512 words = 256
  // longwords), the RAM top, the ROM base and the last longword of 32 MB
  // (the training's pair lives there, and is read once before this)
  reg [22:0] addrs [0:11];
  reg [31:0] vals  [0:11];
  integer n;
  initial begin
    addrs[0]  = 23'h000000; addrs[1]  = 23'h000001; addrs[2]  = 23'h0000FF; addrs[3]  = 23'h000100;
    addrs[4]  = 23'h1FFFFF; addrs[5]  = 23'h200000; addrs[6]  = 23'h20FFFF; addrs[7]  = 23'h400010;
    addrs[8]  = 23'h600010; addrs[9]  = 23'h7FFFFF; addrs[10] = 23'h001FFF; addrs[11] = 23'h002000;
    for (n = 0; n < 12; n = n + 1) vals[n] = {n[7:0], ~n[7:0], 8'hA5 ^ n[7:0], 8'h5A + n[7:0]};
  end

  // ----------------------------------------------------------- the run
  real     t_ready;
  integer  ack, k, gaps_over, acks_before, cycles_before, late_dl = 0;
  reg [31:0] rd, rd2;
  integer  dl_done = 0;
  integer  late_dk = 0, dk_done = 0, dk_bad = 0, cpu_bad = 0, ops_before, n_cpu;
  reg [15:0] q16, w_hi, w_lo;
  integer  kd, late_ref = 0;

  initial begin
    $display("---- reset, power-up and the read-capture training  (CLK_TO_PIN %0.2f  OUT_TO_PIN %0.2f  DQ_TO_REG %0.2f)",
             CLK_TO_PIN, OUT_TO_PIN, DQ_TO_REG);
    repeat (5) @(posedge clk_mem); #1 reset_n = 1;
    while (!ready) @(posedge clk_mem);
    t_ready = $realtime;
    check(t_ready > 200000.0 && t_ready < 260000.0, "ready after the 200 us pause, the ladder and the training");
    check(chip.refreshes == 8, "eight refreshes in the ladder");
    check(chip.errors == 0, "the ladder and the training are accepted by the model");
    check(chip.mem[24'hFFFFFE] == 16'hA5C3 && chip.mem[24'hFFFFFF] == 16'h5A3C, "the training wrote its pair to the top two words");
    check(cap_ok == EXPECT_OK, "the training's verdict is what these delays call for");
    check(cap_sel == EXPECT_SEL, "and its choice");
    check(clashes == 0, "our DQ driver never overlaps the chip's (the training)");
    check((cap_fail_a == 0) == cap_ok[1] && (cap_fail_b == 0) == cap_ok[0] && (cap_ok[1] || cap_fail_a == 32) && (cap_ok[0] || cap_fail_b == 32),
          "the failure counts agree with the verdict (a capture outside the eye fails every read)");
    $display("      ready at %0.1f us; the training passed A=%0d B=%0d and chose %s", t_ready / 1000.0,
             cap_ok[1], cap_ok[0], cap_sel ? "B (clk_mem - 2.261 ns)" : "A (clk_mem - 0.266 ns)");
    if (TRAIN_ONLY) begin
      if (fails == 0) $display("==== PASS: %0d checks, the training", pass);
      else $display("==== FAIL: %0d of %0d checks failed", fails, pass + fails);
      $finish;
    end
    cpu_read(23'h7FFFFF, rd, ack);
    check(rd == 32'hA5C35A3C && ack == 2, "the first CPU read returns the training's pair through the capture chosen");

    // 2. writes and reads at the contract's latency
    $display("---- longword writes and reads, all patterns");
    for (n = 0; n < 12; n = n + 1) begin
      cpu_write(addrs[n], 4'hF, vals[n], ack);
      check(ack == 2, "write acknowledged at two C16M");
    end
    for (n = 0; n < 12; n = n + 1) begin
      cpu_read(addrs[n], rd, ack);
      check(ack == 2, "read acknowledged at two C16M");
      check(rd == vals[n], "read data matches");
      if (rd !== vals[n]) $display("      addr %06x: got %08x expected %08x", addrs[n], rd, vals[n]);
    end

    // 3. byte enables
    $display("---- byte enables");
    cpu_write(addrs[3], 4'b1000, 32'h11223344, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == {8'h11, vals[3][23:0]}, "be 1000 touches D31-D24 only");
    cpu_write(addrs[3], 4'b0100, 32'h11223344, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == {8'h11, 8'h22, vals[3][15:0]}, "be 0100 touches D23-D16 only");
    cpu_write(addrs[3], 4'b0010, 32'h11223344, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == {8'h11, 8'h22, 8'h33, vals[3][7:0]}, "be 0010 touches D15-D8 only");
    cpu_write(addrs[3], 4'b0001, 32'h11223344, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == 32'h11223344, "be 0001 touches D7-D0 only");
    cpu_write(addrs[3], 4'b1100, 32'hAABBCCDD, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == 32'hAABB3344, "be 1100 is the high word");
    cpu_write(addrs[3], 4'b0011, 32'hAABBCCDD, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == 32'hAABBCCDD, "be 0011 is the low word");
    cpu_write(addrs[3], 4'b0110, 32'h55667788, ack);
    cpu_read(addrs[3], rd, ack);  check(rd == 32'hAA6677DD, "be 0110 is the middle word");
    vals[3] = 32'hAA6677DD;

    // 4. back to back
    $display("---- back-to-back cycles");
    cycles_before = bus_cycles; acks_before = acks_late;
    for (k = 0; k < 4; k = k + 1)
      for (n = 0; n < 12; n = n + 1) begin
        if (k[0]) begin cpu_read(addrs[n], rd, ack); check(rd == vals[n], "back-to-back read data"); end
        else cpu_write(addrs[n], 4'hF, vals[n], ack);
      end
    check(acks_late == acks_before, "every back-to-back cycle acknowledged at two C16M");

    // 5. aborted starts
    $display("---- aborted starts");
    bus_cycle(0, addrs[7], 4'hF, 0, 1, 0, rd, ack);                  // a read that never runs
    cpu_read(addrs[8], rd, ack);
    check(ack == 2 && rd == vals[8], "a read after an aborted read is right and on time");
    bus_cycle(1, addrs[8], 4'hF, 32'hDEADBEEF, 1, 0, rd, ack);       // a write that never runs
    cpu_read(addrs[8], rd, ack);
    check(rd == vals[8], "an aborted write never reaches the array");
    check(ack == 2, "and the read after it is on time");
    bus_cycle(1, addrs[8], 4'hF, 32'hDEADBEEF, 1, 0, rd, ack);       // abort, then a write to elsewhere
    cpu_write(addrs[9], 4'hF, 32'h0BADF00D, ack);
    cpu_read(addrs[9], rd, ack);  check(rd == 32'h0BADF00D, "a write after an aborted write lands");
    cpu_read(addrs[8], rd, ack);  check(rd == vals[8], "and the aborted one still did not");
    vals[9] = 32'h0BADF00D;

    // 6. late requests (GLUE's refresh window)
    $display("---- late requests");
    bus_cycle(0, addrs[5], 4'hF, 0, 0, 4, rd, ack);
    check(rd == vals[5], "a read with the request four C16M late has the right data");
    check(ack == 6, "and is acknowledged two edges after the request (the request is sampled on the second clock)");
    bus_cycle(1, addrs[5], 4'hF, 32'h600D1DEA, 0, 4, rd, ack);
    check(ack == 6, "a late write re-opens its row: acknowledged two edges after the request");
    cpu_read(addrs[5], rd, ack);
    check(rd == 32'h600D1DEA, "and it landed");
    vals[5] = 32'h600D1DEA;

    // 7. the download port
    $display("---- download");
    for (k = 0; k < 64; k = k + 1) dl_word(24'h420000 + k, 16'h8000 + k[15:0] * 16'h0101);
    for (k = 0; k < 32; k = k + 1) begin
      cpu_read(23'h210000 + k, rd, ack);
      check(rd[31:16] == 16'h8000 + (2*k) * 16'h0101 && rd[15:0] == 16'h8000 + (2*k+1) * 16'h0101,
            "downloaded words read back as a big-endian longword");
    end
    // interleaved with CPU cycles: a start that lands on a download word
    // waits for it, so these may be acknowledged late - counted, not failed
    acks_before = acks_late;
    fork
      begin
        for (k = 0; k < 48; k = k + 1) dl_word(24'h440000 + k, 16'hC000 + k[15:0]);
        dl_done = 1;
      end
      begin
        while (!dl_done) begin
          cpu_write(addrs[0], 4'hF, 32'h12345678, ack);
          cpu_read(addrs[0], rd, ack);
          check(rd == 32'h12345678, "CPU data intact while downloading");
        end
      end
    join
    late_dl = acks_late - acks_before;
    $display("      %0d CPU cycles waited for a download word", late_dl);
    for (k = 0; k < 24; k = k + 1) begin
      cpu_read(23'h220000 + k, rd, ack);
      check(rd[31:16] == 16'hC000 + 2*k[14:0] && rd[15:0] == 16'hC001 + 2*k[14:0],
            "words downloaded during CPU cycles read back");
    end
    vals[0] = 32'h12345678;

    // 8. refresh under a long back-to-back load
    $display("---- 100 us of back-to-back cycles");
    cycles_before = bus_cycles; acks_before = acks_late;
    chip.max_ref_gap = 0.0;
    for (k = 0; k < 390; k = k + 1) begin                            // 390 x 255 ns ~ 100 us
      cpu_read(addrs[k % 12], rd, ack);
      if (rd !== vals[k % 12]) fails = fails + 1;
    end
    check(acks_late == acks_before, "no cycle of the 100 us was delayed by a refresh");
    check(chip.max_ref_gap > 0.0 && chip.max_ref_gap <= 7812.5, "every refresh interval inside 7.8125 us");
    $display("      %0d cycles, longest refresh interval %0.1f ns, %0d refreshes so far",
             bus_cycles - cycles_before, chip.max_ref_gap, chip.refreshes);

    // 9. the raw experiment port (the controller's header).  The schedules
    // below are compile 9's question put to the model: a single word with
    // the clock after its WRITE masked (the old download's shape), the same
    // with that clock unmasked, and the two-WRITE form; in the chip's
    // single-write mode and, through a raw LOAD MODE, in burst-write mode.
    $display("---- the raw experiment port");
    acks_before = acks_late;
    cpu_write(23'h006000, 4'hF, 32'hAAAA5555, ack);                  // words $00C000/$00C001
    // single-write mode (as loaded): the masked-beat schedule writes the one word
    raw_op(raw_word(16'h1234, 16'h0000, 8'b00_00_11_00, 4'b0011, 3'b000, 1'b0, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C000);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h12345555, "raw: one WRITE in single-write mode lands one word");
    // burst-write mode: the model masks the second beat as the datasheet says
    raw_op(raw_word(16'h0, 16'h0, 8'h0, 4'h0, 3'h0, 1'b0, 1'b0, 1'b0, 1'b1, 13'h0021), 24'h0);
    raw_op(raw_word(16'h2222, 16'h0000, 8'b00_00_11_00, 4'b0011, 3'b000, 1'b0, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C000);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h22225555, "raw: burst-write mode, the second beat masked stays unwritten");
    raw_op(raw_word(16'h4444, 16'h3333, 8'b00_00_00_00, 4'b0011, 3'b010, 1'b0, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C000);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h44443333, "raw: burst-write mode, the second beat unmasked is written with clock 3's word");
    // (in burst-write mode the second WRITE starts its own burst, whose
    // second beat wraps to the even column: clock 4 must be masked, as the
    // model showed when this schedule first left it open)
    raw_op(raw_word(16'h5566, 16'h7788, 8'b00_11_00_00, 4'b0011, 3'b010, 1'b0, 1'b1, 1'b1, 1'b0, 13'h0), 24'h00C000);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h55667788, "raw: two WRITEs land both words (clock 4 masked)");
    // back to single-write mode; the CPU port and the precharge path
    raw_op(raw_word(16'h0, 16'h0, 8'h0, 4'h0, 3'h0, 1'b0, 1'b0, 1'b0, 1'b1, 13'h0221), 24'h0);
    cpu_write(23'h006000, 4'hF, 32'h0BADF00D, ack);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h0BADF00D, "raw: after the LOAD MODE round trip a CPU write and read are intact");
    raw_op(raw_word(16'h9999, 16'h0000, 8'b00_00_00_00, 4'b0001, 3'b000, 1'b0, 1'b0, 1'b0, 1'b0, 13'h0), 24'h00C001);
    cpu_read(23'h006000, rd, ack);
    check(rd == 32'h0BAD9999, "raw: an experiment without auto-precharge (the odd word) is precharged by the port");
    check(acks_late == acks_before, "raw: the experiments left the CPU port on time");

    // 9. an abandoned read, a long idle, a peek-shaped read (plan 3.8
    // item 20: the board on compile 10 read one longword behind)
    $display("---- an abandoned read, 20 us idle, peek-shaped reads");
    chip.max_ref_gap = 0.0;
    bus_cycle(0, addrs[2], 4'hF, 32'h0, 1, 0, rd, ack);              // a start with no request
    #20000;
    check(chip.max_ref_gap > 0.0 && chip.max_ref_gap <= 7812.5, "refresh went on while an unrequested read waited");
    peek_read(addrs[5], rd);
    check(rd == vals[5], "a peek-shaped read after the idle returns its own data, not the abandoned read's");
    peek_read(addrs[6], rd);
    check(rd == vals[6], "and the one after it");
    cpu_read(addrs[7], rd, ack);
    check(rd == vals[7] && ack == 2, "and a GLUE-shaped read after those is right and on time");

    // 10. raw READs: the mask on the output beats
    $display("---- raw reads, masked and not");
    cpu_write(23'h006001, 4'hF, 32'hC0DEF00D, ack);                  // words $00C002/3
    raw_op(raw_word(16'h0, 16'h0, 8'h00, 4'h0, 3'h0, 1'b1, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C002);
    check(cpu_rdata == 32'hC0DEF00D, "a raw READ, unmasked, captures the longword");
    raw_op(raw_word(16'h0, 16'h0, 8'b00_00_11_11, 4'h0, 3'h0, 1'b1, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C002);
    check(cpu_rdata !== 32'hC0DEF00D, "a raw READ with DQM on clocks 2 and 3 captures blanked beats");
    $display("      masked read captured %08x (blanked beats read as the floating bus)", cpu_rdata);
    raw_op(raw_word(16'h0, 16'h0, 8'b00_00_00_11, 4'h0, 3'h0, 1'b1, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C002);
    $display("      DQM on clock 2 alone: captured %08x", cpu_rdata);
    raw_op(raw_word(16'h0, 16'h0, 8'b00_00_11_00, 4'h0, 3'h0, 1'b1, 1'b1, 1'b0, 1'b0, 13'h0), 24'h00C002);
    $display("      DQM on clock 3 alone: captured %08x", cpu_rdata);
    cpu_read(23'h006001, rd, ack);
    check(rd == 32'hC0DEF00D, "and the longword is intact after the masked reads");

    // 12. the disk port
    $display("---- the disk port");
    for (k = 0; k < 64; k = k + 1) dk_op(1, 24'h460000 + k, 16'hD000 + k[15:0] * 16'h0101, q16);
    dk_bad = 0;
    for (k = 0; k < 32; k = k + 1) begin
      cpu_read(23'h230000 + k, rd, ack);
      w_hi = 16'hD000 + (2*k) * 16'h0101; w_lo = 16'hD000 + (2*k+1) * 16'h0101;   // 16 bits, as written
      if (rd != {w_hi, w_lo}) dk_bad = dk_bad + 1;
    end
    check(dk_bad == 0, "disk words written read back as the CPU's big-endian longwords");
    for (k = 0; k < 16; k = k + 1) cpu_write(23'h238000 + k, 4'hF, {16'hE000 + k[15:0], 16'hF000 + k[15:0]}, ack);
    dk_bad = 0;
    for (k = 0; k < 32; k = k + 1) begin
      dk_op(0, 24'h470000 + k, 16'h0, q16);
      if (q16 != (k[0] ? 16'hF000 + k[15:1] : 16'hE000 + k[15:1])) dk_bad = dk_bad + 1;
    end
    check(dk_bad == 0, "disk reads of even and odd words return the CPU's words");
    // alongside back-to-back CPU cycles: the disk waits for the window
    acks_before = acks_late; ops_before = dk_ops; dk_done = 0; dk_bad = 0; cpu_bad = 0; n_cpu = 0;
    fork
      begin
        for (k = 0; k < 40; k = k + 1) dk_op(1, 24'h480000 + k, 16'hA000 ^ k[15:0], q16);
        for (k = 0; k < 40; k = k + 1) begin
          dk_op(0, 24'h480000 + k, 16'h0, q16);
          if (q16 != (16'hA000 ^ k[15:0])) dk_bad = dk_bad + 1;
        end
        dk_done = 1;
      end
      begin
        while (!dk_done) begin
          cpu_write(addrs[1], 4'hF, 32'h13572468, ack);
          cpu_read(addrs[1], rd, ack);
          if (rd != 32'h13572468) cpu_bad = cpu_bad + 1;
          n_cpu = n_cpu + 2;
        end
      end
    join
    vals[1] = 32'h13572468;
    check(dk_ops - ops_before == 80 && dk_bad == 0, "the disk port's 80 words done and right among back-to-back CPU cycles");
    check(cpu_bad == 0, "the CPU's data intact alongside it");
    check(acks_late == acks_before, "no back-to-back CPU cycle late: the disk waits for the window after a start");
    $display("      80 disk words in %0d CPU cycles", n_cpu);
    // requests arriving late in the window: timed off since_start, so some
    // land at clocks 14-18 of a back-to-back stream, where only 14 and 15
    // may issue
    acks_before = acks_late; dk_done = 0; cpu_bad = 0;
    fork
      begin
        for (kd = 0; kd < 40; kd = kd + 1) begin
          @(posedge clk_mem); while (dut.since_start != 6'd11 + kd % 6) @(posedge clk_mem);
          dk_op(kd[0], 24'h4A0000 + kd[7:0], kd[15:0], q16);
        end
        dk_done = 1;
      end
      begin
        while (!dk_done) begin
          cpu_read(addrs[2], rd, ack);
          if (rd != vals[2]) cpu_bad = cpu_bad + 1;
        end
      end
    join
    check(cpu_bad == 0 && acks_late == acks_before, "requests arriving late in the window: no CPU cycle late, data right");
    check(dk_out_of_window == 0, "every disk ACTIVE in the window after a start (10-15) or on an idle bus");
    $display("      %0d disk ACTIVEs, %0d of them at clocks 14-15 of the window", dk_issues, dk_late_in_window);
    check(dk_late_in_window > 0, "(the window's last clocks were exercised)");

    // an idle bus, then a CPU stream starting into the disk traffic
    acks_before = acks_late; dk_done = 0; cpu_bad = 0; late_ref = 0;
    fork
      begin
        // its own counter: the CPU branch loops on k (a shared one moved
        // the CPU's address under its expected value)
        for (kd = 0; kd < 300; kd = kd + 1) dk_op(kd[0], 24'h490000 + kd[7:0], kd[15:0], q16);
        dk_done = 1;
      end
      begin
        #3000;                                                         // the disk alone on an idle bus
        for (k = 0; k < 24; k = k + 1) begin
          cpu_read(addrs[k % 12], rd, ack);
          if (rd != vals[k % 12]) begin cpu_bad = cpu_bad + 1; $display("      cycle %0d: data %08x, want %08x", k, rd, vals[k % 12]); end
          if (ack != 2) begin
            $display("      cycle %0d of the stream: acknowledged at %0d, its start found %0s", k, ack,
                     start_blocker == 1 ? "a disk word" : start_blocker == 2 ? "a refresh" : "the chip free");
            if (start_blocker == 1) begin
              late_dk = late_dk + 1;
              if (k != 0) cpu_bad = cpu_bad + 1;            // after the first start the window rule holds
            end else if (start_blocker == 2) late_ref = late_ref + 1;
            else cpu_bad = cpu_bad + 1;
            if (ack > 3) cpu_bad = cpu_bad + 1;             // at most one wait state
          end
        end
      end
    join
    check(cpu_bad == 0, "a CPU stream into idle-bus disk traffic: right; a disk word delays only its first cycle, by one C16M at most");
    $display("      %0d CPU cycle(s) of that stream waited for a disk word", late_dk);

    // 11. the model's verdict
    check(chip.errors == 0, "no datasheet violation in the whole run");
    check(clashes == 0, "our DQ driver never overlaps the chip's (the whole run)");

    check(acks_late == late_dl + 2 + late_dk + late_ref,
          "only the two late-request cycles, the download collisions, the disk's idle-bus collision and a refresh due after the idle were late");
    $display("---- %0d bus cycles, %0d acknowledged later than two C16M: the two late-request cases, %0d download collisions, %0d disk, %0d refresh after an idle bus",
             bus_cycles, acks_late, late_dl, late_dk, late_ref);
    if (fails == 0) $display("==== PASS: %0d checks, the SDRAM controller holds GLUE's contract and the datasheets", pass);
    else $display("==== FAIL: %0d of %0d checks failed", fails, pass + fails);
    $finish;
  end

  initial begin
    #2000000;                                                        // 2 ms
    $display("==== FAIL: timeout");
    $finish;
  end

endmodule
