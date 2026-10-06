// tb_se30_mfmread.v - the MFM read seam: image -> encoder -> track buffer
// -> drive -> SWIM's ISM -> the ROM's reads, held to SE30_PLAN.md 5.13,
// item 5 of 5.13.10's list (5.13.12 item 6).
//
// WHAT THIS PROVES
//   The real se30_swim, se30_fdhd and se30_flp_encoder, wired as the
//   machine and the top wire them, driven at the register level by the
//   ROM's own sequences at the ROM's pace:
//
//     1. the drive brought up from the ISM: the switch, the ROM's
//        parameter table ($4082E82E, reversed) and Setup $20, drive 1
//        enabled by mode bits 7 and 1, the drive's commands through the
//        phase register (motor on, MFM mode $6), $F reading a high-density
//        medium, /READY after the spin-up and the speed group's settle
//     2. a 1.44 MB disk, cylinder 0, both sides: every sector found by the
//        ROM's address-field read ($4082E9A6) - A1 A1 A1 FE through the
//        Mark register, C H R N, the handshake at CRC 2 `and #$22` = 0,
//        the error register 0 - and read by its data-field read
//        ($4082EA68): its 512 bytes the image's, byte for byte, the CRC
//        zero, no error; every byte inside the ROM's 31-poll budget; the
//        address fields read per sector found (1:1, the next sector's
//        address field after one gap 3)
//     3. a step to cylinder 1 and its side 1 the same way
//     4. a 720K disk (decision A: 600 rpm, the same parameters): $F reads
//        double density; cylinder 0, both sides, nine sectors each
//     5. an 800K GCR disk with the drive in MFM mode (the ROM tries a
//        double-density disk as MFM first, $4082E872): the address-field
//        read times out, and the ISM never locks
//
// THE BENCH
//   clk is FCLK (15.6672 MHz, c16_en tied high, as sim/gcrwrite).  The
//   image is a word memory answering the encoder's disk port in 3 to 8
//   clocks.  The drive's SEL is VIA1 PA5, a bench register.  The pace
//   (plan 1.17.5, the paced kernel): a handshake poll every 13 FCLK, a
//   first-byte wait loop of a VIA1 poll and a handshake poll (38 FCLK) per
//   turn, the set-up's writes 13 FCLK apart, 20 FCLK of bookkeeping after
//   each byte read.

`timescale 1ns/1ps

module tb_se30_mfmread;

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

  // ------------------------------------------------------------ the drive and the encoder
  reg        disk_in = 0, img_mfm = 1, img_hd = 1;
  wire [6:0] cyl, trk_cyl;
  wire       trk_valid, trk_side, trk_bit, trk_we, trk_wbit;
  wire [17:0] trk_addr, trk_cells;
  wire       en_req;
  wire [23:0] en_addr;
  reg  [15:0] en_rdata = 0;
  reg        en_ack = 0;

  se30_fdhd drive (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(ph_pin), .sel(via_sel), .sense(sense),
    .disk_in(disk_in), .eject(),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .hd(img_hd), .wprot(1'b1), .wrreq_n(wrreq_n), .wrdata(wrdata),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
    .arc_done(), .arc_side(), .arc_start(), .arc_end(), .arc_whole(),
    .dbg());

  se30_flp_encoder #(.BASE(BASE)) enc (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .img_ds(1'b1), .img_tags(1'b0), .img_800k(1'b1), .img_mfm(img_mfm), .img_hd(img_hd),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .hold(1'b0), .dec_addr(19'd0), .dec_bit(), .enc_idle(),
    .mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
    .dbg());

  // ------------------------------------------------------------ the image
  reg [15:0] mem [0:2880 * 256 - 1];
  integer mspt;                                  // 18 (1.44 MB) or 9 (720K)
  // block n's byte i: bytes 0-2 its cylinder, side and sector (1-based)
  function [7:0] mbyte(input integer n, input integer i);
    case (i)
      0: mbyte = n / (2 * mspt); 1: mbyte = (n / mspt) % 2; 2: mbyte = n % mspt + 1;
      default: mbyte = (n * 7 + i * 13 + (i >> 5)) & 8'hFF;
    endcase
  endfunction
  task build_image;
    integer n, i;
    for (n = 0; n < 160 * mspt; n = n + 1)
      for (i = 0; i < 256; i = i + 1) mem[n * 256 + i] = {mbyte(n, 2 * i), mbyte(n, 2 * i + 1)};
  endtask
  integer elat = 0, ehold = 0;
  always @(posedge clk) begin
    if (en_req && !en_ack) begin
      if (elat == 0) elat <= 3 + (cyc % 6);
      else if (elat == 1) begin en_ack <= 1; elat <= 0; en_rdata <= mem[en_addr - BASE]; end
      else elat <= elat - 1;
    end
    if (en_ack && !en_req) begin
      if (ehold == 1) begin en_ack <= 0; ehold <= 0; end else if (ehold == 0) ehold <= 2; else ehold <= ehold - 1;
    end
  end

  // the ISM's lock, watched (section 5)
  integer locks = 0;
  reg     lock_d = 0;
  always @(posedge clk) begin
    lock_d <= (swim.csm == 3'd4);
    if (swim.csm == 3'd4 && !lock_d) locks = locks + 1;
  end

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

  // the drive through the ISM: the phase register's levels are {LSTRB,
  // CA2, CA1, CA0}, all four outputs; SEL is VIA1 PA5.  n is the ROM's
  // register number {CA1, CA0, SEL, CA2}
  task ism_addr(input [3:0] n, input lstrb);
    begin #1 via_sel = n[1]; wr(16'h0800, {4'hF, lstrb, n[0], n[3], n[2]}); end
  endtask
  task ism_cmd(input [3:0] n);
    begin ism_addr(n, 0); ism_addr(n, 1); ism_addr(n, 0); end
  endtask
  reg sns;
  task ism_sense(input [3:0] n);                 // the handshake's bit 3: SENSE
    begin ism_addr(n, 0); rd(16'h1E00); sns = q[3]; end
  endtask
  task wait_ready;
    integer t;
    begin
      t = cyc; ism_sense(4'hB);
      while (sns && cyc - t < 30000000) begin repeat (5000) @(posedge clk); ism_sense(4'hB); end
    end
  endtask

  // ------------------------------------------------------------ the ROM's field reads
  // the set-up ($4082E9C6): the error register read, write and ACTION off,
  // Clear FIFO on and off, the error read, ACTION
  task arm;
    begin rd(16'h1400); wr(16'h0C00, 8'h18); wr(16'h0E00, 8'h01); wr(16'h0C00, 8'h01); rd(16'h1400); wr(16'h0E00, 8'h08); end
  endtask
  // the first byte's wait: a VIA1 poll (25 FCLK) and a handshake poll a
  // turn, `budget` turns (the D2 the caller shares); then the Mark read
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
  // a later byte: at most 31 polls (`moveq #$1E` ... `dbmi`), then the read
  integer maxpolls, over_budget;
  task next_byte;
    integer p;
    begin
      hs = 8'h00; p = 0;
      while (!hs[7] && p < 31) begin rd(16'h1E00); hs = q; p = p + 1; end
      if (p > maxpolls) maxpolls = p;
      if (!hs[7]) begin over_budget = over_budget + 1; timed_out = 1; end
      else begin rd(16'h1200); mv = q; repeat (20) @(posedge clk); end
    end
  endtask
  // $4082E9A6: the marks A1 A1 A1 FE (a mismatch re-arms, the budget
  // shared), then C H R N, CRC 1, CRC 2 - its handshake kept - and the
  // error register
  reg [7:0] fc, fh, fr, fn, hs_crc, er;
  task addr_read;
    integer k;
    reg ok;
    begin
      timed_out = 0; budget = 20000; ok = 0;
      while (!ok && !timed_out) begin
        arm; ok = 1;
        for (k = 0; k < 4 && ok && !timed_out; k = k + 1) begin
          first_byte;
          if (!timed_out && mv != ((k < 3) ? 8'hA1 : 8'hFE)) ok = 0;
        end
      end
      if (!timed_out) begin
        next_byte; fc = mv; next_byte; fh = mv; next_byte; fr = mv; next_byte; fn = mv;
        next_byte;                                // CRC 1
        next_byte; hs_crc = hs;                   // CRC 2: the handshake that saw it (D5)
        rd(16'h1400); er = q;
      end
    end
  endtask
  // $4082EA68: A1 A1 A1 FB (a mismatch is an error here), 512 bytes, the CRC
  reg [7:0] db [0:511];
  reg       data_marks_ok;
  task data_read;
    integer k;
    begin
      timed_out = 0; budget = 65535; data_marks_ok = 1;
      arm;
      for (k = 0; k < 4 && !timed_out; k = k + 1) begin
        first_byte;
        if (!timed_out && mv != ((k < 3) ? 8'hA1 : 8'hFB)) data_marks_ok = 0;
      end
      for (k = 0; k < 512 && !timed_out; k = k + 1) begin next_byte; db[k] = mv; end
      if (!timed_out) begin next_byte; next_byte; hs_crc = hs; rd(16'h1400); er = q; end
    end
  endtask

  // a side of a cylinder, sector by sector as the driver asks: address
  // fields until R is the one wanted, then its data field
  integer s_found, s_good, s_hdr_bad, s_reads, s_maxreads;
  task read_side(input integer c, input integer s);
    integer r, tries, k, n, mism;
    begin
      #1 via_sel = s;
      ism_addr({1'b0, 1'b0, s[0], 1'b1}, 0);      // RDDATA: $1 side 0, $3 side 1
      for (r = 1; r <= mspt; r = r + 1) begin
        tries = 0; fr = 0;
        while (fr != r && tries < 40) begin
          addr_read; tries = tries + 1;
          if (timed_out || ((hs_crc & 8'h22) != 0) || er != 0 || fc != c || fh != s || fn != 8'h02) s_hdr_bad = s_hdr_bad + 1;
        end
        s_reads = s_reads + tries;
        if (r > 1 && tries > s_maxreads) s_maxreads = tries;
        if (fr == r) begin
          s_found = s_found + 1;
          data_read;
          n = (2 * c + s) * mspt + r - 1; mism = 0;
          for (k = 0; k < 512; k = k + 1) if (db[k] !== mbyte(n, k)) mism = mism + 1;
          if (!timed_out && data_marks_ok && mism == 0 && (hs_crc & 8'h22) == 0 && er == 0) s_good = s_good + 1;
          else $display("     cylinder %0d side %0d sector %0d: marks %0d, %0d bytes differ, handshake %h, error %h, timed out %0d",
                        c, s, r, data_marks_ok, mism, hs_crc, er, timed_out);
        end
      end
    end
  endtask

  integer t0;
  reg [127:0] ptab;
  integer i;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. bring-up
    $display("---- 1. the drive brought up through the ISM");
    mspt = 18; build_image;
    #1 disk_in = 1; img_mfm = 1; img_hd = 1;
    // the IWM's mode $17, then the switch ($4082E6C0)
    rd(16'h1000); rd(16'h1A00); wr(16'h1E00, 8'h17); rd(16'h1C00); rd(16'h1800);
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    check(swim.ism == 1, "(the ISM)", swim.ism, 1);
    // $4082E79A: write, ACTION and HDSEL off, Setup $20, the parameter RAM
    wr(16'h0C00, 8'h38); wr(16'h0A00, 8'h20);
    ptab = 128'h3B571B97_19192F2F_1B1B1818_2E2E4118;
    wr(16'h0C00, 8'h38);
    for (i = 0; i < 16; i = i + 1) wr(16'h0600, ptab[8 * i +: 8]);
    wr(16'h0E00, 8'h82);                                  // MotorOn, drive 1
    check(!enbl1_n, "mode bits 7 and 1: drive 1 enabled", enbl1_n, 0);
    ism_sense(4'hF);
    check(sns == 0, "$F: a high-density medium (the 1.44 MB image)", sns, 0);
    ism_cmd(4'h8);                                        // the motor on
    ism_cmd(4'h6);                                        // MFM mode
    ism_sense(4'h7);
    check(sns == 1, "$7: MFM mode", sns, 1);
    t0 = cyc; wait_ready;
    check(!sns, "/READY: spun up, settled, cylinder 0 built", sns, 0);
    $display("     ready after %0d FCLK (%0d ms)", cyc - t0, (cyc - t0) / 15667);

    // ---- 2. cylinder 0, both sides
    $display("---- 2. a 1.44 MB disk: cylinder 0, both sides, the ROM's reads");
    s_found = 0; s_good = 0; s_hdr_bad = 0; s_reads = 0; s_maxreads = 0; maxpolls = 0; over_budget = 0;
    read_side(0, 0); read_side(0, 1);
    check(s_found == 36, "every sector's address field found, R = 1..18 on each side", s_found, 36);
    check(s_hdr_bad == 0, "  each: A1 A1 A1 FE, C H R N right, and #$22 = 0, error 0", s_hdr_bad, 0);
    check(s_good == 36, "every data field: its 512 bytes the image's, CRC zero, no error", s_good, 36);
    check(over_budget == 0, "every byte inside the ROM's 31 polls", over_budget, 0);
    $display("     most polls for a byte: %0d of 31; address fields read per sector (after the first): at most %0d, %0d in all for 36",
             maxpolls, s_maxreads, s_reads);
    check(s_maxreads == 1, "1:1 - the next sector's address field is the next one read", s_maxreads, 1);

    // ---- 3. a step, cylinder 1 side 1
    $display("---- 3. a step to cylinder 1");
    ism_cmd(4'h0);                                        // direction: in
    ism_cmd(4'h4);                                        // step
    t0 = cyc; wait_ready;
    check(!sns && cyl == 1, "/READY on cylinder 1", cyl, 1);
    s_found = 0; s_good = 0; s_hdr_bad = 0;
    read_side(1, 1);
    check(s_found == 18 && s_good == 18 && s_hdr_bad == 0, "cylinder 1 side 1: eighteen sectors, C = 1, H = 1", s_good, 18);

    // ---- 4. 720K
    $display("---- 4. a 720K disk: 600 rpm, the same parameters");
    ism_cmd(4'h9);                                        // the motor off, the disk changed
    #1 disk_in = 0; repeat (100) @(posedge clk);
    mspt = 9; build_image;
    #1 img_hd = 0; disk_in = 1;
    ism_sense(4'hF);
    check(sns == 1, "$F: double density", sns, 1);
    ism_cmd(4'h8);
    t0 = cyc; wait_ready;
    check(!sns, "/READY", sns, 0);
    // back to cylinder 0
    ism_cmd(4'h1); ism_cmd(4'h4); wait_ready;
    check(!sns && cyl == 0, "(cylinder 0)", cyl, 0);
    check(trk_cells == 100000, "100,000 cells a revolution (600 rpm)", trk_cells, 100000);
    s_found = 0; s_good = 0; s_hdr_bad = 0; maxpolls = 0; over_budget = 0;
    read_side(0, 0); read_side(0, 1);
    check(s_found == 18 && s_hdr_bad == 0, "cylinder 0: nine address fields a side, right", s_found, 18);
    check(s_good == 18, "  nine data fields a side, byte for byte", s_good, 18);
    check(over_budget == 0, "  inside the 31-poll budget", maxpolls, 31);

    // ---- 5. a GCR disk read as MFM
    $display("---- 5. an 800K GCR disk with the drive in MFM mode");
    ism_cmd(4'h9);
    #1 disk_in = 0; repeat (100) @(posedge clk);
    #1 img_mfm = 0; img_hd = 0; disk_in = 1;
    ism_cmd(4'h8);
    wait_ready;
    check(!sns, "(/READY: the GCR track built, the drive spinning at 600 rpm)", sns, 0);
    #1 via_sel = 0; ism_addr(4'h1, 0);
    locks = 0;
    addr_read;
    check(timed_out, "the ROM's address-field read times out (then GCR, $4082E872)", timed_out, 1);
    check(locks == 0, "  and the ISM never locked on the GCR flux", locks, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the MFM read seam holds to plan 5.13", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(64.0 * 120000000); $display("==== FAIL: timeout"); $finish; end

endmodule
