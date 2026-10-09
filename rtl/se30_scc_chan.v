// se30_scc_chan.v - one channel of the Zilog 8530 SCC, to Zilog's 1986 technical manual:
// async, mono/bisync, external-sync and SDLC, NRZ/NRZI/FM, the baud-rate generator, DPLL and CRC.

`timescale 1ns/1ps

module se30_scc_chan (
  input            clk,
  input            hw_reset,           // hardware reset: Fig 3-8's hardware column
  input            ch_reset,           // channel reset (one clock): the channel column
  input            pclk,               // one clk per PCLK

  // pins, as levels (already synchronised)
  input            rtxc,
  input            trxc,
  input            rxd,
  input            cts_n,
  input            dcd_n,
  input            sync_n,
  output           txd,
  output           rts_n,
  output           dtr_req_n,
  output           w_req_n,

  // the bus side (rtl/se30_scc.v decodes the pointer)
  input            wr,                 // a write to WR[wreg] (1, 3-7, 10-15)
  input      [3:0] wreg,
  input      [7:0] wval,
  input            cmd,                // a WR0 write: its command fields are wval
  input            dwr,                // a data write (WR8)
  input            drd,                // a data read (RR8): pops the FIFO
  output     [7:0] rr0,
  output     [7:0] rr1,
  output     [7:0] rr10,
  output     [7:0] rr12,
  output     [7:0] rr13,
  output     [7:0] rr15,
  output     [7:0] rdata,              // RR8: the FIFO's top, or the last character when empty

  // interrupts pending, gated by their enables
  output           ip_rx,              // a receive character or a special condition
  output           ip_sp,              // ... a special condition (RR2's status)
  output           ip_tx,
  output           ip_ext
);

  // =================================================================
  // registers
  reg  [7:0] wr1, wr3, wr4, wr5, wr6, wr7, wr10, wr11, wr12, wr13, wr15;
  reg  [4:0] wr14;                     // D4-D0 (D7-D5 are commands)

  wire       async   = (wr4[3:2] != 2'b00);
  wire       sdlc    = !async && (wr4[5:4] == 2'b10);
  wire       mono    = !async && (wr4[5:4] == 2'b00);
  wire       bisync  = !async && (wr4[5:4] == 2'b01);
  wire       extsync = !async && (wr4[5:4] == 2'b11);
  wire [1:0] enc     = wr10[6:5];      // 00 NRZ, 01 NRZI, 10 FM1, 11 FM0
  wire       aecho   = wr14[3];
  wire       loopbk  = wr14[4] && !aecho;   // both set: Auto Echo wins
  wire       cts     = !cts_n;         // RR0 reads the pins inverted
  wire       dcd     = !dcd_n;
  wire       autoen  = wr3[5];

  // the clock factor: asynchronous only, sync modes force x1
  wire [6:0] factor  = !async ? 7'd1 : (wr4[7:6] == 2'd0) ? 7'd1 : (wr4[7:6] == 2'd1) ? 7'd16 :
                       (wr4[7:6] == 2'd2) ? 7'd32 : 7'd64;
  // receive bits/char: 00 = 5, 01 = 7, 10 = 6, 11 = 8 (Table 7-2)
  wire [3:0] rbits   = (wr3[7:6] == 2'd0) ? 4'd5 : (wr3[7:6] == 2'd1) ? 4'd7 : (wr3[7:6] == 2'd2) ? 4'd6 : 4'd8;

  function [15:0] crc_bit (input [15:0] c, input bi, input crc16);
    // bit-serial, least significant bit first
    crc_bit = (c >> 1) ^ ((c[0] ^ bi) ? (crc16 ? 16'hA001 : 16'h8408) : 16'h0000);
  endfunction
  wire [15:0] crc_pre = wr10[7] ? 16'hFFFF : 16'h0000;
  // the residue after an inverted check field, whatever the preset
  wire [15:0] crc_good = wr5[2] ? 16'hB001 : 16'hF0B8;

  // the five-or-less transmit format (Table 7-3)
  function [3:0] five_n (input [7:0] d);
    five_n = (d[7:4] == 4'b1111 && d[3:1] == 3'b000) ? 4'd1 :
             (d[7:5] == 3'b111  && d[4:2] == 3'b000) ? 4'd2 :
             (d[7:6] == 2'b11   && d[5:3] == 3'b000) ? 4'd3 :
             (d[7]   == 1'b1    && d[6:4] == 3'b000) ? 4'd4 : 4'd5;
  endfunction

  // =================================================================
  // the baud-rate generator: a 16-bit down counter; each output half-period is TC+2 source clocks
  reg         rtxc_q;
  reg  [16:0] brg_cnt;
  reg         brg_out, brg_run, brg_zc;
  wire        brg_tick = wr14[1] ? pclk : (rtxc && !rtxc_q);
  wire [16:0] brg_tc1  = {1'b0, wr13, wr12} + 17'd1;

  // =================================================================
  // the DPLL
  reg         dp_en, dp_fm, dp_brg, dp_search;
  reg   [4:0] dp_cnt;
  reg   [1:0] dp_adj, dp_padj;         // 01 lengthen, 10 shorten
  reg         dp_held, dp_line, dp_seen, dp_miss1;
  reg         rr10_one, rr10_two;
  reg         dp_src_q;
  wire        dp_src  = dp_brg ? brg_out : rtxc;
  wire        dp_rise = dp_en &&  dp_src && !dp_src_q;
  wire        dp_fall = dp_en && !dp_src &&  dp_src_q;
  wire  [5:0] dp_pos  = {dp_cnt, dp_rise};   // half counts: a rise ends a count's second half
  wire  [3:0] dpc     = dp_cnt[3:0];
  wire        dp_rx   = dp_fm ? (dpc >= 4'd4 && dpc <= 4'd11) : dp_cnt[4];
  wire        dp_tx   = dp_fm ? dp_cnt[3] : dp_cnt[4];

  // =================================================================
  // clock selection (WR11) and the internal edges
  wire rx_int = (wr11[6:5] == 2'd0) ? !rtxc : (wr11[6:5] == 2'd1) ? !trxc :
                (wr11[6:5] == 2'd2) ? !brg_out : dp_rx;
  wire tx_int = (wr11[4:3] == 2'd0) ?  rtxc : (wr11[4:3] == 2'd1) ?  trxc :
                (wr11[4:3] == 2'd2) ?  brg_out : dp_tx;
  reg  rx_int_q, tx_int_q;
  wire rx_s    = !rx_int &&  rx_int_q; // the sample (NRZ, NRZI, async); FM's 3/4 sample
  wire rx_q1   =  rx_int && !rx_int_q; // FM's 1/4 sample
  wire tx_cell = !tx_int &&  tx_int_q; // a bit cell begins
  wire tx_mid  =  tx_int && !tx_int_q; // FM's mid-cell

  // =================================================================
  // transmitter
  reg  [7:0] tbuf;
  reg        tfull;                    // the transmit buffer holds a character
  reg        tx_ip;
  reg        eom;                      // the Tx Underrun/EOM latch (RR0 D6)
  reg        crc_act;                  // the frame's end (CRC, or an underrun's abort) is going out
  reg [15:0] crc_tx;
  reg        tline;                    // the encoder's output level
  reg        tbit;                     // the current cell's bit (FM's mid-cell)
  reg        req_pulse;                // /W//REQ and /DTR//REQ high for a PCLK after the CRC
  reg        abort_req;
  reg        txen_q;
  reg        rts_hold;                 // async Auto Enables: /RTS held low until all sent
  // synchronous
  reg [15:0] ts_sr;
  reg  [4:0] ts_n;                     // bits left in the shift register
  reg  [2:0] ts_kind;
  localparam K_MARK = 3'd0, K_FILL = 3'd1, K_DATA = 3'd2, K_CRC = 3'd3, K_ABORT = 3'd4;
  reg  [2:0] ts_ones;
  reg        ts_stuff;
  reg        ts_crcin;                 // this data character goes into the CRC (WR5 D0 at its load)
  // asynchronous
  reg        at_busy, at_stopping;
  reg  [9:0] at_sr;                    // the bits after the start bit: data, then parity
  reg  [3:0] at_bits;
  reg  [7:0] at_tick, at_len;
  reg        at_line;

  // =================================================================
  // receiver: a three-character FIFO with status, plus the character waiting in the shift register
  reg  [7:0] fd0, fd1, fd2, fdh;
  reg  [3:0] fs0, fs1, fs2, fsh;       // {EOF, CRC/framing, overrun, parity}
  reg  [1:0] fcnt;
  reg        fhold;
  reg  [7:0] rlast;                    // RR8 of an empty FIFO: "you read the last character"
  reg        ovr_l, par_l;             // RR1's latched errors
  reg  [2:0] residue;
  reg        first_arm;                // Rx Int on First Character: armed
  reg        rx_req_hold;              // /W//REQ (Rx) high after a locked character is read
  reg        hunt;                     // RR0 D4 in the synchronous modes
  reg        brk;                      // RR0 D7: Break (async), Abort (SDLC)
  reg        fm_s1, nrzi_prev;
  // asynchronous
  reg  [2:0] ar_st;
  localparam AR_IDLE = 3'd0, AR_START = 3'd1, AR_DATA = 3'd2, AR_FEWAIT = 3'd3, AR_BREAK = 3'd4;
  reg  [6:0] ar_cnt;
  reg  [3:0] ar_n;
  reg  [8:0] ar_sh;
  // synchronous and SDLC
  reg [15:0] rs_win;                   // the last 16 bits: the sync hunt
  reg  [7:0] rsr;                      // the character being assembled
  reg  [3:0] rcnt;
  reg  [2:0] r_ones;
  reg  [7:0] pq;                       // SDLC: the eight-bit queue (header)
  reg  [3:0] pq_n;
  reg        in_frame, frame_ok, addr_next, frame_data;
  reg [15:0] crc_rx;
  reg        rcrc_on;                  // sync modes: Rx CRC enable as taken at the character
  // SDLC Loop and X.21
  reg        on_loop, loop_send, loop_d, x21_go;
  reg  [2:0] loop_ones;

  // =================================================================
  // External/Status
  reg        ext_closed;
  reg  [5:0] ext_lat;                  // {brk, eom, cts, sync, dcd, zc}
  reg  [5:0] ext_q;
  reg        brk_pend, eom_pend;
  wire       zc_live   = wr15[1] && brg_zc;
  wire       sync_live = async   ? (!sync_n && !wr11[7]) :
                         extsync ? !sync_n : hunt;
  wire [5:0] ext_live  = {brk, eom, cts, sync_live, dcd, zc_live};
  wire [5:0] ext_ie    = {wr15[7], wr15[6], wr15[5], wr15[4], wr15[3], wr15[1]};
  wire [5:0] ext_view  = ext_closed ? ((ext_lat & ext_ie) | (ext_live & ~ext_ie)) : ext_live;
  // qualifying transitions: Break/Abort, CTS, Sync/Hunt and DCD on either
  // edge; Tx Underrun/EOM and Zero Count on 0 -> 1 only
  wire [5:0] ext_chg   = ext_live ^ ext_q;
  wire [5:0] ext_qual  = {ext_chg[5], ext_live[4] & !ext_q[4], ext_chg[3:1], ext_live[0] & !ext_q[0]} & ext_ie;

  // =================================================================
  // status
  wire       txen     = wr5[3] && (!(autoen && async) || cts || loopbk || aecho) &&
                        !(!sdlc && !async && wr10[1] && !x21_go);
  wire       tbe      = !tfull && !crc_act;
  wire       allsent  = !async || (!tfull && !at_busy);
  wire       ravail   = (fcnt != 2'd0);
  wire [3:0] top_s    = ravail ? fs0 : 4'b0000;
  wire       rxen     = wr3[0] && (!autoen || dcd || loopbk);
  wire       rline    = loopbk ? tline : rxd;
  // a special receive condition at the top of the FIFO
  wire       sp_top   = ravail && (fs0[1] | (fs0[0] && wr1[2] && wr4[0]) |
                                   (async && fs0[2]) | (sdlc && fs0[3]));
  wire [1:0] rxmode   = wr1[4:3];
  wire       locked   = sp_top && (rxmode == 2'b01 || rxmode == 2'b11);

  assign rr0   = {ext_view[5], ext_view[4], ext_view[3], ext_view[2], ext_view[1], tbe, ext_view[0], ravail};
  assign rr1   = {top_s[3] & sdlc, top_s[2], top_s[1] | ovr_l, top_s[0] | par_l,
                  (async ? 3'b011 : residue), allsent};
  assign rr10  = {rr10_one, rr10_two, 1'b0, loop_send, 2'b00, on_loop, 1'b0};
  assign rr12  = wr12;
  assign rr13  = wr13;
  assign rr15  = {wr15[7:3], 1'b0, wr15[1], 1'b0};
  assign rdata = ravail ? fd0 : rlast;

  assign ip_tx  = tx_ip && wr1[1];
  assign ip_ext = ext_closed && wr1[0];
  assign ip_sp  = (rxmode != 2'b00) && sp_top;
  assign ip_rx  = ip_sp || (rxmode == 2'b01 && first_arm && ravail) || (rxmode == 2'b10 && ravail);

  // pins
  wire       loop_rep   = sdlc && on_loop && !loop_send;
  assign txd       = wr5[4] ? 1'b0 : aecho ? rxd : loop_rep ? loop_d : tline;
  assign rts_n     = !(wr5[1] || rts_hold);
  wire       tx_req_lvl = tbe && !req_pulse;
  assign dtr_req_n = wr14[2] ? !tx_req_lvl : !wr5[7];
  assign w_req_n   = !wr1[7] ? 1'b1 :
                     !wr1[6] ? 1'b1 :                  // Wait: low only during an access, which nothing else sees
                     wr1[5]  ? !(ravail && !rx_req_hold) : !tx_req_lvl;

  // =================================================================
  // the synchronous transmitter's next unit, when the shift register is empty
  wire [3:0]  tbits = (wr5[6:5] == 2'd0) ? five_n(tbuf) : (wr5[6:5] == 2'd1) ? 4'd7 :
                      (wr5[6:5] == 2'd2) ? 4'd6 : 4'd8;
  wire [15:0] fill_sr = sdlc ? (wr10[3] ? 16'h00FF : {8'h00, wr7}) : bisync ? {wr7, wr6} : {8'h00, wr6};
  wire [4:0]  fill_n  = (sdlc || !bisync) ? ((mono || extsync) && wr10[0] ? 5'd6 : 5'd8) : 5'd16;
  wire [2:0]  fill_k  = (sdlc && wr10[3]) ? K_MARK : K_FILL;
  reg  [2:0]  nx_kind;
  reg  [15:0] nx_sr;
  reg  [4:0]  nx_n;
  reg         nx_take, nx_under, nx_end;    // takes the buffer; an underrun; the frame's end is over
  // the CRC (or an abort) has left the shift register: the closing flag follows, the transmit IP sets
  wire        fr_end = crc_act && (ts_kind == K_CRC || ts_kind == K_ABORT);
  always @* begin
    nx_take = 1'b0; nx_under = 1'b0; nx_end = 1'b0;
    if (abort_req)        begin nx_kind = K_ABORT; nx_sr = 16'h00FF; nx_n = 5'd8; end
    else if (!txen)       begin nx_kind = K_MARK;  nx_sr = 16'h00FF; nx_n = 5'd8; end
    else if (fr_end)      begin nx_kind = K_FILL;  nx_sr = sdlc ? {8'h00, wr7} : bisync ? {wr7, wr6} : {8'h00, wr6};
                                nx_n = (sdlc || !bisync) ? ((mono || extsync) && wr10[0] ? 5'd6 : 5'd8) : 5'd16; nx_end = 1'b1; end
    else if (tfull)       begin nx_kind = K_DATA;  nx_sr = {8'h00, tbuf}; nx_n = {1'b0, tbits}; nx_take = 1'b1; end
    else if (!eom) begin
      nx_under = 1'b1;                                   // buffer and shift register empty
      if (sdlc && wr10[2])  begin nx_kind = K_ABORT; nx_sr = 16'h00FF; nx_n = 5'd8; end
      else if (wr5[0])      begin nx_kind = K_CRC;   nx_sr = sdlc ? ~crc_tx : crc_tx; nx_n = 5'd16; end
      else                  begin nx_kind = fill_k;  nx_sr = fill_sr; nx_n = fill_n; end
    end else begin
      nx_kind = fill_k; nx_sr = fill_sr; nx_n = fill_n;
    end
  end
  wire        ts_load = (ts_n == 5'd0) || abort_req;
  wire [2:0]  cu_kind = ts_load ? nx_kind : ts_kind;
  wire [15:0] cu_sr   = ts_load ? nx_sr   : ts_sr;
  wire [4:0]  cu_n    = ts_load ? nx_n    : ts_n;
  wire        cu_crc  = ts_load ? wr5[0]  : ts_crcin;
  wire        ts_bit  = ts_stuff ? 1'b0 : cu_sr[0];

  // the asynchronous transmitter's next level
  wire [7:0]  amask   = (8'd1 << tbits) - 8'd1;
  wire        apar    = ^(tbuf & amask) ^ !wr4[1];      // even when WR4 D1 = 1
  wire [7:0]  astop   = (wr4[3:2] == 2'b01) ? {1'b0, factor} :
                        (wr4[3:2] == 2'b10) ? ({1'b0, factor} + {2'b00, factor[6:1]}) : {factor, 1'b0};

  // =================================================================
  // the FIFO's push and pop, on next-state variables
  reg  [7:0] n_fd0, n_fd1, n_fd2, n_fdh;
  reg  [3:0] n_fs0, n_fs1, n_fs2, n_fsh;
  reg  [1:0] n_fcnt;
  reg        n_fhold;
  task push (input [7:0] d, input [3:0] s);
    begin
      if (n_fcnt == 2'd0)      begin n_fd0 = d; n_fs0 = s; n_fcnt = 2'd1; end
      else if (n_fcnt == 2'd1) begin n_fd1 = d; n_fs1 = s; n_fcnt = 2'd2; end
      else if (n_fcnt == 2'd2) begin n_fd2 = d; n_fs2 = s; n_fcnt = 2'd3; end
      else if (!n_fhold)       begin n_fdh = d; n_fsh = s; n_fhold = 1'b1; end
      else                     begin n_fdh = d; n_fsh = s | 4'b0010; end   // overrun
    end
  endtask
  task pop;
    begin
      if (n_fcnt != 2'd0) begin
        n_fd0 = n_fd1; n_fs0 = n_fs1; n_fd1 = n_fd2; n_fs1 = n_fs2;
        if (n_fhold) begin
          if (n_fcnt == 2'd3)      begin n_fd2 = n_fdh; n_fs2 = n_fsh; end
          else if (n_fcnt == 2'd2) begin n_fd1 = n_fdh; n_fs1 = n_fsh; end
          else                     begin n_fd0 = n_fdh; n_fs0 = n_fsh; end
          n_fhold = 1'b0;
        end else n_fcnt = n_fcnt - 2'd1;
      end
    end
  endtask

  // =================================================================
  // power-up contents: the FPGA configures them to 0; hw_reset then applies the reset values
  initial begin
    wr1 = 0; wr3 = 0; wr4 = 8'h04; wr5 = 0; wr6 = 0; wr7 = 0; wr10 = 0; wr11 = 8'h08;
    wr12 = 0; wr13 = 0; wr14 = 0; wr15 = 8'hF8;
    rtxc_q = 0; brg_cnt = 0; brg_out = 1; brg_run = 0; brg_zc = 1;
    dp_en = 0; dp_fm = 0; dp_brg = 0; dp_search = 1; dp_cnt = 16; dp_adj = 0; dp_padj = 0;
    dp_held = 0; dp_line = 1; dp_seen = 0; dp_miss1 = 0; rr10_one = 0; rr10_two = 0; dp_src_q = 0;
    rx_int_q = 0; tx_int_q = 0;
    tbuf = 0; tfull = 0; tx_ip = 0; eom = 1; crc_act = 0; crc_tx = 0; tline = 1; tbit = 1;
    req_pulse = 0; abort_req = 0; txen_q = 0; rts_hold = 0;
    ts_sr = 0; ts_n = 0; ts_kind = 0; ts_ones = 0; ts_stuff = 0; ts_crcin = 0;
    at_busy = 0; at_stopping = 0; at_sr = 0; at_bits = 0; at_tick = 0; at_len = 1; at_line = 1;
    fd0 = 0; fd1 = 0; fd2 = 0; fdh = 0; fs0 = 0; fs1 = 0; fs2 = 0; fsh = 0; fcnt = 0; fhold = 0;
    rlast = 0; ovr_l = 0; par_l = 0; residue = 3'b011; first_arm = 1; rx_req_hold = 0;
    hunt = 1; brk = 0; fm_s1 = 0; nrzi_prev = 1;
    ar_st = 0; ar_cnt = 0; ar_n = 0; ar_sh = 0;
    rs_win = 0; rsr = 0; rcnt = 0; r_ones = 0; pq = 0; pq_n = 0;
    in_frame = 0; frame_ok = 0; addr_next = 0; frame_data = 0; crc_rx = 0; rcrc_on = 0;
    on_loop = 0; loop_send = 0; loop_d = 1; x21_go = 0; loop_ones = 0;
    ext_closed = 0; ext_lat = 0; ext_q = 0; brk_pend = 0; eom_pend = 0;
  end

  integer    i;
  reg  [7:0] d8;
  reg        b, pe, rbit_v, rbit, pushq;
  reg  [3:0] nb;
  reg  [8:0] m9;

  always @(posedge clk) begin
    rtxc_q <= rtxc; rx_int_q <= rx_int; tx_int_q <= tx_int; dp_src_q <= dp_src;
    ext_q  <= ext_live;
    n_fd0 = fd0; n_fd1 = fd1; n_fd2 = fd2; n_fdh = fdh;
    n_fs0 = fs0; n_fs1 = fs1; n_fs2 = fs2; n_fsh = fsh;
    n_fcnt = fcnt; n_fhold = fhold;
    if (pclk) req_pulse <= 1'b0;

    // ---------------------------------------------------------- BRG
    if (!wr14[0]) brg_run <= 1'b0;
    else if (brg_tick) begin
      if (!brg_run) begin brg_run <= 1'b1; brg_cnt <= brg_tc1; brg_out <= 1'b1; end
      else if (brg_cnt == 17'd0) begin brg_out <= !brg_out; brg_cnt <= brg_tc1; end
      else brg_cnt <= brg_cnt - 17'd1;
    end
    if (brg_run) brg_zc <= (brg_cnt == 17'd1);           // the counter's zero; held while disabled

    // ---------------------------------------------------------- DPLL
    if (dp_rise || dp_fall) begin
      if (rxd != dp_line) begin
        if (dp_search) begin
          dp_search <= 1'b0;                              // the first edge is a cell boundary (count 15/16)
          dp_adj <= 2'b00; dp_padj <= 2'b00; dp_seen <= 1'b1;
        end else if (!dp_fm) begin
          if (dp_pos == 6'd31 || dp_pos == 6'd32) ;
          else if (dp_pos >= 6'd33) dp_padj <= 2'b01;
          else dp_padj <= 2'b10;
        end else begin
          if (dp_pos == 6'd31 || dp_pos == 6'd32) dp_seen <= 1'b1;
          else if (dp_pos >= 6'd33 && dp_pos <= 6'd38) begin dp_padj <= 2'b01; dp_seen <= 1'b1; end
          else if (dp_pos >= 6'd25 && dp_pos <= 6'd30) begin dp_padj <= 2'b10; dp_seen <= 1'b1; end
        end
      end
      dp_line <= rxd;
    end
    if (dp_rise && !dp_search) begin
      if (dp_cnt == 5'd5 && dp_adj == 2'b01 && !dp_held) dp_held <= 1'b1;    // count 5 doubled
      else if (dp_cnt == 5'd4 && dp_adj == 2'b10) dp_cnt <= 5'd6;           // count 5 deleted
      else dp_cnt <= dp_cnt + 5'd1;
      if (dp_cnt == 5'd31) begin dp_adj <= dp_padj; dp_padj <= 2'b00; dp_held <= 1'b0; end
      if (dp_fm && dp_cnt == 5'd2) begin                                     // the missing-clock decision
        if (!dp_seen) begin
          rr10_one <= 1'b1;
          if (dp_miss1) begin rr10_two <= 1'b1; dp_search <= 1'b1; dp_cnt <= 5'd16; end
          dp_miss1 <= 1'b1;
        end else dp_miss1 <= 1'b0;
        dp_seen <= 1'b0;
      end
    end

    // ---------------------------------------------------------- transmitter
    if (txen_q && !txen && !async) eom <= 1'b1;            // disabling the transmitter sets EOM
    txen_q <= txen;
    if (!async || !autoen || wr5[1] || allsent) rts_hold <= async && autoen && wr5[1];

    if (tx_cell) begin
      if (async) begin
        // ---- asynchronous: each bit is `factor` cells
        b = at_line;
        if (at_busy) begin
          if (at_tick + 8'd1 >= at_len) begin
            at_tick <= 8'd0;
            if (at_bits != 4'd0) begin
              b = at_sr[0]; at_sr <= {1'b1, at_sr[9:1]}; at_bits <= at_bits - 4'd1; at_len <= {1'b0, factor};
            end else if (!at_stopping) begin
              b = 1'b1; at_stopping <= 1'b1; at_len <= astop;
            end else begin
              b = 1'b1; at_busy <= 1'b0;
            end
          end else at_tick <= at_tick + 8'd1;
        end
        if ((!at_busy || (at_stopping && at_tick + 8'd1 >= at_len)) && tfull && txen) begin
          // the next character: its start bit now
          b = 1'b0;
          at_busy <= 1'b1; at_stopping <= 1'b0; at_tick <= 8'd0; at_len <= {1'b0, factor};
          at_sr <= ({2'b00, tbuf & amask} | (wr4[0] ? ({9'd0, apar} << tbits) : 10'd0)) |
                   (10'h3FF << (tbits + {3'd0, wr4[0]}));
          at_bits <= tbits + {3'd0, wr4[0]};
          tfull <= 1'b0; tx_ip <= 1'b1;
        end
        at_line <= b;
      end else begin
        // ---- synchronous and SDLC: one bit a cell
        b = ts_bit;
        if (ts_stuff) begin
          ts_stuff <= 1'b0;
        end else begin
          ts_kind <= cu_kind; ts_crcin <= cu_crc;
          ts_sr <= {1'b0, cu_sr[15:1]}; ts_n <= cu_n - 5'd1;
          if (ts_load) begin
            if (abort_req) abort_req <= 1'b0;
            if (!txen) crc_act <= 1'b0;                     // disabled: the frame's end is abandoned
            if (nx_take) begin tfull <= 1'b0; tx_ip <= 1'b1; end
            if (nx_under) begin eom <= 1'b1; crc_act <= (sdlc && wr10[2]) || wr5[0]; end
            if (nx_end) begin crc_act <= 1'b0; tx_ip <= 1'b1; req_pulse <= 1'b1; end
          end
          if (cu_kind == K_DATA && cu_crc) crc_tx <= crc_bit(crc_tx, b, wr5[2]);
          // zero insertion in the data and the CRC
          if (sdlc && (cu_kind == K_DATA || cu_kind == K_CRC)) begin
            if (b) begin
              if (ts_ones == 3'd4) begin ts_stuff <= 1'b1; ts_ones <= 3'd0; end
              else ts_ones <= ts_ones + 3'd1;
            end else ts_ones <= 3'd0;
          end else ts_ones <= 3'd0;
        end
      end
      // the encoder: the cell's boundary
      tbit <= b;
      case (enc)
        2'b00: tline <= b;
        2'b01: if (!b) tline <= !tline;
        default: tline <= !tline;
      endcase
    end
    if (tx_mid && enc[1] && (enc[0] ? !tbit : tbit)) tline <= !tline;   // FM0: a 0; FM1: a 1

    // ---------------------------------------------------------- receiver
    rbit_v = 1'b0; rbit = 1'b0;
    if (enc[1]) begin                                      // FM: 1/4, then 3/4
      if (rx_q1) fm_s1 <= rline;
      if (rx_s) begin rbit_v = 1'b1; rbit = enc[0] ? (fm_s1 == rline) : (fm_s1 != rline); end
    end else if (rx_s) begin
      rbit_v = 1'b1;
      rbit = enc[0] ? (rline == nrzi_prev) : rline;
      nrzi_prev <= rline;
    end

    if (!rxen) begin
      hunt <= 1'b1;                                        // set while the receiver is disabled
      in_frame <= 1'b0; pq_n <= 4'd0; ar_st <= AR_IDLE;
    end else if (async) begin
      // ---- asynchronous: the raw line, sampled at mid-cell
      if (rx_s) begin
        nb = rbits + {3'd0, wr4[0]};
        case (ar_st)
          AR_IDLE:
            if (!rline) begin
              ar_n <= 4'd0; ar_sh <= 9'h000;
              if (factor == 7'd1) begin ar_st <= AR_DATA; ar_cnt <= 7'd0; end
              else begin ar_st <= AR_START; ar_cnt <= 7'd1; end
            end
          AR_START:
            if (ar_cnt == {1'b0, factor[6:1]}) begin
              if (!rline) begin ar_st <= AR_DATA; ar_cnt <= 7'd0; end   // mid start bit
              else ar_st <= AR_IDLE;                                    // a false start
            end else ar_cnt <= ar_cnt + 7'd1;
          AR_DATA:
            if (ar_cnt + 7'd1 >= factor) begin
              ar_cnt <= 7'd0;
              if (ar_n < nb) begin
                ar_sh[ar_n] <= rline; ar_n <= ar_n + 4'd1;
              end else begin
                // the stop bit: the character, with unused bits read as 1s
                m9 = (9'd1 << nb) - 9'd1;
                d8 = ar_sh[7:0] | ~m9[7:0];
                pe = wr4[0] && (^(ar_sh & m9) ^ !wr4[1]);
                if (rline) begin
                  if (!(wr3[1] && d8 == wr6)) push(d8, {2'b00, 1'b0, pe});      // O-5
                  ar_st <= AR_IDLE;
                end else if ((ar_sh & m9) == 9'd0) begin
                  brk <= 1'b1;                              // a break: one null, no framing error
                  push(d8, {3'b000, wr4[0] && !wr4[1]});
                  ar_st <= AR_BREAK;
                end else begin
                  if (!(wr3[1] && d8 == wr6)) push(d8, {2'b01, 1'b0, pe});
                  ar_st <= AR_FEWAIT; ar_cnt <= 7'd0;       // half a bit, not taken as a start
                end
              end
            end else ar_cnt <= ar_cnt + 7'd1;
          AR_FEWAIT:
            if (ar_cnt + 7'd1 >= {1'b0, factor[6:1]}) ar_st <= AR_IDLE; else ar_cnt <= ar_cnt + 7'd1;
          AR_BREAK:
            if (rline) begin brk <= 1'b0; ar_st <= AR_IDLE; end
          default: ar_st <= AR_IDLE;
        endcase
      end
    end else if (rbit_v) begin
      rs_win <= {rbit, rs_win[15:1]};
      if (sdlc) begin
        // ---- SDLC
        pushq = (r_ones < 3'd5);                           // a data bit (a 0 after five 1s is stuffed)
        if (rbit) begin
          if (r_ones != 3'd7) r_ones <= r_ones + 3'd1;
          if (r_ones == 3'd6) begin                        // seven 1s: an abort
            brk <= 1'b1; hunt <= 1'b1; in_frame <= 1'b0; pq_n <= 4'd0;
          end
        end else begin
          r_ones <= 3'd0;
          if (r_ones == 3'd7) brk <= 1'b0;                 // the abort ends on a 0
          if (r_ones == 3'd5) pushq = 1'b0;                // deleted
          if (r_ones == 3'd6) begin                        // a flag
            pushq = 1'b0;
            if (in_frame && frame_ok && frame_data && !hunt) begin
              d8 = rsr >> (4'd8 - rbits);                  // the snapshot, with EOF
              push(d8, {1'b1, (crc_rx != crc_good), 2'b00});
              residue <= {rcnt[0], rcnt[1], rcnt[2]};
            end
            hunt <= 1'b0;
            in_frame <= 1'b1; frame_ok <= 1'b1; addr_next <= 1'b1; frame_data <= 1'b0;
            pq_n <= 4'd0; rcnt <= 4'd0; crc_rx <= crc_pre;
          end
        end
        if (pushq) begin
          pq <= {pq[6:0], rbit};
          if (in_frame && !hunt) begin
            if (pq_n >= 4'd6) begin crc_rx <= crc_bit(crc_rx, pq[5], wr5[2]); frame_data <= 1'b1; end
            if (pq_n >= 4'd8) begin
              rsr <= {pq[7], rsr[7:1]};
              if (rcnt + 4'd1 == rbits) begin
                rcnt <= 4'd0;
                d8 = {pq[7], rsr[7:1]} >> (4'd8 - rbits);
                if (addr_next && wr3[2] && !(d8 == 8'hFF || (wr3[1] ? (d8[7:4] == wr6[7:4]) : (d8 == wr6))))
                  frame_ok <= 1'b0;                        // address search: another station's
                else if (frame_ok) push(d8, 4'b0000);
                addr_next <= 1'b0;
              end else rcnt <= rcnt + 4'd1;
            end else pq_n <= pq_n + 4'd1;
          end
        end
      end else begin
        // ---- monosync, bisync, external sync
        if (hunt) begin
          if ((mono    && (wr10[0] ? ({rbit, rs_win[15:11]} == wr7[7:2]) : ({rbit, rs_win[15:9]} == wr7))) ||
              (bisync  && (wr10[0] ? ({rbit, rs_win[15:5]} == {wr7, wr6[7:4]}) : ({rbit, rs_win[15:1]} == {wr7, wr6}))) ||
              (extsync && !sync_n)) begin
            hunt <= 1'b0; rcnt <= 4'd0; rcrc_on <= wr3[3];
          end
        end else begin
          rsr <= {rbit, rsr[7:1]};
          if (rcrc_on) crc_rx <= crc_bit(crc_rx, rbit, wr5[2]);
          if (rcnt + 4'd1 == rbits) begin
            rcnt <= 4'd0;
            d8 = {rbit, rsr[7:1]} >> (4'd8 - rbits);
            if (!(wr3[1] && d8 == wr6))                    // sync-character load inhibit
              push(d8, {1'b0, (rcrc_on ? crc_bit(crc_rx, rbit, wr5[2]) : crc_rx) != 16'h0000, 2'b00});
            rcrc_on <= wr3[3];
          end else rcnt <= rcnt + 4'd1;
        end
      end
    end

    // ---------------------------------------------------------- SDLC Loop, X.21
    if (rx_s) begin
      loop_d <= rline;
      if (rline) begin if (loop_ones != 3'd7) loop_ones <= loop_ones + 3'd1; end
      else loop_ones <= 3'd0;
      if (sdlc && rline && loop_ones == 3'd6) begin
        if (wr10[1] && !on_loop) begin on_loop <= 1'b1; brk <= 1'b1; hunt <= 1'b1; end
        else if (!wr10[1] && on_loop && !loop_send) on_loop <= 1'b0;
        else if (wr10[1] && on_loop && wr10[4] && !loop_send && frame_data) begin
          loop_send <= 1'b1; loop_d <= 1'b0;               // the EOP's last 1 becomes a flag's 0
        end
      end
    end
    if (loop_send && tx_cell && ts_n == 5'd1 && ts_kind == K_FILL && eom && !tfull) loop_send <= 1'b0;
    if (!sdlc && !async && wr10[1] && !hunt && !x21_go && rbit_v && rcnt + 4'd1 == rbits) begin
      x21_go <= 1'b1; wr5[4] <= 1'b0;                      // X.21: a character after sync; Send Break cleared
    end
    if (hunt || sdlc || async || !wr10[1]) x21_go <= 1'b0;

    // ---------------------------------------------------------- the bus
    if (dwr) begin
      tbuf <= wval; tfull <= 1'b1; tx_ip <= 1'b0; req_pulse <= 1'b0;
      if (crc_act && ts_kind == K_CRC) begin               // NMOS: data during the CRC
        ts_kind <= K_FILL; ts_sr <= fill_sr; ts_n <= fill_n; crc_act <= 1'b0;
      end
    end
    if (drd && n_fcnt != 2'd0) begin
      rlast <= n_fd0;
      if (n_fs0[1]) ovr_l <= 1'b1;
      if (n_fs0[0] && wr4[0]) par_l <= 1'b1;
      if (!locked) begin pop; if (rxmode == 2'b01) first_arm <= 1'b0; end
      else rx_req_hold <= 1'b1;
    end
    if (wr) begin
      case (wreg)
        4'd1:  begin if (wval[4:3] == 2'b01 && wr1[4:3] != 2'b01) first_arm <= 1'b1; wr1 <= wval; end
        4'd3:  begin wr3 <= wval; if (wval[4]) begin hunt <= 1'b1; in_frame <= 1'b0; end end
        4'd4:  wr4 <= wval;
        4'd5:  wr5 <= wval;
        4'd6:  wr6 <= wval;
        4'd7:  wr7 <= wval;
        4'd10: wr10 <= wval;
        4'd11: wr11 <= wval;
        4'd12: wr12 <= wval;
        4'd13: wr13 <= wval;
        4'd14: begin
                 wr14 <= wval[4:0];
                 case (wval[7:5])
                   3'b001: begin dp_en <= 1'b1; dp_search <= 1'b1; dp_cnt <= 5'd16; rr10_one <= 1'b0; rr10_two <= 1'b0; dp_miss1 <= 1'b0; end
                   3'b010: begin dp_search <= 1'b1; dp_cnt <= 5'd16; rr10_one <= 1'b0; rr10_two <= 1'b0; dp_miss1 <= 1'b0; end  // O-9
                   3'b011: begin dp_en <= 1'b0; dp_search <= 1'b1; dp_cnt <= 5'd16; rr10_one <= 1'b0; rr10_two <= 1'b0; dp_miss1 <= 1'b0; end
                   3'b100: dp_brg <= 1'b1;
                   3'b101: dp_brg <= 1'b0;
                   3'b110: dp_fm <= 1'b1;
                   3'b111: dp_fm <= 1'b0;
                   default: ;
                 endcase
               end
        4'd15: wr15 <= wval;
        default: ;
      endcase
    end
    if (cmd) begin
      case (wval[7:6])
        2'b01: crc_rx <= crc_pre;                          // Reset Rx CRC Checker
        2'b10: crc_tx <= crc_pre;                          // Reset Tx CRC Generator
        2'b11: if (txen) eom <= 1'b0;                      // Reset Tx Underrun/EOM Latch
               else if (!ext_closed) begin                 // the transmitter disabled
                 ext_closed <= 1'b1; ext_lat <= {ext_live[5], 1'b0, ext_live[3:0]};
               end
        default: ;
      endcase
      case (wval[5:3])
        3'b010: begin                                      // Reset Ext/Status Interrupts
                  if ((|((ext_live ^ ext_lat) & ext_ie & 6'b001110)) || (brk_pend && wr15[7]) ||
                      (eom_pend && wr15[6]) || (zc_live && wr15[1])) begin
                    ext_closed <= 1'b1; ext_lat <= ext_live;   // a change that persisted
                  end else ext_closed <= 1'b0;
                  brk_pend <= 1'b0; eom_pend <= 1'b0;
                end
        3'b011: if (sdlc) begin abort_req <= 1'b1; tfull <= 1'b0; eom <= 1'b1; end   // Send Abort
        3'b100: first_arm <= 1'b1;                         // Enable Int on Next Rx Character
        3'b101: tx_ip <= 1'b0;                             // Reset Tx Int Pending
        3'b110: begin                                      // Error Reset
                  ovr_l <= 1'b0; par_l <= 1'b0; rx_req_hold <= 1'b0;
                  if (locked) pop;                         // "the data is lost"
                end
        default: ;
      endcase
    end

    // ---------------------------------------------------------- External/Status latches
    if (!ext_closed) begin
      if (|ext_qual) begin ext_closed <= 1'b1; ext_lat <= ext_live; end
    end else begin
      if (ext_chg[5] && wr15[7]) brk_pend <= 1'b1;
      if (ext_qual[4]) eom_pend <= 1'b1;
    end

    fd0 <= n_fd0; fd1 <= n_fd1; fd2 <= n_fd2; fdh <= n_fdh;
    fs0 <= n_fs0; fs1 <= n_fs1; fs2 <= n_fs2; fsh <= n_fsh;
    fcnt <= n_fcnt; fhold <= n_fhold;

    // ---------------------------------------------------------- resets
    if (hw_reset || ch_reset) begin
      wr1 <= wr1 & 8'b0010_0100;
      wr3[0] <= 1'b0;
      wr4[2] <= 1'b1;
      wr5 <= wr5 & 8'b0110_0001;
      wr15 <= 8'hF8;
      if (hw_reset) begin wr10 <= 8'h00; wr11 <= 8'h08; wr14 <= 5'b00000; end
      else          begin wr10 <= wr10 & 8'b0110_0000; wr14 <= wr14 & 5'b00011; end
      tfull <= 1'b0; tx_ip <= 1'b0; eom <= 1'b1; crc_act <= 1'b0; abort_req <= 1'b0;
      tline <= 1'b1; tbit <= 1'b1; req_pulse <= 1'b0; rts_hold <= 1'b0;
      ts_kind <= K_MARK; ts_n <= 5'd0; ts_ones <= 3'd0; ts_stuff <= 1'b0; ts_crcin <= 1'b0;
      at_busy <= 1'b0; at_stopping <= 1'b0; at_line <= 1'b1; at_tick <= 8'd0; at_len <= 8'd1;
      fcnt <= 2'd0; fhold <= 1'b0; ovr_l <= 1'b0; par_l <= 1'b0; residue <= 3'b011;
      first_arm <= 1'b1; rx_req_hold <= 1'b0; hunt <= 1'b1; brk <= 1'b0;
      ar_st <= AR_IDLE; in_frame <= 1'b0; pq_n <= 4'd0; r_ones <= 3'd0; rcnt <= 4'd0;
      dp_en <= 1'b0; dp_fm <= 1'b0; dp_brg <= 1'b0; dp_search <= 1'b1; dp_cnt <= 5'd16;
      dp_adj <= 2'b00; dp_padj <= 2'b00; dp_held <= 1'b0; dp_seen <= 1'b0; dp_miss1 <= 1'b0;
      rr10_one <= 1'b0; rr10_two <= 1'b0;
      on_loop <= 1'b0; loop_send <= 1'b0; loop_ones <= 3'd0; x21_go <= 1'b0;
      ext_closed <= 1'b0; brk_pend <= 1'b0; eom_pend <= 1'b0;
      if (hw_reset) begin brg_run <= 1'b0; brg_zc <= 1'b1; brg_out <= 1'b1; end
    end
  end

endmodule
