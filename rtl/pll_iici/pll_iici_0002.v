// pll_iici_0002.v - the IIci's PLL (SE30_PLAN.md "THE MacIIci TOP AND ITS
// SDRAM"): one 1200 MHz VCO (50 MHz x 24) for every clock, in the shape the
// Altera PLL wizard emits (rtl/pll/pll_0002.v's), Quartus computing the
// counters from the frequencies.
//   outclk_0   50 MHz           clk_sys
//   outclk_1  150 MHz           clk_mem, the SDRAM controller
//   outclk_2  150 MHz +1042 ps  clk_sdc, the chip's clock (inverted at the pin)
//   outclk_3  150 MHz +5521 ps  clk_capa = clk_mem - 1.15 ns, read capture A (PROVISIONAL, iici_sdram.v)
//   outclk_4  150 MHz +4062 ps  clk_capb = clk_mem - 2.60 ns, read capture B (PROVISIONAL)
//   outclk_5   25 MHz           clk_k, the CPU clock (tg68k.v KCLK)
//   outclk_6   57.142857 MHz    clk_vid, the RBV's video: 1200 / 21, Table 12-5's 57.28 less 0.24 %
// Phase steps are the VCO's eighth, 104.2 ps.
`timescale 1ns/10ps
module  pll_iici_0002(
	input wire refclk,
	input wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire outclk_3,
	output wire outclk_4,
	output wire outclk_5,
	output wire outclk_6,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(7),
		.output_clock_frequency0("50.000000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("150.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("150.000000 MHz"),
		.phase_shift2("1042 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("150.000000 MHz"),
		.phase_shift3("5521 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("150.000000 MHz"),
		.phase_shift4("4062 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("25.000000 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("57.142857 MHz"),
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
		.outclk	({outclk_6, outclk_5, outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule
