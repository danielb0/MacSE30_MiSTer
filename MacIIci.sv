//============================================================================
//  Macintosh IIci for MiSTer
//
//  The framework shell around rtl/iici_machine.v (SE30_PLAN.md "THE MacIIci
//  TOP AND ITS SDRAM"): the PLL, hps_io, the reset, the ROM downloads, the
//  floppy's image chain, the PRAM image and the SDRAM controller.  MacSE30.sv
//  is its pattern; the probe deck, the SE/30's video ROM and the IIcx's card
//  are not here.
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
assign LED_DISK  = 0;
assign BUTTONS   = 0;

`include "build_id.v"

// Memory (Daniel 2026-11-13: up to 32 MB at this stage).  Bank A at SDRAM
// 0, bank B at 32 MB (iici_mdu.v), so bank B needs a 64 MB module or more;
// on a 32 MB module only the bank-A sizes are offered.
//   0 = 16 MB  (bank A 16 MB: four 4 MB SIMMs)
//   1 =  4 MB  (bank A 4 MB: four 1 MB SIMMs)
//   2 =  8 MB  (4 MB in each bank)
//   3 = 32 MB  (16 MB in each bank)
// The monitor (THE PORTRAIT DISPLAY): latched at reset, as the ROM reads the
// sense lines once.
localparam CONF_STR = {
	"MACIICI;;",
	"-;",
	"S0,DSKIMG,Mount Internal Floppy;",
	"-;",
	"SC2,IMGVHD,Mount SCSI-0;",
	"SC3,IMGVHD,Mount SCSI-1;",
	"SC4,ISOTO*,Mount CD-ROM;",
	"-;",
	"SC5,NVR,Mount PRAM;",
	"-;",
	"O[12],Monitor,640x480 RGB,Portrait 640x870;",
	"O[2:1],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[9:8],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"h0O[11:10],Memory,16 MB,4 MB;",
	"h1O[11:10],Memory,16 MB,4 MB,8 MB,32 MB;",
	"O[7:6],Mouse speed,Normal,/2,/4,/8;",
	"O[5],Power switch,Normal,Locked on;",
	"-;",
	"R[0],Reset & Apply Memory and Monitor;",
	"R[3],Wipe PRAM (erases settings!);",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [24:0] ps2_mouse_s;
wire  [32:0] TIMESTAMP;
wire         ioctl_download, ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire         ioctl_wait;

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
wire  [31:0] flp_sd_lba, flp_wr_lba;
wire         flp_sd_wr;
wire  [15:0] flp_sd_din;
wire  [95:0] scsi_io_lba;
wire  [47:0] scsi_sd_buff_din;
wire   [2:0] scsi_io_rd, scsi_io_wr;
wire  [17:0] scsi_io_blk_cnt;
assign sd_lba[0]      = flp_sd_wr ? flp_wr_lba : flp_sd_lba;
assign sd_lba[1]      = 32'd0;
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
assign sd_buff_din[1] = 16'd0;
assign sd_buff_din[2] = scsi_sd_buff_din[15:0];
assign sd_buff_din[3] = scsi_sd_buff_din[31:16];
assign sd_buff_din[4] = scsi_sd_buff_din[47:32];
assign sd_buff_din[5] = pram_sd_din;
assign sd_rd[1]       = 1'b0;
assign sd_rd[4:2]     = scsi_io_rd;
assign sd_rd[5]       = pram_sd_rd;
assign sd_wr          = {pram_sd_wr, 1'b0, scsi_io_wr[1:0], 1'b0, flp_sd_wr};

wire [15:0] sdram_sz;
wire [15:0] menumask;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1), .VDNUM(6)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.buttons(buttons),
	.status(status),
	.status_menumask(menumask),
	.sdram_sz(sdram_sz),
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
// One PLL (rtl/pll_iici): clk_sys 50 MHz; clk_mem 150 MHz and its three
// shifted copies for the SDRAM (rtl/iici_sdram.v); clk_k 25 MHz, the CPU
// clock (tg68k.v KCLK); clk_vid 57.14 MHz, the RBV's video.  phi2 is the
// clk_sys clock after a clk_k rising edge, phi1 the one ending at the next.

wire clk_sys, clk_mem, clk_sdc, clk_capa, clk_capb, clk_k, clk_vid, pll_locked;
pll_iici pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_mem),
	.outclk_2(clk_sdc),
	.outclk_3(clk_capa),
	.outclk_4(clk_capb),
	.outclk_5(clk_k),
	.outclk_6(clk_vid),
	.locked(pll_locked)
);

reg tk = 0, tk_q = 0;
always @(posedge clk_k) tk <= ~tk;
always @(posedge clk_sys) tk_q <= tk;
wire phi  = tk ^ tk_q;
wire phi1 = ~phi;
wire phi2 = phi;

reg [1:0] lock_s = 0;
always @(posedge clk_sys) lock_s <= {lock_s[0], pll_locked};

///////////////////////   RESET   ////////////////////////////////
// MacSE30.sv's rules: held until boot0.rom has been streamed, while any
// download runs, until the SDRAM is trained, on the framework's, the OSD's
// and the button's reset, until the saved PRAM is in, and while the soft
// power is off (iicx_power: the IIci's v2PowerOff, data B bit 2).

reg         machine_reset_n = 0;
wire        poweroff_req, pwr_off, pwr_restart;
reg         pwr_key_q = 0;
always @(posedge clk_sys) pwr_key_q <= ps2_key[10];
iicx_power iicx_power
(
	.clk(clk_sys), .running(machine_reset_n), .poweroff_req(poweroff_req), .locked(status[5]),
	.power_key(ps2_key[10] != pwr_key_q && ps2_key[9] && ps2_key[8] && ps2_key[7:0] == 8'h37),
	.reset_req(status[0] || buttons[1] || RESET),
	.off(pwr_off), .restart(pwr_restart)
);

reg rom_loaded = 0;
always @(posedge clk_sys) if (ioctl_download && ioctl_index[7:0] == 8'h00) rom_loaded <= 1'b1;

wire sdram_ready, pram_ready, pram_restart;
reg [15:0] rst_cnt = '1;
always @(posedge clk_sys) begin
	if (!lock_s[1] || !rom_loaded || !sdram_ready || status[0] || buttons[1] || RESET || ioctl_download ||
	    !pram_ready || pram_restart || pwr_off || pwr_restart) begin
		rst_cnt <= '1;
		machine_reset_n <= 0;
	end else if (rst_cnt != 0) rst_cnt <= rst_cnt - 1'd1;
	else machine_reset_n <= 1;
end

// the SIMMs and the monitor change only while the machine is held
wire        big = sdram_sz[15] && (sdram_sz[1:0] >= 2'd2);   // a 64 or 128 MB module: bank B fits
assign      menumask = {14'd0, big, !big};
reg   [1:0] bank_a = 2'd3, bank_b = 2'd0;
reg         portrait = 0;
always @(posedge clk_sys) if (!machine_reset_n) begin
	portrait <= status[12];
	case ((!big && status[11]) ? 2'd0 : status[11:10])
		2'd0: begin bank_a <= 2'd3; bank_b <= 2'd0; end
		2'd1: begin bank_a <= 2'd2; bank_b <= 2'd0; end
		2'd2: begin bank_a <= 2'd2; bank_b <= 2'd2; end
		2'd3: begin bank_a <= 2'd3; bank_b <= 2'd3; end
	endcase
end

///////////////////////   PERSISTENT PRAM   //////////////////////
wire        pram_sd_rd, pram_sd_wr;
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

///////////////////////   ROM DOWNLOADS   ////////////////////////
// boot0.rom, the 512 KB IIci ROM, to the SDRAM's ROM region (word $C00000,
// the MDU's long $600000) as big-endian words; boot2.rom, the ADB
// transceiver's program, into its store.  Each word holds the HPS until
// the memory has taken it.

wire boot0 = (ioctl_index[7:0] == 8'h00);
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
assign ioctl_wait = dl_req;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_download && boot0) begin
		dl_req  <= 1;
		dl_addr <= 24'hC00000 + ioctl_addr[18:1];
		dl_data <= {ioctl_dout[7:0], ioctl_dout[15:8]};
	end else if (dl_req && dl_ack) dl_req <= 0;
end

///////////////////////   THE FLOPPY   ///////////////////////////
// MacSE30.sv's internal-drive chain: the image at word $800000, the encoder,
// the decoder and the SD writer through the SDRAM's disk port.

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

se30_flp_loader flp_loader
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.img_mounted(img_mounted[0]), .img_size(img_size), .img_readonly(img_readonly),
	.sd_lba(flp_sd_lba), .sd_rd(sd_rd[0]), .sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
	.mem_req(ld_req), .mem_addr(ld_addr), .mem_wdata(ld_wdata), .mem_ack(ld_ack),
	.eject(disk_eject), .mac_reset_n(machine_reset_n),
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

se30_flp_dkmux flp_dkmux
(
	.clk(clk_sys), .reset_n(flp_reset_n),
	.ld0_req(ld_req), .ld0_addr(ld_addr), .ld0_wdata(ld_wdata), .ld0_ack(ld_ack),
	.en0_req(en_req), .en0_addr(en_addr), .en0_rdata(en_rdata), .en0_ack(en_ack),
	.ld1_req(1'b0), .ld1_addr(24'd0), .ld1_wdata(16'd0), .ld1_ack(),
	.en1_req(1'b0), .en1_addr(24'd0), .en1_rdata(), .en1_ack(),
	.de0_req(de_req), .de0_addr(de_addr), .de0_wdata(de_wdata), .de0_ack(de_ack),
	.wr0_req(wr_req), .wr0_addr(wr_addr), .wr0_rdata(wr_rdata), .wr0_ack(wr_ack),
	.de1_req(1'b0), .de1_addr(24'd0), .de1_wdata(16'd0), .de1_ack(),
	.wr1_req(1'b0), .wr1_addr(24'd0), .wr1_rdata(), .wr1_ack(),
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack)
);

///////////////////////   SDRAM   ////////////////////////////////
// rtl/iici_sdram.v at 150 MHz.  Its reset is the PLL's lock alone: the ROM
// and the training's choice stay across the machine's resets.

wire        cap_sel;
wire  [1:0] cap_ok;
wire [13:0] cap_fail_a, cap_fail_b;
wire        mem_req, mem_we, mem_burst, mem_ack, mem_refresh, v_req, v_ack;
wire [24:0] mem_addr, v_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata, mem_rdata, v_rdata;

iici_sdram sdram
(
	.clk(clk_mem), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(pll_locked),
	.ready(sdram_ready), .cap_sel(cap_sel), .cap_ok(cap_ok), .cap_fail_a(cap_fail_a), .cap_fail_b(cap_fail_b),
	.c1_ok(), .c1_fail(),
	.m_req(mem_req), .m_we(mem_we), .m_burst(mem_burst), .m_addr(mem_addr), .m_be(mem_be), .m_wdata(mem_wdata),
	.m_rdata(mem_rdata), .m_ack(mem_ack), .m_refresh(mem_refresh),
	.v_req(v_req), .v_addr(v_addr), .v_rdata(v_rdata), .v_ack(v_ack),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
	.dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
	.sd_clk(SDRAM_CLK), .sd_cke(SDRAM_CKE), .sd_addr(SDRAM_A), .sd_ba(SDRAM_BA), .sd_dq(SDRAM_DQ),
	.sd_dqm({SDRAM_DQMH, SDRAM_DQML}), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE)
);

///////////////////////   THE MACHINE   //////////////////////////

wire        ce_pix, hsync_n, vsync_n, hblank, vblank;
wire  [7:0] vid_r, vid_g, vid_b;

se30_mouse_speed mouse_speed (.clk(clk_sys), .speed(status[7:6]), .ps2_in(ps2_mouse), .ps2_out(ps2_mouse_s));

iici_machine machine
(
	.clk(clk_sys), .clk_k(clk_k), .clk_vid(clk_vid), .portrait(portrait), .phi1(phi1), .phi2(phi2),
	.reset_n(machine_reset_n), .bank_a(bank_a), .bank_b(bank_b),
	.mem_req(mem_req), .mem_we(mem_we), .mem_burst(mem_burst), .mem_addr(mem_addr), .mem_be(mem_be),
	.mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_refresh(mem_refresh),
	.v_req(v_req), .v_addr(v_addr), .v_rdata(v_rdata), .v_ack(v_ack),
	.ce_pix(ce_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
	.hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank), .poweroff_req(poweroff_req),
	.nmi_n(1'b1), .pace_en(1'b1),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse_s), .timestamp(TIMESTAMP),
	.pram_h_we(pram_h_we), .pram_h_addr(pram_h_addr), .pram_h_wdata(pram_h_wdata), .pram_h_raddr(pram_h_raddr),
	.pram_h_rdata(pram_h_rdata), .pram_wr(pram_wr),
	.adb_pm_we(adb_pm_we), .adb_pm_waddr(adb_pm_waddr), .adb_pm_wdata(adb_pm_wdata),
	.disk_in(disk_in), .disk_eject(disk_eject), .disk_cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid),
	.trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
	.disk_wprot(disk_wprot), .disk_hd(img_hd), .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
	.arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
	.scsi_img_mounted(img_mounted[4:2]), .scsi_img_blocks(img_size[40:9]),
	.scsi_io_lba(scsi_io_lba), .scsi_io_rd(scsi_io_rd), .scsi_io_wr(scsi_io_wr), .scsi_io_blk_cnt(scsi_io_blk_cnt), .scsi_io_ack(sd_ack[4:2]),
	.scsi_sd_buff_addr(sd_buff_addr), .scsi_sd_buff_dout(sd_buff_dout), .scsi_sd_buff_din(scsi_sd_buff_din),
	.scsi_sd_buff_wr(sd_buff_wr),
	.scc_port_in(6'b110_110), .scc_port_out(),
	.audio_l(asc_audio_l), .audio_r(asc_audio_r),
	.dbg_addr(), .dbg_fc(), .dbg_as_n(), .dbg_rw_n(), .dbg_dsack_n(), .dbg_berr(), .dbg_halted(), .reset_out_n(),
	.dbg_regs(), .dbg_overlay(), .dbg_late()
);

///////////////////////   VIDEO   ////////////////////////////////
// The RBV's picture on clk_vid.  Aspect: the 640 x 480 monitor 4:3; the
// Portrait Display square pixels, 640:870.

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = ce_pix;

wire [1:0] ar = status[2:1];
wire       vga_de = ~(hblank | vblank);
video_freak video_freak
(
	.*,
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? (portrait ? 12'd640 : 12'd4) : (ar - 1'd1)),
	.ARY((!ar) ? (portrait ? 12'd870 : 12'd3) : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[9:8]})
);

assign VGA_HS = hsync_n;
assign VGA_VS = vsync_n;
assign VGA_R  = pwr_off ? 8'd0 : vid_r;
assign VGA_G  = pwr_off ? 8'd0 : vid_g;
assign VGA_B  = pwr_off ? 8'd0 : vid_b;

endmodule
