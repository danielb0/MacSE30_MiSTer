// se30_fpu_unpack.v - source operand unpacking into the APU's internal format

`timescale 1ns/1ps
`include "fpu_ucode.vh"

module se30_fpu_unpack (
  input             is_fp,
  input      [79:0] fp,
  input      [2:0]  fmt,
  input      [95:0] operand,
  output reg [85:0] word,
  output     [2:0]  tag,
  output            snan,
  output            den,
  output            neg
);
  reg [85:0] tw;

  reg [31:0] iv;
  reg        in;
  reg [31:0] im;
  reg [7:0]  se;
  reg [22:0] sf;
  reg [10:0] de;
  reg [51:0] df;

  always @* begin
    iv = 32'd0; in = 1'b0; im = 32'd0;
    se = operand[30:23]; sf = operand[22:0];
    de = operand[62:52]; df = operand[51:0];
    word = 86'd0;
    if (is_fp)
      word = {fp[79], 3'd0, fp[78:64], fp[63:0], 3'd0};
    else
      case (fmt)
        3'd0, 3'd4, 3'd6: begin
          iv = (fmt == 3'd0) ? operand[31:0]
             : (fmt == 3'd4) ? {{16{operand[15]}}, operand[15:0]}
             :                 {{24{operand[7]}}, operand[7:0]};
          in = iv[31];
          im = in ? -iv : iv;
          word = {in, 18'd0, 35'd0, im};
        end
        3'd1:
          if (se == 8'hFF)
            word = {operand[31], 18'h07FFF, (sf == 23'd0) ? 67'd0 : {1'b1, sf, 43'd0}};
          else if (se == 8'd0)
            word = (sf == 23'd0) ? {operand[31], 85'd0}
                                 : {operand[31], 18'd16257, 1'b0, sf, 43'd0};
          else
            word = {operand[31], {10'd0, se} + 18'd16256, 1'b1, sf, 43'd0};
        3'd5:
          if (de == 11'h7FF)
            word = {operand[63], 18'h07FFF, (df == 52'd0) ? 67'd0 : {1'b1, df, 14'd0}};
          else if (de == 11'd0)
            word = (df == 52'd0) ? {operand[63], 85'd0}
                                 : {operand[63], 18'd15361, 1'b0, df, 14'd0};
          else
            word = {operand[63], {7'd0, de} + 18'd15360, 1'b1, df, 14'd0};
        3'd2:
          word = {operand[95], 3'd0, operand[94:80], operand[63:0], 3'd0};
        default:
          word = 86'd0;
      endcase
    if (!is_fp && (fmt == 3'd0 || fmt == 3'd4 || fmt == 3'd6))
      tw = {in, 18'h03FFF, (im != 32'd0), 66'd0};
    else
      tw = word;
  end

  wire [17:0] te = tw[84:67];
  wire [66:0] tm = tw[66:0];
  assign tag  = (te == 18'h07FFF) ? ((tm[65:3] != 63'd0) ? `TAG_NAN : `TAG_INF)
              : (tm == 67'd0)     ? `TAG_ZERO
              : tm[66]            ? `TAG_NORM : `TAG_UNN;
  assign snan = (tag == `TAG_NAN) && !tm[65];
  assign den  = (te == 18'd0) && (tm != 67'd0) && !tm[66];
  assign neg  = tw[85];
endmodule
