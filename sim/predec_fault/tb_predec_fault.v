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
//   +BTT1=<ns> (only cycles in that time window), +NOPOST, +NOPACE,
//   +RAMLAT=<n> (each RAM access acknowledged n 16 MHz ticks later than
//   the default, as the board's SDRAM is).  Compiled with +define+SDRAM
//   (run.sh's SDRAM=1) the RAM is the board's memory path instead:
//   rtl/se30_sdram.v and sim/sdram/sdram_model.v, as sim/machine has them.

`timescale 1ns/1ps

module tb_predec_fault;

  reg clk = 0;
`ifdef SDRAM
  // clk_sys and clk_mem 3:1 from one time base, and clk_mem's phase-shifted
  // copies, as sim/machine has them (its header)
  always #15.957 clk = ~clk;               // 31.3344 MHz
  reg clk_mem = 0;
  always #5.319 clk_mem = ~clk_mem;        // 94.0032 MHz
  reg clk_sdc = 0, clk_capa = 0, clk_capb = 0;
  always @(clk_mem) begin
    clk_sdc  <= #(1.064)  clk_mem;
    clk_capa <= #(10.372) clk_mem;
    clk_capb <= #(8.377)  clk_mem;
  end
`else
  always #15.9574 clk = ~clk;              // 31.3344 MHz
`endif
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
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .coff(2'b00), .pace_en(pace_en), .post_en(post_en),
    .reset_out_n(reset_out_n), .halted(halted), .ecs(ecs));

  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire [31:0] ram_rdata;
  wire        ram_ack;
  reg  [31:0] ram_rdata_r = 0, rom_rdata = 0;
  reg         ram_ack_r = 0, rom_ack = 0;
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
    .via1_irq_n(1'b1), .via2_irq_n(via2_irq_n), .scc_irq_n(1'b1), .nmi_n(1'b1),
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
`ifdef SDRAM
  // the board's memory path: se30_machine's port (its "the memory port")
  // into rtl/se30_sdram.v and sim/sdram/sdram_model.v, the chip's DQM on
  // the A12/A11 traces, the board's pin delays (sim/machine's)
  wire        sd_ready, sd_cap_sel, mem_ack;
  wire  [1:0] sd_cap_ok;
  wire [31:0] mem_rdata;
  wire        mem_start = ecs && mem_early;
  wire        mem_req   = ram_req || rom_req;
  wire        mem_we    = !rom_early && ram_we && !ram_empty;
  wire [22:0] mem_addr  = rom_early ? {2'b11, 5'b00000, rom_addr} : {1'b0, ram_phys};
  reg         sdram_reset_n = 0;
  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;
  se30_sdram #(.TR_READS_LOG2(5)) sdram (
    .clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(sdram_reset_n),
    .ready(sd_ready), .cap_sel(sd_cap_sel), .cap_ok(sd_cap_ok),
    .cpu_start(mem_start), .cpu_req(mem_req), .cpu_we(mem_we), .cpu_addr(mem_addr),
    .cpu_be(ram_be), .cpu_wdata(ram_wdata), .cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
    .dl_req(1'b0), .dl_addr(24'd0), .dl_data(16'd0), .dl_ack(),
    .dk_req(1'b0), .dk_we(1'b0), .dk_addr(24'd0), .dk_wdata(16'd0), .dk_rdata(), .dk_ack(),
    .vr_req(1'b0), .vr_we(1'b0), .vr_addr(23'd0), .vr_be(4'd0), .vr_wdata(32'd0), .vr_rdata(), .vr_ack(),
    .raw_req(1'b0), .raw_ctl(64'd0), .raw_addr(24'd0), .raw_ack(), .dbg_dqm_force(1'b0),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq),
    .sd_dqm(sd_dqm), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));
  localparam real CLK_TO_PIN = 4.0, OUT_TO_PIN = 4.0, DQ_TO_REG = 2.0;
  wire        sd_clk_chip, cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, oe_c;
  wire [12:0] addr_c;
  wire  [1:0] ba_c, dqm_c;
  wire [15:0] dq_out_c, dq_chip;
  assign #(CLK_TO_PIN) sd_clk_chip = sd_clk;
  assign #(OUT_TO_PIN) {cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, addr_c, ba_c, dqm_c} =
                       {sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_addr, sd_ba, sd_dqm};
  assign #(OUT_TO_PIN) oe_c     = sdram.dq_oe;
  assign #(OUT_TO_PIN) dq_out_c = sdram.dq_out;
  assign dq_chip = oe_c ? dq_out_c : 16'hzzzz;
  assign #(DQ_TO_REG) sd_dq = sdram.dq_oe ? 16'hzzzz : dq_chip;
  sdram_model #(.PRELOAD_HEX("program.hex"), .PRELOAD_WORD(0), .FILL_UNWRITTEN(1)) chip (
    .clk(sd_clk_chip), .cke(cke_c), .cs_n(cs_n_c), .ras_n(ras_n_c), .cas_n(cas_n_c), .we_n(we_n_c),
    .ba(ba_c), .addr(addr_c), .dqm(addr_c[12:11]), .dq(dq_chip));
  assign ram_rdata = mem_rdata | {32{ram_empty_q}};
  assign ram_ack   = mem_ack;
  // a long of RAM, from the chip's array: word address = byte address / 2
  function [31:0] rd32(input [31:0] a);
    rd32 = {chip.mem[a[24:1]], chip.mem[a[24:1] + 1]};
  endfunction
  always @(posedge clk) if (phi1) rom_ack <= 0;
`else
  assign ram_rdata = ram_rdata_r;
  assign ram_ack   = ram_ack_r;
  function [31:0] rd32(input [31:0] a);
    rd32 = ram[a[23:2]];
  endfunction
  integer ramlat = 0, ram_wait = 0;      // +RAMLAT=<n>: a RAM access waits n ticks (the board's SDRAM is slower)
  always @(posedge clk) if (phi1) begin
    ram_ack_r <= 0; rom_ack <= 0;
    if (!ram_req || ram_ack_r) ram_wait <= 0;
    else if (ram_wait < ramlat) ram_wait <= ram_wait + 1;
    if (ram_req && !ram_ack_r && ram_wait >= ramlat) begin
      if (ram_we && !ram_empty) begin
        if (ram_be[3]) ram[ram_phys][31:24] <= ram_wdata[31:24];
        if (ram_be[2]) ram[ram_phys][23:16] <= ram_wdata[23:16];
        if (ram_be[1]) ram[ram_phys][15:8]  <= ram_wdata[15:8];
        if (ram_be[0]) ram[ram_phys][7:0]   <= ram_wdata[7:0];
      end
      ram_rdata_r <= ram[ram_phys] | {32{ram_empty}};
      ram_ack_r <= 1;
    end
    if (rom_req && !rom_ack) begin
      rom_rdata <= rom[rom_addr];
      rom_ack <= 1;
    end
  end
`endif


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

`ifdef RTRACE
  // ------------------------------------------- RTRACE (KNOWN ISSUES 20)
  // the board's replay trace (rtl/dbg_rtrace.v) on the bench's taps,
  // armed from reset, every replay matched, stopping at 512 records; the
  // run's end checks that every replay's frame, kernel beat and SDRAM pair
  // agree, as on a correct machine they must
  reg         rt_arm = 0;
  wire [127:0] rt_q;
  wire  [63:0] rt_stat;
  dbg_rtrace rt (
    .clk(clk), .rpr(cpu.dbg_rpr), .rpk(cpu.dbg_rpk), .sdw(sdram.dbg_wr),
    .arm(rt_arm), .wrap(1'b0), .mask(32'd0), .match(32'd0), .raddr(9'd0), .rdata(rt_q), .status(rt_stat));
  always @(posedge clk) rt_arm <= reset_n;
  task rt_check;
    integer e, nr, nk, ns, st, rfails;
    reg [127:0] q;
    reg  [15:0] ssw; reg [31:0] fa, dob, kl, kp, kd; reg [1:0] ksiz, want_siz;
    reg  [22:0] sxs; reg [3:0] sdqm; reg [31:0] sd;
    begin
      nr = 0; nk = 0; ns = 0; st = 0; rfails = 0;
      for (e = 0; e < rt.wp; e = e + 1) begin
        q = rt.mem[e];
        case (q[127:126])
          2'b01: begin
            ssw = q[109:94]; fa = q[77:46]; dob = q[45:14]; nr = nr + 1; st = 1;
            $display("RT %3d R t=%04x ssw=%04x state1=%04x fault=%08x dob=%08x #%0d", e, q[125:110], ssw, q[93:78], fa, dob, q[13:0]);
            want_siz = (ssw[5:4] == 2'b01) ? 2'b01 : (ssw[5:4] == 2'b10) ? 2'b10 : 2'b00;
            if (!ssw[8] || ssw[6]) begin rfails = rfails + 1; $display("FAIL: RTRACE R %0d: SSW %04x is not a data write fault", e, ssw); end
          end
          2'b10: begin
            kl = q[109:78]; kp = q[77:46]; kd = q[45:14]; ksiz = q[13:12]; nk = nk + 1;
            $display("RT %3d K t=%04x log=%08x phys=%08x d=%08x siz=%0d fc=%0d post=%0d lanes=%b", e, q[125:110], kl, kp, kd, ksiz, q[11:9], q[8], q[7:4]);
            if (st == 1) begin                 // the replay's own beat
              if (kl !== fa || ksiz !== want_siz || (ksiz == 2'b00 && kd !== dob)) begin
                rfails = rfails + 1; $display("FAIL: RTRACE K %0d: the replay's beat is not the frame's (log %08x siz %0d d %08x)", e, kl, ksiz, kd);
              end
              st = 2;
            end
          end
          2'b11: begin
            sdqm = q[109:106]; sxs = {q[105:104], q[103:91], q[90:83]}; sd = q[81:50]; ns = ns + 1;
            $display("RT %3d S t=%04x dqm=%b/%b long=%06x (byte %08x) d=%08x", e, q[125:110], sdqm[3:2], sdqm[1:0], sxs, {7'd0, sxs, 2'b00}, sd);
            if (st == 2) begin                 // the replay's own pair
              if (sxs !== kp[24:2] || (ksiz == 2'b00 && (sdqm !== 4'b0000 || sd !== dob))) begin
                rfails = rfails + 1; $display("FAIL: RTRACE S %0d: the replay's WRITE pair is not its beat (long %06x dqm %b d %08x)", e, sxs, sdqm, sd);
              end
              st = 3;
            end
          end
          default: begin rfails = rfails + 1; $display("FAIL: RTRACE record %0d has no kind", e); end
        endcase
      end
      $display("---- RTRACE: %0d replays seen, %0d matched; %0d records: %0d R, %0d K, %0d S", rt_stat[63:40], rt_stat[39:24], rt.wp, nr, nk, ns);
      if (nr == 0) begin rfails = rfails + 1; $display("FAIL: RTRACE logged no replay"); end
      if (nr != rt_stat[39:24]) begin rfails = rfails + 1; $display("FAIL: RTRACE: %0d R records for %0d matched replays", nr, rt_stat[39:24]); end
      fails = fails + rfails;
    end
  endtask
`endif

  initial begin
    if (!$value$plusargs("PROG=%s", prog_dir)) prog_dir = ".";
    if (!$value$plusargs("MAXCLK=%d", maxclk)) maxclk = 20000000;
    if ($value$plusargs("BTLO=%h", bt_lo) && $value$plusargs("BTHI=%h", bt_hi)) btrace = 1;
    if ($value$plusargs("BTT0=%d", bt_t0)) ;
    if ($value$plusargs("BTT1=%d", bt_t1)) ;
`ifndef SDRAM
    if ($value$plusargs("RAMLAT=%d", ramlat)) ;
`endif
    pace_en = !$test$plusargs("NOPACE");
    post_en = !$test$plusargs("NOPOST");
`ifdef SDRAM
    fd = $fopen({prog_dir, "/stop_at.txt"}, "r"); r = $fscanf(fd, "%h %d", stop_at, nexp); $fclose(fd);
    repeat (5) @(posedge clk_mem); #1 sdram_reset_n = 1;
    while (!sd_ready) @(posedge clk_mem);
    $display("---- SDRAM ready at %0.1f us (capture %s, cap_ok %b)", $realtime / 1000.0, sd_cap_sel ? "B" : "A", sd_cap_ok);
`else
    for (i = 0; i < 4194304; i = i + 1) ram[i] = 32'h0;
    for (i = 0; i < 65536; i = i + 1) rom[i] = 32'h0;
    $readmemh({prog_dir, "/program.hex"}, img);
    for (i = 0; i < 131072; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    fd = $fopen({prog_dir, "/stop_at.txt"}, "r"); r = $fscanf(fd, "%h %d", stop_at, nexp); $fclose(fd);
`endif
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (!done && !halted && n < maxclk) begin @(posedge clk); n = n + 1; end
    if (halted) begin fails = fails + 1; $display("FAIL: the CPU halted (double bus fault) after %0d clocks", n); end
    if (!done) begin fails = fails + 1; $display("FAIL: STOP not reached after %0d clocks", n); end
    $display("---- %0d clocks, %0d bus-error handler entries, %0d interrupts", n, rd32(32'h3200), rd32(32'h3208));
`ifdef SDRAM
    $display("---- the SDRAM model saw %0d datasheet violations", chip.errors);
    if (chip.errors != 0) fails = fails + 1;
`endif
`ifdef RTRACE
    rt_check;
`endif
    v = rd32(32'h3F00);
    if (v[31:16] == 16'hBBBB) begin fails = fails + 1; $display("FAIL: the bus-error handler ran more than 100 times (a fault that never resolves)"); end
    else if (v != 0) begin
      fails = fails + 1;
      $display("FAIL: an exception: format/vector word %04x, stacked PC %08x", v[15:0], rd32(32'h3F04));
    end
    for (la = 32'h3300; la < rd32(32'h3204) && la < 32'h3600; la = la + 8)
      $display("---- fault: address %08x  SSW %04x  format word %04x", rd32(la), rd32(la + 4) >> 16, rd32(la + 4) & 16'hFFFF);
    fd = $fopen({prog_dir, "/expect.txt"}, "r"); nrun = 0;
    while ($fscanf(fd, "%h %h", slot, want) == 2) begin
      r = $fgets(what, fd); nrun = nrun + 1;
      v = rd32(slot);
      if (v === want) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: got %08x, want %08x - %0s", v, want, what[8*399-1:0]); end
    end
    $fclose(fd);
    if (nrun != nexp) begin fails = fails + 1; $display("FAIL: %0d checks read from expect.txt, %0d written", nrun, nexp); end
    if (fails == 0) $display("==== PASS: %0d checks - every faulted instruction resumed correctly", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
