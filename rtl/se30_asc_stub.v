// se30_asc_stub.v - the Apple Sound Chip, as a stub (SE30_PLAN.md Section
// 7): enough of the chip that a System waiting on it does not hang, and
// no sound.  The real ASC is its own section.
//
// WHAT IT ANSWERS (plan 7.3; the register facts are secondary - MacLC's
// rtl/asc.sv, from MAME - as no Apple document of them was found, 7.2)
//   $800        version: $00, the original ASC (the SE/30 ROM branches on
//               it, $4082F0B2)
//   $801-$80F   read back what was written ($801 the mode, $802 control,
//               $803 FIFO mode, $806 volume, $807 the clock rate)
//   $804        FIFO status: $0F - FIFO A and B both half empty (bits 0,
//               2) and empty (bits 1, 3), whatever is written to them
//   $000-$7FF   the FIFOs (and the wavetables): writes are dropped
//   SNDINT*     only in FIFO mode ($801 = 1): raised on a sample tick,
//               every 704 C16M (22,254.5 Hz), cleared by a read of $804.
//               Raised every clock it would storm (MacLC's finding).
//
// THE BUS
//   GLUE's device port, as the VIA takes it: an access lands at the
//   strobe on the C16M edge (sel && strobe && c16_en); rdata is
//   combinational.  A11-A0 are the chip's.  Held to sim/asc/tb_se30_asc_stub.v.

`timescale 1ns/1ps

module se30_asc_stub (
  input         clk,
  input         c16_en,                // C16M
  input         reset_n,

  input         sel,
  input         strobe,
  input         rw,                    // 1 = read
  input  [11:0] addr,                  // A11-A0
  input   [7:0] wdata,
  output  [7:0] rdata,

  output        irq_n                  // SNDINT*, to VIA2 CB1
);

  localparam [9:0] TICK = 10'd704;     // C16M a sample: 22,254.5 Hz

  reg [127:0] regs;                    // $80r at [8r+7:8r]; $800 and $804 unused
  reg   [9:0] tick;
  reg         irq;

  wire       acc   = c16_en && sel && strobe;
  wire       reg_a = (addr[11:4] == 8'h80);
  wire [3:0] r     = addr[3:0];
  wire [7:0] mode  = regs[15:8];

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      regs <= 128'd0; tick <= 0; irq <= 0;
    end else begin
      if (c16_en) tick <= (tick == TICK - 1'b1) ? 10'd0 : tick + 1'b1;
      if (acc && !rw && reg_a && r != 4'h0 && r != 4'h4) regs[{r, 3'b000} +: 8] <= wdata;
      if (acc && rw && reg_a && r == 4'h4) irq <= 0;
      else if (c16_en && tick == TICK - 1'b1 && mode == 8'h01) irq <= 1;
      if (mode != 8'h01) irq <= 0;
    end
  end

  assign rdata = !reg_a    ? 8'h00 :
                 r == 4'h0 ? 8'h00 :
                 r == 4'h4 ? 8'h0F : regs[{r, 3'b000} +: 8];
  assign irq_n = !irq;

endmodule
