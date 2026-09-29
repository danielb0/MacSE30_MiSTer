// se30_fpu_cond.v - the BIU's conditional predicate (plan 8.6.9): FBcc,
// FDBcc, FScc, FTRAPcc and FNOP's test of FPCC, held to
// tools/fpu_ucode/sim.py (predicate) through sim/fpu.
//
// The predicate against FPCC is a 16 x 32 truth table, the assembler's
// `FPU_CC_TABLE (sim.predicate: the model's default for 8.6.14 item 17).
// Predicates with bit 4 set are the IEEE-aware ones that signal: with
// FPCC's NAN set they set BSUN (and AEXC's IOP), and the BIU takes the
// BSUN exception if it is enabled.  Pure logic.

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
