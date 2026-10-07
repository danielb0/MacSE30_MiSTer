// se30_swim.v - Apple's SWIM floppy controller (IWM and ISM modes)

`timescale 1ns/1ps

module se30_swim #(
  parameter     MFM_WRITE = 1
) (
  input         clk,
  input         c16_en,
  input         reset_n,

  input         sel,
  input         strobe,
  input   [3:0] rs,
  input   [7:0] wdata,
  output  [7:0] rdata,

  output  [3:0] ph_out,
  output  [3:0] ph_oe,
  input   [3:0] ph_in,
  output        enbl1_n,
  output        enbl2_n,
  input         sense,
  output        wrdata,
  output        wrreq_n,
  output        hdsel,

  output [47:0] dbg,
  output        dbg_vread
);

  localparam [24:0] IWM_TIMER = 25'd8388708;

  reg        ism;
  reg  [3:0] ph_lvl;
  reg  [3:0] ph_dir;
  reg        motor, drvsel, l6, l7;
  reg  [4:0] iwm_mode;
  reg        iwm_test;
  reg [24:0] timer;
  reg  [2:0] iwm_cfg;
  reg  [1:0] sw_cnt;
  reg  [7:0] rd_latch;
  reg  [7:0] sr;
  reg  [7:0] ism_mode;
  reg  [7:0] ism_setup, ism_error;
  reg  [7:0] param [0:15];
  reg  [3:0] pidx;
  reg        corr_sel;

  reg  [7:0] wbuf;
  reg        wempty;
  reg        unr_n;
  reg  [7:0] wsr;
  reg  [7:0] wsr_last;
  reg  [2:0] wbits;
  reg  [4:0] wcnt;
  reg  [3:0] wlock;
  reg        wload;
  reg        wrd;

  wire       hit = c16_en && sel && strobe;

  wire [2:0] k = rs[3:1];
  wire       v = rs[0];
  wire [3:0] ph_n     = (k[2] == 1'b0) ? ((ph_lvl & ~(4'b1 << k[1:0])) | ({3'b0, v} << k[1:0])) : ph_lvl;
  wire       motor_n  = (k == 3'd4) ? v : motor;
  wire       drvsel_n = (k == 3'd5) ? v : drvsel;
  wire       l6_n     = (k == 3'd6) ? v : l6;
  wire       l7_n     = (k == 3'd7) ? v : l7;
  wire       t_start  = motor && !motor_n && !iwm_mode[2];
  wire       t_kill   = iwm_cfg[2] && !motor_n && (drvsel_n != drvsel);
  wire       motor_d  = motor || (timer != 0);
  wire       motor_dn = motor_n || (!t_kill && (t_start || timer != 0));
  wire       iwm_wr   = l6_n && l7_n && v;
  wire       mode_wr  = iwm_wr && !motor_dn;

  wire [7:0] rd_val;
  reg  [7:0] iwm_q;
  always @* begin
    case ({l7_n, l6_n})
      2'b00: iwm_q = motor_dn ? rd_val : 8'hFF;
      2'b01: iwm_q = {sense, 1'b0, motor_dn, iwm_mode};
      2'b10: iwm_q = {wempty, unr_n, 6'h3F};
      2'b11: iwm_q = 8'hFF;
    endcase
  end

  wire       fast    = iwm_mode[3];
  wire       m8      = iwm_mode[4];
  wire       async_m = iwm_mode[1];
  reg        cdiv;
  wire       clk_en  = c16_en && (fast || cdiv);
  wire [6:0] blank   = m8 ? 7'd6  : 7'd5;
  wire [6:0] first0  = m8 ? 7'd24 : 7'd21;
  wire [6:0] win     = m8 ? 7'd16 : 7'd14;
  wire       rstate  = !ism && !l6 && !l7;
  reg        rd_s;
  reg  [6:0] ncl;
  reg  [6:0] nb;
  wire       fall    = rd_s && !sense;
  wire       take    = rstate && clk_en && fall && ncl >= blank;
  wire       bound   = rstate && clk_en && nb == 7'd1;
  wire [8:0] sh0     = {sr, 1'b0};
  wire       lat0    = bound && sh0[7];
  wire [7:0] sr0     = !bound ? sr : (lat0 ? 8'h00 : sh0[7:0]);
  wire [7:0] sh1     = {sr0[6:0], 1'b1};
  wire       lat1    = take && sh1[7];
  wire [7:0] sr_n    = !take ? sr0 : (lat1 ? 8'h00 : sh1);
  reg  [3:0] clr_cnt;
  reg  [6:0] stall;
  reg  [7:0] stall_v;
  assign     rd_val  = async_m ? rd_latch : (stall != 0 ? stall_v : sr);
  wire       rd_sel  = !ism && !l7_n && !l6_n && motor_dn;
  wire       vread   = hit && rd_sel && async_m && rd_latch[7];

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      cdiv <= 0; rd_s <= 1; ncl <= 7'h7F; nb <= 0; sr <= 0; rd_latch <= 0;
      clr_cnt <= 0; stall <= 0; stall_v <= 0;
    end else begin
      if (c16_en) cdiv <= !cdiv;
      if (clk_en) begin
        rd_s <= sense;
        if (take) begin ncl <= 0; nb <= first0; end
        else begin
          if (ncl != 7'h7F) ncl <= ncl + 1'b1;
          if (rstate) nb <= (nb <= 7'd1) ? win : nb - 1'b1;
        end
        if (stall != 0) stall <= stall - 1'b1;
      end
      sr <= sr_n;
      if (lat0 || lat1) begin
        rd_latch <= lat1 ? sh1 : sh0[7:0];
        stall_v  <= lat1 ? sh1 : sh0[7:0];
        stall    <= {win[5:0], 1'b0} + 7'd4;
        clr_cnt  <= 0;
      end else begin
        if (vread) clr_cnt <= 4'd14;
        else if (c16_en && clr_cnt != 0) begin
          clr_cnt <= clr_cnt - 1'b1;
          if (clr_cnt == 4'd1) rd_latch <= 8'h00;
        end
      end
    end
  end

  wire [4:0] wcell = m8 ? 5'd16 : 5'd14;
  wire       wdreg = hit && !ism && iwm_wr && motor_dn;
  wire       wact  = !ism && l7 && motor_d;
  wire       wload_now = wact && clk_en && wcnt == 5'd1 && wbits == 0;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wbuf <= 0; wempty <= 1; unr_n <= 1; wsr <= 0; wsr_last <= 0;
      wbits <= 0; wcnt <= 0; wlock <= 0; wload <= 0; wrd <= 0;
    end else begin
      wload <= 0;
      if (c16_en && wlock != 0) wlock <= wlock - 1'b1;
      if (!l7) begin unr_n <= 1; if (!wdreg) wempty <= 1; end

      if (wdreg && wlock == 0 && !wload_now) begin wbuf <= wdata; wempty <= 0; end

      if (!wact) begin
        wcnt <= 5'd7; wbits <= 0;
      end else if (clk_en) begin
        if (wcnt != 5'd1) wcnt <= wcnt - 1'b1;
        else begin
          wcnt <= wcell;
          if (wbits == 0) begin
            wload <= 1; wlock <= 4'd9; wempty <= 1; wbits <= 3'd7;
            if (wempty) begin unr_n <= 0; wsr <= 8'h00; wsr_last <= 8'h00; end
            else begin
              wsr <= {wbuf[6:0], 1'b0}; wsr_last <= wbuf;
              if (wbuf[7]) wrd <= !wrd;
            end
          end else begin
            wbits <= wbits - 1'b1;
            wsr <= {wsr[6:0], 1'b0};
            if (wsr[7]) wrd <= !wrd;
          end
        end
      end
    end
  end

  reg   [7:0] f_b0, f_b1;
  reg         f_m0, f_m1, f_c0, f_c1;
  reg   [1:0] f_n;
  reg  [15:0] rcrc;
  wire [3:0] ph_rd  = (ph_dir & ph_lvl) | (~ph_dir & ph_in);
  wire       fifo_w = ism_mode[4];
  reg  [7:0] ism_q;
  always @* begin
    case (rs)
      4'd8:  ism_q = ism_mode[3] ? f_b0 : 8'h00;
      4'd9:  ism_q = f_b0;
      4'd10: ism_q = ism_error;
      4'd11: ism_q = param[pidx];
      4'd12: ism_q = {ph_dir, ph_rd};
      4'd13: ism_q = ism_setup;
      4'd14: ism_q = ism_mode | 8'h40;
      4'd15: ism_q = fifo_w ? {f_n != 2'd2 || |ism_error, f_n == 2'd0 || |ism_error, |ism_error,
                               ism_mode[7], sense, sense, 2'b00}
                            : {f_n != 0, f_n == 2'd2, |ism_error, ism_mode[7], sense, sense,
                               (f_n != 0) ? !f_c0 : (rcrc != 16'h0000), (f_n != 0) && f_m0};
      default: ism_q = 8'hFF;
    endcase
  end

  assign rdata = ism ? ism_q : iwm_q;

  wire        ism_rd   = ism && !ism_mode[4];
  wire        ism_act  = ism_rd && ism_mode[3];
  reg         rdd_s;
  wire        ism_tr     = c16_en && (ism_setup[5] ? (sense && !rdd_s) : (sense != rdd_s));
  reg  [11:0] tc;
  reg         have_t;
  reg         prev_l;
  reg         wide_done;
  wire [11:0] ivl = tc + 12'd2;
  wire [11:0] bnd1 = {4'd0, param[0]} + 12'd6;
  wire [11:0] bnd2 = bnd1 + {4'd0, prev_l ? param[8]  : param[2]} + 12'd4;
  wire [11:0] bnd3 = bnd2 + {4'd0, prev_l ? param[10] : param[4]} + 12'd4;
  wire [11:0] bnd4 = bnd3 + {4'd0, param[6]} + 12'd4;
  wire  [2:0] ccls = (ivl < bnd1) ? 3'd0 : (ivl < bnd2) ? 3'd2 : (ivl < bnd3) ? 3'd3 : 3'd4;
  wire        cell_ok  = ism_act && have_t && ism_tr && !wide_done && ivl < bnd4;
  wire        wide_now = ism_act && have_t && !wide_done && c16_en && ivl >= bnd4;

  localparam [2:0] C_IDLE = 3'd0, C_SYNC = 3'd1, C_WAIT = 3'd2, C_MARK = 3'd3, C_LOCK = 3'd4;
  reg   [2:0] csm;
  reg   [5:0] nmin;
  reg         ref_d;
  reg   [7:0] asr;
  reg   [3:0] acnt;
  reg         amark;

  wire        is_mark = (ccls == 3'd4) && !ref_d;
  wire  [1:0] dbits   = (ccls == 3'd2) ? {ref_d, 1'b0} :
                        (ccls == 3'd3) ? (ref_d ? 2'b00 : {1'b1, 1'b0}) :
                                         (ref_d ? 2'b01 : 2'b00);
  wire        dtwo    = (ccls == 3'd2) ? 1'b0 : (ccls == 3'd3) ? ref_d : 1'b1;
  wire        ref_n   = (ccls == 3'd2) ? ref_d : (ccls == 3'd3) ? !ref_d : ref_d;

  wire        rd_data  = hit && ism && rs == 4'd8 && ism_mode[3] && !ism_mode[4];
  wire        rd_mark  = hit && ism && rs == 4'd9 && !ism_mode[4];
  wire        f_pop    = (rd_data || rd_mark) && f_n != 0;

  function [15:0] crc1(input [15:0] c, input d);
    crc1 = {c[14:0], 1'b0} ^ ((c[15] ^ d) ? 16'h1021 : 16'h0000);
  endfunction

  reg   [7:0] n_asr, done_b;
  reg   [3:0] n_acnt;
  reg  [15:0] n_crc;
  reg         n_amark, done, done_m, done_c;
  integer     bi;
  always @* begin
    n_asr = asr; n_acnt = acnt; n_crc = rcrc; n_amark = amark || is_mark;
    done = 1'b0; done_b = 8'h00; done_m = 1'b0; done_c = 1'b0;
    for (bi = 1; bi >= 0; bi = bi - 1)
      if (bi == 1 || dtwo) begin
        n_asr = {n_asr[6:0], dbits[bi]};
        n_crc = crc1(n_crc, dbits[bi]);
        n_acnt = n_acnt + 1'b1;
        if (n_acnt == 4'd8) begin
          done = 1'b1; done_b = n_asr; done_m = n_amark; done_c = (n_crc == 16'h0000);
          n_acnt = 4'd0; n_amark = 1'b0;
        end
      end
  end

  wire        f_push  = cell_ok && ccls != 3'd0 && done && !ism_mode[0] &&
                        (csm == C_LOCK || (csm == C_MARK && is_mark));

  wire        iw_on   = MFM_WRITE && ism && ism_mode[4] && ism_mode[3];
  wire        w_push  = MFM_WRITE && hit && ism && ism_mode[4] && !rs[3] && !ism_mode[0] &&
                        (rs[2:0] == 3'd0 || rs[2:0] == 3'd1 || (rs[2:0] == 3'd2 && ism_mode[3]));
  wire        w_mk    = (rs[2:0] == 3'd1);
  wire        w_crc   = (rs[2:0] == 3'd2);
  wire        iw_go   = MFM_WRITE && hit && ism && !rs[3] && rs[2:0] == 3'd7 && wdata[3] &&
                        !ism_mode[3] && (ism_mode[4] || wdata[4]);
  reg  [15:0] wsr16;
  reg   [4:0] wn;
  reg         wisc, wmk, wpmk;
  reg  [15:0] wcrc;
  reg         wh2, wh1, wcur, wnxt, wmk_c, wmk_n;
  reg         wtok, wtok2, wtok2v;
  reg   [9:0] tcnt;
  reg         wrd_m;
  reg   [2:0] wpul;
  wire  [9:0] tcnt_n  = tcnt - 10'd2;
  wire        tk_end  = iw_on && c16_en && $signed(tcnt_n) <= 0;
  wire        need_b  = tk_end && !wtok2;
  wire        w_need  = (need_b && wn == 0) || iw_go;
  wire        w_in    = w_need && f_n != 0;
  wire        w_unr   = w_need && f_n == 0;
  wire        in_crc  = f_c0 && !iw_go;
  wire        wb      = (wn != 0) ? wsr16[15] : (in_crc ? wcrc[15] : f_b0[7]);
  wire        wb_mk   = (wn != 0) ? wmk : (!in_crc && f_m0);
  wire        wb_isc  = (wn != 0) ? wisc : in_crc;
  wire [15:0] crc_b0  = (wn == 0 && !in_crc && f_m0 && !wpmk) ? 16'hFFFF : wcrc;
  function [2:0] tks(input h2, input h1, input c, input n, input mk);
    if (mk && h2 && !h1 && !c && !n) tks = 3'b010;
    else case ({c, n})
      2'b00:   tks = 3'b100;
      2'b01:   tks = 3'b011;
      2'b10:   tks = 3'b000;
      default: tks = 3'b100;
    endcase
  endfunction
  wire  [9:0] dur1 = {2'b00, param[15]} + 10'd4;
  wire  [9:0] dur0 = {2'b00, param[13]} + 10'd4;
  wire        a_c  = iw_go ? f_b0[7] : wnxt;
  wire        a_n  = iw_go ? f_b0[6] : wb;
  wire  [2:0] a_t  = iw_go ? tks(1'b0, 1'b0, f_b0[7], f_b0[6], f_m0) : tks(wh1, wcur, wnxt, wb, wmk_n);
  wire        w_tog = tk_end && wtok;
  wire  [7:0] rc_err  = {2'b00,
                         wide_now,
                         cell_ok && ccls == 3'd0,
                         1'b0,
                         (rd_data || rd_mark) && f_n == 0,
                         rd_data && f_n != 0 && f_m0,
                         f_push && f_n == 2'd2 && !f_pop};
  wire  [7:0] wc_err  = {5'b00000,
                         w_push && f_n == 2'd2 && !w_in,
                         1'b0,
                         w_unr};
  wire  [7:0] all_err = rc_err | wc_err;
  wire        fp   = f_push || w_push;
  wire        fo   = f_pop  || w_in;
  wire  [7:0] fd_b = w_push ? wdata : done_b;
  wire        fd_m = w_push ? w_mk  : done_m;
  wire        fd_c = w_push ? w_crc : done_c;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wsr16 <= 0; wn <= 0; wisc <= 0; wmk <= 0; wpmk <= 0; wcrc <= 16'hFFFF;
      wh2 <= 0; wh1 <= 0; wcur <= 0; wnxt <= 0; wmk_c <= 0; wmk_n <= 0;
      wtok <= 0; wtok2 <= 0; wtok2v <= 0; tcnt <= 0; wrd_m <= 0; wpul <= 0;
    end else begin
      if (c16_en && wpul != 0) wpul <= wpul - 1'b1;
      if (w_tog) begin wrd_m <= !wrd_m; wpul <= 3'd4; end

      if (iw_go) begin
        wh2 <= 0; wh1 <= 0; wcur <= f_b0[7]; wnxt <= f_b0[6]; wmk_c <= f_m0; wmk_n <= f_m0;
        wsr16 <= {f_b0[5:0], 10'd0}; wn <= 5'd6; wisc <= 0; wmk <= f_m0; wpmk <= f_m0;
        wcrc <= crc1(crc1((f_m0 && !wpmk) ? 16'hFFFF : wcrc, f_b0[7]), f_b0[6]);
        wtok <= a_t[2]; wtok2 <= a_t[1]; wtok2v <= a_t[0];
        tcnt <= a_t[2] ? dur1 : dur0;
      end else if (!iw_on) begin
        wtok <= 0; wtok2 <= 0; wn <= 0;
      end else if (c16_en) begin
        if (!tk_end) tcnt <= tcnt_n;
        else if (wtok2) begin
          wtok <= wtok2v; wtok2 <= 0;
          tcnt <= tcnt_n + (wtok2v ? dur1 : dur0);
        end else begin
          wh2 <= wh1; wh1 <= wcur; wcur <= wnxt; wnxt <= wb; wmk_c <= wmk_n; wmk_n <= wb_mk;
          if (!wb_isc) wcrc <= crc1(crc_b0, wb);
          if (wn != 0) begin wsr16 <= {wsr16[14:0], 1'b0}; wn <= wn - 1'b1; end
          else if (f_n != 0) begin
            wisc <= in_crc; wmk <= !in_crc && f_m0; wpmk <= !in_crc && f_m0;
            wsr16 <= in_crc ? {wcrc[14:0], 1'b0} : {f_b0[6:0], 9'd0};
            wn <= in_crc ? 5'd15 : 5'd7;
          end
          wtok <= a_t[2]; wtok2 <= a_t[1]; wtok2v <= a_t[0];
          tcnt <= tcnt_n + (a_t[2] ? dur1 : dur0);
        end
      end
    end
  end

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      rdd_s <= 1; tc <= 0; have_t <= 0; prev_l <= 0; wide_done <= 0;
      csm <= C_IDLE; nmin <= 0; ref_d <= 0; asr <= 0; acnt <= 0; amark <= 0; rcrc <= 16'hFFFF;
      f_b0 <= 0; f_b1 <= 0; f_m0 <= 0; f_m1 <= 0; f_c0 <= 0; f_c1 <= 0; f_n <= 0;
    end else begin
      if (c16_en) rdd_s <= sense;
      if (c16_en) tc <= ism_tr ? 12'd0 : (tc[11] ? tc : tc + 12'd2);

      if (!ism_act) begin
        csm <= C_IDLE; have_t <= 0; wide_done <= 0; acnt <= 0; amark <= 0;
      end else begin
        if (wide_now) begin
          wide_done <= 1;
          if (csm != C_LOCK) begin csm <= C_SYNC; nmin <= 0; end
        end
        if (ism_tr) begin
          have_t <= 1; wide_done <= 0;
          if (csm == C_IDLE) begin csm <= C_SYNC; nmin <= 0; ref_d <= 0; prev_l <= 0; end
        end
        if (cell_ok) begin
          prev_l <= (ccls != 3'd2);
          if (ccls == 3'd0) begin
            if (csm != C_LOCK) begin csm <= C_SYNC; nmin <= 0; end
          end else case (csm)
            C_SYNC:
              if (ccls == 3'd2) begin
                if (nmin == 6'd63) csm <= C_WAIT; else nmin <= nmin + 1'b1;
              end else nmin <= 0;
            C_WAIT:
              if (ccls == 3'd3) begin
                asr <= 8'h01; acnt <= 4'd1; amark <= 0; rcrc <= crc1(16'hFFFF, 1'b1);
                ref_d <= 1; csm <= C_MARK;
              end else if (ccls != 3'd2) begin csm <= C_SYNC; nmin <= 0; end
            C_MARK: begin
              asr <= n_asr; acnt <= n_acnt; amark <= n_amark; rcrc <= n_crc; ref_d <= ref_n;
              if (is_mark) csm <= C_LOCK;
              else if (done) begin csm <= C_SYNC; nmin <= 0; end
            end
            C_LOCK: begin
              asr <= n_asr; acnt <= n_acnt; amark <= n_amark; rcrc <= n_crc; ref_d <= ref_n;
            end
            default: ;
          endcase
        end
      end

      if (ism_mode[0]) begin
        f_n <= 0; rcrc <= 16'hFFFF;
      end else begin
        if (fo) begin f_b0 <= f_b1; f_m0 <= f_m1; f_c0 <= f_c1; end
        if (fp) begin
          if (f_n == 2'd2 && !fo) ;
          else if ((f_n == 2'd0) || (f_n == 2'd1 && fo)) begin
            f_b0 <= fd_b; f_m0 <= fd_m; f_c0 <= fd_c;
            f_n <= fo ? f_n : f_n + 1'b1;
          end else begin
            f_b1 <= fd_b; f_m1 <= fd_m; f_c1 <= fd_c;
            f_n <= fo ? f_n : f_n + 1'b1;
          end
        end else if (fo) f_n <= f_n - 1'b1;
      end
    end
  end

  integer i;
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      ism <= 0; ph_lvl <= 4'h0; ph_dir <= 4'hF;
      motor <= 0; drvsel <= 0; l6 <= 0; l7 <= 0;
      iwm_mode <= 0; iwm_test <= 0; timer <= 0; iwm_cfg <= 0; sw_cnt <= 0;
      ism_mode <= 0; ism_setup <= 0; ism_error <= 0; pidx <= 0; corr_sel <= 0;
    end else begin
      if (c16_en && timer != 0) timer <= timer - 1'b1;
      if (all_err != 0 && ism_error == 0) ism_error <= all_err;

      if (hit && !ism) begin
        ph_lvl <= ph_n; motor <= motor_n; drvsel <= drvsel_n; l6 <= l6_n; l7 <= l7_n;
        if (motor_n || t_kill) timer <= 0;
        else if (t_start)      timer <= iwm_cfg[1] ? {IWM_TIMER[23:0], 1'b0} : IWM_TIMER;
        if (mode_wr) begin
          iwm_mode <= wdata[4:0]; iwm_test <= wdata[5];
          if (wdata[6] == (sw_cnt != 2'd1)) begin
            if (sw_cnt == 2'd3) begin ism <= 1; sw_cnt <= 0; end
            else sw_cnt <= sw_cnt + 1'b1;
          end else
            sw_cnt <= {1'b0, wdata[6]};
        end
      end

      if (hit && ism) begin
        if (!rs[3]) case (rs[2:0])
          3'd2: if (!ism_mode[3]) iwm_cfg <= wdata[7:5];
          3'd3: begin param[pidx] <= wdata; pidx <= pidx + 1'b1; end
          3'd4: begin ph_dir <= wdata[7:4]; ph_lvl <= wdata[3:0]; end
          3'd5: ism_setup <= wdata;
          3'd6: begin
            ism_mode <= ism_mode & ~wdata & 8'hBF;
            pidx <= 0;
            if (wdata[6] && !(ism_mode[7] && !wdata[7])) ism <= 0;
          end
          3'd7: ism_mode <= (ism_mode | wdata) & 8'hBF;
          default: ;
        endcase
        else case (rs[2:0])
          3'd0: if (!ism_mode[3]) corr_sel <= !corr_sel;
          3'd2: ism_error <= all_err;
          3'd3: pidx <= pidx + 1'b1;
          default: ;
        endcase
      end
      if (wc_err != 0) ism_mode[3] <= 1'b0;
    end
  end

  assign ph_out  = ph_lvl;
  assign ph_oe   = ph_dir;
  assign enbl1_n = ism ? !(ism_mode[7] && ism_mode[1]) : !(motor_d && !drvsel);
  assign enbl2_n = ism ? !(ism_mode[7] && ism_mode[2]) : !(motor_d &&  drvsel);
  assign wrdata  = ism ? (ism_setup[5] ? (wpul == 0) : wrd_m) : wrd;
  assign wrreq_n = ism ? !iw_on : !(wact && unr_n);
  assign hdsel   = ism_setup[0] && ism_mode[5];

  assign dbg_vread = vread;
  assign dbg = {ism, l7, l6, drvsel, motor, ph_lvl, iwm_mode, motor_d, enbl1_n, enbl2_n, sense,
                iwm_test, sw_cnt, ism_mode | (ism ? 8'h40 : 8'h00), ism_setup, ph_dir, iwm_cfg, 4'b0};

endmodule
