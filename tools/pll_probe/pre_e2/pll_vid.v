`timescale 1 ps / 1 ps
// pll_vid - the IIcx card's dot clock, 30.24 MHz (rtl/pll_vid/pll_vid_0002.v).
module pll_vid (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  locked
	);
	pll_vid_0002 pll_inst (
		.refclk   (refclk),
		.rst      (rst),
		.outclk_0 (outclk_0),
		.locked   (locked)
	);
endmodule
