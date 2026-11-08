// tb_pdma_berr.v - the kernel, the wrapper and GLUE taking a bus error in the
// MIDDLE of a long read from the SCSI handshake window, as NetBSD's ncrscsi
// meets it (SE30_PLAN.md KNOWN ISSUES 62).
//
// WHY
//   NetBSD 11's GENERIC kernel (ncrscsi) hangs at sd0's attach on both
//   cores while the sbc kernel runs.  sim/scsi_seam 10c drives the 53C80
//   and the targets exactly as ncrscsi does and passes; the first thing
//   ncrscsi does at that attach that nothing else does is a SHORT transfer
//   (START UNIT refused, then REQUEST SENSE asking 32 bytes and getting 18)
//   read as "*long_data++ = *long_drq++" from $50006000: the target stops,
//   DRQ never comes, GLUE's UI6 bus-errors the waiting byte cycle, and
//   NetBSD's nofault handler counts the bytes moved as the frame's fault
//   address minus $50006000.  So the bus error falls on any byte of a long
//   the 68030 is reading from an 8-bit port, a byte cycle at a time.
//
// WHAT THIS PROVES (MC68030 User's Manual, 3rd ed.), for K = +K (0-31)
// bytes the target sends before DRQ stops:
//     1. one bus error exception, at the faulted byte cycle: one handler
//        entry, one BERR, vector 2 only ("when a bus error exception occurs
//        while accessing a data item, the exception is taken immediately
//        after the bus cycle terminates", 8.2)
//     2. the long bus fault frame, format $B, its PC the MOVE's
//     3. its SSW: DF, a read, FC 5, and SIZE the bytes still to go at the
//        faulted cycle, 4 - K mod 4 ("byte, word, and 3-byte operands are
//        right-justified", 8.2.2; SIZ is the number of bytes remaining to be
//        transferred, 5.5)
//     4. its data cycle fault address the faulted cycle's, $50006000 + K:
//        where a handler completes "properly sized data" (8.2.2), and
//        NetBSD's count
//     5. the byte cycles before it each ran once: K handshake bytes
//     6. the longs before the faulted one reached the buffer, that one not
//   MMU=1 (gen_program.py) reaches the window through a translated,
//   cache-inhibited logical address, $E0006000, as NetBSD maps its I/O: the
//   fault address is the LOGICAL one; CACHE=1 turns both caches on (CACR
//   $2101).
//   With +K=32 no fault: the 32 bytes land, the run ends after the loop.
//
// CLOCKING AND MEMORY: as sim/busfault_dib (clk 2 x C16M, GLUE on phi1, a
//   32-bit RAM model, HSYNC* as the video PALs make it for UI6).
`timescale 1ns/1ps

module tb_pdma_berr;

  reg clk = 0;
  always #15.9574 clk = ~clk;
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;

  integer K = 18;
  initial if (!$value$plusargs("K=%d", K)) K = 18;

  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        cpu_as_n, cpu_ds_n, cpu_rw_n, berr, reset_out_n, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;
  wire [56:0] exc;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .coff(2'b00), .pace_en(1'b1), .post_en(1'b1), .reset_out_n(reset_out_n), .halted(halted),
    .dbg_exc(exc));

  integer excs = 0, exc2 = 0;
  always @(posedge clk) if (exc[56]) begin
    excs = excs + 1;
    if (exc[55:48] == 8'd2) exc2 = exc2 + 1;
    $display("t=%0t exception: vector %0d, PC %08x", $time, exc[55:48], exc[31:0]);
  end

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

  // the 53C80's DRQ as the bench needs it: up while the target has bytes
  // left (K); the byte, $A0 + its index
  integer given = 0;
  wire       drq = (given < K);
  wire [7:0] hs_byte = 8'hA0 + given[7:0];

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
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(hs_byte), .scsi_drq(drq),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  // a handshake byte is taken at its device strobe
  integer hs_cycles = 0;
  always @(posedge clk) if (phi1 && dev_strobe && scsi_dack) begin
    $display("t=%0t handshake byte %0d at %08x siz %b: %02x", $time, given, cpu_addr, cpu_siz, hs_byte);
    given = given + 1; hs_cycles = hs_cycles + 1;
  end

  integer px = 0;
  always @(posedge clk) if (phi1) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

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

  integer berrs = 0; reg berr_q = 0;
  always @(posedge clk) begin
    berr_q <= berr;
    if (berr && !berr_q) begin
      berrs = berrs + 1;
      $display("t=%0t BERR: addr %08x fc %0d rw %b siz %b", $time, cpu_addr, cpu_fc, cpu_rw_n, cpu_siz);
    end
  end

  integer pass = 0, fails = 0;
  task check(input cond, input [8*104-1:0] what, input [31:0] got, input [31:0] want);
    begin
      if (cond) begin pass = pass + 1; $display("pass %0s: %08x", what, got); end
      else begin fails = fails + 1; $display("FAIL %0s: got %08x, want %08x", what, got, want); end
    end
  endtask

  integer n, fd, r, b, full, bad;
  reg [31:0] move_pc, lbase, endcode, ent, fpc, fa, a0, a1;
  reg [15:0] fv, ssw;
  reg  [1:0] wsiz;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 32768; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    fd = $fopen("layout.txt", "r"); r = $fscanf(fd, "%h %h", move_pc, lbase); $fclose(fd);
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0;
    while (ram[32'h3FF0 >> 2] == 0 && !halted && n < 2_000_000) begin @(posedge clk); n = n + 1; end
    repeat (40) @(posedge clk);
    endcode = ram[32'h3FF0 >> 2]; ent = ram[32'h3020 >> 2]; fpc = ram[32'h3024 >> 2];
    fv = ram[32'h3028 >> 2][31:16]; ssw = ram[32'h3028 >> 2][15:0]; fa = ram[32'h302C >> 2];
    a0 = ram[32'h3030 >> 2]; a1 = ram[32'h3034 >> 2];
    $display("---- K=%0d: %0d clocks; end %08x; %0d entries, %0d BERRs, %0d handshake bytes; frame PC %08x fmt %04x SSW %04x fault %08x; A0 %08x A1 %08x",
             K, n, endcode, ent, berrs, hs_cycles, fpc, fv, ssw, fa, a0, a1);
    check(!halted, "no double bus fault", halted, 0);
    if (K >= 32) begin
      check(endcode == 32'h600D0001, "no fault: the loop ran to its end", endcode, 32'h600D0001);
      check(berrs == 0 && excs == 0, "no bus error, no exception", berrs, 0);
      full = 8;
    end else begin
      wsiz = (K % 4 == 0) ? 2'b00 : (4 - K % 4);   // SIZE: 1 byte 01, 2 bytes 10, 3 bytes 11, 4 bytes 00
      check(endcode == 32'h600D0002, "the run ends on the handler's path", endcode, 32'h600D0002);
      check(ent == 1 && exc2 == 1 && excs == 1, "1. one handler entry, one vector-2 exception, no other", {ent[15:0], excs[15:0]}, 32'h00010001);
      check(berrs == 1, "1. one BERR", berrs, 1);
      check(fv == 16'hB008, "2. the long bus fault frame, format $B, vector offset $008", fv, 16'hB008);
      check(fpc == move_pc, "2. its PC is the MOVE's", fpc, move_pc);
      check(ssw[8] == 1 && ssw[6] == 1 && ssw[2:0] == 3'd5, "3. SSW: DF, a read, FC 5", ssw, 16'h0145);
      check(ssw[5:4] == wsiz, "3. SSW SIZE: the bytes still to go at the faulted cycle", ssw[5:4], wsiz);
      check(fa == lbase + K, "4. the data cycle fault address is the faulted cycle's logical address (base + K: NetBSD's count)", fa, lbase + K);
      check(hs_cycles == K, "5. the byte cycles before it ran once each", hs_cycles, K);
      full = K / 4;
    end
    bad = 0;
    for (b = 0; b < 4 * full; b = b + 1) if (ram[(32'h5000 + b) >> 2][31 - 8 * (b % 4) -: 8] !== (8'hA0 + b)) bad = bad + 1;
    check(bad == 0, "6. the longs before the faulted one reached the buffer", bad, 0);
    if (K < 32) check(ram[(32'h5000 + 4 * full) >> 2] == 0, "6. the faulted long did not", ram[(32'h5000 + 4 * full) >> 2], 0);
    if (fails == 0) $display("==== PASS: %0d checks - K=%0d", pass, K);
    else $display("==== FAIL: %0d failures, %0d passes - K=%0d", fails, pass, K);
    $finish;
  end

endmodule
