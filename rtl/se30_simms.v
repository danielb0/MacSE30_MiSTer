// se30_simms.v - RAM SIMM configurations (8 MB, 16 MB) mapped into SDRAM

module se30_simms (
  input             clk,
  input             big,
  input       [1:0] ramsiz,
  input      [24:0] ram_addr,
  input             start,
  input             sel,
  output     [21:0] phys,
  output            empty,
  output reg        empty_q
);

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

  assign phys  = big ? offset[21:0] : {1'b0, bank_b, offset[19:0]};
  assign empty = big && bank_b;

  initial empty_q = 1'b0;
  always @(posedge clk)
    if (start) empty_q <= sel && empty;

endmodule
