// tb_predec_fault.v - MOVE.L -(A0),-(A1) page-faulting mid-instruction,
// through the PMMU, resumed by RTE (SE30_PLAN.md KNOWN ISSUES 20).
//
// WHAT THIS LOOKS FOR
//   A/UX's Mac environment bombs in QuickDraw on a garbage GDevice pointer,
//   the same value on every run (2026-10-14: btrace_1, poll_7).  Seconds
//   before, the dying process ran the ROM's BlockMove backward loop
//   ($4080F006: eight MOVE.L -(A0),-(A1)) over ~100 KB of its heap, and
//   the loop page-faulted 35 times mid-instruction - 34 on the destination
//   write, one on the source read.  The 68030 resumes such a fault from its
//   internal state (UM 8.2); our kernel instead rolls the register file
//   back and re-executes the instruction, except for a fault on an
//   instruction's last write, which it replays from a format $A frame.
//   MOVE.L -(A0),-(A1) - two predecrements - takes both paths.  A wrong
//   resume corrupts the moved block silently.
//
//   gen_program.py's program copies a patterned block downward with the
//   ROM's own loop, in user mode, with the source pages, the destination
//   pages or both invalid; the handler makes each faulting page valid and
//   RTEs with the frame untouched, as a pager does.  A case passes when A0
//   and A1 end at the block starts, D1 = -1, every destination long equals
//   its source, and the handler ran once per invalid page.  expect.txt
//   holds the slots and values; the handler's log (fault address, SSW,
//   format word) is printed.
//
// THE MODELS
//   sim/mmu16's: the tg68k wrapper (kernel, PMMU walker, caches, pacing),
//   GLUE, VIA2 and 16 MB of SIMMs, acknowledged a clock after the request.
//   The program image is the first 512 KB of RAM; no ROM.
//
//   Plusargs: +PROG=<dir> (default .), +MAXCLK=<n> (default 20,000,000),
//   +BTLO=<hex> +BTHI=<hex> (the bus trace, as sim/mmu16), +BTT0=<ns>
//   +BTT1=<ns> (only cycles in that time window), +NOPOST, +NOPACE.

`timescale 1ns/1ps

module tb_predec_fault;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;
  reg pace_en = 1, post_en = 1;

  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;
  wire        ecs;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .pace_en(pace_en), .post_en(post_en),
    .reset_out_n(reset_out_n), .halted(halted), .ecs(ecs));

  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  reg  [31:0] ram_rdata = 0, rom_rdata = 0;
  reg         ram_ack = 0, rom_ack = 0;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  reg         hsync_n = 1;
  wire        mem_early, rom_early;

  // VIA2, as se30_machine wires it: port A's RAMSIZ (PA7:6) reaches GLUE and
  // the SIMMs; an undriven port line reads 1
  wire  [7:0] via2_rdata, via2_pa_out, via2_pa_oe, via2_pb_out, via2_pb_oe;
  wire  [7:0] via2_pa_pin = (via2_pa_oe & via2_pa_out) | ~via2_pa_oe;
  wire  [1:0] ramsiz = via2_pa_pin[7:6];
  wire        via2_irq_n;
  se30_via via2 (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n && reset_out_n), .e_clk(e_clk),
    .sel(via2_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via2_rdata), .irq_n(via2_irq_n),
    .pa_in(via2_pa_pin), .pa_out(via2_pa_out), .pa_oe(via2_pa_oe),
    .pb_in(8'hFF), .pb_out(via2_pb_out), .pb_oe(via2_pb_oe),
    .ca1(1'b1), .ca2_in(1'b0), .ca2_out(), .ca2_oe(), .cb1_in(1'b1), .cb1_out(), .cb1_oe(),
    .cb2_in(1'b0), .cb2_out(), .cb2_oe(), .dbg_ifr(), .dbg_ier());

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(rom_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(via2_sel ? via2_rdata : 8'h00), .scsi_drq(1'b0),
    .mem_early(mem_early), .rom_early(rom_early),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(ramsiz), .hsync_n(hsync_n));

  // the SIMMs: four 4 MB in bank A, bank B empty (se30_simms, big = 1)
  wire [21:0] ram_phys;
  wire        ram_empty, ram_empty_q;
  se30_simms simms (
    .clk(clk), .big(1'b1), .ramsiz(ramsiz), .ram_addr(ram_addr), .start(ecs && mem_early), .sel(!rom_early),
    .phys(ram_phys), .empty(ram_empty), .empty_q(ram_empty_q));

  integer px = 0;
  always @(posedge clk) if (phi1) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

  // ------------------------------------------------------- RAM and ROM
  reg [31:0] ram [0:4194303];              // 16 MB
  reg [31:0] rom [0:65535];                // 256 KB
  reg [15:0] img [0:262143];               // the program image: the first 512 KB of RAM
  integer i;
  always @(posedge clk) if (phi1) begin
    ram_ack <= 0; rom_ack <= 0;
    if (ram_req && !ram_ack) begin
      if (ram_we && !ram_empty) begin
        if (ram_be[3]) ram[ram_phys][31:24] <= ram_wdata[31:24];
        if (ram_be[2]) ram[ram_phys][23:16] <= ram_wdata[23:16];
        if (ram_be[1]) ram[ram_phys][15:8]  <= ram_wdata[15:8];
        if (ram_be[0]) ram[ram_phys][7:0]   <= ram_wdata[7:0];
      end
      ram_rdata <= ram[ram_phys] | {32{ram_empty}};
      ram_ack <= 1;
    end
    if (rom_req && !rom_ack) begin
      rom_rdata <= rom[rom_addr];
      rom_ack <= 1;
    end
  end

  // ------------------------------------------------------ the bus trace
  // each cycle printed once, at the first clock of its acknowledge
  reg [31:0] bt_lo = 0, bt_hi = 0; reg btrace = 0;
  reg [63:0] bt_t0 = 0, bt_t1 = 64'hFFFFFFFFFFFFFFFF;   // +BTT0/+BTT1 (ns): a time window for the trace
  reg bt_ack_seen = 0;
  always @(posedge clk) if (phi1 && btrace) begin
    if (!cpu_as_n && dsack_n != 2'b11 && !bt_ack_seen &&
        ((cpu_addr >= bt_lo && cpu_addr < bt_hi) || (cpu.k_addr_log >= bt_lo && cpu.k_addr_log < bt_hi)) &&
        ($time >= bt_t0 && $time < bt_t1))
      $display("BT %0t %s a=%08x fc=%0d siz=%0d d=%08x  log=%08x op=%04x pc=%08x",
               $time, cpu_rw_n ? "R" : "W", cpu_addr, cpu_fc, cpu_siz, cpu_rw_n ? cpu_din : cpu_dout,
               cpu.k_addr_log, cpu.k_opcode, cpu.k_opcode_pc);
  end
  always @(posedge clk) if (phi1) begin
    if (cpu_as_n) bt_ack_seen <= 0;
    else if (dsack_n != 2'b11) bt_ack_seen <= 1;
  end


  // ------------------------------------------------------------- the run
  integer n, kk, maxclk, fails = 0, pass = 0; integer fd, r;
  reg [31:0] stop_at, v, slot, want, la;
  reg [8*200-1:0] prog_dir;
  reg [8*400-1:0] what;
  integer nexp, nrun;
  reg done = 0; integer tail = -1;
  always @(posedge clk) if (phi1 && reset_n && !done) begin
    if (!cpu_as_n && cpu_fc == 3'd6 && cpu_addr[31:2] == stop_at[31:2] && tail < 0) tail = 200;
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
  end

  initial begin
    if (!$value$plusargs("PROG=%s", prog_dir)) prog_dir = ".";
    if (!$value$plusargs("MAXCLK=%d", maxclk)) maxclk = 20000000;
    if ($value$plusargs("BTLO=%h", bt_lo) && $value$plusargs("BTHI=%h", bt_hi)) btrace = 1;
    if ($value$plusargs("BTT0=%d", bt_t0)) ;
    if ($value$plusargs("BTT1=%d", bt_t1)) ;
    pace_en = !$test$plusargs("NOPACE");
    post_en = !$test$plusargs("NOPOST");
    for (i = 0; i < 4194304; i = i + 1) ram[i] = 32'h0;
    for (i = 0; i < 65536; i = i + 1) rom[i] = 32'h0;
    $readmemh({prog_dir, "/program.hex"}, img);
    for (i = 0; i < 131072; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    fd = $fopen({prog_dir, "/stop_at.txt"}, "r"); r = $fscanf(fd, "%h %d", stop_at, nexp); $fclose(fd);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (!done && !halted && n < maxclk) begin @(posedge clk); n = n + 1; end
    if (halted) begin fails = fails + 1; $display("FAIL: the CPU halted (double bus fault) after %0d clocks", n); end
    if (!done) begin fails = fails + 1; $display("FAIL: STOP not reached after %0d clocks", n); end
    $display("---- %0d clocks, %0d bus-error handler entries", n, ram[32'h3200 >> 2]);
    v = ram[32'h3F00 >> 2];
    if (v[31:16] == 16'hBBBB) begin fails = fails + 1; $display("FAIL: the bus-error handler ran more than 100 times (a fault that never resolves)"); end
    else if (v != 0) begin
      fails = fails + 1;
      $display("FAIL: an exception: format/vector word %04x, stacked PC %08x", v[15:0], ram[32'h3F04 >> 2]);
    end
    for (la = 32'h3300; la < ram[32'h3204 >> 2] && la < 32'h3600; la = la + 8)
      $display("---- fault: address %08x  SSW %04x  format word %04x", ram[la >> 2], ram[(la + 4) >> 2] >> 16, ram[(la + 4) >> 2] & 16'hFFFF);
    fd = $fopen({prog_dir, "/expect.txt"}, "r"); nrun = 0;
    while ($fscanf(fd, "%h %h", slot, want) == 2) begin
      r = $fgets(what, fd); nrun = nrun + 1;
      v = ram[slot[23:2]];
      if (v === want) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0s - got %08x, want %08x", what[8*399-1:0], v, want); end
    end
    $fclose(fd);
    if (nrun != nexp) begin fails = fails + 1; $display("FAIL: %0d checks read from expect.txt, %0d written", nrun, nexp); end
    if (fails == 0) $display("==== PASS: %0d checks - every faulted instruction resumed correctly", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
