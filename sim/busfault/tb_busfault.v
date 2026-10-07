// tb_busfault.v - the kernel, the wrapper and GLUE taking the SE/30 ROM's
// empty-slot bus error, and returning from it, as the MC68030 does.
//
// WHY
//   Compile 15 on the board (SE30_PLAN.md 5.11 item 5): the ROM's Slot
//   Manager reads $F9FFFFFF with its own bus-error handler in vector 2;
//   the handler RTEs to re-run the read 100 times, then discards a
//   92-byte frame and RTEs to a continuation.  Ours resumed four bytes
//   past the faulting instruction and died in System Error 3.
//
// WHAT THIS PROVES (MC68030 User's Manual, 3rd ed., section 8)
//     1. the run ends on the ROM's path: the continuation, not an
//        unexpected exception (the stub markers $DEADxxxx), not a halt
//     2. the read faults once per RTE: N handler entries and N bus errors
//        on $F9FFFFFF - "if the DF bit is set when the processor reads the
//        stack frame, it reruns the faulted data access" (8.2.1, 8.2.3)
//     3. the frame is the LONG bus fault frame: "data read faults only
//        generate the long bus fault frame" (8.2.2) - format $B, vector
//        offset $008, 46 words = 92 bytes below the SP (8.4, Table 8-7)
//     4. its PC is the faulting instruction's address - "the logical
//        address of the instruction that was executing at the time the
//        fault was detected" (8.1.2)
//     5. its SSW (+$0A) says a data read fault: DF (bit 8) set, RW (6)
//        read, SIZE (5-4) byte, FC (2-0) supervisor data (8.2.1)
//     6. its data cycle fault address (+$10) is $F9FFFFFF (8.4)
//     7. after the handler's unwind (adda.w #$5C) the SP is where it was
//        before the fault: the ROM's own check that the frame is 92 bytes
//
//   The frame is captured as the kernel writes it: every supervisor-data
//   write from the first bus error until the handler's first fetch.
//
// CLOCKING AND MEMORY: as sim/system (tb_se30_system.v): clk 2 x C16M,
//   GLUE on phi1, a 32-bit RAM model acknowledging a clock after the
//   request.  GLUE's UI6 timeout raises BERR on the slot read, clocked by
//   an HSYNC* made here as the video PALs make it.

`timescale 1ns/1ps

module tb_busfault;

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
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
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

  // ---------------------------------------------- the frame, as written
  // every supervisor-data write from the first bus error until the
  // handler's first fetch, by byte address (the RAM model's lanes)
  reg [31:0] probe_pc, h_pc, c_pc; integer n_ret, is_wr;
  reg  [7:0] fbyte [0:32767];
  reg        fset  [0:32767];
  integer    berrs = 0, fetch_h = 0, lo = 32'h7FFFFFFF;
  reg        capturing = 0, captured = 0, berr_q = 0, as_q = 1;
  reg [31:0] a; integer b;
  // BERR can be shorter than a C16M period (GLUE drops it with AS*): seen on every clk
  always @(posedge clk) begin
    berr_q <= berr;
    if (berr && !berr_q) $display("t=%0t BERR: addr %08x fc %0d rw %b siz %b", $time, cpu_addr, cpu_fc, cpu_rw_n, cpu_siz);
    if (berr && !berr_q && cpu_addr == 32'hF9FFFFFF) begin
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
  integer n, fd, r; reg [31:0] endcode, sp0, sp1, count, ssw;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 32768; i = i + 1) begin ram[i] = {img[2*i], img[2*i+1]}; fset[i] = 0; fbyte[i] = 0; end
    fd = $fopen("layout.txt", "r"); r = $fscanf(fd, "%h %h %h %d %d", probe_pc, h_pc, c_pc, n_ret, is_wr); $fclose(fd);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (ram[32'h3FF0 >> 2] == 0 && !halted && n < 4_000_000) begin @(posedge clk); n = n + 1; end
    repeat (40) @(posedge clk);
    endcode = ram[32'h3FF0 >> 2]; sp0 = ram[32'h3010 >> 2]; sp1 = ram[32'h3018 >> 2]; count = ram[32'h3020 >> 2];
    $display("---- %0d clocks; end %08x; %0d handler entries, %0d bus errors on $F9FFFFFF; SP before %08x, after the unwind %08x",
             n, endcode, count, berrs, sp0, sp1);

    // 1. the ROM's path
    check(!halted, "no double bus fault", halted, 0);
    check(endcode == 32'h600D0002, "the run ends at the ROM's continuation", endcode, 32'h600D0002);
    // 2. rerun
    check(count == n_ret, "one handler entry per RTE: the read re-run and faulted again", count, n_ret);
    check(berrs == n_ret, "one bus error on $F9FFFFFF per entry", berrs, n_ret);
    // 3-6. the first frame
    $display("---- the first frame as written: %0d bytes, from %08x", sp0 - lo, lo);
    for (b = 0; b < 92 && lo + b < sp0; b = b + 16)
      $display("     +%02x: %04x %04x %04x %04x %04x %04x %04x %04x", b,
               fw(b), fw(b+2), fw(b+4), fw(b+6), fw(b+8), fw(b+10), fw(b+12), fw(b+14));
    check(sp0 - lo == 92, "the frame is 92 bytes: the long bus fault frame", sp0 - lo, 92);
    check(fw(6) == 16'hB008, "format $B, vector offset $008", fw(6), 16'hB008);
    check({fw(2), fw(4)} == probe_pc, "the PC is the faulting instruction's", {fw(2), fw(4)}, probe_pc);
    ssw = fw(10);
    check(ssw[8] == 1, "SSW DF: a data fault", ssw, 32'h0100);
    check(ssw[6] == !is_wr && ssw[5:4] == 2'b01 && ssw[2:0] == 3'd5, "SSW: a byte read (WRITE=1: a byte write, RW=0) in supervisor data space", ssw, is_wr ? 32'h0115 : 32'h0155);
    check({fw(16), fw(18)} == 32'hF9FFFFFF, "the data cycle fault address is $F9FFFFFF", {fw(16), fw(18)}, 32'hF9FFFFFF);
    // 7. the unwind
    check(sp1 == sp0, "the SP after the ROM's $5C unwind is the SP before the fault", sp1, sp0);
    // 8. the probe deck's exception pulse (plan 5.12.12 item 8)
    check(exc2 == n_ret, "the exception pulse: once per bus error, vector 2", exc2, n_ret);
    check(excs == exc2, "and no other exception taken", excs, exc2);
    check(exc_pc0 == probe_pc, "its PC: the faulting instruction's, as stacked", exc_pc0, probe_pc);

    if (fails == 0) $display("==== PASS: %0d checks - the empty-slot bus error returns as the MC68030's", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
