//============================================================================
//  Macintosh SE/30 for MiSTer
//
//  The framework shell (SE30_PLAN.md 3.5): the PLL, hps_io, the reset, the
//  two ROM downloads and the SDRAM controller around rtl/se30_machine.v,
//  which is the logic board.  Written from Template_MiSTer's emu shell;
//  the reset and download rules are MacLC_MiSTer's lessons, re-implemented.
//
//  Copyright (C) 2026 Daniel Baum
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// silent until the ASC section
assign AUDIO_S = 1;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

// 512 x 342 at square pixels, the SE/30's own image (256:171, as
// MacPlus has it; plan 3.5)
wire [1:0] ar = status[2:1];
assign VIDEO_ARX = (!ar) ? 12'd256 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd171 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"MACSE30;;",
	"-;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"R[0],Reset;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire         ioctl_download, ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   CLOCKS   ///////////////////////////////
// One PLL (rtl/pll, plan 3.2): clk_sys is 2 x C16M = 31.3344 MHz, the
// board's own oscillator; clk_mem is 3 x clk_sys for the SDRAM, phase-
// locked.  phi1 and phi2 mark C16M's edges, one clk_sys each, alternating.

wire clk_sys, clk_mem, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.locked(pll_locked)
);

reg phi = 0;
always @(posedge clk_sys) phi <= ~phi;
wire phi1 = ~phi;
wire phi2 = phi;

reg [1:0] lock_s = 0;
always @(posedge clk_sys) lock_s <= {lock_s[0], pll_locked};

///////////////////////   RESET   ////////////////////////////////
// Held from configuration until boot0.rom has been streamed (without the
// latch the CPU runs whatever the previous core left at the ROM window),
// while any download runs, until the SDRAM's power-up ladder is done, and
// on the framework's reset, the OSD's and the user button's.  The CPU's
// RESET instruction resets the peripherals, never this (the ROM executes
// RESET during boot: feeding it back is an infinite reset loop).

reg rom_loaded = 0;
always @(posedge clk_sys) if (ioctl_download && ioctl_index[7:0] == 8'h00) rom_loaded <= 1'b1;

reg        machine_reset_n = 0;
reg [15:0] rst_cnt = '1;
always @(posedge clk_sys) begin
	if (!lock_s[1] || !rom_loaded || !sdram_ready || status[0] || buttons[1] || RESET || ioctl_download) begin
		rst_cnt <= '1;
		machine_reset_n <= 0;
	end else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
	else machine_reset_n <= 1;
end

///////////////////////   ROM DOWNLOADS   ////////////////////////
// Main sends bootN.rom with index N << 6 (plan 3.4): boot0.rom, the 256 KB
// SE/30 ROM, to the SDRAM's ROM region as big-endian words; boot1.rom, the
// 8 KB declaration ROM, to the video's BRAM a byte at a time.  Each word
// holds the HPS (ioctl_wait) until the memory has taken it.

wire boot0 = (ioctl_index[7:0] == 8'h00);
wire boot1 = (ioctl_index[7:0] == 8'h40);

reg         dl_req = 0;
reg  [23:0] dl_addr;
reg  [15:0] dl_data;
wire        dl_ack;
reg         declrom_we = 0, dr_second = 0;
reg  [12:0] declrom_waddr;
reg   [7:0] declrom_wdata, dr_hi;
assign ioctl_wait = dl_req || dr_second;

always @(posedge clk_sys) begin
	declrom_we <= 0;
	if (ioctl_wr && ioctl_download && boot0) begin
		dl_req  <= 1;
		dl_addr <= 24'h400000 + ioctl_addr[18:1];
		dl_data <= {ioctl_dout[7:0], ioctl_dout[15:8]};   // byte 0 is the low half of the HPS word
	end else if (dl_req && dl_ack) dl_req <= 0;

	if (ioctl_wr && ioctl_download && boot1) begin
		declrom_we <= 1; declrom_waddr <= {ioctl_addr[12:1], 1'b0}; declrom_wdata <= ioctl_dout[7:0];
		dr_hi <= ioctl_dout[15:8]; dr_second <= 1;
	end else if (dr_second) begin
		declrom_we <= 1; declrom_waddr <= {declrom_waddr[12:1], 1'b1}; declrom_wdata <= dr_hi;
		dr_second <= 0;
	end
end

///////////////////////   SDRAM   ////////////////////////////////
// rtl/se30_sdram.v (plan 3.3).  Its reset is the PLL's lock alone: the
// ladder is content-preserving and the ROM stays in SDRAM across resets.

wire        sdram_ready;
wire        mem_start, mem_req, mem_we, mem_ack;
wire [22:0] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata, mem_rdata;

se30_sdram sdram
(
	.clk(clk_mem), .phi(phi), .reset_n(pll_locked), .ready(sdram_ready),
	.cpu_start(mem_start), .cpu_req(mem_req), .cpu_we(mem_we), .cpu_addr(mem_addr),
	.cpu_be(mem_be), .cpu_wdata(mem_wdata), .cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
	.sd_clk(SDRAM_CLK), .sd_cke(SDRAM_CKE), .sd_addr(SDRAM_A), .sd_ba(SDRAM_BA), .sd_dq(SDRAM_DQ),
	.sd_dqm({SDRAM_DQMH, SDRAM_DQML}), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE)
);

///////////////////////   THE MACHINE   //////////////////////////

wire        vidout, hsync_n, vsync_n, hblank, vblank;
wire [31:0] dbg_addr;
wire  [2:0] dbg_fc;
wire  [1:0] dbg_dsack_n;
wire        dbg_as_n, dbg_rw_n, dbg_berr, dbg_halted, reset_out_n;
wire [31:0] dbg_via;

se30_machine machine
(
	.clk(clk_sys), .phi1(phi1), .phi2(phi2), .reset_n(machine_reset_n),
	.mem_start(mem_start), .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
	.mem_be(mem_be), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
	.declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
	.vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
	.nmi_n(1'b1),
	.dbg_addr(dbg_addr), .dbg_fc(dbg_fc), .dbg_as_n(dbg_as_n), .dbg_rw_n(dbg_rw_n),
	.dbg_dsack_n(dbg_dsack_n), .dbg_berr(dbg_berr), .dbg_halted(dbg_halted), .reset_out_n(reset_out_n),
	.dbg_via(dbg_via)
);

///////////////////////   VIDEO   ////////////////////////////////
// The pixel clock is C16M: one pixel every other clk_sys.  The syncs are
// active low, as MacPlus presents them; the framework normalises.

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = phi1;
assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync_n;
assign VGA_VS = vsync_n;
assign VGA_R  = {8{~vidout}};
assign VGA_G  = {8{~vidout}};
assign VGA_B  = {8{~vidout}};

///////////////////////   PROBES   ///////////////////////////////
// JTAG In-System Probes for the bring-up (plan 3.5), read with
// quartus_stp; FPGA-only, behind USE_DBG_PROBES in MacSE30.qsf.

`ifdef USE_DBG_PROBES
dbg_probes probes
(
	.clk(clk_sys), .phi1(phi1), .reset_n(machine_reset_n),
	.cpu_addr(dbg_addr), .cpu_fc(dbg_fc), .cpu_as_n(dbg_as_n), .cpu_rw_n(dbg_rw_n),
	.dsack_n(dbg_dsack_n), .berr(dbg_berr), .halted(dbg_halted), .sdram_ready(sdram_ready),
	.rom_loaded(rom_loaded), .via_state(dbg_via)
);
`endif

endmodule
