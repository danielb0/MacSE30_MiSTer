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
