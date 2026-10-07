derive_pll_clocks
derive_clock_uncertainty

# The SDRAM controller samples the machine's requests on the second clk_mem
# edge after each clk_sys edge.
set_multicycle_path -setup -end 2 -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_keepers {*|se30_sdram:sdram|xs_*}]
set_multicycle_path -hold  -end 1 -from [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] -to [get_keepers {*|se30_sdram:sdram|xs_*}]

# SDRAM_CLK is the inverted clk_sdc. Delays: W9825G6KH-6 / AS4C32M16SB-7.
create_generated_clock -name sdram_clk -invert \
  -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# chip -> FPGA (read data)
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]

# The read capture register's clock is chosen at power-up by a training read
# between two shifted clocks; one of them meets timing at every corner, so
# the flow does not time the capture itself (se30_time_capture: a corner
# analysis that does).
if {[info exists ::se30_time_capture]} {
  set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_keepers {*|se30_sdram:sdram|dq_q[*]}]
} else {
  set_false_path -from [get_clocks {sdram_clk}] -to [get_keepers {*|se30_sdram:sdram|dq_q[*]}]
}
set_clock_groups -exclusive \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]

# FPGA -> chip (address, command, write data, byte masks)
set SDRAM_OUT [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQMH SDRAM_DQML SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk -max  2.0 $SDRAM_OUT
set_output_delay -clock sdram_clk -min -0.8 $SDRAM_OUT

# The 68882's APU registers change on every other clk_sys.
set fpu_apu  [get_keepers {*|se30_fpu_apu:apu|*}]
set fpu_p0   [get_keepers {*|se30_fpu_apu:apu|altsyncram:urom_rtl_0|* *|se30_fpu_apu:apu|altsyncram:entry_rtl_0|* *|se30_fpu_apu:apu|ua[*] *|se30_fpu_apu:apu|abort_l}]
set fpu_apu1 [remove_from_collection $fpu_apu $fpu_p0]
set_multicycle_path -setup -end 2 -from $fpu_apu1 -to $fpu_apu1
set_multicycle_path -hold  -end 1 -from $fpu_apu1 -to $fpu_apu1
