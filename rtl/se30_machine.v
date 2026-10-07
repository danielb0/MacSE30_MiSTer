// se30_machine.v - the SE/30 logic board

`timescale 1ns/1ps

module se30_machine #(
  parameter DECLROM_HEX = "",
  parameter V_TOTAL     = 370,
  parameter FPU_UCODE   = "rtl/fpu/ucode/",
  parameter EXT_DRIVE   = 1,
  parameter CDROM_EN    = 1
) (
  input         clk,
  input         phi1,
  input         phi2,
  input         reset_n,
  input         ram16,

  output        mem_start,
  output        mem_req,
  output        mem_we,
  output [22:0] mem_addr,
  output  [3:0] mem_be,
  output [31:0] mem_wdata,
  input  [31:0] mem_rdata,
  input         mem_ack,

  input         declrom_we,
  input  [12:0] declrom_waddr,
  input   [7:0] declrom_wdata,

  output        vidout,
  output        hsync_n,
  output        vsync_n,
  output        hblank,
  output        vblank,

  input         nmi_n,
  input         pace_en,

  input  [10:0] ps2_key,
  input  [24:0] ps2_mouse,
  input  [32:0] timestamp,
  input         pram_h_we,
  input   [7:0] pram_h_addr,
  input   [7:0] pram_h_wdata,
  input   [7:0] pram_h_raddr,
  output  [7:0] pram_h_rdata,
  output        pram_wr,

  input         adb_pm_we,
  input   [8:0] adb_pm_waddr,
  input  [11:0] adb_pm_wdata,

  input         disk_in,
  output        disk_eject,
  output  [6:0] disk_cyl,
  input   [6:0] trk_cyl,
  input         trk_valid,
  output [17:0] trk_addr,
  output        trk_side,
  input         trk_bit,
  input         disk_wprot,
  input         disk_hd,
  output        trk_we,
  output        trk_wbit,
  output [17:0] trk_cells,
  output        arc_done,
  output        arc_side,
  output [17:0] arc_start,
  output [17:0] arc_end,
  output        arc_whole,

  input         disk2_in,
  output        disk2_eject,
  output  [6:0] disk2_cyl,
  input   [6:0] trk2_cyl,
  input         trk2_valid,
  output [17:0] trk2_addr,
  output        trk2_side,
  input         trk2_bit,
  input         disk2_wprot,
  input         disk2_hd,
  output        trk2_we,
  output        trk2_wbit,
  output [17:0] trk2_cells,
  output        arc2_done,
  output        arc2_side,
  output [17:0] arc2_start,
  output [17:0] arc2_end,
  output        arc2_whole,

  input   [2:0] scsi_img_mounted,
  input  [31:0] scsi_img_blocks,
  output [95:0] scsi_io_lba,
  output  [2:0] scsi_io_rd,
  output  [2:0] scsi_io_wr,
  output [17:0] scsi_io_blk_cnt,
  input   [2:0] scsi_io_ack,
  input  [12:0] scsi_sd_buff_addr,
  input  [15:0] scsi_sd_buff_dout,
  output [47:0] scsi_sd_buff_din,
  input         scsi_sd_buff_wr,

  input   [5:0] scc_port_in,
  output  [5:0] scc_port_out,

  output [31:0] dbg_addr,
  output  [2:0] dbg_fc,
  output        dbg_as_n,
  output        dbg_rw_n,
  output  [1:0] dbg_dsack_n,
  output        dbg_berr,
  output        dbg_halted,
  output        reset_out_n,
  output [31:0] dbg_via,
  output [63:0] dbg_regs,
  output [56:0] dbg_exc,
  output [55:0] dbg_mmuf,
  output [63:0] dbg_cache,
  output [63:0] dbg_swim,
  output [15:0] dbg_fdhd2,
  output        dbg_swim_vread,
  output [63:0] dbg_adb,
  output [31:0] dbg_rtc,
  output [15:0] dbg_scsi,
  output [31:0] dbg_scc,
  output [31:0] dbg_asc,
  output  [1:0] dbg_fpu,
  output [35:0] dbg_pace,
  output [15:0] audio_l,
  output [15:0] audio_r
);

  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        ecs, cpu_as_n, cpu_ds_n, cpu_rw_n, berr, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;
  wire        cpu_cdis;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .ecs(ecs), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(cpu_cdis), .pace_en(pace_en), .post_en(1'b1), .reset_out_n(reset_out_n), .halted(halted),
    .dbg_d6(dbg_regs[63:32]), .dbg_d7(dbg_regs[31:0]), .dbg_exc(dbg_exc), .dbg_cache(dbg_cache), .dbg_pace(dbg_pace), .dbg_mmuf(dbg_mmuf));

  assign dbg_addr = cpu_addr;  assign dbg_fc = cpu_fc;  assign dbg_as_n = cpu_as_n;
  assign dbg_rw_n = cpu_rw_n;  assign dbg_dsack_n = dsack_n;  assign dbg_berr = berr;
  assign dbg_halted = halted;

  wire        mem_early, rom_early;
  wire        ram_req, ram_we, ram_ack, rom_req, rom_ack, ram_refresh;
  wire [24:0] ram_addr;
  wire [31:0] ram_rdata;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        scsi_drq, scsi_irq;
  wire        scsi_hs_wait;
  wire [15:0] scsi_dbg;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  wire        vid_dsack0_n, irq6_n, vid_sel;
  wire  [7:0] vid_dout;
  wire        fpu_sel;
  wire  [1:0] fpu_dsack_n;
  wire [31:0] fpu_rdata;

  wire        overlay, vid_page, vsyncen_n, via1_irq_n, via2_irq_n;
  wire  [1:0] ramsiz;
  wire  [7:0] dev_rdata;
  wire        scc_irq_n, scc_w_req_n;
  wire  [7:0] scc_rdata;

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .mem_early(mem_early), .rom_early(rom_early),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(ram_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata), .scsi_drq(scsi_drq),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .fpu_sel(fpu_sel), .fpu_dsack_n(fpu_dsack_n), .fpu_rdata(fpu_rdata),
    .slot_sel(slot_sel), .slot_dsack0_n(vid_sel ? vid_dsack0_n : 1'b1), .slot_rdata(vid_dout),
    .via1_irq_n(via1_irq_n), .via2_irq_n(via2_irq_n), .scc_irq_n(scc_irq_n), .nmi_n(nmi_n),
    .slot_irq_n({irq6_n, 5'b11111}), .slot_irq_or_n(slot_irq_or_n),
    .overlay(overlay), .ramsiz(ramsiz), .hsync_n(hsync_n), .dbg_hs_wait(scsi_hs_wait));

  se30_fpu #(
    .UROM_HEX({FPU_UCODE, "ucode.urom.hex"}), .NROM_HEX({FPU_UCODE, "ucode.nrom.hex"}),
    .ENTRY_HEX({FPU_UCODE, "ucode.entry.hex"}), .KROM_HEX({FPU_UCODE, "ucode.krom.hex"}),
    .NSEL_HEX({FPU_UCODE, "ucode.nsel.hex"}),
    .CVT_HEX({FPU_UCODE, "ucode.cvt.hex"}), .CVSEL_HEX({FPU_UCODE, "ucode.cvsel.hex"}), .TADJ_HEX({FPU_UCODE, "ucode.tadj.hex"})
  ) fpu (
    .clk(clk), .ce(phi1), .reset(!(reset_n && reset_out_n)),
    .cs(fpu_sel), .rw(cpu_rw_n), .a(cpu_addr[4:0]), .din(cpu_dout), .dout(fpu_rdata),
    .dsack_n(fpu_dsack_n),
    .dbg_exop(), .dbg_clocks(), .dbg_err(), .dbg_state(), .dbg_busy(dbg_fpu));

  assign mem_start = ecs && mem_early;
  assign mem_req   = ram_req || rom_req;
  wire [21:0] ram_phys;
  wire        ram_empty, ram_empty_q;
  se30_simms simms (
    .clk(clk), .big(ram16), .ramsiz(ramsiz), .ram_addr(ram_addr), .start(mem_start), .sel(!rom_early),
    .phys(ram_phys), .empty(ram_empty), .empty_q(ram_empty_q));
  assign ram_rdata = mem_rdata | {32{ram_empty_q}};

  assign mem_we    = !rom_early && ram_we && !ram_empty;
  assign mem_addr  = rom_early ? {2'b11, 5'b00000, rom_addr} : {1'b0, ram_phys};
  assign mem_be    = ram_be;
  assign mem_wdata = ram_wdata;
  assign ram_ack   = mem_ack;
  assign rom_ack   = mem_ack;

  wire        via_reset_n = reset_n && reset_out_n;
  wire        adb_int_n, adb_sclk, adb_dio, via1_cb2_out, via1_cb2_oe;
  wire        rtc_d_out, rtc_d_oe, rtc_1hz, rtc_d;
  wire  [7:0] via1_rdata, via2_rdata, swim_rdata, asc_rdata, scsi_rdata;
  wire        asc_irq_n;
  wire  [7:0] via1_pa_out, via1_pa_oe, via1_pb_out, via1_pb_oe;
  wire  [7:0] via2_pa_out, via2_pa_oe, via2_pb_out, via2_pb_oe;
  wire  [6:0] via1_ifr, via1_ier, via2_ifr, via2_ier;
  wire  [7:0] via1_pa_ext = {scc_w_req_n, 7'h7F};
  wire  [7:0] via1_pb_ext = {4'b1111, adb_int_n, 2'b11, rtc_d};
  wire  [7:0] via2_pa_ext = {2'b11, irq6_n, 5'b11111};
  wire  [7:0] via2_pb_ext = 8'b1011_0111;
  wire  [7:0] via1_pa_pin = (via1_pa_oe & via1_pa_out) | (~via1_pa_oe & via1_pa_ext);
  wire  [7:0] via1_pb_pin = (via1_pb_oe & via1_pb_out) | (~via1_pb_oe & via1_pb_ext);
  wire  [7:0] via2_pa_pin = (via2_pa_oe & via2_pa_out) | (~via2_pa_oe & via2_pa_ext);
  wire  [7:0] via2_pb_pin = (via2_pb_oe & via2_pb_out) | (~via2_pb_oe & via2_pb_ext);
  assign      cpu_cdis    = !via2_pb_pin[0];
  assign overlay   = via1_pa_pin[4];
  assign vid_page  = via1_pa_pin[6];
  assign vsyncen_n = via1_pb_pin[6];
  assign ramsiz    = via2_pa_pin[7:6];
  assign dev_rdata = via1_sel ? via1_rdata : via2_sel ? via2_rdata : swim_sel ? swim_rdata :
                     asc_sel ? asc_rdata : (scsi_sel || scsi_dack) ? scsi_rdata : scc_sel ? scc_rdata : 8'h00;
  assign dbg_via   = {overlay, ramsiz, vsyncen_n, via1_ier, via1_ifr, via2_ier, via2_ifr};

  se30_via via1 (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n), .e_clk(e_clk),
    .sel(via1_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via1_rdata), .irq_n(via1_irq_n),
    .pa_in(via1_pa_pin), .pa_out(via1_pa_out), .pa_oe(via1_pa_oe),
    .pb_in(via1_pb_pin), .pb_out(via1_pb_out), .pb_oe(via1_pb_oe),
    .ca1(via2_pb_pin[7]),
    .ca2_in(rtc_1hz), .ca2_out(), .ca2_oe(),
    .cb1_in(adb_sclk), .cb1_out(), .cb1_oe(),
    .cb2_in(adb_dio), .cb2_out(via1_cb2_out), .cb2_oe(via1_cb2_oe),
    .dbg_ifr(via1_ifr), .dbg_ier(via1_ier));

  se30_via via2 (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n), .e_clk(e_clk),
    .sel(via2_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via2_rdata), .irq_n(via2_irq_n),
    .pa_in(via2_pa_pin), .pa_out(via2_pa_out), .pa_oe(via2_pa_oe),
    .pb_in(via2_pb_pin), .pb_out(via2_pb_out), .pb_oe(via2_pb_oe),
    .ca1(slot_irq_or_n),
    .ca2_in(scsi_drq), .ca2_out(), .ca2_oe(),
    .cb1_in(asc_irq_n), .cb1_out(), .cb1_oe(),
    .cb2_in(scsi_irq), .cb2_out(), .cb2_oe(),
    .dbg_ifr(via2_ifr), .dbg_ier(via2_ier));

  wire        xcvr_pull, kbd_pull, mouse_pull;
  wire        adb_line = !(xcvr_pull | kbd_pull | mouse_pull);
  wire [63:0] xcvr_dbg;
  wire [15:0] kbd_dbg, mouse_dbg;
  reg  [15:0] adb_falls = 0;
  reg         adb_line_q = 1;
  always @(posedge clk) begin
    adb_line_q <= adb_line;
    if (adb_line_q && !adb_line) adb_falls <= adb_falls + 1'b1;
  end
  assign dbg_adb = {xcvr_dbg[63:55], xcvr_dbg[54:47],
                    adb_line, adb_int_n, adb_sclk, adb_dio, via1_pb_pin[5], via1_pb_pin[4],
                    xcvr_pull, kbd_pull, mouse_pull,
                    kbd_dbg[15:12], mouse_dbg[15:12], kbd_dbg[11:4], adb_falls, 6'd0};

  se30_adb_xcvr xcvr (
    .clk(clk), .c16_en(phi1), .c3m_en(c3m_en), .reset_n(via_reset_n),
    .pm_we(adb_pm_we), .pm_waddr(adb_pm_waddr), .pm_wdata(adb_pm_wdata),
    .st0(via1_pb_pin[4]), .st1(via1_pb_pin[5]), .int_n(adb_int_n), .sclk(adb_sclk),
    .via_cb2_out(via1_cb2_out), .via_cb2_oe(via1_cb2_oe), .dio(adb_dio),
    .line(adb_line), .pull(xcvr_pull), .dbg(xcvr_dbg));

  se30_adb_kbd kbd (
    .clk(clk), .reset(1'b0), .ps2_key(ps2_key), .line(adb_line), .pull(kbd_pull), .dbg(kbd_dbg));

  se30_adb_mouse mouse (
    .clk(clk), .reset(1'b0), .ps2_mouse(ps2_mouse), .line(adb_line), .pull(mouse_pull), .dbg(mouse_dbg));

  assign      rtc_d = rtc_d_oe ? rtc_d_out : 1'b1;

  se30_rtc rtc (
    .clk(clk), .timestamp(timestamp),
    .cs_n(via1_pb_pin[2]), .sck(via1_pb_pin[1]), .d_in(via1_pb_pin[0]),
    .d_out(rtc_d_out), .d_oe(rtc_d_oe), .one_hz(rtc_1hz),
    .h_we(pram_h_we), .h_addr(pram_h_addr), .h_wdata(pram_h_wdata), .h_raddr(pram_h_raddr),
    .h_rdata(pram_h_rdata), .pram_wr(pram_wr), .dbg(dbg_rtc));

  se30_asc asc (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n),
    .sel(asc_sel), .strobe(dev_strobe), .rw(dev_rw), .addr(dev_addr[11:0]), .wdata(dev_wdata),
    .rdata(asc_rdata), .irq_n(asc_irq_n), .audio_l(audio_l), .audio_r(audio_r), .dbg(dbg_asc));

  wire  [3:0] swim_ph, swim_ph_oe;
  wire        enbl1_n, enbl2_n, fdhd_sense, fdhd2_sense;
  wire        swim_wrdata, swim_wrreq_n;
  wire [47:0] swim_dbg;
  wire [15:0] fdhd_dbg;
  wire  [3:0] swim_ph_pin = (swim_ph_oe & swim_ph) | ~swim_ph_oe;
  wire        swim_sense  = fdhd_sense & fdhd2_sense;
  assign dbg_swim = {swim_dbg, fdhd_dbg};

  se30_swim swim (
    .clk(clk), .c16_en(phi1), .reset_n(via_reset_n),
    .sel(swim_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .wdata(dev_wdata), .rdata(swim_rdata),
    .ph_out(swim_ph), .ph_oe(swim_ph_oe), .ph_in(swim_ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(swim_sense),
    .wrdata(swim_wrdata), .wrreq_n(swim_wrreq_n), .hdsel(),
    .dbg(swim_dbg), .dbg_vread(dbg_swim_vread));

  se30_fdhd fdhd_int (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
    .sense(fdhd_sense), .disk_in(disk_in), .eject(disk_eject),
    .cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .hd(disk_hd), .wprot(disk_wprot), .wrreq_n(swim_wrreq_n), .wrdata(swim_wrdata),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
    .dbg(fdhd_dbg));

  generate if (EXT_DRIVE) begin : ext
    se30_fdhd fdhd_ext (
      .clk(clk), .c16_en(phi1), .reset_n(reset_n),
      .enbl_n(enbl2_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
      .sense(fdhd2_sense), .disk_in(disk2_in), .eject(disk2_eject),
      .cyl(disk2_cyl), .trk_cyl(trk2_cyl), .trk_valid(trk2_valid), .trk_addr(trk2_addr), .trk_side(trk2_side), .trk_bit(trk2_bit),
      .hd(disk2_hd), .wprot(disk2_wprot), .wrreq_n(swim_wrreq_n), .wrdata(swim_wrdata),
      .trk_we(trk2_we), .trk_wbit(trk2_wbit), .trk_cells(trk2_cells),
      .arc_done(arc2_done), .arc_side(arc2_side), .arc_start(arc2_start), .arc_end(arc2_end), .arc_whole(arc2_whole),
      .dbg(dbg_fdhd2));
  end else begin : noext
    assign fdhd2_sense = 1'b1;
    assign disk2_eject = 1'b0;
    assign disk2_cyl   = 7'd0;
    assign trk2_addr   = 18'd0;
    assign trk2_side   = 1'b0;
    assign dbg_fdhd2   = 16'd0;
    assign trk2_we     = 1'b0;
    assign trk2_wbit   = 1'b0;
    assign trk2_cells  = 18'd0;
    assign arc2_done   = 1'b0;
    assign arc2_side   = 1'b0;
    assign arc2_start  = 18'd0;
    assign arc2_end    = 18'd0;
    assign arc2_whole  = 1'b0;
  end endgenerate

  assign vid_sel = slot_sel && (cpu_addr[31:24] == 8'hFE);

  se30_video #(.DECLROM_HEX(DECLROM_HEX), .V_TOTAL(V_TOTAL)) video (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
    .sel(vid_sel), .as_n(cpu_as_n), .ds_n(cpu_ds_n), .rw(cpu_rw_n), .addr(cpu_addr[16:0]),
    .din(dev_wdata), .dout(vid_dout), .dsack0_n(vid_dsack0_n),
    .page(vid_page), .vsyncen_n(vsyncen_n),
    .vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
    .irq6_n(irq6_n));

  wire scsi_stb = dev_strobe && phi1 && (scsi_sel || scsi_dack);
  se30_scsi #(.CDROM_EN(CDROM_EN)) scsi (
    .clk(clk), .reset_n(via_reset_n), .sys_reset_n(reset_n),
    .cs(scsi_sel), .dack(scsi_dack), .rd(scsi_stb && dev_rw), .wr(scsi_stb && !dev_rw),
    .rs(dev_addr[6:4]), .wdata(dev_wdata), .rdata(scsi_rdata), .drq(scsi_drq), .irq(scsi_irq),
    .img_mounted(scsi_img_mounted), .img_blocks(scsi_img_blocks),
    .io_lba(scsi_io_lba), .io_rd(scsi_io_rd), .io_wr(scsi_io_wr), .io_blk_cnt(scsi_io_blk_cnt), .io_ack(scsi_io_ack),
    .sd_buff_addr(scsi_sd_buff_addr), .sd_buff_dout(scsi_sd_buff_dout), .sd_buff_din(scsi_sd_buff_din),
    .sd_buff_wr(scsi_sd_buff_wr), .dbg(scsi_dbg));
  assign dbg_scsi = {scsi_dbg[15:1], scsi_hs_wait};

  wire scc_stb = dev_strobe && phi1 && scc_sel;
  se30_scc scc (
    .clk(clk), .c16_en(phi1), .c3m_en(c3m_en), .reset_n(reset_n),
    .stb(scc_stb), .rd(dev_rw), .a1(dev_addr[1]), .a2(dev_addr[2]), .wdata(dev_wdata), .rdata(scc_rdata),
    .irq_n(scc_irq_n),
    .vsync(via1_pa_pin[3]), .w_req_n(scc_w_req_n),
    .a_rxd(scc_port_in[5]), .a_hski(scc_port_in[4]), .a_gpi(scc_port_in[3]),
    .b_rxd(scc_port_in[2]), .b_hski(scc_port_in[1]), .b_gpi(scc_port_in[0]),
    .a_txd(scc_port_out[5]), .a_txd_en(scc_port_out[4]), .a_hsko(scc_port_out[3]),
    .b_txd(scc_port_out[2]), .b_txd_en(scc_port_out[1]), .b_hsko(scc_port_out[0]),
    .dbg(dbg_scc));

endmodule
