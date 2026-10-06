// tb_se30_flp_sdwriter.v - the SD writer (and the loader's header store)
// held to SE30_PLAN.md 5.15.5 items 6 and 8, item 4 of 5.15.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_flp_sdwriter.v puts every block a commit touched back on the
//   card, byte for byte, and nothing else:
//
//     1. a DiskCopy 4.2 800K image with tags, loaded by the real loader:
//        a sector committed in the middle of the disk reaches the card -
//        its data across the two file blocks the 84-byte header spreads it
//        over, its 12 tags in the tag region's block - and the rest of the
//        file is untouched
//     2. the eject flush: the header's data checksum (bytes 72-75) and
//        tag checksum (76-79, the tags past the first 12) recomputed from
//        the image, block 0 rewritten from the loader's header store, the
//        rest of block 0 intact; a second eject with nothing written
//        writes nothing
//     3. the last sector of the disk: its tags in the file's partial last
//        block, written whole and clipped at the file's end as Main does
//        (the file does not grow)
//     4. a raw 800K image: one block a sector, at its own place; no flush
//     5. a block whose sd_ack comes after the writer's timeout: presented
//        again, written once, nothing lost (MacPlus defect 2)
//     6. back-pressure: with the card stalled, cm_ready falls before the
//        queue can overflow; every commit made while waiting for it lands
//     7. read-only: a commit is ignored
//     8. a mount empties the queue: blocks queued for the old file are
//        never written into the new one; a block being presented is
//        withdrawn and no disk-port request is left up (found by this
//        bench: a mount on the clock a request rose left it up, and the
//        next block's first word took the stale acknowledge's data)
//     9. the disk port's handshake: no request torn down before its
//        acknowledge, its address held, none raised over a stale one
//    10. 1.44 MB (plan 5.16.5 item 6): image blocks 2,879 and 2,048 of a
//        DiskCopy image (format 3, no tags) - the 12-bit block - and the
//        partial last file block; the eject's data sum over 1,474,560
//        bytes and a tag sum of 0; block 2,879 of a raw image
//
// THE BENCH
//   clk is clk_sys.  The HPS model serves the slot as Main does: it polls
//   every POLL clocks, picks a read (sd_rd) or a write (sd_wr) up with
//   sd_ack, moves 256 words - a read delivering them with sd_buff_wr, a
//   write reading sd_buff_din at each address after it has settled - and
//   drops sd_ack.  A write is clipped to the file's size (Main's
//   user_io.cpp: a partial last block is written short, the file never
//   grows).  The memory answers after 1 to 4 clocks (short, to keep the
//   loads and the flush scans quick; the handshake rules are checked all
//   the same).  The bench commits as the decoder does: it changes the image
//   in SDRAM, then offers cm_done when cm_ready is high.

`timescale 1ns/1ps

module tb_se30_flp_sdwriter;

  localparam [23:0] BASE = 24'h800000;
  localparam integer MAXF = 1474644 + 1024;      // a 1.44 MB DiskCopy image, the largest
  localparam integer POLL = 40;

  reg clk = 0;
  always #16 clk = ~clk;
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

  // ------------------------------------------------------------ the DUTs
  reg         img_mounted = 0, img_readonly = 0;
  reg  [63:0] img_size = 0;
  wire [31:0] ld_lba, wr_lba;
  wire        sd_rd, sd_wr;
  reg         sd_ack = 0;
  reg   [7:0] sd_buff_addr = 0;
  reg  [15:0] sd_buff_dout = 0;
  reg         sd_buff_wr = 0;
  wire [15:0] sd_buff_din;
  wire        ld_req, wr_req;
  wire [23:0] ld_addr, wr_addr;
  wire [15:0] ld_wdata;
  reg  [15:0] wr_rdata = 0;
  reg         ld_ack = 0, wr_ack = 0;
  wire        disk_in, img_ds, img_800k, img_tags, readonly, loading, is_dc42;
  wire  [5:0] hdr_addr;
  wire [15:0] hdr_data;
  wire [12:0] file_blks;
  reg         cm_done = 0, flush_req = 0;
  reg  [11:0] cm_blk = 0;
  wire        cm_ready, wbusy;
  wire [31:0] wdbg;

  se30_flp_loader #(.BASE(BASE)) loader (
    .clk(clk), .reset_n(reset_n),
    .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly),
    .sd_lba(ld_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
    .eject(1'b0),
    .disk_in(disk_in), .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags),
    .readonly(readonly), .loading(loading),
    .hdr_addr(hdr_addr), .hdr_data(hdr_data), .is_dc42(is_dc42), .file_blks(file_blks),
    .dbg());

  se30_flp_sdwriter #(.BASE(BASE), .ACK_TIMEOUT_BITS(11), .QDEPTH_BITS(4)) dut (
    .clk(clk), .reset_n(reset_n),
    .img_mounted(img_mounted), .loading(loading), .write_ok(!readonly),
    .dc42(is_dc42), .img_tags(img_tags), .img_800k(img_800k), .file_blks(file_blks),
    .cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(cm_ready),
    .flush_req(flush_req),
    .hdr_addr(hdr_addr), .hdr_data(hdr_data),
    .mem_req(wr_req), .mem_addr(wr_addr), .mem_rdata(wr_rdata), .mem_ack(wr_ack),
    .sd_lba(wr_lba), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din),
    .busy(wbusy), .dbg(wdbg));

  // ------------------------------------------------------------ the card
  reg  [7:0] file [0:MAXF - 1];
  reg  [7:0] expf [0:MAXF - 1];                  // what the card should hold
  integer    fsize;
  integer    rd_xfers = 0, wr_xfers = 0, ignore_wr = 0;
  reg        hps_on = 1;
  integer    wr_blk [0:255];
  always begin : hps
    integer w, lba, k;
    repeat (POLL) @(posedge clk);
    if (hps_on && sd_rd) begin
      lba = ld_lba;
      repeat (3) @(posedge clk);
      #1 sd_ack = 1;
      for (w = 0; w < 256; w = w + 1) begin
        @(posedge clk); #1
        sd_buff_addr = w;
        sd_buff_dout = {(lba * 512 + 2 * w + 1 < fsize) ? file[lba * 512 + 2 * w + 1] : 8'hEE,
                        (lba * 512 + 2 * w     < fsize) ? file[lba * 512 + 2 * w]     : 8'hEE};
        sd_buff_wr = 1;
        @(posedge clk); #1 sd_buff_wr = 0;
      end
      repeat (2) @(posedge clk); #1 sd_ack = 0;
      rd_xfers = rd_xfers + 1;
    end else if (hps_on && sd_wr) begin
      if (ignore_wr > 0) begin                         // Main slow to pick this one up
        ignore_wr = ignore_wr - 1;
        repeat (3000) @(posedge clk);
      end else begin
        lba = wr_lba;
        repeat (3) @(posedge clk);
        #1 sd_ack = 1; sd_buff_addr = 0;
        for (w = 0; w < 256; w = w + 1) begin
          #1 sd_buff_addr = w;
          repeat (6) @(posedge clk); #1;                 // the HPS's word spacing
          if (lba * 512 + 2 * w     < fsize) file[lba * 512 + 2 * w]     = sd_buff_din[7:0];
          if (lba * 512 + 2 * w + 1 < fsize) file[lba * 512 + 2 * w + 1] = sd_buff_din[15:8];
        end
        repeat (2) @(posedge clk); #1 sd_ack = 0;
        if (wr_xfers < 256) wr_blk[wr_xfers] = lba;
        wr_xfers = wr_xfers + 1;
      end
    end
  end

  // ------------------------------------------------------------ the memory
  reg  [15:0] mem [0:MAXF / 2];
  integer llat = 0, lhold = 0, wlat = 0, whold = 0, torn = 0, moved = 0, early = 0;
  reg     wreq_d = 0;
  reg [23:0] waddr_d;
  always @(posedge clk) begin
    // the loader's writes
    if (ld_req && !ld_ack) begin
      if (llat == 0) llat <= 1 + (cyc % 3);
      else if (llat == 1) begin
        ld_ack <= 1; llat <= 0;
        if (ld_addr >= BASE && ld_addr - BASE <= MAXF / 2) mem[ld_addr - BASE] <= ld_wdata;
      end else llat <= llat - 1;
    end
    if (ld_ack && !ld_req) begin
      if (lhold == 1) begin ld_ack <= 0; lhold <= 0; end
      else if (lhold == 0) lhold <= 2;
      else lhold <= lhold - 1;
    end
    // the writer's reads, and the handshake's rules
    wreq_d <= wr_req; waddr_d <= wr_addr;
    if (wreq_d && !wr_req && !wr_ack) torn <= torn + 1;
    if (wreq_d && wr_req && !wr_ack && wr_addr != waddr_d) moved <= moved + 1;
    if (wr_req && !wreq_d && wr_ack) early <= early + 1;
    if (wr_req && !wr_ack) begin
      if (wlat == 0) wlat <= 1 + (cyc % 4);
      else if (wlat == 1) begin
        wr_ack <= 1; wlat <= 0;
        wr_rdata <= (wr_addr >= BASE && wr_addr - BASE <= MAXF / 2) ? mem[wr_addr - BASE] : 16'hBAD0;
      end else wlat <= wlat - 1;
    end
    if (wr_ack && !wr_req) begin
      if (whold == 1) begin wr_ack <= 0; whold <= 0; end
      else if (whold == 0) whold <= 2;
      else whold <= whold - 1;
    end
  end

  // ------------------------------------------------------------ the files
  integer i, j, n, k, t0, diffs, nb0;
  task make_dc42;                                  // an 800K DiskCopy image with tags
    begin
      fsize = 838484;
      for (i = 0; i < fsize; i = i + 1) file[i] = ((i * 7) ^ (i >> 9) ^ (i >> 17)) & 8'hFF;
      for (i = 0; i < 84; i = i + 1) file[i] = 8'h00;
      file[0] = 8'd9;
      for (i = 1; i < 10; i = i + 1) file[i] = "A" + i;
      {file[64], file[65], file[66], file[67]} = 32'd819200;
      {file[68], file[69], file[70], file[71]} = 32'd19200;
      {file[72], file[73], file[74], file[75]} = 32'h12345678;   // stale sums: the flush must replace them
      {file[76], file[77], file[78], file[79]} = 32'h9ABCDEF0;
      file[80] = 8'h01; file[81] = 8'h22; file[82] = 8'h01; file[83] = 8'h00;
      for (i = 0; i < fsize; i = i + 1) expf[i] = file[i];
    end
  endtask
  task make_dc42_1440;                             // a 1.44 MB DiskCopy image (format 3, no tags)
    begin
      fsize = 1474644;
      for (i = 0; i < fsize; i = i + 1) file[i] = ((i * 3) ^ (i >> 9) ^ (i >> 15)) & 8'hFF;
      for (i = 0; i < 84; i = i + 1) file[i] = 8'h00;
      file[0] = 8'd9;
      for (i = 1; i < 10; i = i + 1) file[i] = "a" + i;
      {file[64], file[65], file[66], file[67]} = 32'd1474560;
      {file[68], file[69], file[70], file[71]} = 32'd0;
      {file[72], file[73], file[74], file[75]} = 32'h12345678;   // stale sums: the flush must replace them
      {file[76], file[77], file[78], file[79]} = 32'h9ABCDEF0;
      file[80] = 8'h03; file[81] = 8'h22; file[82] = 8'h01; file[83] = 8'h00;
      for (i = 0; i < fsize; i = i + 1) expf[i] = file[i];
    end
  endtask
  task make_raw_1440;
    begin
      fsize = 1474560;
      for (i = 0; i < fsize; i = i + 1) begin file[i] = ((i * 9) ^ (i >> 7)) & 8'hFF; expf[i] = file[i]; end
    end
  endtask
  task make_raw;
    begin
      fsize = 819200;
      for (i = 0; i < fsize; i = i + 1) begin file[i] = ((i * 5) ^ (i >> 8)) & 8'hFF; expf[i] = file[i]; end
    end
  endtask
  task mount(input integer size, input ro);
    begin
      @(posedge clk); #1 img_size = size; img_readonly = ro; img_mounted = 1;
      @(posedge clk); #1 img_mounted = 0; img_size = 64'hDEAD;
      t0 = cyc;
      repeat (8) @(posedge clk);
      while (loading && cyc - t0 < 20000000) @(posedge clk);
      repeat (20) @(posedge clk);
    end
  endtask
  // a commit as the decoder makes one: image block n's data (and its tags)
  // changed in SDRAM and in the expected file, then cm_done when ready
  integer hdr;
  task commit(input integer nb, input integer seed);
    reg [7:0] b0, b1;
    begin
      hdr = is_dc42 ? 84 : 0;
      for (j = 0; j < 256; j = j + 1) begin
        b0 = (seed * 31 + j * 3) & 8'hFF; b1 = (seed * 17 + j * 5 + 1) & 8'hFF;
        mem[nb * 256 + j] = {b0, b1};
        expf[hdr + nb * 512 + 2 * j] = b0; expf[hdr + nb * 512 + 2 * j + 1] = b1;
      end
      if (img_tags) for (j = 0; j < 6; j = j + 1) begin
        b0 = (seed * 13 + j) & 8'hFF; b1 = (seed * 11 + j + 7) & 8'hFF;
        mem[409600 + nb * 6 + j] = {b0, b1};
        expf[84 + 819200 + nb * 12 + 2 * j] = b0; expf[84 + 819200 + nb * 12 + 2 * j + 1] = b1;
      end
      t0 = cyc; @(posedge clk);
      while (!cm_ready && cyc - t0 < 5000000) @(posedge clk);
      if (!cm_ready) begin fails = fails + 1; $display("FAIL commit %0d: cm_ready never came", nb); end
      #1 cm_done = 1; cm_blk = nb;
      @(posedge clk); #1 cm_done = 0;
    end
  endtask
  reg rdy_fell = 0;
  always @(posedge clk) if (!hps_on && dut.count != 0 && !cm_ready && dut.ps == 0) rdy_fell <= 1;
  task drain;
    begin
      t0 = cyc; repeat (8) @(posedge clk);
      while (wbusy && cyc - t0 < 40000000) @(posedge clk);
      repeat (100) @(posedge clk);
    end
  endtask
  task compare_file;
    begin
      diffs = 0;
      for (i = 0; i < fsize; i = i + 1) if (file[i] !== expf[i]) begin
        if (diffs < 4) $display("     differs at byte %0d (block %0d, +%0d): card %h, expected %h", i, i / 512, i % 512, file[i], expf[i]);
        diffs = diffs + 1;
      end
    end
  endtask
  // DiskCopy's sum over the expected file: data from byte 84, tags from
  // byte 84 + dsize + 12
  reg [31:0] dsum, tsum;
  task dc42_dsum(input integer dsize);              // the data sum alone (an image without tags)
    reg [31:0] s;
    begin
      s = 0;
      for (i = 84; i < 84 + dsize; i = i + 2) begin s = s + {expf[i], expf[i + 1]}; s = {s[0], s[31:1]}; end
      dsum = s;
    end
  endtask
  task dc42_sums;
    reg [31:0] s;
    begin
      s = 0;
      for (i = 84; i < 84 + 819200; i = i + 2) begin s = s + {expf[i], expf[i + 1]}; s = {s[0], s[31:1]}; end
      dsum = s; s = 0;
      for (i = 84 + 819200 + 12; i < 84 + 819200 + 19200; i = i + 2) begin s = s + {expf[i], expf[i + 1]}; s = {s[0], s[31:1]}; end
      tsum = s;
    end
  endtask
  integer pf;
  task prog(input [8*40-1:0] what);
    begin $fdisplay(pf, "%0d %0s: busy %0d pst %0d count %0d wr_xfers %0d loading %0d", cyc, what, wbusy, dut.pst, dut.count, wr_xfers, loading); $fflush(pf); end
  endtask
  task pulse_eject; begin @(posedge clk); #1 flush_req = 1; @(posedge clk); #1 flush_req = 0; end endtask

  initial begin
    pf = $fopen("prog.txt", "w");
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (5) @(posedge clk);

    $display("---- 1. a DiskCopy 800K image with tags: a sector committed");
    prog("1. a DiskCopy 800K image with ");
    make_dc42;
    mount(fsize, 0); prog("mounted");
    check(disk_in && is_dc42 && img_tags && img_800k, "(the image in: DiskCopy, tags, 800K)", {disk_in, is_dc42, img_tags}, 7);
    check(file_blks == 1638, "file_blks: 838,484 bytes are 1,638 blocks, the last partial", file_blks, 1638);
    wr_xfers = 0;
    commit(600, 1); prog("committed");
    drain; prog("drained");
    compare_file;
    check(diffs == 0, "the card holds the new data and tags, nothing else changed", diffs, 0);
    check(wr_xfers == 3, "three blocks: data in 600 and 601 (the header's shift), tags in one", wr_xfers, 3);
    check(wr_blk[0] == 600 && wr_blk[1] == 601 && wr_blk[2] == (84 + 819200 + 600 * 12) / 512,
          "blocks 600, 601 and the tags' block", wr_blk[2], (84 + 819200 + 600 * 12) / 512);

    $display("---- 2. the eject flush");
    prog("2. the eject flush");
    dc42_sums;
    {expf[72], expf[73], expf[74], expf[75]} = dsum;
    {expf[76], expf[77], expf[78], expf[79]} = tsum;
    wr_xfers = 0;
    pulse_eject;
    drain;
    compare_file;
    check(diffs == 0, "the header's data and tag checksums recomputed, the rest of block 0 intact", diffs, 0);
    check(wr_xfers == 1 && wr_blk[0] == 0, "one block written: block 0", wr_blk[0], 0);
    wr_xfers = 0;
    pulse_eject;
    drain;
    check(wr_xfers == 0, "a second eject, nothing written since: nothing written", wr_xfers, 0);

    $display("---- 3. the last sector: tags in the file's partial last block");
    prog("3. the last sector: tags in th");
    wr_xfers = 0;
    commit(1599, 3);
    drain;
    compare_file;
    check(diffs == 0, "written, clipped at the file's end", diffs, 0);
    check(wr_xfers == 3 && wr_blk[2] == 1637, "blocks 1599, 1600 and the partial 1637", wr_blk[2], 1637);
    dc42_sums;
    {expf[72], expf[73], expf[74], expf[75]} = dsum;
    {expf[76], expf[77], expf[78], expf[79]} = tsum;
    pulse_eject; drain; compare_file;
    check(diffs == 0, "and the sums again after the eject", diffs, 0);

    $display("---- 5. an acknowledge after the timeout: presented again");
    prog("5. an acknowledge after the ti");
    wr_xfers = 0; nb0 = wdbg[7:4];
    ignore_wr = 1;
    commit(77, 5);
    drain;
    compare_file;
    check(diffs == 0, "the block written, nothing lost", diffs, 0);
    check(wdbg[7:4] != nb0, "a retry counted", wdbg[7:4] - nb0, 1);

    $display("---- 6. back-pressure");
    prog("6. back-pressure");
    #1 hps_on = 0; wr_xfers = 0; rdy_fell = 0;
    fork
      for (k = 0; k < 12; k = k + 1) commit(900 + 2 * k, 20 + k);  // 36 blocks into a 16-deep queue
      begin repeat (300000) @(posedge clk); #1 hps_on = 1; end     // the card back after a while
    join
    check(rdy_fell, "cm_ready fell while the card was stalled (the queue near full)", rdy_fell, 1);
    drain;
    compare_file;
    check(diffs == 0, "every commit landed", diffs, 0);
    check(wr_xfers == 36, "36 blocks", wr_xfers, 36);

    $display("---- 7. read-only");
    prog("7. read-only");
    make_dc42;
    mount(fsize, 1);
    wr_xfers = 0;
    for (j = 0; j < 256; j = j + 1) mem[300 * 256 + j] = 16'h5A5A;
    @(posedge clk); #1 cm_done = 1; cm_blk = 300; @(posedge clk); #1 cm_done = 0;
    drain;
    check(wr_xfers == 0, "a commit to a read-only image: nothing written", wr_xfers, 0);

    $display("---- 8. a mount empties the queue");
    prog("8. a mount empties the queue");
    make_dc42;
    mount(fsize, 0);
    #1 hps_on = 0; wr_xfers = 0;
    commit(10, 40); commit(20, 41);
    repeat (200) @(posedge clk);
    make_dc42;                                      // the slot now names a new file
    mount(fsize, 0);
    check(dut.pst == 0 && !sd_wr && !wr_req, "the writer idle after the mount: the old block withdrawn, no request left up", dut.pst, 0);
    #1 hps_on = 1;
    drain;
    check(wr_xfers == 0, "nothing queued for the old file is written to the new", wr_xfers, 0);
    compare_file;
    check(diffs == 0, "the new file untouched", diffs, 0);

    $display("---- 4. a raw 800K image");
    prog("4. a raw 800K image");
    make_raw;
    mount(fsize, 0);
    check(disk_in && !is_dc42 && !img_tags, "(raw, no tags)", is_dc42, 0);
    wr_xfers = 0;
    commit(123, 50);
    drain;
    compare_file;
    check(diffs == 0, "the block written at its own place", diffs, 0);
    check(wr_xfers == 1 && wr_blk[0] == 123, "one block, 123", wr_blk[0], 123);
    wr_xfers = 0;
    pulse_eject; drain;
    check(wr_xfers == 0, "no flush for a raw image", wr_xfers, 0);

    $display("---- 10. 1.44 MB: the 12-bit block (plan 5.16.5 item 6)");
    prog("10. 1.44 MB");
    make_dc42_1440;
    mount(fsize, 0);
    check(disk_in && is_dc42 && !img_tags && file_blks == 2881, "(a 1.44 MB DiskCopy image: 1,474,644 bytes, 2,881 blocks, no tags)", file_blks, 2881);
    wr_xfers = 0;
    commit(2879, 60);
    drain;
    compare_file;
    check(diffs == 0, "image block 2,879, the last: written, clipped at the file's end", diffs, 0);
    check(wr_xfers == 2 && wr_blk[0] == 2879 && wr_blk[1] == 2880, "file blocks 2,879 and 2,880 (the partial last)", wr_blk[1], 2880);
    wr_xfers = 0;
    commit(2048, 61);
    drain;
    compare_file;
    check(diffs == 0 && wr_xfers == 2 && wr_blk[0] == 2048, "image block 2,048 (bit 11): file blocks 2,048 and 2,049, not block 0", wr_blk[0], 2048);
    // adjacent sectors, as MFM's 1:1 writes commit them (board gate 3,
    // 2026-10-06): with the header's shift, image blocks n and n + 1 share
    // file block n + 1.  The second commit must write it again once the
    // first's copy is on the card; it may skip it only while that copy
    // still waits in the queue.
    wr_xfers = 0;
    commit(100, 63); drain;
    commit(101, 64); drain;
    compare_file;
    check(diffs == 0 && wr_xfers == 4, "adjacent sectors, the writer idle between: file block 101 written again (100, 101; 101, 102)", wr_xfers, 4);
    for (k = 0; k < 6; k = k + 1) commit(400 + k, 70 + k);   // back to back: some of the shared blocks still queued
    drain;
    compare_file;
    check(diffs == 0, "six adjacent sectors back to back: every byte on the card", diffs, 0);
    dc42_dsum(1474560);
    {expf[72], expf[73], expf[74], expf[75]} = dsum;
    {expf[76], expf[77], expf[78], expf[79]} = 32'd0;
    wr_xfers = 0;
    pulse_eject; drain; compare_file;
    check(diffs == 0 && wr_xfers == 1, "the eject: the data sum over 1,474,560 bytes, the tag sum 0", diffs, 0);
    make_raw_1440;
    mount(fsize, 0);
    wr_xfers = 0;
    commit(2879, 62);
    drain;
    compare_file;
    check(diffs == 0 && wr_xfers == 1 && wr_blk[0] == 2879, "a raw 1.44 MB image: block 2,879 at its own place", wr_blk[0], 2879);

    $display("---- 9. the disk port's handshake");
    prog("9. the disk port's handshake");
    check(torn == 0, "no request torn down before its acknowledge", torn, 0);
    check(moved == 0, "its address held", moved, 0);
    check(early == 0, "none raised over a stale acknowledge", early, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the SD writer holds to plan 5.15.5", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(32.0 * 400000000); $display("==== FAIL: timeout"); $finish; end

endmodule
