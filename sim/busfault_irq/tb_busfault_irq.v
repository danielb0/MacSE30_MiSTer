// tb_busfault_irq.v - an interrupt at every clock around an exception that
// is not a page fault: an external bus error (GLUE's UI6 on an empty slot)
// or an instruction's own trap (KNOWN ISSUES 46, SE30_PLAN.md).
//
// WHY
//   The Pawn on the SE/30 (2026-10-25, release 20261024): a MOVEA.L (A0),A0
//   reading empty slot $A completed with junk ($FA000059, the PMMU walk's
//   last descriptor) when a level-2 interrupt came with the bus error; the
//   interrupt was taken (its frame: PC $40810BF8, the next instruction) and
//   the bus error surfaced at the VIA2 handler's first instruction.  Every
//   earlier interrupt sweep used PMMU page faults, raised before a bus cycle
//   goes out; GLUE's bus error ends a bus cycle up to 63 us long.
//
// WHAT THIS PROVES (MC68030 User's Manual, 3rd ed., 8.1 and 8.2)
//   The program (gen_program.py) runs one exception-raising instruction ITER
//   times.  Iterations 0 and 1 run without an interrupt; iteration 1 is the
//   reference.  Every later iteration i raises the interrupt at clock
//   OFF[i-2] after the iteration's marker and holds it until the handler
//   acknowledges.  For every such iteration:
//     1. as many exceptions as the reference, and the first one's frame
//        word for word (SR, PC, format/vector, and by format the SSW, the
//        fault address, the stage B address).  Pipe stage B (+$0E) and the
//        DOB (+$18) only with +PIPE: an interrupt taken just before the
//        instruction changes them (KNOWN ISSUES 46's second item - the core's
//        pipe words are not the UM's stages even without one), and neither
//        is used on the way back (HMODE rerun and complete pass on the
//        registers)
//     2. A0, D0, D1 and the SR at the continuation as the reference's: the
//        bus-errored access never completes with bus data
//     3. the interrupt taken exactly once, its stacked PC an instruction's
//        address, and never Fn (the instruction after the faulting one)
//        unless all the reference's exceptions came first (a completed
//        access, HMODE=complete or a trap that returns)
//     4. no unexpected exception (the stub's $DEADFFFF), no halt
//     5. reads (r, m): every iteration's frame SR is $3018's - the CCR
//        before the faulting instruction (UM 8.2.2), never flags from bus data
//   +PLANT=k: iteration k's bus error is replaced by an acknowledge with
//   $DEADBEEF - the lost bus error itself; the bench must FAIL it.
//
// TIMING: HSYNC* (UI6's clock) restarts at every iteration's marker, so the
//   iterations' bus cycles time out alike and OFF is relative to the same
//   events in each.  +EVT prints the reference iteration's events (the
//   marker, BERR edges, exceptions, the handler's entry, the continuation)
//   for run_sweep.sh to place the offsets.
//
// CLOCKING AND MEMORY: as sim/busfault.

`timescale 1ns/1ps

module tb_busfault_irq;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ------------------------------------------------- the interrupt line
  integer level = 2;
  initial if (!$value$plusargs("LEVEL=%d", level)) level = 2;
  reg irq = 0;

  // ------------------------------------------------------------ the bus
  wire [31:0] cpu_addr, cpu_dout, glue_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, glue_berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, glue_dsack_n;
  wire [56:0] exc;
  // the plant: the bus error replaced by an acknowledge with junk
  reg         plant_now = 0;
  wire        berr    = glue_berr && !plant_now;
  wire  [1:0] dsack_n = plant_now && glue_berr ? 2'b00 : glue_dsack_n;
  wire [31:0] cpu_din = plant_now && glue_berr ? 32'hDEADBEEF : glue_din;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .coff(2'b00), .pace_en(1'b1), .post_en(1'b1), .reset_out_n(reset_out_n), .halted(halted),
    .dbg_exc(exc));

  // --------------------------------------------------------------- GLUE
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

  // the IIcx (vlog +define+IICX): GLUE as the IIcx's, every slot cycle
  // terminated by the NuChip - an empty slot is its NuBus timeout (256
  // NuBus clocks), a bus error with no UI6 in it
  wire  [1:0] nb_dsack_n;
  wire [31:0] nb_rdata;
  wire        nb_berr;
  wire  [3:0] slot_be;
`ifdef IICX
  localparam IICX = 1;
  iicx_nuchip nuchip (
    .clk(clk), .reset_n(reset_n),
    .sel(slot_sel), .addr(cpu_addr), .rw(cpu_rw_n), .be(slot_be), .wdata(cpu_dout),
    .rdata(nb_rdata), .dsack_n(nb_dsack_n), .berr(nb_berr), .tm_pb54(), .nb_tick(),
    .card_sel(), .card_addr(), .card_rw(), .card_be(), .card_wdata(),
    .card_rdata(32'h0), .card_ack(1'b0));
`else
  localparam IICX = 0;
  assign nb_dsack_n = 2'b11; assign nb_rdata = 32'h0; assign nb_berr = 1'b0;
`endif

  se30_glue #(.IICX(IICX)) glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(glue_din),
    .dsack_n(glue_dsack_n), .berr(glue_berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(rom_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(8'h00), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .nb_dsack_n(nb_dsack_n), .nb_rdata(nb_rdata), .nb_berr(nb_berr), .slot_be(slot_be),
    .via1_irq_n(!(irq && level == 1)), .via2_irq_n(!(irq && level == 2)), .scc_irq_n(!(irq && level == 4)), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  // HSYNC* as the video PALs make it (704 C16M, low 119-534), restarted at
  // every iteration's marker.  +HPER=n scales the line to n clocks: UI6's
  // wait shortens, the bus error still ends the cycle by GLUE's own rule.
  integer px = 0, hper = 704;
  initial if (!$value$plusargs("HPER=%d", hper)) hper = 704;
  reg     px_restart = 0;
  always @(posedge clk) if (phi1) begin
    px <= px_restart ? 0 : (px == hper - 1) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= hper * 535 / 704) || (px + 1 < hper * 119 / 704));
  end

  // ---------------------------------------------------------- RAM model
  reg [15:0] img [0:65535];
  reg [31:0] ram [0:32767];
  integer i;
  wire ram_wr_now = phi1 && ram_req && ram_we && !ram_ack;
  always @(posedge clk) if (phi1) begin
    ram_ack <= 0;
    if (ram_req && !ram_ack) begin
      if (ram_we) begin
        if (ram_be[3]) ram[ram_addr[14:0]][31:24] <= ram_wdata[31:24];
        if (ram_be[2]) ram[ram_addr[14:0]][23:16] <= ram_wdata[23:16];
        if (ram_be[1]) ram[ram_addr[14:0]][15:8]  <= ram_wdata[15:8];
        if (ram_be[0]) ram[ram_addr[14:0]][7:0]   <= ram_wdata[7:0];
      end
      ram_rdata <= ram[ram_addr[14:0]];
      ram_ack <= 1;
    end
  end

  // ------------------------------------------- the iterations and the offsets
  reg [31:0] F, FN, C, XH, IH, A0, nstarts;
  reg [8*8-1:0] fam, hmode;
  reg [31:0] starts [0:1023];
  integer noff = 0, plant = -1, evt = 0, it = -1, t0 = 0, irq_at = -1;
  integer off [0:8191];
  integer berr_edges = 0;
  reg     glue_berr_q = 0;
  always @(posedge clk) begin
    glue_berr_q <= glue_berr;
    // the marker: iteration it starts at clock t0
    if (ram_wr_now && ram_addr[14:0] == (32'h3F90 >> 2)) begin
      if (irq && it >= 2) $display("NOTE iteration %0d: the interrupt was still pending at its end", it);
      irq <= 0;
      it = ram_wdata; t0 = cyc; px_restart <= 1;
      irq_at = (it >= 2 && it - 2 < noff) ? t0 + off[it - 2] : -1;
      plant_now <= (it == plant);
      if (evt && it == 1) $display("EVT marker 0");
      if (evt && it == 2) $display("EVT end %0d", 0);
    end else px_restart <= 0;
    if (irq_at >= 0 && cyc == irq_at) irq <= 1;
    if (ram_wr_now && ram_addr[14:0] == (32'h3F80 >> 2)) irq <= 0;          // the acknowledge
    if (evt && it == 1) begin
      if (glue_berr && !glue_berr_q) $display("EVT berr %0d", cyc - t0);
      if (exc[56]) $display("EVT exc %0d vector %0d pc %08x", cyc - t0, exc[55:48], exc[31:0]);
      if (ram_wr_now && ram_addr[14:0] == (32'h3040 >> 2)) $display("EVT xh %0d", cyc - t0);
      if (ram_wr_now && ram_addr[14:0] == (32'h3F94 >> 2)) $display("EVT c %0d", cyc - t0);
    end
    if (evt && it == 2 && ram_wr_now && ram_addr[14:0] == (32'h3F90 >> 2)) ;
  end
  // the reference iteration's length, for the offsets' upper bound
  integer t1_end = 0;
  always @(posedge clk) if (ram_wr_now && ram_addr[14:0] == (32'h3F90 >> 2) && ram_wdata == 2 && evt)
    $display("EVT next %0d", cyc - t0);

  // +TRACE: the kernel's boundary signals on every clock of iteration 2
  // (ModelSim's signal spy into the VHDL kernel)
  reg        s_clkena, s_setint, s_int, s_mkberr, s_berrk, s_tint, s_tberr, s_setopc, s_setend, s_dec;
  reg  [1:0] s_state;
  reg  [2:0] s_ipl;
  reg [31:0] s_pc, s_epc;
  integer    trace = 0, trace_it = 2;
  reg  [7:0] s_flags, s_shadow; reg s_rccr, s_rsig, s_mmub, s_erw; reg [2:0] s_efc;
  reg        s_dsv, s_dsf, s_dsp, s_dsh, s_dsrw, s_prw; reg [31:0] s_dsa, s_kaddr;
  initial if ($test$plusargs("TRACE")) begin
    trace = 1;
    if (!$value$plusargs("TRACE=%d", trace_it)) trace_it = 2;
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/clkena_lw", "/tb_busfault_irq/s_clkena");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/setinterrupt", "/tb_busfault_irq/s_setint");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/interrupt", "/tb_busfault_irq/s_int");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/make_berr", "/tb_busfault_irq/s_mkberr");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/berr_k", "/tb_busfault_irq/s_berrk");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/trap_interrupt", "/tb_busfault_irq/s_tint");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/trap_berr", "/tb_busfault_irq/s_tberr");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/setopcode", "/tb_busfault_irq/s_setopc");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/setendOPC", "/tb_busfault_irq/s_setend");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/decodeOPC", "/tb_busfault_irq/s_dec");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/state", "/tb_busfault_irq/s_state");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/IPL_nr", "/tb_busfault_irq/s_ipl");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/TG68_PC", "/tb_busfault_irq/s_pc");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/exe_pc", "/tb_busfault_irq/s_epc");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/ALU/Flags", "/tb_busfault_irq/s_flags");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/flags_shadow", "/tb_busfault_irq/s_shadow");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/berr_read_ccr_restore", "/tb_busfault_irq/s_rccr");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/restore_ccr_sig", "/tb_busfault_irq/s_rsig");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/make_mmu_berr", "/tb_busfault_irq/s_mmub");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/berr_external_rw", "/tb_busfault_irq/s_erw");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/berr_external_fc", "/tb_busfault_irq/s_efc");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_valid", "/tb_busfault_irq/s_dsv");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_fresh", "/tb_busfault_irq/s_dsf");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_pre", "/tb_busfault_irq/s_dsp");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_hit", "/tb_busfault_irq/s_dsh");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_rw", "/tb_busfault_irq/s_dsrw");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/pmmu_rw", "/tb_busfault_irq/s_prw");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/dib_sub_addr", "/tb_busfault_irq/s_dsa");
    $init_signal_spy("/tb_busfault_irq/cpu/kernel/addr", "/tb_busfault_irq/s_kaddr");
  end
  always @(posedge clk) if (trace && it == trace_it && (s_clkena || s_berrk || s_mkberr))
    $display("TR ds v%b f%b p%b h%b rw%b prw%b %08x ka %08x | fl %02x sh %02x rccr %b rsig %b mmub %b erw %b efc %o | %0d st %b ipl %0d setint %b int %b mkberr %b berrk %b tint %b tberr %b setopc %b setend %b dec %b pc %08x epc %08x as %b addr %08x berr %b",
             s_dsv, s_dsf, s_dsp, s_dsh, s_dsrw, s_prw, s_dsa, s_kaddr, s_flags, s_shadow, s_rccr, s_rsig, s_mmub, s_erw, s_efc, cyc - t0, s_state, s_ipl, s_setint, s_int, s_mkberr, s_berrk, s_tint, s_tberr, s_setopc, s_setend, s_dec, s_pc, s_epc, cpu_as_n, cpu_addr, glue_berr);

  // +WREC=n: the record's writes (the handler's frame copy) in iteration n
  integer wrec = -1;
  initial if (!$value$plusargs("WREC=%d", wrec)) wrec = -1;
  always @(posedge clk) if (wrec >= 0 && it == wrec && ram_wr_now &&
                            ram_addr[14:0] >= (32'h6000 >> 2) + 16 * it && ram_addr[14:0] < (32'h6000 >> 2) + 16 * it + 16)
    $display("WREC %0d +%0d %08x", cyc - t0, (ram_addr[14:0] - (32'h6000 >> 2) - 16 * it) * 4, ram_wdata);

  // ------------------------------------------------------------ scoring
  integer pass = 0, fails = 0, bad_its = 0;
  function [31:0] rec(input integer k, input integer o);
    rec = ram[(32'h6000 + 64 * k + o) >> 2];
  endfunction
  function legal_pc(input [31:0] pc);
    integer j;
    begin
      legal_pc = 0;
      for (j = 0; j < nstarts; j = j + 1) if (starts[j] == pc) legal_pc = 1;
    end
  endfunction

  integer n, fd, r, k, o, iters, bad, pipe = 0, wdog;
  reg [31:0] endcode, ipc;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 32768; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    fd = $fopen("layout.txt", "r");
    r = $fscanf(fd, "%h %h %h %h %h %h %s %s %d", F, FN, C, XH, IH, A0, fam, hmode, nstarts);
    for (i = 0; i < nstarts; i = i + 1) r = $fscanf(fd, "%h", starts[i]);
    $fclose(fd);
    if ($test$plusargs("EVT")) evt = 1;
    if ($test$plusargs("PIPE")) pipe = 1;
    if (!$value$plusargs("PLANT=%d", plant)) plant = -1;
    noff = 0;
    if ($test$plusargs("OFFS")) begin
      fd = $fopen("offsets.txt", "r");
      while (!$feof(fd) && noff < 8192) begin
        r = $fscanf(fd, "%d", off[noff]);
        if (r == 1) noff = noff + 1;
      end
      $fclose(fd);
    end
    iters = 2 + noff;
    ram[32'h3014 >> 2] = iters;
    $display("---- %0s, HMODE %0s: F $%0h, Fn $%0h, C $%0h, A0 $%08h; level %0d; %0d iterations (%0d offsets); plant %0d",
             fam, hmode, F, FN, C, A0, level, iters, noff, plant);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    // an iteration is a few thousand clocks; 400,000 (+WDOG=n) is a hang (a
    // bus error that recurs for ever), reported rather than left to a timeout
    if (!$value$plusargs("WDOG=%d", wdog)) wdog = 400_000;
    while (ram[32'h3FF0 >> 2] == 0 && !halted && cyc - t0 < wdog) begin @(posedge clk); n = n + 1; end
    if (ram[32'h3FF0 >> 2] == 0 && !halted) $display("FAIL iteration %0d hung: %0d clocks without its end", it, wdog);
    repeat (40) @(posedge clk);
    endcode = ram[32'h3FF0 >> 2];
    $display("---- %0d clocks; end %08x; halted %0d", n, endcode, halted);

    // the reference
    $display("---- reference: %0d exceptions, frame %08x %08x %08x %08x %08x %08x %08x; A0 %08x D0 %08x D1 %08x SR %04x",
             rec(1, 0), rec(1, 20), rec(1, 24), rec(1, 28), rec(1, 32), rec(1, 36), rec(1, 40), rec(1, 44),
             rec(1, 48), rec(1, 52), rec(1, 56), rec(1, 60) & 16'hFFFF);
    if (endcode != 32'h600D0001 || halted) begin
      fails = fails + 1; $display("FAIL the run did not end on the loop's path: end %08x, halted %0d", endcode, halted);
    end
    if (rec(1, 0) == 0) begin
      fails = fails + 1; $display("FAIL the reference took no exception");
    end
    // a read's fault stacks the SR before the instruction's flags (UM 8.2.2):
    // $3018's (moveq #0,d2's Z, the prelude's X), never flags from the
    // bus-errored data
    if (fam == "r" || fam == "m")
      for (k = 0; k < iters; k = k + 1)
        if (rec(k, 20) >> 16 != ram[32'h3018 >> 2]) begin
          fails = fails + 1;
          $display("FAIL it %0d: the frame's SR %04x, not %04x (the CCR before the instruction)", k, rec(k, 20) >> 16, ram[32'h3018 >> 2]);
        end
    if (rec(0, 0) != rec(1, 0)) begin
      fails = fails + 1; $display("FAIL iteration 0 (cold) took %0d exceptions, the reference %0d", rec(0, 0), rec(1, 0));
    end
    for (k = 2; k < iters; k = k + 1) begin
      bad = 0;
      for (o = 0; o < 64; o = o + 4)
        if ((o == 0 || (o >= 20 && o < 64)) && (pipe || (o != 32 && o != 40)) && rec(k, o) != rec(1, o)) begin
          bad = 1;
          $display("FAIL it %0d (offset %0d): +%0d %08x, reference %08x", k, off[k - 2], o, rec(k, o), rec(1, o));
        end
      if (rec(k, 4) != 1) begin
        bad = 1; $display("FAIL it %0d (offset %0d): %0d interrupts taken", k, off[k - 2], rec(k, 4));
      end else begin
        ipc = rec(k, 8);
        if (!legal_pc(ipc)) begin
          bad = 1; $display("FAIL it %0d (offset %0d): the interrupt's PC %08x is no instruction's", k, off[k - 2], ipc);
        end
        if (ipc == FN && rec(k, 16) != rec(1, 0)) begin
          bad = 1; $display("FAIL it %0d (offset %0d): the interrupt taken at Fn %08x after %0d of %0d exceptions - the instruction ended without them",
                            k, off[k - 2], ipc, rec(k, 16), rec(1, 0));
        end
      end
      if (bad) bad_its = bad_its + 1; else pass = pass + 1;
    end
    if (plant >= 2) $display("---- the plant at iteration %0d: %0s", plant, (plant < iters) ? "armed" : "out of range");
    if (fails == 0 && bad_its == 0) $display("==== PASS: %0d iterations, every one as the reference", pass);
    else $display("==== FAIL: %0d iterations failed, %0d passed, %0d run failures", bad_its, pass, fails);
    $finish;
  end

endmodule
