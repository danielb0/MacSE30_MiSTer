//============================================================================
//  Macintosh SE/30 for MiSTer
//
//  The MiSTer shell around rtl/se30_machine.v, the logic board: the PLL,
//  hps_io, reset, the ROM downloads, the floppy and PRAM images, the SDRAM.
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

wire [15:0] asc_audio_l, asc_audio_r;
assign AUDIO_S = 1;
assign AUDIO_L = asc_audio_l;
assign AUDIO_R = asc_audio_r;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

wire [1:0] ar = status[2:1];
assign VIDEO_ARX = (!ar) ? 12'd256 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd171 : 12'd0;

`include "build_id.v"

// define SE30_EXT_DRIVE for the external floppy drive
`ifdef SE30_EXT_DRIVE
localparam EXT_DRIVE = 1;
`else
localparam EXT_DRIVE = 0;
`endif

// define SE30_NO_CDROM to build without the CD-ROM
`ifdef SE30_NO_CDROM
localparam CDROM_EN = 0;
`else
localparam CDROM_EN = 1;
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
`ifndef SE30_NO_CDROM
	"SC4,ISOTO*,Mount CD-ROM;",
`endif
	"-;",
	"SC5,NVR,Mount PRAM;",
	"-;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[4],Memory,8 MB,16 MB;",
	"-;",
	"R[0],Reset & Apply Memory;",
	"R[3],Wipe PRAM (erases settings!);",
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

// image slots: 0-1 floppies, 2-3 SCSI disks, 4 CD-ROM, 5 PRAM
wire   [5:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[6];
wire   [5:0] sd_blk_cnt[6];
wire  [15:0] sd_buff_din[6];
wire   [5:0] sd_rd, sd_wr, sd_ack;
wire         sd_buff_wr;
wire  [12:0] sd_buff_addr;
wire  [15:0] sd_buff_dout;
wire  [31:0] flp_sd_lba, flp2_sd_lba, flp_wr_lba, flp2_wr_lba;
wire         flp_sd_wr, flp2_sd_wr;
wire  [15:0] flp_sd_din, flp2_sd_din;
wire  [95:0] scsi_io_lba;
wire  [47:0] scsi_sd_buff_din;
wire   [2:0] scsi_io_rd, scsi_io_wr;
wire  [17:0] scsi_io_blk_cnt;
assign sd_lba[0]      = flp_sd_wr  ? flp_wr_lba  : flp_sd_lba;
assign sd_lba[1]      = flp2_sd_wr ? flp2_wr_lba : flp2_sd_lba;
assign sd_lba[2]      = scsi_io_lba[31:0];
assign sd_lba[3]      = scsi_io_lba[63:32];
assign sd_lba[4]      = scsi_io_lba[95:64];
assign sd_lba[5]      = 32'd0;
assign sd_blk_cnt[0]  = 6'd0;
assign sd_blk_cnt[1]  = 6'd0;
assign sd_blk_cnt[2]  = scsi_io_blk_cnt[5:0];
assign sd_blk_cnt[3]  = scsi_io_blk_cnt[11:6];
assign sd_blk_cnt[4]  = 6'd0;
assign sd_blk_cnt[5]  = 6'd0;
assign sd_buff_din[0] = flp_sd_din;
assign sd_buff_din[1] = flp2_sd_din;
assign sd_buff_din[2] = scsi_sd_buff_din[15:0];
assign sd_buff_din[3] = scsi_sd_buff_din[31:16];
assign sd_buff_din[4] = scsi_sd_buff_din[47:32];
assign sd_buff_din[5] = pram_sd_din;
assign sd_rd[4:2]     = scsi_io_rd;
assign sd_rd[5]       = pram_sd_rd;
assign sd_wr          = {pram_sd_wr, 1'b0, scsi_io_wr[1:0], flp2_sd_wr, flp_sd_wr};

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(6)) hps_io
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

// clk_sys = 2 x C16M; clk_mem = 3 x clk_sys for the SDRAM
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

// the machine is held in reset until the ROM, the SDRAM and the PRAM are ready
reg rom_loaded = 0;
always @(posedge clk_sys) if (ioctl_download && ioctl_index[7:0] == 8'h00) rom_loaded <= 1'b1;

reg        machine_reset_n = 0;
reg [15:0] rst_cnt = '1;
always @(posedge clk_sys) begin
	if (!lock_s[1] || !rom_loaded || !sdram_ready || status[0] || buttons[1] || RESET || ioctl_download ||
	    !pram_ready || pram_restart) begin
		rst_cnt <= '1;
		machine_reset_n <= 0;
	end else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
	else machine_reset_n <= 1;
end

// the memory size changes only while the machine is held in reset
reg ram16 = 0;
always @(posedge clk_sys) if (!machine_reset_n) ram16 <= status[4];

// persistent PRAM
wire        pram_sd_rd, pram_sd_wr, pram_ready, pram_restart;
wire [15:0] pram_sd_din;
wire        pram_h_we, pram_wr;
wire  [7:0] pram_h_addr, pram_h_wdata, pram_h_raddr, pram_h_rdata;

se30_pram pram (
	.clk(clk_sys), .reset(!lock_s[1]),
	.osd_open(OSD_STATUS), .wipe(status[3]),
	.img_mounted(img_mounted[5]), .img_present(img_size != 64'd0),
	.sd_rd(pram_sd_rd), .sd_wr(pram_sd_wr), .sd_ack(sd_ack[5]), .sd_buff_addr(sd_buff_addr[7:0]),
	.sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .sd_buff_din(pram_sd_din),
	.h_we(pram_h_we), .h_addr(pram_h_addr), .h_wdata(pram_h_wdata), .h_raddr(pram_h_raddr),
	.h_rdata(pram_h_rdata), .pram_wr(pram_wr),
	.ready(pram_ready), .restart(pram_restart), .dbg());

// boot0.rom: SE/30 ROM to SDRAM; boot1.rom: video declaration ROM;
// boot2.rom: the ADB transceiver's program
wire boot0 = (ioctl_index[7:0] == 8'h00);
wire boot1 = (ioctl_index[7:0] == 8'h40);
wire boot2 = (ioctl_index[7:0] == 8'h80);

reg         adb_pm_we = 0;
reg   [8:0] adb_pm_waddr;
reg  [11:0] adb_pm_wdata;
always @(posedge clk_sys) begin
	adb_pm_we <= ioctl_wr && ioctl_download && boot2 && ioctl_addr[26:10] == 0;
	adb_pm_waddr <= ioctl_addr[9:1];
	adb_pm_wdata <= ioctl_dout[11:0];
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
		dl_addr <= 24'hC00000 + ioctl_addr[18:1];
		dl_data <= {ioctl_dout[7:0], ioctl_dout[15:8]};
	end else if (dl_req && dl_ack) dl_req <= 0;

	if (ioctl_wr && ioctl_download && boot1) begin
		declrom_we <= 1; declrom_waddr <= {ioctl_addr[12:1], 1'b0}; declrom_wdata <= ioctl_dout[7:0];
		dr_hi <= ioctl_dout[15:8]; dr_second <= 1;
	end else if (dr_second) begin
		declrom_we <= 1; declrom_waddr <= {declrom_waddr[12:1], 1'b1}; declrom_wdata <= dr_hi;
		dr_second <= 0;
	end
end

// floppy images: loader, track encoder, written-track decoder, SD writer
wire        flp_reset_n = lock_s[1];
wire        disk_in, img_ds, img_800k, img_tags, img_mfm, img_hd, flp_readonly, flp_loading, disk_eject;
wire  [6:0] disk_cyl, trk_cyl;
wire        trk_valid, trk_side, trk_bit;
wire [17:0] trk_addr;
wire        ld_req, ld_ack, en_req, en_ack;
wire [23:0] ld_addr, en_addr;
wire [15:0] ld_wdata, en_rdata;
wire        dk_req, dk_we, dk_ack;
wire [23:0] dk_addr;
wire [15:0] dk_wdata, dk_rdata;
wire        disk_wprot = flp_readonly;
wire        trk_we, trk_wbit, arc_done, arc_side, arc_whole;
wire [17:0] trk_cells, arc_start, arc_end;
wire        enc_hold, enc_idle, dec_bit, ds_eff, flp_dc42;
wire [18:0] dec_addr;
wire  [5:0] hdr_addr;
wire [15:0] hdr_data;
wire [12:0] flp_blks;
wire        de_req, de_ack, wr_req, wr_ack, cm_done, cm_ready;
wire [23:0] de_addr, wr_addr;
wire [15:0] de_wdata, wr_rdata;
wire [11:0] cm_blk;
wire        disk2_in, img2_ds, img2_800k, img2_tags, img2_mfm, img2_hd, flp2_readonly, flp2_loading, disk2_eject;
wire  [6:0] disk2_cyl, trk2_cyl;
wire        trk2_valid, trk2_side, trk2_bit;
wire [17:0] trk2_addr;
wire        ld2_req, ld2_ack, en2_req, en2_ack;
wire [23:0] ld2_addr, en2_addr;
wire [15:0] ld2_wdata, en2_rdata;
wire [15:0] dbg_fdhd2;
wire        disk2_wprot = flp2_readonly;
wire        trk2_we, trk2_wbit, arc2_done, arc2_side, arc2_whole;
wire [17:0] trk2_cells, arc2_start, arc2_end;
wire        de2_req, de2_ack, wr2_req, wr2_ack;
wire [23:0] de2_addr, wr2_addr;
wire [15:0] de2_wdata, wr2_rdata;
wire        enc2_hold, enc2_idle, dec2_bit, ds2_eff, flp2_dc42, cm2_done, cm2_ready;
wire [18:0] dec2_addr;
wire  [5:0] hdr2_addr;
wire [15:0] hdr2_data;
wire [12:0] flp2_blks;
wire [11:0] cm2_blk;

se30_flp_loader flp_loader
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[0]), .img_size(img_size), .img_readonly(img_readonly),
	.sd_lba(flp_sd_lba), .sd_rd(sd_rd[0]), .sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
	.eject(disk_eject),
	.disk_in(disk_in), .img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags),
	.img_mfm(img_mfm), .img_hd(img_hd),
	.readonly(flp_readonly), .loading(flp_loading),
	.hdr_addr(hdr_addr), .hdr_data(hdr_data), .is_dc42(flp_dc42), .file_blks(flp_blks),
	.dbg()
);

se30_flp_encoder flp_encoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk_in), .img_ds(ds_eff), .img_tags(img_tags), .img_800k(img_800k),
	.img_mfm(img_mfm), .img_hd(img_hd),
	.cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
	.trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
	.trk_we(trk_we), .trk_wbit(trk_wbit), .hold(enc_hold), .dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle),
	.mem_req(en_req), .mem_addr(en_addr), .mem_rdata(en_rdata), .mem_ack(en_ack),
	.dbg()
);

se30_flp_decoder flp_decoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk_in), .loading(flp_loading), .write_ok(!disk_wprot),
	.img_ds(img_ds), .img_800k(img_800k), .img_tags(img_tags), .img_mfm(img_mfm), .img_hd(img_hd), .ds_eff(ds_eff),
	.arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end),
	.arc_whole(arc_whole), .trk_cells(trk_cells), .cyl(disk_cyl),
	.dec_addr(dec_addr), .dec_bit(dec_bit), .enc_idle(enc_idle), .hold(enc_hold),
	.mem_req(de_req), .mem_addr(de_addr), .mem_wdata(de_wdata), .mem_ack(de_ack),
	.cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(cm_ready),
	.dbg()
);

se30_flp_sdwriter flp_sdwriter
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[0]), .loading(flp_loading), .write_ok(!disk_wprot),
	.dc42(flp_dc42), .img_tags(img_tags), .img_800k(img_800k), .file_blks(flp_blks),
	.cm_done(cm_done), .cm_blk(cm_blk), .cm_ready(cm_ready),
	.flush_req(disk_eject),
	.hdr_addr(hdr_addr), .hdr_data(hdr_data),
	.mem_req(wr_req), .mem_addr(wr_addr), .mem_rdata(wr_rdata), .mem_ack(wr_ack),
	.sd_lba(flp_wr_lba), .sd_wr(flp_sd_wr), .sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_din(flp_sd_din),
	.busy(), .dbg()
);

generate if (EXT_DRIVE) begin : ext
se30_flp_loader #(.BASE(24'h900000)) flp2_loader
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[1]), .img_size(img_size), .img_readonly(img_readonly),
	.sd_lba(flp2_sd_lba), .sd_rd(sd_rd[1]), .sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.mem_req(ld2_req), .mem_addr(ld2_addr), .mem_wdata(ld2_wdata), .mem_ack(ld2_ack),
	.eject(disk2_eject),
	.disk_in(disk2_in), .img_ds(img2_ds), .img_800k(img2_800k), .img_tags(img2_tags),
	.img_mfm(img2_mfm), .img_hd(img2_hd),
	.readonly(flp2_readonly), .loading(flp2_loading),
	.hdr_addr(hdr2_addr), .hdr_data(hdr2_data), .is_dc42(flp2_dc42), .file_blks(flp2_blks),
	.dbg()
);

se30_flp_encoder #(.BASE(24'h900000)) flp2_encoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk2_in), .img_ds(ds2_eff), .img_tags(img2_tags), .img_800k(img2_800k),
	.img_mfm(img2_mfm), .img_hd(img2_hd),
	.cyl(disk2_cyl), .trk_cyl(trk2_cyl), .trk_valid(trk2_valid),
	.trk_addr(trk2_addr), .trk_side(trk2_side), .trk_bit(trk2_bit),
	.trk_we(trk2_we), .trk_wbit(trk2_wbit), .hold(enc2_hold), .dec_addr(dec2_addr), .dec_bit(dec2_bit), .enc_idle(enc2_idle),
	.mem_req(en2_req), .mem_addr(en2_addr), .mem_rdata(en2_rdata), .mem_ack(en2_ack),
	.dbg()
);

se30_flp_decoder #(.BASE(24'h900000)) flp2_decoder
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.disk_in(disk2_in), .loading(flp2_loading), .write_ok(!disk2_wprot),
	.img_ds(img2_ds), .img_800k(img2_800k), .img_tags(img2_tags), .img_mfm(img2_mfm), .img_hd(img2_hd), .ds_eff(ds2_eff),
	.arc_done(arc2_done), .arc_side(arc2_side), .arc_start(arc2_start), .arc_end(arc2_end),
	.arc_whole(arc2_whole), .trk_cells(trk2_cells), .cyl(disk2_cyl),
	.dec_addr(dec2_addr), .dec_bit(dec2_bit), .enc_idle(enc2_idle), .hold(enc2_hold),
	.mem_req(de2_req), .mem_addr(de2_addr), .mem_wdata(de2_wdata), .mem_ack(de2_ack),
	.cm_done(cm2_done), .cm_blk(cm2_blk), .cm_ready(cm2_ready),
	.dbg()
);

se30_flp_sdwriter #(.BASE(24'h900000)) flp2_sdwriter
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[1]), .loading(flp2_loading), .write_ok(!disk2_wprot),
	.dc42(flp2_dc42), .img_tags(img2_tags), .img_800k(img2_800k), .file_blks(flp2_blks),
	.cm_done(cm2_done), .cm_blk(cm2_blk), .cm_ready(cm2_ready),
	.flush_req(disk2_eject),
	.hdr_addr(hdr2_addr), .hdr_data(hdr2_data),
	.mem_req(wr2_req), .mem_addr(wr2_addr), .mem_rdata(wr2_rdata), .mem_ack(wr2_ack),
	.sd_lba(flp2_wr_lba), .sd_wr(flp2_sd_wr), .sd_ack(sd_ack[1]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_din(flp2_sd_din),
	.busy(), .dbg()
);
end else begin : noext
assign flp2_sd_lba   = 32'd0;
assign sd_rd[1]      = 1'b0;
assign disk2_in      = 1'b0;
assign img2_ds       = 1'b0;
assign img2_800k     = 1'b0;
assign img2_tags     = 1'b0;
assign img2_mfm      = 1'b0;
assign img2_hd       = 1'b0;
assign flp2_readonly = 1'b0;
assign flp2_loading  = 1'b0;
assign ld2_req       = 1'b0;
assign ld2_addr      = 24'd0;
assign ld2_wdata     = 16'd0;
assign en2_req       = 1'b0;
assign en2_addr      = 24'd0;
assign trk2_cyl      = 7'd0;
assign trk2_valid    = 1'b0;
assign trk2_bit      = 1'b0;
assign flp2_wr_lba   = 32'd0;
assign flp2_sd_wr    = 1'b0;
assign flp2_sd_din   = 16'd0;
assign de2_req       = 1'b0;
assign de2_addr      = 24'd0;
assign de2_wdata     = 16'd0;
assign wr2_req       = 1'b0;
assign wr2_addr      = 24'd0;
end endgenerate

se30_flp_dkmux flp_dkmux
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.ld0_req(ld_req), .ld0_addr(ld_addr), .ld0_wdata(ld_wdata), .ld0_ack(ld_ack),
	.en0_req(en_req), .en0_addr(en_addr), .en0_rdata(en_rdata), .en0_ack(en_ack),
	.ld1_req(ld2_req), .ld1_addr(ld2_addr), .ld1_wdata(ld2_wdata), .ld1_ack(ld2_ack),
	.en1_req(en2_req), .en1_addr(en2_addr), .en1_rdata(en2_rdata), .en1_ack(en2_ack),
	.de0_req(de_req), .de0_addr(de_addr), .de0_wdata(de_wdata), .de0_ack(de_ack),
	.wr0_req(wr_req), .wr0_addr(wr_addr), .wr0_rdata(wr_rdata), .wr0_ack(wr_ack),
	.de1_req(de2_req), .de1_addr(de2_addr), .de1_wdata(de2_wdata), .de1_ack(de2_ack),
	.wr1_req(wr2_req), .wr1_addr(wr2_addr), .wr1_rdata(wr2_rdata), .wr1_ack(wr2_ack),
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack)
);

// SDRAM
wire        sdram_ready;
wire        mem_start, mem_req, mem_we, mem_ack;
wire [22:0] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata, mem_rdata;

se30_sdram sdram
(
	.clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(pll_locked),
	.ready(sdram_ready), .cap_sel(), .cap_ok(), .cap_fail_a(), .cap_fail_b(),
	.cpu_start(mem_start), .cpu_req(mem_req), .cpu_we(mem_we), .cpu_addr(mem_addr),
	.cpu_be(mem_be), .cpu_wdata(mem_wdata),
	.cpu_rdata(mem_rdata), .cpu_ack(mem_ack),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
	.raw_req(1'b0), .raw_ctl(64'd0), .raw_addr(24'd0), .raw_ack(),
	.dbg_dqm_force(1'b0),
	.sd_clk(SDRAM_CLK), .sd_cke(SDRAM_CKE), .sd_addr(SDRAM_A), .sd_ba(SDRAM_BA), .sd_dq(SDRAM_DQ),
	.sd_dqm({SDRAM_DQMH, SDRAM_DQML}), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE)
);

// the logic board
wire        vidout, hsync_n, vsync_n, hblank, vblank;
wire [63:0] dbg_swim;
se30_machine #(.EXT_DRIVE(EXT_DRIVE), .CDROM_EN(CDROM_EN)) machine
(
	.clk(clk_sys), .phi1(phi1), .phi2(phi2), .reset_n(machine_reset_n), .ram16(ram16),
	.mem_start(mem_start), .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
	.mem_be(mem_be), .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack),
	.declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
	.vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
	.nmi_n(1'b1),
	.pace_en(1'b1),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse), .timestamp(TIMESTAMP),
	.pram_h_we(pram_h_we), .pram_h_addr(pram_h_addr), .pram_h_wdata(pram_h_wdata), .pram_h_raddr(pram_h_raddr),
	.pram_h_rdata(pram_h_rdata), .pram_wr(pram_wr),
	.adb_pm_we(adb_pm_we), .adb_pm_waddr(adb_pm_waddr), .adb_pm_wdata(adb_pm_wdata),
	.disk_in(disk_in), .disk_eject(disk_eject), .disk_cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
	.trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
	.disk_wprot(disk_wprot), .disk_hd(img_hd), .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
	.arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
	.disk2_in(disk2_in), .disk2_eject(disk2_eject), .disk2_cyl(disk2_cyl), .trk2_cyl(trk2_cyl), .trk2_valid(trk2_valid),
	.trk2_addr(trk2_addr), .trk2_side(trk2_side), .trk2_bit(trk2_bit),
	.disk2_wprot(disk2_wprot), .disk2_hd(img2_hd), .trk2_we(trk2_we), .trk2_wbit(trk2_wbit), .trk2_cells(trk2_cells),
	.arc2_done(arc2_done), .arc2_side(arc2_side), .arc2_start(arc2_start), .arc2_end(arc2_end), .arc2_whole(arc2_whole),
	.dbg_swim(dbg_swim), .dbg_fdhd2(dbg_fdhd2),
	.audio_l(asc_audio_l), .audio_r(asc_audio_r),
	.scsi_img_mounted(img_mounted[4:2]), .scsi_img_blocks(img_size[40:9]),
	.scsi_io_lba(scsi_io_lba), .scsi_io_rd(scsi_io_rd), .scsi_io_wr(scsi_io_wr), .scsi_io_blk_cnt(scsi_io_blk_cnt), .scsi_io_ack(sd_ack[4:2]),
	.scsi_sd_buff_addr(sd_buff_addr), .scsi_sd_buff_dout(sd_buff_dout), .scsi_sd_buff_din(scsi_sd_buff_din),
	.scsi_sd_buff_wr(sd_buff_wr),
	.scc_port_in(6'b110_110), .scc_port_out()
);

assign LED_DISK = {1'b0, dbg_swim[15] | dbg_fdhd2[15]};

// video: one pixel per C16M clock
assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = phi1;
assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync_n;
assign VGA_VS = vsync_n;
assign VGA_R  = {8{~vidout}};
assign VGA_G  = {8{~vidout}};
assign VGA_B  = {8{~vidout}};

endmodule
