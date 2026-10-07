// tb_cpu_int.v - the 68030 integer corpus (SE30_PLAN.md 1.18.6): WinUAE
// cputest rounds run as programs on the kernel, the wrapper and GLUE, as
// tools/cputest/harness_i.py builds them.
//
// WHAT THIS PROVES (when it passes)
//   Every round in the batch ran from the registers, SR and memory WinUAE's
//   68030 started from and left the registers, SR (the CCR in user mode)
//   and the bytes it wrote as WinUAE's did: program.hex runs to its end
//   marker ($600D0001 at $9FF0) without an unexpected exception (a stub
//   writes $DEADxxxx there, xxxx the vector), and every line of expect.txt
//   (address, value, mask) holds.
//
// CLOCKING AND MEMORY: as sim/cpfpu (clk 2 x C16M, GLUE on phi1), with
//   8 MB of RAM decoded in full (GLUE's RAMSIZ 01: 4 MB banks, no
//   aliasing), so each round runs at its own addresses: the generator's
//   test memory ($500000-$6FFFFF) and low memory ($0-$7FFF).  program.hex
//   is the first 128 KB.  No FPU: the integer presets have no F-line.
//   +trace prints bus cycles (the first +ntr=N, 400 by default).

`timescale 1ns/1ps

module tb_cpu_int;

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
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .pace_en(1'b1), .post_en(1'b1),
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
  reg [15:0] img [0:65535];
  reg [31:0] ram [0:2097151];
  integer i;
  always @(posedge clk) if (phi1) begin
    ram_ack <= 0;
    if (ram_req && !ram_ack) begin
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

  reg trace_on = 0;
  integer ntr = 0, ntrmax = 400;
  initial begin trace_on = $test$plusargs("trace"); if ($value$plusargs("ntr=%d", ntrmax)) ; end
  always @(posedge clk) if (trace_on && phi1 && !cpu_as_n && (dsack_n != 2'b11 || berr) && ntr < ntrmax) begin
    ntr = ntr + 1;
    $display("t=%0t %s %08x fc=%0d siz=%0d %s=%08x dsack=%b berr=%b", $time,
             cpu_rw_n ? "R" : "W", cpu_addr, cpu_fc, cpu_siz, cpu_rw_n ? "din" : "dout",
             cpu_rw_n ? cpu_din : cpu_dout, dsack_n, berr);
  end

  integer pass = 0, fails = 0, n, fd, r, stuck;
  reg [31:0] last;
  reg [31:0] a, want, mask, v;
  initial begin
    $readmemh("program.hex", img);
    for (i = 0; i < 2097152; i = i + 1) ram[i] = 32'h0;
    for (i = 0; i < 32768; i = i + 1) ram[i] = {img[2*i], img[2*i+1]};
    repeat (20) @(posedge clk);
    reset_n = 1;
    n = 0; last = 32'hFFFFFFFF; stuck = 0;
    // a watchdog per round: a round that leaves the harness (a branch into
    // stale bytes, a loop) would otherwise run to the clock limit
    while (ram[32'h9FF0 >> 2] == 32'h0 && !halted && stuck < 50000) begin
      @(posedge clk); n = n + 1;
      if (ram[32'h9FF4 >> 2] != last) begin last = ram[32'h9FF4 >> 2]; stuck = 0; end
      else stuck = stuck + 1;
    end
    repeat (200) @(posedge clk);
    v = ram[32'h9FF0 >> 2];
    $display("---- the run: %0d clocks, marker %08x, last round %0d", n, v, ram[32'h9FF4 >> 2]);
    if (halted) begin fails = fails + 1; $display("FAIL: the CPU halted (double bus fault)"); end
    if (stuck >= 50000) begin fails = fails + 1; $display("FAIL: round %0d never came back (50,000 clocks)", ram[32'h9FF4 >> 2]); end
    if (v[31:16] == 16'hDEAD) begin
      fails = fails + 1;
      $display("FAIL: exception vector %0d taken in round %0d", v[7:0], ram[32'h9FF4 >> 2]);
    end else if (v != 32'h600D0001) begin
      fails = fails + 1; $display("FAIL: the end marker never written");
    end
    fd = $fopen("expect.txt", "r");
    while (!$feof(fd)) begin
      r = $fscanf(fd, "%h %h %h\n", a, want, mask);
      if (r == 3) begin
        v = ram[a[22:2]];
        if ((v & mask) === (want & mask)) pass = pass + 1;
        else begin fails = fails + 1; $display("FAIL $%06x: %08x, expected %08x (mask %08x)", a, v, want, mask); end
      end
    end
    $fclose(fd);
    if (fails == 0) $display("==== PASS: %0d checks - every round as WinUAE's 68030", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
