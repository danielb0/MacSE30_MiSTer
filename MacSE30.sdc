derive_pll_clocks
derive_clock_uncertainty

# core specific constraints (SE30_PLAN.md 3.2)
#
# clk_sys (31.3344 MHz, 2 x C16M), clk_mem (94.0032 MHz, 3 x clk_sys) and
# clk_mem's two phase-shifted copies clk_sdc (+2.128 ns, the SDRAM chip's
# clock) and clk_capa (+3.058 ns, read-data capture A) are the four outputs
# of the one PLL in rtl/pll, so derive_pll_clocks makes them related clocks
# and STA times every path between them exactly.  Nothing is relaxed across
# those boundaries: MacLC's Phase C history (its MacLC.sdc) is a multicycle
# credit there that hid a 6.7 ns violation and corrupted memory.
#
# MacSE30.qsf runs the analysis at every corner (TIMEQUEST_MULTICORNER_
# ANALYSIS ON, plan 3.8 item 18): a slack is met only when it is met at all
# four.  scripts/sta_corners.tcl prints the SDRAM interface's per corner.
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
# SDRAM_CLK is altddio_out(datain_h=0, datain_l=1) of clk_sdc, i.e. the
# INVERTED clk_sdc, so the chip's rising edges are clk_sdc's falling edges,
# 6.38 ns after clk_mem's rising edges in the fabric - at the pin, about 4
# ns later still (the second compile's STA, 2026-09-27: -3.97 ns of clock
# skew on the read-data paths, the clock's delay through the DDR cell and
# the pin).  Until plan 3.8 item 18 the chip clocked on inverted clk_mem
# itself; the 1.064 ns shift balances our outputs' setup and hold at the
# chip (about 2.4 ns each at the slow corner, item 18's experiment).
#
# Delays: W9825G6KH-6 and AS4C32M16SB-7, the worse of the two at each row
# (plan 3.2's table): tAC(CL2) 6.0 ns, tOH 2.5 ns, tIS/tDS 1.5 ns, tIH/tDH
# 0.8 ns, plus 0.5 ns of board trace on the max numbers.
#
# sdram_clk is deliberately NOT added to any exclusive clock group: a clock
# in no group stays related to every other, which is what makes these paths
# get timed against the capture clocks instead of being cut.
create_generated_clock -name sdram_clk -invert \
  -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# chip -> FPGA (read data)
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]

# The read-data capture (plan 3.8 item 18, 4.11 item 8).  rtl/se30_sdram.v
# captures read data in ONE I/O-cell register, dq_q, whose clock a clock
# control block selects at power-up between capture A (clk_capa, 0.266 ns
# before clk_mem's edge) and capture B (clk_capb, 2.261 ns before), by a
# training read.  Why: a word is at the pin for about 6.6 ns, and the
# point in that eye at which a fixed edge lands moves 3.9 ns between the
# slow and fast timing corners, leaving less than a nanosecond in which
# one edge is inside it at every corner; compile 6's single-corner "met"
# hid -0.128 ns of hold at the fast -40C corner (4.11 item 8's table).
# Two edges 2 ns apart cover the four corners: A the slow ones by at least
# 1.40 ns, B the fast ones by at least 1.89 (item 18's experiment, whose
# clock paths match the core's within 0.1 ns).
#
# STA sees both clocks reach dq_q through the select block and times the
# capture under each.  The honest reading is that AT EVERY CORNER AT LEAST
# ONE of the two is met, never that both are - by design one fails at each
# corner - and only scripts/sta_corners.tcl can make that reading; the
# compile flow's fitter and STA cannot, so for them the capture is cut:
# the fitter would otherwise chase an impossible pair with the SDRAM_DQ
# input delay chains (compile 6's had 1.5-2.5 ns of chain on those pins,
# tuning one capture as far as it could go), and the flow's summary would
# always say "not met".  The chains are pinned to zero in MacSE30.qsf, so
# the capture's timing is the silicon's and the experiment's.  The
# constraint itself, read by sta_corners.tcl (it sets se30_time_capture
# before read_sdc): from sdram_clk's rising edge (6.38 ns after clk_mem's)
# the first rising edge of either capture clock is inside the same period
# and the word is valid only from 10.5 ns after the launch, so the capture
# edge is the SECOND one for both clocks: a two-cycle setup multicycle,
# stating 14.63 ns from launch to capture for A and 12.63 for B.  NO hold
# multicycle goes with it, unlike the xs_* credit above: the default hold
# check that a setup multicycle of 2 brings - the same launch edge against
# the capture edge one period earlier, 3.99 ns for A and 1.99 for B - is
# exactly the physical requirement that the NEXT word (launched a period
# later) must not reach the register before the capture edge, and the STA
# must check it.
if {[info exists ::se30_time_capture]} {
  set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_keepers {*|se30_sdram:sdram|dq_q[*]}]
} else {
  set_false_path -from [get_clocks {sdram_clk}] -to [get_keepers {*|se30_sdram:sdram|dq_q[*]}]
}

# The two capture clocks never run the same register at the same time -
# the select block passes one or the other - but STA sees both reach dq_q
# and dq_w and would time the phantom crossings between them (dq_q on B to
# dq_w on A: a 2 ns relationship on a 6 ns path).  Exclusive groups cut
# exactly those; a clock in no group (sdram_clk, clk_mem) stays related to
# both, so the capture and the dq_w -> dq_m crossing are still timed.
set_clock_groups -exclusive \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]

# From dq_q onward (rtl/se30_sdram.v's timeline) every path is an ordinary
# single-cycle one and takes no credit: dq_q -> dq_w on the capture clock
# (a full period for the cell-to-fabric path, which is most of one at the
# slow corner); dq_w -> dq_m on clk_mem's FALLING edge, 5.6 ns from A's
# edge and 7.6 from B's; dq_m -> cpu_rdata and the training compare, half
# a period.  This is what the falling-edge stage buys: the two capture
# edges straddle nothing, so no consumer path needs a multicycle with a
# short hold check behind it.

# FPGA -> chip (address, command, write data, byte masks)
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT

# ----------------------------------------------------------------------------
# The 68882's APU (plan 8.9.5): two clk_sys for its datapath.
# ----------------------------------------------------------------------------
# rtl/fpu/se30_fpu_apu.v runs one microinstruction per FPU clock (C16M, two
# clk_sys, ce = phi1).  Every register it writes - the datapath's, the
# flags, the operand RAMs' address registers, the temporaries' and the FP
# file's write ports - changes only at a p1 edge (ce high); abort is held to
# one.  So a path from one of them to another has two clk_sys, and the
# datapath needs them: operand RAM -> 67-bit barrel shifter -> ALU ->
# normalise -> the result's count and flags is about 41 ns at the slow
# corner (the first synthesis, 8.9.5).  Not in the set: what the p0 edge
# between writes - the µROM and entry reads, their address register ua,
# and the abort latch - so the next-address path (p1 flags to the p0 µROM
# read) stays a one-clk path, as do the BIU's paths into and out of the APU.
# The standalone compile found no combinational loop in the APU (Quartus
# 332125), the condition MacLC's kernel credit lacked.
set fpu_apu  [get_keepers {*|se30_fpu_apu:apu|*}]
set fpu_p0   [get_keepers {*|se30_fpu_apu:apu|altsyncram:urom_rtl_0|* *|se30_fpu_apu:apu|altsyncram:entry_rtl_0|* *|se30_fpu_apu:apu|ua[*] *|se30_fpu_apu:apu|abort_l}]
set fpu_apu1 [remove_from_collection $fpu_apu $fpu_p0]
set_multicycle_path -setup -end 2 -from $fpu_apu1 -to $fpu_apu1
set_multicycle_path -hold  -end 1 -from $fpu_apu1 -to $fpu_apu1
