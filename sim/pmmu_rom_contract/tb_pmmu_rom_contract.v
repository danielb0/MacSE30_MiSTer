// tb_pmmu_rom_contract.v - the SE/30 ROM's MMU contract, run through the
// upstream 68030 PMMU.
//
// WHAT THIS PROVES
//   SE30_PLAN.md 1.11 read, from the ROM image itself, exactly what the
//   SE/30 ROM asks of the PMMU: two CRP/TC rows in ROM (24-bit and 32-bit
//   mode), each pointing at a sixteen-entry short-format table of
//   early-terminating page descriptors that is ALSO in ROM, with U and M
//   pre-set so the walker never has to write.  This bench loads those exact
//   rows into TG68K_PMMU_030 - the PMMU we intend to ship - serves the
//   tables from the real ROM image, and asserts:
//
//     - every one of the 16 blocks in each mode translates to what the
//       table says, with the cache-inhibit bit the table says;
//     - in 24-bit mode the top address byte is ignored (TC.IS=8), which is
//       the whole mechanism by which a "dirty" 24-bit System runs;
//     - the walker reads only inside the ROM and NEVER asserts mem_we;
//     - TC accepts both geometries (no MMU configuration exception);
//     - a PMOVE with FD=0 into CRP/TC flushes the ATC, so the ROM's
//       _SwapMMUMode dance (24 -> 32 -> 24) sees the new table each time;
//     - TC=0, as the reset path writes it, returns the PMMU to identity.
//
// WHAT IT DOES NOT PROVE
//   The CACR readback the ROM uses to identify a 68030 lives in the kernel,
//   not the PMMU, and needs a kernel-level bench.  Nothing here exercises
//   the System's own use of the MMU (virtual memory builds RAM tables and
//   does need U/M writeback, RMC and the walker timeout - plan 1.7).
//
// HOW IT DRIVES THE PMMU
//   The register port is what the kernel's PMOVE decode drives: reg_we for
//   one clock with reg_sel (10000 = TC, 10011 = CRP), reg_wdat and reg_part
//   (1 = high half of a 64-bit register, written FIRST, 0 = low half, which
//   commits).  reg_fd is the PMOVE FD bit.  A translation is req=1 with
//   addr_log/fc/rw/is_insn held until busy falls; that mirrors upstream's
//   own tb_pmmu_early_term_remap.vhd.  The memory model acks one clock
//   after mem_req, as upstream's mock does.
//
// MIXED LANGUAGE
//   This is Verilog instantiating a VHDL entity.  It runs under ModelSim
//   (Starter Edition is enough: the PMMU alone is ~5,000 VHDL lines, under
//   the 10,000-line speed limit) and cannot run under iverilog - see plan
//   1.10 for why that is the accepted cost.
//
// ROM
//   Reads `se30.rom` from the working directory: the 256KB $97221136 image
//   (II FDHD / IIx / IIcx / SE/30).  run.sh copies it in.  The image is not
//   in the repo.

`timescale 1ns/1ps

module tb_pmmu_rom_contract;

  // ---------------------------------------------------------------- clock
  reg clk = 0;
  always #5 clk = ~clk;                    // 100 MHz; the PMMU is synchronous, rate is irrelevant
  reg nreset = 0;

  // ------------------------------------------------------ PMMU port signals
  reg         reg_we = 0, reg_re = 0, reg_part = 0, reg_fd = 0;
  reg  [4:0]  reg_sel = 0;
  reg  [31:0] reg_wdat = 0;
  wire [31:0] reg_rdat;
  reg         req = 0, is_insn = 0, rw = 1, rmw = 0;
  reg  [2:0]  fc = 3'd5;
  reg  [31:0] addr_log = 0;
  wire [31:0] addr_phys;
  wire        cache_inhibit, write_protect, fault, tc_enable, busy, mmu_config_err;
  wire [31:0] fault_status, fault_addr;
  wire [2:0]  fault_fc;
  wire        fault_rw, fault_is_insn;
  wire        mem_req, mem_we;
  wire [31:0] mem_addr, mem_wdat;
  reg         mem_ack = 0;
  reg  [31:0] mem_rdat = 0;
  wire [31:0] ptest_desc_addr;

  TG68K_PMMU_030 uut (
    .clk(clk), .nreset(nreset),
    .reg_we(reg_we), .reg_re(reg_re), .reg_sel(reg_sel), .reg_wdat(reg_wdat),
    .reg_rdat(reg_rdat), .reg_part(reg_part), .reg_fd(reg_fd),
    .ptest_req(1'b0), .pflush_req(1'b0), .pload_req(1'b0),
    .pmmu_fc(3'b000), .pmmu_addr(32'h0), .pmmu_brief(16'h0),
    .req(req), .is_insn(is_insn), .rw(rw), .rmw(rmw), .fc(fc),
    .addr_log(addr_log), .addr_phys(addr_phys),
    .cache_inhibit(cache_inhibit), .write_protect(write_protect),
    .fault(fault), .fault_status(fault_status), .fault_addr(fault_addr),
    .fault_fc(fault_fc), .fault_rw(fault_rw), .fault_is_insn(fault_is_insn),
    .tc_enable(tc_enable),
    .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdat(mem_wdat),
    .mem_ack(mem_ack), .mem_berr(1'b0), .mem_rdat(mem_rdat),
    .busy(busy),
    .mmu_config_err(mmu_config_err), .mmu_config_ack(1'b0),
    .ptest_desc_addr(ptest_desc_addr),
    .mmudis(1'b0), .cpu_reset(1'b0)
  );

  // ------------------------------------------------------------ ROM model
  // The walker's only legitimate memory is the ROM: both tables live there.
  localparam [31:0] ROM_BASE = 32'h40800000;
  localparam        ROM_SIZE = 32'h00040000;
  reg [7:0] rom [0:ROM_SIZE-1];

  integer walker_reads   = 0;   // every acked walker read
  integer walker_writes  = 0;   // must stay 0: U and M are pre-set in the ROM tables
  integer walker_outside = 0;   // must stay 0: a walk that left the ROM followed a bad pointer

  wire [31:0] rom_off = mem_addr - ROM_BASE;
  wire        in_rom  = (mem_addr >= ROM_BASE) && (mem_addr < ROM_BASE + ROM_SIZE);

  always @(posedge clk) begin
    mem_ack <= 1'b0;
    if (mem_req && !mem_ack) begin
      mem_ack <= 1'b1;
      if (mem_we) begin
        walker_writes = walker_writes + 1;
        $display("FAIL walker WRITE to %08X data %08X - the ROM tables have U and M set, nothing should be written",
                 mem_addr, mem_wdat);
      end else if (in_rom) begin
        walker_reads = walker_reads + 1;
        mem_rdat <= {rom[rom_off & ~32'd3], rom[(rom_off & ~32'd3) + 1],
                     rom[(rom_off & ~32'd3) + 2], rom[(rom_off & ~32'd3) + 3]};
        $display("walk  %08X -> %02X%02X%02X%02X   (for log %08X fc=%0d rw=%b)", mem_addr,
                 rom[rom_off & ~32'd3], rom[(rom_off & ~32'd3) + 1],
                 rom[(rom_off & ~32'd3) + 2], rom[(rom_off & ~32'd3) + 3], addr_log, fc, rw);
      end else begin
        walker_outside = walker_outside + 1;
        mem_rdat <= 32'h0;
        $display("FAIL walker read outside ROM at %08X", mem_addr);
      end
    end
  end

  // ---------------------------------------------------------- bookkeeping
  integer pass = 0, fails = 0;

  task note(input [8*96-1:0] s);
    begin $display("---- %0s", s); end
  endtask

  // -------------------------------------------------------- register port
  // sel: 10000 = TC, 10011 = CRP.  A 64-bit register is written high half
  // first (part=1, staged) then low half (part=0, commits both).
  task write_reg(input [4:0] sel, input [31:0] data, input part, input fd);
    begin
      @(posedge clk);
      reg_sel <= sel; reg_wdat <= data; reg_part <= part; reg_fd <= fd; reg_we <= 1'b1;
      @(posedge clk);
      reg_we <= 1'b0;
      @(posedge clk);
    end
  endtask

  // One row of the ROM's table at $40803B7A: CRP then TC, as the ROM's
  // _SwapMMUMode issues them (PMOVE (a0),CRP ; PMOVE 8(a0),TC), FD=0.
  task load_row(input [31:0] crp_hi, input [31:0] crp_lo, input [31:0] tc);
    begin
      write_reg(5'b10011, crp_hi, 1'b1, 1'b0);
      write_reg(5'b10011, crp_lo, 1'b0, 1'b0);
      write_reg(5'b10000, tc,     1'b0, 1'b0);
      repeat (3) @(posedge clk);            // let the TC validation pipeline settle
      if (mmu_config_err) begin
        fails = fails + 1;
        $display("FAIL MMU configuration exception for TC=%08X", tc);
      end
    end
  endtask

  // ------------------------------------------------------------ translate
  // Present a bus cycle, wait for the PMMU (ATC hit, or a walk through the
  // ROM model), then compare the physical address and CI against the table.
  task xlate(input [31:0] log, input [2:0] fcode, input read, input insn,
             input [31:0] want, input want_ci, input [8*56-1:0] name);
    integer i;
    begin
      @(posedge clk);
      addr_log <= log; fc <= fcode; rw <= read; is_insn <= insn; req <= 1'b1;
      @(posedge clk); #1;
      i = 0;
      while (busy && !fault && i < 400) begin
        @(posedge clk); #1; i = i + 1;
      end
      @(posedge clk); #1;
      req <= 1'b0;
      if (fault) begin
        fails = fails + 1;
        $display("FAIL %0s: log %08X fc=%0d faulted, status %08X", name, log, fcode, fault_status);
      end else if (i >= 400) begin
        fails = fails + 1;
        $display("FAIL %0s: log %08X fc=%0d - PMMU never became ready", name, log, fcode);
      end else if (addr_phys !== want || cache_inhibit !== want_ci) begin
        fails = fails + 1;
        $display("FAIL %0s: log %08X fc=%0d -> phys %08X ci=%b, want %08X ci=%b",
                 name, log, fcode, addr_phys, cache_inhibit, want, want_ci);
      end else begin
        pass = pass + 1;
        $display("pass %0s: log %08X fc=%0d -> phys %08X ci=%b", name, log, fcode, addr_phys, cache_inhibit);
      end
      @(posedge clk);
    end
  endtask

  // ------------------------------------------- the ROM's own table values
  // Read from the image, not hard-coded from the plan, so a different ROM
  // would be judged by its own table.  Offsets are those 1.11 records.
  localparam ROW24 = 32'h3B92;             // MMUType 4 (68030), 24-bit row: CRP(8) + TC(4)
  localparam ROW32 = 32'h3B9E;             // MMUType 4 (68030), 32-bit row

  function [31:0] rom32(input [31:0] off);
    rom32 = {rom[off], rom[off+1], rom[off+2], rom[off+3]};
  endfunction

  reg [31:0] crp_hi, crp_lo, tc, tbl, desc, want;
  integer    fd, n, blk, reads_before;
  reg [31:0] junk;

  initial begin
    // ------------------------------------------------------- load the ROM
    fd = $fopen("se30.rom", "rb");
    if (fd == 0) begin
      $display("FAIL cannot open se30.rom - run.sh copies the $97221136 image here");
      $finish;
    end
    n = $fread(rom, fd);
    $fclose(fd);
    if (n != ROM_SIZE || rom32(0) != 32'h97221136) begin
      $display("FAIL se30.rom is not the $97221136 256KB image (read %0d bytes, checksum %08X)", n, rom32(0));
      $finish;
    end
    note("ROM loaded: $97221136 (II FDHD / IIx / IIcx / SE/30)");

    // ---------------------------------------------------------------- reset
    repeat (4) @(posedge clk);
    nreset = 1;
    repeat (4) @(posedge clk);

    // ----------------------------------------- 1. after reset: identity
    // UM 9.2.2: RESET clears TC.E.  The ROM fetches its first instructions
    // at $4080002A with translation off, and then writes TC=0 anyway.
    note("1. reset: translation disabled, logical passes through");
    if (tc_enable) begin fails = fails + 1; $display("FAIL tc_enable set after reset"); end
    xlate(32'h4080002A, 3'd6, 1, 1, 32'h4080002A, 1'b0, "reset vector fetch");
    xlate(32'h00001000, 3'd5, 1, 0, 32'h00001000, 1'b0, "low RAM, MMU off");

    // ------------------------------------- 2. the 24-bit row, all 16 blocks
    crp_hi = rom32(ROW24); crp_lo = rom32(ROW24 + 4); tc = rom32(ROW24 + 8);
    $display("---- 2. 24-bit row: CRP %08X%08X TC %08X", crp_hi, crp_lo, tc);
    load_row(crp_hi, crp_lo, tc);
    if (!tc_enable) begin fails = fails + 1; $display("FAIL tc_enable clear after loading the 24-bit TC"); end
    tbl = crp_lo - ROM_BASE;
    reads_before = walker_reads;
    for (blk = 0; blk < 16; blk = blk + 1) begin
      desc = rom32(tbl + 4 * blk);
      if (desc[1:0] != 2'b01) begin
        fails = fails + 1;
        $display("FAIL 24-bit table entry %0d is not a page descriptor: %08X", blk, desc);
      end
      // logical block blk of 1MB, offset $12340
      want = {desc[31:8], 8'h00} + 32'h00012340;
      xlate({8'h00, blk[3:0], 20'h12340}, 3'd5, 1, 0, want, desc[6], "24-bit block");
    end
    $display("---- walker reads for 16 first-touch blocks: %0d", walker_reads - reads_before);
    if (walker_reads - reads_before != 16) begin
      fails = fails + 1;
      $display("FAIL expected exactly 16 walker reads, one early-terminating descriptor per block");
    end
    // The same 16 blocks with junk in the top byte.  IS=8 makes the walk
    // ignore it, so the translation is the same - but UM 9.7.3 (TC, Initial
    // Shift): "all 32 bits of the address are compared during address
    // translation, bits ignored due to initial shift cannot have random
    // values ... in order to ensure that subsequent address translations
    // match the corresponding entries in the ATC."  So each distinct top
    // byte is an ATC miss and a fresh walk: 16 more reads, not 0.  That is
    // what a 24-bit System with flag bits in the top byte costs on real
    // silicon: correct translation, one ATC entry per distinct value.
    note("2a. same blocks, top byte $A5: same translation, but 16 fresh walks (UM 9.7.3)");
    reads_before = walker_reads;
    for (blk = 0; blk < 16; blk = blk + 1) begin
      desc = rom32(tbl + 4 * blk);
      want = {desc[31:8], 8'h00} + 32'h00012340;
      xlate({8'hA5, blk[3:0], 20'h12340}, 3'd5, 1, 0, want, desc[6], "24-bit block, top byte junk (IS=8)");
    end
    if (walker_reads - reads_before != 16) begin
      fails = fails + 1;
      $display("FAIL expected 16 walker reads for 16 new ATC tags, got %0d", walker_reads - reads_before);
    end
    // And an ATC hit, to show the walks above were misses and not a walker
    // that never caches: the access just made, repeated, must not walk.
    reads_before = walker_reads;
    xlate(32'hA5F12340, 3'd5, 1, 0, 32'h50F12340, 1'b1, "repeat of the last access: ATC hit");
    if (walker_reads != reads_before) begin
      fails = fails + 1;
      $display("FAIL a repeated access walked again - the ATC is not retaining entries");
    end

    // ------------------------------------------- 2b. specific addresses
    // The block map 1.11 tabulates, as the ROM and System will use it.
    // The ATC tag also carries the function code (UM 9.4, Figure 9-22), so
    // a supervisor-fetch or user-data access to a block already cached for
    // supervisor data is a fresh walk.  The 32 fills above also exceed the
    // 22-entry ATC, so some of these walk on eviction too; the walk trace
    // shows which, and none of it is a fault.
    note("2b. 24-bit map: named addresses");
    xlate(32'h00800000, 3'd6, 1, 1, 32'h40800000, 1'b0, "ROM at $800000 (supervisor fetch)");
    xlate(32'h00F02000, 3'd5, 1, 0, 32'h50F02000, 1'b1, "VIA2 at $F02000 -> $50F02000, CI");
    xlate(32'h00E00000, 3'd5, 0, 0, 32'hFE000000, 1'b1, "video slot $E -> $FE000000, CI, write");
    xlate(32'h007FFFFE, 3'd1, 1, 0, 32'h007FFFFE, 1'b0, "top of 8MB, user data");
    xlate(32'h00001234, 3'd1, 0, 0, 32'h00001234, 1'b0, "user write to RAM: M pre-set, no writeback");
    xlate(32'h00400000, 3'd2, 1, 1, 32'h00400000, 1'b0, "user program fetch at 4MB");
    reads_before = walker_reads;
    xlate(32'h00400000, 3'd2, 1, 1, 32'h00400000, 1'b0, "user program fetch at 4MB, again: ATC hit");
    if (walker_reads != reads_before) begin
      fails = fails + 1;
      $display("FAIL a repeated user-program fetch walked again");
    end

    // ------------------------------------- 3. the 32-bit row, all 16 blocks
    crp_hi = rom32(ROW32); crp_lo = rom32(ROW32 + 4); tc = rom32(ROW32 + 8);
    $display("---- 3. 32-bit row: CRP %08X%08X TC %08X", crp_hi, crp_lo, tc);
    load_row(crp_hi, crp_lo, tc);
    tbl = crp_lo - ROM_BASE;
    reads_before = walker_reads;
    for (blk = 0; blk < 16; blk = blk + 1) begin
      desc = rom32(tbl + 4 * blk);
      if (desc[1:0] != 2'b01) begin
        fails = fails + 1;
        $display("FAIL 32-bit table entry %0d is not a page descriptor: %08X", blk, desc);
      end
      want = {desc[31:8], 8'h00} + 32'h01234567;     // 256MB blocks: identity
      xlate({blk[3:0], 28'h1234567}, 3'd5, 1, 0, want, desc[6], "32-bit block");
    end
    if (walker_reads - reads_before != 16) begin
      fails = fails + 1;
      $display("FAIL expected 16 walker reads after the ATC flush that PMOVE CRP/TC (FD=0) implies, got %0d",
               walker_reads - reads_before);
    end
    note("3b. 32-bit map: named addresses");
    xlate(32'h40800000, 3'd6, 1, 1, 32'h40800000, 1'b0, "ROM, cacheable");
    xlate(32'h50F02000, 3'd5, 1, 0, 32'h50F02000, 1'b1, "VIA2, CI");
    xlate(32'hFE000000, 3'd5, 0, 0, 32'hFE000000, 1'b1, "video, CI, write");
    xlate(32'h3FFFFFFC, 3'd5, 1, 0, 32'h3FFFFFFC, 1'b0, "top of the 1GB RAM window, cacheable");

    // --------------------------------- 4. back to 24-bit: the SwapMMU dance
    // The ROM flips modes around individual calls (1.11).  The reload must
    // flush the ATC or the old 32-bit identity mapping would answer.
    note("4. reload the 24-bit row: ATC must be flushed by the PMOVEs");
    // Touch two 32-bit-mode entries first so they are certainly in the ATC,
    // then reload; the same two accesses must walk again (flush) and land
    // on the 24-bit answers (new table), not the identity ones.
    xlate(32'h00800000, 3'd6, 1, 1, 32'h00800000, 1'b0, "$800000 identity under the 32-bit row");
    xlate(32'h00F02000, 3'd5, 1, 0, 32'h00F02000, 1'b0, "$F02000 identity under the 32-bit row");
    load_row(rom32(ROW24), rom32(ROW24 + 4), rom32(ROW24 + 8));
    reads_before = walker_reads;
    xlate(32'h00800000, 3'd6, 1, 1, 32'h40800000, 1'b0, "ROM at $800000 again");
    xlate(32'h00F02000, 3'd5, 1, 0, 32'h50F02000, 1'b1, "VIA2 again");
    if (walker_reads - reads_before != 2) begin
      fails = fails + 1;
      $display("FAIL expected both accesses to re-walk after PMOVE CRP/TC with FD=0, got %0d walks",
               walker_reads - reads_before);
    end

    // ----------------------------------- 5. TC=0: what the reset path does
    note("5. TC=0 as at $4083F872: back to identity");
    write_reg(5'b10000, 32'h0, 1'b0, 1'b0);
    repeat (3) @(posedge clk);
    if (tc_enable) begin fails = fails + 1; $display("FAIL tc_enable still set after TC=0"); end
    xlate(32'h00800000, 3'd6, 1, 1, 32'h00800000, 1'b0, "$800000 untranslated");

    // ---------------------------------------------------------- verdict
    if (walker_writes)  begin fails = fails + 1; $display("FAIL walker wrote memory %0d times", walker_writes); end
    if (walker_outside) begin fails = fails + 1; $display("FAIL walker read outside the ROM %0d times", walker_outside); end
    $display("==== walker: %0d reads, %0d writes, %0d outside ROM", walker_reads, walker_writes, walker_outside);
    if (fails == 0) $display("==== PASS: %0d checks, the SE/30 ROM's MMU contract holds on TG68K_PMMU_030", pass);
    else            $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

  // A guard against a PMMU that never answers.
  initial begin
    #2_000_000;
    $display("FAIL timeout");
    $finish;
  end

endmodule
