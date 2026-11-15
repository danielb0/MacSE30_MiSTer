derive_pll_clocks
derive_clock_uncertainty

# The IIci's constraints (SE30_PLAN.md "THE MacIIci TOP AND ITS SDRAM").
# MacSE30.sdc's reasoning holds throughout; this file states the IIci's
# clocks.  rtl/pll_iici, one 1200 MHz VCO:
#   general[0] clk_sys 50 MHz      general[1] clk_mem 100 MHz
#   general[2] clk_sdc 100 +2.50   general[3] clk_capa 100 +1.667 (capture A)
#   general[4] clk_capb 100 +0.3125 (capture B)
#   general[5] clk_k 25 MHz (the CPU)
#   general[6] clk_vid 57.14 MHz (the RBV's video)
# clk_sys, clk_k and clk_mem are related and timed exactly; nothing between
# them is relaxed except the SDRAM controller's inputs below.  Timing is met only when
# it is met at every corner (MacIIci.qsf: TIMEQUEST_MULTICORNER_ANALYSIS).

set pll_out {emu|pll|pll_inst|altera_pll_i|general[%d].gpll~PLL_OUTPUT_COUNTER|divclk}

# ----------------------------------------------------------------------------
# clk_sys -> clk_mem.  rtl/iici_sdram.v takes every input from clk_sys (and
# from the wrapper's clk_k registers, which move at clk_sys edges) only at
# sample_en: the clk_mem edge that IS the next clk_sys edge, 20 ns after the
# launch - the request's fresh path to the pins' registers included.  The one
# exception is phi itself, which finds that edge: one clk_mem period.
# ----------------------------------------------------------------------------
set iici_in [remove_from_collection [get_keepers {*|iici_sdram:sdram|*}] [get_keepers {*|iici_sdram:sdram|phi_q}]]
set_multicycle_path -setup -end 2 -from [get_clocks [list [format $pll_out 0] [format $pll_out 5]]] -to $iici_in
set_multicycle_path -hold  -end 1 -from [get_clocks [list [format $pll_out 0] [format $pll_out 5]]] -to $iici_in

# ----------------------------------------------------------------------------
# The SDRAM's pins (MacSE30.sdc's derivation at 100 MHz, CL2).
# SDRAM_CLK is the inverted clk_sdc.  Read data: tAC(CL2) 6.0 ns + 0.5 ns of
# trace max; tOH 2.5 min.  Commands and write data:
# tIS/tDS 1.5 + 0.5, tIH/tDH 0.8.
# ----------------------------------------------------------------------------
create_generated_clock -name sdram_clk -invert \
  -source [get_pins [format $pll_out 2]] \
  [get_ports {SDRAM_CLK}]

set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]

# The read capture (dq_q in the I/O cell, on capture A or B through a clock
# control block, chosen by the training): as MacSE30.sdc, cut for the
# compile flow and timed by scripts/sta_corners_iici.tcl when it sets
# iici_time_capture - the reading is that at every corner at least ONE of
# the two captures meets, never both.  The phases are PROVISIONAL (the
# controller's header).  sdram_clk's launch is 7.5 ns after our edge; A
# (clk_mem + 1.667) and B (+ 0.3125) both take the word on their SECOND
# edge after it.  The default hold check one edge earlier is the next
# word's, as MacSE30.sdc explains.
if {[info exists ::iici_time_capture]} {
  # (by destination CLOCK: set_multicycle_path has no -to_clock, and the
  # only paths sdram_clk launches into these two clocks are the captures)
  set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_clocks [format $pll_out 3]]
  set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_clocks [format $pll_out 4]]
} else {
  set_false_path -from [get_clocks {sdram_clk}] -to [get_keepers {*|iici_sdram:sdram|dq_q[*]}]
}
set_clock_groups -exclusive \
  -group [get_clocks [format $pll_out 3]] \
  -group [get_clocks [format $pll_out 4]]

# dq_q -> dq_r: the I/O cell's capture register to the fabric, on capture A
# 8.33 ns less 2.3 of clock skew for up to 5.5 ns of route.  Compile 7's
# fitter left two bits 0.34 short while the next hop (dq_r -> its consumers)
# had 2.4 ns to spare.  For the FITTER only, ask 1 ns more of this hop so it
# places dq_r by the pins' side; the analysis keeps the true relationship.
if {[info exists ::TimeQuestInfo(nameofexecutable)] && $::TimeQuestInfo(nameofexecutable) eq "quartus_fit"} {
  set_max_delay -from [get_keepers {*|iici_sdram:sdram|dq_q[*]}] -to [get_keepers {*|iici_sdram:sdram|dq_r[*]}] 7.0
  # clk_sys <-> clk_k: the wrapper's kk_* registers take clk_sys registers, and are taken by them, on a
  # common edge, some with no logic between (din_r <-> kk_din, cyc_fc -> kk_ffc): their hold is the two clock
  # trees' skew, and a full device left some short (probes5: 4-36 ps; probes6: 0.2-0.4 ns).  For the FITTER
  # only, 0.3 ns of minimum delay on the crossings into and out of kk_* - not between the clocks as a whole.
  set CK_SYS [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
  set_min_delay -from $CK_SYS -to [get_registers {*|tg68k:cpu|kk_*}] 0.3
  set_min_delay -from [get_registers {*|tg68k:cpu|kk_*}] -to $CK_SYS 0.3
  # ... and the same for the SDRAM controller's request samplers (x*_ registers, clk_mem, taking clk_sys
  # registers on a shared edge): build probes7 left mdu v_base[14] -> xv_addr[14] 0.18-0.35 ns short
  set_min_delay -from $CK_SYS -to [get_registers {*|iici_sdram:sdram|x*}] 0.3
}

# mdu v_base -> sdram xv_addr: no hold relationship.  v_base moves only on the clk_sys edge that raises
# v_req (iici_mdu.v, v_start), and xv_addr loads only on a clk_mem edge that samples v_req high (iici_sdram.v:
# v_req && !vq).  On the edge they share, the sampler still sees v_req low (v_req's own crossing is analysed
# and met), so xv_addr's enable is off while v_base moves; it loads a clk_mem clock later, v_base long still.
# The fitter's 0.3 ns guide (above) left bit 10 0.16-0.33 ns short in the build of 2026-11-15 (probes13).
set_false_path -hold -from [get_registers {*|iici_mdu:mdu|v_base[*]}] -to [get_registers {*|iici_sdram:sdram|xv_addr[*]}]

set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT

# ----------------------------------------------------------------------------
# The 68882's APU: two clk_sys for its datapath (MacSE30.sdc; ce = phi2 here,
# still one microinstruction every two clk_sys).
# ----------------------------------------------------------------------------
set fpu_apu  [get_keepers {*|se30_fpu_apu:apu|*}]
set fpu_p0   [get_keepers {*|se30_fpu_apu:apu|altsyncram:urom_rtl_0|* *|se30_fpu_apu:apu|altsyncram:entry_rtl_0|* *|se30_fpu_apu:apu|ua[*] *|se30_fpu_apu:apu|abort_l}]
set fpu_apu1 [remove_from_collection $fpu_apu $fpu_p0]
set_multicycle_path -setup -end 2 -from $fpu_apu1 -to $fpu_apu1
set_multicycle_path -hold  -end 1 -from $fpu_apu1 -to $fpu_apu1

# ----------------------------------------------------------------------------
# clk_vid: the RBV's video side and CLK_VIDEO.  Every crossing with clk_sys
# is built for unrelated clocks (rtl/iici_rbv.v CROSSINGS: the Gray-coded
# FIFO, the frame handshake, the dual-clock CLUT, two flip-flops for the
# quasi-static settings), and the framework's video side runs on it: so,
# as the IIcx card's dot clock (MacSE30.sdc, KNOWN ISSUES 24), asynchronous
# to every other clock.
# ----------------------------------------------------------------------------
set_clock_groups -asynchronous -group [get_clocks [format $pll_out 6]]
