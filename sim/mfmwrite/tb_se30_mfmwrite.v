// tb_se30_mfmwrite.v - the MFM write seam: SWIM's ISM -> drive -> track
// buffer -> decoder -> image, and back out through the ISM's read chain,
// held to SE30_PLAN.md 5.16, item 5 of 5.16.7's list (5.16.11 item 6).
//
// WHAT THIS PROVES
//   The real se30_swim, se30_fdhd, se30_flp_encoder and se30_flp_decoder,
//   wired as the machine and the top wire them, driven at the register
//   level by the ROM's own sequences at the ROM's pace:
//
//     1. the drive brought up from the ISM as sim/mfmread brings it up (a
//        1.44 MB disk, MFM mode, /READY)
//     2. a sector written as the ROM's writer writes it ($4082EB3E): its
//        address field read first ($4082E9A6), then write mode, Clear
//        FIFO, the 0.459 ms delay, 00 00 into the FIFO, ACTION, ten more
//        00, A1 A1 A1 through the Mark register, FB, 512 new bytes, the
//        CRC register, four 4E, write mode off: no underrun; the sector's
//        512 bytes reach the image at its block (the decoder finding the
//        address field in its look-back), nothing else changes; then read
//        back by the ROM's own address- and data-field reads, byte for
//        byte, CRC zero
//     3. cylinder 1 formatted as the ROM's formatter formats it
//        ($4082EC5E), side 0 then side 1: the head selected (RDDATA0/1,
//        phases $F4), write mode, two 4E, ACTION, 4E until SENSE reads 0
//        and then 1 - the index, on RDDATA while the gate is low (5.16.4)
//        - then 32 x 4E and eighteen sectors (12 x 00, A1 A1 A1 FE C H R
//        02 CRC, 22 x 4E, 12 x 00, A1 A1 A1 FB, 512 x F6, CRC, 108 x 4E),
//        then 4E with phases $F4 until SENSE reads 1 (side 1; side 0 a few
//        bytes): the index found both times, no underrun; all 36 sectors
//        in the image as F6, nothing else changed; then every sector of
//        both sides read back by the ROM's reads: C = 1, H, R right, F6
//
// THE BENCH
//   clk is FCLK (15.6672 MHz, c16_en tied high, as sim/mfmread); the
//   encoder and decoder run on it too (the machine runs them on clk_sys,
//   twice as fast).  The image sits in a word memory served to the
//   encoder and written by the decoder.  The drive's SEL is VIA1 PA5, a
//   bench register.  The pace (plan 1.17.5): an access every 13 FCLK, a
//   write byte after a VIA1 poll (the driver's SCC check, 25 FCLK) and the
//   handshake polled until it shows a place free.

`timescale 1ns/1ps

module tb_se30_mfmwrite;

  localparam [23:0] BASE = 24'h800000;

  reg clk = 0;
  always #31.9149 clk = ~clk;
  reg reset_n = 0;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // ------------------------------------------------------------ the bus and the SWIM
  reg        sel = 0, strobe = 0;
  reg  [3:0] rs = 0;
  reg  [7:0] wdata = 8'hA5;
  wire [7:0] rdata;
  wire [3:0] ph_out, ph_oe;
  wire [3:0] ph_pin = (ph_oe & ph_out) | ~ph_oe;
  wire       enbl1_n, enbl2_n, wrdata, wrreq_n;
  reg        via_sel = 0;
  wire       sense;

  se30_swim swim (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .sel(sel), .strobe(strobe), .rs(rs), .wdata(wdata), .rdata(rdata),
    .ph_out(ph_out), .ph_oe(ph_oe), .ph_in(ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(sense),
    .wrdata(wrdata), .wrreq_n(wrreq_n), .hdsel(), .dbg(), .dbg_vread());

  // ------------------------------------------------------------ the drive and the chain
  reg        disk_in = 0;
  wire [6:0] cyl, trk_cyl;
  wire       trk_valid, trk_side, trk_bit, trk_we, trk_wbit;
  wire [17:0] trk_addr, trk_cells, arc_start, arc_end;
  wire       arc_done, arc_side, arc_whole;
  wire       hold, dec_bit, enc_idle, ds_eff;
  wire [18:0] dec_addr;
  wire       en_req, de_req, cm_done;
  wire [23:0] en_addr, de_addr;
  wire [15:0] de_wdata;
  reg  [15:0] en_rdata = 0;
  reg        en_ack = 0, de_ack = 0;
  wire [11:0] cm_blk;
  wire [31:0] ddbg;

  se30_fdhd drive (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(ph_pin), .sel(via_sel), .sense(sense),
    .disk_in(disk_in), .eject(),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .hd(1'b1), .wprot(1'b0), .wrreq_n(wrreq_n), .wrdata(wrdata),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
    .dbg());

  se30_flp_encoder #(.BASE(BASE)) enc (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .img_ds(1'b1), .img_tags(1'b0), .img_800k(1'b0), .img_mfm(1'b1), .img_hd(1'b1),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .hold(hold), .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle),
    .mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
    .dbg());

  se30_flp_decoder #(.BASE(BASE)) dec (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .loading(1'b0), .write_ok(1'b1),
    .img_ds(1'b1), .img_800k(1'b0), .img_tags(1'b0), .img_mfm(1'b1), .img_hd(1'b1), .ds_eff(ds_eff),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end),
    .arc_whole(arc_whole), .trk_cells(trk_cells), .cyl(cyl),
    .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle), .hold(hold),
    .mem_req(de_req), .mem_addr(de_addr), .mem_wdata(de_wdata), .mem_ack(de_ack),
    .cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(1'b1),
    .dbg(ddbg));

  // ------------------------------------------------------------ the image
  localparam integer MEMW = 2880 * 256;
  reg [15:0] mem  [0:MEMW - 1];
  reg [15:0] want [0:MEMW - 1];
  // block n's byte i: bytes 0-2 its cylinder, side and sector (sim/mfmread's)
  function [7:0] mbyte(input integer n, input integer i);
    case (i)
      0: mbyte = n / 36; 1: mbyte = (n / 18) % 2; 2: mbyte = n % 18 + 1;
      default: mbyte = (n * 7 + i * 13 + (i >> 5)) & 8'hFF;
    endcase
  endfunction
  integer n, i, k, diffs;
  task build_image;
    for (n = 0; n < 2880; n = n + 1)
      for (i = 0; i < 256; i = i + 1) begin mem[n * 256 + i] = {mbyte(n, 2 * i), mbyte(n, 2 * i + 1)}; want[n * 256 + i] = mem[n * 256 + i]; end
  endtask
  task compare_image;
    begin diffs = 0; for (n = 0; n < MEMW; n = n + 1) if (mem[n] !== want[n]) diffs = diffs + 1; end
  endtask
  integer elat = 0, ehold = 0, dlat = 0, dhold = 0;
  always @(posedge clk) begin
    if (en_req && !en_ack) begin
      if (elat == 0) elat <= 3 + (cyc % 6);
      else if (elat == 1) begin en_ack <= 1; elat <= 0; en_rdata <= mem[en_addr - BASE]; end
      else elat <= elat - 1;
    end
    if (en_ack && !en_req) begin
      if (ehold == 1) begin en_ack <= 0; ehold <= 0; end else if (ehold == 0) ehold <= 2; else ehold <= ehold - 1;
    end
    if (de_req && !de_ack) begin
      if (dlat == 0) dlat <= 3 + (cyc % 6);
      else if (dlat == 1) begin de_ack <= 1; dlat <= 0; mem[de_addr - BASE] <= de_wdata; end
      else dlat <= dlat - 1;
    end
    if (de_ack && !de_req) begin
      if (dhold == 1) begin de_ack <= 0; dhold <= 0; end else if (dhold == 0) dhold <= 2; else dhold <= dhold - 1;
    end
  end
  integer ncm = 0;
  integer cmb [0:63];
  always @(posedge clk) if (cm_done) begin if (ncm < 64) cmb[ncm] = cm_blk; ncm = ncm + 1; end

  // ------------------------------------------------------------ the ROM's accesses
  reg [7:0] q;
  task access(input [15:0] off, input [7:0] d);
    begin
      @(posedge clk); #1 rs = off[12:9]; wdata = d; sel = 1;
      @(posedge clk); @(posedge clk);
      #1 strobe = 1;
      @(posedge clk);
      q = rdata;
      #1 strobe = 0; sel = 0; wdata = 8'hA5;
    end
  endtask
  // an access at the ROM's pace: 13 FCLK strobe to strobe (an access is 4)
  task rd(input [15:0] off);               begin access(off, 8'hA5); repeat (9) @(posedge clk); end endtask
  task wr(input [15:0] off, input [7:0] d); begin access(off, d); repeat (9) @(posedge clk); end endtask
  // the drive through the ISM ($4082E8E0): phases {LSTRB, CA2, CA1, CA0},
  // SEL by VIA1 PA5; n is the ROM's register number {CA1, CA0, SEL, CA2}
  task ism_addr(input [3:0] n, input lstrb);
    begin #1 via_sel = n[1]; wr(16'h0800, {4'hF, lstrb, n[0], n[3], n[2]}); end
  endtask
  task ism_cmd(input [3:0] n);
    begin ism_addr(n, 0); ism_addr(n, 1); ism_addr(n, 0); end
  endtask
  reg sns;
  task ism_sense(input [3:0] n);
    begin ism_addr(n, 0); rd(16'h1E00); sns = q[3]; end
  endtask
  task wait_ready;
    integer t;
    begin
      t = cyc; ism_sense(4'hB);
      while (sns && cyc - t < 30000000) begin repeat (5000) @(posedge clk); ism_sense(4'hB); end
    end
  endtask
  // the decoder done with the written cylinder
  task wait_decoded;
    integer t;
    begin
      t = cyc; repeat (8) @(posedge clk);
      while (hold && cyc - t < 4000000) @(posedge clk);
      repeat (8) @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------ the ROM's reads (sim/mfmread's)
  task arm;
    begin rd(16'h1400); wr(16'h0C00, 8'h18); wr(16'h0E00, 8'h01); wr(16'h0C00, 8'h01); rd(16'h1400); wr(16'h0E00, 8'h08); end
  endtask
  reg [7:0] hs, mv;
  integer   budget;
  reg       timed_out;
  task first_byte;
    begin
      hs = 8'h00;
      while (!hs[7] && budget > 0) begin repeat (25) @(posedge clk); rd(16'h1E00); hs = q; budget = budget - 1; end
      if (!hs[7]) timed_out = 1;
      else begin rd(16'h1200); mv = q; repeat (20) @(posedge clk); end
    end
  endtask
  integer over_budget;
  task next_byte;
    integer p;
    begin
      hs = 8'h00; p = 0;
      while (!hs[7] && p < 31) begin rd(16'h1E00); hs = q; p = p + 1; end
      if (!hs[7]) begin over_budget = over_budget + 1; timed_out = 1; end
      else begin rd(16'h1200); mv = q; repeat (20) @(posedge clk); end
    end
  endtask
  reg [7:0] fc, fh, fr, fn, hs_crc, er;
  task addr_read;
    integer k2;
    reg ok;
    begin
      timed_out = 0; budget = 20000; ok = 0;
      while (!ok && !timed_out) begin
        arm; ok = 1;
        for (k2 = 0; k2 < 4 && ok && !timed_out; k2 = k2 + 1) begin
          first_byte;
          if (!timed_out && mv != ((k2 < 3) ? 8'hA1 : 8'hFE)) ok = 0;
        end
      end
      if (!timed_out) begin
        next_byte; fc = mv; next_byte; fh = mv; next_byte; fr = mv; next_byte; fn = mv;
        next_byte; next_byte; hs_crc = hs;
        rd(16'h1400); er = q;
      end
    end
  endtask
  reg [7:0] db [0:511];
  reg       data_marks_ok;
  task data_read;
    integer k2;
    begin
      timed_out = 0; budget = 65535; data_marks_ok = 1;
      arm;
      for (k2 = 0; k2 < 4 && !timed_out; k2 = k2 + 1) begin
        first_byte;
        if (!timed_out && mv != ((k2 < 3) ? 8'hA1 : 8'hFB)) data_marks_ok = 0;
      end
      for (k2 = 0; k2 < 512 && !timed_out; k2 = k2 + 1) begin next_byte; db[k2] = mv; end
      if (!timed_out) begin next_byte; next_byte; hs_crc = hs; rd(16'h1400); er = q; end
    end
  endtask
  // address fields until R is `r` on cylinder c side s (40 tries)
  integer tries;
  task find_sector(input integer c, input integer s, input integer r);
    begin
      tries = 0; fr = 0;
      while (!(fr == r && fc == c && fh == s) && tries < 40) begin addr_read; tries = tries + 1; end
    end
  endtask

  // ------------------------------------------------------------ the ROM's writes
  // a byte: the driver's SCC check (a VIA1 poll), the handshake polled
  // until a place is free, then the write
  reg [7:0] whs;
  integer   wpolls_max;
  task w_byte(input [15:0] off, input [7:0] v);
    integer p;
    begin
      repeat (25) @(posedge clk);
      p = 0; rd(16'h1E00);
      while (!q[7] && p < 4000) begin rd(16'h1E00); p = p + 1; end
      if (p > wpolls_max) wpolls_max = p;
      whs = q;
      wr(off, v);
    end
  endtask
  // the set-up ($4082EB4C / $4082EC7E): the error register read, write and
  // ACTION off, write mode, Clear FIFO on and off, the error read
  task w_arm;
    begin rd(16'h1400); wr(16'h0C00, 8'h18); wr(16'h0E00, 8'h10); wr(16'h0E00, 8'h01); wr(16'h0C00, 8'h01); rd(16'h1400); end
  endtask
  reg [7:0] wsec [0:511];
  reg       w_err;
  // $4082EB3E: after its address field
  task rom_write_sector;
    integer k2;
    begin
      wr(16'h0800, 8'hF5);
      w_arm;
      repeat (7191) @(posedge clk);                       // $758E x TimeSCCDB / 65,536: 0.459 ms
      wr(16'h0000, 8'h00); wr(16'h0000, 8'h00);
      wr(16'h0E00, 8'h08);                                // ACTION
      for (k2 = 0; k2 < 10; k2 = k2 + 1) w_byte(16'h0000, 8'h00);
      for (k2 = 0; k2 < 3; k2 = k2 + 1) w_byte(16'h0200, 8'hA1);
      w_byte(16'h0000, 8'hFB);
      for (k2 = 0; k2 < 512; k2 = k2 + 1) w_byte(16'h0000, wsec[k2]);
      w_byte(16'h0400, 8'h00);                            // the CRC
      for (k2 = 0; k2 < 4; k2 = k2 + 1) w_byte(16'h0000, 8'h4E);
      w_err = whs[5];
      wr(16'h0C00, 8'h18);
    end
  endtask
  // $4082EC5E: one side of cylinder c, 18 sectors of F6
  integer idx_wait, idx_ok, tail;
  task rom_format_side(input integer c, input integer s);
    integer k2, r, p;
    begin
      ism_addr({2'b00, s[0], 1'b1}, 0);                   // RDDATA0/1: the head ($4082E0EC -> $4082E8E0)
      w_arm;
      wr(16'h0000, 8'h4E); wr(16'h0000, 8'h4E);
      wr(16'h0E00, 8'h08);
      // 4E while SENSE reads 1, then while it reads 0: the index's rising edge
      idx_ok = 0; idx_wait = 0; p = 0;
      while (idx_wait < 13500 && !idx_ok) begin
        w_byte(16'h0000, 8'h4E); idx_wait = idx_wait + 1;
        if (p == 0 && !whs[3]) p = 1;
        else if (p == 1 && whs[3]) idx_ok = 1;
      end
      wr(16'h0800, 8'hF5);
      for (k2 = 0; k2 < 32; k2 = k2 + 1) w_byte(16'h0000, 8'h4E);
      for (r = 1; r <= 18; r = r + 1) begin
        for (k2 = 0; k2 < 12; k2 = k2 + 1) w_byte(16'h0000, 8'h00);
        for (k2 = 0; k2 < 3; k2 = k2 + 1) w_byte(16'h0200, 8'hA1);
        w_byte(16'h0000, 8'hFE); w_byte(16'h0000, c); w_byte(16'h0000, s); w_byte(16'h0000, r); w_byte(16'h0000, 8'h02);
        w_byte(16'h0400, 8'h00);
        for (k2 = 0; k2 < 22; k2 = k2 + 1) w_byte(16'h0000, 8'h4E);
        for (k2 = 0; k2 < 12; k2 = k2 + 1) w_byte(16'h0000, 8'h00);
        for (k2 = 0; k2 < 3; k2 = k2 + 1) w_byte(16'h0200, 8'hA1);
        w_byte(16'h0000, 8'hFB);
        for (k2 = 0; k2 < 512; k2 = k2 + 1) w_byte(16'h0000, 8'hF6);
        w_byte(16'h0400, 8'h00);
        for (k2 = 0; k2 < 108; k2 = k2 + 1) w_byte(16'h0000, 8'h4E);
      end
      // the tail ($4082EDF0): four 4E, phases $F4, then 4E until SENSE
      // reads 1 - side 1 up to 1,000 bytes, side 0 about seven
      tail = 0; p = (s == 0) ? 4 : 1000;
      for (k2 = 0; k2 < 4; k2 = k2 + 1) w_byte(16'h0000, 8'h4E);
      wr(16'h0800, 8'hF4);
      w_byte(16'h0000, 8'h4E);
      while (!whs[3] && tail < p) begin w_byte(16'h0000, 8'h4E); tail = tail + 1; end
      w_err = whs[5];
      wr(16'h0C00, 8'h18);
    end
  endtask

  integer t0, k3, bad, good;
  reg [127:0] ptab;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. bring-up
    $display("---- 1. the drive brought up through the ISM (a 1.44 MB disk)");
    build_image;
    #1 disk_in = 1;
    rd(16'h1000); rd(16'h1A00); wr(16'h1E00, 8'h17); rd(16'h1C00); rd(16'h1800);
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    check(swim.ism == 1, "(the ISM)", swim.ism, 1);
    wr(16'h0C00, 8'h38); wr(16'h0A00, 8'h20);
    ptab = 128'h3B571B97_19192F2F_1B1B1818_2E2E4118;
    wr(16'h0C00, 8'h38);
    for (i = 0; i < 16; i = i + 1) wr(16'h0600, ptab[8 * i +: 8]);
    wr(16'h0E00, 8'h82);
    ism_cmd(4'h8); ism_cmd(4'h6);
    wait_ready;
    check(!sns, "/READY: MFM mode, spun up, cylinder 0 built", sns, 0);

    // ---- 2. a sector written, then read back
    $display("---- 2. the ROM's sector write: cylinder 0 side 0 R 7");
    for (k = 0; k < 512; k = k + 1) wsec[k] = ((k * 5 + 8'h33) ^ (k >> 4)) & 8'hFF;
    for (k = 0; k < 256; k = k + 1) want[6 * 256 + k] = {wsec[2 * k], wsec[2 * k + 1]};
    #1 via_sel = 0; ism_addr(4'h1, 0);
    over_budget = 0;
    find_sector(0, 0, 7);
    check(fr == 7 && fc == 0 && fh == 0, "its address field found (C 0, H 0, R 7)", fr, 7);
    ncm = 0; wpolls_max = 0;
    rom_write_sector;
    check(!w_err, "no underrun (the handshake's error bit after the last byte)", w_err, 0);
    rd(16'h1400);
    check(q == 0, "  the error register 0", q, 0);
    wait_decoded;
    check(ncm == 1 && cmb[0] == 6, "committed once, to block 6 ((2C + H) x 18 + R - 1)", cmb[0], 6);
    compare_image;
    check(diffs == 0, "  its 512 bytes in the image, nothing else changed", diffs, 0);
    ism_addr(4'h1, 0);                                    // the write left phases $F5: the head again, as the ROM's reads do
    find_sector(0, 0, 7);
    data_read;
    bad = 0; for (k = 0; k < 512; k = k + 1) if (db[k] !== wsec[k]) bad = bad + 1;
    check(!timed_out && data_marks_ok && bad == 0 && (hs_crc & 8'h22) == 0 && er == 0,
          "read back by the ROM's reads: A1 A1 A1 FB, the 512 new bytes, CRC zero, no error", bad, 0);
    find_sector(0, 0, 8);
    data_read;
    bad = 0; for (k = 0; k < 512; k = k + 1) if (db[k] !== mbyte(7, k)) bad = bad + 1;
    check(!timed_out && bad == 0 && (hs_crc & 8'h22) == 0, "  and R 8 after it untouched (the splice ends in gap 3)", bad, 0);

    // ---- 3. a format of cylinder 1
    $display("---- 3. the ROM's format of cylinder 1, side 0 then side 1");
    ism_cmd(4'h0); ism_cmd(4'h4);
    wait_ready;
    check(!sns && cyl == 1, "(cylinder 1)", cyl, 1);
    for (k3 = 0; k3 < 2; k3 = k3 + 1) begin
      ncm = 0;
      rom_format_side(1, k3);
      check(idx_ok && idx_wait < 13500, (k3 == 0) ? "side 0: the index found on RDDATA0 while writing (no fmt2Err)"
                                                  : "side 1: the index found on RDDATA1 while writing", idx_wait, 0);
      if (k3 == 1) check(whs[3], "  side 1's tail ends at the next index (no fmt2Err)", tail, 192);
      check(!w_err, "  no underrun", w_err, 0);
      $display("     side %0d: %0d bytes before the index, a tail of %0d", k3, idx_wait, tail);
      wait_decoded;
      check(ncm == 18, "  18 sectors committed, once each", ncm, 18);
      for (i = 1; i <= 18; i = i + 1) for (k = 0; k < 256; k = k + 1) want[((2 + k3) * 18 + i - 1) * 256 + k] = 16'hF6F6;
    end
    compare_image;
    check(diffs == 0, "the image: cylinder 1's 36 sectors F6, nothing else changed", diffs, 0);
    good = 0; bad = 0;
    for (k3 = 0; k3 < 2; k3 = k3 + 1) begin
      #1 via_sel = k3; ism_addr({2'b00, k3[0], 1'b1}, 0);
      for (i = 1; i <= 18; i = i + 1) begin
        find_sector(1, k3, i);
        if (fr == i && fc == 1 && fh == k3 && fn == 2 && (hs_crc & 8'h22) == 0) begin
          data_read;
          n = 0; for (k = 0; k < 512; k = k + 1) if (db[k] !== 8'hF6) n = n + 1;
          if (!timed_out && data_marks_ok && n == 0 && (hs_crc & 8'h22) == 0 && er == 0) good = good + 1;
          else bad = bad + 1;
        end else bad = bad + 1;
      end
    end
    check(good == 36 && bad == 0, "every formatted sector read back by the ROM's reads: C 1, H, R, N 2, F6, CRC zero", good, 36);
    check(over_budget == 0, "  every byte inside the ROM's 31 polls", over_budget, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the MFM write seam holds to plan 5.16", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(64.0 * 200000000); $display("==== FAIL: timeout"); $finish; end

endmodule
