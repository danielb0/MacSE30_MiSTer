// probe.v - a placement probe for KNOWN ISSUES 24: the IIcx build's PLLs and
// the framework's two clock switches, nothing else, so the fitter answers
// placement questions in minutes.  Same primitives as the real design:
//   pll        (rtl/pll)      main PLL, FPGA_CLK2_50 -> clk_sys/clk_mem/clk_sdc/clk_capa/clk_capb
//   cap_clkctrl               se30_sdram's capture select (two counters of one PLL)
//   pll_vid    (rtl/pll_vid)  the card's dot clock from clk_mem
//   pll_hdmi + pll_cfg_hdmi   sys/'s reconfigurable HDMI PLL
//   pll_audio                 sys/'s audio PLL
//   hdmi_clk_sw, vga_clk_sw   sys_top's cyclonev_clkselect switches
module probe (
	input         FPGA_CLK1_50,
	input         FPGA_CLK2_50,
	input         FPGA_CLK3_50,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_CLK,
	output        HDMI_TX_CLK,
	output  [7:0] HDMI_TX_D,
	output  [5:0] VGA_R,
	output  [3:0] LED,
	input   [1:0] KEY,
	input   [3:0] SW
);

// ---------------------------------------------------------------- main PLL
wire clk_sys, clk_mem, clk_sdc, clk_capa, clk_capb, pll_locked;
wire clk_pix;
`ifdef VID_FROM_MAIN
`PLL6 pll
(
	.refclk(FPGA_CLK2_50),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_sdc),
	.outclk_3(clk_capa),
	.outclk_4(clk_capb),
	.outclk_5(clk_pix),
	.locked(pll_locked)
);
`else
pll pll
(
	.refclk(FPGA_CLK2_50),
	.rst(1'b0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_sdc),
	.outclk_3(clk_capa),
	.outclk_4(clk_capb),
	.locked(pll_locked)
);
`endif

// the read capture select, as rtl/se30_sdram.v
reg cap_sel = 0;
always @(posedge clk_sys) cap_sel <= SW[2];
wire clk_cap;
altclkctrl #(
	.clock_type("Global Clock"), .intended_device_family("Cyclone V"),
	.ena_register_mode("falling edge"), .implement_in_les("OFF"),
	.number_of_clocks(4), .use_glitch_free_switch_over_implementation("OFF"),
	.width_clkselect(2), .lpm_type("altclkctrl")
) cap_clkctrl (
	.inclk({clk_capb, clk_capa, 2'b00}), .clkselect({1'b1, cap_sel}), .ena(1'b1), .outclk(clk_cap)
);
reg [15:0] dq_q, dq_w, dq_m;
always @(posedge clk_cap) begin dq_q <= SDRAM_DQ; dq_w <= dq_q; end
always @(negedge clk_mem) dq_m <= dq_w;

reg [15:0] dq_out; reg dq_oe;
always @(posedge clk_mem) begin dq_out <= dq_m + 1'b1; dq_oe <= SW[3]; end
assign SDRAM_DQ = dq_oe ? dq_out : 16'bz;

altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
) sdclk_ddr (
	.datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sdc), .dataout(SDRAM_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0), .oe_out()
);

// ---------------------------------------------------------------- the dot clock
`ifndef VID_FROM_MAIN
pll_vid pll_vid
(
	.refclk(clk_mem),
	.rst(1'b0),
	.outclk_0(clk_pix),
	.locked()
);
`endif
wire clk_vid = clk_pix;

// ---------------------------------------------------------------- sys/: pll_hdmi + its reconfiguration
wire [63:0] reconfig_to_pll, reconfig_from_pll;
wire hdmi_clk_out, cfg_waitrequest;
pll_hdmi pll_hdmi
(
	.refclk(FPGA_CLK1_50),
	.rst(1'b0),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.outclk_0(hdmi_clk_out)
);
reg  [5:0] cfg_address = 0;
reg [31:0] cfg_data = 0;
reg        cfg_write = 0;
always @(posedge FPGA_CLK1_50) begin
	cfg_write   <= KEY[0] & ~cfg_waitrequest;
	cfg_address <= cfg_address + 1'b1;
	cfg_data    <= {cfg_data[30:0], KEY[1]};
end
pll_cfg_hdmi pll_cfg_hdmi
(
	.mgmt_clk(FPGA_CLK1_50),
	.mgmt_reset(1'b0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll)
);

// ---------------------------------------------------------------- sys_top's clock switches
wire hdmi_tx_clk, vga_tx_clk;
cyclonev_clkselect hdmi_clk_sw
(
	.clkselect({1'b1, SW[0]}),
	.inclk({clk_vid, hdmi_clk_out, 2'b00}),
	.outclk(hdmi_tx_clk)
);
cyclonev_clkselect vga_clk_sw
(
	.clkselect({1'b1, SW[1]}),
	.inclk({clk_vid, hdmi_clk_out, 2'b00}),
	.outclk(vga_tx_clk)
);
altddio_out #(
	.extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
	.lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"), .power_up_high("OFF"), .width(1)
) hdmiclk_ddr (
	.datain_h(1'b0), .datain_l(1'b1), .outclock(hdmi_tx_clk), .dataout(HDMI_TX_CLK),
	.aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0), .oe_out()
);
reg [7:0] hd = 0; always @(posedge hdmi_tx_clk) hd <= hd + 1'b1;
assign HDMI_TX_D = hd;
reg [5:0] vr = 0; always @(posedge vga_tx_clk) vr <= vr + 1'b1;
assign VGA_R = vr;

// ---------------------------------------------------------------- sys/: pll_audio
wire clk_audio;
pll_audio pll_audio
(
	.refclk(FPGA_CLK3_50),
	.rst(1'b0),
	.outclk_0(clk_audio)
);
reg [3:0] au = 0; always @(posedge clk_audio) au <= au + 1'b1;
reg [7:0] cs = 0; always @(posedge clk_sys)   cs <= cs + 1'b1;
reg [7:0] cp = 0; always @(posedge clk_pix)   cp <= cp + 1'b1;
assign LED = {au[3] ^ cs[7], cp[7] ^ dq_m[0], hd[7] ^ vr[5], pll_locked};

endmodule
