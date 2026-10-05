// se30_flp_decoder.v - a written GCR track back into sectors, and the
// sectors into the image (SE30_PLAN.md 5.15.5 items 4, 5 and 7).
//
// WHAT IT IS
//   The drive records what the SWIM writes into the track buffer, cell by
//   cell (se30_fdhd.v), and reports each recording as an arc: its side,
//   first and last cells, and whether it covered a whole revolution.  This
//   module reads the arc's cells back out of the buffer (the encoder's
//   port B, while the encoder is idle), frames them into bytes as the IWM
//   does, finds the fields the ROM writes, and puts every good data field
//   into the disk image in SDRAM under the head's cylinder, the arc's side
//   and the field's own sector number.  Each commit is then offered to the
//   SD writer (cm_done, cm_blk), which may hold it back (cm_ready).  While
//   it works it holds the encoder's rebuild (`hold`): a seek waits until
//   the written cylinder is in the image.  Held to
//   sim/flpdec/tb_se30_flp_decoder.v.
//
// THE WINDOW
//   A sector write (5.15.4) is an arc shorter than a revolution: its cells,
//   from the first to the last, are parsed - everything in them is new.  A
//   track format overruns its own start, so the whole side is new: the
//   parse starts at the cell after the arc's end and runs a revolution and
//   one sector (6,208 cells) more, so the field the wrap cuts is read
//   whole on the second pass; a sector already committed from this arc is
//   not committed twice.
//
// THE FRAMING AND THE FIELDS (the ERS, sheets 40-42; the ROM's writer)
//   Bits enter a shift register until a one reaches its MSB - a byte - as
//   in the IWM's read path (5.12.2).  D5 AA 96 opens an address field:
//   five codes (track, sector, side, format, checksum = the XOR of the
//   four); a good one sets the medium's sidedness from the format byte's
//   bit 5 (item 7).  D5 AA AD opens a data field: the sector's code, 699
//   codes - 174 groups of four and one of three - and four checksum codes.
//   The inverse of the encoder's steps, per group A' B' C': rotate CSUMC
//   left (its bit 7 the carry); A = A' ^ CSUMC; CSUMA += A + carry; B = B'
//   ^ CSUMA; CSUMB += B + carry; C = C' ^ CSUMB; CSUMC += C + carry.  The
//   last group has no C, and CSUMC is left rotated.  A field with a code
//   outside the GCR table, or a checksum that does not match, is refused.
//
// THE IMAGE (the encoder's layout, 5.12.5b)
//   Cylinder c, side s, sector k is block sides x (sectors before c) + s x
//   spt + k, its data at BASE + 256 x block, its tags (when the image has
//   them) at BASE + 409,600 or 204,800 (the file's data region) + 6 x
//   block.  The bytes are the 12 tags then the 512 data bytes.  A field
//   the layout cannot place - a sector past the zone's count, side 1 of a
//   single-sided medium, a cylinder past 79 - is refused, checked in the
//   state that issues the first word (MacPlus defect 4); nothing is
//   committed while the image is loading, out or read-only (defect 3).
//
// THE SIDEDNESS (5.15.5 item 7; the LC's 6B)
//   ds_eff is what the encoder and this module lay the image out by: the
//   file can hold two sides (img_800k), and either the last good address
//   field written since the mount says so, or, with none, the loader's
//   reading of the volume (img_ds).  A one-sided format of an 800K image
//   so becomes a 400K disk at once, and stays one after a remount.

`timescale 1ns/1ps

module se30_flp_decoder #(
  parameter [23:0] BASE  = 24'h800000,
  parameter [17:0] SIDE1 = 18'd74560   // side 1's half of the track buffer (the encoder's)
) (
  input             clk,
  input             reset_n,

  input             disk_in,
  input             loading,
  input             write_ok,          // the image may be written (not read-only)
  input             img_ds,            // the loader's sidedness
  input             img_800k,          // the file's data region is 1600 blocks
  input             img_tags,          // the image carries 12 tag bytes a block
  output            ds_eff,            // the sidedness the image is laid out by

  input             arc_done,          // the drive's recording ended
  input             arc_side,
  input      [16:0] arc_start,
  input      [16:0] arc_end,
  input             arc_whole,
  input      [16:0] trk_cells,         // the revolution, in cells
  input       [6:0] cyl,               // the head's cylinder

  output reg [17:0] dec_addr,          // the track buffer (the encoder's port B)
  input             dec_bit,
  input             enc_idle,
  output            hold,              // no rebuild while a written cylinder is decoded

  output reg        mem_req,           // the disk port: writes
  output reg [23:0] mem_addr,
  output reg [15:0] mem_wdata,
  input             mem_ack,

  output reg        cm_done,           // one clock: a sector is in the image
  output reg [10:0] cm_blk,            // its block
  input             cm_ready,          // the SD writer can take one

  output     [31:0] dbg
);

  // ------------------------------------------------------------ tables
  // the GCR table's inverse: {valid, value}
  function [6:0] dnib(input [7:0] v);
    case (v)
      8'h96: dnib = 7'h40; 8'h97: dnib = 7'h41; 8'h9A: dnib = 7'h42; 8'h9B: dnib = 7'h43;
      8'h9D: dnib = 7'h44; 8'h9E: dnib = 7'h45; 8'h9F: dnib = 7'h46; 8'hA6: dnib = 7'h47;
      8'hA7: dnib = 7'h48; 8'hAB: dnib = 7'h49; 8'hAC: dnib = 7'h4A; 8'hAD: dnib = 7'h4B;
      8'hAE: dnib = 7'h4C; 8'hAF: dnib = 7'h4D; 8'hB2: dnib = 7'h4E; 8'hB3: dnib = 7'h4F;
      8'hB4: dnib = 7'h50; 8'hB5: dnib = 7'h51; 8'hB6: dnib = 7'h52; 8'hB7: dnib = 7'h53;
      8'hB9: dnib = 7'h54; 8'hBA: dnib = 7'h55; 8'hBB: dnib = 7'h56; 8'hBC: dnib = 7'h57;
      8'hBD: dnib = 7'h58; 8'hBE: dnib = 7'h59; 8'hBF: dnib = 7'h5A; 8'hCB: dnib = 7'h5B;
      8'hCD: dnib = 7'h5C; 8'hCE: dnib = 7'h5D; 8'hCF: dnib = 7'h5E; 8'hD3: dnib = 7'h5F;
      8'hD6: dnib = 7'h60; 8'hD7: dnib = 7'h61; 8'hD9: dnib = 7'h62; 8'hDA: dnib = 7'h63;
      8'hDB: dnib = 7'h64; 8'hDC: dnib = 7'h65; 8'hDD: dnib = 7'h66; 8'hDE: dnib = 7'h67;
      8'hDF: dnib = 7'h68; 8'hE5: dnib = 7'h69; 8'hE6: dnib = 7'h6A; 8'hE7: dnib = 7'h6B;
      8'hE9: dnib = 7'h6C; 8'hEA: dnib = 7'h6D; 8'hEB: dnib = 7'h6E; 8'hEC: dnib = 7'h6F;
      8'hED: dnib = 7'h70; 8'hEE: dnib = 7'h71; 8'hEF: dnib = 7'h72; 8'hF2: dnib = 7'h73;
      8'hF3: dnib = 7'h74; 8'hF4: dnib = 7'h75; 8'hF5: dnib = 7'h76; 8'hF6: dnib = 7'h77;
      8'hF7: dnib = 7'h78; 8'hF9: dnib = 7'h79; 8'hFA: dnib = 7'h7A; 8'hFB: dnib = 7'h7B;
      8'hFC: dnib = 7'h7C; 8'hFD: dnib = 7'h7D; 8'hFE: dnib = 7'h7E; 8'hFF: dnib = 7'h7F;
      default: dnib = 7'h00;
    endcase
  endfunction

  // ------------------------------------------------------------ the arc
  localparam [16:0] SECTOR_CELLS = 17'd6400;     // a sector's 6,208 cells, and some

  reg        fmt_seen, fmt_ds;
  assign ds_eff = img_800k && (fmt_seen ? fmt_ds : img_ds);

  reg        pend;                               // an arc waiting
  reg        p_side, p_whole;
  reg [16:0] p_start, p_end, p_cells;
  reg  [6:0] p_cyl;

  reg        a_side;                             // the arc being decoded
  reg [16:0] a_cells;
  reg  [6:0] a_cyl;
  reg [16:0] pos;                                // the next cell to read
  reg [17:0] left;                               // cells still to read
  reg [11:0] seen;                               // sectors committed from this arc

  // ------------------------------------------------------------ the parse
  localparam F_HUNT = 3'd0, F_ADDR = 3'd1, F_SEC = 3'd2, F_DATA = 3'd3, F_SUM = 3'd4;
  reg  [2:0] fs;
  reg  [7:0] sr;                                 // the framing shift register
  reg [15:0] hist;                               // the two bytes before
  reg  [2:0] k;                                  // the code within the field's group
  reg  [5:0] c0, c1, c2;                         // codes held: the group's high bits, A', B'
  reg  [7:0] g;                                  // the group
  reg  [5:0] h_trk, h_sec, h_side, h_fmt;
  reg  [3:0] sector;
  reg  [7:0] ca, cb, cc;                         // CSUMA, CSUMB, CSUMC
  reg  [9:0] bidx;                               // the sector byte being written
  reg  [7:0] wq0, wq1, wq2;                      // a group's bytes, waiting to be written
  reg  [1:0] wqn;                                // how many
  reg  [7:0] sbuf [0:523];                       // the sector: 12 tags, 512 data
  reg  [9:0] sb_ra;
  reg  [7:0] sb_q;
  reg        sb_we;
  reg  [9:0] sb_wa;
  reg  [7:0] sb_wd;
  always @(posedge clk) begin
    if (sb_we) sbuf[sb_wa] <= sb_wd;
    sb_q <= sbuf[sb_ra];
  end

  // a group's decode: A', B', C' from the held codes and this one
  wire [7:0] rot = {cc[6:0], cc[7]};
  wire [5:0] cur = dnib_q[5:0];
  wire [7:0] Ap  = {c0[5:4], c1};
  wire [7:0] Bp  = {c0[3:2], c2};
  wire [7:0] Cp  = {c0[1:0], cur};
  wire [7:0] A   = Ap ^ rot;
  wire [8:0] sa  = {1'b0, ca} + {1'b0, A} + {8'd0, cc[7]};
  wire [7:0] B   = Bp ^ sa[7:0];
  wire [8:0] sb  = {1'b0, cb} + {1'b0, B} + {8'd0, sa[8]};
  wire [7:0] C   = Cp ^ sb[7:0];
  wire [8:0] sc  = {1'b0, rot} + {1'b0, C} + {8'd0, sb[8]};
  // the last group: A' B' from c0 and c1 with this code as B's low six
  wire [7:0] Bl  = {c0[3:2], cur} ^ sa[7:0];
  wire [8:0] sbl = {1'b0, cb} + {1'b0, Bl} + {8'd0, sa[8]};

  reg  [7:0] byte_q;                             // the byte just framed
  reg  [6:0] dnib_q;                             // and its code's value
  reg        byte_v;

  // ------------------------------------------------------------ the image
  wire [2:0]  grp    = a_cyl[6:4];
  wire [3:0]  spt    = 4'd12 - {1'b0, grp};
  reg  [9:0]  gstart;
  always @* begin
    case (grp)
      3'd0: gstart = 10'd0;   3'd1: gstart = 10'd192; 3'd2: gstart = 10'd368;
      3'd3: gstart = 10'd528; default: gstart = 10'd672;
    endcase
  end
  wire [10:0] before_c = {1'b0, gstart} + a_cyl[3:0] * spt;
  wire [10:0] blk      = (ds_eff ? {before_c[9:0], 1'b0} : before_c) + (a_side ? {7'd0, spt} : 11'd0) + {7'd0, sector};
  wire [23:0] tag_base = BASE + (img_800k ? 24'd409600 : 24'd204800) + {blk, 2'b00} + {blk, 1'b0};
  wire        placeable = (a_cyl < 7'd80) && (sector < spt) && (!a_side || ds_eff) && !seen[sector];
  wire        writable  = write_ok && disk_in && !loading;

  // ------------------------------------------------------------ the states
  localparam S_IDLE = 3'd0, S_WAIT = 3'd1, S_ISSUE = 3'd2, S_BIT = 3'd3,
             S_COMMIT = 3'd4, S_WORD = 3'd5, S_PUSH = 3'd6;
  reg  [2:0] st;
  reg  [8:0] w;                                  // the word being committed: 256 data, 6 tags
  reg  [1:0] wp;                                 // its two byte reads
  reg  [7:0] hi;

  reg [15:0] n_commit;
  reg  [7:0] n_arc, n_refused;

  assign hold = (st != S_IDLE) || pend || arc_done;

  wire [8:0] nwords = img_tags ? 9'd262 : 9'd256;
  // word w's bytes: data words first (bytes 12 + 2w), then the tags (2(w - 256))
  wire [9:0] wbyte = (w < 9'd256) ? 10'd12 + {w[7:0], 1'b0} : {w - 9'd256, 1'b0};
  wire [23:0] waddr = (w < 9'd256) ? BASE + {5'd0, blk, 8'd0} + {16'd0, w[7:0]}
                                   : tag_base + {15'd0, w - 9'd256};

  wire [7:0] sr_n = {sr[6:0], dec_bit};

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      st <= S_IDLE; pend <= 0; fmt_seen <= 0; fmt_ds <= 0;
      p_side <= 0; p_whole <= 0; p_start <= 0; p_end <= 0; p_cells <= 0; p_cyl <= 0;
      a_side <= 0; a_cells <= 0; a_cyl <= 0; pos <= 0; left <= 0; seen <= 0;
      fs <= F_HUNT; sr <= 0; hist <= 0; k <= 0; c0 <= 0; c1 <= 0; c2 <= 0; g <= 0;
      h_trk <= 0; h_sec <= 0; h_side <= 0; h_fmt <= 0; sector <= 0; ca <= 0; cb <= 0; cc <= 0;
      bidx <= 0; wq0 <= 0; wq1 <= 0; wq2 <= 0; wqn <= 0; sb_ra <= 0; sb_we <= 0; sb_wa <= 0; sb_wd <= 0;
      byte_q <= 0; dnib_q <= 0; byte_v <= 0;
      dec_addr <= 0; mem_req <= 0; mem_addr <= 0; mem_wdata <= 0; cm_done <= 0; cm_blk <= 0;
      w <= 0; wp <= 0; hi <= 0; n_commit <= 0; n_arc <= 0; n_refused <= 0;
    end else begin
      cm_done <= 0;
      sb_we   <= 0;
      if (!disk_in) fmt_seen <= 0;

      // an arc arriving is kept until the decoder is free (one deep: the
      // ROM writes a sector, then reads the next address field - far
      // longer than a decode)
      if (arc_done && disk_in) begin
        pend <= 1; p_side <= arc_side; p_whole <= arc_whole; p_start <= arc_start;
        p_end <= arc_end; p_cells <= trk_cells; p_cyl <= cyl;
        n_arc <= n_arc + 1'b1;
      end

      // a group's bytes go into the sector buffer one a clock
      if (wqn != 0) begin
        sb_we <= 1; sb_wa <= bidx; sb_wd <= wq0; bidx <= bidx + 1'b1;
        wq0 <= wq1; wq1 <= wq2; wqn <= wqn - 1'b1;
      end

      case (st)
        S_IDLE:
          if (pend && !arc_done) begin
            pend <= 0;
            a_side <= p_side; a_cells <= p_cells; a_cyl <= p_cyl; seen <= 0;
            if (p_whole) begin
              pos  <= (p_end + 1'b1 >= p_cells) ? 17'd0 : p_end + 1'b1;
              left <= {1'b0, p_cells} + {1'b0, SECTOR_CELLS};
            end else begin
              pos  <= p_start;
              left <= (p_end >= p_start) ? {1'b0, p_end - p_start} + 18'd1
                                         : {1'b0, p_end} + {1'b0, p_cells} - {1'b0, p_start} + 18'd1;
            end
            fs <= F_HUNT; sr <= 0; hist <= 0;
            st <= S_WAIT;
          end

        S_WAIT:                                  // the encoder's port is ours while it is idle
          if (!disk_in) st <= S_IDLE;
          else if (enc_idle) st <= S_ISSUE;

        S_ISSUE: begin                           // a cell's address; its bit a clock later
          if (left == 0 || !disk_in) st <= S_IDLE;
          else begin
            dec_addr <= a_side ? SIDE1 + {1'b0, pos} : {1'b0, pos};
            pos  <= (pos + 1'b1 >= a_cells) ? 17'd0 : pos + 1'b1;
            left <= left - 1'b1;
            st   <= S_BIT;
          end
        end

        S_BIT: begin                             // (dec_bit is read here: one clock after the address)
          st <= S_ISSUE;
          byte_v <= 0;
          if (sr_n[7]) begin sr <= 0; byte_q <= sr_n; dnib_q <= dnib(sr_n); byte_v <= 1; end
          else sr <= sr_n;
        end

        S_COMMIT: begin                          // bound and address checked here, with the first word
          if (!(placeable && writable)) begin
            n_refused <= n_refused + 1'b1; st <= S_ISSUE;
          end else begin
            w <= 0; wp <= 0; sb_ra <= 10'd12; st <= S_WORD;
          end
        end

        S_WORD: begin                            // two byte reads, then the word to the disk port
          case (wp)
            2'd0: begin sb_ra <= wbyte + 1'b1; wp <= 2'd1; end
            2'd1: begin hi <= sb_q; wp <= 2'd2; end
            2'd2: if (!mem_req && !mem_ack) begin
                    mem_req <= 1; mem_addr <= waddr; mem_wdata <= {hi, sb_q}; wp <= 2'd3;
                  end
            default: if (mem_ack) begin
                    mem_req <= 0;
                    if (w + 1'b1 == nwords) st <= S_PUSH;
                    else begin w <= w + 1'b1; sb_ra <= (w + 1'b1 < 9'd256) ? 10'd14 + {w[7:0], 1'b0} : {w - 9'd255, 1'b0}; wp <= 2'd0; end
                  end
          endcase
        end

        S_PUSH:                                  // offered to the SD writer, which may hold it
          if (cm_ready && !mem_ack) begin
            cm_done <= 1; cm_blk <= blk; seen[sector] <= 1;
            n_commit <= n_commit + 1'b1;
            st <= S_ISSUE;
          end

        default: st <= S_IDLE;
      endcase

      // the field machine, on a framed byte (the clock after S_BIT)
      if (byte_v) begin
        byte_v <= 0;
        hist <= {hist[7:0], byte_q};
        case (fs)
          F_HUNT:
            if (hist == 16'hD5AA && byte_q == 8'h96) begin fs <= F_ADDR; k <= 0; end
            else if (hist == 16'hD5AA && byte_q == 8'hAD) fs <= F_SEC;
          F_ADDR:
            if (!dnib_q[6]) fs <= F_HUNT;
            else begin
              k <= k + 1'b1;
              case (k)
                3'd0: h_trk <= dnib_q[5:0];
                3'd1: h_sec <= dnib_q[5:0];
                3'd2: h_side <= dnib_q[5:0];
                3'd3: h_fmt <= dnib_q[5:0];
                default: begin
                  if ((h_trk ^ h_sec ^ h_side ^ h_fmt) == dnib_q[5:0]) begin
                    fmt_seen <= 1; fmt_ds <= h_fmt[5];
                  end
                  fs <= F_HUNT;
                end
              endcase
            end
          F_SEC:
            if (!dnib_q[6] || dnib_q[5:4] != 2'b00) fs <= F_HUNT;
            else begin
              sector <= dnib_q[3:0]; ca <= 0; cb <= 0; cc <= 0;
              g <= 0; k <= 0; bidx <= 0; fs <= F_DATA;
            end
          F_DATA:
            if (!dnib_q[6]) begin n_refused <= n_refused + 1'b1; fs <= F_HUNT; end
            else if (g == 8'd174) begin           // the last group: high bits, A', B'
              k <= k + 1'b1;
              if (k == 3'd0) c0 <= cur;
              else if (k == 3'd1) c1 <= cur;
              else begin
                wq0 <= A; wq1 <= Bl; wqn <= 2'd2;
                ca <= sa[7:0]; cb <= sbl[7:0]; cc <= rot;
                k <= 0; fs <= F_SUM;
              end
            end else begin
              k <= k + 1'b1;
              case (k)
                3'd0: c0 <= cur;
                3'd1: c1 <= cur;
                3'd2: c2 <= cur;
                default: begin
                  wq0 <= A; wq1 <= B; wq2 <= C; wqn <= 2'd3;
                  ca <= sa[7:0]; cb <= sb[7:0]; cc <= sc[7:0];
                  k <= 0; g <= g + 1'b1;
                end
              endcase
            end
          F_SUM:
            if (!dnib_q[6]) begin n_refused <= n_refused + 1'b1; fs <= F_HUNT; end
            else begin
              k <= k + 1'b1;
              case (k)
                3'd0: c0 <= cur;
                3'd1: c1 <= cur;
                3'd2: c2 <= cur;
                default: begin
                  fs <= F_HUNT;
                  if ({c0[5:4], c1} == ca && {c0[3:2], c2} == cb && {c0[1:0], cur} == cc)
                    st <= S_COMMIT;                // the parse pauses for the commit
                  else n_refused <= n_refused + 1'b1;
                end
              endcase
            end
          default: fs <= F_HUNT;
        endcase
      end
    end
  end

  assign dbg = {n_commit, n_refused, n_arc};

endmodule
