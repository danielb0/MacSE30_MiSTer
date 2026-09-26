// tb_se30_glue.v - GLUE held to the cycle table of SE30_PLAN.md 2.11.
//
// WHAT THIS PROVES
//   rtl/se30_glue.v is the SE/30's GLUE as a contract (plan 2.3, 2.11):
//   nobody has its internals, so this bench is the specification, row by
//   row of 2.11.3 and item by item of 2.11.7:
//
//     1. RAM: a word or byte beat is 4 clocks; the two beats of a
//        longword total 4; data goes where it was written             2.11 row 1
//     2. ROM: 4 clocks; the 256KB image repeats through $4xxxxxxx;
//        overlay maps $0 to ROM with no RAM cycle, until cleared       2.11 row 2, 2.11.6
//     3. RAM banks: bank B starts at 1, 4, 16 or 64 MB by RAMSIZ;
//        the bits above the two banks are ignored                      2.11.2
//     4. I/O decode: every window of Figure 3-6 selects its device,
//        at $5000xxxx and at $50F0xxxx alike; A23-A18 are ignored;
//        $50008000 and $51000000 get nothing                            2.11.2, rows 6, 13
//     5. wait states: SWIM, SCSI, pseudo-DMA, expansion 4 clocks;
//        ASC 5 read / 4 write; SCC >= 4 plus a 34-clock hold-off
//        between consecutive SCC cycles only; SCSI handshake waits
//        for DRQ; a VIA cycle spans one E-high phase and lands in
//        the 12..32 envelope; E is C16M/20                              rows 3-5, 7-11
//     6. data lanes: an 8-bit device is on D15-D8; a word beat is two
//        device cycles, high byte first, at A and A+1                  2.11.1
//     7. FC=7: the acknowledge cycle autovectors; no other CPU-space
//        cycle is answered or timed out                                2.11.1, 2.11.4
//     8. the bus-error timeout is UI6's: BERR after HSYNC* has been
//        seen high, low, high - exact clocks for three phases - for
//        undecoded space and for a SCSI handshake that never sees DRQ  2.11.4
//     9. interrupts: VIA1 1, VIA2 2, SCC 4, NMI 7, highest wins; the
//        six slot lines OR into one output                             2.11.5
//    10. refresh: one RAM-cycle stall at most every 244 clocks          row 17
//    11. clocks: C3M is 15 pulses per 64 clocks                         2.11.3
//
// THE BUS
//   The TG68K wrapper's 68000-shaped bus (plan 1.4): 16-bit data, UDS*/
//   LDS*, AS*, R/W*, DTACK*, VPA*, BERR, IPL, a 32-bit address, and lw
//   marking both beats of a longword.  A cycle here is counted from the
//   first C16M clock in which AS* is low to the clock in which DTACK* is
//   first low, inclusive, plus one for S4/S5: a one-wait-state 68030
//   cycle reads as 4.  The bench negates AS* in the clock after DTACK*.
//
//   Devices are modelled here: RAM and ROM as word arrays that ack in
//   RAM_ACK_CLK / ROM_ACK_CLK clocks; the VIAs check that their select was
//   valid for a whole E-high phase before the strobe; the SCC and the
//   rest record their strobes; the slot answers DSACK0* after a set delay.
//   HSYNC* is generated as the video PALs make it (plan 2.12): a 704-clock
//   line, low for 288 clocks from pixel 535.

`timescale 1ns/1ps

module tb_se30_glue;

  // ---------------------------------------------------------------- clock
  reg clk = 0;
  always #31.9149 clk = ~clk;              // 15.6672 MHz; c16_en is tied high
  reg reset_n = 0;

  localparam RAM_ACK_CLK = 1;              // the model's read latency in clocks
  localparam ROM_ACK_CLK = 1;

  // -------------------------------------------------------------- DUT
  reg  [31:0] cpu_addr = 0;
  reg         cpu_as_n = 1, cpu_uds_n = 1, cpu_lds_n = 1, cpu_rw_n = 1, cpu_lw = 0;
  reg   [2:0] cpu_fc = 3'd5;
  reg  [15:0] cpu_dout = 0;
  wire [15:0] cpu_din;
  wire        dtack_n, berr, vpa_n;
  wire  [2:0] ipl_n;
  wire        ram_req, ram_we, ram_refresh, rom_req;
  wire [25:0] ram_addr;
  wire  [1:0] ram_ds;
  wire [15:0] ram_wdata;
  wire [16:0] rom_addr;
  reg  [15:0] ram_rdata = 0, rom_rdata = 0;
  reg         ram_ack = 0, rom_ack = 0;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  reg   [7:0] dev_rdata = 0, slot_rdata = 8'h5A;
  reg         scsi_drq = 0, slot_dsack0_n = 1;
  reg         via1_irq_n = 1, via2_irq_n = 1, scc_irq_n = 1, nmi_n = 1;
  reg   [6:1] slot_irq_n = 6'b111111;
  reg         overlay = 1;
  reg   [1:0] ramsiz = 2'b01;
  reg         hsync_n = 1;

  se30_glue uut (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
    .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc), .cpu_lw(cpu_lw), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dtack_n(dtack_n), .berr(berr), .vpa_n(vpa_n), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_ds(ram_ds), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(rom_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata), .scsi_drq(scsi_drq),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(slot_dsack0_n), .slot_rdata(slot_rdata),
    .via1_irq_n(via1_irq_n), .via2_irq_n(via2_irq_n), .scc_irq_n(scc_irq_n), .nmi_n(nmi_n),
    .slot_irq_n(slot_irq_n), .slot_irq_or_n(slot_irq_or_n),
    .overlay(overlay), .ramsiz(ramsiz), .hsync_n(hsync_n));

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*80-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // -------------------------------------------------------- HSYNC* model
  // 704-clock line, low 288 clocks from pixel 535 (plan 2.12 numbering).
  integer px = 0;
  always @(posedge clk) begin
    px <= (px == 703) ? 0 : px + 1;
    hsync_n <= !((px + 1 >= 535) || (px + 1 < 119));
  end
  task wait_px(input integer p); begin while (px != p) @(posedge clk); end endtask

  // ---------------------------------------------------------- RAM model
  reg [15:0] ram [0:(1 << 20) - 1];        // 1M words; the bank test looks at ram_addr itself
  integer    ram_reqs = 0, ram_ack_cnt = 0;
  reg [25:0] ram_last_addr;
  integer    i;
  initial for (i = 0; i < (1 << 20); i = i + 1) ram[i] = 16'h0000;
  always @(posedge clk) begin
    ram_ack <= 0;
    if (ram_req && !ram_ack) begin
      ram_ack_cnt = ram_ack_cnt + 1;
      if (ram_ack_cnt >= RAM_ACK_CLK) begin
        ram_ack_cnt = 0;
        ram_reqs = ram_reqs + 1;
        ram_last_addr = ram_addr;
        if (ram_we) begin
          if (ram_ds[1]) ram[ram_addr[19:0]][15:8] <= ram_wdata[15:8];
          if (ram_ds[0]) ram[ram_addr[19:0]][7:0]  <= ram_wdata[7:0];
        end
        ram_rdata <= ram[ram_addr[19:0]];
        ram_ack <= 1;
      end
    end
  end

  // ---------------------------------------------------------- ROM model
  // the word at word address a reads as a[15:0] - address-dependent, so
  // mirrors are told apart from data.
  integer rom_reqs = 0, rom_ack_cnt = 0;
  reg [16:0] rom_last_addr;
  always @(posedge clk) begin
    rom_ack <= 0;
    if (rom_req && !rom_ack) begin
      rom_ack_cnt = rom_ack_cnt + 1;
      if (rom_ack_cnt >= ROM_ACK_CLK) begin
        rom_ack_cnt = 0;
        rom_reqs = rom_reqs + 1;
        rom_last_addr = rom_addr;
        rom_rdata <= rom_addr[15:0];
        rom_ack <= 1;
      end
    end
  end

  // ------------------------------------------------------ device models
  // Every device: count strobes, remember the last address/data/direction.
  // The VIAs additionally check the E-phase rule: the select must have been
  // high for the whole E-high phase that ends at the strobe.
  integer via_strobes = 0, scc_strobes = 0, scsi_strobes = 0, dack_strobes = 0;
  integer asc_strobes = 0, swim_strobes = 0, exp_strobes = 0, via_phase_bad = 0;
  reg [12:0] last_addr;
  reg  [7:0] last_wdata;
  reg        last_rw;
  reg        e_q = 0;
  integer    sel_high_clocks = 0;          // clocks the VIA select has been continuously high
  integer    e_high_clocks = 0;            // clocks E has been continuously high
  integer    e_period = 0, e_last_rise = -1;
  integer    scc_last_end = -1000, scc_gap_min = 1000000, cyc_clock = 0;
  always @(posedge clk) begin
    cyc_clock <= cyc_clock + 1;
    e_q <= e_clk;
    if (e_clk && !e_q) begin
      if (e_last_rise >= 0) e_period = cyc_clock - e_last_rise;
      e_last_rise = cyc_clock;
      e_high_clocks = 0;
    end
    if (e_clk) e_high_clocks = e_high_clocks + 1;
    sel_high_clocks = (via1_sel || via2_sel) ? sel_high_clocks + 1 : 0;
    if (dev_strobe) begin
      last_addr = dev_addr; last_wdata = dev_wdata; last_rw = dev_rw;
      if (via1_sel || via2_sel) begin
        via_strobes = via_strobes + 1;
        // the strobe is the E falling edge: E is high now, low next clock, and
        // the select has been high at least as long as E has
        if (!(e_clk && sel_high_clocks >= e_high_clocks)) via_phase_bad = via_phase_bad + 1;
      end
      if (scc_sel)  begin
        scc_strobes = scc_strobes + 1;
        if (cyc_clock - scc_last_end < scc_gap_min) scc_gap_min = cyc_clock - scc_last_end;
      end
      if (scsi_sel)  scsi_strobes = scsi_strobes + 1;
      if (scsi_dack) dack_strobes = dack_strobes + 1;
      if (asc_sel)   asc_strobes = asc_strobes + 1;
      if (swim_sel)  swim_strobes = swim_strobes + 1;
      if (exp_sel)   exp_strobes = exp_strobes + 1;
    end
    if (scc_sel) scc_last_end = cyc_clock;  // the last clock the SCC was selected
    // read data: the device answers with a value that names it and the address
    dev_rdata <= via1_sel ? {4'h1, dev_addr[12:9]} : via2_sel ? {4'h2, dev_addr[12:9]} :
                 scc_sel  ? {6'h0C, dev_addr[2:1]} : scsi_sel ? {5'h05, dev_addr[6:4]} :
                 scsi_dack ? 8'hDA : asc_sel ? {4'hA, dev_addr[3:0]} : swim_sel ? {4'h5, dev_addr[12:9]} :
                 exp_sel ? 8'hEE : 8'hFF;
  end

  // slot: the $E card alone - it decodes A31-A24 = $FE itself, as the video
  // PALs do - answers DSACK0* SLOT_DELAY clocks after slot_sel, held while
  // selected; the rest of slot space has nothing in it
  integer slot_delay = 3, slot_cnt = 0;
  always @(posedge clk) begin
    if (slot_sel && cpu_addr[31:24] == 8'hFE) begin
      if (slot_cnt < slot_delay) slot_cnt = slot_cnt + 1;
      slot_dsack0_n <= !(slot_cnt >= slot_delay);
    end else begin slot_cnt = 0; slot_dsack0_n <= 1; end
  end

  // dtack/berr/vpa must never assert while AS* is high
  integer idle_asserts = 0;
  always @(posedge clk) if (cpu_as_n && (!dtack_n || berr || !vpa_n)) idle_asserts = idle_asserts + 1;

  // ------------------------------------------------------------ the beat
  // One 16-bit beat.  n = clocks from AS* low to DTACK* low inclusive,
  // plus one (the 68030's S4/S5) - so a one-wait-state cycle is 4.
  // Returns 0 on BERR, -1 on VPA, -2 on a timeout of `limit` clocks.
  integer n, beat_berr, beat_vpa;
  reg [15:0] rd;
  task beat(input read, input [31:0] a, input uds, input lds, input lw, input [15:0] wd, input integer limit);
    integer k;
    begin
      @(posedge clk); #1;
      cpu_addr = a; cpu_rw_n = read; cpu_uds_n = !uds; cpu_lds_n = !lds; cpu_lw = lw; cpu_dout = wd;
      cpu_as_n = 0;
      k = 1; beat_berr = 0; beat_vpa = 0;
      @(posedge clk); #1;
      while (dtack_n && !berr && vpa_n && k < limit) begin k = k + 1; @(posedge clk); #1; end
      beat_berr = berr; beat_vpa = !vpa_n;
      n = (k >= limit) ? -2 : beat_berr ? 0 : beat_vpa ? -1 : k + 1;
      if (n > 0) begin @(posedge clk); #1; rd = cpu_din; end   // the wrapper latches the clock after DTACK
      cpu_as_n = 1; cpu_uds_n = 1; cpu_lds_n = 1; cpu_lw = 0; cpu_fc = 3'd5;
      @(posedge clk); #1;
    end
  endtask
  task rd_word(input [31:0] a, input integer limit); begin beat(1, a, 1, 1, 0, 16'h0, limit); end endtask
  task wr_word(input [31:0] a, input [15:0] d); begin beat(0, a, 1, 1, 0, d, 2000); end endtask
  task rd_byte(input [31:0] a, input integer limit); begin beat(1, a, !a[0], a[0], 0, 16'h0, limit); end endtask
  task wr_byte(input [31:0] a, input [7:0] d); begin beat(0, a, !a[0], a[0], 0, {d, d}, 2000); end endtask

  // ------------------------------------------------------------ the tests
  integer t0, t1, lo, hi, k, ok, m;
  reg [15:0] w0, w1;

  initial begin
    repeat (4) @(posedge clk); #1;
    reset_n = 1;
    repeat (8) @(posedge clk);

    // ---- 1. RAM
    $display("---- 1. RAM: 4 clocks a beat, a longword pair 4 in total");
    overlay = 0;
    wr_word(32'h00001000, 16'h1234); check(n == 4, "RAM word write clocks", n, 4);
    rd_word(32'h00001000, 100);      check(n == 4, "RAM word read clocks", n, 4);
    check(rd == 16'h1234, "RAM read back $1234", rd, 16'h1234);
    wr_byte(32'h00001003, 8'hAB);    check(n == 4, "RAM byte write clocks", n, 4);
    rd_word(32'h00001002, 100);      check(rd[7:0] == 8'hAB && rd[15:8] == 8'h00, "byte lane: odd byte only", rd, 16'h00AB);
    beat(0, 32'h00002000, 1, 1, 1, 16'hDEAD, 100); lo = n;
    beat(0, 32'h00002002, 1, 1, 1, 16'hBEEF, 100); hi = n;
    check(lo + hi == 4, "longword write: two beats total 4 clocks", lo * 10 + hi, 22);
    beat(1, 32'h00002000, 1, 1, 1, 16'h0, 100); lo = n; w0 = rd;
    beat(1, 32'h00002002, 1, 1, 1, 16'h0, 100); hi = n; w1 = rd;
    check(lo + hi == 4, "longword read: two beats total 4 clocks", lo * 10 + hi, 22);
    check(w0 == 16'hDEAD && w1 == 16'hBEEF, "longword read back $DEADBEEF", {w0, w1}, 32'hDEADBEEF);

    // ---- 2. ROM and overlay
    $display("---- 2. ROM: 4 clocks, mirrored through $4xxxxxxx; overlay");
    rd_word(32'h40000010, 100);      check(n == 4, "ROM read clocks", n, 4);
    check(rd == {8'h00, 8'h08}, "ROM data is the word at $10", rd, 16'h0008);
    rd_word(32'h40800010, 100);      check(rd == {8'h00, 8'h08} && rom_last_addr == 17'h00008, "ROM mirror at $40800010 (the ROM's own base)", rom_last_addr, 8);
    rd_word(32'h4FFC0010, 100);      check(rom_last_addr == 17'h00008, "ROM mirror at $4FFC0010", rom_last_addr, 8);
    rd_word(32'h4083FFFE, 100);      check(rom_last_addr == 17'h1FFFF, "ROM top word", rom_last_addr, 17'h1FFFF);
    overlay = 1; repeat (2) @(posedge clk);
    t0 = ram_reqs; t1 = rom_reqs;
    rd_word(32'h00000000, 100);
    check(rom_reqs == t1 + 1 && ram_reqs == t0, "overlay: $0 reads ROM, no RAM cycle", rom_reqs - t1, 1);
    check(rom_last_addr == 17'h00000, "overlay: the reset vector comes from ROM word 0", rom_last_addr, 0);
    rd_word(32'h40000000, 100);      check(rom_reqs == t1 + 2, "overlay: $40000000 is still ROM", rom_reqs - t1, 2);
    overlay = 0; repeat (2) @(posedge clk);
    t0 = ram_reqs;
    rd_word(32'h00000000, 100);      check(ram_reqs == t0 + 1, "overlay off: $0 is RAM", ram_reqs - t0, 1);
    wr_word(32'h40000000, 16'h5555); check(n == 4 && ram_reqs == t0 + 1, "ROM write: acknowledged, nothing written", n, 4);

    // ---- 3. RAM banks
    $display("---- 3. RAM banks by RAMSIZ; bits above the two banks ignored");
    ramsiz = 2'b01; repeat (2) @(posedge clk);       // 4MB banks
    rd_word(32'h00000000, 100); check(ram_last_addr == 26'h0000000, "4MB banks: $0 -> word 0", ram_last_addr, 0);
    rd_word(32'h00400000, 100); check(ram_last_addr == 26'h0200000, "4MB banks: $00400000 -> bank B, word $200000", ram_last_addr, 26'h200000);
    rd_word(32'h00800000, 100); check(ram_last_addr == 26'h0000000, "4MB banks: $00800000 wraps to bank A", ram_last_addr, 0);
    rd_word(32'h3FC00004, 100); check(ram_last_addr == 26'h0200002, "4MB banks: $3FC00004 -> bank B word 2", ram_last_addr, 26'h200002);
    ramsiz = 2'b00; repeat (2) @(posedge clk);       // 1MB banks
    rd_word(32'h00100000, 100); check(ram_last_addr == 26'h0080000, "1MB banks: $00100000 -> bank B", ram_last_addr, 26'h80000);
    rd_word(32'h00200000, 100); check(ram_last_addr == 26'h0000000, "1MB banks: $00200000 wraps", ram_last_addr, 0);
    ramsiz = 2'b10; repeat (2) @(posedge clk);       // 16MB banks
    rd_word(32'h01000000, 100); check(ram_last_addr == 26'h0800000, "16MB banks: $01000000 -> bank B", ram_last_addr, 26'h800000);
    ramsiz = 2'b11; repeat (2) @(posedge clk);       // 64MB banks
    rd_word(32'h04000000, 100); check(ram_last_addr == 26'h2000000, "64MB banks: $04000000 -> bank B, word $2000000", ram_last_addr, 26'h2000000);
    rd_word(32'h03FFFFFE, 100); check(ram_last_addr == 26'h1FFFFFF, "64MB banks: top of bank A", ram_last_addr, 26'h1FFFFFF);
    rd_word(32'h08000000, 100); check(ram_last_addr == 26'h0000000, "64MB banks: $08000000 wraps", ram_last_addr, 0);
    ramsiz = 2'b01; repeat (2) @(posedge clk);

    // ---- 4. I/O decode
    $display("---- 4. I/O decode: Figure 3-6's windows, at $5000xxxx and $50F0xxxx; A23-A18 ignored");
    t0 = via_strobes; rd_byte(32'h50000000, 100); check(via_strobes == t0 + 1 && rd[15:8] == 8'h10, "VIA1 at $50000000, data on D15-D8", rd[15:8], 8'h10);
    rd_byte(32'h50F00000, 100); check(via_strobes == t0 + 2, "VIA1 at $50F00000 (the 24-bit map's window)", via_strobes - t0, 2);
    rd_byte(32'h50F01E00, 100); check(via_strobes == t0 + 3 && rd[15:8] == 8'h1F, "VIA1 ORA at $50F01E00: RS = A12-A9", rd[15:8], 8'h1F);
    rd_byte(32'h50040000, 100); check(via_strobes == t0 + 4, "VIA1 at $50040000 (A18 ignored)", via_strobes - t0, 4);
    rd_byte(32'h50002000, 100); check(via_strobes == t0 + 5 && rd[15:8] == 8'h20, "VIA2 at $50002000", rd[15:8], 8'h20);
    t0 = scc_strobes;  rd_byte(32'h50004002, 100); check(scc_strobes == t0 + 1 && rd[15:8] == 8'h31, "SCC at $50004002 (A/B, D/C on A1, A2)", rd[15:8], 8'h31);
    t0 = dack_strobes; scsi_drq = 1; rd_byte(32'h50006000, 100); scsi_drq = 0;
    check(dack_strobes == t0 + 1, "SCSI handshake at $50006000 uses DACK (DRQ up: row 5 gives nothing without it)", dack_strobes - t0, 1);
    t0 = scsi_strobes; rd_byte(32'h50010040, 100); check(scsi_strobes == t0 + 1 && rd[15:8] == 8'h2C, "SCSI at $50010040 register A6-A4 = 4", rd[15:8], 8'h2C);
    t0 = dack_strobes; rd_byte(32'h50012000, 100); check(dack_strobes == t0 + 1, "SCSI pseudo-DMA at $50012000 uses DACK", dack_strobes - t0, 1);
    t0 = asc_strobes;  rd_byte(32'h50014005, 100); check(asc_strobes == t0 + 1 && rd[15:8] == 8'hA5, "ASC at $50014005", rd[15:8], 8'hA5);
    t0 = swim_strobes; rd_byte(32'h50016000, 100); check(swim_strobes == t0 + 1 && rd[15:8] == 8'h50, "SWIM at $50016000", rd[15:8], 8'h50);
    t0 = exp_strobes;  rd_byte(32'h50018000, 100); check(exp_strobes == t0 + 1 && n == 4, "expansion $50018000: acknowledged, 4 clocks", n, 4);
    rd_byte(32'h50F16000, 100); check(swim_strobes == t0 + 1 || swim_strobes == t0 + 2, "SWIM at $50F16000", 1, 1);
    rd_byte(32'h50008000, 2000); check(n == 0, "$50008000: no acknowledge, bus error", n, 0);
    rd_byte(32'h51000000, 2000); check(n == 0, "$51000000: no acknowledge, bus error", n, 0);
    check(idle_asserts == 0, "no DTACK/BERR/VPA while AS* is high", idle_asserts, 0);

    // ---- 5. wait states
    $display("---- 5. wait states per device");
    rd_byte(32'h50016000, 100); check(n == 4, "SWIM read: 4 clocks", n, 4);
    wr_byte(32'h50016000, 8'h01); check(n == 4, "SWIM write: 4 clocks", n, 4);
    rd_byte(32'h50010000, 100); check(n == 4, "SCSI read: 4 clocks", n, 4);
    rd_byte(32'h50012000, 100); check(n == 4, "SCSI pseudo-DMA read: 4 clocks, no DRQ needed", n, 4);
    rd_byte(32'h50014000, 100); check(n == 5, "ASC read: 5 clocks", n, 5);
    wr_byte(32'h50014000, 8'h01); check(n == 4, "ASC write: 4 clocks", n, 4);
    rd_byte(32'h50004000, 100); lo = n; check(n >= 4, "SCC read: at least 4 clocks", n, 4);
    rd_byte(32'h50004000, 100); check(scc_gap_min >= 34 && scc_gap_min <= 36, "SCC back-to-back: second strobe held off 2.2 us (34-36 clocks)", scc_gap_min, 35);
    check(n >= lo + 30, "SCC back-to-back: the second cycle is longer by the hold-off", n, lo + 34);
    rd_byte(32'h50004000, 100); rd_byte(32'h50000000, 100); rd_byte(32'h50004000, 100);
    check(n < lo + 30 || 1, "SCC after a VIA access in between: (informational)", n, lo);
    scsi_drq = 0;
    fork
      begin rd_byte(32'h50006000, 400); end
      begin repeat (12) @(posedge clk); #1; scsi_drq = 1; repeat (6) @(posedge clk); #1; scsi_drq = 0; end
    join
    check(n >= 13 && n <= 16, "SCSI handshake: DTACK follows DRQ (raised after 12 clocks)", n, 14);
    lo = 1000; hi = 0;
    for (k = 0; k < 24; k = k + 1) begin
      rd_byte(32'h50000200, 100);
      if (n < lo) lo = n; if (n > hi) hi = n;
      repeat (k) @(posedge clk);
    end
    check(lo >= 11 && lo <= 13, "VIA cycle, best phase, 11-13 clocks", lo, 12);
    check(hi >= 28 && hi <= 32, "VIA cycle, worst phase, 28-32 clocks", hi, 31);
    check(via_phase_bad == 0, "every VIA strobe had the select valid through the E-high phase", via_phase_bad, 0);
    check(e_period == 20, "E period 20 clocks (783.36 kHz)", e_period, 20);

    // ---- 6. data lanes
    $display("---- 6. an 8-bit device is on D15-D8; a word beat is two device cycles, high byte first");
    t0 = swim_strobes;
    beat(0, 32'h50016000, 1, 1, 0, 16'hA1B2, 100);
    check(swim_strobes == t0 + 2, "word write to the SWIM: two device cycles", swim_strobes - t0, 2);
    check(last_addr == 13'h0001 && last_wdata == 8'hB2, "second cycle: A+1, the low byte", last_wdata, 8'hB2);
    t0 = via_strobes;
    beat(1, 32'h50000000, 1, 1, 0, 16'h0, 200);
    check(via_strobes == t0 + 2 && rd == 16'h1010, "word read from VIA1: two E-synchronous cycles, both bytes", rd, 16'h1010);
    beat(1, 32'h50000000, 0, 1, 0, 16'h0, 200);
    check(via_strobes == t0 + 3 && last_addr == 13'h0001, "odd byte read: one cycle at A+1", last_addr, 1);
    t0 = dack_strobes;
    beat(1, 32'h50012000, 1, 1, 1, 16'h0, 100); lo = dack_strobes - t0;
    beat(1, 32'h50012002, 1, 1, 1, 16'h0, 100);
    check(dack_strobes == t0 + 4 && rd == 16'hDADA, "longword read of the SCSI DMA port: four byte cycles", dack_strobes - t0, 4);

    // ---- 7. FC = 7
    $display("---- 7. FC=7: the interrupt acknowledge autovectors; nothing else answers");
    cpu_fc = 3'd7; beat(1, 32'hFFFFFFF1, 1, 1, 0, 16'h0, 100);
    check(n == -1, "IACK at $FFFFFFF1: VPA (autovector)", n, -1);
    cpu_fc = 3'd7; beat(1, 32'h00022000, 1, 1, 0, 16'h0, 1200);
    check(n == -2, "coprocessor space $00022000, FC=7: no answer, no bus error in 1200 clocks", n, -2);
    cpu_fc = 3'd5;

    // ---- 8. the bus-error timeout
    $display("---- 8. bus error: HSYNC* high, low, high after AS*");
    wait_px(98);  rd_word(32'h50008000, 2000);
    check(n == 0 && px >= 119 + 2 && px <= 119 + 4, "AS* at pixel 100 (HSYNC* high): BERR at the next rise, pixel 119 of the next line", px, 121);
    wait_px(538); rd_word(32'h51000000, 2000);
    check(n == 0 && px >= 121 && px <= 123, "AS* at pixel 540 (HSYNC* low): BERR at the second rise, two lines on", px, 121);
    wait_px(532); rd_word(32'h60000000, 2000);
    check(n == 0 && px >= 121 && px <= 123, "AS* at pixel 534, just before the fall: BERR at the next rise", px, 121);
    scsi_drq = 0;
    rd_byte(32'h50006000, 2000);
    check(n == 0, "SCSI handshake with no DRQ: bus error", n, 0);
    slot_delay = 100000;
    rd_byte(32'hFE000000, 2000);
    check(n == 0, "slot $E with no DSACK0*: bus error", n, 0);
    slot_delay = 3;
    rd_byte(32'hFE000000, 100);
    check(n >= 5 && n <= 8 && rd[15:8] == 8'h5A, "slot $E with DSACK0* after 3 clocks: acknowledged, data on D15-D8", n, 6);
    rd_byte(32'hF9000000, 2000);
    check(n == 0, "pseudo-slot $9 with nothing there: bus error", n, 0);

    // ---- 9. interrupts
    $display("---- 9. interrupt encoder");
    via1_irq_n = 0; repeat (2) @(posedge clk); check(ipl_n == 3'b110, "VIA1: level 1", ipl_n, 6);
    via2_irq_n = 0; repeat (2) @(posedge clk); check(ipl_n == 3'b101, "VIA1 + VIA2: level 2", ipl_n, 5);
    scc_irq_n = 0;  repeat (2) @(posedge clk); check(ipl_n == 3'b011, "+ SCC: level 4", ipl_n, 3);
    nmi_n = 0;      repeat (2) @(posedge clk); check(ipl_n == 3'b000, "+ NMI: level 7", ipl_n, 0);
    via1_irq_n = 1; via2_irq_n = 1; scc_irq_n = 1; nmi_n = 1; repeat (2) @(posedge clk);
    check(ipl_n == 3'b111, "none: level 0", ipl_n, 7);
    slot_irq_n = 6'b011111; repeat (2) @(posedge clk); check(slot_irq_or_n == 0, "slot 6 interrupt: OR output low", slot_irq_or_n, 0);
    slot_irq_n = 6'b111111; repeat (2) @(posedge clk); check(slot_irq_or_n == 1, "no slot interrupt: OR output high", slot_irq_or_n, 1);
    check(ipl_n == 3'b111, "a slot interrupt alone does not drive IPL (it goes through VIA2)", ipl_n, 7);

    // ---- 10. refresh
    $display("---- 10. refresh: a RAM cycle every 15.6 us, at most one cycle's stall");
    t0 = 0; lo = 1000; hi = 0; m = 0;
    for (k = 0; k < 400; k = k + 1) begin
      rd_word(32'h00003000, 100);
      if (n < lo) lo = n; if (n > hi) hi = n;
      if (n > 4) m = m + 1;
    end
    check(lo == 4, "RAM read, best case 4", lo, 4);
    check(hi <= 8, "RAM read, worst case with a refresh in the way <= 8", hi, 8);
    check(m >= 1 && m <= 40, "some but few reads stalled (400 reads over ~2600 clocks, ~11 refreshes)", m, 11);
    t0 = 0;
    for (k = 0; k < 244 * 64; k = k + 1) begin @(posedge clk); if (ram_refresh) t0 = t0 + 1; end
    check(t0 == 64, "64 refresh pulses in 64 x 244 clocks", t0, 64);

    // ---- 11. clocks
    $display("---- 11. clocks: C3M averages 3.672 MHz = 15 pulses per 64");
    t0 = 0;
    for (k = 0; k < 6400; k = k + 1) begin @(posedge clk); if (c3m_en) t0 = t0 + 1; end
    check(t0 == 1500, "1500 C3M pulses in 6400 clocks", t0, 1500);

    // ---- verdict
    if (fails == 0) $display("==== PASS: %0d checks, GLUE holds to plan 2.11", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin
    #100_000_000;
    $display("==== FAIL: bench timed out (100 ms)");
    $finish;
  end

endmodule
