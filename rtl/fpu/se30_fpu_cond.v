// se30_fpu_cond.v - the 68882's conditional predicate (FBcc, FDBcc, FScc, FTRAPcc, FNOP): a
// 16 x 32 truth table against FPCC; the IEEE-aware predicates set BSUN on a NaN.

`timescale 1ns/1ps
`include "fpu_ucode.vh"

module se30_fpu_cond (
  input  [5:0] pred,             // the condition field; bit 5 is ignored
  input  [3:0] fpcc,             // FPSR 27-24: N, Z, I, NAN
  output       taken,
  output       bsun              // set BSUN (and IOP)
);
  localparam [511:0] TABLE = `FPU_CC_TABLE;

  assign taken = TABLE[{fpcc, pred[4:0]}];
  assign bsun  = pred[4] & fpcc[0];
endmodule
