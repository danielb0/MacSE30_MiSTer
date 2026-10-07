// se30_flp_encoder.v - floppy track buffers: a cylinder of the image as GCR or MFM bit cells

`timescale 1ns/1ps

module se30_flp_encoder #(
  parameter [23:0] BASE = 24'h800000
) (
  input             clk,
  input             reset_n,

  input             disk_in,
  input             img_ds,
  input             img_tags,
  input             img_800k,
  input             img_mfm,
  input             img_hd,

  input       [6:0] cyl,
  output reg  [6:0] trk_cyl,
  output reg        trk_valid,
  input      [17:0] trk_addr,
  input             trk_side,
  output reg        trk_bit,
  input             trk_we,
  input             trk_wbit,

  input             hold,
  input      [18:0] dec_addr,
  output reg        dec_bit,
  output            enc_idle,

  output reg        mem_req,
  output reg [23:0] mem_addr,
  input      [15:0] mem_rdata,
  input             mem_ack,

  output     [15:0] dbg
);

  localparam [18:0] SIDE1 = 19'd200000;

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
  function [7:0] chunk(input [2:0] i);
    case (i)
      3'd1: chunk = 8'h3F; 3'd2: chunk = 8'hCF; 3'd3: chunk = 8'hF3; 3'd4: chunk = 8'hFC;
      default: chunk = 8'hFF;
    endcase
  endfunction

  reg  [6:0] c;
  reg        bside;
  wire [2:0] grp  = c[6:4];
  wire [3:0] spt  = 4'd12 - {1'b0, grp};
  reg [17:0] cells;
  reg  [7:0] lead;
  reg  [3:0] lead_m;
  reg  [9:0] gstart;
  always @* begin
    case (grp)
      3'd0:    begin cells = 18'd74558; lead = 8'd62;  lead_m = 4'd1; gstart = 10'd0;   end
      3'd1:    begin cells = 18'd68476; lead = 8'd188; lead_m = 4'd7; gstart = 10'd192; end
      3'd2:    begin cells = 18'd62237; lead = 8'd157; lead_m = 4'd6; gstart = 10'd368; end
      3'd3:    begin cells = 18'd55954; lead = 8'd82;  lead_m = 4'd1; gstart = 10'd528; end
      default: begin cells = 18'd49790; lead = 8'd126; lead_m = 4'd5; gstart = 10'd672; end
    endcase
    if (img_mfm) cells = img_hd ? 18'd200000 : 18'd100000;
  end
  wire [10:0] before_c = {1'b0, gstart} + c[3:0] * spt;

  reg  [4:0] slot;
  wire [3:0] half = (spt - 4'd1) / 2 + 4'd1;
  wire [3:0] sector = slot[0] ? half + (slot >> 1) : (slot >> 1);
  wire [10:0] blk = (img_ds ? {before_c[9:0], 1'b0} : before_c) + (bside ? {7'd0, spt} : 11'd0) + {7'd0, sector};
  wire [23:0] tag_base = BASE + (img_800k ? 24'd409600 : 24'd204800) + {blk, 2'b00} + {blk, 1'b0};

  wire [5:0] h_trk = c[5:0];
  wire [5:0] h_sec = {2'b00, sector};
  wire [5:0] h_sd  = {bside, 4'b0000, c[6]};
  wire [5:0] h_fmt = img_ds ? 6'h22 : 6'h02;
  wire [5:0] h_chk = h_trk ^ h_sec ^ h_sd ^ h_fmt;

  wire  [7:0] ts    = {c, bside};
  wire [11:0] mblk  = (img_hd ? {ts, 4'b0000} + {3'b000, ts, 1'b0} : {1'b0, ts, 3'b000} + {4'd0, ts})
                      + {7'd0, slot};
  wire [11:0] fblk  = img_mfm ? mblk : {1'b0, blk};
  wire  [4:0] mspt  = img_hd ? 5'd18 : 5'd9;
  wire  [9:0] mlast = img_hd ? 10'd681 : 10'd653;

  reg        tbuf [0:399999];
  reg [15:0] sbuf [0:261];
  reg  [7:0] cbuf [0:702];

  wire [18:0] pa = trk_side ? SIDE1 + {1'b0, trk_addr} : {1'b0, trk_addr};
  always @(posedge clk) begin
    if (trk_we) tbuf[pa] <= trk_wbit;
    else        trk_bit <= tbuf[pa];
  end

  localparam S_IDLE = 4'd0, S_SIDE = 4'd1, S_FILL = 4'd2, S_LEAD = 4'd3, S_FETCH = 4'd4,
             S_NIB = 4'd5, S_SUM = 4'd6, S_EMIT = 4'd7, S_DONE = 4'd8, S_MFM = 4'd9;
  reg  [3:0] st;
  reg [17:0] wptr;
  reg  [8:0] widx;
  reg  [7:0] lcnt;
  reg  [3:0] lm;
  reg  [7:0] g;
  reg  [3:0] ns;
  reg  [9:0] bidx;
  reg [15:0] sbuf_q;
  reg        bsel_q;
  reg  [7:0] A, B;
  reg  [7:0] ca, cb, cc, Ap, Bp, Cp;
  reg  [9:0] ci;
  reg  [9:0] j;
  reg  [2:0] bk;
  reg  [2:0] j6;
  reg  [7:0] cur;
  reg  [7:0] cbuf_q;
  reg  [9:0] cbuf_ra;
  reg  [1:0] mm;
  reg        ph;
  reg        pd;
  reg        mk;
  reg [15:0] crc;
  wire [15:0] crc_nx = {crc[14:0], 1'b0} ^ ((crc[15] ^ cur[7]) ? 16'h1021 : 16'h0000);

  wire [7:0] sbyte = bsel_q ? sbuf_q[7:0] : sbuf_q[15:8];
  wire       last  = (g == 8'd174);

  wire [7:0] rot = {cc[6:0], cc[7]};
  wire [8:0] sa  = {1'b0, ca} + {1'b0, A} + {8'd0, cc[7]};
  wire [7:0] ap  = A ^ rot;
  wire [8:0] sb  = {1'b0, cb} + {1'b0, B} + {8'd0, sa[8]};
  wire [7:0] bp  = B ^ sa[7:0];
  wire [8:0] sc  = {1'b0, rot} + {1'b0, sbyte} + {8'd0, sb[8]};
  wire [7:0] cp  = sbyte ^ sb[7:0];

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

  reg  [7:0] mbyte;
  reg        mbmark;
  always @* begin
    mbmark = 1'b0;
    if (jn < 10'd12)                       mbyte = 8'h00;
    else if (jn < 10'd15) begin            mbyte = 8'hA1; mbmark = 1'b1; end
    else if (jn == 10'd15)                 mbyte = 8'hFE;
    else if (jn == 10'd16)                 mbyte = {1'b0, c};
    else if (jn == 10'd17)                 mbyte = {7'd0, bside};
    else if (jn == 10'd18)                 mbyte = {3'd0, slot} + 8'd1;
    else if (jn == 10'd19)                 mbyte = 8'h02;
    else if (jn < 10'd22)                  mbyte = crc_nx[15:8];
    else if (jn < 10'd44)                  mbyte = 8'h4E;
    else if (jn < 10'd56)                  mbyte = 8'h00;
    else if (jn < 10'd59) begin            mbyte = 8'hA1; mbmark = 1'b1; end
    else if (jn == 10'd59)                 mbyte = 8'hFB;
    else if (jn < 10'd572)                 mbyte = sbyte;
    else if (jn < 10'd574)                 mbyte = crc_nx[15:8];
    else                                   mbyte = 8'h4E;
  end

  reg        tb_we, tb_d;
  reg [18:0] tb_a;
  wire [18:0] pb = tb_we ? tb_a : dec_addr;
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

  wire [18:0] wbase = bside ? SIDE1 : 19'd0;
  wire        mlastcell = (wptr + 1'b1 == cells);
  wire        leave = !disk_in || cyl != c;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      st <= S_IDLE; trk_valid <= 0; trk_cyl <= 7'h7F; mem_req <= 0; mem_addr <= 0;
      c <= 0; bside <= 0; slot <= 0; wptr <= 0; widx <= 0; lcnt <= 0; lm <= 0; g <= 0; ns <= 0;
      bidx <= 0; A <= 0; B <= 0; ca <= 0; cb <= 0; cc <= 0; Ap <= 0; Bp <= 0; Cp <= 0;
      ci <= 0; j <= 0; bk <= 0; j6 <= 0; cur <= 0; cbuf_ra <= 0;
      mm <= 0; ph <= 0; pd <= 0; mk <= 0; crc <= 16'hFFFF;
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

        S_SIDE: begin
          wptr <= 0; slot <= 0; lcnt <= lead; lm <= lead_m;
          j <= 0; bk <= 0; ph <= 0; pd <= 0; mm <= 0; cur <= 8'h4E; mk <= 0;
          st <= img_mfm ? S_MFM : (bside && !img_ds) ? S_FILL : S_LEAD;
        end

        S_FILL: begin
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= 0;
          wptr <= wptr + 1'b1;
          if (wptr + 1'b1 == cells) st <= S_DONE;
        end

        S_LEAD: begin
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= (lm >= 4'd2);
          wptr <= wptr + 1'b1;
          lm <= (lm == 0) ? 4'd9 : lm - 1'b1;
          lcnt <= lcnt - 1'b1;
          if (lcnt == 8'd1) begin widx <= 0; st <= S_FETCH; end
        end

        S_FETCH: begin
          if (widx < 9'd6 && !img_tags) begin
            sb_we <= 1; sb_a <= widx; sb_d <= 16'h0000; widx <= widx + 1'b1;
          end else if (widx == 9'd262) begin
            g <= 0; ns <= 0; ci <= 0; ca <= 0; cb <= 0; cc <= 0;
            j <= 0; cur <= 8'h00; mk <= 0; mm <= 2'd1;
            st <= img_mfm ? S_MFM : S_NIB;
          end else if (mem_req) begin
            if (mem_ack) begin
              mem_req <= 0; sb_we <= 1; sb_a <= widx; sb_d <= mem_rdata; widx <= widx + 1'b1;
            end
          end else if (!mem_ack) begin
            mem_req  <= 1;
            mem_addr <= (widx < 9'd6) ? tag_base + {15'd0, widx}
                                       : BASE + {4'd0, fblk, 8'd0} + {15'd0, widx - 9'd6};
          end
        end

        S_NIB: begin
          ns <= ns + 1'b1;
          case (ns)
            4'd0: bidx <= {g, 1'b0} + {2'b00, g};
            4'd1: bidx <= bidx + 1'b1;
            4'd2: begin bidx <= bidx + 1'b1; A <= sbyte; end
            4'd3: B <= sbyte;
            4'd4: begin
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

        S_SUM: begin
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

        S_EMIT: begin
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr}; tb_d <= cur[7];
          wptr <= wptr + 1'b1;
          cur <= {cur[6:0], 1'b0};
          bk <= bk + 1'b1;
          cbuf_ra <= jn - 10'd69;
          if (bk == 3'd7) begin
            if (j == 10'd775) begin
              if (slot + 1'b1 == spt) begin
                if (bside) st <= S_DONE;
                else begin bside <= 1; st <= S_SIDE; end
              end else begin slot <= slot + 1'b1; widx <= 0; st <= S_FETCH; end
            end else begin
              j <= jn; cur <= nbyte;
              j6 <= (j6 == 3'd5) ? 3'd0 : j6 + 1'b1;
            end
          end
        end

        S_MFM: begin
          tb_we <= 1; tb_a <= wbase + {1'b0, wptr};
          wptr <= wptr + 1'b1;
          ph <= !ph;
          bidx <= jn - 10'd48;
          if (!ph)
            tb_d <= !pd && !cur[7] && !(mk && bk == 3'd5);
          else begin
            tb_d <= cur[7]; pd <= cur[7]; crc <= crc_nx;
            cur <= {cur[6:0], 1'b0};
            bk <= bk + 1'b1;
            if (bk == 3'd7)
              case (mm)
                2'd0:
                  if (j == 10'd31) begin widx <= 9'd6; st <= S_FETCH; end
                  else begin j <= jn; cur <= 8'h4E; end
                2'd1:
                  if (j == mlast) begin
                    if (slot + 1'b1 == mspt) begin mm <= 2'd2; cur <= 8'h4E; mk <= 0; end
                    else begin slot <= slot + 1'b1; widx <= 9'd6; st <= S_FETCH; end
                  end else begin
                    j <= jn; cur <= mbyte; mk <= mbmark;
                    if (jn == 10'd12 || jn == 10'd56) crc <= 16'hFFFF;
                  end
                default:
                  if (mlastcell) begin
                    if (bside) st <= S_DONE;
                    else begin bside <= 1; st <= S_SIDE; end
                  end else cur <= 8'h4E;
              endcase
          end
        end

        S_DONE: begin
          trk_valid <= 1; trk_cyl <= c; st <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

  assign enc_idle = (st == S_IDLE);
  assign dbg = {trk_valid, bside, st, slot[3:0], c[5:0]};

endmodule
