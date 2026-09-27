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
# clk_sys -> clk_mem: the SDRAM controller's input registers (plan 3.2).
# ----------------------------------------------------------------------------
# The controller samples the machine's request bundle (start, request, R/W,
# address, byte enables, write data, the download port) on the SECOND clk_mem
# edge after each clk_sys edge - rtl/se30_sdram.v, sample_en and the xs_*
# registers - because the bundle is the kernel's address adder and the beat
# engine's byte routing: 12 logic levels, 15.1 ns of data delay in the first
# compile (2026-09-27), against the 10.6 ns single-cycle window between the
# related clocks (-5.7 ns).  The second edge gives it 21.3 ns.  This credit
# states exactly that, for exactly those registers; the hold check stays on
# the default edge.  Nothing else between the two clocks is relaxed: the
# controller's outputs to GLUE (ack, read data) are honest single-cycle paths
# and passed (+2.9 ns).  The phi_q register is NOT in the set: it is sampled
# on the first edge, and is a register-to-register hop.
set_multicycle_path -setup -end 2 -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_keepers {*|se30_sdram:sdram|xs_*}]
set_multicycle_path -hold  -end 1 -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_keepers {*|se30_sdram:sdram|xs_*}]

# ----------------------------------------------------------------------------
# SDRAM interface I/O constraints (plan 3.2; MacLC's 2026-09-12 derivation,
# the same chips, our clock).
# ----------------------------------------------------------------------------
# SDRAM_CLK is altddio_out(datain_h=0, datain_l=1) of clk_mem, i.e. the
# INVERTED clk_mem, so the chip's rising edges are the FPGA's falling edges -
# at the pin, about 4 ns later than in the fabric (the second compile's STA,
# 2026-09-27: -3.97 ns of clock skew on the read-data paths, the clock's
# delay through the DDR cell and the pin).  rtl/se30_sdram.v captures read
# data in an I/O-cell register (dq_q) on the RISING edge of clk_mem one and
# a half periods after the launch edge, and consumes it in the fabric on the
# rising edge after that, an ordinary same-clock path.  The capture edge is
# a multicycle, stated below.
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

# The read-data capture edge.  A word is at the pin from (skew 4.0 + tAC 6.5)
# 10.5 ns after the FPGA's falling edge to (skew + the 10.64 ns period + tOH
# 2.5) 17.1 ns after it.  The default capture edge, the next falling edge at
# 10.64 ns, is 0.1 ns into that eye: the second compile's -2.49 ns (MacLC's
# choice of edge, which its slower clock affords).  The rising edge after,
# at 15.96 ns, is 5.4 ns into the eye with 1.1 ns to spare, and that is the
# edge dq_q clocks on.  From sdram_clk's rising edge the first rising edge of
# clk_mem is half a period away, so the capture edge is the SECOND: a
# two-cycle setup multicycle.  NO hold multicycle goes with it, unlike the
# xs_* credit above: the default hold check that a setup multicycle of 2
# brings - the same launch edge against the capture edge one period earlier,
# a 5.3 ns relationship - is exactly the physical requirement that the NEXT
# word (launched a period later) must not reach the register before the
# capture edge, and the STA must check it.
set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_keepers {*|se30_sdram:sdram|dq_q[*]}]

# FPGA -> chip (address, command, write data, byte masks)
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT
