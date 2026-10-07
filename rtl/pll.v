// pll.v - the core's PLL

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  outclk_1,
		output wire  outclk_2,
		output wire  outclk_3,
		output wire  outclk_4,
		output wire  locked
	);

	pll_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.outclk_1 (outclk_1),
		.outclk_2 (outclk_2),
		.outclk_3 (outclk_3),
		.outclk_4 (outclk_4),
		.locked   (locked)
	);

endmodule
