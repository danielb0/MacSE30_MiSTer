// pll.v - the core's one PLL (SE30_PLAN.md 3.2, 3.8 item 18), in the
// two-file shape the Altera PLL wizard emits for the MiSTer cores.  Written
// by hand, not generated: the instance in pll/pll_0002.v names the
// frequencies and phases and Quartus derives M, N and the output counters
// at synthesis.
//
//   outclk_0  clk_sys   31.3344 MHz  2 x C16M - the SE/30's own oscillator
//                                    (Y2, 31.3344 MHz, plan 2.5)
//   outclk_1  clk_mem   94.0032 MHz  3 x clk_sys, the SDRAM controller's
//   outclk_2  clk_sdc   94.0032 MHz  clk_mem + 1.064 ns: the SDRAM chip's
//                                    clock, inverted at the pin
//   outclk_3  clk_capa  94.0032 MHz  clk_mem - 0.266 ns: read-data capture
//                                    A, for slow silicon
//   outclk_4  clk_capb  94.0032 MHz  clk_mem - 2.261 ns: read-data capture
//                                    B, for fast silicon
//
// All five come from one VCO (940.032 MHz) through integer counters, so
// they are related clocks and STA times every crossing exactly
// (MacSE30.sdc).  The three phases are rtl/se30_sdram.v's header.

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  outclk_1, // outclk1.clk
		output wire  outclk_2, // outclk2.clk
		output wire  outclk_3, // outclk3.clk
		output wire  outclk_4, // outclk4.clk
		output wire  locked    //  locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.outclk_1 (outclk_1), // outclk1.clk
		.outclk_2 (outclk_2), // outclk2.clk
		.outclk_3 (outclk_3), // outclk3.clk
		.outclk_4 (outclk_4), // outclk4.clk
		.locked   (locked)    //  locked.export
	);

endmodule
