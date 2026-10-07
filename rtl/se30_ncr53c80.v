// se30_ncr53c80.v - the NCR 53C80 SCSI controller

`timescale 1ns/1ps

module se30_ncr53c80 #(
  parameter integer SETTLE = 13
) (
  input            clk,
  input            reset_n,

  input            cs,
  input            dack,
  input            rd,
  input            wr,
  input      [2:0] rs,
  input      [7:0] wdata,
  output reg [7:0] rdata,
  output reg       drq,
  output reg       irq,

  input      [7:0] b_db,
  input            b_dbp,
  input            b_bsy, b_sel, b_rst, b_atn, b_ack,
  input            b_req, b_msg, b_cd, b_io,
  input            b_sel_other,

  output     [7:0] o_db,
  output           o_db_en,
  output           o_bsy, o_sel, o_rst, o_atn, o_ack
);

  reg  [7:0] odr;
  reg  [7:0] idr;
  reg        icr_rst, icr_tm, icr_ack, icr_bsy, icr_sel, icr_atn, icr_data;
  reg  [7:0] mr;
  reg  [3:0] tcr;
  reg  [7:0] ser;
  reg        busy_err;
  reg        aip, la;

  wire mr_block = mr[7], mr_target = mr[6], mr_moncbsy = mr[2], mr_dma = mr[1], mr_arb = mr[0];

  reg        dma_send, dma_irecv;
  reg        dma_ack;
  reg        byte_full;
  reg        consumed;
  reg        dack_cycled;
  reg        drq_due;

  wire       phase_match = ({b_msg, b_cd, b_io} == tcr[2:0]);
  wire       dbp = b_dbp;

  reg  [4:0] free_n, nobsy_n, selc_n;
  wire       bus_free = (free_n  >= SETTLE);
  wire       bsy_lost = (nobsy_n >= SETTLE);
  wire       sel_cond = b_sel && !b_bsy && ((ser & b_db) != 8'h00);
  wire       sel_seen = (selc_n  >= SETTLE);

  wire       quiet   = icr_tm;
  wire       arb_drv = aip;
  assign o_db_en = !quiet && (arb_drv || (icr_data && !mr_target && !b_io && phase_match));
  assign o_db    = o_db_en ? odr : 8'h00;
  assign o_bsy   = !quiet && (icr_bsy || arb_drv);
  assign o_sel   = !quiet && icr_sel;
  assign o_rst   = !quiet && icr_rst;
  assign o_atn   = !quiet && icr_atn && !mr_target;
  assign o_ack   = !quiet && (icr_ack || dma_ack) && !mr_target;

  wire [7:0] icr_rd = {icr_rst, aip, la, icr_ack, icr_bsy, icr_sel, icr_atn, icr_data};
  wire [7:0] csr    = {b_rst, b_bsy, b_req, b_msg, b_cd, b_io, b_sel, dbp};
  wire [7:0] bsr    = {1'b0, drq, 1'b0, irq, phase_match, busy_err, b_atn, b_ack};
  always @* begin
    if (dack) rdata = idr;
    else case (rs)
      3'd0: rdata = b_db;
      3'd1: rdata = icr_rd;
      3'd2: rdata = mr;
      3'd3: rdata = {4'b0000, tcr};
      3'd4: rdata = csr;
      3'd5: rdata = bsr;
      3'd6: rdata = idr;
      default: rdata = 8'h00;
    endcase
  end

  reg  b_req_q, b_rst_q, dack_q;
  wire req_rise  = b_req && !b_req_q;
  wire req_fall  = !b_req && b_req_q;
  wire dack_fall = !dack && dack_q;
  wire rst_hold  = b_rst;

  task clear_all;
    begin
      odr <= 8'h00; idr <= 8'h00;
      icr_tm <= 0; icr_ack <= 0; icr_bsy <= 0; icr_sel <= 0; icr_atn <= 0; icr_data <= 0;
      mr <= 8'h00; tcr <= 4'h0; ser <= 8'h00; busy_err <= 0; aip <= 0; la <= 0;
      dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; byte_full <= 0; consumed <= 0; dack_cycled <= 0;
      drq <= 0; drq_due <= 0;
    end
  endtask

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      clear_all; icr_rst <= 0; irq <= 0;
      free_n <= 0; nobsy_n <= 0; selc_n <= 0;
      b_req_q <= 0; b_rst_q <= 0; dack_q <= 0;
    end else begin
      b_req_q <= b_req; b_rst_q <= b_rst; dack_q <= dack;
      free_n  <= (b_bsy || b_sel) ? 5'd0 : (bus_free ? free_n : free_n + 5'd1);
      nobsy_n <= b_bsy ? 5'd0 : (bsy_lost ? nobsy_n : nobsy_n + 5'd1);
      selc_n  <= !sel_cond ? 5'd0 : (sel_seen ? selc_n : selc_n + 5'd1);

      if (rst_hold) begin
        if (!b_rst_q) irq <= 1;
        clear_all;
        if (wr && cs && rs == 3'd1) icr_rst <= wdata[7];
        if (rd && cs && rs == 3'd7) irq <= 0;
      end else begin
        if (wr && cs) case (rs)
          3'd0: odr <= wdata;
          3'd1: begin
                  icr_rst <= wdata[7]; icr_tm <= wdata[6];
                  icr_ack <= wdata[4]; icr_bsy <= wdata[3]; icr_sel <= wdata[2];
                  icr_atn <= wdata[1]; icr_data <= wdata[0];
                end
          3'd2: begin
                  mr <= wdata;
                  if (!wdata[1]) begin
                    dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
                    byte_full <= 0; consumed <= 0; dack_cycled <= 0;
                  end
                  if (!wdata[0]) begin aip <= 0; la <= 0; end
                end
          3'd3: tcr <= wdata[3:0];
          3'd4: ser <= wdata;
          3'd5: if (mr_dma) begin
                  dma_send <= 1; dma_irecv <= 0; dma_ack <= 0;
                  byte_full <= 0; consumed <= 0; drq_due <= 1;
                end
          3'd6: ;
          3'd7: if (mr_dma && !mr_target) begin
                  dma_irecv <= 1; dma_send <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0; dack_cycled <= 0;
                end
        endcase

        if (rd && cs && rs == 3'd7) begin irq <= 0; busy_err <= 0; end

        if (mr_arb && !aip && bus_free) aip <= 1;
        if (aip && b_sel_other) la <= 1;

        if (wr && dack) odr <= wdata;
        if (dack) drq <= 0;

        if (mr_dma) begin
          if (dma_irecv) begin
            if (b_req && phase_match && !dma_ack) begin
              idr <= b_db; dma_ack <= 1; dack_cycled <= 0; drq_due <= 1;
            end
            if (dack && dma_ack) dack_cycled <= 1;
            if (dma_ack && dack_cycled && !dack && !b_req) dma_ack <= 0;
          end
          if (dma_send) begin
            if (wr && dack) byte_full <= 1;
            if (b_req && phase_match && byte_full && !dma_ack) dma_ack <= 1;
            if (dma_ack && req_fall && byte_full && !consumed) begin
              byte_full <= 0; consumed <= 1; drq_due <= 1;
            end
            if (dma_ack && consumed && dack_fall) begin dma_ack <= 0; consumed <= 0; end
          end
          if (drq_due && !dack) begin drq <= 1; drq_due <= 0; end
          if (req_rise && !phase_match) irq <= 1;
        end

        if (mr_moncbsy && bsy_lost) busy_err <= 1;
        if (mr_moncbsy && !b_bsy && nobsy_n == SETTLE - 1) begin
          irq <= 1;
          icr_tm <= 0; icr_ack <= 0; icr_bsy <= 0; icr_sel <= 0; icr_atn <= 0; icr_data <= 0;
          mr[1] <= 0; dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
          byte_full <= 0; consumed <= 0; dack_cycled <= 0;
        end

        if (sel_cond && selc_n == SETTLE - 1) irq <= 1;
      end
    end

endmodule
