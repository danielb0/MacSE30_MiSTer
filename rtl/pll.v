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
//   outclk_5  clk_pix   30.2153 MHz  IIcx only (`MACIICX): the video card's
//                                    dot clock, the nearest this VCO comes
//                                    to the card's 30.24 MHz (-0.082 %)
//
// The SE/30's five come from one VCO at 940.032 MHz through integer
// counters (30, 10, 10, 10, 10), so they are related clocks and STA times
// every crossing exactly (MacSE30.sdc).  The three phases are
// rtl/se30_sdram.v's header.
//
// The IIcx (KNOWN ISSUES 24, 2026-10-23): the card's dot clock must come
// from this PLL - the framework's HDMI clock switch takes CLK_VIDEO only
// from a PLL on pll_hdmi's edge of the chip, and that edge has two PLLs,
// pll_hdmi's and ours - and no VCO divides to both 31.3344 and 30.24
// (544/525).  So the IIcx's VCO is 846.0288 MHz (counters 27, 9, 9, 9, 9,
// 28: clk_sys and clk_mem exact, the dot clock 30.2153 MHz), and the three
// phases are re-quantised to that VCO's 147.7 ps step: +1034, -296 and
// -2219 ps for +1064, -266 and -2261 (30-42 ps moves on margins of over a
// nanosecond; sta_corners is the verdict).  Exact 30.24 MHz needs a PLL of
// its own on that edge, which needs the SDRAM capture select redesigned -
// the plan's KNOWN ISSUES 24 lists every route tried and the ones left.

`timescale 1 ps / 1 ps
module pll (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  outclk_1, // outclk1.clk
		output wire  outclk_2, // outclk2.clk
		output wire  outclk_3, // outclk3.clk
		output wire  outclk_4, // outclk4.clk
`ifdef MACIICX
		output wire  outclk_5, // outclk5.clk - the IIcx card's dot clock
`endif
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
`ifdef MACIICX
		.outclk_5 (outclk_5), // outclk5.clk
`endif
		.locked   (locked)    //  locked.export
	);

endmodule
