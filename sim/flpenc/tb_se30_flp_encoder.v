// tb_se30_flp_encoder.v - the track encoder held to SE30_PLAN.md 5.12.4
// and 5.12.5b, item 3 of 5.12.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_flp_encoder.v lays out, from a disk image in memory, the
//   tracks the ROM's GCR formatter would have written ($40831F24), at the
//   drive model's exact revolution lengths:
//
//     1. every cylinder of a double-sided image with tags, both sides:
//        all 1600 sectors recovered byte for byte - tags and data - by a
//        reference decoder in this bench (the IWM's byte framing, the
//        address field, the ERS's steps 1-9 inverted) reading exactly
//        ONE revolution; the address fields' track, side and format
//        ($22), the formatter's interleave, eight sync chunks before
//        every address mark, and the leftover at the track's start
//     2. the disk port's handshake: no request torn down before its
//        acknowledge, its address held, and no request raised while the
//        last acknowledge is still up (MacPlus phases 1 and 7)
//     3. a single-sided image: side 0 with format $02, side 1 no flux
//     4. an image without tags: the tag bytes decode as zeros
//     5. a second opinion: MacPlus's floppy_track_encoder.v run on the
//        same (tagless) image produces the same address fields and the
//        same 704 data-field code bytes, sector for sector, on a track
//        of every speed group, both sides
//     6. negative cases, one revolution only (MacLC phases 0 and 2): a
//        bit flipped in one sector's data field fails that sector's
//        checksum and no other; one flipped in an address field fails
//        that header
//     1b. every cell outside the data-field codes, on every side of every
//        cylinder, is the formatter's layout bit for bit (the sync
//        chunks, the pads, the marks, the address fields)
//     7. a new cylinder mid-build - one arriving while a request waits for
//        its acknowledge - restarts the build; trk_valid only for
//        the cylinder asked for; disk out drops it; the build time
//
//   and, for an MFM image (plan 5.13.9 item 3, 5.13.10 item 3), the track
//   the ROM's MFM formatter would have written ($4082EC5E):
//
//     8. a 1.44 MB image, every cylinder, both sides: 200,000 cells a
//        side; every interval between transitions 2, 3 or 4 cells (MFM's
//        rule, around the wrap too); the mark - an A1 with its clock
//        dropped as the User's Reference describes - nowhere but in the
//        36 places a side's 18 sectors put it; all 2,880 sectors found
//        by a reference decoder in this bench - the address field's C H
//        R N, both CRCs (the User's Reference's pseudo-code, from all
//        ones over the three A1s and the field), the data byte for byte -
//        in 1:1 order; the gaps (32 x 4E after the index, 22, gap 3 of
//        108, 4E to the end); and every cell the formatter's layout bit
//        for bit; the port reads what the buffer holds (side 1 at
//        200,000); the build time
//     9. a 720K image: 100,000 cells, 9 sectors, gap 3 of 80, on a set of
//        cylinders
//    10. a second opinion: MacLC's mfm_track_encoder.v (byte-level, an
//        IBM layout of its own) gives the same address fields and data
//        fields - marks, C H R N, data, CRCs - sector for sector
//    11. negative cases (a flipped cell fails its sector's CRC alone, or
//        its header); a new cylinder mid-build; a GCR image after the
//        MFM ones still builds GCR
//
//   +MFM_ONLY skips sections 1-7 (the GCR half, ~6.5 min).
//
// THE BENCH
//   clk is clk_sys (31.3344 MHz).  The image sits in a word memory as the
//   loader will leave it (5.12.5b: base + k holds bytes 2k and 2k+1; the
//   tags after the data).  Each block's data bytes 0-2 are its cylinder,
//   side and sector (MacLC's self-identifying pattern); the rest and the
//   tags are functions of the block number.  The memory answers a request
//   after 3 to 12 clocks and holds its acknowledge two clocks after the
//   request drops.

`timescale 1ns/1ps

module tb_se30_flp_encoder;

  localparam [23:0] BASE = 24'h800000;

  reg clk = 0;
  always #16 clk = ~clk;
  reg reset_n = 0;

  reg        disk_in = 0, img_ds = 1, img_tags = 1, img_mfm = 0, img_hd = 0;
  reg  [6:0] cyl = 0;
  wire [6:0] trk_cyl;
  wire       trk_valid;
  reg [17:0] trk_addr = 0;
  reg        trk_side = 0;
  wire       trk_bit;
  wire       mem_req;
  wire [23:0] mem_addr;
  reg  [15:0] mem_rdata = 0;
  reg        mem_ack = 0;
  wire [15:0] dbg;

  se30_flp_encoder #(.BASE(BASE)) dut (
    .clk(clk), .reset_n(reset_n),
    .disk_in(disk_in), .img_ds(img_ds), .img_tags(img_tags), .img_800k(img_ds),
    .img_mfm(img_mfm), .img_hd(img_hd),
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .trk_we(1'b0), .trk_wbit(1'b0), .hold(1'b0), .dec_addr(19'd0), .dec_bit(), .enc_idle(),
    .mem_req(mem_req), .mem_addr(mem_addr), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
    .dbg(dbg));

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

  // ------------------------------------------------------------ geometry
  function integer spt(input integer c);
    spt = 12 - c / 16;
  endfunction
  function integer secs_before(input integer c);     // sectors on one side before cylinder c
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
  // the formatter's order ($408321CA)
  function integer il(input integer n, input integer i);
    il = (i % 2 == 0) ? i / 2 : (n - 1) / 2 + 1 + (i - 1) / 2;
  endfunction

  // ------------------------------------------------------------ the image
  integer blocks;                                // 1600 or 800
  function [7:0] dbyte(input integer n, input integer i);
    integer c, s, k, r;
    begin
      // invert block -> (c, s, k) for this image's sidedness
      c = 0; while (c < 79 && (img_ds ? 2 : 1) * secs_before(c + 1) <= n) c = c + 1;
      r = n - (img_ds ? 2 : 1) * secs_before(c);
      s = r / spt(c); k = r % spt(c);
      case (i)
        0: dbyte = c; 1: dbyte = s; 2: dbyte = k;
        default: dbyte = (n * 7 + i * 13 + (i >> 5)) & 8'hFF;
      endcase
    end
  endfunction
  function [7:0] tbyte(input integer n, input integer j);
    tbyte = img_tags ? ((n * 5 + j * 31 + 1) & 8'hFF) : 8'h00;
  endfunction

  reg [15:0] mem [0:2880*256 - 1];               // the larger of 1600 x 262 (GCR) and 2880 x 256 (1.44 MB)
  reg  [7:0] exp_sec [0:1599*524 + 523];         // the 524 bytes each block should decode to
  reg  [7:0] mem8 [0:1474559];                   // MacPlus's and MacLC's view: the data, bytes
  task build_image;
    integer n, i, j;
    reg [7:0] d [0:511];
    begin
      blocks = img_ds ? 1600 : 800;
      for (n = 0; n < blocks; n = n + 1) begin
        for (i = 0; i < 512; i = i + 1) begin
          d[i] = (i < 3) ? dbyte(n, i) : ((n * 7 + i * 13 + (i >> 5)) & 8'hFF);
          mem8[n * 512 + i] = d[i];
          exp_sec[n * 524 + 12 + i] = d[i];
        end
        for (i = 0; i < 256; i = i + 1) mem[n * 256 + i] = {d[2 * i], d[2 * i + 1]};
        for (j = 0; j < 12; j = j + 1) exp_sec[n * 524 + j] = tbyte(n, j);
        for (j = 0; j < 6; j = j + 1)
          mem[blocks * 256 + n * 6 + j] = img_tags ? {tbyte(n, 2 * j), tbyte(n, 2 * j + 1)} : 16'hDEAD;
      end
    end
  endtask

  // ------------------------------------------------------------ the memory
  integer lat = 0, torn = 0, moved = 0, early = 0, reqs = 0;
  reg     req_d = 0, ack_hold = 0;
  reg [23:0] addr_d;
  integer hold = 0;
  always @(posedge clk) begin
    req_d <= mem_req; addr_d <= mem_addr;
    if (req_d && !mem_req && !mem_ack) torn <= torn + 1;          // dropped before the acknowledge
    if (req_d && mem_req && !mem_ack && mem_addr != addr_d) moved <= moved + 1;
    if (mem_req && !req_d && mem_ack) early <= early + 1;         // raised over a stale acknowledge
    if (mem_req && !mem_ack) begin
      if (lat == 0) lat <= 3 + (cyc % 10);
      else if (lat == 1) begin
        mem_ack <= 1; lat <= 0; reqs <= reqs + 1;
        mem_rdata <= (mem_addr >= BASE && mem_addr - BASE < 2880*256) ? mem[mem_addr - BASE] : 16'hBAD0;
      end else lat <= lat - 1;
    end
    if (mem_ack && !mem_req) begin
      if (hold == 1) begin mem_ack <= 0; hold <= 0; end
      else if (hold == 0) hold <= 2;
      else hold <= hold - 1;
    end
  end

  // ------------------------------------------------------------ reading a track out
  reg rev0 [0:74557];
  reg rev1 [0:74557];
  task wait_valid(input integer c, output integer took);
    integer t0;
    begin
      t0 = cyc;
      @(posedge clk);
      while (!(trk_valid && trk_cyl == c) && cyc - t0 < 3000000) @(posedge clk);
      took = cyc - t0;
    end
  endtask
  // one revolution of each side through the read port (a clock of latency)
  task read_track(input integer c);
    integer a, n;
    begin
      n = cells(c);
      for (a = 0; a < n; a = a + 1) begin
        #1 trk_addr = a; trk_side = 0;
        @(posedge clk); #1 rev0[a] = trk_bit;          // registered on this edge
      end
      for (a = 0; a < n; a = a + 1) begin
        #1 trk_addr = a; trk_side = 1;
        @(posedge clk); #1 rev1[a] = trk_bit;
      end
    end
  endtask

  // ------------------------------------------------------------ the reference decoder
  reg  [7:0] gcr [0:63];
  integer    inv [0:255];
  // the ERS's codeword table (sheet 42), typed from the page image
  localparam [511:0] GCR_T = {
    8'h96,8'h97,8'h9A,8'h9B,8'h9D,8'h9E,8'h9F,8'hA6, 8'hA7,8'hAB,8'hAC,8'hAD,8'hAE,8'hAF,8'hB2,8'hB3,
    8'hB4,8'hB5,8'hB6,8'hB7,8'hB9,8'hBA,8'hBB,8'hBC, 8'hBD,8'hBE,8'hBF,8'hCB,8'hCD,8'hCE,8'hCF,8'hD3,
    8'hD6,8'hD7,8'hD9,8'hDA,8'hDB,8'hDC,8'hDD,8'hDE, 8'hDF,8'hE5,8'hE6,8'hE7,8'hE9,8'hEA,8'hEB,8'hEC,
    8'hED,8'hEE,8'hEF,8'hF2,8'hF3,8'hF4,8'hF5,8'hF6, 8'hF7,8'hF9,8'hFA,8'hFB,8'hFC,8'hFD,8'hFE,8'hFF};
  initial begin : tables
    integer i;
    for (i = 0; i < 256; i = i + 1) inv[i] = -1;
    for (i = 0; i < 64; i = i + 1) begin gcr[i] = GCR_T[511 - 8 * i -: 8]; inv[gcr[i]] = i; end
  end

  // the IWM's framing over one revolution: bytes, and where each began
  reg  [7:0] bb [0:9400];
  integer    bpos [0:9400];
  integer    nb;
  task frame(input integer side, input integer n);
    integer i, st;
    reg [7:0] sr;
    reg b;
    begin
      nb = 0; sr = 0; st = 0;
      for (i = 0; i < n; i = i + 1) begin
        b = side ? rev1[i] : rev0[i];
        if (sr == 0 && !b) ;                       // leading zeros are dropped
        else begin
          if (sr == 0) st = i;
          sr = {sr[6:0], b};
          if (sr[7]) begin bb[nb] = sr; bpos[nb] = st; nb = nb + 1; sr = 0; end
        end
      end
    end
  endtask

  // decode every sector in bb[]: counts, and what was found
  integer found, good_hdr, good_data, bad_hdr, bad_data, fmt_seen, order_ok, sync_min, first_mark;
  integer seq [0:11];
  reg [7:0] out [0:523];
  task decode(input integer c, input integer s, input integer check_data);
    integer p, q, k, g, t, sc, sd, f, ck, n1, ap, bp, cp, blk, i, mism, nsync;
    reg [7:0] ca, cb, cc, A, B, C;
    reg [8:0] sum;
    reg carry, c1, c2;
    begin
      found = 0; good_hdr = 0; good_data = 0; bad_hdr = 0; bad_data = 0; fmt_seen = -1;
      order_ok = 1; sync_min = 999; first_mark = -1;
      p = 0;
      while (p + 2 < nb) begin
        if (bb[p] == 8'hD5 && bb[p+1] == 8'hAA && bb[p+2] == 8'h96) begin
          if (first_mark < 0) first_mark = bpos[p];
          // the sync before it: plain FF bytes as the IWM frames a chunk
          // run (FF FF FF FF FF per chunk: its four groups and the FF)
          nsync = 0; q = p - 1; while (q >= 0 && bb[q] == 8'hFF) begin nsync = nsync + 1; q = q - 1; end
          if (found > 0 && nsync < sync_min) sync_min = nsync;
          t = inv[bb[p+3]]; sc = inv[bb[p+4]]; sd = inv[bb[p+5]]; f = inv[bb[p+6]]; ck = inv[bb[p+7]];
          if (t < 0 || sc < 0 || sd < 0 || f < 0 || ck < 0 || ck != (t ^ sc ^ sd ^ f) ||
              bb[p+8] != 8'hDE || bb[p+9] != 8'hAA || t != (c & 63) || sd != ((s << 5) | (c >> 6))) begin
            bad_hdr = bad_hdr + 1; p = p + 3;
          end else begin
            good_hdr = good_hdr + 1; fmt_seen = f;
            if (found < 12) seq[found] = sc;
            if (sc != il(spt(c), found)) order_ok = 0;
            found = found + 1;
            // the data field within the next 20 bytes
            q = p + 10;
            while (q < p + 30 && !(bb[q] == 8'hD5 && bb[q+1] == 8'hAA && bb[q+2] == 8'hAD)) q = q + 1;
            if (q >= p + 30 || inv[bb[q+3]] != sc) bad_data = bad_data + 1;
            else begin
              ca = 0; cb = 0; cc = 0; k = q + 4; i = 0;
              for (g = 0; g < 175; g = g + 1) begin
                n1 = inv[bb[k]]; ap = inv[bb[k+1]]; bp = inv[bb[k+2]];
                cp = (g < 174) ? inv[bb[k+3]] : 0;
                if (n1 < 0 || ap < 0 || bp < 0 || cp < 0) begin n1 = 0; ap = 0; bp = 0; cp = 0; ca = ca ^ 8'h55; end
                carry = cc[7]; cc = {cc[6:0], cc[7]};
                A = {n1[5:4], ap[5:0]} ^ cc; sum = ca + A + carry; ca = sum[7:0]; c1 = sum[8];
                B = {n1[3:2], bp[5:0]} ^ ca; sum = cb + B + c1;    cb = sum[7:0]; c2 = sum[8];
                out[i] = A; out[i+1] = B; i = i + 2;
                if (g < 174) begin
                  C = {n1[1:0], cp[5:0]} ^ cb; sum = cc + C + c2; cc = sum[7:0];
                  out[i] = C; i = i + 1; k = k + 4;
                end else k = k + 3;
              end
              n1 = inv[bb[k]]; ap = inv[bb[k+1]]; bp = inv[bb[k+2]]; cp = inv[bb[k+3]];
              if (n1 < 0 || ap < 0 || bp < 0 || cp < 0 ||
                  {n1[5:4], ap[5:0]} != ca || {n1[3:2], bp[5:0]} != cb ||
                  {n1[1:0], cp[5:0]} != cc || bb[k+4] != 8'hDE || bb[k+5] != 8'hAA)
                bad_data = bad_data + 1;
              else if (check_data) begin
                blk = (img_ds ? 2 : 1) * secs_before(c) + s * spt(c) + sc;
                mism = 0;
                for (i = 0; i < 524; i = i + 1) if (out[i] !== exp_sec[blk * 524 + i]) mism = mism + 1;
                if (mism == 0) good_data = good_data + 1; else bad_data = bad_data + 1;
              end else good_data = good_data + 1;
            end
            p = p + 10;
          end
        end else p = p + 1;
      end
    end
  endtask

  // ------------------------------------------------------------ the layout, bit for bit
  // every cell outside the 703 data-field codes against the formatter's
  // track (5.12.5b): the leftover's groups ending 00, then per sector
  // 8 x FF 3F CF F3 FC FF, D5 AA 96, the five, DE AA FF, a chunk, D5 AA AD,
  // the sector, [the codes], DE AA FF FF
  integer lay_bad;
  function [7:0] chunkb(input integer i);
    case (i % 6) 1: chunkb = 8'h3F; 2: chunkb = 8'hCF; 3: chunkb = 8'hF3; 4: chunkb = 8'hFC; default: chunkb = 8'hFF; endcase
  endfunction
  task layout(input integer c, input integer s);
    integer L, n, i, b, bit_i, sl, sc, jj, t, sd, f;
    reg [7:0] v;
    reg e, got;
    begin
      L = leftover(c); n = spt(c); lay_bad = 0;
      for (i = 0; i < L; i = i + 1) begin
        e = ((L - 1 - i) % 10) >= 2;
        got = s ? rev1[i] : rev0[i];
        if (got !== e) lay_bad = lay_bad + 1;
      end
      for (sl = 0; sl < n; sl = sl + 1) begin
        sc = il(n, sl); t = c & 63; sd = (s << 5) | (c >> 6); f = img_ds ? 8'h22 : 8'h02;
        for (jj = 0; jj < 776; jj = jj + 1) begin
          if (jj < 48) v = chunkb(jj);
          else if (jj < 59)
            case (jj - 48)
              0: v = 8'hD5; 1: v = 8'hAA; 2: v = 8'h96; 3: v = gcr[t]; 4: v = gcr[sc]; 5: v = gcr[sd];
              6: v = gcr[f]; 7: v = gcr[t ^ sc ^ sd ^ f]; 8: v = 8'hDE; 9: v = 8'hAA; default: v = 8'hFF;
            endcase
          else if (jj < 65) v = chunkb(jj - 59);
          else if (jj == 65) v = 8'hD5; else if (jj == 66) v = 8'hAA; else if (jj == 67) v = 8'hAD;
          else if (jj == 68) v = gcr[sc];
          else if (jj < 772) v = 8'hxx;
          else if (jj == 772) v = 8'hDE; else if (jj == 773) v = 8'hAA; else v = 8'hFF;
          if (jj < 69 || jj >= 772)
            for (b = 0; b < 8; b = b + 1) begin
              bit_i = L + sl * 6208 + jj * 8 + b;
              got = s ? rev1[bit_i] : rev0[bit_i];
              if (got !== v[7 - b]) lay_bad = lay_bad + 1;
            end
        end
      end
    end
  endtask

  // ------------------------------------------------------------ MacPlus's encoder
  reg        mp_ready = 0, mp_rst = 1, mp_side = 0;
  reg  [6:0] mp_track = 0;
  wire [21:0] mp_addr;
  wire [7:0] mp_odata;
  wire [7:0] mp_idata = mem8[mp_addr];
  floppy_track_encoder mp (
    .clk(clk), .ready(mp_ready), .rst(mp_rst),
    .side(mp_side), .sides(1'b1), .track(mp_track),
    .addr(mp_addr), .idata(mp_idata), .odata(mp_odata),
    .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0));
  reg [7:0] mpb [0:19999];
  task run_macplus(input integer c, input integer s);
    integer i;
    begin
      mp_track = c; mp_side = s; mp_rst = 1;
      @(posedge clk); @(negedge clk); mp_rst = 0; #1;
      // ready changes on the falling edge: set on the rising edge the
      // encoder samples, it raced the encoder's own always blocks and the
      // stream read some image bytes twice (plan 5.12.7, the benches)
      for (i = 0; i < 20000; i = i + 1) begin
        mpb[i] = mp_odata;
        repeat (7) @(posedge clk);
        @(negedge clk) mp_ready = 1;
        @(negedge clk) mp_ready = 0;
      end
    end
  endtask
  // the address field and the data field's 704 codes of sector sc, from
  // our framed bytes and from MacPlus's stream: equal?
  integer mp_mism;
  task compare_sector(input integer sc);
    integer p, q, r, m, i;
    begin
      p = 0; while (p + 4 < nb && !(bb[p] == 8'hD5 && bb[p+1] == 8'hAA && bb[p+2] == 8'h96 && inv[bb[p+4]] == sc)) p = p + 1;
      r = 0; while (r + 4 < 20000 && !(mpb[r] == 8'hD5 && mpb[r+1] == 8'hAA && mpb[r+2] == 8'h96 && inv[mpb[r+4]] == sc)) r = r + 1;
      if (p + 4 >= nb || r + 4 >= 20000) mp_mism = mp_mism + 1000;
      else begin
        for (i = 0; i < 10; i = i + 1) if (bb[p+i] != mpb[r+i]) mp_mism = mp_mism + 1;
        q = p + 10; while (!(bb[q] == 8'hD5 && bb[q+1] == 8'hAA && bb[q+2] == 8'hAD)) q = q + 1;
        m = r + 10; while (!(mpb[m] == 8'hD5 && mpb[m+1] == 8'hAA && mpb[m+2] == 8'hAD)) m = m + 1;
        for (i = 0; i < 3 + 1 + 703 + 2; i = i + 1) if (bb[q+i] != mpb[m+i]) mp_mism = mp_mism + 1;
      end
    end
  endtask

  // ------------------------------------------------------------ MFM (plan 5.13)
  integer mspt, mcells, mgap3;                   // 18, 200,000, 108 (1.44 MB); 9, 100,000, 80 (720K)
  task mfm_geometry(input hd);
    begin mspt = hd ? 18 : 9; mcells = hd ? 200000 : 100000; mgap3 = hd ? 108 : 80; end
  endtask
  // block n's data byte i: bytes 0-2 its cylinder, side and sector (1-based)
  function [7:0] mdbyte(input integer n, input integer i);
    case (i)
      0: mdbyte = n / (2 * mspt); 1: mdbyte = (n / mspt) % 2; 2: mdbyte = n % mspt + 1;
      default: mdbyte = (n * 7 + i * 13 + (i >> 5)) & 8'hFF;
    endcase
  endfunction
  task build_mfm_image;
    integer n, i;
    begin
      for (n = 0; n < 160 * mspt; n = n + 1)
        for (i = 0; i < 512; i = i + 1) mem8[n * 512 + i] = mdbyte(n, i);
      for (n = 0; n < 160 * mspt * 256; n = n + 1) mem[n] = {mem8[2 * n], mem8[2 * n + 1]};
    end
  endtask

  // the User's Reference's CRC (p. 9) as its pseudo-code reads: xorBit =
  // CRC15 ^ DATA7, CRC4 and CRC11 ^= xorBit, rotate left with xorBit into
  // CRC0; all ones to begin
  function [15:0] ucrc(input [15:0] cin, input [7:0] d);
    integer b;
    reg [15:0] r;
    reg  [7:0] dd;
    reg        x;
    begin
      r = cin; dd = d;
      for (b = 0; b < 8; b = b + 1) begin
        x = r[15] ^ dd[7];
        r[4] = r[4] ^ x; r[11] = r[11] ^ x;
        r = {r[14:0], x};
        dd = {dd[6:0], 1'b0};
      end
      ucrc = r;
    end
  endfunction

  // a byte's 16 cells, the clock cell first (the User's Reference p. 7: a
  // data 1 a transition in its cell, a clock transition between two 0s; a
  // mark byte drops "the middle clock pulse in a run of four zeroes" - the
  // TSM's "1000", the clock before the last zero, p. 18); p0 the last bit
  function [15:0] menc(input [7:0] v, input mark, input p0);
    integer b;
    reg p, d, ck;
    reg [3:0] h;
    begin
      p = p0; h = {3'b000, p0};
      for (b = 7; b >= 0; b = b - 1) begin
        d = v[b];
        ck = !p && !d;
        h = {h[2:0], d};
        if (mark && h == 4'b1000) ck = 1'b0;
        menc[2 * b + 1] = ck; menc[2 * b] = d;
        p = d;
      end
    end
  endfunction

  // the formatter's side ($4082EC5E): 32 x 4E from the index, then per
  // sector R = 1.. (1:1) 12 x 00, A1 A1 A1 (marks) FE C H R 02 CRC, 22 x
  // 4E, 12 x 00, A1 A1 A1 FB, the 512 bytes, CRC, gap 3; 4E to the end
  reg  [7:0] xb [0:12499];
  reg        xm [0:12499];
  integer    xn;
  task mfm_expect(input integer c, input integer s);
    integer k, r, i, n;
    reg [15:0] cr;
    begin
      xn = mcells / 16;
      for (i = 0; i < xn; i = i + 1) begin xb[i] = 8'h4E; xm[i] = 0; end
      k = 32;
      for (r = 1; r <= mspt; r = r + 1) begin
        n = (2 * c + s) * mspt + r - 1;
        for (i = 0; i < 12; i = i + 1) begin xb[k] = 8'h00; k = k + 1; end
        cr = 16'hFFFF;
        for (i = 0; i < 3; i = i + 1) begin xb[k] = 8'hA1; xm[k] = 1; cr = ucrc(cr, 8'hA1); k = k + 1; end
        xb[k] = 8'hFE; cr = ucrc(cr, xb[k]); k = k + 1;
        xb[k] = c;     cr = ucrc(cr, xb[k]); k = k + 1;
        xb[k] = s;     cr = ucrc(cr, xb[k]); k = k + 1;
        xb[k] = r;     cr = ucrc(cr, xb[k]); k = k + 1;
        xb[k] = 8'h02; cr = ucrc(cr, xb[k]); k = k + 1;
        xb[k] = cr[15:8]; xb[k + 1] = cr[7:0]; k = k + 2;
        k = k + 22;
        for (i = 0; i < 12; i = i + 1) begin xb[k] = 8'h00; k = k + 1; end
        cr = 16'hFFFF;
        for (i = 0; i < 3; i = i + 1) begin xb[k] = 8'hA1; xm[k] = 1; cr = ucrc(cr, 8'hA1); k = k + 1; end
        xb[k] = 8'hFB; cr = ucrc(cr, xb[k]); k = k + 1;
        for (i = 0; i < 512; i = i + 1) begin xb[k] = mem8[n * 512 + i]; cr = ucrc(cr, xb[k]); k = k + 1; end
        xb[k] = cr[15:8]; xb[k + 1] = cr[7:0]; k = k + 2;
        k = k + mgap3;
      end
    end
  endtask

  // a side's cells: the buffer itself, or through the drive's port
  reg mrev [0:199999];
  task mfm_peek(input integer s);
    integer a;
    for (a = 0; a < mcells; a = a + 1) mrev[a] = dut.tbuf[s ? 200000 + a : a];
  endtask
  task mfm_port(input integer s, output integer diff);
    integer a;
    begin
      diff = 0;
      for (a = 0; a < mcells; a = a + 1) begin
        #1 trk_addr = a; trk_side = s;
        @(posedge clk); #1 mrev[a] = trk_bit;
        if (trk_bit !== dut.tbuf[s ? 200000 + a : a]) diff = diff + 1;
      end
    end
  endtask

  // every cell against the formatter's side, encoded by menc
  task mfm_layout(output integer bad);
    integer k, b;
    reg p;
    reg [15:0] w;
    begin
      bad = 0; p = 0;
      for (k = 0; k < xn; k = k + 1) begin
        w = menc(xb[k], xm[k], p); p = xb[k][0];
        for (b = 0; b < 16; b = b + 1) if (mrev[16 * k + b] !== w[15 - b]) bad = bad + 1;
      end
    end
  endtask

  // the reference decoder
  reg [15:0] mark_cells;                         // menc(A1, mark): what a mark's cells are
  function [7:0] mdata(input integer pos);       // the byte whose cells begin at pos: its data cells
    integer b;
    for (b = 0; b < 8; b = b + 1) mdata[7 - b] = (pos + 2 * b + 1 < mcells) ? mrev[pos + 2 * b + 1] : 1'b0;
  endfunction
  integer mkp [0:199];                           // every mark's first cell
  integer id_pos [0:17], da_pos [0:17];          // sector R's address and data marks
  integer m_illegal, m_marks, m_stray, m_ids, m_hdr_ok, m_data_ok, m_order_bad;
  integer m_gap1, m_gap2_bad, m_gap3_bad, m_tail, m_tail_bad, cur_r;
  task mfm_decode(input integer c, input integer s);
    integer i, f1, run, k, p, r, n, nm, nid, mism, last_end;
    reg [15:0] w, cr;
    reg  [7:0] v;
    begin
      // MFM's rule: transitions 2, 3 or 4 cells apart, around the wrap too
      m_illegal = 0;
      f1 = 0; while (f1 < mcells && mrev[f1] !== 1'b1) f1 = f1 + 1;
      run = 0;
      for (i = 1; i <= mcells; i = i + 1) begin
        run = run + 1;
        if (mrev[(f1 + i) % mcells] === 1'b1) begin
          if (run < 2 || run > 4) m_illegal = m_illegal + 1;
          run = 0;
        end
      end
      // the marks, looked for at every cell
      nm = 0; w = 0;
      for (i = 0; i < mcells; i = i + 1) begin
        w = {w[14:0], mrev[i] === 1'b1};
        if (i >= 15 && w == mark_cells) begin if (nm < 200) mkp[nm] = i - 15; nm = nm + 1; end
      end
      m_marks = nm;
      // the fields: three marks, then FE (an address field) or FB (data)
      m_ids = 0; m_hdr_ok = 0; m_data_ok = 0; m_order_bad = 0; m_stray = 0;
      m_gap2_bad = 0; m_gap3_bad = 0; m_tail_bad = 0; m_tail = 0;
      for (r = 0; r < 18; r = r + 1) begin id_pos[r] = -1; da_pos[r] = -1; end
      nid = 0; cur_r = -1; i = 0;
      while (i < nm && i < 200) begin
        if (i + 2 < nm && mkp[i + 1] == mkp[i] + 16 && mkp[i + 2] == mkp[i] + 32) begin
          p = mkp[i] + 48; v = mdata(p);
          cr = ucrc(ucrc(ucrc(16'hFFFF, 8'hA1), 8'hA1), 8'hA1);
          if (v == 8'hFE) begin
            m_ids = m_ids + 1;
            for (k = 0; k < 7; k = k + 1) cr = ucrc(cr, mdata(p + 16 * k));   // FE C H R N, the CRC
            r = mdata(p + 48); cur_r = -1;
            if (cr == 0 && mdata(p + 16) == c && mdata(p + 32) == s && mdata(p + 64) == 8'h02 && r >= 1 && r <= mspt) begin
              m_hdr_ok = m_hdr_ok + 1; id_pos[r - 1] = mkp[i]; cur_r = r;
              if (r != nid + 1) m_order_bad = m_order_bad + 1;
              nid = r;
              // gap 2: 22 x 4E and 12 x 00 to the data field's marks
              for (k = 10; k < 44; k = k + 1) if (mdata(mkp[i] + 16 * k) != (k < 32 ? 8'h4E : 8'h00)) m_gap2_bad = m_gap2_bad + 1;
            end
          end else if (v == 8'hFB) begin
            // the data field belongs to the address field just read, if it is near
            for (k = 0; k < 515; k = k + 1) cr = ucrc(cr, mdata(p + 16 * k));  // FB, 512, the CRC
            if (cur_r > 0 && mkp[i] - id_pos[cur_r - 1] < 16 * 60 && cr == 0) begin
              n = (2 * c + s) * mspt + cur_r - 1; mism = 0;
              for (k = 0; k < 512; k = k + 1) if (mdata(p + 16 + 16 * k) != mem8[n * 512 + k]) mism = mism + 1;
              if (mism == 0) begin m_data_ok = m_data_ok + 1; da_pos[cur_r - 1] = mkp[i]; end
            end
            cur_r = -1;
          end else m_stray = m_stray + 3;
          i = i + 3;
        end else begin m_stray = m_stray + 1; i = i + 1; end
      end
      // gap 1, gap 3, the tail (4E to the index)
      m_gap1 = id_pos[0];
      for (k = 0; k < 32; k = k + 1) if (mdata(16 * k) != 8'h4E) m_gap2_bad = m_gap2_bad + 1;
      for (r = 0; r + 1 < mspt; r = r + 1)
        if (da_pos[r] < 0 || id_pos[r + 1] < 0) m_gap3_bad = m_gap3_bad + 1;
        else begin
          last_end = da_pos[r] + 16 * 518;
          if ((id_pos[r + 1] - last_end) / 16 - 12 != mgap3) m_gap3_bad = m_gap3_bad + 1;
          for (k = last_end; k < id_pos[r + 1] - 16 * 12; k = k + 16) if (mdata(k) != 8'h4E) m_gap3_bad = m_gap3_bad + 1;
        end
      if (da_pos[mspt - 1] >= 0) begin
        last_end = da_pos[mspt - 1] + 16 * 518;
        m_tail = (mcells - last_end) / 16;
        for (k = last_end; k < mcells; k = k + 16) if (mdata(k) != 8'h4E) m_tail_bad = m_tail_bad + 1;
      end else m_tail_bad = 1;
    end
  endtask

  // ------------------------------------------------------------ MacLC's MFM encoder
  reg        lc_ready = 0, lc_rst = 1, lc_side = 0, lc_hd = 1;
  reg  [6:0] lc_track = 0;
  wire [21:0] lc_addr;
  wire  [7:0] lc_odata;
  wire        lc_omark;
  wire  [7:0] lc_idata = mem8[lc_addr];
  mfm_track_encoder lc (
    .clk(clk), .ready(lc_ready), .rst(lc_rst), .side(lc_side), .track(lc_track), .hd(lc_hd),
    .addr(lc_addr), .idata(lc_idata), .odata(lc_odata), .omark(lc_omark),
    .ocrc0(), .oneeds(), .oindex(), .osector());
  reg  [7:0] lcb [0:12499];
  reg        lcm [0:12499];
  integer    lcn, lc_mism = 0, lc_secs = 0;
  task run_lc(input integer c, input integer s);
    integer i;
    begin
      lc_track = c; lc_side = s; lc_hd = (mspt == 18); lc_rst = 1;
      @(posedge clk); @(negedge clk) lc_rst = 0; #1;
      lcn = 146 + mspt * 682;                    // its track: an index field, gap 3 of 108
      for (i = 0; i < lcn; i = i + 1) begin
        lcb[i] = lc_odata; lcm[i] = lc_omark;
        @(negedge clk) lc_ready = 1;
        @(negedge clk) lc_ready = 0; #1;
      end
    end
  endtask
  // the side just decoded (mrev, id_pos, da_pos) against MacLC's stream
  task lc_compare(input integer c, input integer s);
    integer r, p, q, i;
    begin
      run_lc(c, s);
      for (r = 1; r <= mspt; r = r + 1) begin
        lc_secs = lc_secs + 1;
        p = 0;
        while (p + 9 < lcn && !(lcm[p] && lcm[p + 1] && lcm[p + 2] && lcb[p] == 8'hA1 && lcb[p + 3] == 8'hFE && lcb[p + 6] == r)) p = p + 1;
        if (p + 9 >= lcn || id_pos[r - 1] < 0 || da_pos[r - 1] < 0) lc_mism = lc_mism + 1000;
        else begin
          for (i = 0; i < 10; i = i + 1)
            if (lcb[p + i] != mdata(id_pos[r - 1] + 16 * i) || lcm[p + i] != (i < 3)) lc_mism = lc_mism + 1;
          q = p + 10; while (q + 3 < lcn && !(lcm[q] && lcb[q + 3] == 8'hFB)) q = q + 1;
          for (i = 0; i < 518; i = i + 1)
            if (lcb[q + i] != mdata(da_pos[r - 1] + 16 * i) || lcm[q + i] != (i < 3)) lc_mism = lc_mism + 1;
        end
      end
    end
  endtask

  // ------------------------------------------------------------ the run
  integer c, s, took, maxtook, all_good, all_hdr, all_found, bad_order, bad_fmt, bad_sync, bad_lead, bad_layout;
  integer side1_bytes, a, i, k, nsec;
  integer m_all_ids, m_all_hdr, m_all_data, m_bad_rule, m_bad_marks, m_bad_order, m_bad_gaps, m_bad_layout, port_diff;
  reg [15:0] crc0;
  // a side of an MFM disk through the reference decoder, its layout, and
  // (port) the drive's port; the sums for the checks
  task mfm_side(input integer c, input integer s, input port, input lc);
    integer d;
    begin
      if (port) begin mfm_port(s, d); port_diff = port_diff + d; end else mfm_peek(s);
      mfm_decode(c, s);
      m_all_ids = m_all_ids + m_ids; m_all_hdr = m_all_hdr + m_hdr_ok; m_all_data = m_all_data + m_data_ok;
      if (m_illegal != 0) m_bad_rule = m_bad_rule + 1;
      if (m_marks != 6 * mspt || m_stray != 0) m_bad_marks = m_bad_marks + 1;
      if (m_order_bad != 0) m_bad_order = m_bad_order + 1;
      if (m_gap1 != 16 * 44 || m_gap2_bad != 0 || m_gap3_bad != 0 || m_tail_bad != 0) m_bad_gaps = m_bad_gaps + 1;
      mfm_expect(c, s); mfm_layout(d); if (d != 0) m_bad_layout = m_bad_layout + 1;
      if (lc) lc_compare(c, s);
    end
  endtask
  task mfm_sums_clear;
    begin
      m_all_ids = 0; m_all_hdr = 0; m_all_data = 0; m_bad_rule = 0; m_bad_marks = 0; m_bad_order = 0;
      m_bad_gaps = 0; m_bad_layout = 0; port_diff = 0; maxtook = 0;
    end
  endtask

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;

    if (!$test$plusargs("MFM_ONLY")) begin
    // ---- 1 and 2: the whole double-sided disk with tags
    $display("---- 1. every cylinder, both sides, tags: one revolution each, the reference decoder");
    img_ds = 1; img_tags = 1; build_image;
    #1 disk_in = 1;
    all_good = 0; all_hdr = 0; all_found = 0; bad_order = 0; bad_fmt = 0; bad_sync = 0; bad_lead = 0; bad_layout = 0; maxtook = 0;
    for (c = 0; c < 80; c = c + 1) begin
      #1 cyl = c;
      wait_valid(c, took); if (took > maxtook) maxtook = took;
      read_track(c);
      for (s = 0; s < 2; s = s + 1) begin
        frame(s, cells(c));
        decode(c, s, 1);
        all_good = all_good + good_data; all_hdr = all_hdr + good_hdr; all_found = all_found + found;
        if (!order_ok || found != spt(c)) bad_order = bad_order + 1;
        if (fmt_seen != 8'h22) bad_fmt = bad_fmt + 1;
        if (sync_min < 8 * 5) bad_sync = bad_sync + 1;       // eight chunks frame as 5 FFs each
        if (first_mark < leftover(c) + 8 * 48) bad_lead = bad_lead + 1;
        layout(c, s); if (lay_bad != 0) bad_layout = bad_layout + 1;
        if (c == 0 && s == 0) $display("     cylinder 0 side 0: sectors in track order %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d, first mark at cell %0d",
                                       seq[0], seq[1], seq[2], seq[3], seq[4], seq[5], seq[6], seq[7], seq[8], seq[9], seq[10], seq[11], first_mark);
      end
    end
    check(all_found == 1600, "address fields found, one revolution a side", all_found, 1600);
    check(all_hdr == 1600, "  their track, side and checksum right", all_hdr, 1600);
    check(all_good == 1600, "sectors recovered byte for byte, tags and data", all_good, 1600);
    check(bad_order == 0, "every track in the formatter's 2:1 order ($408321CA)", bad_order, 0);
    check(bad_fmt == 0, "format $22 on every double-sided track", bad_fmt, 0);
    check(bad_sync == 0, "eight sync chunks before every address mark", bad_sync, 0);
    check(bad_lead == 0, "the leftover and eight chunks before the first mark", bad_lead, 0);
    check(bad_layout == 0, "every cell outside the codes is the formatter's, all 160 sides", bad_layout, 0);
    $display("     longest build: %0d clocks (%0d us at clk_sys)", maxtook, maxtook * 32 / 1000);
    check(maxtook < 1128038, "each cylinder built inside the drive's 36 ms settle", maxtook, 1128038);

    $display("---- 2. the disk port's handshake");
    check(torn == 0, "no request dropped before its acknowledge", torn, 0);
    check(moved == 0, "no address moved under a pending request", moved, 0);
    check(early == 0, "no request raised over the last acknowledge", early, 0);
    check(reqs > 0, "(requests made)", reqs, 1);

    // ---- 7. restarts, validity, disk out
    $display("---- 7. a new cylinder mid-build, validity, disk out");
    #1 cyl = 20;
    repeat (2000) @(posedge clk);
    check(!(trk_valid && trk_cyl == 20), "not valid for cylinder 20 mid-build", trk_valid, 0);
    // the next change lands on a request's first clock: the memory takes
    // at least three to answer, so an encoder that abandoned the build
    // now would tear the request down unanswered
    @(posedge clk); #1;
    while (!(mem_req && !req_d)) begin @(posedge clk); #1; end
    cyl = 45;
    wait_valid(45, took);
    check(trk_valid && trk_cyl == 45, "the build restarted and finished for cylinder 45", trk_cyl, 45);
    read_track(45); frame(0, cells(45)); decode(45, 0, 1);
    check(good_data == 10, "  and it holds cylinder 45's ten sectors", good_data, 10);
    #1 disk_in = 0; repeat (4) @(posedge clk);
    check(!trk_valid, "the disk out: not valid", trk_valid, 0);
    check(torn == 0 && moved == 0 && early == 0, "the handshake still clean after the restarts", torn + moved + early, 0);

    // ---- 3. single-sided
    $display("---- 3. a single-sided (400K) image");
    img_ds = 0; img_tags = 1; build_image;
    #1 cyl = 0; disk_in = 1;
    all_good = 0; bad_fmt = 0; side1_bytes = 0; nsec = 0;
    for (k = 0; k < 5; k = k + 1) begin
      c = k * 16 + 7;
      #1 cyl = c; wait_valid(c, took); read_track(c);
      frame(0, cells(c)); decode(c, 0, 1);
      all_good = all_good + good_data; nsec = nsec + spt(c);
      if (fmt_seen != 8'h02) bad_fmt = bad_fmt + 1;
      frame(1, cells(c)); side1_bytes = side1_bytes + nb;
    end
    check(all_good == nsec, "side 0 recovered on a track of each group", all_good, nsec);
    check(bad_fmt == 0, "format $02", bad_fmt, 0);
    check(side1_bytes == 0, "side 1: no flux, no bytes", side1_bytes, 0);

    // ---- 4. no tags
    $display("---- 4. an image without tags");
    #1 disk_in = 0; img_ds = 1; img_tags = 0; build_image;
    repeat (4) @(posedge clk); #1 cyl = 3; disk_in = 1;
    wait_valid(3, took); read_track(3);
    frame(1, cells(3)); decode(3, 1, 1);
    check(good_data == 12, "the tag bytes decode as zeros (and the data)", good_data, 12);

    // ---- 5. MacPlus's encoder, a second opinion
    $display("---- 5. MacPlus's floppy_track_encoder.v on the same image");
    mp_mism = 0; nsec = 0;
    for (k = 0; k < 6; k = k + 1) begin
      c = (k < 5) ? k * 16 + 5 : 79;
      #1 cyl = c; wait_valid(c, took); read_track(c);
      for (s = 0; s < 2; s = s + 1) begin
        run_macplus(c, s);
        frame(s, cells(c));
        took = mp_mism;
        for (i = 0; i < spt(c); i = i + 1) begin compare_sector(i); nsec = nsec + 1; end
        $display("     cylinder %0d side %0d: %0d sectors, %0d bytes differ", c, s, spt(c), mp_mism - took);
      end
    end
    $display("     %0d sectors compared", nsec);
    check(mp_mism == 0, "address fields and data-field codes identical to MacPlus's", mp_mism, 0);

    // ---- 6. negative cases
    $display("---- 6. negative cases, one revolution only");
    #1 cyl = 10; wait_valid(10, took); read_track(10);
    frame(0, cells(10)); decode(10, 0, 1);
    check(good_data == 12 && bad_data == 0, "(cylinder 10 side 0 clean)", good_data, 12);
    // a bit inside the fourth sector's data field: its cell is well past its mark
    k = leftover(10) + 3 * 6208 + 384 + 88 + 48 + 32 + 2000;
    rev0[k] = !rev0[k];
    frame(0, cells(10)); decode(10, 0, 1);
    check(good_data == 11 && bad_data == 1, "a flipped data bit fails that sector alone", bad_data, 1);
    rev0[k] = !rev0[k];
    // a bit inside the sixth sector's address field (its track code)
    k = leftover(10) + 5 * 6208 + 384 + 3 * 8 + 3;
    rev0[k] = !rev0[k];
    frame(0, cells(10)); decode(10, 0, 1);
    check(good_hdr == 11 && bad_hdr >= 1, "a flipped header bit fails that header", good_hdr, 11);
    end   // the GCR half

    // ---- 8. a 1.44 MB image
    $display("---- 8. a 1.44 MB image: every cylinder, both sides, the reference decoder");
    #1 disk_in = 0; repeat (4) @(posedge clk);
    mfm_geometry(1); build_mfm_image;
    #1 img_mfm = 1; img_hd = 1; img_ds = 1; img_tags = 0;
    mark_cells = menc(8'hA1, 1'b1, 1'b0);
    check(mark_cells == 16'h4489, "(the bench's mark: A1, its middle clock dropped, cells $4489)", mark_cells, 16'h4489);
    crc0 = ucrc(ucrc(ucrc(16'hFFFF, 8'hA1), 8'hA1), 8'hA1);
    check(crc0 == 16'hCDB4, "(the bench's CRC over A1 A1 A1 from all ones: $CDB4)", crc0, 16'hCDB4);
    #1 disk_in = 1;
    mfm_sums_clear;
    for (c = 0; c < 80; c = c + 1) begin
      #1 cyl = c;
      wait_valid(c, took); if (took > maxtook) maxtook = took;
      for (s = 0; s < 2; s = s + 1) begin
        mfm_side(c, s, c == 0 || c == 41 || c == 79, c == 0 || c == 37 || c == 79);
        if (c == 0 && s == 0)
          $display("     cylinder 0 side 0: first address mark at cell %0d, %0d marks, gap 3 %0d bytes, the tail %0d bytes of 4E",
                   m_gap1, m_marks, (id_pos[1] - da_pos[0]) / 16 - 518 - 12, m_tail);
      end
    end
    check(m_all_ids == 2880, "address fields found, one revolution a side", m_all_ids, 2880);
    check(m_all_hdr == 2880, "  C H R N and their CRC right", m_all_hdr, 2880);
    check(m_all_data == 2880, "data fields: the CRC right, the data byte for byte", m_all_data, 2880);
    check(m_bad_rule == 0, "every interval 2, 3 or 4 cells, all 160 sides (and the wrap)", m_bad_rule, 0);
    check(m_bad_marks == 0, "the mark only where the 18 sectors put it (108 a side)", m_bad_marks, 0);
    check(m_bad_order == 0, "sectors 1..18 in order (1:1)", m_bad_order, 0);
    check(m_bad_gaps == 0, "32 x 4E from the index, gap 2, gap 3 of 108, 4E to the end", m_bad_gaps, 0);
    check(m_bad_layout == 0, "every cell the formatter's layout, all 160 sides", m_bad_layout, 0);
    check(port_diff == 0, "the drive's port reads the buffer (cylinders 0, 41, 79, both sides)", port_diff, 0);
    $display("     longest build: %0d clocks (%0d us at clk_sys)", maxtook, maxtook * 32 / 1000);
    check(maxtook < 1128038, "each cylinder built inside the drive's 36 ms settle", maxtook, 1128038);
    check(torn == 0 && moved == 0 && early == 0, "the disk port's handshake clean", torn + moved + early, 0);

    // ---- 11 (first part). negative cases, on cylinder 79 side 1 just read
    $display("---- 11. negative cases, a restart, GCR after MFM");
    k = da_pos[3] + 16 * 100 + 2 * 3 + 1;        // a data cell in sector 4's data
    mrev[k] = !mrev[k]; mfm_decode(79, 1);
    check(m_data_ok == 17 && m_hdr_ok == 18, "a flipped data cell fails that sector's CRC alone", m_data_ok, 17);
    mrev[k] = !mrev[k];
    k = id_pos[5] + 16 * 5 + 2 * 6 + 1;          // a data cell in sector 6's H
    mrev[k] = !mrev[k]; mfm_decode(79, 1);
    check(m_hdr_ok == 17, "a flipped address-field cell fails that header", m_hdr_ok, 17);
    mrev[k] = !mrev[k];

    // ---- 9. a 720K image
    $display("---- 9. a 720K image: cylinders of the whole disk, both sides");
    #1 disk_in = 0; repeat (4) @(posedge clk);
    mfm_geometry(0); build_mfm_image;
    #1 img_hd = 0; disk_in = 1;
    mfm_sums_clear; nsec = 0;
    for (k = 0; k < 8; k = k + 1) begin
      c = (k == 0) ? 0 : (k == 1) ? 1 : (k == 2) ? 17 : (k == 3) ? 33 : (k == 4) ? 40 : (k == 5) ? 63 : (k == 6) ? 78 : 79;
      #1 cyl = c;
      wait_valid(c, took); if (took > maxtook) maxtook = took;
      for (s = 0; s < 2; s = s + 1) begin
        mfm_side(c, s, c == 79, c == 1 || c == 79);
        nsec = nsec + mspt;
      end
    end
    check(m_all_ids == nsec && m_all_hdr == nsec, "address fields found and right, 16 sides", m_all_hdr, nsec);
    check(m_all_data == nsec, "data fields right, byte for byte", m_all_data, nsec);
    check(m_bad_rule == 0 && m_bad_marks == 0 && m_bad_order == 0, "MFM's rule, the marks, sectors 1..9 in order", m_bad_rule + m_bad_marks + m_bad_order, 0);
    check(m_bad_gaps == 0, "gaps: 32, 22, gap 3 of 80, 4E to the end of 100,000 cells", m_bad_gaps, 0);
    check(m_bad_layout == 0, "every cell the formatter's layout", m_bad_layout, 0);
    check(port_diff == 0, "the drive's port reads the buffer (cylinder 79)", port_diff, 0);
    $display("     longest build: %0d clocks", maxtook);

    // ---- 10. MacLC's encoder
    $display("---- 10. MacLC's mfm_track_encoder.v on the same images");
    $display("     %0d sectors compared (1.44 MB cylinders 0, 37, 79; 720K 1, 79; both sides)", lc_secs);
    check(lc_secs == 6 * 18 + 4 * 9, "(sectors compared)", lc_secs, 6 * 18 + 4 * 9);
    check(lc_mism == 0, "address and data fields identical to MacLC's, marks and CRCs", lc_mism, 0);

    // ---- 11. a restart; GCR after MFM
    $display("---- 11 (cont.)");
    #1 cyl = 20;
    repeat (2000) @(posedge clk);
    @(posedge clk); #1;
    while (!(mem_req && !req_d)) begin @(posedge clk); #1; end
    cyl = 45;
    wait_valid(45, took);
    check(trk_valid && trk_cyl == 45, "a new cylinder mid-build: restarted, valid for 45", trk_cyl, 45);
    mfm_peek(1); mfm_decode(45, 1);
    check(m_data_ok == 9 && m_hdr_ok == 9, "  its nine sectors of side 1", m_data_ok, 9);
    #1 disk_in = 0; repeat (4) @(posedge clk);
    img_mfm = 0; img_ds = 1; img_tags = 1; build_image;
    #1 cyl = 3; disk_in = 1;
    wait_valid(3, took); read_track(3);
    frame(1, cells(3)); decode(3, 1, 1);
    check(good_data == 12, "a GCR image after the MFM ones: GCR again", good_data, 12);
    check(torn == 0 && moved == 0 && early == 0, "the handshake still clean", torn + moved + early, 0);

    if (fails == 0) $display("==== PASS: %0d checks, the encoder holds to plan 5.12.4, 5.12.5b and 5.13.9", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(32.0 * 300000000); $display("==== FAIL: timeout"); $finish; end

endmodule
