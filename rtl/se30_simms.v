// se30_simms.v - the RAM SIMMs: where GLUE's RAM access lands in the SDRAM, for 8, 16, 32 or 64 MB.
// A bank aliases; an empty one reads ones; at 64 MB bank B repeats bank A, as the ROM's RAM test requires.

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
  assign empty = (size == 2'd1) && bank_b;       // 16 MB's bank B; 64 MB's repeats bank A

  initial empty_q = 1'b0;
  always @(posedge clk)
    if (start) empty_q <= sel && empty;

endmodule
