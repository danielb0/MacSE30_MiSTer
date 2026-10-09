// pll.v - the core's PLL, in the wizard's two-file shape: clk_sys 31.3344 MHz (2 x C16M),
// clk_mem 94.0032 MHz (3 x), the SDRAM chip's clock and two read-capture clocks, from one VCO.

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   // refclk.clk
		input  wire  rst,      // reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  outclk_1, // outclk1.clk
		output wire  outclk_2, // outclk2.clk
		output wire  outclk_3, // outclk3.clk
		output wire  outclk_4, // outclk4.clk
		output wire  locked    // locked.export
	);

	pll_0002 pll_inst (
		.refclk   (refclk),   // refclk.clk
		.rst      (rst),      // reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.outclk_1 (outclk_1), // outclk1.clk
		.outclk_2 (outclk_2), // outclk2.clk
		.outclk_3 (outclk_3), // outclk3.clk
		.outclk_4 (outclk_4), // outclk4.clk
		.locked   (locked)    // locked.export
	);

endmodule
