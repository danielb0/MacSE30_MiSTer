// tb_wsfb_replay.v - NetBSD's readdisklabel() on the kernel, the wrapper
// and GLUE, from the state the IIcx board had (gen_replay.py's header; the
// X11/WSFB investigation, 2026-11-09).
//
// THE BOARD'S FAILURE: whichType() ($1D434, link.w a6,#-$20 ... movem.l
// -$2c(a6),a2-a4; unlk a6; rts) reached its epilogue with a6 on
// readdisklabel's frame ($453BC4), unwound it and returned to
// dk_getdisklabel ($25E226) with readdisklabel's loop registers; and the
// argument it had been called with read $FFFFFF74, as if
// "move.l d2,d6; addi.l #$ffffff74,d6" had added to d6's old 0.
//
// THIS BENCH: the run ends PASS at brelse ($234C8C: readdisklabel's loops
// done, its frame intact), FAIL at $25E226 (the board's failure), FAIL on
// any exception (gen_replay.py's handler marks $7FFF00) or the clock limit.
// It also checks, at every return from whichType, that a6 is $453BC4 (its
// caller's frame) and prints every argument written to $453B98 (the slot
// whichType's argument is pushed to).  +trace prints each instruction from
// readdisklabel on: exe_pc, d2, d6, a6, a7.
//
// CLOCKING AND MEMORY: as sim/cputest_int (clk 2 x C16M, GLUE on phi1,
// RAMSIZ 01: 8 MB, no aliasing); ram.hex loads all of it.

`timescale 1ns/1ps

module tb_wsfb_replay;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;

  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .coff(2'b00), .pace_en(1'b1), .post_en(1'b1),
    .reset_out_n(reset_out_n), .halted(halted));

  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  reg  [31:0] ram_rdata = 0;
  reg         ram_ack = 0;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel, fpu_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  reg         hsync_n = 1;

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
    .fpu_sel(fpu_sel), .fpu_dsack_n(2'b11), .fpu_rdata(32'h0),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  integer px = 0;
  always @(posedge clk) if (phi1) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

  // 8 MB: GLUE's longword address with RAMSIZ 01 is {4'b0, A22-A2}
  reg [31:0] ram [0:2097151];
  integer i;
  // +RAMLAT=<n>: each RAM access waits n ticks; +RAMJIT=<n> +RAMSEED=<s>:
  // RAMLAT + 0..n, drawn per access (as sim/predec_fault: the board's SDRAM
  // is slower than an answer on the next tick, and not constant)
  integer ramlat = 0, ramjit = 0, ramseed = 1, ram_wait = 0, ram_lat_now = 0;
  initial begin
    if ($value$plusargs("RAMLAT=%d", ramlat)) ;
    if ($value$plusargs("RAMJIT=%d", ramjit)) ;
    if ($value$plusargs("RAMSEED=%d", ramseed)) ;
    $display("---- RAM: latency %0d + 0..%0d ticks, seed %0d", ramlat, ramjit, ramseed);
  end
  always @(posedge clk) if (phi1) begin
    ram_ack <= 0;
    if (!ram_req || ram_ack) begin
      ram_wait <= 0;
      ram_lat_now <= ramjit > 0 ? ramlat + ({$random(ramseed)} % (ramjit + 1)) : ramlat;
    end
    else if (ram_wait < ram_lat_now) ram_wait <= ram_wait + 1;
    if (ram_req && !ram_ack && ram_wait >= ram_lat_now) begin
      if (ram_we) begin
        if (ram_be[3]) ram[ram_addr[20:0]][31:24] <= ram_wdata[31:24];
        if (ram_be[2]) ram[ram_addr[20:0]][23:16] <= ram_wdata[23:16];
        if (ram_be[1]) ram[ram_addr[20:0]][15:8]  <= ram_wdata[15:8];
        if (ram_be[0]) ram[ram_addr[20:0]][7:0]   <= ram_wdata[7:0];
      end
      ram_rdata <= ram[ram_addr[20:0]];
      ram_ack <= 1;
    end
  end

  // the kernel's PC and registers
  reg [31:0] epc, d2, d6, a6, a7;
  initial begin
    $init_signal_spy("/tb_wsfb_replay/cpu/kernel/exe_pc", "/tb_wsfb_replay/epc", 1);
    $init_signal_spy("/tb_wsfb_replay/cpu/kernel/regfile(2)", "/tb_wsfb_replay/d2", 1);
    $init_signal_spy("/tb_wsfb_replay/cpu/kernel/regfile(6)", "/tb_wsfb_replay/d6", 1);
    $init_signal_spy("/tb_wsfb_replay/cpu/kernel/regfile(14)", "/tb_wsfb_replay/a6", 1);
    $init_signal_spy("/tb_wsfb_replay/cpu/kernel/regfile(15)", "/tb_wsfb_replay/a7", 1);
  end

  reg trace_on = 0, inside = 0;
  initial trace_on = $test$plusargs("trace");
  reg [31:0] last_epc = 0;
  integer ninsn = 0, nret = 0, badret = 0, ncall = 0;
  always @(posedge clk) begin
    if (epc != last_epc) begin
      last_epc <= epc;
      if (epc == 32'h0001D544) inside <= 1;
      if (inside) begin
        ninsn = ninsn + 1;
        if (trace_on) $display("i %0d t=%0t pc=%08x d2=%08x d6=%08x a6=%08x a7=%08x", ninsn, $time, epc, d2, d6, a6, a7);
        if (epc == 32'h0001D434) ncall = ncall + 1;
        // the instruction after each JSR (A4) in readdisklabel: whichType came back
        if (epc == 32'h0001D614 || epc == 32'h0001D65A || epc == 32'h0001D690 ||
            epc == 32'h0001D6C4 || epc == 32'h0001D6F4 || epc == 32'h0001D74E) begin
          nret = nret + 1;
          if (a6 != 32'h00453BC4) begin
            badret = badret + 1;
            $display("FAIL: whichType return %0d at %08x: a6=%08x, not $00453BC4", nret, epc, a6);
          end
        end
      end
    end
  end

  // the argument slot whichType reads its partition-map entry pointer from
  always @(posedge clk) if (phi1 && !cpu_as_n && !cpu_rw_n && dsack_n != 2'b11 && cpu_addr == 32'h00453B98)
    $display("---- t=%0t argument pushed: %08x (call %0d, pc %08x)", $time, cpu_dout, ncall + 1, epc);

  integer n, fails = 0;
  reg [31:0] v, stop_pc;
  initial begin
    for (i = 0; i < 2097152; i = i + 1) ram[i] = 32'h0;
    $readmemh("ram.hex", ram);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (ram[32'h7FFF00 >> 2] === 32'h0 && halted !== 1'b1 && n < 4000000 &&
           epc !== 32'h00234C8C && epc !== 32'h0025E226) begin
      @(posedge clk); n = n + 1;
    end
    stop_pc = epc;
    repeat (20) @(posedge clk);
    $display("---- the run: %0d clocks, %0d instructions from readdisklabel, %0d whichType calls, %0d returns checked, pc %08x",
             n, ninsn, ncall, nret, stop_pc);
    v = ram[32'h7FFF00 >> 2];
    if (v == 32'hDEADDEAD) begin
      fails = fails + 1;
      $display("FAIL: exception, format/vector %04x, stacked PC %08x", ram[32'h7FFF04 >> 2][31:16], ram[32'h7FFF08 >> 2]);
    end else if (halted) begin
      fails = fails + 1; $display("FAIL: the CPU halted (double bus fault)");
    end else if (stop_pc === 32'h0025E226) begin
      fails = fails + 1; $display("FAIL: returned to dk_getdisklabel past readdisklabel (the board's failure), a6=%08x d2=%08x d6=%08x", a6, d2, d6);
    end else if (stop_pc !== 32'h00234C8C) begin
      fails = fails + 1; $display("FAIL: neither brelse nor $25E226 in 4,000,000 clocks (pc %08x)", stop_pc);
    end
    if (badret) fails = fails + 1;
    if (ncall == 0) begin fails = fails + 1; $display("FAIL: whichType never called"); end
    if (fails == 0) $display("==== PASS: readdisklabel's loops ran to brelse, a6 right at all %0d whichType returns", nret);
    else            $display("==== FAIL (%0d)", fails);
    $finish;
  end

endmodule
