// tb_iicx_nubus.v - the IIcx's NuBus path: GLUE (IICX), the NuChip and the
// Macintosh II Video Card together (SE30_PLAN.md 14.3 items 2-3, step 2).
//
// WHAT THIS PROVES
//   1. the card's declaration ROM, loaded as boot3.rom is (byte-reversed and
//      inverted), reads at the top of slot $9's space on byte lane 0
//      (D31-D24): ByteLanes $E1, the test pattern $5A932BC7, length $1000
//   2. slot $9 is a 32-bit port: DSACK1*/DSACK0* = 00, a longword in one
//      cycle; VRAM keeps longwords, words and bytes by lane
//   3. a transaction waits for the NuBus clock (10 MHz) and takes at least
//      a start and an acknowledge cycle: an access is 5 to 8 C16M clocks
//   4. the NuBus clock: ticks per C16M = 10 / 15.6672 over a long run
//   5. an empty slot ($FAxxxxxx), super slot space ($9xxxxxxx) and slot
//      $9's absent super space time out after 256 NuBus clocks (25.6 us):
//      BERR, and VIA2 PB5/PB4 (v2TM0A, v2TM1A) read 0/1, "bus timeout";
//      the next good transaction sets them 0/0
//   6. $F0xxxxxx, the board's own slot, is a bus error at once
//   7. the registers: a SetMode table written inverted gives the depth;
//      SetPage's bytes give the base
//   8. the Bt453: an address and an entry written, read back inverted
//   9. undecoded non-NuBus space ($51000000) still times out on GLUE's
//      UI6 rule (its own 22.25 kHz tick on the IIcx): BERR in 18-64 us
//  10. no DSACK or BERR while AS* is negated
//  11. VRAM above the block RAM ($4B020 up) goes out on the up_* port and
//      comes back by lane
//  12. a frame: the scan-out at 8, 4 (page 1), 2 (page 2) and 1 bit per pixel shows the pixels
//      written, through CLUT entries written as the driver writes them
//      (the address byte as SetEntries computes it, the colour inverted),
//      at the right places - first, last and middle pixels and lines
//
// HOW
//   GLUE at C16M with c16_en tied high, as sim/glue drives it; the NuChip
//   and the card on the same clock (the NuChip's fraction set for 15.6672
//   MHz); the bus driver is sim/glue's.  The ROM image comes from out/
//   card.hex, made by run.sh from 342-0008-a.bin.

`timescale 1ns/1ps

module tb_iicx_nubus;

  reg clk = 0;
  always #31.9149 clk = ~clk;              // 15.6672 MHz
  reg reset_n = 0;

  // ---------------------------------------------------------------- GLUE
  reg  [31:0] cpu_addr = 0;
  reg         cpu_as_n = 1, cpu_ds_n = 1, cpu_rw_n = 1;
  reg   [1:0] cpu_siz = 2'b00;
  reg   [2:0] cpu_fc = 3'd5;
  reg  [31:0] cpu_dout = 0;
  wire [31:0] cpu_din;
  wire  [1:0] dsack_n;
  wire        berr, slot_sel;
  wire  [3:0] slot_be;
  wire  [1:0] nb_dsack_n, nb_tm;
  wire [31:0] nb_rdata;
  wire        nb_berr;

  se30_glue #(.IICX(1)) glue (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(),
    .mem_early(), .rom_early(),
    .ram_req(), .ram_we(), .ram_addr(), .ram_be(), .ram_wdata(), .ram_rdata(32'h0), .ram_ack(1'b0), .ram_refresh(),
    .rom_req(), .rom_addr(), .rom_rdata(32'h0), .rom_ack(1'b0),
    .via1_sel(), .via2_sel(), .scc_sel(), .scsi_sel(), .scsi_dack(), .asc_sel(), .swim_sel(), .exp_sel(),
    .dev_strobe(), .dev_addr(), .dev_rw(), .dev_wdata(), .dev_rdata(8'h00), .scsi_drq(1'b0),
    .e_clk(), .c3m_en(),
    .fpu_sel(), .fpu_dsack_n(2'b11), .fpu_rdata(32'h0),
    .slot_sel(slot_sel), .slot_dsack0_n(1'b1), .slot_rdata(8'h00),
    .nb_dsack_n(nb_dsack_n), .nb_rdata(nb_rdata), .nb_berr(nb_berr), .slot_be(slot_be),
    .via1_irq_n(1'b1), .via2_irq_n(1'b1), .scc_irq_n(1'b1), .nmi_n(1'b1),
    .slot_irq_n(6'b111111), .slot_irq_or_n(),
    .overlay(1'b0), .ramsiz(2'b01), .hsync_n(1'b1), .dbg_hs_wait());

  // ------------------------------------------------------- NuChip, card
  wire        card_sel, card_rw, card_ack, nb_tick, card_irq_n;
  wire [19:0] card_addr;
  wire  [3:0] card_be;
  wire [31:0] card_wdata, card_rdata;
  iicx_nuchip #(.NB_NUM(100000), .NB_DEN(156672)) nuchip (
    .clk(clk), .reset_n(reset_n),
    .sel(slot_sel), .addr(cpu_addr), .rw(cpu_rw_n), .be(slot_be), .wdata(cpu_dout),
    .rdata(nb_rdata), .dsack_n(nb_dsack_n), .berr(nb_berr), .tm_pb54(nb_tm), .nb_tick(nb_tick),
    .card_sel(card_sel), .card_addr(card_addr), .card_rw(card_rw), .card_be(card_be),
    .card_wdata(card_wdata), .card_rdata(card_rdata), .card_ack(card_ack));

  reg        rom_we = 0;
  reg [11:0] rom_waddr = 0;
  reg  [7:0] rom_wdata = 0;
  nubus_tfb card (
    .clk(clk), .reset_n(reset_n),
    .sel(card_sel), .rw(card_rw), .addr(card_addr), .be(card_be), .wdata(card_wdata),
    .rdata(card_rdata), .ack(card_ack), .irq_n(card_irq_n),
    .rom_we(rom_we), .rom_waddr(rom_waddr), .rom_wdata(rom_wdata),
    .up_req(up_req), .up_we(up_we), .up_addr(up_addr), .up_be(up_be), .up_wdata(up_wdata), .up_rdata(up_rdata), .up_ack(up_ack),
    .clk_pix(clk), .r(pr), .g(pg), .b(pb), .hs_n(), .vs_n(), .hblank(phb), .vblank(pvb));

  // the upper VRAM: a memory behind se30_sdram's level handshake, a few
  // clocks late
  wire        up_req, up_we;
  wire [16:0] up_addr;
  wire  [3:0] up_be;
  wire [31:0] up_wdata;
  reg  [31:0] up_rdata = 0, upmem [0:131071];
  reg         up_ack = 0;
  integer     up_wait = 0;
  always @(posedge clk) begin
    if (!up_req) begin up_ack <= 0; up_wait = 0; end
    else if (!up_ack) begin
      up_wait = up_wait + 1;
      if (up_wait == 5) begin
        if (up_we) begin
          if (up_be[3]) upmem[up_addr][31:24] = up_wdata[31:24];
          if (up_be[2]) upmem[up_addr][23:16] = up_wdata[23:16];
          if (up_be[1]) upmem[up_addr][15:8]  = up_wdata[15:8];
          if (up_be[0]) upmem[up_addr][7:0]   = up_wdata[7:0];
        end
        up_rdata <= upmem[up_addr]; up_ack <= 1;
      end
    end
  end

  // the scan-out, sampled: the active pixel's coordinates
  wire [7:0] pr, pg, pb;
  wire       phb, pvb;
  integer px = 0, py = 0, frames = 0;
  reg        phb_q = 1, pvb_q = 1;
  reg [23:0] pix [0:7];                    // the sampled pixels, by test point
  integer    tx [0:7], ty [0:7];
  integer    q;
  always @(posedge clk) begin
    phb_q <= phb; pvb_q <= pvb;
    if (!phb && !pvb) begin
      for (q = 0; q < 8; q = q + 1) if (px == tx[q] && py == ty[q]) pix[q] <= {pr, pg, pb};
      px = px + 1;
    end
    if (phb && !phb_q) begin px = 0; if (!pvb) py = py + 1; end
    if (pvb && !pvb_q) begin py = 0; frames = frames + 1; end
  end
  integer active_w = 0, line_px = 0;
  always @(posedge clk) if (!phb && !pvb) line_px = line_px + 1; else if (phb && !phb_q) begin if (line_px != 0) active_w = line_px; line_px = 0; end

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*80-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask
  task checkx(input cond, input [8*80-1:0] what, input [31:0] got, input [31:0] want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: $%h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got $%h, want $%h", what, got, want); end
    end
  endtask

  integer idle_asserts = 0;
  always @(posedge clk) if (cpu_as_n && (dsack_n != 2'b11 || berr)) idle_asserts = idle_asserts + 1;

  // -------------------------------------------- the bus driver (sim/glue's)
  integer n, port;
  reg [31:0] rd;
  task cycle(input read, input [31:0] a, input [1:0] siz, input [31:0] wd, input integer limit);
    integer k;
    begin
      @(posedge clk); #1;
      cpu_addr = a; cpu_rw_n = read; cpu_siz = siz; cpu_dout = wd;
      cpu_as_n = 0; cpu_ds_n = !read;
      k = 1;
      @(posedge clk); #1;
      cpu_ds_n = 0;
      while (dsack_n == 2'b11 && !berr && k < limit) begin k = k + 1; @(posedge clk); #1; end
      port = dsack_n;
      n = (k >= limit) ? -2 : berr ? 0 : k + 2;
      if (n > 0) begin @(posedge clk); #1; rd = cpu_din; end
      cpu_as_n = 1; cpu_ds_n = 1;
      @(posedge clk); #1;
    end
  endtask
  task rd_long(input [31:0] a); begin cycle(1, a, 2'b00, 32'h0, 4000); end endtask
  task wr_long(input [31:0] a, input [31:0] d); begin cycle(0, a, 2'b00, d, 4000); end endtask
  task wr_word(input [31:0] a, input [15:0] d); begin cycle(0, a, 2'b10, {d, d}, 4000); end endtask
  task wr_byte(input [31:0] a, input [7:0] d); begin cycle(0, a, 2'b01, {d, d, d, d}, 4000); end endtask
  task rd_byte(input [31:0] a); begin cycle(1, a, 2'b01, 32'h0, 4000); end endtask

  // the berr cycle's length in clocks
  integer t0, t_berr;
  task timed_read(input [31:0] a);
    begin
      t0 = $time; rd_long(a); t_berr = ($time - t0);
    end
  endtask

  // ----------------------------------------------------------- the ROM
  reg [7:0] img [0:4095];
  integer i, nmin, nmax, ticks, c16s;
  initial begin
    $readmemh("out/card.hex", img);
    #200 reset_n = 1;
    // boot3.rom as the top loads it: file order, a byte per write
    for (i = 0; i < 4096; i = i + 1) begin
      @(posedge clk); #1 rom_we = 1; rom_waddr = i; rom_wdata = img[i];
    end
    @(posedge clk); #1 rom_we = 0;
    repeat (4) @(posedge clk);

    // 1. the format block
    rd_byte(32'hF9FFFFFC);
    checkx(n > 0 && rd[31:24] == 8'hE1, "1 ByteLanes at $F9FFFFFC (lane 0, D31-D24)", rd[31:24], 8'hE1);
    rd_byte(32'hF9FFFFE8); i = rd[31:24];
    rd_byte(32'hF9FFFFEC); i = (i << 8) | rd[31:24];
    rd_byte(32'hF9FFFFF0); i = (i << 8) | rd[31:24];
    rd_byte(32'hF9FFFFF4); i = (i << 8) | rd[31:24];
    checkx(i == 32'h5A932BC7, "1 test pattern at $F9FFFFE8-F4", i, 32'h5A932BC7);
    rd_byte(32'hF9FFFFC0); i = rd[31:24];                    // the format block's Length: ROM bytes 4080-4083
    rd_byte(32'hF9FFFFC4); i = (i << 8) | rd[31:24];
    rd_byte(32'hF9FFFFC8); i = (i << 8) | rd[31:24];
    rd_byte(32'hF9FFFFCC); i = (i << 8) | rd[31:24];
    checkx(i == 32'h00001000, "1 length", i, 32'h1000);

    // 2. a 32-bit port; VRAM by lane
    wr_long(32'hF9000020, 32'h12345678);
    check(port == 2'b00, "2 write: DSACK1*/DSACK0* = 00 (32-bit)", port, 0);
    rd_long(32'hF9000020);
    checkx(port == 2'b00 && rd == 32'h12345678, "2 longword read back", rd, 32'h12345678);
    wr_byte(32'hF9000021, 8'hAB);
    wr_word(32'hF9000022, 16'hCDEF);
    rd_long(32'hF9000020);
    checkx(rd == 32'h12ABCDEF, "2 byte at +1, word at +2", rd, 32'h12ABCDEF);
    wr_long(32'hF904B01C, 32'hA5A55A5A);                     // the last block-RAM longword
    rd_long(32'hF904B01C);
    checkx(rd == 32'hA5A55A5A, "2 a longword at $4B01C (1-bit: an invisible column, SDRAM)", rd, 32'hA5A55A5A);
    checkx(nb_tm == 2'b00, "5 TM after good transactions: 00 (no error)", nb_tm, 0);

    // 3. the access time, over a spread of phases against the NuBus clock
    nmin = 99; nmax = 0;
    for (i = 0; i < 40; i = i + 1) begin
      rd_long(32'hF9000020);
      if (n < nmin) nmin = n;
      if (n > nmax) nmax = n;
      repeat (i % 3) @(posedge clk);
    end
    check(nmin >= 5 && nmax <= 8, "3 an access: shortest C16M clocks", nmin, 5);
    check(nmax <= 8, "3 an access: longest C16M clocks", nmax, 8);

    // 4. the NuBus clock's rate: ticks over 15,667 C16M clocks (1 ms) = 10,000
    ticks = 0;
    for (c16s = 0; c16s < 15667; c16s = c16s + 1) begin @(posedge clk); if (nb_tick) ticks = ticks + 1; end
    check(ticks >= 9999 && ticks <= 10001, "4 NuBus clocks in 1 ms", ticks, 10000);

    // 5. timeouts: an empty slot, super slot space
    timed_read(32'hFA000000);
    check(n == 0, "5 empty slot $FA: BERR", n, 0);
    check(t_berr >= 25600 && t_berr <= 26000, "5 empty slot: BERR after 25.6 us (ns)", t_berr, 25700);
    checkx(nb_tm == 2'b01, "5 TM after the timeout: PB5 0, PB4 1 (v2TM1A = 1: bus timeout)", nb_tm, 2'b01);
    rd_long(32'hF9000020);
    checkx(nb_tm == 2'b00, "5 TM after the next good transaction: 00", nb_tm, 0);
    rd_long(32'h90000000);
    check(n == 0, "5 super slot space $9xxxxxxx: BERR (no card answers it)", n, 0);
    rd_long(32'hFB000000);
    check(n == 0, "5 empty slot $FB: BERR", n, 0);

    // 6. the board's own slot
    timed_read(32'hF0800000);
    check(n == 0 && t_berr < 300, "6 $F0xxxxxx: BERR at once (ns)", t_berr, 200);

    // 7. registers: SetMode's 8-bit table (register 15 = $F9: depth 3), SetPage
    wr_byte(32'hF988003C, ~8'hF9);
    check(card.depth == 2'd3, "7 register 15 = $F9: depth 8 bits", card.depth, 3);
    wr_byte(32'hF9880008, ~8'h00);
    wr_byte(32'hF988000C, ~8'h08);
    check(card.base == 16'd8, "7 registers 2-3: base 8 longwords ($20)", card.base, 8);

    // 8. the Bt453: address $10, an entry, read back
    wr_byte(32'hF989001C, ~8'h10);
    wr_byte(32'hF9890018, ~8'h11); wr_byte(32'hF9890018, ~8'h22); wr_byte(32'hF9890018, ~8'h33);
    checkx(card.clut[8'h10] == 24'h112233, "8 CLUT entry $10 = $112233", card.clut[8'h10], 24'h112233);
    wr_byte(32'hF989001C, ~8'h10);
    rd_byte(32'hF9890018); i = ~rd[31:24] & 8'hFF;
    checkx(i == 8'h11, "8 the entry's red read back (inverted on the bus)", i, 8'h11);

    // 9. undecoded non-NuBus space: UI6 on GLUE's own tick
    timed_read(32'h51000000);
    check(n == 0 && t_berr >= 18000 && t_berr <= 64000, "9 $51000000: BERR on UI6's rule (ns)", t_berr, 40000);

    // 10.
    check(idle_asserts == 0, "10 no DSACK or BERR with AS* negated", idle_asserts, 0);

    // 11. the upper VRAM
    wr_long(32'hF9050000, 32'hDEADBEEF);
    wr_byte(32'hF9050001, 8'h77);
    rd_long(32'hF9050000);
    checkx(n > 0 && rd == 32'hDE77BEEF, "11 an invisible byte (8-bit: row 319, column 992): through up_*, by lane", rd, 32'hDE77BEEF);
    checkx(up_addr == 17'h14000, "11 at its own address in SDRAM: $50000 / 4 = $14000", up_addr, 17'h14000);

    // 12. a frame at 8 bits: CLUT entries 1-4 by SetEntries' arithmetic
    // (8-bit: the address byte is the index), colours inverted as the
    // gamma table holds them; pixels at the test points
    wr_byte(32'hF988003C, ~8'hF9);                             // register 15: 8-bit
    wr_byte(32'hF9880008, ~8'h00); wr_byte(32'hF988000C, ~8'h08);   // base $20
    for (i = 1; i <= 4; i = i + 1) begin
      wr_byte(32'hF989001C, i);
      wr_byte(32'hF9890018, ~(8'h10 * i)); wr_byte(32'hF9890018, ~(8'h20 + i)); wr_byte(32'hF9890018, ~(8'h40 + i));
    end
    tx[0] = 0;   ty[0] = 0;   wr_byte(32'hF9000020 + 0 * 1024 + 0, 8'd1);
    tx[1] = 639; ty[1] = 0;   wr_byte(32'hF9000020 + 0 * 1024 + 639, 8'd2);
    tx[2] = 0;   ty[2] = 479; wr_byte(32'hF9000020 + 479 * 1024 + 0, 8'd3);   // byte 490,528: rowBytes 1024
    tx[3] = 321; ty[3] = 240; wr_byte(32'hF9000020 + 240 * 1024 + 321, 8'd4);
    tx[4] = 1;   ty[4] = 0;   wr_byte(32'hF9000020 + 0 * 1024 + 1, 8'd2);
    for (q = 5; q < 8; q = q + 1) begin tx[q] = -1; ty[q] = -1; end
    i = frames; while (frames < i + 2) @(posedge clk);         // a whole frame after the writes
    checkx(pix[0] == {8'h10, 8'h21, 8'h41}, "12 8-bit: pixel (0,0) = entry 1", pix[0], {8'h10, 8'h21, 8'h41});
    checkx(pix[4] == {8'h20, 8'h22, 8'h42}, "12 8-bit: pixel (1,0) = entry 2", pix[4], {8'h20, 8'h22, 8'h42});
    checkx(pix[1] == {8'h20, 8'h22, 8'h42}, "12 8-bit: pixel (639,0) = entry 2", pix[1], {8'h20, 8'h22, 8'h42});
    checkx(pix[2] == {8'h30, 8'h23, 8'h43}, "12 8-bit: pixel (0,479) = entry 3", pix[2], {8'h30, 8'h23, 8'h43});
    checkx(pix[3] == {8'h40, 8'h24, 8'h44}, "12 8-bit: pixel (321,240) = entry 4", pix[3], {8'h40, 8'h24, 8'h44});
    check(active_w == 640, "12 the active line: 640 pixels", active_w, 640);
    // 1 bit: register 15 = $C8; entries 0 and 1 by SetEntries' arithmetic
    // ((index << 7) | $7F); pixel bits at (0,0) and (17,2)
    wr_byte(32'hF988003C, ~8'hC8);
    wr_byte(32'hF989001C, 8'h7F);
    wr_byte(32'hF9890018, ~8'hEE); wr_byte(32'hF9890018, ~8'hEE); wr_byte(32'hF9890018, ~8'hEE);
    wr_byte(32'hF989001C, 8'hFF);
    wr_byte(32'hF9890018, ~8'h11); wr_byte(32'hF9890018, ~8'h11); wr_byte(32'hF9890018, ~8'h11);
    wr_long(32'hF9000020, 32'h8000_0000);                      // line 0: pixel 0 set
    wr_long(32'hF9000020 + 2 * 128, 32'h0000_4000);            // line 2: pixel 17 set
    tx[0] = 0;  ty[0] = 0; tx[1] = 1;  ty[1] = 0;
    tx[2] = 17; ty[2] = 2; tx[3] = 16; ty[3] = 2;
    i = frames; while (frames < i + 2) @(posedge clk);
    checkx(pix[0] == 24'h111111, "12 1-bit: pixel (0,0) set = entry 1", pix[0], 24'h111111);
    checkx(pix[1] == 24'hEEEEEE, "12 1-bit: pixel (1,0) clear = entry 0", pix[1], 24'hEEEEEE);
    checkx(pix[2] == 24'h111111, "12 1-bit: pixel (17,2) set", pix[2], 24'h111111);
    checkx(pix[3] == 24'hEEEEEE, "12 1-bit: pixel (16,2) clear", pix[3], 24'hEEEEEE);

    // 4 bits, page 1 (SetPage: base = 1 x 512 x 480 + $20 = 245,792 bytes =
    // 61,448 longwords = $F008); CLUT index 5 at (5 << 4) | $0F; pixel (5,10)
    // is byte 2's low nibble
    wr_byte(32'hF988003C, ~8'hE8);                             // register 15 = $E8: 4-bit
    wr_byte(32'hF9880008, ~8'hF0); wr_byte(32'hF988000C, ~8'h08);
    wr_byte(32'hF989001C, 8'h5F);
    wr_byte(32'hF9890018, ~8'h55); wr_byte(32'hF9890018, ~8'h66); wr_byte(32'hF9890018, ~8'h77);
    wr_byte(32'hF9000020 + 245760 + 10 * 512 + 2, 8'h05);      // pixels 4 and 5: 0 and 5
    tx[0] = 5; ty[0] = 10; tx[1] = 4; ty[1] = 10;
    tx[2] = -1; ty[2] = -1; tx[3] = -1; ty[3] = -1;
    i = frames; while (frames < i + 2) @(posedge clk);
    checkx(pix[0] == 24'h556677, "12 4-bit page 1: pixel (5,10), byte 2's low nibble = entry 5", pix[0], 24'h556677);
    check(card.depth_p == 2'd2 && card.base_p == 16'hF008, "12 4-bit page 1: depth and base taken at the frame's top", card.base_p, 16'hF008);
    // 2 bits, page 2 (base = 2 x 256 x 480 + $20 = 245,792 too); CLUT index 2
    // at (2 << 6) | $3F; pixel (6,479) is byte 1's third pair
    wr_byte(32'hF988003C, ~8'hD8);                             // register 15 = $D8: 2-bit
    wr_byte(32'hF989001C, 8'hBF);
    wr_byte(32'hF9890018, ~8'h9A); wr_byte(32'hF9890018, ~8'hBC); wr_byte(32'hF9890018, ~8'hDE);
    wr_byte(32'hF9000020 + 245760 + 479 * 256 + 1, 8'b00_00_10_00);
    tx[0] = 6; ty[0] = 479; tx[1] = 7; ty[1] = 479;
    i = frames; while (frames < i + 2) @(posedge clk);
    checkx(pix[0] == 24'h9ABCDE, "12 2-bit page 2: pixel (6,479), byte 1's third pair = entry 2", pix[0], 24'h9ABCDE);
    check(pix[1] !== 24'h9ABCDE, "12 2-bit page 2: its neighbour (7,479) is not (its entry, $C0, never written)", 0, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the IIcx's NuBus path", checks);
    else $display("==== FAIL: %0d of %0d checks failed", fails, checks);
    $finish;
  end

  initial begin #400_000_000; $display("==== FAIL: timeout"); $finish; end

endmodule
