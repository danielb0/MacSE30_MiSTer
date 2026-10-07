// se30_fpu_cond.v - the 68882's conditional predicates (FBcc, FDBcc, FScc, FTRAPcc)

`timescale 1ns/1ps
`include "fpu_ucode.vh"

module se30_fpu_cond (
  input  [5:0] pred,
  input  [3:0] fpcc,
  output       taken,
  output       bsun
);
  localparam [511:0] TABLE = `FPU_CC_TABLE;

  assign taken = TABLE[{fpcc, pred[4:0]}];
  assign bsun  = pred[4] & fpcc[0];
endmodule
