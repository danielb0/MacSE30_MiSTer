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

  reg        disk_in = 0, img_ds = 1, img_tags = 1;
  reg  [6:0] cyl = 0;
  wire [6:0] trk_cyl;
  wire       trk_valid;
  reg [16:0] trk_addr = 0;
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
    .cyl(cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
    .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
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

  reg [15:0] mem [0:1600*256 + 1600*6 - 1];
  reg  [7:0] exp_sec [0:1599*524 + 523];         // the 524 bytes each block should decode to
  reg  [7:0] mem8 [0:819199];                    // MacPlus's view: the data, bytes
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
        mem_rdata <= (mem_addr >= BASE && mem_addr - BASE < 1600*256 + 1600*6) ? mem[mem_addr - BASE] : 16'hBAD0;
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

  // ------------------------------------------------------------ the run
  integer c, s, took, maxtook, all_good, all_hdr, all_found, bad_order, bad_fmt, bad_sync, bad_lead, bad_layout;
  integer side1_bytes, a, i, k, nsec;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;

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

    if (fails == 0) $display("==== PASS: %0d checks, the encoder holds to plan 5.12.4 and 5.12.5b", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #(32.0 * 300000000); $display("==== FAIL: timeout"); $finish; end

endmodule
