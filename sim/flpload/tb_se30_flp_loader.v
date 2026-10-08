// tb_se30_flp_loader.v - the floppy loader held to SE30_PLAN.md 5.12.5
// (item 5 of 5.12.12; 5.12.9 item 4).
//
// WHAT THIS PROVES
//   rtl/se30_flp_loader.v takes an image from the HPS's block device into
//   SDRAM as the encoder reads it, and says what disk it is:
//
//     1. raw 800K and 400K: every word lands at BASE + k as {byte 2k,
//        byte 2k+1}; the geometry
//     2. DiskCopy 4.2, 800K with tags and 400K without: the 84-byte header
//        never reaches SDRAM, the data follows at BASE, the tags after it;
//        a DC42 whose tag size is not 12 a block is tagless; an odd-sized
//        DC42's last partial block is read
//     3. the three ceilings of MacPlus phase 7: an 800K file carrying a
//        400K volume is single-sided (img_800k still 1, for the tags); a
//        400K file is single-sided whatever its MDB says
//     4. the medium sniff on MacPlus phase 7's eleven images
//     5. MFM (plan 5.13.6): raw 1.44 MB and 720K, DiskCopy 4.2 with
//        format byte 3 and 2: resident, in, img_mfm, img_hd for 1.44 MB
//        only, no tags; not a disk: a 1.44 MB-sized DC42 whose format
//        byte says GCR, a file a block short; a GCR image after an MFM
//        one clears img_mfm and img_hd
//     6. the disk counts as in only when its last word is written; a
//        mount during a load takes the new image (between sectors); a
//        mount over the disk in is held until the eject (item 9);
//        unmount; the drive's eject; readonly latched at the slot's own
//        mount pulse
//     7. the HPS side: each sector transferred once (sd_rd dropped when
//        the transfer is picked up); the disk port: no request torn, none
//        moved, none raised over the last acknowledge
//     9. a mount over the disk the Mac holds (SE30_PLAN.md KNOWN ISSUES
//        14): the Mac's floppy driver lets a disk go only on its own eject
//        or on an access that finds the drive empty, so a new image that
//        appeared at once would be taken for the old volume and written
//        with its catalog and bitmap.  The mount is held: the old disk
//        stays in, write-protected, `loading` up (no commit, no write-back:
//        the slot names the new file now), no sector read and no word
//        written; at the drive's eject the held image loads, read-only as
//        at its own pulse; a second mount replaces the held one; an
//        unmount takes the old disk out and cancels it; the machine's
//        reset loads it (the escape when the Mac cannot eject); a mount
//        into an empty drive loads at once.  `+SWAPONLY` runs this item
//        alone (a minute or two).
//     8. a real image, if present (Daniel's C:\temp\Mac\SE30\Disk605.dsk):
//        resident byte for byte - a smoke test only, nothing fitted to it
//
// THE BENCH
//   clk is clk_sys.  The HPS model polls sd_rd every POLL clocks as Main
//   does through hps_io's command $16, raises sd_ack for the transfer, and
//   delivers 256 words with sd_buff_wr pulses (file byte 0 in the low
//   half, as hps_io's io_din); past the end of the file it serves $EE.
//   The memory answers in 3 to 8 clocks and holds its acknowledge two
//   clocks after the request drops.

`timescale 1ns/1ps

module tb_se30_flp_loader;

  localparam [23:0] BASE = 24'h800000;
  localparam integer POLL = 40;
  localparam integer MAXF = 1474560 + 84 + 512;

  reg clk = 0;
  always #16 clk = ~clk;
  reg reset_n = 0;

  reg         img_mounted = 0, img_readonly = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] sd_lba;
  wire        sd_rd;
  reg         sd_ack = 0;
  reg   [7:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         sd_buff_wr = 0;
  wire        mem_req;
  wire [23:0] mem_addr;
  wire [15:0] mem_wdata;
  reg         mem_ack = 0;
  reg         eject = 0;
  reg         mac_reset_n = 1;                 // the machine's reset (the escape for a held swap)
  wire        disk_in, img_ds, img_800k, img_tags, img_mfm, img_hd, readonly, loading;
  wire [15:0] dbg;

  se30_flp_loader #(.BASE(BASE)) dut (
    .clk(clk), .reset_n(reset_n),
    .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .mem_req(mem_req), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_ack(mem_ack),
    .eject(eject), .mac_reset_n(mac_reset_n),
    .disk_in(disk_in), .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags),
    .img_mfm(img_mfm), .img_hd(img_hd),
    .readonly(readonly), .loading(loading), .dbg(dbg));

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

  // ------------------------------------------------------------ the file
  reg  [7:0] file [0:MAXF - 1];
  integer    fsize;
  // ------------------------------------------------------------ the HPS
  integer xfers = 0, rereads = 0;
  integer last_lba = -1;
  reg     hps_on = 1;
  always begin : hps
    integer w, lba;
    repeat (POLL) @(posedge clk);
    if (hps_on && sd_rd) begin                          // Main's poll ($16) saw the request
      lba = sd_lba;
      if (lba == last_lba) rereads = rereads + 1;
      last_lba = lba;
      repeat (3) @(posedge clk);
      #1 sd_ack = 1;                                     // $17: the transfer begins
      for (w = 0; w < 256; w = w + 1) begin
        @(posedge clk); #1
        sd_buff_addr = w;
        sd_buff_dout = {(lba * 512 + 2 * w + 1 < fsize) ? file[lba * 512 + 2 * w + 1] : 8'hEE,
                        (lba * 512 + 2 * w     < fsize) ? file[lba * 512 + 2 * w]     : 8'hEE};
        sd_buff_wr = 1;
        @(posedge clk); #1 sd_buff_wr = 0;
      end
      repeat (2) @(posedge clk); #1 sd_ack = 0;
      xfers = xfers + 1;
    end
  end

  // ------------------------------------------------------------ the memory
  reg  [15:0] mem [0:MAXF / 2];
  integer lat = 0, torn = 0, moved = 0, early = 0, hold = 0, writes = 0, last_write = 0, oob = 0;
  reg     req_d = 0;
  reg [23:0] addr_d;
  always @(posedge clk) begin
    req_d <= mem_req; addr_d <= mem_addr;
    if (req_d && !mem_req && !mem_ack) torn <= torn + 1;
    if (req_d && mem_req && !mem_ack && mem_addr != addr_d) moved <= moved + 1;
    if (mem_req && !req_d && mem_ack) early <= early + 1;
    if (mem_req && !mem_ack) begin
      if (lat == 0) lat <= 3 + (cyc % 6);
      else if (lat == 1) begin
        mem_ack <= 1; lat <= 0; writes <= writes + 1; last_write <= cyc;
        if (mem_addr >= BASE && mem_addr - BASE <= MAXF / 2) mem[mem_addr - BASE] <= mem_wdata;
        else oob <= oob + 1;
      end else lat <= lat - 1;
    end
    if (mem_ack && !mem_req) begin
      if (hold == 1) begin mem_ack <= 0; hold <= 0; end
      else if (hold == 0) hold <= 2;
      else hold <= hold - 1;
    end
  end

  // disk_in's rise, against the last write
  integer rise_at = 0, early_rise = 0;
  reg     disk_d = 0;
  always @(posedge clk) begin
    disk_d <= disk_in;
    if (disk_in && !disk_d) begin
      rise_at <= cyc;
      if (mem_req || lat != 0) early_rise <= early_rise + 1;     // a word still on its way
    end
  end

  // ------------------------------------------------------------ building files
  task clear_file(input integer n);
    integer i;
    begin fsize = n; for (i = 0; i < n; i = i + 1) file[i] = ((i * 7) ^ (i >> 9)) & 8'hFF; end
  endtask
  // an MDB at payload offset 1024 + off: signature, drNmAlBlks (word 9),
  // drAlBlkSiz (words 10-11), big-endian
  task put_mdb(input integer off, input [15:0] sig, input [15:0] nalbk, input [31:0] absz);
    begin
      file[off + 1024] = sig[15:8];   file[off + 1025] = sig[7:0];
      file[off + 1042] = nalbk[15:8]; file[off + 1043] = nalbk[7:0];
      file[off + 1044] = absz[31:24]; file[off + 1045] = absz[23:16];
      file[off + 1046] = absz[15:8];  file[off + 1047] = absz[7:0];
    end
  endtask
  task put_dc42(input [31:0] dsize, input [31:0] tsize, input [7:0] fmt);
    integer i;
    begin
      for (i = 0; i < 84; i = i + 1) file[i] = 8'h00;
      file[0] = 8'd9;                                      // the name, a Pascal string
      for (i = 1; i < 10; i = i + 1) file[i] = "A" + i;
      {file[64], file[65], file[66], file[67]} = dsize;    // $40 data size
      {file[68], file[69], file[70], file[71]} = tsize;    // $44 tag size
      file[80] = fmt;                                      // $50 disk format
      file[81] = 8'h22;                                    // $51 format byte
      file[82] = 8'h01; file[83] = 8'h00;                  // $52 the magic
    end
  endtask

  // ------------------------------------------------------------ mounting
  task mount(input integer size, input ro);
    begin
      @(posedge clk); #1 img_size = size; img_readonly = ro; img_mounted = 1;
      @(posedge clk); #1 img_mounted = 0; img_readonly = !ro; img_size = 64'hDEAD;   // valid only at the pulse
    end
  endtask
  integer t0, pf = 0;
  task wait_load;                                          // until the loader is idle again
    begin
      t0 = cyc;
      repeat (4) @(posedge clk);
      while ((loading || mem_req) && cyc - t0 < 40000000) @(posedge clk);
      if (loading || mem_req) $display("     (a load still running after 40M clocks: state %0d, lba %0d)", dut.dbg[9:7], sd_lba);
      if (pf == 0) pf = $fopen("prog.txt", "w");
      $fdisplay(pf, "load done at %0d clocks, %0d after the mount; disk_in %0d loading %0d", cyc, cyc - t0, disk_in, loading);
      $fflush(pf);
      repeat (20) @(posedge clk);
    end
  endtask
  // SDRAM against the file: words mismatched over [first byte, last byte)
  // of the file, landing from word `at`
  integer mism;
  task compare(input integer first, input integer last, input integer at);
    integer b;
    begin
      mism = 0;
      for (b = first; b + 1 < last; b = b + 2)
        if (mem[at + (b - first) / 2] !== {file[b], file[b + 1]}) mism = mism + 1;
    end
  endtask
  task clear_mem;
    integer i;
    begin for (i = 0; i <= MAXF / 2; i = i + 1) mem[i] = 16'hXXXX; end
  endtask

  // one load and its verdict, into an empty drive: a disk still in is
  // ejected first, as the Mac's eject would (a mount over it is held)
  task empty_drive;
    begin if (disk_in) begin @(posedge clk); #1 eject = 1; @(posedge clk); #1 eject = 0; repeat (2) @(posedge clk); end end
  endtask
  task load(input integer size, input ro);
    begin
      empty_drive; clear_mem; mount(size, ro); wait_load;
    end
  endtask

  integer x0, fd, r, i, n, sniffs_bad;
  reg [8*96-1:0] what;

  // ---- 9. a mount over the disk the Mac holds (the header's item 9)
  integer x1, w1;
  task new_image(input [7:0] k);                           // the slot's next file: the last one xor k
    begin
      for (i = 0; i < 819200; i = i + 1) file[i] = file[i] ^ k;
      put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    end
  endtask
  task pulse_eject;
    begin @(posedge clk); #1 eject = 1; @(posedge clk); #1 eject = 0; repeat (2) @(posedge clk); end
  endtask
  task swap_tests;
    begin
      $display("---- 9. a mount over the disk the Mac holds (KNOWN ISSUES 14)");
      clear_file(819200); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
      load(819200, 0);
      check(disk_in && !readonly, "(A in, writable)", {disk_in, readonly}, 2'b10);
      new_image(8'hA5);                                    // B on the slot
      x1 = xfers; w1 = writes;
      mount(819200, 1); repeat (2) @(posedge clk);
      check(disk_in, "a mount over the disk in: the old disk stays in", disk_in, 1);
      check(readonly, "  write-protected at once (the slot names the new file)", readonly, 1);
      check(loading, "  loading up: no commit, no write-back", loading, 1);
      repeat (200000) @(posedge clk);
      check(xfers == x1 && writes == w1 && disk_in, "  held: no sector read, no word written, still in",
            (xfers - x1) + (writes - w1), 0);
      new_image(8'h3C);                                    // C replaces B, writable
      mount(819200, 0); repeat (2000) @(posedge clk);
      check(xfers == x1 && disk_in && readonly, "a second mount while held: still held, still protected",
            {xfers == x1, disk_in, readonly}, 3'b111);
      pulse_eject;
      check(!disk_in, "the drive's eject: the old disk out", disk_in, 0);
      wait_load;
      compare(0, 819200, 0);
      check(mism == 0, "  and the held image (the second) loads, resident", mism, 0);
      check(disk_in && !readonly && !loading, "  and comes in, writable as at its own pulse", {disk_in, readonly, loading}, 3'b100);
      x1 = xfers;
      @(posedge clk); #1 mac_reset_n = 0; repeat (8) @(posedge clk); #1 mac_reset_n = 1;
      repeat (2000) @(posedge clk);
      check(disk_in && xfers == x1, "the machine's reset with nothing held: the disk stays, no reload",
            {disk_in, xfers == x1}, 2'b11);

      new_image(8'h11); mount(819200, 1); repeat (2) @(posedge clk);
      check(disk_in && readonly, "(held again)", {disk_in, readonly}, 2'b11);
      x1 = xfers;
      mount(0, 0); repeat (4) @(posedge clk);
      check(!disk_in, "an unmount while held: out at once", disk_in, 0);
      repeat (200000) @(posedge clk);
      check(!disk_in && !loading && xfers == x1, "  and the held image never loads", {disk_in, loading, xfers == x1}, 3'b001);

      load(819200, 0);
      new_image(8'h77); mount(819200, 1); repeat (2) @(posedge clk);
      check(disk_in && readonly, "(held once more)", {disk_in, readonly}, 2'b11);
      @(posedge clk); #1 mac_reset_n = 0; repeat (8) @(posedge clk); #1 mac_reset_n = 1;
      repeat (2) @(posedge clk);
      check(!disk_in, "the machine's reset while held: the old disk out", disk_in, 0);
      wait_load;
      compare(0, 819200, 0);
      check(mism == 0, "  and the held image loads, resident", mism, 0);
      check(disk_in && readonly, "  and comes in, read-only as at its own pulse", {disk_in, readonly}, 2'b11);

      pulse_eject;
      check(!disk_in, "(ejected: the drive empty)", disk_in, 0);
      new_image(8'h5A); x1 = xfers;
      mount(819200, 0); repeat (200000) @(posedge clk);
      check(xfers > x1, "a mount into the empty drive loads at once", xfers - x1, 1);
      wait_load;
      check(disk_in && !readonly, "  and comes in", {disk_in, readonly}, 2'b10);
    end
  endtask

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (5) @(posedge clk);
    if ($test$plusargs("SWAPONLY")) begin
      swap_tests;
      if (fails == 0) $display("==== PASS: %0d checks, item 9 alone", checks);
      else            $display("==== FAIL: %0d of %0d checks (item 9 alone)", fails, checks);
      $finish;
    end

    // ---- 1. raw images
    $display("---- 1. raw 800K and 400K");
    clear_file(819200); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    x0 = xfers; load(819200, 0);
    compare(0, 819200, 0);
    check(mism == 0, "raw 800K: every word at BASE + k as {byte 2k, 2k+1}", mism, 0);
    check(disk_in && img_ds && img_800k && !img_tags, "  in, double-sided, 800K, no tags", {disk_in, img_ds, img_800k, img_tags}, 4'b1110);
    check(!img_mfm && !img_hd, "  GCR: not MFM, not high density", {img_mfm, img_hd}, 0);
    check(xfers - x0 == 1600, "  1600 sectors transferred", xfers - x0, 1600);
    check(rise_at > last_write, "  the disk in only after its last word", rise_at - last_write, 1);
    clear_file(409600); put_mdb(0, 16'hD2D7, 16'd391, 32'd1024);
    load(409600, 0);
    compare(0, 409600, 0);
    check(mism == 0, "raw 400K: resident", mism, 0);
    check(disk_in && !img_ds && !img_800k && !img_tags, "  in, single-sided, 400K", {disk_in, img_ds, img_800k, img_tags}, 4'b1000);

    // ---- 2. DiskCopy 4.2
    $display("---- 2. DiskCopy 4.2");
    clear_file(84 + 819200 + 19200); put_dc42(819200, 19200, 8'd1); put_mdb(84, 16'h4244, 16'd797, 32'd1024);
    load(84 + 819200 + 19200, 0);
    compare(84, 84 + 819200 + 19200, 0);
    check(mism == 0, "DC42 800K with tags: the header stripped, data then tags from BASE", mism, 0);
    check(disk_in && img_ds && img_800k && img_tags, "  in, double-sided, 800K, tags", {disk_in, img_ds, img_800k, img_tags}, 4'b1111);
    check(mem[0] !== 16'h0941, "  (the header's first word is nowhere at BASE)", mem[0], 0);
    clear_file(84 + 409600); put_dc42(409600, 0, 8'd0); put_mdb(84, 16'hD2D7, 16'd391, 32'd1024);
    load(84 + 409600, 0);
    compare(84, 84 + 409600, 0);
    check(mism == 0, "DC42 400K without tags: resident, an odd-sized file's last block read", mism, 0);
    check(disk_in && !img_ds && !img_800k && !img_tags, "  in, single-sided, no tags", {disk_in, img_ds, img_800k, img_tags}, 4'b1000);
    clear_file(84 + 819200 + 100); put_dc42(819200, 100, 8'd1); put_mdb(84, 16'h4244, 16'd1594, 32'd512);
    load(84 + 819200 + 100, 0);
    check(disk_in && img_ds && !img_tags, "a DC42 whose tag size is not 12 a block: tagless", {disk_in, img_ds, img_tags}, 3'b110);

    // ---- 3. the ceilings
    $display("---- 3. the ceilings (MacPlus phase 7)");
    clear_file(819200); put_mdb(0, 16'hD2D7, 16'd391, 32'd1024);
    load(819200, 0);
    check(disk_in && !img_ds && img_800k, "an 800K file carrying a 400K volume: single-sided, img_800k", {disk_in, img_ds, img_800k}, 3'b101);
    clear_file(409600); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    load(409600, 0);
    check(disk_in && !img_ds, "a 400K file is single-sided whatever its MDB says", {disk_in, img_ds}, 2'b10);
    clear_file(84 + 819200 + 19200); put_dc42(819200, 19200, 8'd1); put_mdb(84, 16'hD2D7, 16'd391, 32'd1024);
    load(84 + 819200 + 19200, 0);
    check(disk_in && !img_ds && img_800k && img_tags, "an 800K DC42 with a 400K volume: single-sided, its tags after 800K", {disk_in, img_ds, img_800k, img_tags}, 4'b1011);

    // ---- 4. the sniff, MacPlus phase 7's eleven
    $display("---- 4. the medium sniff's eleven images");
    sniffs_bad = 0;
    for (n = 0; n < 10; n = n + 1) begin
      clear_file(819200);
      case (n)
        0: begin put_mdb(0, 16'hD2D7, 16'd391,  32'd1024);  what = "MFS 391 x 1024: single"; end
        1: begin put_mdb(0, 16'h4244, 16'd395,  32'd1024);  what = "HFS 395 x 1024: single"; end
        2: begin put_mdb(0, 16'h4244, 16'd1594, 32'd512);   what = "HFS 1594 x 512: double"; end
        3: begin put_mdb(0, 16'h4244, 16'd797,  32'd1024);  what = "HFS 797 x 1024: double"; end
        4: begin for (i = 0; i < 819200; i = i + 1) file[i] = 0; what = "zero-filled: says nothing, double"; end
        5: begin put_mdb(0, 16'h1234, 16'd391,  32'd1024);  what = "unrecognised signature: double"; end
        6: begin put_mdb(0, 16'h4244, 16'd391,  32'd1000);  what = "drAlBlkSiz not a multiple of 512: double"; end
        7: begin put_mdb(0, 16'h4244, 16'd3,    32'h10000); what = "drAlBlkSiz above 64K: double"; end
        8: begin put_mdb(0, 16'h4244, 16'd25,   32'd32768); what = "32768 (the multiplier's top bit), 25 blocks = 1600: double"; end
        9: begin put_mdb(0, 16'h4244, 16'd12,   32'd32768); what = "32768 x 12 = 768 blocks: single"; end
      endcase
      load(819200, 0);
      r = (n == 0 || n == 1 || n == 9) ? 0 : 1;
      check(disk_in && img_ds == r, what, img_ds, r);
    end
    // the eleventh: a file with no sector 2 (and so no disk)
    clear_file(1024);
    load(1024, 0);
    check(!disk_in, "a file too short to have a sector 2: no disk", disk_in, 0);

    // ---- 5. MFM
    $display("---- 5. MFM: 1.44 MB and 720K, raw and DiskCopy 4.2");
    clear_file(1474560); x0 = xfers;
    load(1474560, 0); compare(0, 1474560, 0);
    check(mism == 0, "raw 1.44 MB: every word at BASE + k", mism, 0);
    check(disk_in && img_mfm && img_hd && !img_800k && !img_tags, "  in, MFM, high density, no tags", {disk_in, img_mfm, img_hd, img_800k, img_tags}, 5'b11100);
    check(xfers - x0 == 2880, "  2880 sectors transferred", xfers - x0, 2880);
    clear_file(737280);
    load(737280, 0); compare(0, 737280, 0);
    check(mism == 0 && disk_in && img_mfm && !img_hd, "raw 720K: resident, in, MFM, double density", {mism == 0, disk_in, img_mfm, img_hd}, 4'b1110);
    clear_file(84 + 1474560); put_dc42(1474560, 0, 8'd3);
    load(84 + 1474560, 0); compare(84, 84 + 1474560, 0);
    check(mism == 0 && disk_in && img_mfm && img_hd && !img_tags, "DC42 1440K (format 3): the header stripped, in, MFM, HD", {mism == 0, disk_in, img_mfm, img_hd, img_tags}, 5'b11110);
    clear_file(84 + 737280); put_dc42(737280, 0, 8'd2);
    load(84 + 737280, 0); compare(84, 84 + 737280, 0);
    check(mism == 0 && disk_in && img_mfm && !img_hd, "DC42 720K (format 2): in, MFM, double density", {mism == 0, disk_in, img_mfm, img_hd}, 4'b1110);
    clear_file(84 + 1474560); put_dc42(1474560, 0, 8'd1);
    load(84 + 1474560, 0);
    check(!disk_in, "a 1.44 MB-sized DC42 whose format byte says 800K: not a disk", disk_in, 0);
    clear_file(1474560 - 512);
    load(1474560 - 512, 0);
    check(!disk_in && !img_mfm, "a raw file a block short of 1.44 MB: not a disk", {disk_in, img_mfm}, 0);
    clear_file(1474560); load(1474560, 0);
    clear_file(819200); load(819200, 0);
    check(disk_in && img_800k && !img_mfm && !img_hd, "800K after 1.44 MB: GCR again, img_mfm and img_hd clear", {disk_in, img_800k, img_mfm, img_hd}, 4'b1100);

    // ---- 6. mounts, unmount, eject, readonly
    $display("---- 6. a mount during a load, unmount, eject, readonly");
    clear_file(819200); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    empty_drive; clear_mem; mount(819200, 0);
    repeat (400000) @(posedge clk);                            // well into the load
    check(loading && !disk_in, "(mid-load: loading, not in)", {loading, disk_in}, 2'b10);
    clear_file(409600); put_mdb(0, 16'hD2D7, 16'd391, 32'd1024);   // the second image
    for (i = 0; i < 409600; i = i + 1) file[i] = file[i] ^ 8'h5A;
    put_mdb(0, 16'hD2D7, 16'd391, 32'd1024);
    mount(409600, 1);
    wait_load;
    compare(0, 409600, 0);
    check(mism == 0, "a mount during a load: the new image resident", mism, 0);
    check(disk_in && !img_ds && readonly, "  and it is the disk in, read-only", {disk_in, img_ds, readonly}, 3'b101);
    check(rise_at > last_write, "  in only after its last word", rise_at - last_write, 1);
    mount(0, 0); repeat (4) @(posedge clk);
    check(!disk_in, "unmount: out", disk_in, 0);
    clear_file(819200); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    load(819200, 1);
    check(disk_in && readonly, "(in again, read-only as at its own pulse)", {disk_in, readonly}, 2'b11);
    mount(409600, 0); repeat (2) @(posedge clk);
    check(disk_in && readonly && loading, "a new mount over the disk in is held (item 9)", {disk_in, readonly, loading}, 3'b111);
    @(posedge clk); #1 eject = 1; @(posedge clk); #1 eject = 0;
    wait_load;
    check(disk_in && !readonly, "  and after the eject the new one comes in, writable as at its pulse", {disk_in, readonly}, 2'b10);
    @(posedge clk); #1 eject = 1; @(posedge clk); #1 eject = 0;
    repeat (2) @(posedge clk);
    check(!disk_in, "the drive's eject: out", disk_in, 0);
    repeat (1000) @(posedge clk);
    check(!disk_in && !loading, "  and it stays out, no reload", {disk_in, loading}, 2'b00);

    // a mount pulse on the very clock a load completes supersedes it
    clear_file(819200); put_mdb(0, 16'h4244, 16'd1594, 32'd512);
    empty_drive; clear_mem; mount(819200, 0);
    @(posedge clk); #1;
    while (!(dut.state == 3'd5 && !dut.mul_busy && !mem_req && !mem_ack)) begin @(posedge clk); #1; end
    img_size = 409600; img_readonly = 0; img_mounted = 1;           // sampled on the completing edge
    @(posedge clk); #1 img_mounted = 0;
    check(!disk_in && loading, "a mount on the clock a load completes: that image never counts as in", {disk_in, loading}, 2'b01);
    clear_file(409600); put_mdb(0, 16'hD2D7, 16'd391, 32'd1024);
    wait_load;
    check(disk_in && !img_ds, "  and the new one loads and comes in", {disk_in, img_ds}, 2'b10);

    swap_tests;

    // ---- 7. the HPS side and the port
    $display("---- 7. the HPS side and the disk port");
    check(rereads == 0, "no sector transferred twice (sd_rd dropped at the pickup)", rereads, 0);
    check(torn == 0 && moved == 0 && early == 0, "no request torn, moved or raised over the last acknowledge", torn + moved + early, 0);
    check(oob == 0, "no write outside the image's region", oob, 0);
    check(early_rise == 0, "disk_in never rose with a word on its way", early_rise, 0);

    // ---- 8. a real image
    fd = $fopen("C:/temp/Mac/SE30/Disk605.dsk", "rb");
    if (fd != 0) begin
      $display("---- 8. a real image: Disk605.dsk");
      fsize = $fread(file, fd, 0, MAXF);
      $fclose(fd);
      load(fsize, 0);
      compare(0, fsize, 0);
      check(mism == 0, "Disk605.dsk resident byte for byte", mism, 0);
      $display("     %0d bytes; in %0d, double-sided %0d, 800K %0d, tags %0d", fsize, disk_in, img_ds, img_800k, img_tags);
    end else $display("---- 8. (Disk605.dsk not present: skipped)");

    if (fails == 0) $display("==== PASS: %0d checks, the loader holds to plan 5.12.5", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(32.0 * 600000000); $display("==== FAIL: timeout"); $finish; end

endmodule
