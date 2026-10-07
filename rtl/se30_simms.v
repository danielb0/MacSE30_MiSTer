// The SE/30's RAM SIMMs (plan 13.4): where an access GLUE sends to RAM
// lands in the SDRAM, for the two configurations the OSD offers.
//
//   big = 0   8 MB: four 1 MB SIMMs (1 Mbit chips) in each bank
//   big = 1  16 MB: four 4 MB SIMMs (4 Mbit chips) in bank A, bank B empty
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
// RAMSIZ 01 and 8 MB, or RAMSIZ 10 and 16 MB.
//
// Undocumented and never reached by the ROM's sizing: what GLUE drives on
// a chip's top address pins while RAMSIZ is below the chips' size.  This
// model drives 0 there.
//
// For 8 MB with RAMSIZ 01 (where the ROM leaves it) the address is
// ram_addr[20:0] for every access, as before this module.

module se30_simms (
  input             clk,
  input             big,               // 0 = 8 MB, 1 = 16 MB (latched at reset by the top)
  input       [1:0] ramsiz,            // VIA2 PA7:6
  input      [24:0] ram_addr,          // GLUE's longword address, flat over both banks
  input             start,             // an access (RAM or ROM) starts: latch empty_q
  input             sel,               // ... and it is a RAM access (a ROM access clears empty_q)
  output     [21:0] phys,              // longword address in the SDRAM's RAM area
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

  // 1 Mbit chips: 4 MB a bank, 20 longword bits; 4 Mbit: 16 MB, 22
  assign phys  = big ? offset[21:0] : {1'b0, bank_b, offset[19:0]};
  assign empty = big && bank_b;

  initial empty_q = 1'b0;
  always @(posedge clk)
    if (start) empty_q <= sel && empty;

endmodule
