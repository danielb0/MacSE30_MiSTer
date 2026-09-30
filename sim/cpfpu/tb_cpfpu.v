// tb_cpfpu.v - item 7d (SE30_PLAN.md 8.9.4): the 68030 and the MC68882 on
// the bus - the kernel, the wrapper, GLUE and rtl/fpu/se30_fpu.v - running
// FPU instructions out of RAM.
//
// WHAT THIS PROVES (when it passes)
//   The MPU's side of the coprocessor protocol (docs/cp030_mpu_protocol.md,
//   030 UM Section 10): gen_program.py's program - FNOP, FMOVE of a control
//   register from an immediate, FMOVE in from Dn and from an immediate
//   (the CA = 0 form), register to register, stores to memory and to Dn,
//   FMOVEM in both directions, FTST and a taken FBcc, a store with an
//   absolute address after the command word, FSAVE and FRESTORE - runs to
//   its end marker with every result in RAM as expected, by CIR cycles to
//   CPU space $22000-$2201F (counted), and takes no exception.
//
//   Until the kernel speaks the protocol (8.9.4 stage B) it FAILS on the
//   first instruction: the kernel takes the F-line at decode ($DEAD000B at
//   the marker) with no CIR cycle at all.
//
//   The stage programs (gen_program.py b1, b2, b3a-c, b4, b5a-b) each cover one
//   part of stage B with their own checks; exceptions they expect have
//   handlers that file the frames. Two aids, set by inject.txt, stand in
//   for what the 68882 alone cannot provoke (B3): the reserved primitive
//   $0B00 answering one instruction's first response read (the MPU's
//   protocol violation), and VIA1's IRQ raised at a come-again or an
//   FSAVE's not-ready (interrupts inside a dialog), dropped when the
//   handler writes $3F00 - or, for an instruction's address there, at
//   that instruction's first released-while-running null (B5). A third
//   number, unless all ones, is how many CPU-space cycles to anything but
//   the 68882 (IDs 2-7, IACKs) the run must make (B5).
//   +trace prints bus cycles and micro-states,
//   +ntr=N the first N bus cycles (400 by default).
//
// CLOCKING AND MEMORY: as sim/system (tb_se30_system.v): clk 2 x C16M,
//   GLUE and the FPU on phi1, a 32-bit RAM model acknowledging a clock
//   after the request.

`timescale 1ns/1ps

module tb_cpfpu;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;

  // ------------------------------------------------------------ the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .reset_out_n(reset_out_n), .halted(halted));

  // --------------------------------------------------------------- GLUE
  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  reg  [31:0] ram_rdata = 0;
  reg         ram_ack = 0;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  reg         hsync_n = 1;
  reg         irq1_n = 1;             // VIA1's IRQ, raised by the bench (B3; below)
  wire        fpu_sel;
  wire  [1:0] fpu_dsack_n;
  wire [31:0] fpu_rdata, fpu_q;

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(32'h0), .rom_ack(1'b0),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(8'h00), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .fpu_sel(fpu_sel), .fpu_dsack_n(fpu_dsack_n), .fpu_rdata(fpu_rdata),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .via1_irq_n(irq1_n), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  // ---------------------------------------------------------------- FPU
  se30_fpu #(
    .UROM_HEX("../../rtl/fpu/ucode/ucode.urom.hex"), .NROM_HEX("../../rtl/fpu/ucode/ucode.nrom.hex"),
    .ENTRY_HEX("../../rtl/fpu/ucode/ucode.entry.hex"), .KROM_HEX("../../rtl/fpu/ucode/ucode.krom.hex"),
    .NSEL_HEX("../../rtl/fpu/ucode/ucode.nsel.hex")
  ) fpu (
    .clk(clk), .ce(phi1), .reset(!(reset_n && reset_out_n)),
    .cs(fpu_sel), .rw(cpu_rw_n), .a(cpu_addr[4:0]), .din(cpu_dout), .dout(fpu_q),
    .dsack_n(fpu_dsack_n), .dbg_exop(), .dbg_clocks(), .dbg_err(), .dbg_state());

  // Interrupts inside a dialog (B3, inject.txt's second number = 1): VIA1's
  // IRQ (level 1) rises when the first come-again ($8900) is read from the
  // response CIR and when the next not-ready ($01xx) is read from the save
  // CIR, and falls when the handler writes $3F00.  A second number above 1
  // (B5) is an instruction's address: the IRQ rises at the first released-
  // while-running null ($0900) that instruction reads.
  reg [31:0] irq_mode = 0;
  reg [31:0] cps_want = 32'hFFFFFFFF;       // inject.txt's third number: CPU-space cycles to other IDs (B5)
  integer nirq = 0;
  always @(posedge clk) begin
    if (irq1_n && fpu_sel && cpu_rw_n && fpu_dsack_n != 2'b11 &&
        ((irq_mode == 1 && nirq == 0 && cpu_addr[4:0] == 5'd0 && fpu_q[31:16] == 16'h8900) ||
         (irq_mode == 1 && nirq == 1 && cpu_addr[4:0] == 5'd4 && fpu_q[31:24] == 8'h01) ||
         (irq_mode > 1 && nirq == 0 && cpu_addr[4:0] == 5'd0 && fpu_q[31:16] == 16'h0900 &&
          cpu.kernel.opcode_pc == irq_mode))) begin
      irq1_n <= 0; nirq = nirq + 1;
    end
    if (phi1 && ram_req && !ram_ack && ram_we && ram_addr[14:0] == (32'h3F00 >> 2)) irq1_n <= 1;
  end

  // A coprocessor that answers what the 68882 never does (B3): the first
  // response CIR read of the instruction at inject.txt's address (0: none)
  // reads the reserved primitive $0B00, once - the MPU's protocol violation.
  reg [31:0] inj_pc = 0;
  reg inj_armed = 1, inj_q = 0;
  wire inj_hit = inj_armed && inj_pc != 0 && fpu_sel && cpu_rw_n && cpu_addr[4:0] == 5'd0 &&
                 cpu.kernel.opcode_pc == inj_pc;
  always @(posedge clk) begin
    if (inj_hit) inj_q <= 1;
    if (inj_q && cpu_as_n) begin inj_armed <= 0; inj_q <= 0; end
  end
  assign fpu_rdata = inj_hit ? {16'h0B00, fpu_q[15:0]} : fpu_q;
  integer fdi;
  initial begin
    fdi = $fopen("inject.txt", "r");
    if (fdi) begin if ($fscanf(fdi, "%h %h %h", inj_pc, irq_mode, cps_want)) ; $fclose(fdi); end
  end

  // HSYNC* as the video PALs make it (only the UI6 timeout cares)
  integer px = 0;
  always @(posedge clk) if (phi1) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

  // ---------------------------------------------------------- RAM model
  reg [15:0] img [0:65535];
  reg [31:0] ram [0:32767];
  integer i;
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

  // --------------------------------------------- the coprocessor cycles
  integer cir_cycles = 0, cpu_space_other = 0;
  reg as_q = 1;
  always @(posedge clk) if (phi1) begin
    if (!cpu_as_n && as_q && cpu_fc == 3'd7) begin
      if (cpu_addr[19:13] == 7'b0010_001) cir_cycles = cir_cycles + 1;
      else cpu_space_other = cpu_space_other + 1;
    end
    as_q = cpu_as_n;
  end

  // +trace: every bus cycle as it ends (address, FC, R/W, SIZ, data, DSACK/BERR)
  reg trace_on = 0;
  integer ntr = 0, ntrmax = 400;          // +ntr=N: trace N bus cycles (default 400)
  initial begin trace_on = $test$plusargs("trace"); if ($value$plusargs("ntr=%d", ntrmax)) ; end
  // +trace: the kernel's micro-state as it changes, with the opcode
  integer trms = -1;
  always @(posedge clk) if (trace_on && cpu.kernel.clkena_lw && ntr < ntrmax &&
                            (cpu.kernel.micro_state != trms || cpu.kernel.decodeOPC)) begin
    trms = cpu.kernel.micro_state;
    $display("t=%0t     ustate=%0d next=%0d opcode=%04x brief=%04x state=%b setstate=%b decodeOPC=%b PC=%08x flv=%b", $time,
             cpu.kernel.micro_state, cpu.kernel.next_micro_state, cpu.kernel.opcode, cpu.kernel.brief,
             cpu.kernel.state, cpu.kernel.setstate, cpu.kernel.decodeOPC, cpu.kernel.TG68_PC, cpu.kernel.fline_context_valid);
  end
  reg tr_as_q = 1;
  always @(posedge clk) if (trace_on && phi1) begin
    if (!cpu_as_n && tr_as_q && ntr < ntrmax)
      $display("t=%0t   start %s %08x fc=%0d siz=%0d  ustate=%0d", $time, cpu_rw_n ? "R" : "W", cpu_addr, cpu_fc, cpu_siz,
               cpu.kernel.micro_state);
    tr_as_q = cpu_as_n;
  end
  always @(posedge clk) if (trace_on && phi1 && !cpu_as_n && (dsack_n != 2'b11 || berr) && ntr < ntrmax) begin
    ntr = ntr + 1;
    $display("t=%0t %s %08x fc=%0d siz=%0d %s=%08x dsack=%b berr=%b", $time,
             cpu_rw_n ? "R" : "W", cpu_addr, cpu_fc, cpu_siz, cpu_rw_n ? "din" : "dout",
             cpu_rw_n ? cpu_din : cpu_dout, dsack_n, berr);
  end

  // ------------------------------------------------------------ the run
  integer pass = 0, fails = 0, n, fd, r;
  reg [31:0] a, want, mask, v;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 32768; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (ram[32'h3FF0 >> 2] == 32'h0 && !halted && n < 2000000) begin @(posedge clk); n = n + 1; end
    repeat (200) @(posedge clk);
    v = ram[32'h3FF0 >> 2];
    $display("---- the run: %0d clocks, marker %08x, %0d CIR cycles, %0d other CPU-space cycles",
             n, v, cir_cycles, cpu_space_other);
    if (halted) begin fails = fails + 1; $display("FAIL: the CPU halted (double bus fault)"); end
    if (v[31:16] == 16'hDEAD) begin
      fails = fails + 1;
      $display("FAIL: exception vector %0d taken (%0s)", v[7:0], v[7:0] == 8'd11 ? "the F-line" : "unexpected");
    end
    if (cps_want != 32'hFFFFFFFF) begin
      if (cpu_space_other == cps_want) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0d other CPU-space cycles, expected %0d", cpu_space_other, cps_want); end
    end
    if (cir_cycles > 0) pass = pass + 1;
    else begin fails = fails + 1; $display("FAIL: no coprocessor cycle"); end
    fd = $fopen("expect.txt", "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h\n", a, want, mask);
      if (r == 3) begin
        v = ram[a >> 2];
        if ((v & mask) === (want & mask)) pass = pass + 1;
        else begin fails = fails + 1; $display("FAIL $%04x: %08x, expected %08x (mask %08x)", a, v, want, mask); end
      end
    end
    $fclose(fd);
    if (fails == 0) $display("==== PASS: %0d checks - the 68030 and the 68882 run the program's dialogs", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
