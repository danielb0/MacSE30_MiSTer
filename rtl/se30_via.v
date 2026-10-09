// se30_via.v - Apple's 6523 VIA (VIA1, VIA2): the 6522 as Apple's VIA Cell specification
// describes it, with the features the cell dropped restored from the R6522 data sheet.
// GLUE's device port: a write and a read's side effects land on E's last high clock.

`timescale 1ns/1ps

module se30_via (
  input         clk,
  input         c16_en,
  input         reset_n,
  input         e_clk,

  input         sel,
  input         strobe,
  input   [3:0] rs,
  input         rw,                    // 1 = read
  input   [7:0] wdata,
  output  [7:0] rdata,
  output        irq_n,

  input   [7:0] pa_in,
  output  [7:0] pa_out,
  output  [7:0] pa_oe,
  input   [7:0] pb_in,
  output  [7:0] pb_out,
  output  [7:0] pb_oe,
  input         ca1,
  input         ca2_in,
  output        ca2_out,
  output        ca2_oe,
  input         cb1_in,
  output        cb1_out,
  output        cb1_oe,
  input         cb2_in,
  output        cb2_out,
  output        cb2_oe,

  output  [6:0] dbg_ifr,               // debug: the interrupt flags
  output  [6:0] dbg_ier
);

  reg  [7:0] ora, orb, ddra, ddrb, acr, pcr;
  reg  [6:0] ifr, ier;
  reg [15:0] t1c, t1l, t2c;
  reg  [7:0] t2l;
  reg  [8:0] sr;                       // sr[8] is CB2out while shifting out
  reg  [2:0] srcnt;
  reg        sr_active;                // an internal-clock transfer in progress
  reg        t1_armed, t1_reload, t1_skip, t2_armed, t2_skip;
  reg        pb7_t1;                   // T1's PB7 output under ACR7
  reg  [7:0] ira_l, irb_l;             // the input latches under ACR0/ACR1
  reg        e_q, ca1_q, ca2_q, cb1_q, cb2_q, pb6_q, iclk_q;
  reg        ca2_hs, cb2_hs;           // the handshake outputs
  reg  [1:0] ca2_pulse, cb2_pulse;     // the pulse outputs: low while nonzero
  reg        iclk;                     // the internal shift clock (CB1 out)

  // ------------------------------------------------------------- decode
  wire acc   = c16_en && sel && strobe;
  wire wr    = acc && !rw;
  wire rd    = acc && rw;
  wire ora_acc = acc && (rs == 4'd1);          // register 15 does not count
  wire orb_acc = acc && (rs == 4'd0);
  wire ca2_indep = !pcr[3] && pcr[1];          // independent input: port access leaves the flag
  wire cb2_indep = !pcr[7] && pcr[5];

  // the shift register's mode (ACR4-2), R6522 table
  wire [2:0] srm     = acr[4:2];
  wire       sr_out  = srm[2];                 // 100, 101, 110, 111
  wire       sr_ext  = (srm == 3'b011) || (srm == 3'b111);
  wire       sr_e    = (srm == 3'b010) || (srm == 3'b110);
  wire       sr_t2   = (srm == 3'b001) || (srm == 3'b100) || (srm == 3'b101);
  wire       sr_free = (srm == 3'b100);

  // --------------------------------------------------------------- edges
  wire e_fall   = c16_en && e_q && !e_clk;
  wire ca1_edge = c16_en && (ca1 != ca1_q) && (ca1 == pcr[0]);
  wire ca2_edge = c16_en && !pcr[3] && (ca2_in != ca2_q) && (ca2_in == pcr[2]);
  wire cb1_edge = c16_en && !cb1_oe && (cb1_in != cb1_q) && (cb1_in == pcr[4]);
  wire cb2_edge = c16_en && !cb2_oe && (cb2_in != cb2_q) && (cb2_in == pcr[6]);
  wire cb1_rise = c16_en && cb1_in && !cb1_q;
  wire cb1_fall = c16_en && !cb1_in && cb1_q;
  wire pb6_fall = c16_en && !pb_in[6] && pb6_q;
  wire iclk_rise = c16_en && iclk && !iclk_q;
  wire iclk_fall = c16_en && !iclk && iclk_q;

  // T2 in the T2-clocked shift modes lends its low byte as the shift clock
  wire t2_srtick = e_fall && sr_t2 && (t2c[7:0] == 8'h00);
  wire t2_tick   = acr[5] ? pb6_fall : (e_fall && !t2_skip && !sr_t2);

  wire shift_out = sr_out && (sr_ext ? cb1_fall : iclk_fall) && (sr_ext || sr_active);
  wire shift_in  = !sr_out && (srm != 3'b000) && (sr_ext ? cb1_rise : iclk_rise) && (sr_ext || sr_active);

  // --------------------------------------------------------------- state
  always @(posedge clk)
    if (!reset_n) begin
      ora <= 0; orb <= 0; ddra <= 0; ddrb <= 0; acr <= 0; pcr <= 0; ifr <= 0; ier <= 0;
      t1c <= 16'hFFFF; t1l <= 16'hFFFF; t2c <= 16'hFFFF; t2l <= 8'hFF;
      sr <= 0; srcnt <= 0; sr_active <= 0;
      t1_armed <= 0; t1_reload <= 0; t1_skip <= 0; t2_armed <= 0; t2_skip <= 0; pb7_t1 <= 1;
      ira_l <= 8'hFF; irb_l <= 8'hFF;
      e_q <= 0; iclk_q <= 1;
      ca1_q <= ca1; ca2_q <= ca2_in; cb1_q <= cb1_in; cb2_q <= cb2_in; pb6_q <= pb_in[6];   // no edge out of reset
      ca2_hs <= 1; cb2_hs <= 1; ca2_pulse <= 0; cb2_pulse <= 0; iclk <= 1;
    end else begin
      if (c16_en) begin
        e_q <= e_clk; ca1_q <= ca1; ca2_q <= ca2_in; cb1_q <= cb1_in; cb2_q <= cb2_in;
        pb6_q <= pb_in[6]; iclk_q <= iclk;
      end

      // ---- the access: writes, and the side effects of reads
      if (wr) case (rs)
        4'd0:  orb <= (orb & ~ddrb) | (wdata & ddrb);
        4'd1, 4'd15: ora <= (ora & ~ddra) | (wdata & ddra);
        4'd2:  ddrb <= wdata;
        4'd3:  ddra <= wdata;
        4'd4, 4'd6: t1l[7:0] <= wdata;
        4'd5:  begin t1l[15:8] <= wdata; t1c <= {wdata, t1l[7:0]}; ifr[6] <= 0;
                     t1_armed <= 1; t1_skip <= 1; t1_reload <= 0; if (acr[7]) pb7_t1 <= 0; end
        4'd7:  begin t1l[15:8] <= wdata; ifr[6] <= 0; end
        4'd8:  t2l <= wdata;
        4'd9:  begin t2c <= {wdata, t2l}; ifr[5] <= 0; t2_armed <= 1; t2_skip <= 1; end
        4'd10: begin sr[7:0] <= wdata; ifr[2] <= 0; srcnt <= 0; sr_active <= 1; end
        4'd11: acr <= wdata;
        4'd12: pcr <= wdata;
        4'd13: ifr <= ifr & ~wdata[6:0];
        4'd14: ier <= wdata[7] ? (ier | wdata[6:0]) : (ier & ~wdata[6:0]);
        default: ;
      endcase
      if (rd) case (rs)
        4'd4:  ifr[6] <= 0;
        4'd8:  ifr[5] <= 0;
        4'd10: begin ifr[2] <= 0; srcnt <= 0; sr_active <= 1; end
        default: ;
      endcase
      if (ora_acc) begin ifr[1] <= 0; if (!ca2_indep) ifr[0] <= 0; ca2_pulse <= 2'd2; end
      if (orb_acc) begin ifr[4] <= 0; if (!cb2_indep) ifr[3] <= 0; cb2_pulse <= 2'd2; end

      // ---- the handshake and pulse outputs (R6522 CA2 table, modes 100 and 101)
      if (pcr[3:1] != 3'b100) ca2_hs <= 1;
      else if (ora_acc) ca2_hs <= 0;
      else if (ca1_edge) ca2_hs <= 1;
      if (pcr[7:5] != 3'b100) cb2_hs <= 1;
      else if (orb_acc) cb2_hs <= 0;
      else if (cb1_edge) cb2_hs <= 1;
      if (e_fall) begin
        if (ca2_pulse != 0 && !ora_acc) ca2_pulse <= ca2_pulse - 1'b1;
        if (cb2_pulse != 0 && !orb_acc) cb2_pulse <= cb2_pulse - 1'b1;
      end

      // ---- the input latches (ACR0, ACR1)
      if (ca1_edge) ira_l <= pa_in;
      if (cb1_edge) irb_l <= pb_in;

      // ---- T1: N+1 falls after the load it reads $FFFF, the flag
      // sets, and a cycle later the latches reload it
      if (e_fall) begin
        if (t1_skip) t1_skip <= 0;
        else if (t1_reload) begin t1c <= t1l; t1_reload <= 0; end
        else if (t1c == 16'h0000) begin
          t1c <= 16'hFFFF; t1_reload <= 1;
          if (acr[6] || t1_armed) begin
            ifr[6] <= 1;
            if (acr[7]) pb7_t1 <= acr[6] ? ~pb7_t1 : 1'b1;
          end
          t1_armed <= 0;
        end else t1c <= t1c - 1'b1;
      end

      // ---- T2: one-shot, then a free roll-over; or PB6 pulses; or the
      // shift clock's divider (low byte reloaded from the latch)
      if (e_fall && t2_skip) t2_skip <= 0;
      if (t2_tick) begin
        if (t2c == 16'h0000 && t2_armed) begin ifr[5] <= 1; t2_armed <= 0; end
        t2c <= t2c - 1'b1;
      end
      if (e_fall && sr_t2) t2c[7:0] <= (t2c[7:0] == 8'h00) ? t2l : t2c[7:0] - 1'b1;

      // ---- the shift register
      if (sr_e && (sr_active || sr_free) && e_fall) iclk <= ~iclk;
      else if (sr_t2 && (sr_active || sr_free) && t2_srtick) iclk <= ~iclk;
      else if (!(sr_e || sr_t2) || !(sr_active || sr_free)) iclk <= 1;
      if (shift_out || shift_in) begin
        if (shift_out) sr <= {sr[7], sr[6:0], sr[7]};
        else           sr[7:0] <= {sr[6:0], cb2_in};
        srcnt <= srcnt + 1'b1;
        if (srcnt == 3'd7) begin
          if (!sr_free) ifr[2] <= 1;
          sr_active <= 0;
        end
      end

      // ---- the control lines' flags: set after the clears, so a set wins
      if (ca1_edge) ifr[1] <= 1;
      if (ca2_edge) ifr[0] <= 1;
      if (cb1_edge) ifr[4] <= 1;
      if (cb2_edge) ifr[3] <= 1;
    end

  // ---------------------------------------------------------------- read
  wire [7:0] ira   = acr[0] ? ira_l : pa_in;
  wire [7:0] irb   = acr[1] ? irb_l : pb_in;
  wire [7:0] pa_rd = (ora & ddra) | (ira & ~ddra);
  wire [7:0] pb_rd = (pb_out & ddrb) | (irb & ~ddrb);
  wire       irq   = |(ifr & ier);
  reg  [7:0] rmux;
  always @(*) case (rs)
    4'd0:  rmux = pb_rd;
    4'd1, 4'd15: rmux = pa_rd;
    4'd2:  rmux = ddrb;
    4'd3:  rmux = ddra;
    4'd4:  rmux = t1c[7:0];
    4'd5:  rmux = t1c[15:8];
    4'd6:  rmux = t1l[7:0];
    4'd7:  rmux = t1l[15:8];
    4'd8:  rmux = t2c[7:0];
    4'd9:  rmux = t2c[15:8];
    4'd10: rmux = sr[7:0];
    4'd11: rmux = acr;
    4'd12: rmux = pcr;
    4'd13: rmux = {irq, ifr};
    default: rmux = {1'b1, ier};
  endcase
  assign rdata = sel ? rmux : 8'h00;
  assign irq_n = !irq;
  assign dbg_ifr = ifr;
  assign dbg_ier = ier;

  // ---------------------------------------------------------------- pins
  assign pa_out  = ora;
  assign pa_oe   = ddra;
  assign pb_out  = {acr[7] ? pb7_t1 : orb[7], orb[6:0]};
  assign pb_oe   = ddrb;
  assign ca2_oe  = pcr[3];
  assign ca2_out = (pcr[2:1] == 2'b00) ? ca2_hs : (pcr[2:1] == 2'b01) ? (ca2_pulse == 0) : pcr[1];
  assign cb1_oe  = sr_e || sr_t2;
  assign cb1_out = iclk;
  assign cb2_oe  = sr_out || pcr[7];
  assign cb2_out = sr_out ? sr[8] : (pcr[6:5] == 2'b00) ? cb2_hs : (pcr[6:5] == 2'b01) ? (cb2_pulse == 0) : pcr[5];

endmodule
