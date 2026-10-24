// pll_0002.v - the altera_pll instance behind rtl/pll.v (SE30_PLAN.md 3.2,
// 3.8 item 18).  Hand-written in the wizard's shape; the frequencies and
// phases are the whole specification and Quartus computes the counters.
// Reference: the DE10-Nano's 50 MHz.  VCO 940.032 MHz = 31.3344 x 30 =
// 94.0032 x 10, inside Cyclone V's 600-1600 MHz range; the fractional
// multiplier is 18.80064.
//
// The phase shifts are multiples of the VCO phase step, an eighth of the
// VCO period (1063.8 / 8 = 132.98 ps), so Quartus need not round them,
// and are given as positive shifts inside one 10.638 ns period:
//   outclk_2   +1064 ps =  8 steps   the SDRAM chip's clock (inverted at
//                                    the pin by rtl/se30_sdram.v)
//   outclk_3  +10372 ps = 78 steps   read-data capture A, 0.266 ns BEFORE
//                                    clk_mem's edge
//   outclk_4   +8377 ps = 63 steps   read-data capture B, 2.261 ns before
// Why these numbers is rtl/se30_sdram.v's header and MacSE30.sdc.

`timescale 1ns/10ps
module  pll_0002(
	// interface 'refclk'
	input wire refclk,
	// interface 'reset'
	input wire rst,
	// interface 'outclk0'
	output wire outclk_0,
	// interface 'outclk1'
	output wire outclk_1,
	// interface 'outclk2'
	output wire outclk_2,
	// interface 'outclk3'
	output wire outclk_3,
	// interface 'outclk4'
	output wire outclk_4,
	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(5),
		.output_clock_frequency0("31.334400 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("94.003200 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("94.003200 MHz"),
		.phase_shift2("1064 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("94.003200 MHz"),
		.phase_shift3("10372 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("94.003200 MHz"),
		.phase_shift4("8377 ps"),
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
		.outclk	({outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
