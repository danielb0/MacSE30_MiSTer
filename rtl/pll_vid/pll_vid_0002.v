// pll_vid_0002.v - the altera_pll instance behind rtl/pll_vid.v: the IIcx
// build's Macintosh II Video Card dot clock (SE30_PLAN.md 14.3 item 4).
// Hand-written in the wizard's shape, as rtl/pll/pll_0002.v is; the
// frequency is the whole specification and Quartus computes the counters.
// 30.24 MHz is the book's dot clock (*Designing Cards and Drivers*, Figure
// 11-3: 864 x 525 at 66.67 Hz); the main PLL's VCO (940.032 MHz) has no
// integer division to it, hence a PLL of its own: VCO 907.2 MHz = 30 x
// 30.24.  Its reference is clk_sys (31.3344 MHz, the main PLL's output on a
// global network), not the 50 MHz pin: the DE10-Nano's three 50 MHz inputs
// each feed the one fractional PLL beside them, and all three are taken
// (HDMI, audio, the main PLL) - the first fit put this PLL on CLK2's and
// failed (Error 11239, plan 14.3).  31.3344 to 30.24 MHz is a fractional
// ratio, which this PLL type takes.

`timescale 1ns/10ps
module  pll_vid_0002(
	// interface 'refclk'
	input wire refclk,
	// interface 'reset'
	input wire rst,
	// interface 'outclk0'
	output wire outclk_0,
	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("31.3344 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(1),
		.output_clock_frequency0("30.240000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("0 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	(outclk_0),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
