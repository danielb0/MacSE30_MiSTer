// pll_iici.v - the IIci's one PLL (rtl/pll_iici/pll_iici_0002.v has the clocks)
`timescale 1 ps / 1 ps
module pll_iici (
		input  wire  refclk,
		input  wire  rst,
		output wire  outclk_0,
		output wire  outclk_1,
		output wire  outclk_2,
		output wire  outclk_3,
		output wire  outclk_4,
		output wire  outclk_5,
		output wire  outclk_6,
		output wire  locked
	);
	pll_iici_0002 pll_inst (
		.refclk(refclk), .rst(rst),
		.outclk_0(outclk_0), .outclk_1(outclk_1), .outclk_2(outclk_2), .outclk_3(outclk_3),
		.outclk_4(outclk_4), .outclk_5(outclk_5), .outclk_6(outclk_6),
		.locked(locked)
	);
endmodule
