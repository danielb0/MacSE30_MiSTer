// tb_se30_machine.v - the machine from reset, with the real ROM in the
// SDRAM behind our controller (SE30_PLAN.md 3.6 item 3).
//
// WHAT THIS PROVES
//   rtl/se30_machine.v (the kernel, the wrapper, GLUE, the video) with
//   rtl/se30_sdram.v and sim/sdram/sdram_model.v holding the SE/30 ROM at
//   the ROM region, from reset, as the top will run it:
//
//     1. the first bus cycles are the reset vector from ROM through the
//        overlay: a long read at $00000000, one at $00000004, then the
//        first instruction fetch at the PC the ROM's vector names
//        (plan 2.2: $4080002A in the ROM's own table; the wrapper fetches
//        the aligned long)
//     2. every RAM and ROM cycle on the way is the Guide's four C16M
//        clocks, GLUE's refresh-window stall excepted
//     3. no bus error and no halt before the ROM's first I/O access
//     4. the ROM runs to its first I/O access - a VIA, by plan 2.11.6 -
//        which is reported (address, FC, direction, cycle number) and is
//        where Section 4 begins.  With no VIAs yet the run stops there.
//
//   It is also 1.10's measurement: the Starter Edition's wall clock on the
//   whole machine (run.sh prints it).
//
// CLOCKING
//   clk_sys 31.3344 MHz and clk_mem 94.0032 MHz from one time base, 3:1,
//   as the PLL gives them; phi1/phi2 as MacSE30.sv makes them.

`timescale 1ns/1ps

module tb_se30_machine;

  reg clk_mem = 0;
  always #5.319 clk_mem = ~clk_mem;
  reg clk_sys = 0;
  always #15.957 clk_sys = ~clk_sys;
  reg phi = 0;
  always @(posedge clk_sys) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg sdram_reset_n = 0, reset_n = 0;

  // ------------------------------------------------------------ SDRAM
  wire        ready, mem_start, mem_req, mem_we, mem_ack;
  wire [22:0] mem_addr;
  wire  [3:0] mem_be;
  wire [31:0] mem_wdata, mem_rdata;
  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;

  se30_sdram sdram (
    .clk(clk_mem), .phi(phi), .reset_n(sdram_reset_n), .ready(ready),
    .cpu_start(mem_start), .cpu_req(mem_req), .cpu_we(mem_we), .cpu_addr(mem_addr),
    .cpu_be(mem_be), .cpu_wdata(mem_wdata), .cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
    .dl_req(1'b0), .dl_addr(24'd0), .dl_data(16'd0), .dl_ack(),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq),
    .sd_dqm(sd_dqm), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));

  // the chip's clock reaches its pin about 4 ns after the fabric's edge,
  // and the controller's read capture is designed around that: see
  // sim/sdram/tb_se30_sdram.v, which explains the number
  localparam real CLK_TO_PIN = 4.0;
  wire sd_clk_chip;
  assign #(CLK_TO_PIN) sd_clk_chip = sd_clk;

  sdram_model #(.PRELOAD_HEX("rom.hex"), .PRELOAD_WORD(24'h400000)) chip (
    .clk(sd_clk_chip), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
    .ba(sd_ba), .addr(sd_addr), .dqm(sd_dqm), .dq(sd_dq));

  // ---------------------------------------------------------- machine
  wire        vidout, hsync_n, vsync_n, hblank, vblank;
  wire [31:0] cpu_addr;
  wire  [2:0] cpu_fc;
  wire  [1:0] dsack_n;
  wire        cpu_as_n, cpu_rw_n, berr, halted, reset_out_n;

  se30_machine #(.DECLROM_HEX("declrom.hex")) machine (
    .clk(clk_sys), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .mem_start(mem_start), .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
    .mem_be(mem_be), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .declrom_we(1'b0), .declrom_waddr(13'd0), .declrom_wdata(8'd0),
    .vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
    .nmi_n(1'b1),
    .dbg_addr(cpu_addr), .dbg_fc(cpu_fc), .dbg_as_n(cpu_as_n), .dbg_rw_n(cpu_rw_n),
    .dbg_dsack_n(dsack_n), .dbg_berr(berr), .dbg_halted(halted), .reset_out_n(reset_out_n));

  // -------------------------------------------------- the ROM's vector
  reg [15:0] romw [0:131071];
  initial $readmemh("rom.hex", romw);
  wire [31:0] exp_sp = {romw[0], romw[1]};
  wire [31:0] exp_pc = {romw[2], romw[3]};

  // ------------------------------------------------------ cycle logger
  // on phi1 edges, as the system bench meters: a cycle's length is the
  // C16M clocks AS* is seen low, plus one for S0
  localparam NLOG = 32;
  reg [31:0] log_addr [0:NLOG-1];
  reg  [2:0] log_fc   [0:NLOG-1];
  reg        log_rw   [0:NLOG-1];
  reg  [1:0] log_dsack[0:NLOG-1];
  reg [31:0] log_data [0:NLOG-1];      // the bus data at the cycle's end (read: what the CPU took)
  integer    log_len  [0:NLOG-1];
  integer cycles = 0, as_clocks = 0, long_cycles = 0, mem_cycles = 0, berrs = 0, io_cycles = 0;
  reg as_q = 1;
  reg [31:0] c_addr, c_data; reg [2:0] c_fc; reg c_rw; reg [1:0] c_dsack; reg c_berr;
  reg stop = 0;
  reg [31:0] io_addr; reg [2:0] io_fc; reg io_rw; integer io_cycle;
  integer i;

  wire is_io   = (c_fc != 3'd7) && ((c_addr[31:24] == 8'h50) || (c_addr[31:29] >= 3'b011));
  wire is_mem  = (c_fc != 3'd7) && !is_io;

  // phase 2: run on past the first I/O access until the CPU halts or loops
  // (no fetch address it has not fetched before for LOOP_CYCLES cycles),
  // logging the I/O accesses and the last fetch addresses - the prediction
  // for the probe deck on hardware (plan 3.6 item 6)
  localparam LOOP_CYCLES = 3000, NIO = 24, NRING = 16;
  reg        seen [0:65535];           // ROM-offset longwords fetched so far
  integer    since_new = 0, io_n = 0, ring_i = 0, berr_first = -1;
  reg [31:0] last_fetch = 0, last_as = 0;
  reg [31:0] io_a [0:NIO-1], io_d [0:NIO-1];
  reg        io_rw_l [0:NIO-1];
  reg  [2:0] io_fc_l [0:NIO-1];
  integer    io_cyc [0:NIO-1];
  reg [31:0] ring [0:NRING-1];
  initial for (i = 0; i < 65536; i = i + 1) seen[i] = 0;

  always @(posedge clk_sys) if (phi1 && reset_n) begin
    if (!cpu_as_n) begin
      as_clocks = as_clocks + 1;
      if (dsack_n != 2'b11) begin c_dsack = dsack_n; c_data = c_rw ? machine.cpu_din : machine.cpu_dout; end
      if (berr) c_berr = 1;
    end
    if (!cpu_as_n && as_q) begin
      c_addr = cpu_addr; c_fc = cpu_fc; c_rw = cpu_rw_n; c_dsack = 2'b11; c_berr = 0;
    end
    if (cpu_as_n && !as_q) begin
      if (cycles < NLOG) begin
        log_addr[cycles] = c_addr; log_fc[cycles] = c_fc; log_rw[cycles] = c_rw;
        log_dsack[cycles] = c_dsack; log_len[cycles] = as_clocks + 1; log_data[cycles] = c_data;
      end
      if (is_mem) begin mem_cycles = mem_cycles + 1; if (as_clocks + 1 > 4) long_cycles = long_cycles + 1; end
      if (c_berr) begin berrs = berrs + 1; if (berr_first < 0) berr_first = cycles; end
      if (is_io && !stop) begin
        io_addr = c_addr; io_fc = c_fc; io_rw = c_rw; io_cycle = cycles; stop = 1;
      end
      last_as = c_addr;
      if (c_fc == 3'd6) begin
        last_fetch = c_addr;
        if (!seen[c_addr[17:2]]) begin seen[c_addr[17:2]] = 1; since_new = 0; end
        else since_new = since_new + 1;
        ring[ring_i] = c_addr; ring_i = (ring_i + 1) % NRING;
      end else since_new = since_new + 1;
      if (is_io && io_n < NIO) begin
        io_a[io_n] = c_addr; io_d[io_n] = c_data; io_rw_l[io_n] = c_rw; io_fc_l[io_n] = c_fc; io_cyc[io_n] = cycles;
        io_n = io_n + 1;
      end
      cycles = cycles + 1;
      as_clocks = 0;
    end
    as_q = cpu_as_n;
  end

  // ----------------------------------------------------------- scoring
  integer pass = 0, fails = 0;
  task check(input cond, input [8*96-1:0] what);
    begin
      if (cond) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0s", what); end
    end
  endtask

  initial begin
    $display("---- power-up");
    repeat (5) @(posedge clk_mem); #1 sdram_reset_n = 1;
    while (!ready) @(posedge clk_mem);
    $display("      SDRAM ready at %0.1f us; the ROM's vector: SP %08x PC %08x", $realtime / 1000.0, exp_sp, exp_pc);
    repeat (20) @(posedge clk_sys); #1 reset_n = 1;

    $display("---- the ROM from reset");
    while (!stop && !halted && cycles < 20000) @(posedge clk_sys);
    repeat (4) @(posedge clk_sys);

    $display("      %0d bus cycles run; the first %0d:", cycles, (cycles < NLOG) ? cycles : NLOG);
    for (i = 0; i < NLOG && i < cycles; i = i + 1)
      $display("      %3d  %08x  fc %0d  %s  %08x  dsack %b  %0d clocks", i, log_addr[i], log_fc[i],
               log_rw[i] ? "rd" : "wr", log_data[i], log_dsack[i], log_len[i]);

    check(cycles >= 3, "the CPU ran at least three cycles");
    // UM 4.2: "exception vectors are located in supervisor data space, except
    // the reset vector, which is located in supervisor program space"
    check(log_addr[0] == 32'h00000000 && log_rw[0] && log_fc[0] == 3'd6, "cycle 0: the initial SP from $00000000, supervisor program space");
    check(log_addr[1] == 32'h00000004 && log_rw[1] && log_fc[1] == 3'd6, "cycle 1: the initial PC from $00000004");
    check(log_dsack[0] == 2'b00 && log_dsack[1] == 2'b00, "the vector reads are 32-bit port cycles");
    check(log_len[0] == 4 && log_len[1] == 4, "the vector reads are four C16M clocks");
    // the kernel prefetches the long at $8 before it takes the PC - one
    // 4-clock cycle a 68030 does not run (recorded in plan 3.6); the first
    // fetch at the reset PC is then cycle 3
    check((log_addr[2] == {exp_pc[31:2], 2'b00} && log_fc[2] == 3'd6) ||
          (log_addr[2] == 32'h00000008 && log_addr[3] == {exp_pc[31:2], 2'b00} && log_fc[3] == 3'd6),
          "the first fetch is at the ROM's reset PC (aligned long), after at most the kernel's $8 prefetch");
    check(berrs == 0, "no bus error before the first I/O access");
    check(!halted, "the CPU did not halt");
    check(stop, "the ROM reached an I/O access");
    if (stop) $display("      first I/O access: cycle %0d, %s %08x, fc %0d", io_cycle, io_rw ? "read" : "write", io_addr, io_fc);
    $display("      %0d memory cycles, %0d longer than four clocks (the refresh window)", mem_cycles, long_cycles);
    check(long_cycles * 20 < mem_cycles, "fewer than one memory cycle in twenty stalled");

    // ---- phase 2: on to the halt or the loop
    $display("---- running on, with the VIAs answering $00");
    while (!halted && since_new < LOOP_CYCLES && cycles < 40000) @(posedge clk_sys);
    repeat (4) @(posedge clk_sys);
    $display("      stopped after %0d cycles: %s", cycles,
             halted ? "the CPU HALTED (double bus fault)" : (since_new >= LOOP_CYCLES) ? "a LOOP (no new fetch address)" : "the cycle limit");
    $display("      the first %0d I/O accesses:", io_n);
    for (i = 0; i < io_n; i = i + 1)
      $display("      %6d  %s %08x  fc %0d  data %08x", io_cyc[i], io_rw_l[i] ? "rd" : "wr", io_a[i], io_fc_l[i], io_d[i]);
    if (berrs != 0) $display("      %0d bus errors, the first at cycle %0d", berrs, berr_first);
    $display("      the last %0d fetch addresses:", NRING);
    for (i = 0; i < NRING; i = i + 1) $display("      %08x", ring[(ring_i + i) % NRING]);
    $display("---- PREDICTION for the probe deck (plan 3.5): PIFA %08x  PLAS %08x  PACT %0d%s  halted %0d  bus errors %0d",
             last_fetch, last_as, cycles, halted ? "" : " and counting", halted, berrs);
    check(halted || since_new >= LOOP_CYCLES, "the run ends in a halt or a loop, not the cycle limit");
    check(chip.errors == 0, "the SDRAM model saw no datasheet violation");

    if (fails == 0) $display("==== PASS: %0d checks, the machine runs the ROM from reset to its first I/O access", pass);
    else $display("==== FAIL: %0d of %0d checks failed", fails, pass + fails);
    $finish;
  end

  initial begin
    #40000000;                                                       // 40 ms
    $display("==== FAIL: timeout");
    $finish;
  end

endmodule
