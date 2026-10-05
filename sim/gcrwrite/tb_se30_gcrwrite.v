// tb_se30_gcrwrite.v - the write seam: SWIM -> drive -> track buffer ->
// decoder -> image, held to SE30_PLAN.md 5.15, item 6 of 5.15.9's list.
//
// WHAT THIS PROVES
//   The real se30_swim, se30_fdhd, se30_flp_encoder and se30_flp_decoder,
//   wired as the machine and the top wire them, driven at the register
//   level by the ROM's own sequences at the ROM's pace:
//
//     1. a sector written as the ROM's writer writes it ($4082E518): the
//        write state entered from the sense state with $FF, the handshake
//        polled before each byte, the sync, D5 AA AD, the sector's code,
//        703 codes, DE AA FF FF, L7 cleared at once after the last write
//        (so the last FF is cut, as on the real disk): the sector's data
//        and tags reach the image at its block, nothing else changes, no
//        underrun
//     2. a side formatted as the ROM's formatter formats it ($408320BC):
//        one write of 1,200 sync bytes and twelve sectors of zeros - more
//        than a revolution: all twelve committed as zeros, once each
//     3. the cell alignment between the SWIM's write cell and the drive's
//        cell grid: what the IWM shifted out is what the decoder framed
//        (1 and 2 depend on it), from whatever phase the drive is in
//
// THE BENCH
//   clk is FCLK (15.6672 MHz, c16_en tied high, as sim/swim); the encoder
//   and decoder run on it too (the machine runs them on clk_sys, twice as
//   fast - only their pace differs).  The image sits in a word memory
//   (sim/flpdec's), served to the encoder and written by the decoder.  The
//   drive's SEL (VIA1 PA5) is a bench register.  Accesses are the ROM's
//   pace: the write strobe 15 FCLK after the poll that saw the buffer empty
//   (plan 1.17.5's measured minimum).

`timescale 1ns/1ps

module tb_se30_gcrwrite;

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
  wire [6:0] cyl, trk_cyl;
  wire       trk_valid, trk_side, trk_bit, trk_we, trk_wbit;
  wire [16:0] trk_addr, trk_cells, arc_start, arc_end;
  wire       arc_done, arc_side, arc_whole;
  wire       hold, dec_bit, enc_idle, ds_eff;
  wire [17:0] dec_addr;
  wire       en_req, de_req, cm_done;
  wire [23:0] en_addr, de_addr;
  wire [15:0] de_wdata;
  reg  [15:0] en_rdata = 0;
  reg        en_ack = 0, de_ack = 0;
  wire [10:0] cm_blk;
  wire [31:0] ddbg;

  se30_fdhd drive (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(ph_pin), .sel(via_sel), .sense(sense),
    .disk_in(1'b1), .eject(),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .wprot(1'b0), .wrreq_n(wrreq_n), .wrdata(wrdata),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
    .dbg());

  se30_flp_encoder #(.BASE(BASE)) enc (
    .clk(clk), .reset_n(reset_n),
    .disk_in(1'b1), .img_ds(ds_eff), .img_tags(1'b1), .img_800k(1'b1),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .hold(hold), .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle),
    .mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
    .dbg());

  se30_flp_decoder #(.BASE(BASE)) dec (
    .clk(clk), .reset_n(reset_n),
    .disk_in(1'b1), .loading(1'b0), .write_ok(1'b1),
    .img_ds(1'b1), .img_800k(1'b1), .img_tags(1'b1), .ds_eff(ds_eff),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end),
    .arc_whole(arc_whole), .trk_cells(trk_cells), .cyl(cyl),
    .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle), .hold(hold),
    .mem_req(de_req), .mem_addr(de_addr), .mem_wdata(de_wdata), .mem_ack(de_ack),
    .cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(1'b1),
    .dbg(ddbg));

  // ------------------------------------------------------------ the image (sim/flpdec's)
  reg [15:0] mem  [0:1600*256 + 1600*6 - 1];
  reg [15:0] want [0:1600*256 + 1600*6 - 1];
  function [7:0] dimg(input integer n, input integer i); dimg = (n * 7 + i * 13) & 8'hFF; endfunction
  function [7:0] timg(input integer n, input integer j); timg = (n * 5 + j * 31 + 1) & 8'hFF; endfunction
  integer n, i, j, k, diffs;
  task build_image;
    begin
      for (n = 0; n < 1600; n = n + 1) begin
        for (i = 0; i < 256; i = i + 1) begin mem[n * 256 + i] = {dimg(n, 2 * i), dimg(n, 2 * i + 1)}; want[n * 256 + i] = mem[n * 256 + i]; end
        for (j = 0; j < 6; j = j + 1) begin
          mem[409600 + n * 6 + j] = {timg(n, 2 * j), timg(n, 2 * j + 1)};
          want[409600 + n * 6 + j] = mem[409600 + n * 6 + j];
        end
      end
    end
  endtask
  task compare_image;
    begin diffs = 0; for (n = 0; n < 1600 * 262; n = n + 1) if (mem[n] !== want[n]) diffs = diffs + 1; end
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
  task rd(input [15:0] off);               begin access(off, 8'hA5); end endtask
  task wr(input [15:0] off, input [7:0] d); begin access(off, d); end endtask
  task drv_addr(input [3:0] n);
    begin
      rd(16'h0200); rd(16'h0600);
      if (n[0]) rd(16'h0A00); else rd(16'h0800);
      #1 via_sel = n[1];
      if (!n[2]) rd(16'h0000);
      if (!n[3]) rd(16'h0400);
    end
  endtask
  reg sns;
  task drv_read(input [3:0] n); begin drv_addr(n); rd(16'h1A00); rd(16'h1C00); sns = q[7]; rd(16'h1800); end endtask
  task drv_cmd(input [3:0] n);  begin drv_addr(n); rd(16'h0E00); repeat (4) @(posedge clk); rd(16'h0C00); end endtask

  // the byte stream to write (sim/flpdec's field builders)
  reg [7:0] fb [0:12000];
  integer nfb;
  task put(input [7:0] b); begin fb[nfb] = b; nfb = nfb + 1; end endtask
  task put_sync; begin put(8'hFF); put(8'h3F); put(8'hCF); put(8'hF3); put(8'hFC); put(8'hFF); end endtask
  function [7:0] gcr(input [5:0] v);
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
  endfunction
  reg [7:0] sec [0:523];
  task put_data_field(input integer k);
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
      put(gcr({ca[7:6], cb[7:6], cc[7:6]})); put(gcr(ca[5:0])); put(gcr(cb[5:0])); put(gcr(cc[5:0]));
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

  // the ROM's write of fb[]: the sense state (L6 set), the first byte with
  // L7 set ($4082E52E-$4082E536), then each byte after a poll that saw the
  // buffer empty, the strobe 15 FCLK after the poll's; then the last poll's
  // bit 6 and L7 cleared at once ($4082E64E-$4082E656)
  reg underrun;
  task rom_write;
    integer b;
    begin
      rd(16'h1A00); wr(16'h1E00, fb[0]);
      for (b = 1; b < nfb; b = b + 1) begin
        rd(16'h1800);
        while (!q[7]) rd(16'h1800);
        repeat (10) @(posedge clk);
        wr(16'h1A00, fb[b]);
      end
      rd(16'h1800);
      while (!q[7]) rd(16'h1800);
      underrun = !q[6];
      rd(16'h1C00);                                     // L7 cleared
    end
  endtask
  task wait_decoded;
    integer t0;
    begin
      t0 = cyc; repeat (8) @(posedge clk);
      while (hold && cyc - t0 < 4000000) @(posedge clk);
      repeat (8) @(posedge clk);
    end
  endtask
  // the encoder's layout: the leftover, then 776 bytes a slot, the data
  // field's sync 59 bytes in
  function integer slot_of(input integer k);
    slot_of = (k < 6) ? 2 * k : 2 * (k - 6) + 1;       // 12 sectors, 2:1 ($408321CA)
  endfunction
  function integer field_cell(input integer k);
    field_cell = (74558 - 12 * 6208) + slot_of(k) * 6208 + (48 + 11) * 8;
  endfunction

  integer t0, start;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);
    build_image;

    // the ROM's set-up: mode $17, the drive enabled, its motor on, /READY
    rd(16'h1000); rd(16'h1A00); wr(16'h1E00, 8'h17); rd(16'h1C00); rd(16'h1800);
    rd(16'h1200);                                       // MotorOn: /ENBL1 low
    drv_cmd(4'h8);                                      // the drive's motor on
    t0 = cyc; drv_read(4'hB);
    while (sns && cyc - t0 < 12000000) begin repeat (2000) @(posedge clk); drv_read(4'hB); end
    check(!sns, "the drive ready: motor up, cylinder 0 built", sns, 0);
    #1 via_sel = 0;                                     // side 0 (VIA1 PA5)
    rd(16'h0000); rd(16'h0400); rd(16'h0800);           // the phases parked: CA0-2 low (a read register)

    $display("---- 1. a sector written as the ROM writes it");
    for (i = 0; i < 524; i = i + 1) sec[i] = (i * 11 + 3) & 8'hFF;
    nfb = 0; put_data_field(5);                         // (rom_write cuts the last FF, as the ROM does)
    start = field_cell(5);
    while (drive.pos != start - 1) @(posedge clk);      // as the ROM: just after the address field
    ncm = 0;
    rom_write;
    wait_decoded;
    check(!underrun, "no underrun at the ROM's pace", underrun, 0);
    check(ncm == 1 && cmb[0] == 5, "sector 5 committed, to block 5", cmb[0], 5);
    for (i = 0; i < 256; i = i + 1) want[5 * 256 + i] = {sec[12 + 2 * i], sec[13 + 2 * i]};
    for (j = 0; j < 6; j = j + 1) want[409600 + 5 * 6 + j] = {sec[2 * j], sec[2 * j + 1]};
    compare_image;
    check(diffs == 0, "its data and tags in the image, nothing else changed", diffs, 0);

    $display("---- 2. a side formatted as the ROM formats it");
    nfb = 0;
    for (i = 0; i < 200; i = i + 1) put_sync;
    for (i = 0; i < 12; i = i + 1) begin
      for (k = 0; k < 8; k = k + 1) put_sync;
      put_addr_field(0, (i % 2 == 0) ? i / 2 : 6 + (i - 1) / 2, 0, 6'h22);
      for (k = 0; k < 524; k = k + 1) sec[k] = 8'h00;
      put_data_field((i % 2 == 0) ? i / 2 : 6 + (i - 1) / 2);
    end
    ncm = 0;
    rom_write;
    wait_decoded;
    check(!underrun, "no underrun", underrun, 0);
    check(ncm == 12, "all twelve sectors committed, once each", ncm, 12);
    k = 0; for (i = 0; i < ncm && i < 64; i = i + 1) if (cmb[i] > 11) k = k + 1;
    check(k == 0, "to cylinder 0 side 0's blocks", k, 0);
    check(ds_eff == 1, "the format byte $22: still double-sided", ds_eff, 1);
    for (n = 0; n < 12; n = n + 1) begin
      for (i = 0; i < 256; i = i + 1) want[n * 256 + i] = 16'h0000;
      for (j = 0; j < 6; j = j + 1) want[409600 + n * 6 + j] = 16'h0000;
    end
    compare_image;
    check(diffs == 0, "as zeros, data and tags; nothing else changed", diffs, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the write seam holds to plan 5.15", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(64.0 * 40000000); $display("==== FAIL: timeout"); $finish; end

endmodule
