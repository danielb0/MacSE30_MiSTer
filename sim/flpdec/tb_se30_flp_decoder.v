// tb_se30_flp_decoder.v - the written-track decoder held to SE30_PLAN.md
// 5.15.5 items 4, 5 and 7, item 3 of 5.15.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_flp_decoder.v reads back what was written into the track
//   buffer and puts the good data fields into the image, and nothing else:
//
//     1. a whole-revolution arc over a track the encoder built from the
//        image: all 12 sectors of the side decoded and committed once
//        each, to their own blocks, the image unchanged (it wrote back
//        what it read) - the decoder agrees with the encoder's layout
//     2. a sector written as the ROM's writer writes it ($4082E518: sync,
//        D5 AA AD, the sector's code, 703 codes nibbled by the ERS's steps,
//        DE AA FF FF) over the old one: that sector's 512 data bytes and
//        12 tags reach the image, and no other word changes
//     3. a data field with a bad checksum: refused, the image unchanged
//     4. a field cut by the arc's end: not committed
//     5. a sector number past the zone's count (zone 4, 8 sectors):
//        refused
//     6. an image without tags: the data committed, the tag region not
//        touched
//     7. a format of a side (5.15.4: 1,200 sync bytes, then every sector's
//        sync, address field and a field of zeros - about 1.13
//        revolutions, overrunning its own start): every sector committed
//        once, as zeros; a one-sided format ($02) of an 800K image turns
//        the layout single-sided at once (ds_eff; the LC's 6B) and the
//        sectors land in the 400K layout's blocks
//     8. nothing committed while the image is read-only or loading
//        (MacPlus defect 3)
//     9. the SD writer's back-pressure: a commit offered while cm_ready
//        is low waits, and `hold` keeps the encoder from rebuilding until
//        the decoder is done
//    10. the disk port's handshake throughout: no request torn down
//        before its acknowledge, its address and data held, none raised
//        over a stale acknowledge
//
// THE BENCH
//   clk is clk_sys (31.3344 MHz).  The encoder is the real one, building
//   cylinders from an image in a word memory (as sim/flpenc: each block's
//   bytes 0-2 its cylinder, side and sector); the drive is the bench,
//   writing cells through the encoder's port A one a clock and raising the
//   arc as se30_fdhd does.  The memory answers the encoder's reads and the
//   decoder's writes on separate ports, after 3 to 12 clocks.

`timescale 1ns/1ps

module tb_se30_flp_decoder;

  localparam [23:0] BASE  = 24'h800000;
  localparam [18:0] SIDE1 = 19'd200000;

  reg clk = 0;
  always #16 clk = ~clk;
  reg reset_n = 0;

  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // ------------------------------------------------------------ the DUTs
  reg        disk_in = 0, loading = 0, write_ok = 1, img_ds = 1, img_tags = 1, img_800k = 1;
  reg  [6:0] cyl = 0;
  wire [6:0] trk_cyl;
  wire       trk_valid;
  reg [17:0] trk_addr = 0;
  reg        trk_side = 0;
  wire       trk_bit;
  reg        trk_we = 0, trk_wbit = 0;
  wire       hold, dec_bit, enc_idle, ds_eff;
  wire [18:0] dec_addr;
  wire       en_req, de_req;
  wire [23:0] en_addr, de_addr;
  wire [15:0] de_wdata;
  reg  [15:0] en_rdata = 0;
  reg        en_ack = 0, de_ack = 0;
  reg        arc_done = 0, arc_side = 0, arc_whole = 0;
  reg [17:0] arc_start = 0, arc_end = 0, trk_cells = 74558;
  wire       cm_done;
  wire [10:0] cm_blk;
  reg        cm_ready = 1;
  wire [31:0] ddbg;

  se30_flp_encoder #(.BASE(BASE)) enc (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .img_ds(ds_eff), .img_tags(img_tags), .img_800k(img_800k), .img_mfm(1'b0), .img_hd(1'b0),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .hold(hold), .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle),
    .mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
    .dbg());

  se30_flp_decoder #(.BASE(BASE)) dut (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .loading(loading), .write_ok(write_ok),
    .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags), .ds_eff(ds_eff),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end),
    .arc_whole(arc_whole), .trk_cells(trk_cells), .cyl(cyl),
    .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle), .hold(hold),
    .mem_req(de_req), .mem_addr(de_addr), .mem_wdata(de_wdata), .mem_ack(de_ack),
    .cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(cm_ready),
    .dbg(ddbg));

  // ------------------------------------------------------------ geometry
  function integer spt(input integer c);
    spt = 12 - c / 16;
  endfunction
  function integer secs_before(input integer c);
    integer g;
    begin
      secs_before = 0;
      for (g = 0; g < c / 16; g = g + 1) secs_before = secs_before + 16 * (12 - g);
      secs_before = secs_before + (c % 16) * spt(c);
    end
  endfunction
  function integer cells(input integer c);
    case (c / 16)
      0: cells = 74558; 1: cells = 68476; 2: cells = 62237; 3: cells = 55954; default: cells = 49790;
    endcase
  endfunction
  function integer leftover(input integer c);
    leftover = cells(c) - spt(c) * 6208;
  endfunction
  function integer il(input integer n, input integer i);   // the formatter's order ($408321CA)
    il = (i % 2 == 0) ? i / 2 : (n - 1) / 2 + 1 + (i - 1) / 2;
  endfunction
  function integer slot_of(input integer n, input integer k);  // where sector k sits
    integer i;
    begin
      slot_of = 0;
      for (i = 0; i < n; i = i + 1) if (il(n, i) == k) slot_of = i;
    end
  endfunction
  function integer blk_of(input integer c, input integer s, input integer k, input integer ds);
    blk_of = (ds ? 2 : 1) * secs_before(c) + (s ? spt(c) : 0) + k;
  endfunction

  // ------------------------------------------------------------ the image
  integer blocks;
  reg [15:0] mem [0:1600*256 + 1600*6 - 1];
  reg [15:0] want [0:1600*256 + 1600*6 - 1];     // what the memory should hold
  function [7:0] dimg(input integer n, input integer i);   // block n's data byte i
    dimg = (n * 7 + i * 13) & 8'hFF;
  endfunction
  function [7:0] timg(input integer n, input integer j);   // its tag byte j
    timg = (n * 5 + j * 31 + 1) & 8'hFF;
  endfunction
  task build_image;
    integer n, i, j;
    begin
      blocks = 1600;
      for (n = 0; n < 1600 * 256 + 1600 * 6; n = n + 1) begin mem[n] = 16'hDEAD; want[n] = 16'hDEAD; end
      for (n = 0; n < blocks; n = n + 1) begin
        for (i = 0; i < 256; i = i + 1) begin
          mem[n * 256 + i] = {dimg(n, 2 * i), dimg(n, 2 * i + 1)};
          want[n * 256 + i] = mem[n * 256 + i];
        end
        if (img_tags) for (j = 0; j < 6; j = j + 1) begin
          mem[blocks * 256 + n * 6 + j] = {timg(n, 2 * j), timg(n, 2 * j + 1)};
          want[blocks * 256 + n * 6 + j] = mem[blocks * 256 + n * 6 + j];
        end
      end
    end
  endtask
  integer diffs;
  task compare_image;
    integer n;
    begin
      diffs = 0;
      for (n = 0; n < 1600 * 256 + 1600 * 6; n = n + 1) if (mem[n] !== want[n]) diffs = diffs + 1;
    end
  endtask

  // ------------------------------------------------------------ the memory
  // the encoder's reads
  integer elat = 0, ehold = 0;
  always @(posedge clk) begin
    if (en_req && !en_ack) begin
      if (elat == 0) elat <= 3 + (cyc % 10);
      else if (elat == 1) begin
        en_ack <= 1; elat <= 0;
        en_rdata <= (en_addr >= BASE && en_addr - BASE < 1600*256 + 1600*6) ? mem[en_addr - BASE] : 16'hBAD0;
      end else elat <= elat - 1;
    end
    if (en_ack && !en_req) begin
      if (ehold == 1) begin en_ack <= 0; ehold <= 0; end
      else if (ehold == 0) ehold <= 2;
      else ehold <= ehold - 1;
    end
  end
  // the decoder's writes, and the handshake's rules
  integer dlat = 0, dhold = 0, nwr = 0, torn = 0, moved = 0, early = 0, wild = 0;
  reg     dreq_d = 0;
  reg [23:0] daddr_d;
  reg [15:0] dwd_d;
  always @(posedge clk) begin
    dreq_d <= de_req; daddr_d <= de_addr; dwd_d <= de_wdata;
    if (dreq_d && !de_req && !de_ack) torn <= torn + 1;
    if (dreq_d && de_req && !de_ack && (de_addr != daddr_d || de_wdata != dwd_d)) moved <= moved + 1;
    if (de_req && !dreq_d && de_ack) early <= early + 1;
    if (de_req && !de_ack) begin
      if (dlat == 0) dlat <= 3 + (cyc % 10);
      else if (dlat == 1) begin
        de_ack <= 1; dlat <= 0; nwr <= nwr + 1;
        if (de_addr >= BASE && de_addr - BASE < 1600*256 + 1600*6) mem[de_addr - BASE] <= de_wdata;
        else wild <= wild + 1;
      end else dlat <= dlat - 1;
    end
    if (de_ack && !de_req) begin
      if (dhold == 1) begin de_ack <= 0; dhold <= 0; end
      else if (dhold == 0) dhold <= 2;
      else dhold <= dhold - 1;
    end
  end
  // the commits
  integer ncm = 0;
  integer cmb [0:63];
  always @(posedge clk) if (cm_done) begin if (ncm < 64) cmb[ncm] = cm_blk; ncm = ncm + 1; end

  // ------------------------------------------------------------ GCR and the fields
  function [7:0] gcr(input [5:0] v);
    begin
      case (v)
        6'h00: gcr = 8'h96; 6'h01: gcr = 8'h97; 6'h02: gcr = 8'h9A; 6'h03: gcr = 8'h9B;
        6'h04: gcr = 8'h9D; 6'h05: gcr = 8'h9E; 6'h06: gcr = 8'h9F; 6'h07: gcr = 8'hA6;
        6'h08: gcr = 8'hA7; 6'h09: gcr = 8'hAB; 6'h0A: gcr = 8'hAC; 6'h0B: gcr = 8'hAD;
        6'h0C: gcr = 8'hAE; 6'h0D: gcr = 8'hAF; 6'h0E: gcr = 8'hB2; 6'h0F: gcr = 8'hB3;
        6'h10: gcr = 8'hB4; 6'h11: gcr = 8'hB5; 6'h12: gcr = 8'hB6; 6'h13: gcr = 8'hB7;
        6'h14: gcr = 8'hB9; 6'h15: gcr = 8'hBA; 6'h16: gcr = 8'hBB; 6'h17: gcr = 8'hBC;
        6'h18: gcr = 8'hBD; 6'h19: gcr = 8'hBE; 6'h1A: gcr = 8'hBF; 6'h1B: gcr = 8'hCB;
        6'h1C: gcr = 8'hCD; 6'h1D: gcr = 8'hCE; 6'h1E: gcr = 8'hCF; 6'h1F: gcr = 8'hD3;
        6'h20: gcr = 8'hD6; 6'h21: gcr = 8'hD7; 6'h22: gcr = 8'hD9; 6'h23: gcr = 8'hDA;
        6'h24: gcr = 8'hDB; 6'h25: gcr = 8'hDC; 6'h26: gcr = 8'hDD; 6'h27: gcr = 8'hDE;
        6'h28: gcr = 8'hDF; 6'h29: gcr = 8'hE5; 6'h2A: gcr = 8'hE6; 6'h2B: gcr = 8'hE7;
        6'h2C: gcr = 8'hE9; 6'h2D: gcr = 8'hEA; 6'h2E: gcr = 8'hEB; 6'h2F: gcr = 8'hEC;
        6'h30: gcr = 8'hED; 6'h31: gcr = 8'hEE; 6'h32: gcr = 8'hEF; 6'h33: gcr = 8'hF2;
        6'h34: gcr = 8'hF3; 6'h35: gcr = 8'hF4; 6'h36: gcr = 8'hF5; 6'h37: gcr = 8'hF6;
        6'h38: gcr = 8'hF7; 6'h39: gcr = 8'hF9; 6'h3A: gcr = 8'hFA; 6'h3B: gcr = 8'hFB;
        6'h3C: gcr = 8'hFC; 6'h3D: gcr = 8'hFD; 6'h3E: gcr = 8'hFE; default: gcr = 8'hFF;
      endcase
    end
  endfunction

  // a stream of bytes to write, as the ROM puts them on the disk
  reg  [7:0] fb [0:12000];
  integer nfb;
  task put(input [7:0] b); begin fb[nfb] = b; nfb = nfb + 1; end endtask
  task put_sync; begin put(8'hFF); put(8'h3F); put(8'hCF); put(8'hF3); put(8'hFC); put(8'hFF); end endtask

  // the 524 bytes of a sector (12 tags, then 512 data)
  reg [7:0] sec [0:523];
  // a data field as the ROM's writer writes it: sync, D5 AA AD, the
  // sector's code, the 703 codes (the ERS's steps 1-9), DE AA FF FF;
  // `spoil` flips the checksum's last code
  task put_data_field(input integer k, input integer spoil);
    integer g, b;
    reg [7:0] A, B, C, ca, cb, cc, rot, Ap, Bp, Cp;
    reg [8:0] sa, sb, sc;
    begin
      put_sync;
      put(8'hD5); put(8'hAA); put(8'hAD); put(gcr(k));
      ca = 0; cb = 0; cc = 0;
      for (g = 0; g < 175; g = g + 1) begin
        b = 3 * g;
        A = sec[b]; B = sec[b + 1]; C = (g == 174) ? 8'h00 : sec[b + 2];
        rot = {cc[6:0], cc[7]};
        sa = ca + A + cc[7]; Ap = A ^ rot;
        sb = cb + B + sa[8]; Bp = B ^ sa[7:0];
        if (g == 174) begin
          ca = sa[7:0]; cb = sb[7:0]; cc = rot;
          put(gcr({Ap[7:6], Bp[7:6], 2'b00})); put(gcr(Ap[5:0])); put(gcr(Bp[5:0]));
        end else begin
          sc = rot + C + sb[8]; Cp = C ^ sb[7:0];
          ca = sa[7:0]; cb = sb[7:0]; cc = sc[7:0];
          put(gcr({Ap[7:6], Bp[7:6], Cp[7:6]})); put(gcr(Ap[5:0])); put(gcr(Bp[5:0])); put(gcr(Cp[5:0]));
        end
      end
      put(gcr({ca[7:6], cb[7:6], cc[7:6]})); put(gcr(ca[5:0])); put(gcr(cb[5:0]));
      put(spoil ? gcr(cc[5:0] ^ 6'h01) : gcr(cc[5:0]));
      put(8'hDE); put(8'hAA); put(8'hFF); put(8'hFF);
    end
  endtask
  task put_addr_field(input integer c, input integer k, input integer s, input [5:0] fmt);
    reg [5:0] t, sc, sd;
    begin
      t = c[5:0]; sc = k[5:0]; sd = {s[0], 4'b0000, c[6]};
      put(8'hD5); put(8'hAA); put(8'h96);
      put(gcr(t)); put(gcr(sc)); put(gcr(sd)); put(gcr(fmt)); put(gcr(t ^ sc ^ sd ^ fmt));
      put(8'hDE); put(8'hAA); put(8'hFF);
    end
  endtask

  // write the byte stream into side `s` from cell `start`, a cell a clock,
  // wrapping at the revolution; the arc then reported as the drive does
  integer last_cell;
  task write_cells(input integer s, input integer start, input integer ncells_rev);
    integer i, b, a;
    begin
      a = start;
      for (i = 0; i < nfb; i = i + 1)
        for (b = 7; b >= 0; b = b - 1) begin
          @(posedge clk); #1 trk_we = 1; trk_side = s; trk_addr = a; trk_wbit = fb[i][b];
          last_cell = a;
          a = (a + 1 == ncells_rev) ? 0 : a + 1;
        end
      @(posedge clk); #1 trk_we = 0;
    end
  endtask
  task raise_arc(input integer s, input integer start, input integer last, input integer whole, input integer ncells_rev);
    begin
      @(posedge clk); #1 arc_done = 1; arc_side = s; arc_start = start; arc_end = last;
      arc_whole = whole; trk_cells = ncells_rev;
      @(posedge clk); #1 arc_done = 0;
    end
  endtask
  task wait_decoded;
    integer t0;
    begin
      t0 = cyc; repeat (4) @(posedge clk);
      while (hold && cyc - t0 < 2000000) @(posedge clk);
      repeat (4) @(posedge clk);
    end
  endtask
  task wait_valid(input integer c);
    integer t0;
    begin
      t0 = cyc; @(posedge clk);
      while (!(trk_valid && trk_cyl == c) && cyc - t0 < 3000000) @(posedge clk);
    end
  endtask
  // where sector k's data field starts on cylinder c (the encoder's layout:
  // the leftover, then 776 bytes a slot: 48 sync, 11 address field, then
  // the data field's own 6 sync bytes)
  function integer field_cell(input integer c, input integer k);
    field_cell = leftover(c) + slot_of(spt(c), k) * 6208 + (48 + 11) * 8;
  endfunction
  // a new sector content, and what the image should then hold
  task new_content(input integer seed);
    integer i;
    begin for (i = 0; i < 524; i = i + 1) sec[i] = (seed * 29 + i * 7 + (i >> 4)) & 8'hFF; end
  endtask
  task expect_block(input integer n);
    integer i, j;
    begin
      for (i = 0; i < 256; i = i + 1) want[n * 256 + i] = {sec[12 + 2 * i], sec[13 + 2 * i]};
      if (img_tags) for (j = 0; j < 6; j = j + 1) want[blocks * 256 + n * 6 + j] = {sec[2 * j], sec[2 * j + 1]};
    end
  endtask

  integer i, k, n0, c, start, p0;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);
    build_image;
    #1 disk_in = 1; cyl = 0;
    wait_valid(0);
    check(trk_valid && trk_cyl == 0, "(cylinder 0 built)", trk_cyl, 0);

    $display("---- 1. a whole revolution over the encoder's own track");
    ncm = 0; nwr = 0;
    raise_arc(0, 0, 1234, 1, 74558);
    wait_decoded;
    check(ncm == 12, "all 12 sectors of side 0 committed, once each", ncm, 12);
    k = 0; for (i = 0; i < ncm && i < 64; i = i + 1) if (cmb[i] > 11) k = k + 1;
    check(k == 0, "each to a block of cylinder 0 side 0 (0-11)", k, 0);
    compare_image;
    check(diffs == 0, "the image unchanged: the decoder wrote back what the encoder laid out", diffs, 0);
    check(nwr == 12 * 262, "262 words a sector (256 data, 6 tags)", nwr, 12 * 262);

    $display("---- 2. a sector written as the ROM writes it");
    new_content(1);
    nfb = 0; put_data_field(5, 0);
    start = field_cell(0, 5);
    write_cells(0, start, 74558);
    ncm = 0;
    raise_arc(0, start, last_cell, 0, 74558);
    wait_decoded;
    check(ncm == 1 && cmb[0] == 5, "sector 5 committed, to block 5", cmb[0], 5);
    expect_block(5);
    compare_image;
    check(diffs == 0, "its data and tags in the image, nothing else changed", diffs, 0);
    // side 1, sector 3 of cylinder 0: block 12 + 3
    new_content(2);
    nfb = 0; put_data_field(3, 0);
    start = field_cell(0, 3);
    write_cells(1, start, 74558);
    ncm = 0;
    raise_arc(1, start, last_cell, 0, 74558);
    wait_decoded;
    check(ncm == 1 && cmb[0] == 15, "side 1 sector 3: block 15", cmb[0], 15);
    expect_block(15);
    compare_image;
    check(diffs == 0, "its data and tags in the image, nothing else changed", diffs, 0);

    $display("---- 3. a bad checksum");
    new_content(3);
    nfb = 0; put_data_field(7, 1);
    start = field_cell(0, 7);
    write_cells(0, start, 74558);
    ncm = 0; n0 = ddbg[15:8];
    raise_arc(0, start, last_cell, 0, 74558);
    wait_decoded;
    check(ncm == 0, "not committed", ncm, 0);
    check(ddbg[15:8] == n0 + 1, "counted refused", ddbg[15:8] - n0, 1);
    compare_image;
    check(diffs == 0, "the image unchanged", diffs, 0);

    $display("---- 4. a field cut by the arc's end");
    new_content(4);
    nfb = 0; put_data_field(9, 0);
    start = field_cell(0, 9);
    write_cells(0, start, 74558);
    ncm = 0;
    raise_arc(0, start, last_cell - 100, 0, 74558);     // the gate rose 100 cells early
    wait_decoded;
    check(ncm == 0, "not committed", ncm, 0);
    compare_image;
    check(diffs == 0, "the image unchanged", diffs, 0);

    $display("---- 5. a sector past the zone's count");
    #1 cyl = 70; wait_valid(70);                       // zone 4: 8 sectors
    new_content(5);
    nfb = 0; put_data_field(9, 0);
    start = field_cell(70, 3);                          // anywhere: the field names sector 9
    write_cells(0, start, 49790);
    ncm = 0; n0 = ddbg[15:8];
    raise_arc(0, start, last_cell, 0, 49790);
    wait_decoded;
    check(ncm == 0 && ddbg[15:8] == n0 + 1, "sector 9 in zone 4 (8 sectors): refused", ncm, 0);
    compare_image;
    check(diffs == 0, "the image unchanged", diffs, 0);
    // a good one there: cylinder 70 side 0 sector 6
    new_content(6);
    nfb = 0; put_data_field(6, 0);
    start = field_cell(70, 6);
    write_cells(0, start, 49790);
    ncm = 0;
    raise_arc(0, start, last_cell, 0, 49790);
    wait_decoded;
    check(ncm == 1 && cmb[0] == blk_of(70, 0, 6, 1), "cylinder 70 sector 6: its block", cmb[0], blk_of(70, 0, 6, 1));
    expect_block(blk_of(70, 0, 6, 1));
    compare_image;
    check(diffs == 0, "in the image, nothing else changed", diffs, 0);

    $display("---- 8. read-only and loading");
    new_content(8);
    nfb = 0; put_data_field(2, 0);
    start = field_cell(70, 2);
    write_cells(0, start, 49790);
    #1 write_ok = 0; ncm = 0;
    raise_arc(0, start, last_cell, 0, 49790);
    wait_decoded;
    check(ncm == 0, "read-only: nothing committed", ncm, 0);
    #1 write_ok = 1; loading = 1;
    raise_arc(0, start, last_cell, 0, 49790);
    wait_decoded;
    check(ncm == 0, "loading: nothing committed", ncm, 0);
    #1 loading = 0;
    compare_image;
    check(diffs == 0, "the image unchanged", diffs, 0);

    $display("---- 9. back-pressure, and hold");
    #1 cm_ready = 0; ncm = 0;
    raise_arc(0, start, last_cell, 0, 49790);
    repeat (100000) @(posedge clk);
    check(ncm == 0 && hold, "a commit waits while cm_ready is low, holding the encoder", ncm, 0);
    #1 cyl = 71;                                        // a seek: the encoder must wait
    repeat (5000) @(posedge clk);
    check(enc_idle && trk_valid && trk_cyl == 70, "no rebuild started while the decoder holds (the encoder idle, cylinder 70 kept)", enc_idle, 1);
    #1 cm_ready = 1;
    wait_decoded;
    check(ncm == 1 && cmb[0] == blk_of(70, 0, 2, 1), "released: committed", cmb[0], blk_of(70, 0, 2, 1));
    expect_block(blk_of(70, 0, 2, 1));
    wait_valid(71);
    check(trk_valid && trk_cyl == 71, "and then the rebuild", trk_cyl, 71);
    compare_image;
    check(diffs == 0, "the image as expected", diffs, 0);

    $display("---- 7. a format: a one-sided format of cylinder 1 of an 800K image");
    #1 cyl = 1; wait_valid(1);
    nfb = 0;
    for (i = 0; i < 200; i = i + 1) put_sync;                    // the 1,200-byte lead-in
    for (i = 0; i < 12; i = i + 1) begin
      for (k = 0; k < 8; k = k + 1) put_sync;                   // 48 sync bytes
      put_addr_field(1, il(12, i), 0, 6'h02);                    // single-sided format byte
      for (k = 0; k < 524; k = k + 1) sec[k] = 8'h00;
      put_data_field(il(12, i), 0);
    end
    start = 30000;
    write_cells(0, start, 74558);
    check(nfb * 8 > 74558, "the format overruns a revolution", nfb * 8, 84096);
    ncm = 0;
    raise_arc(0, start, last_cell, 1, 74558);
    wait_decoded;
    check(ncm == 12, "every sector committed, once", ncm, 12);
    check(ds_eff == 0, "the format byte $02: the layout single-sided at once", ds_eff, 0);
    k = 0; for (i = 0; i < ncm && i < 64; i = i + 1) if (cmb[i] < 12 || cmb[i] > 23) k = k + 1;
    check(k == 0, "to the 400K layout's blocks of cylinder 1 (12-23)", k, 0);
    for (k = 0; k < 524; k = k + 1) sec[k] = 8'h00;
    for (i = 12; i < 24; i = i + 1) expect_block(i);
    compare_image;
    check(diffs == 0, "as zeros, tags too; nothing else changed", diffs, 0);

    $display("---- 6. an image without tags");
    #1 disk_in = 0; repeat (8) @(posedge clk);
    #1 img_tags = 0; build_image;
    #1 disk_in = 1; cyl = 2;
    wait_valid(2);
    check(ds_eff == 1, "(a new disk: the loader's sidedness again)", ds_eff, 1);
    new_content(9);
    nfb = 0; put_data_field(4, 0);
    start = field_cell(2, 4);
    write_cells(1, start, 74558);
    ncm = 0; nwr = 0;
    raise_arc(1, start, last_cell, 0, 74558);
    wait_decoded;
    check(ncm == 1 && cmb[0] == blk_of(2, 1, 4, 1), "committed, to its block", cmb[0], blk_of(2, 1, 4, 1));
    check(nwr == 256, "256 words: data only", nwr, 256);
    expect_block(blk_of(2, 1, 4, 1));
    compare_image;
    check(diffs == 0, "the tag region untouched", diffs, 0);

    $display("---- 10. the disk port's handshake");
    check(torn == 0, "no request torn down before its acknowledge", torn, 0);
    check(moved == 0, "its address and data held", moved, 0);
    check(early == 0, "none raised over a stale acknowledge", early, 0);
    check(wild == 0, "no write outside the image", wild, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the decoder holds to plan 5.15.5", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(32.0 * 60000000); $display("==== FAIL: timeout"); $finish; end

endmodule
