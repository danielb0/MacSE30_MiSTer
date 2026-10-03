// se30_ncr53c80.v - the NCR 53C80 SCSI controller, as NCR's SP-1051
// "NCR 5380-53C80 SCSI Interface Chip Design Manual" (Mar 1986) describes
// it, in the role the Macintosh SE/30 uses it (SE30_PLAN.md Section 9).
// Ours; the MacLC model was audited against the manual and not taken (9.4).
//
// WHAT IS BUILT, AND WHAT IS NOT
//   Built: the eight registers of section 6; the initiator role; arbitration
//   with its bus-free filter (7); selection and the normal-mode signals of
//   the Initiator Command Register (6.2); non-block DMA in the initiator
//   role, which the Mac runs as pseudo-DMA (10.4) - send (6.8.1, 11.4) and
//   initiator receive (6.8.3, 11.6); the interrupts the SE/30's wiring can
//   raise (8.1, 8.3, 8.5, 8.6); the resets of section 9.
//   Not built, because the SE/30 cannot use them (sheet 6): the target
//   role (TARGETMODE, Start DMA Target Receive), block-mode DMA and READY
//   (READY is not connected), /EOP and its interrupt (/EOP is pulled up -
//   so END OF DMA, BSR bit 7, and the 53C80's LAST BYTE SENT, TCR bit 7,
//   read 0), the 5381's DIFF ENBL.  Parity is generated on the bus and
//   always good here (no device in the core drives a bad one), so PARITY
//   ERROR never sets.
//
// THE CPU SIDE
//   cs and dack are levels for the whole access (GLUE's SCSI* and
//   SCSIDACK*); rd/wr are one-clock pulses, one per byte cycle (GLUE's
//   strobe).  With cs, rs (A2-A0 = the CPU's A6-A4) picks the register;
//   with dack, a read is the Input Data Register and a write the Output
//   Data Register (4.1).  The two are never active together (10).
//   A DMA request is cleared by DACK (4.1: "DMA Acknowledge resets DRQ";
//   11.4/11.6 T1, "DRQ false from DACK true"), so DRQ is held low for as
//   long as dack is.
//
// THE SCSI SIDE
//   Signals are active high here (1 = asserted, as the registers show
//   them, 6.0); the bus outside is wired-OR.  o_* are what this chip
//   asserts; the b_* inputs are the bus as everyone drives it, this chip
//   included.
//
// PSEUDO-DMA, AS THE MANUAL'S TIMING DIAGRAMS ORDER IT
//   Initiator receive (11.6): REQ true with phase match latches the bus
//   into the Input Data Register (6.1.3) and asserts DRQ and ACK; DACK
//   clears DRQ; ACK is released once DACK has cycled and both DACK and
//   REQ are false (T8/T10).
//   Send (11.4): Start DMA Send raises DRQ for the first byte; a DACK write
//   loads the Output Data Register and clears DRQ; REQ true with phase
//   match asserts ACK with that byte on the bus; REQ false raises DRQ for
//   the next byte; ACK is released when DACK next goes false (T9, and
//   10.5.2: "the NCR 5380 requires DACK to cycle before ACK goes
//   inactive").
//   A phase mismatch "prevents the recognition of REQ and removes the chip
//   from the bus during an initiator send" (8.5); with DMA MODE set, a
//   mismatch when REQ goes true interrupts.  DRQ "does not reset when a
//   phase mismatch interrupt occurs" (6.7).  Resetting DMA MODE halts DMA
//   and drops DRQ (10.5.3).
//
// READINGS WHERE THE MANUAL IS SILENT (each is the plainest one)
//   - Start DMA Send raises DRQ at once (the first byte has nowhere else
//     to come from; the ROM waits on DRQ before its first DACK write).
//   - A bus reset (received, or issued through ICR bit 7) holds the chip
//     cleared, except the interrupt latch and ASSERT RST, while RST is on
//     the bus; ICR bit 7 stays writable so the CPU can release it (9.2,
//     9.3).
//   - Resetting DMA MODE also releases an ACK the DMA logic was holding:
//     in DMA mode "REQ and ACK are automatically controlled" (6.3).
//   - The selection interrupt is taken as written (8.1), with no exception
//     for the chip's own selection: the SE/30's ROM never sets the Select
//     Enable Register.

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
  input            b_bsy, b_sel, b_rst, b_atn, b_ack,
  input            b_req, b_msg, b_cd, b_io,
  input            b_sel_other,        // SEL asserted by a device other than this chip (lost arbitration)

  // what this chip asserts
  output     [7:0] o_db,
  output           o_db_en,
  output           o_bsy, o_sel, o_rst, o_atn, o_ack
);

  // ------------------------------------------------------------ registers
  reg  [7:0] odr;                      // 6.1.2 Output Data Register
  reg  [7:0] idr;                      // 6.1.3 Input Data Register
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
  wire       dbp = ~^b_db;                                        // odd parity (4.2)

  // the filters: 400 ns of bus free (7), 400 ns of BSY false (8.6), 400 ns
  // of a selection condition (8.1)
  reg  [4:0] free_n, nobsy_n, selc_n;
  wire       bus_free = (free_n  >= SETTLE);
  wire       bsy_lost = (nobsy_n >= SETTLE);
  wire       sel_cond = b_sel && !b_bsy && ((ser & b_db) != 8'h00);
  wire       sel_seen = (selc_n  >= SETTLE);

  // ------------------------------------------------------------ drive
  // arbitrating: BSY and the Output Data Register (6.2 AIP, 7); otherwise
  // ASSERT DATA BUS drives the ODR only as an initiator with I/O false and
  // the phase matching (6.2 bit 0, 8.5)
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
      3'd0: rdata = b_db;                                         // 6.1.1 Current SCSI Data
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
                  if (!wdata[1]) begin                             // 10.5.3: DMA MODE reset halts DMA
                    dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
                    byte_full <= 0; consumed <= 0; dack_cycled <= 0;
                  end
                  if (!wdata[0]) begin aip <= 0; la <= 0; end      // AIP "until the ARBITRATE bit is reset"
                end
          3'd3: tcr <= wdata[3:0];
          3'd4: ser <= wdata;
          3'd5: if (mr_dma) begin                                  // 6.8.1 Start DMA Send
                  dma_send <= 1; dma_irecv <= 0; dma_ack <= 0;
                  byte_full <= 0; consumed <= 0; drq_due <= 1;
                end
          3'd6: ;                                                  // 6.8.2 Start DMA Target Receive: target role, not built
          3'd7: if (mr_dma && !mr_target) begin                    // 6.8.3 Start DMA Initiator Receive
                  dma_irecv <= 1; dma_send <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0; dack_cycled <= 0;
                end
        endcase

        // ---------------------------------------------------- CPU reads
        if (rd && cs && rs == 3'd7) begin irq <= 0; busy_err <= 0; end   // 6.9 (BUSY ERROR re-latches while BSY stays lost)

        // ---------------------------------------------------- arbitration (7)
        if (mr_arb && !aip && bus_free) aip <= 1;
        if (aip && b_sel_other) la <= 1;

        // ---------------------------------------------------- DACK (4.1)
        // a DACK write is the Output Data Register whatever the mode; DACK
        // clears DRQ
        if (wr && dack) odr <= wdata;
        if (dack) drq <= 0;

        // ---------------------------------------------------- DMA
        // REQ is taken as a level ("REQ true", 11.4/11.6 T9 and T7): on a Mac
        // the target is usually already requesting the first byte when the
        // CPU writes the Start DMA register
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
            // "requires DACK to cycle before ACK goes inactive" (10.5.2)
            if (dma_ack && consumed && dack_fall) begin dma_ack <= 0; consumed <= 0; end
          end
          // DRQ rises with its cause, or when DACK goes false if DACK is
          // still active then (11.4/11.6 T2, "DACK false to DRQ true")
          if (drq_due && !dack) begin drq <= 1; drq_due <= 0; end
          // 8.5: a mismatch as REQ goes from false to true interrupts
          if (req_rise && !phase_match) irq <= 1;
        end

        // ---------------------------------------------------- loss of BSY (8.6, 6.7 bit 2)
        // the BUSY ERROR latch is level-sensitive (6.7); the interrupt, the
        // ICR clear and the DMA MODE reset happen as the loss is recognised
        if (mr_moncbsy && bsy_lost) busy_err <= 1;
        if (mr_moncbsy && !b_bsy && nobsy_n == SETTLE - 1) begin
          irq <= 1;
          icr_tm <= 0; icr_ack <= 0; icr_bsy <= 0; icr_sel <= 0; icr_atn <= 0; icr_data <= 0;
          mr[1] <= 0; dma_send <= 0; dma_irecv <= 0; dma_ack <= 0; drq <= 0; drq_due <= 0;
          byte_full <= 0; consumed <= 0; dack_cycled <= 0;
        end

        // ---------------------------------------------------- selection (8.1)
        if (sel_cond && selc_n == SETTLE - 1) irq <= 1;
      end
    end

endmodule
