// tb_busfault_dib.v - the kernel, the wrapper and GLUE taking a bus error
// that the handler completes in software, as the MC68030 does (SE30_PLAN.md
// 1.18: the MODE32 hang of 2026-10-05).
//
// WHY
//   Compile 41 on the board with MODE32 7.5 and 32-bit addressing on hung at
//   the grey screen in a bus-error loop, ~11,600 a second, all on $BF7F1386:
//   the ROM's Memory Manager pointer check ($4080E5F2) reading $38(a6) with
//   a6 = $BF7F134E.  In 32-bit mode Lo3Bytes leaves the high byte, the
//   address is super-slot $B, no card answers and GLUE bus-errors it as the
//   real PALs would.  The ROM's handler ($4080E59C) clears DF in the stacked
//   SSW, writes $FFFFFFFF into the frame's Data Input Buffer and RTEs: the
//   MC68030 then finishes the instruction with that data and does not rerun
//   the read (UM 3ed 8.2.2, "the handler can complete the faulted cycle in
//   software").  Ours reran it, forever.  sim/busfault proves the rerun
//   (DF set); this bench proves the completion (DF clear).
//
// WHAT THIS PROVES (MC68030 User's Manual, 3rd ed., section 8)
//     1. the run ends on the ROM's path: the continuation, not an
//        unexpected exception (the stub markers $DEADxxxx), not a halt
//     2. the read is NOT rerun after the handler's RTE, and the fault is
//        taken at the operand's FIRST bus cycle: one handler entry, one bus
//        error, one exception - for the board's misaligned long too, whose
//        first cycle is a word at $...86 with SIZ saying four bytes remain
//        (5.2.4).  The handler supplies "properly sized data" for the whole
//        remaining operand ("byte, word, and 3-byte operands are right-
//        justified in the 4-byte data buffers", 8.2.2), so no second cycle
//        is run and no second fault taken
//     3. the register after the instruction: for the ROM's MOVE what the
//        handler put in the Data Input Buffer, both halves of it; for
//        MODE32's CMP its D6 untouched; for a completed write (INSTR=write,
//        DF cleared, no DIB) D6 untouched and no second write cycle
//     4. the first frame is the long bus fault frame, format $B, vector
//        offset $008, 92 bytes, its PC the faulting instruction's
//     5. its SSW says a data read fault: DF set, RW read, SIZE long (the
//        bytes remaining at the first cycle), FC supervisor data
//     6. its data cycle fault address (+$10) is the operand's address
//     7. the SP after the ROM's path is the SP before: the frame was
//        unwound whole by the RTE
//     8. the ROM's path runs on from the instruction: vector 2 restored,
//        the check's verdict memAZErr ($FFFFFF8F: $FFFFFFFF masked, minus a6,
//        not zero)
//
//   The frame is captured as the kernel writes it: every supervisor-data
//   write from the first bus error until the handler's first fetch.
//
// OPTIONS (gen_program.py, from the environment): INSTR=cmp (the default)
//   is MODE32's check as peeked from the hung board (RAM $22BE-$231C:
//   CMP.L $38(A6),D6 through the raw pointer, D6 the BFEXTU-stripped one,
//   the ROM's handler $4080E590 armed) - the board's loop; INSTR=move the
//   ROM's own check ($4080E5F2: MOVE.L $38(A6),D0 through the Lo3Bytes-
//   masked pointer), which the kernel's commit whitelist completed before
//   1.18.  HANDLER=zero (default) is $4080E590's clr.l of the DIB, ones is
//   $4080E59C's moveq #-1.  MMU=1 loads the ROM's 32-bit row before the
//   check (CRP $7FFF0002:table, TC $80F04D00, the sixteen early-terminating
//   descriptors of $4083F5A0 copied to RAM; MODE32's rows hold the same) so
//   the read is a translated, cache-inhibited access, as on the board;
//   CACHE=1 sets CACR $2101 (both caches on, write-allocate), the board's
//   value.  The board's case is both.  SP=7FFE starts with a word-aligned
//   SSP, so every frame long is split across two bus cycles.
//   INSTR=write (MOVE.L D6,$38(A6), the handler clearing DF with no DIB:
//   "the data has been correctly written") is the protocol's write side,
//   OPEN on both kernels (SE30_PLAN.md 1.18.4): the frame for an external
//   BERR on a write stacks the continuation PC + 2, so the RTE resumes
//   inside the next instruction.  Not in the gate.
//
// CLOCKING AND MEMORY: as sim/busfault.
//
`timescale 1ns/1ps

module tb_busfault_dib;

  reg clk = 0;
  always #15.9574 clk = ~clk;              // 31.3344 MHz
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;

  // +ipl: a level-2 interrupt pending throughout, masked by SR $2700 as on
  // the board (the deck's interrupt counts froze during the loop)
  reg ipl_pending = 0;
  initial if ($test$plusargs("ipl")) ipl_pending = 1;


  // ------------------------------------------------------------ the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;
  wire [56:0] exc;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .pace_en(1'b1), .post_en(1'b1), .reset_out_n(reset_out_n), .halted(halted),
    .dbg_exc(exc));

  // the kernel's exception pulse (the probe deck's PEXC/PTRP, plan 5.12.12
  // item 8): one clk per exception taken, with its vector number
  integer     excs = 0, exc2 = 0;
  reg  [31:0] exc_pc0 = 0;
  always @(posedge clk) if (exc[56]) begin
    excs = excs + 1;
    if (exc[55:48] == 8'd2) exc2 = exc2 + 1;
    if (excs == 1) exc_pc0 = exc[31:0];
  end

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
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(8'h00), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .via1_irq_n(1'b1), .via2_irq_n(!ipl_pending), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

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

  // the PMMU walker's descriptor reads (MMU=1: the table is at $4000)
  integer desc_reads = 0;
  always @(posedge clk) if (phi1 && ram_req && !ram_we && !ram_ack && ram_addr[24:4] == (32'h4000 >> 6)) desc_reads = desc_reads + 1;

  // ---------------------------------------------- the frame, as written
  // every supervisor-data write from the first bus error until the
  // handler's first fetch, by byte address (the RAM model's lanes)
  reg [31:0] probe_pc, h_pc, faddr, dib, rw;
  reg  [7:0] fbyte [0:32767];
  reg        fset  [0:32767];
  integer    berrs = 0, fetch_h = 0, lo = 32'h7FFFFFFF, slot_cycles = 0;
  reg        capturing = 0, captured = 0, berr_q = 0, as_q = 1;
  reg [31:0] a; integer b;
  // BERR can be shorter than a C16M period (GLUE drops it with AS*): seen on every clk
  always @(posedge clk) begin
    berr_q <= berr;
    if (berr && !berr_q) $display("t=%0t BERR: addr %08x fc %0d rw %b siz %b", $time, cpu_addr, cpu_fc, cpu_rw_n, cpu_siz);
    if (berr && !berr_q && (cpu_addr & 32'hFFFFFFFC) == (faddr & 32'hFFFFFFFC)) begin
      berrs = berrs + 1;
      if (!captured) capturing = 1;
    end
  end
  integer after_berr = 0;
  always @(posedge clk) if (phi1) begin
    if (berrs == 1 && !captured && !cpu_as_n && as_q && after_berr < 6) begin
      after_berr = after_berr + 1;
      $display("t=%0t after the first BERR, cycle %0d: addr %08x fc %0d rw %b", $time, after_berr, cpu_addr, cpu_fc, cpu_rw_n);
    end
    if (!cpu_as_n && as_q && cpu_fc == 3'd5 && (cpu_addr & 32'hFFFFFFF8) == (faddr & 32'hFFFFFFF8)) slot_cycles = slot_cycles + 1;
    if (!cpu_as_n && as_q && cpu_fc == 3'd6 && cpu_addr == h_pc) begin
      fetch_h = fetch_h + 1;
      if (capturing) begin capturing = 0; captured = 1; end
    end
    if (capturing && ram_req && ram_we && !ram_ack && cpu_fc == 3'd5) begin
      for (b = 0; b < 4; b = b + 1) if (ram_be[3 - b]) begin
        a = {ram_addr[14:0], 2'b00} + b;
        fbyte[a[14:0]] = ram_wdata[31 - 8*b -: 8];
        fset[a[14:0]] = 1;
        if (a < lo) lo = a;
      end
    end
    as_q = cpu_as_n;
  end
  function [15:0] fw(input integer off);
    begin fw = {fbyte[(lo + off) & 32'h7FFF], fbyte[(lo + off + 1) & 32'h7FFF]}; end
  endfunction

  // ------------------------------------------------------------ scoring
  integer pass = 0, fails = 0;
  task check(input cond, input [8*96-1:0] what, input [31:0] got, input [31:0] want);
    begin
      if (cond) begin pass = pass + 1; $display("pass %0s: %08x", what, got); end
      else begin fails = fails + 1; $display("FAIL %0s: got %08x, want %08x", what, got, want); end
    end
  endtask

  // ------------------------------------------------------------ the run
  integer n, fd, r; reg [31:0] endcode, sp0, sp1, count, ssw, d0, verdict, vec2;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 32768; i = i + 1) begin ram[i] = {img[2*i], img[2*i+1]}; fset[i] = 0; fbyte[i] = 0; end
    fd = $fopen("layout.txt", "r"); r = $fscanf(fd, "%h %h %h %h %h", probe_pc, h_pc, faddr, dib, rw); $fclose(fd);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (ram[32'h3FF0 >> 2] == 0 && !halted && n < 4_000_000) begin @(posedge clk); n = n + 1; end
    repeat (40) @(posedge clk);
    endcode = ram[32'h3FF0 >> 2]; sp0 = ram[32'h3010 >> 2]; sp1 = ram[32'h3018 >> 2]; count = ram[32'h3020 >> 2];
    d0 = ram[32'h3030 >> 2]; verdict = ram[32'h3034 >> 2]; vec2 = ram[32'h8 >> 2];
    $display("---- %0d clocks; end %08x; %0d handler entries, %0d bus errors on %08x; D0 after the read %08x; SP before %08x, after %08x; %0d descriptor reads; IPL pending %0d",
             n, endcode, count, berrs, faddr, d0, sp0, sp1, desc_reads, ipl_pending);

    // 1. the ROM's path
    check(!halted, "no double bus fault", halted, 0);
    check(endcode == 32'h600D0002, "the run ends at the ROM's continuation", endcode, 32'h600D0002);
    // 2. no rerun
    check(count == 1, "one handler entry: the read was not rerun", count, 1);
    check(berrs == 1, "one bus error on the operand: its first cycle faults, no second is run, and no re-run", berrs, 1);
    check(slot_cycles == 1, "one bus cycle at the operand in all: the completed access never goes out again", slot_cycles, 1);
    // 3. the data the handler supplied
    check(d0 == dib, "the register after the instruction: the DIB (MOVE) or unchanged (CMP)", d0, dib);
    // 4-6. the first frame
    $display("---- the first frame as written: %0d bytes, from %08x", sp0 - lo, lo);
    for (b = 0; b < 92 && lo + b < sp0; b = b + 16)
      $display("     +%02x: %04x %04x %04x %04x %04x %04x %04x %04x", b,
               fw(b), fw(b+2), fw(b+4), fw(b+6), fw(b+8), fw(b+10), fw(b+12), fw(b+14));
    check(sp0 - lo == 92, "the frame is 92 bytes: the long bus fault frame", sp0 - lo, 92);
    check(fw(6) == 16'hB008, "format $B, vector offset $008", fw(6), 16'hB008);
    check({fw(2), fw(4)} == probe_pc, "the PC is the faulting instruction's", {fw(2), fw(4)}, probe_pc);
    ssw = fw(10);
    check(ssw[8] == 1, "SSW DF: a data fault", ssw, 32'h0100);
    check(ssw[6] == rw[0] && ssw[5:4] == 2'b00 && ssw[2:0] == 3'd5, "SSW: a long read (write: RW=0) in supervisor data space", ssw, 32'h0105 | (rw[0] << 6));
    check({fw(16), fw(18)} == faddr, "the data cycle fault address is the operand's first cycle's", {fw(16), fw(18)}, faddr);
    // 7. the unwind
    check(sp1 == sp0, "the SP after the ROM's path is the SP before the fault", sp1, sp0);
    // 8. the ROM's path runs on
    check(vec2 == 32'h2000, "vector 2 restored by the instruction after the read", vec2, 32'h2000);
    check(verdict == 32'hFFFFFF8F, "the check's verdict: memAZErr", verdict, 32'hFFFFFF8F);
    // 9. the probe deck's exception pulse
    check(exc2 == 1, "the exception pulse: once, vector 2", exc2, 1);
    check(excs == exc2, "and no other exception taken", excs, exc2);
    check(exc_pc0 == probe_pc, "its PC: the faulting instruction's, as stacked", exc_pc0, probe_pc);

    if (fails == 0) $display("==== PASS: %0d checks - the software-completed bus error returns as the MC68030's", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
