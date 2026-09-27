create_clock -name CLK_50M -period 20.000 [get_ports {CLK_50M}]
derive_pll_clocks
derive_clock_uncertainty
create_generated_clock -name sdram_clk -invert -source [get_pins {pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]
set_input_delay  -clock sdram_clk -max 6.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock sdram_clk -min 2.5 [get_ports {SDRAM_DQ[*]}]
set_multicycle_path -setup -end 2 -from [get_clocks {sdram_clk}] -to [get_keepers {dq_q[*]}]
set_output_delay -clock sdram_clk -max  2.0 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock sdram_clk -min -0.8 [get_ports {SDRAM_DQ[*]}]
set_clock_groups -exclusive -group [get_clocks {pll|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] -group [get_clocks {pll|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]
