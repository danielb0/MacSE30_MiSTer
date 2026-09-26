derive_pll_clocks
derive_clock_uncertainty

# core specific constraints (SE30_PLAN.md 3.2)
#
# clk_sys (31.3344 MHz, 2 x C16M) and clk_mem (94.0032 MHz, 3 x clk_sys) are
# the two outputs of the one PLL in rtl/pll, so derive_pll_clocks makes them
# related clocks and STA times every path between them exactly.  Nothing is
# relaxed across that boundary: MacLC's Phase C history (its MacLC.sdc) is a
# multicycle credit there that hid a 6.7 ns violation and corrupted memory.
#
# No credit on the kernel either, until the first compile has been read for
# Quartus 332125/332081 (a structural combinational loop, which is what made
# MacLC's two-period kernel credit unsafe for four months).  The argument for
# the credit - the wrapper advances the kernel at most once per C16M, two
# clk_sys - is in the plan, and it is applied here only with that check done.

# ----------------------------------------------------------------------------
# SDRAM interface I/O constraints (plan 3.2; MacLC's 2026-09-12 derivation,
# the same chips, our clock).
# ----------------------------------------------------------------------------
# SDRAM_CLK is altddio_out(datain_h=0, datain_l=1) of clk_mem, i.e. the
# INVERTED clk_mem, so the chip's rising edges are the FPGA's falling edges.
# rtl/se30_sdram.v captures read data in an I/O-cell register on the falling
# edge of clk_mem (the chip's next edge after the launch), re-times it once
# in the fabric on the following falling edge and consumes it on a rising
# edge after that - all ordinary same-clock paths STA checks natively.
#
# Delays: W9825G6KH-6 and AS4C32M16SB-7, the worse of the two at each row
# (plan 3.2's table): tAC(CL2) 6.0 ns, tOH 2.5 ns, tIS/tDS 1.5 ns, tIH/tDH
# 0.8 ns, plus 0.5 ns of board trace on the max numbers.
#
# sdram_clk is deliberately NOT added to any exclusive clock group: a clock
# in no group stays related to every other, which is what makes these paths
# get timed against clk_mem instead of being cut.
create_generated_clock -name sdram_clk -invert \
  -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# chip -> FPGA (read data)
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]

# FPGA -> chip (address, command, write data, byte masks)
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT
