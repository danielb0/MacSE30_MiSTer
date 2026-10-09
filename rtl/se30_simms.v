// se30_simms.v - the RAM SIMMs: where GLUE's RAM access lands in the SDRAM, for 8 MB (four
// 1 MB SIMMs a bank) or 16 MB (four 4 MB SIMMs in bank A). A bank aliases; an empty one reads ones.

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
