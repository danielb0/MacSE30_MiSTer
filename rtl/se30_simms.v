// The SE/30's RAM SIMMs (plan 13.4, FUTURE ADDITIONS 5): where an access
// GLUE sends to RAM lands in the SDRAM, for the four configurations the OSD
// offers.
//
//   size = 0   8 MB: four 1 MB SIMMs (1 Mbit chips) in each bank
//   size = 1  16 MB: four 4 MB SIMMs (4 Mbit chips) in bank A, bank B empty
//   size = 2  32 MB: four 4 MB SIMMs in each bank
//   size = 3  64 MB: four 16 MB SIMMs (16 Mbit chips) in bank A, bank B empty
//
// GLUE (se30_glue.v) puts bank B at the RAMSIZ boundary, A20/A22/A24/A26
// for RAMSIZ 00-11 (Guide Table 4-10, plan 2.11.2), and hands over a flat
// longword address with that boundary at bit 18 + 2 x RAMSIZ.  What the
// SIMMs add is what the chips do with it:
//   - a chip decodes only its own address pins, so a bank aliases modulo
//     its chips' size inside GLUE's bank range;
//   - an empty bank keeps nothing, and a read of it returns what the
//     floating bus last held.  The ROM's sizing probe ($40803610) drives
//     $FFFFFFFF onto the bus (two writes to $4) before every read-back,
//     so an empty bank reads all ones (plan 13.4.1).
// The ROM's sizing (plan 13.4.1) relies on exactly these two: it finds
// RAMSIZ 01 and 8 MB, RAMSIZ 10 and 16 MB, RAMSIZ 10 and 32 MB, or
// RAMSIZ 11 and 64 MB.
//
// Undocumented and never reached by the ROM's sizing: what GLUE drives on
// a chip's top address pins while RAMSIZ is below the chips' size.  This
// model drives 0 there.
//
// The SDRAM: the RAM's 16 MB units go to 0, 32, 48 and 64 MB, around the
// system region at 16-32 MB (the floppy image, the IIcx card's VRAM, the
// ROM, the read-capture training pair), so 8 and 16 MB map as before this
// module grew, 32 MB needs a 64 MB module and 64 MB a 128 MB one (its top
// 16 MB on the module's second chip).
//
// For 8 MB with RAMSIZ 01 (where the ROM leaves it) the address is
// ram_addr[20:0] for every access, as before this module.

module se30_simms (
  input             clk,
  input       [1:0] size,              // 0 = 8, 1 = 16, 2 = 32, 3 = 64 MB (latched at reset by the top)
  input       [1:0] ramsiz,            // VIA2 PA7:6
  input      [24:0] ram_addr,          // GLUE's longword address, flat over both banks
  input             start,             // an access (RAM or ROM) starts: latch empty_q
  input             sel,               // ... and it is a RAM access (a ROM access clears empty_q)
  output     [24:0] phys,              // longword address in the SDRAM
  output            empty,             // this access is to an empty bank (write it as a read)
  output reg        empty_q            // ... held for the access: the data reads all ones
                                       // (the machine ORs it into the one data bus GLUE
                                       // takes for both RAM and ROM, so a ROM access must
                                       // clear it)
);

  // bank B is GLUE's boundary bit; the offset is what lies below it
  reg        bank_b;
  reg [23:0] offset;
  always @* begin
    case (ramsiz)
      2'd0: begin bank_b = ram_addr[18]; offset = {6'b0, ram_addr[17:0]}; end
      2'd1: begin bank_b = ram_addr[20]; offset = {4'b0, ram_addr[19:0]}; end
      2'd2: begin bank_b = ram_addr[22]; offset = {2'b0, ram_addr[21:0]}; end
      default: begin bank_b = ram_addr[24]; offset = ram_addr[23:0]; end
    endcase
  end

  // the RAM as one linear longword address: 1 Mbit chips 4 MB a bank (20
  // longword bits), 4 Mbit 16 MB (22), 16 Mbit 64 MB (24)
  reg [23:0] lin;
  always @* begin
    case (size)
      2'd0:    lin = {3'b0, bank_b, offset[19:0]};
      2'd1:    lin = {2'b0, offset[21:0]};
      2'd2:    lin = {1'b0, bank_b, offset[21:0]};
      default: lin = offset[23:0];
    endcase
  end

  // its 16 MB units around the system region: 0, 2, 3, 4
  reg [2:0] unit;
  always @*
    case (lin[23:22])
      2'd0: unit = 3'd0;
      2'd1: unit = 3'd2;
      2'd2: unit = 3'd3;
      default: unit = 3'd4;
    endcase

  assign phys  = {unit, lin[21:0]};
  assign empty = size[0] && bank_b;

  initial empty_q = 1'b0;
  always @(posedge clk)
    if (start) empty_q <= sel && empty;

endmodule
