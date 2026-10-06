// tb_scsi_seam.v - the seam bench (SE30_PLAN.md 9.6 item 2): the 53C80
// (rtl/se30_ncr53c80.v) and two real MacPlus targets (rtl/scsi.v, byte-
// exact) on the bus of rtl/se30_scsi.v, driven by the SE/30 ROM's own
// sequences (Docs\scsi\audit_se30_rom_scsi.md, romscsi\ listings), with
// a model of hps_io serving two disk images.
//
// THE CPU SIDE
//   Accesses are shaped as GLUE gives them: /CS or /DACK a level for the
//   access, one strobe in it.  The no-wait window ($50F12000) asserts DACK
//   at once; the handshake window ($50F06000) waits for DRQ, then DACK and
//   the strobe - and GLUE's bus error if DRQ does not come within the
//   longest UI6 window (63.3 us, plan 2.11.4).
//
// THE ROM'S SEQUENCES (addresses in the ROM)
//   SCSIReset $40826C7C: ICR = RST ~125 us, ICR = 0, register 7 read
//   SCSIGet $408268D8: ODR = own ID, MR = 0, MR = ARBITRATE, wait AIP, the
//     2.2 us delay, LA and higher-ID checks
//   SCSISelect $40826932: ICR = SEL; TCR = 0, ODR = both IDs; ICR = BSY|SEL|
//     DATA; MR = 0; SER = 0; ICR = SEL|DATA; wait BSY (250 ms); ICR = 0
//   SCSICmd $408269EE: TCR = C/D; per byte: wait REQ, phase check, ODR,
//     ICR = DATA, wait REQ, ICR = ACK|DATA, wait REQ false, ICR = 0
//   SCSIRead/RBlind $4082679A..$40826B54: TCR = I/O, MR = DMA, Start DMA
//     Initiator Receive; wait DRQ or REQ; per byte DRQ then $50F12060
//     (polled), or one DRQ wait then $50F06060 (blind)
//   SCSIWrite/WBlind $40826A48..$40826B9C: wait REQ, TCR = 0, MR = DMA, ICR =
//     DATA, Start DMA Send; per byte DRQ then $50F12000 (polled), or one
//     DRQ wait then $50F06000 (blind); then wait DRQ or phase gone, MR = 0,
//     ICR = 0
//   scStop: MR = 0, ICR = 0
//   SCSIComplete: status and message in by programmed I/O
//
// WHAT THIS PROVES
//    1. bus reset, arbitration and selection of ID 0 as the ROM runs them
//    2. TEST UNIT READY: status 0, message 0 (command complete)
//    3. READ(6) polled, 2 blocks: byte-exact
//    4. READ(6) blind, 4 blocks as four 512-byte ops (the driver's TIB
//       shape), longwords as four byte cycles: byte-exact, no bus error
//    5. WRITE(6) polled, 1 block, and blind, 2 blocks: the image byte-exact
//       after the flush; read back blind: the same
//    6. ID 1 answers, its own image
//    7. an absent ID: the selection times out (BSY never comes)
//    8. a read asking one byte more than the target sends: the polled loop
//       ends on PHASE MATCH (the ROM's error 5)
//    9. slow image fetches (~100 us a sector): reads still byte-exact - the
//       target holds REQ, DRQ follows it, the deskew keeps stale bytes out
//   10. multi-block writes (SE30_PLAN.md 10.4 item 3): the target sends the
//       sectors the Mac has filled as one request (sd_blk_cnt), the model
//       takes them as Main does; with a slow SD card (one write request
//       ~1.3 ms, ~9.6 ms) a 40-block write wraps the 32-sector ring, fills
//       it (the Mac stalls between blocks), and lands byte-exact with fewer
//       requests than blocks, none over 32 sectors; the status byte waits
//       for the last request (the image is checked at once, no settling
//       time); an unaligned 33-block write and a 1-block write after it;
//       reads still ask one sector a request
//   11-22: the CD-ROM at ID 3, an AppleCD SC (SE30_PLAN.md Section 12; its
//       firmware's addresses in Docs\cdrom\audit_applecd_sc_firmware.md),
//       the spin-up shortened to 2^14 clocks.  +NOCD skips them.
//   11. no disc: INQUIRY the SC's 54 bytes with a reset pending; TEST UNIT
//       READY CHECK, REQUEST SENSE 6/29 (16 bytes, additional length 8),
//       then 2/B7; REQUEST SENSE alone reports the state; allocation 0
//       gives 4 bytes; MODE SENSE served with no disc
//   12. a disc goes in: 2/04 while it spins up, one 6/28, then GOOD
//   13. READ CAPACITY: 269 x 2048
//   14. READ(6) polled, READ(10) blind, the last block, byte-exact; past
//       the end 5/21
//   15. MODE SENSE: 3F (64 bytes, the SC's pages and header), 30, a
//       changeable page at allocation 4, 0E refused 5/24
//   16. READ TOC (C1): the header, the lead-out 00:05:45, track 1
//       {14, 00:02:00} (4 bytes of 255 asked), track 2 refused 5/24
//   17. 43 refused after its opcode byte (5/20), CE and WRITE(6) refused
//   18. LUN 1: 5/25; INQUIRY byte 0 $7F
//   19. MODE SELECT 512: READ CAPACITY 1079 x 512, a 512-byte read byte-
//       exact, MODE SENSE's block length; 1024 refused 5/26 (512 kept);
//       back to 2048
//   20. PREVENT then EJECT: 5/80, the disc stays; ALLOW, EJECT GOOD, then
//       6/28, then 2/B7
//   21. the ROM's boot scan: after a bus reset its READ(6) of block 0 gets
//       CHECK with no data phase (6/29), and again inside the spin-up
//       (2/04); after it, block 0 reads
//   22. the CD's slot never asked a write; ID 0 still reads

`timescale 1ns/1ps

module tb_scsi_seam;

  reg clk = 0;
  always #15.9574 clk = ~clk;            // 31.3344 MHz
  reg reset_n = 0;

  // ------------------------------------------------------------ the DUT
  reg        cs = 0, dack = 0, rd = 0, wr = 0;
  reg  [2:0] rs = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata;
  wire       drq, irq;

  reg  [2:0] img_mounted = 0;
  reg [31:0] img_blocks = 0;
  wire [95:0] io_lba;
  wire [2:0] io_rd, io_wr;
  wire [17:0] io_blk_cnt;
  reg  [2:0] io_ack = 0;
  reg [12:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  wire [47:0] sd_buff_din;
  reg        sd_buff_wr = 0;
  wire [15:0] dbg;

  // the CD's spin-up shortened to 2^14 clocks (~0.5 ms); the real 2^27 is
  // ~4.3 s
  se30_scsi #(.CD_SPINUP_LOG(14)) dut (
    .clk(clk), .reset_n(reset_n), .sys_reset_n(reset_n),
    .cs(cs), .dack(dack), .rd(rd), .wr(wr), .rs(rs), .wdata(wdata), .rdata(rdata), .drq(drq), .irq(irq),
    .img_mounted(img_mounted), .img_blocks(img_blocks),
    .io_lba(io_lba), .io_rd(io_rd), .io_wr(io_wr), .io_blk_cnt(io_blk_cnt), .io_ack(io_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
    .dbg(dbg));

  integer fails = 0, checks = 0;
  task check(input cond, input [8*100-1:0] what);
    begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("FAIL %0s (t=%0t)", what, $time); end end
  endtask
  task ticks(input integer n); begin repeat (n) @(negedge clk); end endtask

  // ------------------------------------------------------------ images and hps_io
  localparam BLOCKS = 64;
  reg [7:0] img0 [0:BLOCKS*512-1];
  reg [7:0] img1 [0:BLOCKS*512-1];
  // the CD's image: CD_BLOCKS 512-byte HPS blocks = CD_BLOCKS/4 CD blocks
  localparam CD_BLOCKS = 4 * 270;        // 270 CD blocks: the lead-out at 270 + 150 = 420 frames = 00:05:45
  reg [7:0] img2 [0:CD_BLOCKS*512-1];
  integer cd_reqs = 0, cd_wr_seen = 0;
  integer k, latency = 300;              // clocks before a sector arrives (~10 us)
  integer wr_latency = 300;              // clocks before a write request is taken (the SD card's write)
  initial begin
    for (k = 0; k < BLOCKS*512; k = k + 1) begin
      img0[k] = (k * 7 + (k >> 9) * 13) & 8'hFF;
      img1[k] = (k * 11 + 5 + (k >> 9) * 3) & 8'hFF;
    end
    for (k = 0; k < CD_BLOCKS*512; k = k + 1) img2[k] = (k * 13 + 3 + (k >> 11) * 29) & 8'hFF;
  end
  // one slot at a time, as hps_io serves them; a write request's size is read
  // with the request (Main's UIO_GET_SDSTAT), then (n+1) x 256 words are read
  // over the 13-bit address, as Main's spi_block_read does
  integer s, w, blk, nblk;
  integer wr_reqs = 0, wr_secs = 0, wr_max = 0, rd_multi = 0;
  always begin
    @(negedge clk);
    if (io_rd[0] || io_rd[1] || io_wr[0] || io_wr[1] || io_rd[2] || io_wr[2]) begin
      s = io_rd[0] || io_wr[0] ? 0 : io_rd[1] || io_wr[1] ? 1 : 2;
      blk = io_lba[32*s +: 32];
      if (s == 2) begin cd_reqs = cd_reqs + 1; if (io_wr[2]) cd_wr_seen = cd_wr_seen + 1; end
      if (io_rd[s]) begin
        if (io_blk_cnt[6*s +: 6] != 0) rd_multi = rd_multi + 1;
        ticks(latency);
        io_ack[s] = 1;
        for (w = 0; w < 256; w = w + 1) begin
          @(negedge clk); sd_buff_addr = w;
          sd_buff_dout = (s == 0) ? {img0[blk*512 + 2*w + 1], img0[blk*512 + 2*w]}
                       : (s == 1) ? {img1[blk*512 + 2*w + 1], img1[blk*512 + 2*w]}
                                  : {img2[blk*512 + 2*w + 1], img2[blk*512 + 2*w]};
          sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0;
        end
        @(negedge clk); io_ack[s] = 0;
      end else begin
        nblk = io_blk_cnt[6*s +: 6] + 1;
        wr_reqs = wr_reqs + 1; wr_secs = wr_secs + nblk; if (nblk > wr_max) wr_max = nblk;
        ticks(wr_latency);
        io_ack[s] = 1;
        for (w = 0; w < 256 * nblk; w = w + 1) begin
          @(negedge clk); sd_buff_addr = w; ticks(2);
          if (s == 0) begin img0[blk*512 + 2*w] = sd_buff_din[7:0]; img0[blk*512 + 2*w + 1] = sd_buff_din[15:8]; end
          else        begin img1[blk*512 + 2*w] = sd_buff_din[23:16]; img1[blk*512 + 2*w + 1] = sd_buff_din[31:24]; end
        end
        @(negedge clk); io_ack[s] = 0;
      end
      ticks(4);
    end
  end

  // ------------------------------------------------------------ the CPU side
  reg [7:0] rv;
  reg       berr;
  task reg_wr(input [2:0] r, input [7:0] d);
    begin @(negedge clk); cs = 1; rs = r; wdata = d; @(negedge clk); wr = 1; @(negedge clk); wr = 0; ticks(2); cs = 0; ticks(1); end
  endtask
  task reg_rd(input [2:0] r);
    begin @(negedge clk); cs = 1; rs = r; @(negedge clk); rv = rdata; rd = 1; @(negedge clk); rd = 0; ticks(2); cs = 0; ticks(1); end
  endtask
  // $50F12000 / $50F12060: DACK at once
  task dma_rd; begin @(negedge clk); dack = 1; @(negedge clk); rv = rdata; rd = 1; @(negedge clk); rd = 0; ticks(2); dack = 0; ticks(1); end endtask
  task dma_wr(input [7:0] d); begin @(negedge clk); dack = 1; wdata = d; @(negedge clk); wr = 1; @(negedge clk); wr = 0; ticks(2); dack = 0; ticks(1); end endtask
  // $50F06000 / $50F06060: wait for DRQ (GLUE holds DSACK*), bus error after 63.3 us
  task hs_wait; integer n; begin berr = 0; n = 0; while (!drq && n < 1984) begin @(negedge clk); n = n + 1; end if (!drq) berr = 1; end endtask
  task hs_rd; begin hs_wait; if (!berr) begin dack = 1; rd = 1; @(negedge clk); rd = 0; rv = rdata; ticks(2); dack = 0; ticks(1); end end endtask
  task hs_wr(input [7:0] d); begin hs_wait; if (!berr) begin dack = 1; wdata = d; wr = 1; @(negedge clk); wr = 0; ticks(2); dack = 0; ticks(1); end end endtask

  // waits, as the ROM's loops (bounded here so a failure ends the bench)
  task wait_csr(input integer bitn, input v, input integer limit, output ok);
    integer n; begin ok = 0; for (n = 0; n < limit && !ok; n = n + 1) begin reg_rd(4); if (rv[bitn] == v) ok = 1; end end
  endtask

  // ------------------------------------------------------------ the ROM's routines
  task scsi_reset;
    begin reg_wr(1, 8'h80); ticks(3917); reg_wr(1, 8'h00); reg_rd(7); ticks(2000); end   // RST ~125 us
  endtask
  task scsi_get(output ok);
    integer n;
    begin
      reg_wr(0, 8'h80); reg_wr(2, 8'h00); reg_wr(2, 8'h01);
      ok = 0; for (n = 0; n < 200 && !ok; n = n + 1) begin reg_rd(1); if (rv[6]) ok = 1; end
      ticks(70);                                                        // the 2.2 us arbitration delay
      reg_rd(1); if (rv[5]) ok = 0;
      reg_rd(0); if ((rv ^ 8'h80) > 8'h80) ok = 0;
    end
  endtask
  task scsi_select(input [2:0] id, output ok);
    begin
      reg_wr(1, 8'h04); ticks(4);
      reg_wr(3, 8'h00); reg_wr(0, (8'h01 << id) | 8'h80);
      reg_wr(1, 8'h0D); reg_wr(2, 8'h00); reg_wr(4, 8'h00); reg_wr(1, 8'h05);
      ticks(4);
      wait_csr(6, 1, 400, ok);                                          // BSY from the target
      ticks(4); reg_wr(1, 8'h00);
    end
  endtask
  task scsi_cmd(input [47:0] cdb, output ok);
    integer b;
    begin
      reg_wr(3, 8'h02); ok = 1;
      for (b = 0; b < 6 && ok; b = b + 1) begin
        wait_csr(5, 1, 2000, ok);
        if (ok) begin reg_rd(5); ok = rv[3]; end                         // phase match
        if (ok) begin
          reg_wr(0, cdb[47 - 8*b -: 8]); reg_wr(1, 8'h01);
          wait_csr(5, 1, 2000, ok);
          reg_wr(1, 8'h11);
          wait_csr(5, 0, 2000, ok);
          reg_wr(1, 8'h00);
        end
      end
    end
  endtask
  // a programmed-I/O byte in a given phase (TCR value)
  task pio_in(input [3:0] tcr, output [7:0] b, output ok);
    begin
      // the status's REQ can wait for a write's last HPS request (test 10:
      // ~10 ms); SCSIComplete's own limit is the caller's, in ticks
      reg_wr(3, tcr); wait_csr(5, 1, 400000, ok);
      if (ok) begin reg_rd(5); ok = rv[3]; end
      if (ok) begin reg_rd(0); b = rv; reg_wr(1, 8'h10); wait_csr(5, 0, 2000, ok); reg_wr(1, 8'h00); end
    end
  endtask
  task scsi_complete(output [7:0] st, output [7:0] msg, output ok);
    reg ok2;
    begin pio_in(4'h3, st, ok); pio_in(4'h7, msg, ok2); ok = ok && ok2; end
  endtask
  // data in, n bytes, into rbuf; blind = the handshake window; returns 5 on a phase change
  reg [7:0] rbuf [0:32767];
  integer   rerr;
  task scsi_read(input integer n, input blind, input integer chunk);
    integer b, c;
    begin
      reg_wr(3, 8'h01); reg_wr(2, 8'h02); reg_wr(7, 8'h00);
      rerr = 0; b = 0;
      while (b < n && rerr == 0) begin
        // before each op's first byte: DRQ or REQ, then the phase check
        c = 0; reg_rd(5); while (!rv[6] && c < 100000) begin reg_rd(4); if (rv[5]) c = 100000; else begin reg_rd(5); c = c + 1; end end
        reg_rd(5); if (!rv[3]) rerr = 5;
        for (c = 0; c < chunk && b < n && rerr == 0; c = c + 1) begin
          if (blind) begin hs_rd; if (berr) rerr = 9; else begin rbuf[b] = rv; b = b + 1; end end
          else begin
            reg_rd(5);
            while (!rv[6] && rv[3]) reg_rd(5);
            if (!rv[3] && !rv[6]) rerr = 5; else begin dma_rd; rbuf[b] = rv; b = b + 1; end
          end
        end
      end
      reg_wr(2, 8'h00); reg_wr(1, 8'h00);                                // scStop
    end
  endtask
  reg [7:0] wbuf [0:32767];
  task scsi_write(input integer n, input blind, input integer chunk);
    integer b, c, ok;
    begin
      rerr = 0; b = 0;
      while (b < n && rerr == 0) begin
        wait_csr(5, 1, 100000, ok);
        reg_wr(3, 8'h00); reg_wr(2, 8'h02); reg_wr(1, 8'h01); reg_wr(5, 8'h00);
        reg_rd(5); if (!rv[3]) begin rerr = 5; $display("     write: no phase match at Start DMA Send, BSR %02x dbg %04x", rv, dbg); end
        for (c = 0; c < chunk && b < n && rerr == 0; c = c + 1) begin
          if (blind) begin hs_wr(wbuf[b]); if (berr) rerr = 9; else b = b + 1; end
          else begin
            reg_rd(5);
            while (!rv[6] && rv[3]) reg_rd(5);
            if (!rv[3]) begin rerr = 5; $display("     write: phase gone after %0d bytes, BSR %02x dbg %04x", b, rv, dbg); end
            else begin dma_wr(wbuf[b]); b = b + 1; end
          end
        end
        // the end wait: DRQ or the phase gone, then MR = 0, ICR = 0
        reg_rd(5); while (!rv[6] && rv[3]) reg_rd(5);
        reg_wr(2, 8'h00); reg_wr(1, 8'h00);
      end
    end
  endtask

  // the command bytes of a CDB of any length (left-aligned in 80 bits);
  // nsent: how many went before the target left the command phase
  integer nsent;
  task scsi_cmdn(input [79:0] cdb, input integer len, output ok);
    integer b;
    begin
      reg_wr(3, 8'h02); ok = 1; nsent = 0;
      for (b = 0; b < len && ok; b = b + 1) begin
        wait_csr(5, 1, 2000, ok);
        if (ok) begin reg_rd(5); ok = rv[3]; end
        if (ok) begin
          reg_wr(0, cdb[79 - 8*b -: 8]); reg_wr(1, 8'h01);
          wait_csr(5, 1, 2000, ok);
          reg_wr(1, 8'h11);
          wait_csr(5, 0, 2000, ok);
          reg_wr(1, 8'h00);
          nsent = nsent + 1;
        end
      end
    end
  endtask

  // ------------------------------------------------------------ one command, whole
  reg [7:0] st, msg;
  reg ok, ok2;
  integer i, bad;
  task command(input [2:0] id, input [47:0] cdb, output ok);
    begin
      scsi_get(ok); check(ok, "SCSIGet: arbitration won");
      if (ok) scsi_select(id, ok);
    end
  endtask
  function [47:0] rw6(input [7:0] op, input [20:0] lba, input [7:0] cnt);
    rw6 = {op, 3'b000, lba[20:16], lba[15:8], lba[7:0], cnt, 8'h00};
  endfunction
  task do_read(input [2:0] id, input [20:0] lba, input [7:0] cnt, input blind, input [8*40-1:0] what);
    integer b, n;
    begin
      command(id, 0, ok); check(ok, "select for a read");
      scsi_cmd(rw6(8'h08, lba, cnt), ok); check(ok, "the READ(6) command bytes");
      n = cnt * 512;
      scsi_read(n, blind, blind ? 512 : n); check(rerr == 0, what);
      bad = 0;
      for (b = 0; b < n; b = b + 1)
        if (rbuf[b] !== ((id == 0) ? img0[lba*512 + b] : img1[lba*512 + b])) bad = bad + 1;
      check(bad == 0, what);
      if (bad != 0) begin
        $display("     %0d of %0d bytes wrong; first 12 got/want:", bad, n);
        for (b = 0; b < 12; b = b + 1) $display("       [%0d] %02x %02x", b, rbuf[b], (id == 0) ? img0[lba*512 + b] : img1[lba*512 + b]);
      end
      scsi_complete(st, msg, ok); check(ok && st == 8'h00 && msg == 8'h00, "status GOOD, message COMMAND COMPLETE");
    end
  endtask
  reg [7:0] around [0:1023];             // test 10: the blocks either side of a write, before it
  integer settle = 4000;                 // clocks between the status and the image check
  task do_write(input [2:0] id, input [20:0] lba, input [7:0] cnt, input blind, input [7:0] seed);
    integer b, n;
    begin
      n = cnt * 512;
      for (b = 0; b < n; b = b + 1) wbuf[b] = (b * 5 + seed) ^ (b >> 3);
      command(id, 0, ok); check(ok, "select for a write");
      scsi_cmd(rw6(8'h0A, lba, cnt), ok); check(ok, "the WRITE(6) command bytes");
      scsi_write(n, blind, blind ? 512 : n); check(rerr == 0, "the write's data phase");
      if (rerr != 0) $display("     write error %0d", rerr);
      scsi_complete(st, msg, ok); check(ok && st == 8'h00, "write status GOOD");
      ticks(settle);                                                     // the flush to the image
      bad = 0;
      for (b = 0; b < n; b = b + 1)
        if (((id == 0) ? img0[lba*512 + b] : img1[lba*512 + b]) !== wbuf[b]) bad = bad + 1;
      check(bad == 0, "the image holds the written bytes, byte-exact");
      if (bad != 0) $display("     %0d of %0d bytes wrong in the image", bad, n);
    end
  endtask

  // ------------------------------------------------------------ the CD (plan 12.4)
  // cd_do: select ID 3, the CDB (len bytes, left-aligned in 80 bits), n_in
  // bytes in or n_out bytes out (wbuf) polled, status and message
  reg [7:0] cd_st;
  reg       cd_ok;
  task cd_do(input [79:0] cdb, input integer len, input integer n_in, input integer n_out);
    reg okc;
    begin
      command(3'd3, 0, okc); check(okc, "CD: ID 3 selected");
      scsi_cmdn(cdb, len, okc);
      rerr = 0;
      if (okc && n_in > 0) scsi_read(n_in, 1'b0, n_in);
      if (okc && n_out > 0) scsi_write(n_out, 1'b0, n_out);
      scsi_complete(cd_st, msg, cd_ok); cd_ok = cd_ok && (msg == 8'h00) && (rerr == 0);
    end
  endtask
  reg [3:0] key;
  reg [7:0] asc;
  // REQUEST SENSE, 16 bytes asked: the key and the ASC (cd_st keeps the
  // status of the command before it)
  task cd_sense;
    reg [7:0] st_before;
    begin
      st_before = cd_st;
      cd_do({8'h03, 8'h00, 8'h00, 8'h00, 8'd16, 8'h00, 32'h0}, 6, 16, 0);
      key = rbuf[2][3:0]; asc = rbuf[12];
      cd_st = st_before;
    end
  endtask
  localparam [79:0] CD_TUR = {8'h00, 72'h0};
  function [79:0] cdb6(input [7:0] op, input [7:0] b1, input [7:0] b2, input [7:0] b3, input [7:0] b4);
    cdb6 = {op, b1, b2, b3, b4, 8'h00, 32'h0};
  endfunction
  function [79:0] cdb_toc(input [7:0] trk, input [7:0] alloc, input [7:0] type9);
    cdb_toc = {8'hC1, 32'h0, trk, 8'h00, 8'h00, alloc, type9};
  endfunction
  // the AppleCD SC's INQUIRY data, its firmware's table at $3929
  reg [7:0] inq [0:53];
  initial begin
    for (k = 0; k < 54; k = k + 1) inq[k] = 8'h00;
    inq[0] = 8'h05; inq[1] = 8'h80; inq[2] = 8'h01; inq[3] = 8'h01; inq[4] = 8'h31;
    for (k = 0; k < 28; k = k + 1) inq[8 + k] = "SONY    CD-ROM CDU-8001 3.2i" >> (8 * (27 - k));
    inq[39] = 8'hD0; inq[40] = 8'h90; inq[41] = 8'h27; inq[42] = 8'h3E; inq[43] = 8'h01;
    inq[44] = 8'h04; inq[45] = 8'h91; inq[47] = 8'h18; inq[48] = 8'h06; inq[49] = 8'hF0;
    inq[50] = 8'hFC; inq[53] = 8'hFF;
  end
  task cd_read(input integer op10, input integer lba, input integer cnt, input integer bsize, input blind,
               input [8*48-1:0] what);
    integer b, n;
    begin
      n = cnt * bsize;
      command(3'd3, 0, ok); check(ok, "CD: select for a read");
      if (op10) scsi_cmdn({8'h28, 8'h00, lba[31:0], 8'h00, cnt[15:0], 8'h00}, 10, ok);
      else      scsi_cmdn({8'h08, 3'b000, lba[20:0], cnt[7:0], 8'h00, 32'h0}, 6, ok);
      check(ok, "CD: the READ's command bytes");
      scsi_read(n, blind, blind ? bsize : n); check(rerr == 0, what);
      bad = 0;
      for (b = 0; b < n; b = b + 1) if (rbuf[b] !== img2[lba * bsize + b]) bad = bad + 1;
      check(bad == 0, what);
      if (bad != 0) $display("     %0d of %0d bytes wrong", bad, n);
      scsi_complete(st, msg, ok); check(ok && st == 8'h00 && msg == 8'h00, "CD: the READ's status GOOD");
    end
  endtask

  initial begin
    ticks(5); reset_n = 1; ticks(5);
    img_blocks = BLOCKS;
    @(negedge clk); img_mounted = 3'b011; @(negedge clk); img_mounted = 3'b000; ticks(20);

    if ($test$plusargs("QUICK")) begin
      scsi_reset; reg_rd(7);
      do_read(3'd0, 21'd5, 8'd1, 1'b1, "Q. READ(6) blind, 1 block");
      do_write(3'd0, 21'd10, 8'd1, 1'b0, 8'h3C);
      $display("==== QUICK done: %0d fails", fails); $finish;
    end
    // 1, 2
    scsi_reset; reg_rd(7);
    command(3'd0, 0, ok); check(ok, "1. ID 0 selected");
    scsi_cmd(48'h0, ok); check(ok, "2. TEST UNIT READY's six bytes");
    scsi_complete(st, msg, ok); check(ok, "2. status and message phases");
    check(st == 8'h00 && msg == 8'h00, "2. status GOOD, COMMAND COMPLETE");
    ticks(50); check(dbg[15:14] == 2'b00, "2. the target has left the bus");

    // 3, 4
    do_read(3'd0, 21'd0, 8'd2, 1'b0, "3. READ(6) polled, 2 blocks, byte-exact");
    do_read(3'd0, 21'd5, 8'd4, 1'b1, "4. READ(6) blind, 4 blocks, byte-exact");

    // 5
    do_write(3'd0, 21'd10, 8'd1, 1'b0, 8'h3C);
    do_write(3'd0, 21'd12, 8'd2, 1'b1, 8'hA7);
    do_read(3'd0, 21'd10, 8'd4, 1'b1, "5. the written blocks read back blind");

    // 6
    do_read(3'd1, 21'd3, 8'd2, 1'b0, "6. ID 1 reads its own image");

    // 7
    scsi_get(ok); scsi_select(3'd4, ok2); check(!ok2, "7. an absent ID (4): no BSY, the selection times out");
    reg_wr(1, 8'h00); reg_wr(2, 8'h00); ticks(100);

    // 8: ask 513 bytes of a 1-block read
    command(3'd0, 0, ok); scsi_cmd(rw6(8'h08, 21'd1, 8'd1), ok);
    scsi_read(513, 1'b0, 513); check(rerr == 5, "8. one byte too many: the loop ends on PHASE MATCH (error 5)");
    scsi_complete(st, msg, ok); check(ok && st == 8'h00, "8. then status GOOD");

    // 9
    latency = 3000;
    do_read(3'd0, 21'd20, 8'd3, 1'b0, "9. slow fetches, polled: byte-exact");
    do_read(3'd1, 21'd30, 8'd3, 1'b1, "9. slow fetches, blind per block: byte-exact");

    // 10: multi-block writes
    check(rd_multi == 0, "10. every read request so far asked one sector");
    settle = 0;                                                          // the status must follow the last request
    wr_latency = 40000;                                                  // ~1.3 ms a request
    wr_reqs = 0; wr_secs = 0; wr_max = 0;
    do_write(3'd0, 21'd16, 8'd40, 1'b1, 8'h5D);
    $display("     40 blocks, 1.3 ms requests: %0d requests, %0d sectors, the largest %0d", wr_reqs, wr_secs, wr_max);
    check(wr_secs == 40, "10. 40 blocks at 1.3 ms: every sector sent exactly once");
    check(wr_reqs < 40 && wr_max > 1, "10. 40 blocks at 1.3 ms: the sectors went out in multi-block requests");
    check(wr_max <= 32, "10. 40 blocks at 1.3 ms: no request over the ring's 32 sectors");
    do_read(3'd0, 21'd16, 8'd40, 1'b1, "10. the 40 blocks read back blind, byte-exact");
    wr_latency = 300000;                                                 // ~9.6 ms: the ring fills
    wr_reqs = 0; wr_secs = 0; wr_max = 0;
    for (k = 0; k < 512; k = k + 1) begin around[k] = img1[6*512 + k]; around[512 + k] = img1[40*512 + k]; end
    do_write(3'd1, 21'd7, 8'd33, 1'b1, 8'hC4);
    bad = 0;
    for (k = 0; k < 512; k = k + 1) begin
      if (img1[6*512 + k] !== around[k]) bad = bad + 1;
      if (img1[40*512 + k] !== around[512 + k]) bad = bad + 1;
    end
    check(bad == 0, "10. the blocks either side of the 33 (LBA 6 and 40) untouched");
    $display("     33 blocks from LBA 7, 9.6 ms requests: %0d requests, %0d sectors, the largest %0d", wr_reqs, wr_secs, wr_max);
    check(wr_secs == 33, "10. 33 blocks at 9.6 ms: every sector sent exactly once");
    check(wr_max >= 30 && wr_max <= 32, "10. 33 blocks at 9.6 ms: the ring filled (a request of 30-32 sectors)");
    do_read(3'd1, 21'd7, 8'd33, 1'b0, "10. the 33 blocks read back polled, byte-exact");
    wr_reqs = 0; wr_secs = 0; wr_max = 0;
    do_write(3'd0, 21'd63, 8'd1, 1'b0, 8'h91);
    check(wr_reqs == 1 && wr_secs == 1, "10. a 1-block write at the last LBA: one request, one sector");
    check(rd_multi == 0, "10. reads still ask one sector a request");

    // ---------------------------------------------------- 11-22: the CD-ROM
    // ID 3, an AppleCD SC (plan 12.2/12.3), its spin-up 2^14 clocks here
    latency = 300; wr_latency = 300;
    if (!$test$plusargs("NOCD")) begin
    // 11: no disc
    scsi_reset; reg_rd(7); ticks(20000);                                 // past the spin-up
    cd_do(cdb6(8'h12, 8'h00, 8'h00, 8'h00, 8'd255), 6, 54, 0);
    check(cd_ok && cd_st == 8'h00, "11. INQUIRY with a reset pending: 54 bytes, GOOD");
    bad = 0; for (k = 0; k < 54; k = k + 1) if (rbuf[k] !== inq[k]) bad = bad + 1;
    check(bad == 0, "11. INQUIRY: the AppleCD SC's bytes ($3929), CDU-8001 3.2i");
    cd_do(CD_TUR, 6, 0, 0); check(cd_ok && cd_st == 8'h02, "11. TEST UNIT READY after the reset: CHECK CONDITION");
    cd_sense; check(cd_ok && key == 4'h6 && asc == 8'h29, "11. ... UNIT ATTENTION 6/29");
    check(rbuf[0] == 8'h70 && rbuf[7] == 8'h08, "11. REQUEST SENSE: extended sense, additional length 8 (16 bytes)");
    cd_do(CD_TUR, 6, 0, 0); check(cd_ok && cd_st == 8'h02, "11. TEST UNIT READY, no disc: CHECK");
    cd_sense; check(key == 4'h2 && asc == 8'hB7, "11. ... NOT READY / $B7 (the SC's no-disc)");
    cd_sense; check(key == 4'h2 && asc == 8'hB7, "11. REQUEST SENSE with nothing stored: the state, NOT READY / $B7");
    cd_do(cdb6(8'h03, 8'h00, 8'h00, 8'h00, 8'd0), 6, 4, 0);
    check(cd_ok && cd_st == 8'h00, "11. REQUEST SENSE, allocation 0: 4 bytes, GOOD");
    cd_do(cdb6(8'h1A, 8'h00, 8'h3F, 8'h00, 8'd255), 6, 64, 0);
    check(cd_ok && cd_st == 8'h00, "11. MODE SENSE with no disc: served (NOT READY tolerated), 64 bytes");

    // 12: a disc goes in
    img_blocks = CD_BLOCKS;
    @(negedge clk); img_mounted = 3'b100; @(negedge clk); img_mounted = 3'b000; ticks(20);
    cd_do(CD_TUR, 6, 0, 0); cd_sense;
    check(key == 4'h2 && asc == 8'h04, "12. a disc goes in: NOT READY / 04 while it spins up");
    ticks(20000);
    cd_do(cdb6(8'h00, 8'h20, 8'h00, 8'h00, 8'h00), 6, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h25, "12. a LUN 1 command meanwhile: 5/25, the attention kept");
    cd_do(CD_TUR, 6, 0, 0); check(cd_ok && cd_st == 8'h02, "12. then CHECK once");
    cd_sense; check(key == 4'h6 && asc == 8'h28, "12. ... UNIT ATTENTION 6/28 (medium changed)");
    cd_do(CD_TUR, 6, 0, 0); check(cd_ok && cd_st == 8'h00, "12. then TEST UNIT READY GOOD");

    // 13: READ CAPACITY
    cd_do({8'h25, 72'h0}, 10, 8, 0);
    check(cd_ok && cd_st == 8'h00 && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'd269 &&
          {rbuf[4], rbuf[5], rbuf[6], rbuf[7]} == 32'd2048, "13. READ CAPACITY: last block 269, 2048 bytes");

    // 14: reads
    cd_read(0, 3, 2, 2048, 1'b0, "14. READ(6) polled, 2 CD blocks, byte-exact");
    cd_read(1, 100, 3, 2048, 1'b1, "14. READ(10) blind per block, 3 CD blocks, byte-exact");
    cd_read(0, 269, 1, 2048, 1'b0, "14. READ(6) of the last block, byte-exact");
    cd_do({8'h08, 8'h00, 8'h01, 8'h0E, 8'd1, 8'h00, 32'h0}, 6, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h21, "14. READ(6) at block 270: CHECK, 5/21");

    // 15: MODE SENSE
    cd_do(cdb6(8'h1A, 8'h00, 8'h3F, 8'h00, 8'd255), 6, 64, 0);
    check(cd_ok && rbuf[0] == 8'd63 && rbuf[2] == 8'h00 && rbuf[3] == 8'h08 &&
          {rbuf[5], rbuf[6], rbuf[7]} == 24'h0 && {rbuf[9], rbuf[10], rbuf[11]} == 24'h000800,
          "15. MODE SENSE 3F: header (length 63, no WP, BD 8), block count 0, 2048");
    check(rbuf[12] == 8'h00 && rbuf[13] == 8'h02 && rbuf[14] == 8'h10 && rbuf[16] == 8'h01 && rbuf[24] == 8'h02 &&
          rbuf[26] == 8'h08 && rbuf[36] == 8'h20 && rbuf[39] == 8'h05 && rbuf[40] == 8'h30 && rbuf[41] == 8'h16 &&
          rbuf[42] == "A" && rbuf[60] == "C" && rbuf[63] == " ", "15. MODE SENSE 3F: pages 00, 01, 02, 20, 30 as the SC's ROM");
    cd_do(cdb6(8'h1A, 8'h00, 8'h30, 8'h00, 8'd255), 6, 36, 0);
    check(cd_ok && rbuf[0] == 8'd35 && rbuf[12] == 8'h30, "15. MODE SENSE 30: 36 bytes");
    cd_do(cdb6(8'h1A, 8'h00, 8'h41, 8'h00, 8'd4), 6, 4, 0);
    check(cd_ok && rbuf[0] == 8'd3 && rbuf[3] == 8'h00, "15. MODE SENSE 01 changeable, allocation 4: 4 bytes, no BD length");
    cd_do(cdb6(8'h1A, 8'h00, 8'h0E, 8'h00, 8'd255), 6, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h24, "15. MODE SENSE 0E (not the SC's): CHECK, 5/24");

    // 16: READ TOC (C1)
    cd_do(cdb_toc(8'h00, 8'd4, 8'h00), 10, 4, 0);
    check(cd_ok && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'h01010000, "16. C1 header: first 01, last 01");
    cd_do(cdb_toc(8'h00, 8'd4, 8'h40), 10, 4, 0);
    check(cd_ok && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'h00054500, "16. C1 lead-out: 00:05:45 (270 + 150 frames), BCD");
    cd_do(cdb_toc(8'h01, 8'd255, 8'h80), 10, 4, 0);
    check(cd_ok && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'h14000200, "16. C1 from track 1: {14, 00:02:00}, 4 bytes of 255 asked");
    cd_do(cdb_toc(8'h02, 8'd4, 8'h80), 10, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h24, "16. C1 from track 2 (none): CHECK, 5/24");

    // 17: commands the SC does not have
    cd_do({8'h43, 72'h0}, 10, 0, 0);
    check(nsent == 1 && cd_st == 8'h02, "17. 43 (SCSI-2 READ TOC): STATUS after the opcode byte, CHECK");
    cd_sense; check(key == 4'h5 && asc == 8'h20, "17. ... ILLEGAL REQUEST 5/20");
    cd_do({8'hCE, 72'h0}, 10, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h20, "17. CE (the CDU-8004's AUDIO CONTROL): CHECK, 5/20");
    cd_do(cdb6(8'h0A, 8'h00, 8'h00, 8'h05, 8'd1), 6, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h20, "17. WRITE(6): CHECK, 5/20");

    // 18: the LUN
    cd_do(cdb6(8'h00, 8'h20, 8'h00, 8'h00, 8'h00), 6, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h25, "18. TEST UNIT READY to LUN 1: CHECK, 5/25");
    cd_do(cdb6(8'h12, 8'h20, 8'h00, 8'h00, 8'd1), 6, 1, 0);
    check(cd_ok && rbuf[0] == 8'h7F, "18. INQUIRY to LUN 1: byte 0 $7F");

    // 19: the block length
    for (k = 0; k < 12; k = k + 1) wbuf[k] = 8'h00;
    wbuf[3] = 8'h08; wbuf[10] = 8'h02;
    cd_do(cdb6(8'h15, 8'h00, 8'h00, 8'h00, 8'd12), 6, 0, 12);
    check(cd_ok && cd_st == 8'h00, "19. MODE SELECT, block length 512: GOOD");
    cd_do({8'h25, 72'h0}, 10, 8, 0);
    check(cd_ok && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'd1079 &&
          {rbuf[4], rbuf[5], rbuf[6], rbuf[7]} == 32'd512, "19. READ CAPACITY at 512: last block 1079 (4n + 3)");
    cd_read(0, 13, 3, 512, 1'b0, "19. READ(6) at 512, 3 blocks from 13, byte-exact");
    cd_do(cdb6(8'h1A, 8'h00, 8'h00, 8'h00, 8'd255), 6, 16, 0);
    check(cd_ok && {rbuf[9], rbuf[10], rbuf[11]} == 24'h000200, "19. MODE SENSE: the current block length 512");
    wbuf[10] = 8'h04;
    cd_do(cdb6(8'h15, 8'h00, 8'h00, 8'h00, 8'd12), 6, 0, 12); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h26, "19. MODE SELECT 1024: CHECK, 5/26");
    cd_do({8'h25, 72'h0}, 10, 8, 0);
    check(cd_ok && {rbuf[4], rbuf[5], rbuf[6], rbuf[7]} == 32'd512, "19. ... the length stays 512");
    wbuf[10] = 8'h08;
    cd_do(cdb6(8'h15, 8'h00, 8'h00, 8'h00, 8'd12), 6, 0, 12);
    cd_do({8'h25, 72'h0}, 10, 8, 0);
    check(cd_ok && {rbuf[0], rbuf[1], rbuf[2], rbuf[3]} == 32'd269 &&
          {rbuf[4], rbuf[5], rbuf[6], rbuf[7]} == 32'd2048, "19. MODE SELECT 2048: back to 269 x 2048");

    // 20: eject
    cd_do(cdb6(8'h1E, 8'h00, 8'h00, 8'h00, 8'h01), 6, 0, 0); check(cd_ok && cd_st == 8'h00, "20. PREVENT: GOOD");
    cd_do({8'hC0, 72'h0}, 10, 0, 0); cd_sense;
    check(cd_st == 8'h02 && key == 4'h5 && asc == 8'h80, "20. C0 EJECT while prevented: CHECK, 5/80");
    cd_do(CD_TUR, 6, 0, 0); check(cd_ok && cd_st == 8'h00, "20. ... the disc stays");
    cd_do(cdb6(8'h1E, 8'h00, 8'h00, 8'h00, 8'h00), 6, 0, 0);
    cd_do({8'hC0, 72'h0}, 10, 0, 0); check(cd_ok && cd_st == 8'h00, "20. C0 EJECT allowed: GOOD");
    cd_do(CD_TUR, 6, 0, 0); cd_sense; check(cd_st == 8'h02 && key == 4'h6 && asc == 8'h28, "20. then UNIT ATTENTION 6/28");
    cd_do(CD_TUR, 6, 0, 0); cd_sense; check(cd_st == 8'h02 && key == 4'h2 && asc == 8'hB7, "20. then NOT READY / $B7");

    // 21: the ROM's boot scan with a disc in: a bus reset, then its READ(6)
    // of block 0 (SE30_PLAN.md 9.3) - CHECK with no data phase, twice
    img_blocks = CD_BLOCKS;
    @(negedge clk); img_mounted = 3'b100; @(negedge clk); img_mounted = 3'b000; ticks(20000);
    cd_do(CD_TUR, 6, 0, 0); cd_do(CD_TUR, 6, 0, 0);                        // the medium change, reported
    scsi_reset; reg_rd(7);
    cd_do(cdb6(8'h08, 8'h00, 8'h00, 8'h00, 8'd1), 6, 0, 0);
    check(cd_ok && cd_st == 8'h02, "21. after a bus reset, the ROM's READ(6) of block 0: CHECK, no data phase (6/29)");
    cd_do(cdb6(8'h08, 8'h00, 8'h00, 8'h00, 8'd1), 6, 0, 0);
    check(cd_ok && cd_st == 8'h02, "21. its retry inside the spin-up: CHECK, no data phase (2/04)");
    ticks(20000);
    cd_read(0, 0, 1, 2048, 1'b0, "21. after the spin-up: block 0, 2048 bytes");

    // 22: the CD never asked for a write; the disks still answer
    check(cd_wr_seen == 0 && cd_reqs > 0, "22. the CD's slot: reads only");
    do_read(3'd0, 21'd5, 8'd1, 1'b1, "22. ID 0 still reads, byte-exact");
    end

    if (fails == 0) $display("==== PASS: %0d checks, the 53C80 and the MacPlus targets meet at the bus", checks);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #400000000; $display("==== FAIL: timeout"); $finish; end

endmodule
