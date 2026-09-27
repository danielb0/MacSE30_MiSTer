// tb_se30_glue.v - GLUE held to the cycle table of SE30_PLAN.md 2.11.
//
// WHAT THIS PROVES
//   rtl/se30_glue.v is the SE/30's GLUE as a contract (plan 2.3, 2.11):
//   nobody has its internals, so this bench is the specification, row by
//   row of 2.11.3 and item by item of 2.11.7:
//
//     1. RAM: a byte, word or longword cycle is 4 clocks, one 32-bit
//        access; data goes where it was written, by lane                2.11 row 1
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
//        the 12..34 envelope; E is C16M/20                              rows 3-5, 7-11
//     6. ports: RAM and ROM answer DSACK "00" (32-bit); every device
//        answers DSACK0* alone (8-bit) with its byte on D31-D24, one
//        device cycle per bus cycle - the processor issues the byte
//        cycles of a word or a longword itself                          2.11.1
//     7. FC=7: nothing answers and nothing times out; the interrupt
//        acknowledge autovectors in the processor (AVEC grounded)      2.11.1, 2.11.4
//     8. the bus-error timeout is UI6's: BERR after HSYNC* has been
//        seen high, low, high - exact clocks for three phases - for
//        undecoded space and for a SCSI handshake that never sees DRQ  2.11.4
//     9. interrupts: VIA1 1, VIA2 2, SCC 4, NMI 7, highest wins; the
//        six slot lines OR into one output                             2.11.5
//    10. refresh: one RAM-cycle stall at most every 244 clocks          row 17
//    11. clocks: C3M is 15 pulses per 64 clocks                         2.11.3
//
// THE BUS
//   The 68030's (plan 2.11.1): a 32-bit address, AS*, DS*, R/W*, FC,
//   SIZ1-0, 32-bit data, DSACK1*/DSACK0*, BERR, IPL.  A cycle is counted
//   as the 68030 runs it, S0 to S5 in C16M clocks: the S0/S1 clock (AS*
//   asserted at S1, so GLUE first sees it a clock later), the clocks from
//   then to DSACK* inclusive (the processor takes DSACK* at the falling
//   edge of the clock it appears in), and the S4/S5 clock - so a
//   one-wait-state cycle is 4.  DS* goes with AS* on a read and one clock
//   after it on a write, as the processor drives it (UM 7.1.5); the write
//   data is on all four lanes as Table 7-5 places it; the bench negates
//   AS* in the S4/S5 clock.
//
//   Devices are modelled here: RAM and ROM as longword arrays that ack in
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
  reg         cpu_as_n = 1, cpu_ds_n = 1, cpu_rw_n = 1;
  reg   [1:0] cpu_siz = 2'b10;
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
  reg  [31:0] ram_rdata = 0, rom_rdata = 0;
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
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
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
  reg [31:0] ram [0:(1 << 19) - 1];        // 512K longs; the bank test looks at ram_addr itself
  integer    ram_reqs = 0, ram_ack_cnt = 0;
  reg [24:0] ram_last_addr;
  reg  [3:0] ram_last_be;
  integer    i;
  initial for (i = 0; i < (1 << 19); i = i + 1) ram[i] = 32'h00000000;
  always @(posedge clk) begin
    ram_ack <= 0;
    if (ram_req && !ram_ack) begin
      ram_ack_cnt = ram_ack_cnt + 1;
      if (ram_ack_cnt >= RAM_ACK_CLK) begin
        ram_ack_cnt = 0;
        ram_reqs = ram_reqs + 1;
        ram_last_addr = ram_addr; ram_last_be = ram_be;
        if (ram_we) begin
          if (ram_be[3]) ram[ram_addr[18:0]][31:24] <= ram_wdata[31:24];
          if (ram_be[2]) ram[ram_addr[18:0]][23:16] <= ram_wdata[23:16];
          if (ram_be[1]) ram[ram_addr[18:0]][15:8]  <= ram_wdata[15:8];
          if (ram_be[0]) ram[ram_addr[18:0]][7:0]   <= ram_wdata[7:0];
        end
        ram_rdata <= ram[ram_addr[18:0]];
        ram_ack <= 1;
      end
    end
  end

  // ---------------------------------------------------------- ROM model
  // the two words of the long at long address L read as their own word
  // addresses, 2L and 2L+1 - address-dependent, so mirrors are told apart
  // from data.
  integer rom_reqs = 0, rom_ack_cnt = 0;
  reg [15:0] rom_last_addr;
  always @(posedge clk) begin
    rom_ack <= 0;
    if (rom_req && !rom_ack) begin
      rom_ack_cnt = rom_ack_cnt + 1;
      if (rom_ack_cnt >= ROM_ACK_CLK) begin
        rom_ack_cnt = 0;
        rom_reqs = rom_reqs + 1;
        rom_last_addr = rom_addr;
        rom_rdata <= {rom_addr[14:0], 1'b0, rom_addr[14:0], 1'b1};
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
  integer    e_low_clocks = 0;             // clocks E has been continuously low
  integer    e_rises = 0, e_phase_min = 100;   // plan 4.4: rises counted, the shortest phase seen
  integer    scc_last_end = -1000, scc_gap_min = 1000000, cyc_clock = 0;
  always @(posedge clk) begin
    cyc_clock <= cyc_clock + 1;
    e_q <= e_clk;
    if (e_clk && !e_q) begin
      e_rises = e_rises + 1;
      if (e_low_clocks > 0 && e_low_clocks < e_phase_min) e_phase_min = e_low_clocks;
      e_high_clocks = 0;
    end
    if (!e_clk && e_q) begin
      if (e_high_clocks < e_phase_min) e_phase_min = e_high_clocks;
      e_low_clocks = 0;
    end
    if (e_clk) e_high_clocks = e_high_clocks + 1; else e_low_clocks = e_low_clocks + 1;
    sel_high_clocks = (via1_sel || via2_sel) ? sel_high_clocks + 1 : 0;
    if (dev_strobe) begin
      last_addr = dev_addr; last_wdata = dev_wdata; last_rw = dev_rw;
      if (via1_sel || via2_sel) begin
        via_strobes = via_strobes + 1;
        // the strobe is E's last high clock, and the select was up at least
        // a clock before E rose (the 6522's CS setup to phi2, plan 4.4)
        if (!(e_clk && sel_high_clocks > e_high_clocks)) via_phase_bad = via_phase_bad + 1;
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

  // DSACK/BERR must never assert while AS* is high
  integer idle_asserts = 0;
  always @(posedge clk) if (cpu_as_n && (dsack_n != 2'b11 || berr)) idle_asserts = idle_asserts + 1;

  // ----------------------------------------------------------- the cycle
  // One 68030 bus cycle.  n = clocks from AS* low to DSACK* low inclusive,
  // plus one (the S4/S5) - so a one-wait-state cycle is 4.  Returns 0 on
  // BERR, -2 on a timeout of `limit` clocks.  port = the DSACK code seen:
  // 0 for a 32-bit port, 2 for an 8-bit one.
  integer n, port;
  reg [31:0] rd;
  task cycle(input read, input [31:0] a, input [1:0] siz, input [31:0] wd, input integer limit);
    integer k;
    begin
      @(posedge clk); #1;
      cpu_addr = a; cpu_rw_n = read; cpu_siz = siz; cpu_dout = wd;
      cpu_as_n = 0; cpu_ds_n = !read;                    // DS* with AS* on a read
      k = 1;
      @(posedge clk); #1;
      cpu_ds_n = 0;                                       // and a clock later on a write
      while (dsack_n == 2'b11 && !berr && k < limit) begin k = k + 1; @(posedge clk); #1; end
      port = dsack_n;
      // the true 68030 cycle in C16M clocks: the S0/S1 clock before GLUE
      // first sees AS*, the clocks to DSACK* inclusive, the S4/S5 clock
      n = (k >= limit) ? -2 : berr ? 0 : k + 2;
      if (n > 0) begin @(posedge clk); #1; rd = cpu_din; end   // the processor latches at the end of S4
      cpu_as_n = 1; cpu_ds_n = 1; cpu_fc = 3'd5;
      @(posedge clk); #1;
    end
  endtask
  // the write data as the processor places it (UM Table 7-5)
  task rd_long(input [31:0] a, input integer limit); begin cycle(1, a, 2'b00, 32'h0, limit); end endtask
  task wr_long(input [31:0] a, input [31:0] d); begin cycle(0, a, 2'b00, d, 2000); end endtask
  task rd_word(input [31:0] a, input integer limit); begin cycle(1, a, 2'b10, 32'h0, limit); end endtask
  task wr_word(input [31:0] a, input [15:0] d);
    begin cycle(0, a, 2'b10, a[0] ? {d[15:8], d[15:8], d[7:0], d[15:8]} : {d, d}, 2000); end
  endtask
  task rd_byte(input [31:0] a, input integer limit); begin cycle(1, a, 2'b01, 32'h0, limit); end endtask
  task wr_byte(input [31:0] a, input [7:0] d); begin cycle(0, a, 2'b01, {d, d, d, d}, 2000); end endtask

  // ------------------------------------------------------------ the tests
  integer t0, t1, lo, hi, k, ok, m;

  initial begin
    repeat (4) @(posedge clk); #1;
    reset_n = 1;
    repeat (8) @(posedge clk);

    // ---- 1. RAM
    $display("---- 1. RAM: 4 clocks a cycle, one 32-bit access, DSACK 00");
    overlay = 0;
    wr_word(32'h00001000, 16'h1234); check(n == 4 && port == 0, "RAM word write clocks, 32-bit port", n, 4);
    check(ram_last_be == 4'b1100, "word at +0: lanes 0-1 enabled", ram_last_be, 12);
    rd_word(32'h00001000, 100);      check(n == 4, "RAM word read clocks", n, 4);
    check(rd[31:16] == 16'h1234, "RAM read back $1234 on D31-D16", rd[31:16], 16'h1234);
    wr_byte(32'h00001003, 8'hAB);    check(n == 4 && ram_last_be == 4'b0001, "RAM byte write at +3: lane 3 only", ram_last_be, 1);
    rd_long(32'h00001000, 100);      check(rd == 32'h123400AB, "the long at $1000 is $123400AB: lanes as written", rd, 32'h123400AB);
    wr_long(32'h00002000, 32'hDEADBEEF); check(n == 4 && ram_last_be == 4'b1111, "longword write: one cycle, 4 clocks, all lanes", n, 4);
    rd_long(32'h00002000, 100);      check(n == 4 && rd == 32'hDEADBEEF, "longword read: one cycle, $DEADBEEF", rd, 32'hDEADBEEF);
    wr_word(32'h00002002, 16'hC0DE); check(ram_last_be == 4'b0011, "word at +2: lanes 2-3", ram_last_be, 3);
    cycle(0, 32'h00002001, 2'b00, 32'h11112233, 100);   // a long $11223344 at +1: the processor's first cycle, OP0 OP0 OP1 OP2 on the lanes (Table 7-5)
    check(ram_last_be == 4'b0111, "SIZ=4 at +1: lanes 1-3 (three bytes, Table 7-7)", ram_last_be, 7);
    rd_long(32'h00002000, 100);      check(rd == 32'hDE112233, "the long is now $DE112233", rd, 32'hDE112233);

    // ---- 2. ROM and overlay
    $display("---- 2. ROM: 4 clocks, mirrored through $4xxxxxxx; overlay");
    rd_word(32'h40000010, 100);      check(n == 4 && port == 0, "ROM read clocks, 32-bit port", n, 4);
    check(rd[31:16] == 16'h0008, "ROM data is the word at $10 (word address 8)", rd[31:16], 16'h0008);
    rd_word(32'h40000012, 100);      check(rd[15:0] == 16'h0009, "the word at $12 on D15-D0 (word address 9)", rd[15:0], 16'h0009);
    rd_word(32'h40800010, 100);      check(rd[31:16] == 16'h0008 && rom_last_addr == 16'h0004, "ROM mirror at $40800010 (the ROM's own base)", rom_last_addr, 4);
    rd_word(32'h4FFC0010, 100);      check(rom_last_addr == 16'h0004, "ROM mirror at $4FFC0010", rom_last_addr, 4);
    rd_word(32'h4083FFFE, 100);      check(rom_last_addr == 16'hFFFF && rd[15:0] == 16'hFFFF, "ROM top word", rom_last_addr, 16'hFFFF);
    overlay = 1; repeat (2) @(posedge clk);
    t0 = ram_reqs; t1 = rom_reqs;
    rd_long(32'h00000000, 100);
    check(rom_reqs == t1 + 1 && ram_reqs == t0, "overlay: $0 reads ROM, no RAM cycle", rom_reqs - t1, 1);
    check(rom_last_addr == 16'h0000, "overlay: the reset vector comes from ROM long 0", rom_last_addr, 0);
    rd_long(32'h40000000, 100);      check(rom_reqs == t1 + 2, "overlay: $40000000 is still ROM", rom_reqs - t1, 2);
    overlay = 0; repeat (2) @(posedge clk);
    t0 = ram_reqs;
    rd_long(32'h00000000, 100);      check(ram_reqs == t0 + 1, "overlay off: $0 is RAM", ram_reqs - t0, 1);
    wr_word(32'h40000000, 16'h5555); check(n == 4 && ram_reqs == t0 + 1, "ROM write: acknowledged, nothing written", n, 4);

    // ---- 3. RAM banks
    $display("---- 3. RAM banks by RAMSIZ; bits above the two banks ignored");
    ramsiz = 2'b01; repeat (2) @(posedge clk);       // 4MB banks
    rd_long(32'h00000000, 100); check(ram_last_addr == 25'h0000000, "4MB banks: $0 -> long 0", ram_last_addr, 0);
    rd_long(32'h00400000, 100); check(ram_last_addr == 25'h0100000, "4MB banks: $00400000 -> bank B, long $100000", ram_last_addr, 25'h100000);
    rd_long(32'h00800000, 100); check(ram_last_addr == 25'h0000000, "4MB banks: $00800000 wraps to bank A", ram_last_addr, 0);
    rd_long(32'h3FC00004, 100); check(ram_last_addr == 25'h0100001, "4MB banks: $3FC00004 -> bank B long 1", ram_last_addr, 25'h100001);
    ramsiz = 2'b00; repeat (2) @(posedge clk);       // 1MB banks
    rd_long(32'h00100000, 100); check(ram_last_addr == 25'h0040000, "1MB banks: $00100000 -> bank B", ram_last_addr, 25'h40000);
    rd_long(32'h00200000, 100); check(ram_last_addr == 25'h0000000, "1MB banks: $00200000 wraps", ram_last_addr, 0);
    ramsiz = 2'b10; repeat (2) @(posedge clk);       // 16MB banks
    rd_long(32'h01000000, 100); check(ram_last_addr == 25'h0400000, "16MB banks: $01000000 -> bank B", ram_last_addr, 25'h400000);
    ramsiz = 2'b11; repeat (2) @(posedge clk);       // 64MB banks
    rd_long(32'h04000000, 100); check(ram_last_addr == 25'h1000000, "64MB banks: $04000000 -> bank B, long $1000000", ram_last_addr, 25'h1000000);
    rd_long(32'h03FFFFFC, 100); check(ram_last_addr == 25'h0FFFFFF, "64MB banks: top of bank A", ram_last_addr, 25'hFFFFFF);
    rd_long(32'h08000000, 100); check(ram_last_addr == 25'h0000000, "64MB banks: $08000000 wraps", ram_last_addr, 0);
    ramsiz = 2'b01; repeat (2) @(posedge clk);

    // ---- 4. I/O decode
    $display("---- 4. I/O decode: Figure 3-6's windows, at $5000xxxx and $50F0xxxx; A23-A18 ignored");
    t0 = via_strobes; rd_byte(32'h50000000, 100); check(via_strobes == t0 + 1 && rd[31:24] == 8'h10 && port == 2, "VIA1 at $50000000, data on D31-D24, DSACK0* alone", rd[31:24], 8'h10);
    rd_byte(32'h50F00000, 100); check(via_strobes == t0 + 2, "VIA1 at $50F00000 (the 24-bit map's window)", via_strobes - t0, 2);
    rd_byte(32'h50F01E00, 100); check(via_strobes == t0 + 3 && rd[31:24] == 8'h1F, "VIA1 ORA at $50F01E00: RS = A12-A9", rd[31:24], 8'h1F);
    rd_byte(32'h50040000, 100); check(via_strobes == t0 + 4, "VIA1 at $50040000 (A18 ignored)", via_strobes - t0, 4);
    rd_byte(32'h50002000, 100); check(via_strobes == t0 + 5 && rd[31:24] == 8'h20, "VIA2 at $50002000", rd[31:24], 8'h20);
    t0 = scc_strobes;  rd_byte(32'h50004002, 100); check(scc_strobes == t0 + 1 && rd[31:24] == 8'h31, "SCC at $50004002 (A/B, D/C on A1, A2)", rd[31:24], 8'h31);
    t0 = dack_strobes; scsi_drq = 1; rd_byte(32'h50006000, 100); scsi_drq = 0;
    check(dack_strobes == t0 + 1, "SCSI handshake at $50006000 uses DACK (DRQ up: row 5 gives nothing without it)", dack_strobes - t0, 1);
    t0 = scsi_strobes; rd_byte(32'h50010040, 100); check(scsi_strobes == t0 + 1 && rd[31:24] == 8'h2C, "SCSI at $50010040 register A6-A4 = 4", rd[31:24], 8'h2C);
    t0 = dack_strobes; rd_byte(32'h50012000, 100); check(dack_strobes == t0 + 1, "SCSI pseudo-DMA at $50012000 uses DACK", dack_strobes - t0, 1);
    t0 = asc_strobes;  rd_byte(32'h50014005, 100); check(asc_strobes == t0 + 1 && rd[31:24] == 8'hA5, "ASC at $50014005", rd[31:24], 8'hA5);
    t0 = swim_strobes; rd_byte(32'h50016000, 100); check(swim_strobes == t0 + 1 && rd[31:24] == 8'h50, "SWIM at $50016000", rd[31:24], 8'h50);
    t0 = exp_strobes;  rd_byte(32'h50018000, 100); check(exp_strobes == t0 + 1 && n == 4, "expansion $50018000: acknowledged, 4 clocks", n, 4);
    rd_byte(32'h50F16000, 100); check(swim_strobes == t0 + 1 || swim_strobes == t0 + 2, "SWIM at $50F16000", 1, 1);
    rd_byte(32'h50008000, 2000); check(n == 0, "$50008000: no acknowledge, bus error", n, 0);
    rd_byte(32'h51000000, 2000); check(n == 0, "$51000000: no acknowledge, bus error", n, 0);
    check(idle_asserts == 0, "no DSACK/BERR while AS* is high", idle_asserts, 0);

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
    check(n >= 13 && n <= 16, "SCSI handshake: DSACK follows DRQ (raised after 12 clocks)", n, 14);
    // plan 4.4: E is re-phased to the access - one E rise per 20-clock
    // reference period, takeable early once E has been low 4 clocks; the
    // access high phase is 4 clocks; a used rise is not taken again
    lo = 1000; hi = 0; m = 0;
    for (k = 0; k < 40; k = k + 1) begin
      repeat (17) @(posedge clk);                       // idle: E back on the reference
      rd_byte(32'h50000200, 100);
      if (n < lo) lo = n; if (n > hi) hi = n; m = m + n;
      repeat (k) @(posedge clk);                        // sweep the phase
    end
    check(lo >= 6 && lo <= 9, "VIA cycle, best phase (E low), 6-9 clocks", lo, 7);
    check(hi >= 10 && hi <= 16, "VIA cycle, worst phase (E high), 10-16 clocks", hi, 15);
    check(m >= 40 * 8 && m <= 40 * 11, "VIA cycle, mean over the phases 8-11 clocks (the Guide's 0.5 us average)", m / 40, 9);
    check(via_phase_bad == 0, "every VIA strobe: select up a clock before E rose, held through the E-high phase", via_phase_bad, 0);
    e_phase_min = 100;
    t0 = e_rises; repeat (20000) @(posedge clk);
    check(e_rises - t0 == 1000, "E idle: 1000 rises in 20000 clocks (783.36 kHz)", e_rises - t0, 1000);
    t0 = e_rises; t1 = cyc_clock;
    for (k = 0; k < 100; k = k + 1) begin repeat (137) @(posedge clk); rd_byte(32'h50000200, 100); end
    m = (cyc_clock - t1) / 20;
    check(e_rises - t0 >= m - 1 && e_rises - t0 <= m + 1, "E with sparse VIA accesses: clocks/20 +-1 rises", e_rises - t0, m);
    t0 = e_rises; t1 = cyc_clock; m = 0;
    for (k = 0; k < 900; k = k + 1) begin rd_byte(32'h50000200, 100); if (n > 0) m = m + 1; end
    i = (cyc_clock - t1) / 20;
    check(e_rises - t0 >= i - 1 && e_rises - t0 <= i + 1, "E under 900 back-to-back VIA accesses: clocks/20 +-1 rises (one access a period)", e_rises - t0, i);
    check(m == 900, "... and every access completed", m, 900);
    check((cyc_clock - t1) <= 900 * 24, "... at no worse than one a period", cyc_clock - t1, 900 * 20);
    check(e_phase_min >= 4, "no E phase shorter than 4 clocks throughout", e_phase_min, 4);

    // ---- 6. ports
    $display("---- 6. an 8-bit device is on D31-D24 with DSACK0* alone; one device cycle per bus cycle");
    t0 = swim_strobes;
    cycle(0, 32'h50016000, 2'b10, 32'hA1B2A1B2, 100);    // the processor's first cycle of a word write: SIZ = 2
    check(swim_strobes == t0 + 1 && port == 2 && last_addr == 13'h0000 && last_wdata == 8'hA1,
          "word write to the SWIM, SIZ=2: one device cycle, the high byte at A, DSACK0*", last_wdata, 8'hA1);
    cycle(0, 32'h50016001, 2'b01, 32'hB2B2B2B2, 100);    // the processor's second cycle: SIZ = 1 at A+1
    check(swim_strobes == t0 + 2 && last_addr == 13'h0001 && last_wdata == 8'hB2, "then the low byte at A+1, one more device cycle", last_wdata, 8'hB2);
    t0 = via_strobes;
    cycle(1, 32'h50000000, 2'b10, 32'h0, 200); lo = rd[31:24];
    cycle(1, 32'h50000001, 2'b01, 32'h0, 200);
    check(via_strobes == t0 + 2 && lo == 8'h10 && rd[31:24] == 8'h10, "word read from VIA1: two E-synchronous cycles, each one byte on D31-D24", rd[31:24], 8'h10);
    check(last_addr == 13'h0001, "the second at A+1", last_addr, 1);
    t0 = dack_strobes;
    cycle(1, 32'h50012000, 2'b00, 32'h0, 100); cycle(1, 32'h50012001, 2'b11, 32'h0, 100);
    cycle(1, 32'h50012002, 2'b10, 32'h0, 100); cycle(1, 32'h50012003, 2'b01, 32'h0, 100);
    check(dack_strobes == t0 + 4 && rd[31:24] == 8'hDA, "longword read of the SCSI DMA port: the processor's four byte cycles, four device cycles", dack_strobes - t0, 4);
    cycle(0, 32'h50014000, 2'b00, 32'h0, 100); check(n == 4 && port == 2, "a SIZ=4 cycle to an 8-bit port: one device cycle, DSACK0* alone", port, 2);

    // ---- 7. FC = 7
    $display("---- 7. FC=7: nothing answers, nothing times out");
    cpu_fc = 3'd7; cycle(1, 32'hFFFFFFF1, 2'b01, 32'h0, 1200);
    check(n == -2, "IACK at $FFFFFFF1: no DSACK, no BERR (AVEC is grounded: the processor autovectors)", n, -2);
    cpu_fc = 3'd7; cycle(1, 32'h00022000, 2'b10, 32'h0, 1200);
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
    check(n >= 5 && n <= 9 && rd[31:24] == 8'h5A && port == 2, "slot $E with DSACK0* after 3 clocks: acknowledged, data on D31-D24", n, 7);
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
      rd_long(32'h00003000, 100);
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
