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
// One PLL (rtl/pll, plan 3.2, 3.8 item 18): clk_sys is 2 x C16M = 31.3344
// MHz, the board's own oscillator; clk_mem is 3 x clk_sys for the SDRAM,
// phase-locked; clk_sdc, clk_capa and clk_capb are clk_mem shifted by
// +1.064, -0.266 and -2.261 ns - the SDRAM chip's clock and the two
// read-data captures (rtl/se30_sdram.v's header).  phi1 and phi2 mark
// C16M's edges, one clk_sys each, alternating.

wire clk_sys, clk_mem, clk_sdc, clk_capa, clk_capb, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_sdc),
	.outclk_3(clk_capa),
	.outclk_4(clk_capb),
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
	if (!lock_s[1] || !rom_loaded || !sdram_ready || status[0] || buttons[1] || RESET || ioctl_download || pk_hold) begin
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
// ladder is content-preserving and the ROM stays in SDRAM across resets,
// and so does the read-capture training's choice (plan 3.8 item 18):
// cap_sel says which capture it chose, cap_ok which ones passed; both go
// to the probe deck's PSTA.

wire        sdram_ready, cap_sel;
wire  [1:0] cap_ok;
wire [13:0] cap_fail_a, cap_fail_b;
wire        mem_start, mem_req, mem_we, mem_ack;
wire [22:0] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata, mem_rdata;

// The JTAG memory peek and poke (plan 3.8 items 18 and 19, the probe deck's
// PPEK/PPOK/PRAW): while pk_hold holds the machine in reset, the poke owns
// the controller's CPU port and its raw experiment port, and on each toggle
// of go reads or writes the longword pk_addr or runs one raw experiment.
// Without the probes the machine owns the ports outright.
wire        pk_hold, pk_start, pk_req, pk_we;
wire [22:0] pk_addr;
wire  [3:0] pk_be;
wire [31:0] pk_wdata;
wire        raw_req, raw_ack;
wire [63:0] raw_ctl;
wire [23:0] raw_addr;
wire        dqm_force;

se30_sdram sdram
(
	.clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(pll_locked),
	.ready(sdram_ready), .cap_sel(cap_sel), .cap_ok(cap_ok), .cap_fail_a(cap_fail_a), .cap_fail_b(cap_fail_b),
	.cpu_start(pk_hold ? pk_start : mem_start), .cpu_req(pk_hold ? pk_req : mem_req),
	.cpu_we(pk_hold ? pk_we : mem_we), .cpu_addr(pk_hold ? pk_addr : mem_addr),
	.cpu_be(pk_hold ? pk_be : mem_be), .cpu_wdata(pk_hold ? pk_wdata : mem_wdata),
	.cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
	.raw_req(raw_req), .raw_ctl(raw_ctl), .raw_addr(raw_addr), .raw_ack(raw_ack),
	.dbg_dqm_force(dqm_force),
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
wire [63:0] dbg_regs;
wire [63:0] dbg_swim;

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
	.dbg_via(dbg_via), .dbg_regs(dbg_regs), .dbg_swim(dbg_swim)
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
// the data of the machine's last acknowledged memory read, for PMEM (plan
// 3.8 item 18: the reset vector should read $4080002A)
reg [31:0] mem_last_rdata = 0;
always @(posedge clk_sys) if (mem_req && mem_ack && !mem_we) mem_last_rdata <= mem_rdata;

// The peek and poke.  PPEK's source word is {go, hold, we, raw, 5'b0,
// longword address[22:0]}; PPOK's is {26'b0, DQM force, odd, byte enables
// [3:0], write data[31:0]}; PRAW's is the controller's raw schedule word
// (its header).
// A toggle of go while hold is up runs one operation: a read or a write
// through the CPU port as GLUE would (start for one clk_sys, then the
// request until the acknowledge), or a raw experiment at word address
// {longword address, odd}.  PPEK's probe returns {operations done[7:0],
// data[31:0]} in ONE word - the count and the data of the same operation,
// so the reader can never pair a new count with old data (item 18's peek
// kept them in two probes and was seen one read behind); PPKS is status.
wire [31:0] pk_src;
wire [63:0] pok_src, praw_src;
reg  [31:0] pk_data = 0;
reg   [7:0] pk_cnt = 0;
reg   [2:0] pk_st = 0;
reg         pk_go_q = 0, pk_start_r = 0, pk_req_r = 0, raw_req_r = 0;
assign pk_hold  = pk_src[30];
assign pk_we    = pk_src[29];
assign pk_addr  = pk_src[22:0];
assign pk_be    = pok_src[35:32];
assign pk_wdata = pok_src[31:0];
assign pk_start = pk_start_r;
assign pk_req   = pk_req_r;
assign raw_req  = raw_req_r;
assign raw_ctl  = praw_src;
assign raw_addr = {pk_src[22:0], pok_src[36]};
assign dqm_force = pk_hold && pok_src[37];                   // item 21: the mask high (A12:11, item 22)
always @(posedge clk_sys) begin
	pk_go_q    <= pk_src[31];
	pk_start_r <= 0;
	case (pk_st)
		3'd0: if (pk_hold && (pk_src[31] != pk_go_q)) begin
			if (pk_src[28]) begin raw_req_r <= 1; pk_st <= 3; end
			else begin pk_start_r <= 1; pk_st <= 1; end
		end
		3'd1: begin pk_req_r <= 1; pk_st <= 2; end
		3'd2: if (mem_ack) begin
			pk_data <= pk_we ? pk_wdata : mem_rdata; pk_req_r <= 0; pk_cnt <= pk_cnt + 1'd1; pk_st <= 0;
		end
		3'd3: if (raw_ack) begin raw_req_r <= 0; pk_data <= mem_rdata; pk_cnt <= pk_cnt + 1'd1; pk_st <= 4; end  // a raw READ's words
		3'd4: if (!raw_ack) pk_st <= 0;                              // the level clears before the next operation
		default: pk_st <= 0;
	endcase
	if (!pk_hold) begin pk_req_r <= 0; raw_req_r <= 0; pk_st <= 0; end
end

dbg_probes probes
(
	.clk(clk_sys), .phi1(phi1), .reset_n(machine_reset_n),
	.cpu_addr(dbg_addr), .cpu_fc(dbg_fc), .cpu_as_n(dbg_as_n), .cpu_rw_n(dbg_rw_n),
	.dsack_n(dbg_dsack_n), .berr(dbg_berr), .halted(dbg_halted), .sdram_ready(sdram_ready),
	.sdram_cap({cap_sel, ~|cap_ok, cap_ok}),
	.cap_detail({cap_sel, ~|cap_ok, cap_ok, cap_fail_a, cap_fail_b}),
	.mem_last(mem_last_rdata),
	.peek_src(pk_src), .peek_data({pk_cnt, pk_data}),
	.peek_stat({pk_cnt, 2'b0, raw_ack, pk_hold, pk_req_r, pk_st}),
	.poke_src(pok_src), .raw_src(praw_src),
	.rom_loaded(rom_loaded), .via_state(dbg_via), .cpu_regs(dbg_regs), .swim_state(dbg_swim)
);
`else
assign pk_hold = 1'b0;
assign pk_start = 1'b0;
assign pk_req = 1'b0;
assign pk_we = 1'b0;
assign pk_addr = 23'd0;
assign pk_be = 4'd0;
assign pk_wdata = 32'd0;
assign raw_req = 1'b0;
assign raw_ctl = 64'd0;
assign raw_addr = 24'd0;
assign dqm_force = 1'b0;
`endif

endmodule
