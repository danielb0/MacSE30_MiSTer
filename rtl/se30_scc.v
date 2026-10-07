// se30_scc.v - the Zilog 8530 SCC

`timescale 1ns/1ps

module se30_scc (
  input            clk,
  input            c16_en,
  input            c3m_en,
  input            reset_n,

  input            stb,
  input            rd,
  input            a1,
  input            a2,
  input      [7:0] wdata,
  output reg [7:0] rdata,
  output           irq_n,

  input            vsync,
  output           w_req_n,

  input            a_rxd, a_hski, a_gpi,
  input            b_rxd, b_hski, b_gpi,
  output           a_txd, a_txd_en, a_hsko,
  output           b_txd, b_txd_en, b_hsko,

  output    [31:0] dbg
);

  wire       pclk = c16_en && c3m_en;
  reg        c3m = 1'b0;
  reg  [1:0] c3m_n = 2'd0;
  always @(posedge clk)
    if (pclk) begin c3m <= 1'b1; c3m_n <= 2'd0; end
    else if (c16_en) begin
      if (c3m_n == 2'd1) c3m <= 1'b0;
      if (c3m_n != 2'd3) c3m_n <= c3m_n + 2'd1;
    end

  reg  [2:0] sa1 = 3'b110, sa2 = 3'b110, sb1 = 3'b110, sb2 = 3'b110;
  always @(posedge clk) begin
    sa1 <= {a_rxd, a_hski, a_gpi}; sa2 <= sa1;
    sb1 <= {b_rxd, b_hski, b_gpi}; sb2 <= sb1;
  end
  wire a_rx = sa2[2], a_hk = sa2[1], a_gp = sa2[0];
  wire b_rx = sb2[2], b_hk = sb2[1], b_gp = sb2[0];

  reg  [1:0] por = 2'b00;
  always @(posedge clk) por <= reset_n ? {por[0], 1'b1} : 2'b00;
  wire       hw_cfg = !por[1];

  reg  [3:0] ptr;
  reg  [7:0] wr2;
  reg        shl, mie, dlc, nv, vis;
  reg        hw_force;
  reg        rst_a, rst_b;

  wire [7:0] rr0a, rr1a, rr10a, rr12a, rr13a, rr15a, rda;
  wire [7:0] rr0b, rr1b, rr10b, rr12b, rr13b, rr15b, rdb;
  wire       ipra, ipsa, ipta, ipea, iprb, ipsb, iptb, ipeb;
  wire       txa, rtsa_n, dtra_n, wreqa_n, txb, rtsb_n, dtrb_n, wreqb_n;

  wire       ctl     = stb && !a2;
  wire       ctl_wr  = ctl && !rd;
  wire       ctl_rd  = ctl &&  rd;
  wire       is_wr0  = ctl_wr && (ptr == 4'd0);
  wire       to_reg  = ctl_wr && (ptr != 4'd0);
  wire       dat_wr  = (stb && a2 && !rd) || (to_reg && ptr == 4'd8);
  wire       dat_rd  = (stb && a2 &&  rd) || (ctl_rd && ptr == 4'd8);
  wire       chreg   = to_reg && ptr != 4'd2 && ptr != 4'd8 && ptr != 4'd9;

  se30_scc_chan cha (
    .clk(clk), .hw_reset(hw_cfg || hw_force), .ch_reset(rst_a), .pclk(pclk),
    .rtxc(vsync ? !a_gp : c3m), .trxc(a_hk), .rxd(a_rx), .cts_n(a_hk), .dcd_n(!a_gp), .sync_n(1'b1),
    .txd(txa), .rts_n(rtsa_n), .dtr_req_n(dtra_n), .w_req_n(wreqa_n),
    .wr(chreg && a1), .wreg(ptr), .wval(wdata), .cmd(is_wr0 && a1),
    .dwr(dat_wr && a1), .drd(dat_rd && a1),
    .rr0(rr0a), .rr1(rr1a), .rr10(rr10a), .rr12(rr12a), .rr13(rr13a), .rr15(rr15a), .rdata(rda),
    .ip_rx(ipra), .ip_sp(ipsa), .ip_tx(ipta), .ip_ext(ipea)
  );
  se30_scc_chan chb (
    .clk(clk), .hw_reset(hw_cfg || hw_force), .ch_reset(rst_b), .pclk(pclk),
    .rtxc(c3m), .trxc(b_hk), .rxd(b_rx), .cts_n(b_hk), .dcd_n(!b_gp), .sync_n(1'b1),
    .txd(txb), .rts_n(rtsb_n), .dtr_req_n(dtrb_n), .w_req_n(wreqb_n),
    .wr(chreg && !a1), .wreg(ptr), .wval(wdata), .cmd(is_wr0 && !a1),
    .dwr(dat_wr && !a1), .drd(dat_rd && !a1),
    .rr0(rr0b), .rr1(rr1b), .rr10(rr10b), .rr12(rr12b), .rr13(rr13b), .rr15(rr15b), .rdata(rdb),
    .ip_rx(iprb), .ip_sp(ipsb), .ip_tx(iptb), .ip_ext(ipeb)
  );

  reg  [5:0] ipv;
  reg        spa_v, spb_v;
  reg        half;
  always @(posedge clk)
    if (hw_cfg) begin ipv <= 6'd0; spa_v <= 1'b0; spb_v <= 1'b0; half <= 1'b0; end
    else if (pclk) begin
      half <= !half;
      if (half && ptr != 4'd2 && ptr != 4'd3) begin
        ipv <= {ipra, ipta, ipea, iprb, iptb, ipeb}; spa_v <= ipsa; spb_v <= ipsb;
      end
    end
  wire [2:0] code = ipv[5] ? (spa_v ? 3'b111 : 3'b110) :
                    ipv[4] ? 3'b100 :
                    ipv[3] ? 3'b101 :
                    ipv[2] ? (spb_v ? 3'b011 : 3'b010) :
                    ipv[1] ? 3'b000 :
                    ipv[0] ? 3'b001 : 3'b011;
  wire [7:0] rr2b = shl ? {wr2[7], code[0], code[1], code[2], wr2[3:0]} : {wr2[7:4], code, wr2[0]};
  wire [7:0] rr3a = {2'b00, ipv[5], ipv[4], ipv[3], ipv[2], ipv[1], ipv[0]};
  assign irq_n = !(mie && (ipv != 6'd0));

  function [7:0] rreg (input [3:0] p, input ch_a);
    case (p)
      4'd0, 4'd4:   rreg = ch_a ? rr0a : rr0b;
      4'd1, 4'd5:   rreg = ch_a ? rr1a : rr1b;
      4'd2, 4'd6:   rreg = ch_a ? wr2  : rr2b;
      4'd3, 4'd7:   rreg = ch_a ? rr3a : 8'h00;
      4'd8:         rreg = ch_a ? rda  : rdb;
      4'd10, 4'd14: rreg = ch_a ? rr10a : rr10b;
      4'd12:        rreg = ch_a ? rr12a : rr12b;
      4'd9, 4'd13:  rreg = ch_a ? rr13a : rr13b;
      default:      rreg = ch_a ? rr15a : rr15b;
    endcase
  endfunction

  always @(posedge clk) begin
    hw_force <= 1'b0; rst_a <= 1'b0; rst_b <= 1'b0;
    if (hw_cfg) begin
      ptr <= 4'd0; shl <= 1'b0; mie <= 1'b0; dlc <= 1'b0; nv <= 1'b0; vis <= 1'b0;
      wr2 <= 8'h00; rdata <= 8'h00;
    end else if (stb) begin
      if (rd) rdata <= a2 ? (a1 ? rda : rdb) : rreg(ptr, a1);
      if (!a2) begin
        if (is_wr0) ptr <= (wdata[5:3] == 3'b001) ? {1'b1, wdata[2:0]} : {1'b0, wdata[2:0]};
        else ptr <= 4'd0;
      end
      if (to_reg && ptr == 4'd2) wr2 <= wdata;
      if (to_reg && ptr == 4'd9) begin
        shl <= wdata[4]; mie <= wdata[3]; dlc <= wdata[2]; nv <= wdata[1]; vis <= wdata[0];
        case (wdata[7:6])
          2'b01: rst_b <= 1'b1;
          2'b10: rst_a <= 1'b1;
          2'b11: hw_force <= 1'b1;
          default: ;
        endcase
      end
    end
  end

  reg [11:0] nacc = 12'd0;
  always @(posedge clk) if (stb) nacc <= nacc + 12'd1;
  assign dbg = {nacc, ptr, irq_n, mie, ipv, rr0b};

  assign w_req_n  = wreqa_n && wreqb_n;
  assign a_txd    = txa;  assign a_txd_en = !rtsa_n;  assign a_hsko = !dtra_n;
  assign b_txd    = txb;  assign b_txd_en = !rtsb_n;  assign b_hsko = !dtrb_n;

endmodule
