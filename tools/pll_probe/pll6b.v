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
module pll6b (
		input  wire  refclk,   //  refclk.clk
		input  wire  rst,      //   reset.reset
		output wire  outclk_0, // outclk0.clk
		output wire  outclk_1, // outclk1.clk
		output wire  outclk_2, // outclk2.clk
		output wire  outclk_3, // outclk3.clk
		output wire  outclk_4, // outclk4.clk
		output wire  outclk_5, // outclk5.clk
		output wire  locked    //  locked.export
	);

	pll6b_0002 pll_inst (
		.refclk   (refclk),   //  refclk.clk
		.rst      (rst),      //   reset.reset
		.outclk_0 (outclk_0), // outclk0.clk
		.outclk_1 (outclk_1), // outclk1.clk
		.outclk_2 (outclk_2), // outclk2.clk
		.outclk_3 (outclk_3), // outclk3.clk
		.outclk_4 (outclk_4),
		.outclk_5 (outclk_5), // outclk4.clk
		.locked   (locked)    //  locked.export
	);

endmodule

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
module  pll6b_0002(
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
	output wire outclk_5,
	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(6),
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
		.output_clock_frequency5("30.215314 MHz"),
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
		.outclk	({outclk_5, outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
