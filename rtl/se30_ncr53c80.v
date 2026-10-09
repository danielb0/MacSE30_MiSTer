// se30_ncr53c80.v - the NCR 53C80 SCSI controller, to NCR's 5380-53C80 design manual, in the Mac's
// initiator role: the eight registers, arbitration, selection, programmed I/O and DMA handshakes.

`timescale 1ns/1ps

module se30_ncr53c80 #(
  parameter integer SETTLE = 13          // 400 ns (bus-free and bus-settle delays) in clk periods
) (
  input            clk,
  input            reset_n,            // /RESET: "clears all registers" (4.1, 9.1)

  // the CPU side (GLUE)
  input            cs,
  input            dack,
  input            rd,                 // one clock per read access
  input            wr,                 // one clock per write access
  input      [2:0] rs,
  input      [7:0] wdata,
  output reg [7:0] rdata,
  output reg       drq,
  output reg       irq,

  // the SCSI bus, as seen (everyone's drive OR'd, this chip's included)
  input      [7:0] b_db,
  input            b_dbp,              // the parity line: driven (odd) only with the data bus, else released (0)
  input            b_bsy, b_sel, b_rst, b_atn, b_ack,
  input            b_req, b_msg, b_cd, b_io,
  input            b_sel_other,        // SEL asserted by a device other than this chip (lost arbitration)

  // what this chip asserts
  output     [7:0] o_db,
  output           o_db_en,
  output           o_bsy, o_sel, o_rst, o_atn, o_ack
);

  // ------------------------------------------------------------ registers
  reg  [7:0] odr;                      // Output Data Register
  reg  [7:0] idr;                      // Input Data Register
  reg        icr_rst, icr_tm, icr_ack, icr_bsy, icr_sel, icr_atn, icr_data;   // 6.2
  reg  [7:0] mr;                       // 6.3
  reg  [3:0] tcr;                      // 6.4 bits 3-0 (ASSERT REQ, MSG, C/D, I/O)
  reg  [7:0] ser;                      // 6.6
  reg        busy_err;                 // 6.7 bit 2
  reg        aip, la;                  // 6.2 read bits 6, 5

  wire mr_block = mr[7], mr_target = mr[6], mr_moncbsy = mr[2], mr_dma = mr[1], mr_arb = mr[0];

  // DMA (initiator, non-block)
  reg        dma_send, dma_irecv;      // which Start DMA register was written
  reg        dma_ack;                  // ACK the DMA logic asserts
  reg        byte_full;                // send: a byte is in the ODR, not yet taken by the target
  reg        consumed;                 // send: the target has taken the byte under ACK (REQ fell)
  reg        dack_cycled;              // receive: the CPU has read since this REQ
  reg        drq_due;                  // a byte is wanted (send) or ready (receive), DRQ waits for DACK false

  // ------------------------------------------------------------ bus views
  wire       phase_match = ({b_msg, b_cd, b_io} == tcr[2:0]);     // 6.7 bit 3, continuous
  // DBP is the bus's parity line: whoever drives the data bus drives odd parity; a free bus reads $00
  wire       dbp = b_dbp;

  // the filters: 400 ns of bus free (7), 400 ns of BSY false, 400 ns
  // of a selection condition
  reg  [4:0] free_n, nobsy_n, selc_n;
  wire       bus_free = (free_n  >= SETTLE);
  wire       bsy_lost = (nobsy_n >= SETTLE);
  wire       sel_cond = b_sel && !b_bsy && ((ser & b_db) != 8'h00);
  wire       sel_seen = (selc_n  >= SETTLE);

  // ------------------------------------------------------------ drive
  // arbitrating: BSY and the ODR; otherwise ASSERT DATA BUS drives the ODR as an initiator in phase
  wire       quiet   = icr_tm;                                    // TEST MODE: "disable all output drivers"
  wire       arb_drv = aip;
  assign o_db_en = !quiet && (arb_drv || (icr_data && !mr_target && !b_io && phase_match));
  assign o_db    = o_db_en ? odr : 8'h00;
  assign o_bsy   = !quiet && (icr_bsy || arb_drv);
  assign o_sel   = !quiet && icr_sel;
  assign o_rst   = !quiet && icr_rst;
  assign o_atn   = !quiet && icr_atn && !mr_target;
  assign o_ack   = !quiet && (icr_ack || dma_ack) && !mr_target;

  // ------------------------------------------------------------ reads
  wire [7:0] icr_rd = {icr_rst, aip, la, icr_ack, icr_bsy, icr_sel, icr_atn, icr_data};
  wire [7:0] csr    = {b_rst, b_bsy, b_req, b_msg, b_cd, b_io, b_sel, dbp};          // 6.5
  wire [7:0] bsr    = {1'b0, drq, 1'b0, irq, phase_match, busy_err, b_atn, b_ack}; // 6.7
  always @* begin
    if (dack) rdata = idr;                                        // 4.1: IOR with DACK = Input Data
    else case (rs)
      3'd0: rdata = b_db;                                         // Current SCSI Data
      3'd1: rdata = icr_rd;
      3'd2: rdata = mr;
      3'd3: rdata = {4'b0000, tcr};                               // bit 7 LAST BYTE SENT: never (no /EOP)
      3'd4: rdata = csr;
      3'd5: rdata = bsr;
      3'd6: rdata = idr;
      default: rdata = 8'h00;                                     // 6.9: reading resets parity/interrupt
    endcase
  end

  // ------------------------------------------------------------ the chip
  reg  b_req_q, b_rst_q, dack_q;
  wire req_rise  = b_req && !b_req_q;
  wire req_fall  = !b_req && b_req_q;
  wire dack_fall = !dack && dack_q;
  wire rst_hold  = b_rst;                                         // 9.2/9.3: cleared while RST is on the bus

  task clear_all;                                                 // "all internal logic and registers"
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
        // 8.3: the transition to RST interrupts, and "cannot be disabled"
        if (!b_rst_q) irq <= 1;
        clear_all;
        if (wr && cs && rs == 3'd1) icr_rst <= wdata[7];          // the CPU releases its own RST
        if (rd && cs && rs == 3'd7) irq <= 0;
      end else begin
        // ---------------------------------------------------- CPU writes
        if (wr && cs) case (rs)
          3'd0: odr <= wdata;
          3'd1: begin
                  icr_rst <= wdata[7]; icr_tm <= wdata[6];         // bit 5 DIFF ENBL: 5381 only
                  icr_ack <= wdata[4]; icr_bsy <= wdata[3]; icr_sel <= wdata[2];
                  icr_atn <= wdata[1]; icr_data <= wdata[0];
                end
          3'd2: begin
                  mr <= wdata;
                  if (!wdata[1]) begin                             // DMA MODE reset halts DMA
                    dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
                    byte_full <= 0; consumed <= 0; dack_cycled <= 0;
                  end
                  if (!wdata[0]) begin aip <= 0; la <= 0; end      // AIP "until the ARBITRATE bit is reset"
                end
          3'd3: tcr <= wdata[3:0];
          3'd4: ser <= wdata;
          3'd5: if (mr_dma) begin                                  // Start DMA Send
                  dma_send <= 1; dma_irecv <= 0; dma_ack <= 0;
                  byte_full <= 0; consumed <= 0; drq_due <= 1;
                end
          3'd6: ;                                                  // Start DMA Target Receive: target role, not built
          3'd7: if (mr_dma && !mr_target) begin                    // Start DMA Initiator Receive
                  dma_irecv <= 1; dma_send <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0; dack_cycled <= 0;
                end
        endcase

        // ---------------------------------------------------- CPU reads
        if (rd && cs && rs == 3'd7) begin irq <= 0; busy_err <= 0; end   // 6.9 (BUSY ERROR re-latches while BSY stays lost)

        // ---------------------------------------------------- arbitration (7)
        if (mr_arb && !aip && bus_free) aip <= 1;
        if (aip && b_sel_other) la <= 1;

        // ---------------------------------------------------- DACK
        // a DACK write is the Output Data Register whatever the mode; DACK clears DRQ
        if (wr && dack) odr <= wdata;
        if (dack) drq <= 0;

        // ---------------------------------------------------- DMA
        // REQ is taken as a level: the target is usually already requesting when the CPU starts DMA
        if (mr_dma) begin
          if (dma_irecv) begin
            // 11.6: REQ with phase match latches the byte, raises DRQ and ACK
            if (b_req && phase_match && !dma_ack) begin
              idr <= b_db; dma_ack <= 1; dack_cycled <= 0; drq_due <= 1;
            end
            if (dack && dma_ack) dack_cycled <= 1;
            // T8/T10: ACK false once DACK has cycled and DACK and REQ are both false
            if (dma_ack && dack_cycled && !dack && !b_req) dma_ack <= 0;
          end
          if (dma_send) begin
            // 11.4: a DACK write fills the ODR; REQ with phase match sends it
            if (wr && dack) byte_full <= 1;
            if (b_req && phase_match && byte_full && !dma_ack) dma_ack <= 1;
            // REQ false: the target has the byte; DRQ asks for the next
            if (dma_ack && req_fall && byte_full && !consumed) begin
              byte_full <= 0; consumed <= 1; drq_due <= 1;
            end
            // "requires DACK to cycle before ACK goes inactive"
            if (dma_ack && consumed && dack_fall) begin dma_ack <= 0; consumed <= 0; end
          end
          // DRQ rises with its cause, or when DACK goes false if DACK is
          // still active then (11.4/11.6 T2, "DACK false to DRQ true")
          if (drq_due && !dack) begin drq <= 1; drq_due <= 0; end
          // 8.5: a mismatch as REQ goes from false to true interrupts
          if (req_rise && !phase_match) irq <= 1;
        end

        // ---------------------------------------------------- loss of BSY
        // the BUSY ERROR latch is level-sensitive; the interrupt, ICR clear and DMA MODE reset follow it
        if (mr_moncbsy && bsy_lost) busy_err <= 1;
        if (mr_moncbsy && !b_bsy && nobsy_n == SETTLE - 1) begin
          irq <= 1;
          icr_tm <= 0; icr_ack <= 0; icr_bsy <= 0; icr_sel <= 0; icr_atn <= 0; icr_data <= 0;
          mr[1] <= 0; dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
          byte_full <= 0; consumed <= 0; dack_cycled <= 0;
        end

        // ---------------------------------------------------- selection
        if (sel_cond && selc_n == SETTLE - 1) irq <= 1;
      end
    end

endmodule
