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
// the ASC (plan 11.3): signed PCM, left FIFO A / voices 0+1, right B / 2+3
wire [15:0] asc_audio_l, asc_audio_r;
assign AUDIO_S = 1;
assign AUDIO_L = asc_audio_l;
assign AUDIO_R = asc_audio_r;
assign AUDIO_MIX = 0;

// LED_DISK: the internal drive's motor, under THE MACHINE
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

// The external floppy drive (plan 5.14) is a build option (plan 10.4 item
// 3, compile 37): define SE30_EXT_DRIVE for the second FDHD on the DB-19,
// its OSD mount, its image loader and track encoder.  Without it the
// machine has the internal drive alone, as Daniel's LC core does, and the
// logic goes to the features still to build.  The benches (sim/machine,
// sim/gcrread) instantiate se30_machine with EXT_DRIVE = 1 regardless.
// `define SE30_EXT_DRIVE
`ifdef SE30_EXT_DRIVE
localparam EXT_DRIVE = 1;
`else
localparam EXT_DRIVE = 0;
`endif

localparam CONF_STR = {
	"MACSE30;;",
	"-;",
	"S0,DSKIMG,Mount Internal Floppy;",
`ifdef SE30_EXT_DRIVE
	"S1,DSKIMG,Mount External Floppy;",
`endif
	"-;",
	"SC2,IMGVHD,Mount SCSI-0;",
	"SC3,IMGVHD,Mount SCSI-1;",
	"-;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"R[0],Reset;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [32:0] TIMESTAMP;
wire         ioctl_download, ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;

// the images: S0 the internal drive's, S1 the external drive's (plan
// 5.14), 512-byte blocks read only (plan 5.12.5; writing is rung 3's);
// SC2 and SC3 the SCSI disks at IDs 0 and 1, read and written (plan 9.5).
// The data bus is shared; each client takes sd_buff_wr only under its own
// sd_ack.
wire   [3:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[4];
wire   [5:0] sd_blk_cnt[4];
wire  [15:0] sd_buff_din[4];
wire   [3:0] sd_rd, sd_wr, sd_ack;
wire         sd_buff_wr;
wire  [12:0] sd_buff_addr;
wire  [15:0] sd_buff_dout;
wire  [31:0] flp_sd_lba, flp2_sd_lba;
wire  [63:0] scsi_io_lba;
wire  [31:0] scsi_sd_buff_din;
wire   [1:0] scsi_io_rd, scsi_io_wr;
wire  [11:0] scsi_io_blk_cnt;
assign sd_lba[0]      = flp_sd_lba;
assign sd_lba[1]      = flp2_sd_lba;
assign sd_lba[2]      = scsi_io_lba[31:0];
assign sd_lba[3]      = scsi_io_lba[63:32];
assign sd_blk_cnt[0]  = 6'd0;
assign sd_blk_cnt[1]  = 6'd0;
assign sd_blk_cnt[2]  = scsi_io_blk_cnt[5:0];    // a SCSI write request's sectors - 1 (plan 10.4 item 3)
assign sd_blk_cnt[3]  = scsi_io_blk_cnt[11:6];
assign sd_buff_din[0] = 16'd0;
assign sd_buff_din[1] = 16'd0;
assign sd_buff_din[2] = scsi_sd_buff_din[15:0];
assign sd_buff_din[3] = scsi_sd_buff_din[31:16];
assign sd_rd[3:2]     = scsi_io_rd;
assign sd_wr          = {scsi_io_wr, 2'b00};

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(4)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.TIMESTAMP(TIMESTAMP),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

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
// 8 KB declaration ROM, to the video's BRAM a byte at a time; boot2.rom,
// the ADB transceiver's program (342S0440-B, plan 6.3.4), 512 words of
// two bytes, low byte first, twelve bits used, straight into its store.
// Each word holds the HPS (ioctl_wait) until the memory has taken it.

wire boot0 = (ioctl_index[7:0] == 8'h00);
wire boot1 = (ioctl_index[7:0] == 8'h40);
wire boot2 = (ioctl_index[7:0] == 8'h80);

reg         adb_pm_we = 0;
reg   [8:0] adb_pm_waddr;
reg  [11:0] adb_pm_wdata;
always @(posedge clk_sys) begin
	adb_pm_we <= ioctl_wr && ioctl_download && boot2 && ioctl_addr[26:10] == 0;
	adb_pm_waddr <= ioctl_addr[9:1];
	adb_pm_wdata <= ioctl_dout[11:0];                  // byte 0, the low half, is the word's low byte
end

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

///////////////////////   THE FLOPPY   ///////////////////////////
// The internal drive's disk (plan 5.12.5, 5.12.5b): the loader streams the
// mounted image into SDRAM at word $800000 and says when a whole GCR disk
// is in; the encoder lays the head's cylinder out as the ROM's formatter
// would, a bit a cell, into the track buffers the drive plays; the two
// share the SDRAM's disk port.  They run on the PLL's lock, not the
// machine's reset: a reset keeps the disk in, as it does on a Mac.

wire        flp_reset_n = lock_s[1];
wire        disk_in, img_ds, img_800k, img_tags, flp_readonly, flp_loading, disk_eject;
wire  [6:0] disk_cyl, trk_cyl;
wire        trk_valid, trk_side, trk_bit;
wire [16:0] trk_addr;
wire        ld_req, ld_ack, en_req, en_ack;
wire [23:0] ld_addr, en_addr;
wire [15:0] ld_wdata, en_rdata;
wire        dk_req, dk_we, dk_ack;
wire [23:0] dk_addr;
wire [15:0] dk_wdata, dk_rdata;
wire [15:0] ld_dbg, en_dbg;
// the external drive's (plan 5.14): its image at word $900000
wire        disk2_in, img2_ds, img2_800k, img2_tags, flp2_readonly, flp2_loading, disk2_eject;
wire  [6:0] disk2_cyl, trk2_cyl;
wire        trk2_valid, trk2_side, trk2_bit;
wire [16:0] trk2_addr;
wire        ld2_req, ld2_ack, en2_req, en2_ack;
wire [23:0] ld2_addr, en2_addr;
wire [15:0] ld2_wdata, en2_rdata;
wire [15:0] ld2_dbg, en2_dbg, dbg_fdhd2;

se30_flp_loader flp_loader
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[0]), .img_size(img_size), .img_readonly(img_readonly),
	.sd_lba(flp_sd_lba), .sd_rd(sd_rd[0]), .sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
	.eject(disk_eject),
	.disk_in(disk_in), .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags),
	.readonly(flp_readonly), .loading(flp_loading), .dbg(ld_dbg)
);

se30_flp_encoder flp_encoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk_in), .img_ds(img_ds), .img_tags(img_tags), .img_800k(img_800k),
	.cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
	.trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
	.mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
	.dbg(en_dbg)
);

generate if (EXT_DRIVE) begin : ext   // the external drive's chain (the option above)
se30_flp_loader #(.BASE(24'h900000)) flp2_loader
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[1]), .img_size(img_size), .img_readonly(img_readonly),
	.sd_lba(flp2_sd_lba), .sd_rd(sd_rd[1]), .sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.mem_req(ld2_req), .mem_addr(ld2_addr), .mem_wdata(ld2_wdata), .mem_ack(ld2_ack),
	.eject(disk2_eject),
	.disk_in(disk2_in), .img_ds(img2_ds), .img_800k(img2_800k), .img_tags(img2_tags),
	.readonly(flp2_readonly), .loading(flp2_loading), .dbg(ld2_dbg)
);

se30_flp_encoder #(.BASE(24'h900000)) flp2_encoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk2_in), .img_ds(img2_ds), .img_tags(img2_tags), .img_800k(img2_800k),
	.cyl(disk2_cyl), .trk_cyl(trk2_cyl), .trk_valid(trk2_valid),
	.trk_addr(trk2_addr), .trk_side(trk2_side), .trk_bit(trk2_bit),
	.mem_req(en2_req), .mem_addr(en2_addr), .mem_rdata(en2_rdata), .mem_ack(en2_ack),
	.dbg(en2_dbg)
);
end else begin : noext   // no external drive: no image, no disk, no port requests
assign flp2_sd_lba   = 32'd0;
assign sd_rd[1]      = 1'b0;
assign disk2_in      = 1'b0;
assign img2_ds       = 1'b0;
assign img2_800k     = 1'b0;
assign img2_tags     = 1'b0;
assign flp2_readonly = 1'b0;
assign flp2_loading  = 1'b0;
assign ld2_req       = 1'b0;
assign ld2_addr      = 24'd0;
assign ld2_wdata     = 16'd0;
assign ld2_dbg       = 16'd0;
assign en2_req       = 1'b0;
assign en2_addr      = 24'd0;
assign en2_dbg       = 16'd0;
assign trk2_cyl      = 7'd0;
assign trk2_valid    = 1'b0;
assign trk2_bit      = 1'b0;
end endgenerate

se30_flp_dkmux flp_dkmux
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.ld0_req(ld_req), .ld0_addr(ld_addr), .ld0_wdata(ld_wdata), .ld0_ack(ld_ack),
	.en0_req(en_req), .en0_addr(en_addr), .en0_rdata(en_rdata), .en0_ack(en_ack),
	.ld1_req(ld2_req), .ld1_addr(ld2_addr), .ld1_wdata(ld2_wdata), .ld1_ack(ld2_ack),
	.en1_req(en2_req), .en1_addr(en2_addr), .en1_rdata(en2_rdata), .en1_ack(en2_ack),
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack)
);

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
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
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
wire [63:0] dbg_swim, dbg_adb;
wire [31:0] dbg_rtc;
wire        dbg_swim_vread;
wire [56:0] dbg_exc;
wire [63:0] dbg_cache;
wire [15:0] dbg_scsi;
wire [31:0] dbg_scc;
wire [31:0] dbg_asc;
// PSCS's sector count: the SCSI slots' sd_ack rising edges (plan 9.8)
reg   [9:0] scsi_sectors = 0;
reg   [1:0] scsi_ack_q = 0;
always @(posedge clk_sys) begin
	scsi_ack_q <= sd_ack[3:2];
	if ((sd_ack[2] && !scsi_ack_q[0]) || (sd_ack[3] && !scsi_ack_q[1])) scsi_sectors <= scsi_sectors + 1'd1;
end

se30_machine #(.EXT_DRIVE(EXT_DRIVE)) machine
(
	.clk(clk_sys), .phi1(phi1), .phi2(phi2), .reset_n(machine_reset_n),
	.mem_start(mem_start), .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
	.mem_be(mem_be), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
	.declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
	.vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
	.nmi_n(1'b1),
	.pace_en(1'b1),
	.dbg_addr(dbg_addr), .dbg_fc(dbg_fc), .dbg_as_n(dbg_as_n), .dbg_rw_n(dbg_rw_n),
	.dbg_dsack_n(dbg_dsack_n), .dbg_berr(dbg_berr), .dbg_halted(dbg_halted), .reset_out_n(reset_out_n),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse), .timestamp(TIMESTAMP),
	.adb_pm_we(adb_pm_we), .adb_pm_waddr(adb_pm_waddr), .adb_pm_wdata(adb_pm_wdata),
	.disk_in(disk_in), .disk_eject(disk_eject), .disk_cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
	.trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
	.disk2_in(disk2_in), .disk2_eject(disk2_eject), .disk2_cyl(disk2_cyl), .trk2_cyl(trk2_cyl), .trk2_valid(trk2_valid),
	.trk2_addr(trk2_addr), .trk2_side(trk2_side), .trk2_bit(trk2_bit),
	.dbg_via(dbg_via), .dbg_regs(dbg_regs), .dbg_exc(dbg_exc), .dbg_cache(dbg_cache), .dbg_swim(dbg_swim), .dbg_fdhd2(dbg_fdhd2), .dbg_swim_vread(dbg_swim_vread),
	.dbg_adb(dbg_adb), .dbg_rtc(dbg_rtc), .dbg_scsi(dbg_scsi), .dbg_scc(dbg_scc), .dbg_asc(dbg_asc),
	.audio_l(asc_audio_l), .audio_r(asc_audio_r),
	.scsi_img_mounted(img_mounted[3:2]), .scsi_img_blocks(img_size[40:9]),
	.scsi_io_lba(scsi_io_lba), .scsi_io_rd(scsi_io_rd), .scsi_io_wr(scsi_io_wr), .scsi_io_blk_cnt(scsi_io_blk_cnt), .scsi_io_ack(sd_ack[3:2]),
	.scsi_sd_buff_addr(sd_buff_addr), .scsi_sd_buff_dout(sd_buff_dout), .scsi_sd_buff_din(scsi_sd_buff_din),
	.scsi_sd_buff_wr(sd_buff_wr),
	.scc_port_in(6'b110_110), .scc_port_out()   // both serial ports empty (plan 10.3)
);

assign LED_DISK = {1'b0, dbg_swim[15] | dbg_fdhd2[15]};   // either drive's motor (se30_fdhd's dbg[15])

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

// PFLP (plan 5.12.8): the loader's and the encoder's states, the words the
// disk port has moved, and the bytes the ROM has taken from the SWIM's
// data register (its valid reads)
reg  [15:0] flp_words = 0, flp_bytes = 0, flp2_words = 0;
reg         dk_ack_q = 0, dk2_ack_q = 0;
always @(posedge clk_sys) begin
	dk_ack_q <= dk_ack;
	dk2_ack_q <= ld2_ack | en2_ack;
	if (dk_ack && !dk_ack_q) flp_words <= flp_words + 1'd1;
	if ((ld2_ack | en2_ack) && !dk2_ack_q) flp2_words <= flp2_words + 1'd1;   // PFL2: the external drive's (5.14)
	if (dbg_swim_vread) flp_bytes <= flp_bytes + 1'd1;
end

// PSCT (plan 10.4 item 3): where the SCSI disk's time goes.  Free-running
// counters on clk_sys; the reader takes the difference of two reads, one
// either side of a test (read_probes.tcl scsitime).  An HPS request is
// timed from the target's io_rd or io_wr rising to sd_ack falling (the
// round trip: Linux's response, then the block's transfer while sd_ack is
// high); one request is in flight at a time per disk, and the two disks'
// slots are taken together (the test uses one).  dbg_scsi[1] is a target's
// hold-off (a data phase waiting on the HPS), dbg_scsi[0] GLUE holding the
// CPU at $50006000 for DRQ.  Since multi-block writes (compile 39) a write
// request carries sd_blk_cnt + 1 sectors; st_wr_sec counts them.
reg  [39:0] st_clk = 0, st_bsy = 0, st_hold = 0, st_hsw = 0;
reg  [23:0] st_cmd = 0;
reg  [23:0] st_rd_n = 0, st_rd_max = 0, st_wr_n = 0, st_wr_max = 0;
reg  [39:0] st_rd_sum = 0, st_rd_ack = 0, st_wr_sum = 0, st_wr_ack = 0;
reg  [23:0] st_cur = 0;                     // clocks into the request in flight, saturating
reg  [23:0] st_wr_sec = 0;                  // sectors the write requests carried (sd_blk_cnt + 1 each)
reg   [5:0] st_blk = 0;                     // the request in flight's sd_blk_cnt
reg         st_bsy_q = 0, st_ack_q = 0, st_fly = 0, st_fly_wr = 0;
wire        st_bsy_now = |dbg_scsi[15:14];
wire        st_ack     = |sd_ack[3:2];
always @(posedge clk_sys) begin
	st_clk   <= st_clk + 1'd1;
	st_bsy_q <= st_bsy_now;
	st_ack_q <= st_ack;
	if (st_bsy_now) st_bsy <= st_bsy + 1'd1;
	if (st_bsy_now && !st_bsy_q) st_cmd <= st_cmd + 1'd1;
	if (dbg_scsi[1]) st_hold <= st_hold + 1'd1;
	if (dbg_scsi[0]) st_hsw <= st_hsw + 1'd1;
	if (!st_fly) begin
		if (|scsi_io_rd || |scsi_io_wr) begin
			st_fly <= 1; st_fly_wr <= |scsi_io_wr; st_cur <= 24'd1;
			st_blk <= scsi_io_wr[1] ? scsi_io_blk_cnt[11:6] : scsi_io_blk_cnt[5:0];
		end
	end else begin
		if (~&st_cur) st_cur <= st_cur + 1'd1;
		if (st_ack) begin
			if (st_fly_wr) st_wr_ack <= st_wr_ack + 1'd1;
			else           st_rd_ack <= st_rd_ack + 1'd1;
		end
		if (st_ack_q && !st_ack) begin
			st_fly <= 0;
			if (st_fly_wr) begin
				st_wr_n   <= st_wr_n + 1'd1;
				st_wr_sec <= st_wr_sec + st_blk + 1'd1;
				st_wr_sum <= st_wr_sum + st_cur;
				if (st_cur > st_wr_max) st_wr_max <= st_cur;
			end else begin
				st_rd_n   <= st_rd_n + 1'd1;
				st_rd_sum <= st_rd_sum + st_cur;
				if (st_cur > st_rd_max) st_rd_max <= st_cur;
			end
		end
	end
end

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
	.rom_loaded(rom_loaded), .via_state(dbg_via), .cpu_regs(dbg_regs), .swim_state(dbg_swim),
	.adb_state(dbg_adb), .rtc_state(dbg_rtc),
	.flp_state({ld_dbg, en_dbg, flp_words, flp_bytes}),
	.flp2_state({ld2_dbg, en2_dbg, dbg_fdhd2, flp2_words}),
	.exc_state(dbg_exc),
	.cache_state(dbg_cache),
	.scsi_state({dbg_scsi, scsi_io_rd, scsi_io_wr, sd_ack[3:2], scsi_sectors}),
	.scsi_meter({st_clk, st_bsy, st_hold, st_hsw, st_cmd,
	             st_rd_n, st_rd_sum, st_rd_ack, st_rd_max,
	             st_wr_n, st_wr_sum, st_wr_ack, st_wr_max, st_wr_sec}),
	.scc_state(dbg_scc),
	.asc_state(dbg_asc)
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
