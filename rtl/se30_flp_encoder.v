// se30_flp_encoder.v - the internal drive's track buffers: a cylinder of a
// disk image, laid out as the SE/30 ROM's GCR formatter lays a track, a
// bit a cell (SE30_PLAN.md 5.12.4 and 5.12.5b).
//
// WHAT IT IS
//   When a disk is in and the drive's head is on a cylinder the buffers do
//   not hold, the encoder reads that cylinder's sectors from the image in
//   SDRAM and writes both sides' bitstreams into block RAM, which the
//   drive plays (se30_fdhd.v's trk_addr/trk_side/trk_bit).  trk_valid
//   says the buffers hold trk_cyl whole; the drive's /READY waits for it.
//   Held to sim/flpenc/tb_se30_flp_encoder.v.
//
// THE TRACK (the ROM's formatter at its exact speeds, plan 5.12.5b)
//   The leftover of the revolution first, as ten-bit sync groups ending
//   in 00 - where the formatter's overrun lead-in would be - then, for
//   each sector in the formatter's 2:1 order ($408321CA), 776 bytes:
//     8 x FF 3F CF F3 FC FF          sync, four FF/00 groups and an FF
//     D5 AA 96 T S Sd F C DE AA FF   the address field ($40832198)
//     FF 3F CF F3 FC FF              sync
//     D5 AA AD S                     the data field's mark, its sector
//     703 codes                      524 bytes nibbled, and the checksum
//     DE AA FF FF                    ($4082E65E)
//   All GCR through the table the ROM ($4082E662) and the ERS (sheet 42)
//   both give.  A sector is 6,208 cells; groups 1-5 leave 62, 188, 157,
//   82 and 126 cells over.  A single-sided image's side 1 has no flux.
//
// THE NIBBLING (the ERS's steps 1-9; the ROM's writer, $4082E566)
//   For each group of three bytes A B C: rotate CSUMC left (its bit 7 the
//   carry), CSUMA += A + carry, A ^= CSUMC; CSUMB += B + carry, B ^= CSUMA;
//   CSUMC += C + carry, C ^= CSUMB; then {A7A6 B7B6 C7C6} and the three
//   low sixes.  524 bytes are 174 groups and A B alone (699 codes); the
//   checksum's four codes follow the same split.  The last carry out of
//   CSUMC is lost; the sector number is not in the checksum.
//
// THE IMAGE (5.12.5b)
//   Word BASE + k holds image bytes 2k (high) and 2k+1 (low), the header
//   stripped: block n's data at BASE + 256n, its tag - when the image has
//   tags - at BASE + 256 x blocks + 6n, blocks being the FILE's (img_800k:
//   1600, else 800), not the volume's.  Cylinder c, side s, sector k is
//   block sides x (sectors before c) + s x spt + k.
//
// WRITING (rung 3, plan 5.15.5 item 3)
//   The buffer is the medium: the drive's recording writes cells through
//   the same port it reads (trk_we, a cell read or written, never both),
//   and the decoder reads the written cells through the encoder's port
//   (dec_addr, dec_bit a clock later) while the encoder is idle.  A
//   rebuild waits while `hold` is up - the decoder is turning a written
//   cylinder into sectors, and the new cylinder must be read from an image
//   that already holds them.
//
// THE DISK PORT
//   A level request, its address held, until a level acknowledge that
//   carries the word; the request drops, and the next is not raised until
//   the acknowledge has fallen.  A new cylinder, or the disk leaving,
//   abandons the build - but never with a request outstanding.

`timescale 1ns/1ps

module se30_flp_encoder #(
  parameter [23:0] BASE = 24'h800000
) (
  input             clk,
  input             reset_n,

  input             disk_in,           // a whole image is in SDRAM
  input             img_ds,            // 1 = double-sided (1600 blocks), 0 = 800
  input             img_tags,          // the image carries 12 tag bytes a block
  input             img_800k,          // the FILE's data region is 1600 blocks (its tags follow it)

  input       [6:0] cyl,               // the drive's head
  output reg  [6:0] trk_cyl,           // what the buffers hold
  output reg        trk_valid,
  input      [16:0] trk_addr,          // the drive's port
  input             trk_side,
  output reg        trk_bit,
  input             trk_we,            // the drive records trk_wbit there
  input             trk_wbit,

  input             hold,              // the decoder is busy: no rebuild
  input      [17:0] dec_addr,          // the decoder's read: side 1 at SIDE1 + cell
  output reg        dec_bit,           // a clock later, while the encoder is idle
  output            enc_idle,

  output reg        mem_req,           // the disk port
  output reg [23:0] mem_addr,
  input      [15:0] mem_rdata,
  input             mem_ack,

  output     [15:0] dbg
);

  localparam [17:0] SIDE1 = 18'd74560;           // side 1's half of the buffer

  // ------------------------------------------------------------ tables
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
  function [7:0] chunk(input [2:0] i);           // FF 3F CF F3 FC FF
    case (i)
      3'd1: chunk = 8'h3F; 3'd2: chunk = 8'hCF; 3'd3: chunk = 8'hF3; 3'd4: chunk = 8'hFC;
      default: chunk = 8'hFF;
    endcase
  endfunction

  // ------------------------------------------------------------ the cylinder
  reg  [6:0] c;                                  // the cylinder being built
  reg        bside;
  wire [2:0] grp  = c[6:4];
  wire [3:0] spt  = 4'd12 - {1'b0, grp};
  reg [16:0] cells;                              // a revolution of this group
  reg  [7:0] lead;                               // its leftover
  reg  [3:0] lead_m;                             // (leftover - 1) mod 10: the pattern's phase
  reg  [9:0] gstart;                             // sectors on one side before the group
  always @* begin
    case (grp)
      3'd0:    begin cells = 17'd74558; lead = 8'd62;  lead_m = 4'd1; gstart = 10'd0;   end
      3'd1:    begin cells = 17'd68476; lead = 8'd188; lead_m = 4'd7; gstart = 10'd192; end
      3'd2:    begin cells = 17'd62237; lead = 8'd157; lead_m = 4'd6; gstart = 10'd368; end
      3'd3:    begin cells = 17'd55954; lead = 8'd82;  lead_m = 4'd1; gstart = 10'd528; end
      default: begin cells = 17'd49790; lead = 8'd126; lead_m = 4'd5; gstart = 10'd672; end
    endcase
  end
  wire [10:0] before_c = {1'b0, gstart} + c[3:0] * spt;        // sectors on one side before c

  reg  [3:0] slot;                               // the sector's place on the track
  wire [3:0] half = (spt - 4'd1) / 2 + 4'd1;
  wire [3:0] sector = slot[0] ? half + (slot >> 1) : (slot >> 1);   // $408321CA
  wire [10:0] blk = (img_ds ? {before_c[9:0], 1'b0} : before_c) + (bside ? {7'd0, spt} : 11'd0) + {7'd0, sector};
  // the tags follow the file's data region, whatever the volume on it is:
  // an 800K DiskCopy file may carry a 400K volume (img_ds low)
  wire [23:0] tag_base = BASE + (img_800k ? 24'd409600 : 24'd204800) + {blk, 2'b00} + {blk, 1'b0};

  // the address field: track, sector, side, format, checksum (decoded)
  wire [5:0] h_trk = c[5:0];
  wire [5:0] h_sec = {2'b00, sector};
  wire [5:0] h_sd  = {bside, 4'b0000, c[6]};
  wire [5:0] h_fmt = img_ds ? 6'h22 : 6'h02;
  wire [5:0] h_chk = h_trk ^ h_sec ^ h_sd ^ h_fmt;

  // ------------------------------------------------------------ buffers
  reg        tbuf [0:149119];                    // both sides' bitstreams
  reg [15:0] sbuf [0:261];                       // a sector: 6 tag words, 256 data words
  reg  [7:0] cbuf [0:702];                       // its 703 data-field codes

  // port A, the drive: a cell read, or written by the recording - never
  // both in one clock (a read while writing would ask the M10K for the
  // old data on the same port, which true dual-port mode cannot give, and
  // Quartus then builds the buffer from registers; trk_bit holds instead)
  wire [17:0] pa = trk_side ? SIDE1 + {1'b0, trk_addr} : {1'b0, trk_addr};
  always @(posedge clk) begin
    if (trk_we) tbuf[pa] <= trk_wbit;
    else        trk_bit <= tbuf[pa];
  end

  // ------------------------------------------------------------ the build
  localparam S_IDLE = 4'd0, S_SIDE = 4'd1, S_FILL = 4'd2, S_LEAD = 4'd3, S_FETCH = 4'd4,
             S_NIB = 4'd5, S_SUM = 4'd6, S_EMIT = 4'd7, S_DONE = 4'd8;
  reg  [3:0] st;
  reg [16:0] wptr;                               // the cell being written
  reg  [8:0] widx;                               // FETCH: the sector buffer's word
  reg  [7:0] lcnt;                               // LEAD: cells left
  reg  [3:0] lm;                                 // LEAD: the pattern's phase
  reg  [7:0] g;                                  // NIB: the group
  reg  [3:0] ns;                                 // NIB, SUM: the step
  reg  [9:0] bidx;                               // the sector byte being read
  reg [15:0] sbuf_q;
  reg        bsel_q;
  reg  [7:0] A, B;
  reg  [7:0] ca, cb, cc, Ap, Bp, Cp;
  reg  [9:0] ci;                                 // codes written
  reg  [9:0] j;                                  // EMIT: the byte
  reg  [2:0] bk;                                 // EMIT: its bit, 7 first
  reg  [2:0] j6;                                 // j mod 6 in the sync chunks
  reg  [7:0] cur;
  reg  [7:0] cbuf_q;
  reg  [9:0] cbuf_ra;

  wire [7:0] sbyte = bsel_q ? sbuf_q[7:0] : sbuf_q[15:8];
  wire       last  = (g == 8'd174);

  // one group, the ERS's steps 1-7 on A, B and the byte now read (C)
  wire [7:0] rot = {cc[6:0], cc[7]};
  wire [8:0] sa  = {1'b0, ca} + {1'b0, A} + {8'd0, cc[7]};
  wire [7:0] ap  = A ^ rot;
  wire [8:0] sb  = {1'b0, cb} + {1'b0, B} + {8'd0, sa[8]};
  wire [7:0] bp  = B ^ sa[7:0];
  wire [8:0] sc  = {1'b0, rot} + {1'b0, sbyte} + {8'd0, sb[8]};
  wire [7:0] cp  = sbyte ^ sb[7:0];

  // the byte the emitter takes next (index jn)
  wire [9:0] jn = j + 10'd1;
  reg  [7:0] nbyte;
  always @* begin
    if (jn < 10'd48)       nbyte = chunk(j6 == 3'd5 ? 3'd0 : j6 + 3'd1);
    else if (jn < 10'd59)
      case (jn - 10'd48)
        10'd0: nbyte = 8'hD5;       10'd1: nbyte = 8'hAA;       10'd2: nbyte = 8'h96;
        10'd3: nbyte = gcr(h_trk);  10'd4: nbyte = gcr(h_sec);  10'd5: nbyte = gcr(h_sd);
        10'd6: nbyte = gcr(h_fmt);  10'd7: nbyte = gcr(h_chk);  10'd8: nbyte = 8'hDE;
        10'd9: nbyte = 8'hAA;       default: nbyte = 8'hFF;
      endcase
    else if (jn < 10'd65)  nbyte = chunk(jn - 10'd59);
    else if (jn == 10'd65) nbyte = 8'hD5;
    else if (jn == 10'd66) nbyte = 8'hAA;
    else if (jn == 10'd67) nbyte = 8'hAD;
    else if (jn == 10'd68) nbyte = gcr(h_sec);
    else if (jn < 10'd772) nbyte = cbuf_q;
    else if (jn == 10'd772) nbyte = 8'hDE;
    else if (jn == 10'd773) nbyte = 8'hAA;
    else                   nbyte = 8'hFF;
  end

  // port B: the build's writes, or the decoder's reads while idle
  reg        tb_we, tb_d;
  reg [17:0] tb_a;
  // (by the write, not the state: a build abandoned on a seek can leave its
  // last write for the first idle clock)
  wire [17:0] pb = tb_we ? tb_a : dec_addr;
  always @(posedge clk) begin
    if (tb_we) tbuf[pb] <= tb_d;
    else       dec_bit <= tbuf[pb];
  end

  reg        sb_we;
  reg  [8:0] sb_a;
  reg [15:0] sb_d;
  always @(posedge clk) begin
    if (sb_we) sbuf[sb_a] <= sb_d;
    sbuf_q <= sbuf[bidx[9:1]];
    bsel_q <= bidx[0];
  end

  reg        cb_we;
  reg  [9:0] cb_a;
  reg  [7:0] cb_d;
  always @(posedge clk) begin
    if (cb_we) cbuf[cb_a] <= cb_d;
    cbuf_q <= cbuf[cbuf_ra];
  end

  wire [17:0] wbase = bside ? SIDE1 : 18'd0;
  wire        leave = !disk_in || cyl != c;     // abandon the build (no request out)

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      st <= S_IDLE; trk_valid <= 0; trk_cyl <= 7'h7F; mem_req <= 0; mem_addr <= 0;
      c <= 0; bside <= 0; slot <= 0; wptr <= 0; widx <= 0; lcnt <= 0; lm <= 0; g <= 0; ns <= 0;
      bidx <= 0; A <= 0; B <= 0; ca <= 0; cb <= 0; cc <= 0; Ap <= 0; Bp <= 0; Cp <= 0;
      ci <= 0; j <= 0; bk <= 0; j6 <= 0; cur <= 0; cbuf_ra <= 0;
      tb_we <= 0; tb_a <= 0; tb_d <= 0; sb_we <= 0; sb_a <= 0; sb_d <= 0; cb_we <= 0; cb_a <= 0; cb_d <= 0;
    end else begin
      tb_we <= 0; sb_we <= 0; cb_we <= 0;
      if (!disk_in) trk_valid <= 0;

      if (st != S_IDLE && !mem_req && leave) st <= S_IDLE;
      else case (st)
        S_IDLE:
          if (disk_in && !hold && !(trk_valid && trk_cyl == cyl)) begin
            trk_valid <= 0; c <= cyl; bside <= 0; st <= S_SIDE;
          end

        S_SIDE: begin                            // a side begins
          wptr <= 0; slot <= 0; lcnt <= lead; lm <= lead_m;
          st <= (bside && !img_ds) ? S_FILL : S_LEAD;
        end

        S_FILL: begin                            // side 1 of a single-sided disk: no flux
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= 0;
          wptr <= wptr + 1'b1;
          if (wptr + 1'b1 == cells) st <= S_DONE;        // FILL is only ever side 1
        end

        S_LEAD: begin                            // the leftover: groups ending in 00
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= (lm >= 4'd2);
          wptr <= wptr + 1'b1;
          lm <= (lm == 0) ? 4'd9 : lm - 1'b1;
          lcnt <= lcnt - 1'b1;
          if (lcnt == 8'd1) begin widx <= 0; st <= S_FETCH; end
        end

        S_FETCH: begin                           // the sector's 262 words
          if (widx < 9'd6 && !img_tags) begin
            sb_we <= 1; sb_a <= widx; sb_d <= 16'h0000; widx <= widx + 1'b1;
          end else if (widx == 9'd262) begin
            g <= 0; ns <= 0; ci <= 0; ca <= 0; cb <= 0; cc <= 0; st <= S_NIB;
          end else if (mem_req) begin
            if (mem_ack) begin
              mem_req <= 0; sb_we <= 1; sb_a <= widx; sb_d <= mem_rdata; widx <= widx + 1'b1;
            end
          end else if (!mem_ack) begin
            mem_req  <= 1;
            mem_addr <= (widx < 9'd6) ? tag_base + {15'd0, widx}
                                       : BASE + {5'd0, blk, 8'd0} + {15'd0, widx - 9'd6};
          end
        end

        S_NIB: begin                             // the 175 groups
          ns <= ns + 1'b1;
          case (ns)
            // the buffer's read is registered: byte bidx is on sbyte the
            // clock after bidx is set
            4'd0: bidx <= {g, 1'b0} + {2'b00, g};           // 3g
            4'd1: bidx <= bidx + 1'b1;
            4'd2: begin bidx <= bidx + 1'b1; A <= sbyte; end
            4'd3: B <= sbyte;
            4'd4: begin                                     // C (or none) on sbyte now
              ca <= sa[7:0]; cb <= sb[7:0]; Ap <= ap; Bp <= bp;
              if (last) begin cc <= rot; Cp <= 8'h00; end
              else begin cc <= sc[7:0]; Cp <= cp; end
            end
            4'd5: begin cb_we <= 1; cb_a <= ci; cb_d <= gcr({Ap[7:6], Bp[7:6], Cp[7:6]}); ci <= ci + 1'b1; end
            4'd6: begin cb_we <= 1; cb_a <= ci; cb_d <= gcr(Ap[5:0]); ci <= ci + 1'b1; end
            4'd7: begin
              cb_we <= 1; cb_a <= ci; cb_d <= gcr(Bp[5:0]); ci <= ci + 1'b1;
              if (last) begin ns <= 0; st <= S_SUM; end
            end
            default: begin
              cb_we <= 1; cb_a <= ci; cb_d <= gcr(Cp[5:0]); ci <= ci + 1'b1;
              ns <= 0; g <= g + 1'b1;
            end
          endcase
        end

        S_SUM: begin                             // the checksum's four codes
          ns <= ns + 1'b1;
          cb_we <= 1; cb_a <= ci; ci <= ci + 1'b1;
          case (ns)
            4'd0: cb_d <= gcr({ca[7:6], cb[7:6], cc[7:6]});
            4'd1: cb_d <= gcr(ca[5:0]);
            4'd2: cb_d <= gcr(cb[5:0]);
            default: begin
              cb_d <= gcr(cc[5:0]);
              j <= 0; bk <= 0; j6 <= 0; cur <= 8'hFF; cbuf_ra <= 0;
              st <= S_EMIT;
            end
          endcase
        end

        S_EMIT: begin                            // the sector's 776 bytes, a bit a clock
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= cur[7];
          wptr <= wptr + 1'b1;
          cur <= {cur[6:0], 1'b0};
          bk <= bk + 1'b1;
          cbuf_ra <= jn - 10'd69;                // the code for the next byte, read ahead
          if (bk == 3'd7) begin
            if (j == 10'd775) begin
              if (slot + 1'b1 == spt) begin
                if (bside) st <= S_DONE;
                else begin bside <= 1; st <= S_SIDE; end   // (a single-sided image: FILL)
              end else begin slot <= slot + 1'b1; widx <= 0; st <= S_FETCH; end
            end else begin
              j <= jn; cur <= nbyte;
              j6 <= (j6 == 3'd5) ? 3'd0 : j6 + 1'b1;
            end
          end
        end

        S_DONE: begin                            // the last bit is in: valid
          trk_valid <= 1; trk_cyl <= c; st <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  assign enc_idle = (st == S_IDLE);
  assign dbg = {trk_valid, bside, st, slot, c[5:0]};

endmodule
