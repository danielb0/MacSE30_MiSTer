// pll.v - the core's one PLL (SE30_PLAN.md 3.2), in the two-file shape the
// Altera PLL wizard emits for the MiSTer cores.  Written by hand, not
// generated: the instance in pll/pll_0002.v names the two frequencies and
// Quartus derives M, N and the output counters at synthesis.
//
//   outclk_0  clk_sys  31.3344 MHz  2 x C16M - the SE/30's own oscillator
//                                   (Y2, 31.3344 MHz, plan 2.5)
//   outclk_1  clk_mem  94.0032 MHz  3 x clk_sys, the SDRAM controller's
//
// Both come from one VCO (940.032 MHz) through integer counters, so they
// are related clocks and STA times the crossing exactly (MacSE30.sdc).

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  outclk_1, // outclk1.clk
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.outclk_1 (outclk_1), // outclk1.clk
		.locked   (locked)    //  locked.export
	);

endmodule
