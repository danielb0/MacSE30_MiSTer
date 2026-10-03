// tb_scc_seam.v - the seam between GLUE (rtl/se30_glue.v) and our 8530
// (rtl/se30_scc.v), SE30_PLAN.md 10.5.4 item 2.  The processor's bus
// cycles are driven as tb_se30_glue drives them (one 68030 cycle per
// call, 8-bit port answered with DSACK0*); a word or longword access is
// the 68030's dynamic bus sizing - one byte cycle per byte, A1:A0
// counting up, the byte always on D31-D24 (UM 7.2.5).  The SCC is wired as
// se30_machine wires it: GLUE's strobe with SCCEN*, A1 = A/B, A2 = D/C.
//
// WHAT THIS PROVES
//   1. the window: $50F04000 reads RR0B, +2 RR0A, +4 B data, +6 A data;
//      the window repeats every 8 bytes (A3 and up ignored by the chip)
//   2. the read byte reaches the processor on D31-D24 as GLUE captures it
//   3. a word write is two byte cycles to one register: a pointer, then
//      the register it points at (the Guide's warning, the SE/30's form)
//   4. back-to-back SCC accesses are held off 2.2 us by GLUE, and the chip
//      takes each once: a FIFO read pops exactly one character
//   5. /INT reaches GLUE as level 4

`timescale 1ns/1ps

module tb_scc_seam;

  reg clk = 0;
  always #31.9149 clk = ~clk;              // 15.6672 MHz; c16_en tied high, as tb_se30_glue
  reg reset_n = 0;

  reg  [31:0] cpu_addr = 0;
  reg         cpu_as_n = 1, cpu_ds_n = 1, cpu_rw_n = 1;
  reg   [1:0] cpu_siz = 2'b01;
  reg   [2:0] cpu_fc = 3'd5;
  reg  [31:0] cpu_dout = 0;
  wire [31:0] cpu_din;
  wire  [1:0] dsack_n;
  wire        berr;
  wire  [2:0] ipl_n;
  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n, fpu_sel;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  wire  [7:0] scc_rdata;
  wire        scc_irq_n, w_req_n;
  reg         hsync_n = 1;

  se30_glue glue (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(32'h0), .ram_ack(1'b0), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(32'h0), .rom_ack(1'b0),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(scc_sel ? scc_rdata : 8'hFF), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .fpu_sel(fpu_sel), .fpu_dsack_n(2'b11), .fpu_rdata(32'h0),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'hFF),
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(scc_irq_n), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(slot_irq_or_n),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(hsync_n));

  // as se30_machine: the strobe qualified by C16M's enable (tied high here)
  se30_scc scc (
    .clk(clk), .c16_en(1'b1), .c3m_en(c3m_en), .reset_n(reset_n),
    .stb(dev_strobe && scc_sel), .rd(dev_rw), .a1(dev_addr[1]), .a2(dev_addr[2]), .wdata(dev_wdata), .rdata(scc_rdata),
    .irq_n(scc_irq_n), .vsync(1'b0), .w_req_n(w_req_n),
    .a_rxd(1'b1), .a_hski(1'b1), .a_gpi(1'b0), .b_rxd(1'b1), .b_hski(1'b1), .b_gpi(1'b0),
    .a_txd(), .a_txd_en(), .a_hsko(), .b_txd(), .b_txd_en(), .b_hsko());

  // HSYNC* for UI6's timeout (as tb_se30_glue)
  integer px = 0;
  always @(posedge clk) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end

  integer checks = 0, fails = 0;
  task check (input cond, input [8*80-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask

  // one 68030 byte cycle; n = its clocks (as tb_se30_glue), rd = the processor's latch
  integer n, strobes = 0, scc_last = -1000, gap_min = 100000, clkn = 0;
  reg [31:0] rd;
  always @(posedge clk) begin
    clkn <= clkn + 1;
    if (dev_strobe && scc_sel) begin
      strobes = strobes + 1;
      if (clkn - scc_last < gap_min) gap_min = clkn - scc_last;
    end
    if (scc_sel) scc_last = clkn;
  end
  task cycle (input read, input [31:0] a, input [7:0] wd);
    integer k;
    begin
      @(posedge clk); #1;
      cpu_addr = a; cpu_rw_n = read; cpu_siz = 2'b01; cpu_dout = {wd, wd, wd, wd};
      cpu_as_n = 0; cpu_ds_n = !read;
      k = 1;
      @(posedge clk); #1; cpu_ds_n = 0;
      while (dsack_n == 2'b11 && !berr && k < 2000) begin k = k + 1; @(posedge clk); #1; end
      n = (k >= 2000) ? -2 : berr ? 0 : k + 2;
      if (n > 0) begin @(posedge clk); #1; rd = cpu_din; end
      cpu_as_n = 1; cpu_ds_n = 1;
      @(posedge clk); #1;
    end
  endtask
  task rb (input [31:0] a); cycle(1, a, 8'h00); endtask
  task wb (input [31:0] a, input [7:0] d); cycle(0, a, d); endtask
  // a word write: the 68030 sizes it into two byte cycles, A0 = 0 then 1
  task ww (input [31:0] a, input [15:0] d); begin wb(a, d[15:8]); wb(a + 1, d[7:0]); end endtask

  integer s0, k;
  initial begin
    $display("tb_scc_seam: GLUE and the 8530");
    repeat (10) @(posedge clk); reset_n = 1; repeat (20) @(posedge clk);

    // 1, 2: the window and the read byte
    rb(32'h50F04000); check(rd[31:24] == 8'h44 && n > 0, "1 $50F04000 = RR0B (44) on D31-D24", rd[31:24], 8'h44);
    rb(32'h50F04002); check(rd[31:24] == 8'h44, "1 $50F04002 = RR0A", rd[31:24], 8'h44);
    wb(32'h50F04000, 8'h0C); wb(32'h50F04000, 8'h5A);           // WR12B = 5A
    wb(32'h50F04002, 8'h0C); wb(32'h50F04002, 8'hA5);           // WR12A = A5
    wb(32'h50F04000, 8'h0C); rb(32'h50F04000); check(rd[31:24] == 8'h5A, "1 RR12B through the pointer", rd[31:24], 8'h5A);
    wb(32'h50F04002, 8'h0C); rb(32'h50F04002); check(rd[31:24] == 8'hA5, "1 RR12A: A1 selects channel A", rd[31:24], 8'hA5);
    wb(32'h50F04008, 8'h0C); rb(32'h50F0400A); check(rd[31:24] == 8'hA5, "1 one pointer for both channels: set through B (+8), read through A (+A) = RR12A", rd[31:24], 8'hA5);
    wb(32'h50F05FF8, 8'h0C); rb(32'h50F05FF8); check(rd[31:24] == 8'h5A, "1 the window repeats: $50F05FF8 is B control", rd[31:24], 8'h5A);

    // 3: a word write is two cycles to one register
    ww(32'h50F04000, 16'h0C_77);                                 // pointer 12, then WR12B = 77
    wb(32'h50F04000, 8'h0C); rb(32'h50F04000); check(rd[31:24] == 8'h77, "3 a word write: pointer then register (two byte cycles, one register)", rd[31:24], 8'h77);

    // 4: back-to-back hold-off; one pop per read (channel A, async x16, local loopback)
    wb(32'h50F04002, 8'h04); wb(32'h50F04002, 8'h44);           // WR4A x16 1 stop
    wb(32'h50F04002, 8'h0B); wb(32'h50F04002, 8'h50);           // WR11A clocks = BRG
    wb(32'h50F04002, 8'h0C); wb(32'h50F04002, 8'h00);           // WR12A
    wb(32'h50F04002, 8'h0D); wb(32'h50F04002, 8'h00);           // WR13A
    wb(32'h50F04002, 8'h0E); wb(32'h50F04002, 8'h13);           // WR14A loopback, BRG from PCLK, on
    wb(32'h50F04002, 8'h03); wb(32'h50F04002, 8'hC1);           // WR3A Rx 8 bits on
    wb(32'h50F04002, 8'h05); wb(32'h50F04002, 8'h68);           // WR5A Tx 8 bits on
    check(gap_min >= 34, "4 back-to-back SCC accesses: GLUE's 2.2 us hold-off (>= 34 clocks)", gap_min, 34);
    wb(32'h50F04006, 8'hC1);
    for (k = 0; k < 200; k = k + 1) begin rb(32'h50F04002); if (rd[26]) k = 1000; end
    wb(32'h50F04006, 8'hC2);
    for (k = 0; k < 400; k = k + 1) begin wb(32'h50F04002, 8'h01); rb(32'h50F04002); if (rd[24]) k = 1000; end   // RR1A All Sent
    repeat (3000) @(posedge clk);
    s0 = strobes;
    rb(32'h50F04006); check(rd[31:24] == 8'hC1 && strobes == s0 + 1, "4 one read, one strobe, one pop: C1", rd[31:24], 8'hC1);
    rb(32'h50F04006); check(rd[31:24] == 8'hC2, "4 the next read: C2 (nothing popped twice)", rd[31:24], 8'hC2);
    rb(32'h50F04002); check(rd[24] == 1'b0, "4 the FIFO is empty", rd[24], 0);

    // 5: /INT at level 4 - a transmit interrupt, MIE
    wb(32'h50F04002, 8'h01); wb(32'h50F04002, 8'h02);           // WR1A Tx IE
    wb(32'h50F04002, 8'h09); wb(32'h50F04002, 8'h08);           // WR9 MIE
    wb(32'h50F04006, 8'h33);
    for (k = 0; k < 2000 && ipl_n != 3'b011; k = k + 1) @(posedge clk);
    check(ipl_n == 3'b011, "5 SCC /INT: IPL level 4", ipl_n, 3'b011);
    wb(32'h50F04002, 8'h28);                                     // Reset Tx Int Pending
    repeat (40) @(posedge clk);
    check(ipl_n == 3'b111, "5 serviced: IPL released", ipl_n, 3'b111);

    $display("tb_scc_seam: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end
  initial begin #50_000_000; $display("TIMEOUT"); $display("==== FAIL"); $finish; end

endmodule
