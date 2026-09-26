// tb_se30_sdram.v - the SDRAM controller against a behavioural chip, held
// to GLUE's contract and to the datasheets (SE30_PLAN.md 3.2, 3.3, 3.6
// item 2).
//
// WHAT THIS PROVES
//   rtl/se30_sdram.v, on a 94.0032 MHz clock phase-locked to the 31.3344 MHz
//   clk_sys, driving sim/sdram/sdram_model.v (our model of the W9825G6KH-6 /
//   AS4C32M16SB-7, which checks every datasheet interval and the power-up
//   sequence):
//
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
//     8. the model reports no datasheet violation anywhere in the run
//
// HOW IT DRIVES THE DUT
//   As the wrapper and GLUE do (plan 3.2's timeline): the address, R/W,
//   byte enables and write data appear at the S0 edge with cpu_start high
//   for that clk_sys; cpu_req rises at S1 (AS*) and stays until the
//   acknowledge is sampled, which GLUE does at its C16M edges from two
//   clocks after S0; it then drops the request (mem_done) and the cycle
//   ends two C16M later.  "ack at N" is the C16M edge, counted from S0, at
//   which the acknowledge was first seen: 2 is the contract.

`timescale 1ns/1ps

module tb_se30_sdram;

  // ------------------------------------------------------------ clocks
  // both from one time base: 5.319 ns half-periods, 3:1
  reg clk_mem = 0;
  always #5.319 clk_mem = ~clk_mem;
  reg clk_sys = 0;
  always #15.957 clk_sys = ~clk_sys;
  reg phi = 0;
  always @(posedge clk_sys) phi <= ~phi;
  wire phi1 = !phi;                                // the clk_sys in which C16M rises: S0, S2, S4 begin here
  reg reset_n = 0;

  // --------------------------------------------------------------- DUT
  reg         cpu_start = 0, cpu_req = 0, cpu_we = 0;
  reg  [22:0] cpu_addr = 0;
  reg   [3:0] cpu_be = 4'hF;
  reg  [31:0] cpu_wdata = 0;
  wire [31:0] cpu_rdata;
  wire        cpu_ack, ready;
  reg         dl_req = 0;
  reg  [23:0] dl_addr = 0;
  reg  [15:0] dl_data = 0;
  wire        dl_ack;

  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;

  se30_sdram dut (
    .clk(clk_mem), .reset_n(reset_n), .ready(ready),
    .cpu_start(cpu_start), .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_be(cpu_be), .cpu_wdata(cpu_wdata), .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq),
    .sd_dqm(sd_dqm), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));

  sdram_model chip (
    .clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
    .ba(sd_ba), .addr(sd_addr), .dqm(sd_dqm), .dq(sd_dq));

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

  // ------------------------------------------------------ test vectors
  // 12 longword addresses: all four banks (bit 21 and 22 of the longword
  // address are the bank), a row edge (column wrap at 512 words = 256
  // longwords), the RAM top, the ROM base and the last longword of 32 MB
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

  initial begin
    $display("---- reset and power-up");
    repeat (5) @(posedge clk_mem); #1 reset_n = 1;
    while (!ready) @(posedge clk_mem);
    t_ready = $realtime;
    check(t_ready > 200000.0 && t_ready < 260000.0, "ready after the 200 us pause and the ladder");
    check(chip.refreshes == 8, "eight refreshes in the ladder");
    check(chip.errors == 0, "the ladder is accepted by the model");
    $display("      ready at %0.1f us", t_ready / 1000.0);

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
    check(ack == 5, "and is acknowledged at the edge after the request");
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

    // 9. the model's verdict
    check(chip.errors == 0, "no datasheet violation in the whole run");

    check(acks_late == late_dl + 2, "only the two late-request cycles and the download collisions were late");
    $display("---- %0d bus cycles, %0d acknowledged later than two C16M: the two late-request cases and %0d download collisions",
             bus_cycles, acks_late, late_dl);
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
