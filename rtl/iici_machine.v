// iici_machine.v - the Macintosh IIci's logic board: the 68030 at 25 MHz
// with its burst fills, the 68882, the MDU, VIA1, the SCC, the SCSI, the
// SWIM, the ASC, the ADB and the clock chip (SE30_PLAN.md "THE IIci FROM
// THE DOCUMENTATION", "THE MDU", "THE IIci MACHINE").
//
// WHAT IT IS
//   se30_machine.v's arrangement with the IIci's general logic: the MDU
//   (iici_mdu.v) in GLUE's place, the RBV in VIA2's.  The shared devices
//   are the SE/30's modules unchanged, on the MDU's 15.6672 MHz enable as
//   they are on GLUE's C16M.
//
// CLOCKS
//   clk is clk_sys, 50 MHz; clk_k = clk / 2, the CPU clock (25 MHz), rising
//   at the end of each phi1 clk (tg68k.v CLOCKING, KCLK).  The MDU times RAM
//   and ROM on phi2 (the KCLK devices' edge) and makes c16_en; the 68882
//   runs at the CPU's clock (the IIci's 25 MHz FPU, Guide p.115).
//
// THE MEMORY PORT: the MDU's (iici_mdu.v): a request with ECS*, a long
//   (or four, a burst) answered with m_ack, writes posted.  RAM banks A
//   and B as the top sets them; the ROM's 128K longwords at long $600000.
//
// THE RBV (iici_rbv.v): the VIA2-emulation registers, the interrupts,
//   the 60.15 Hz tick to VIA1 CA1, the video - 640 x 480 or the Portrait
//   Display's 640 x 870, on clk_vid - and its Bt478; its
//   screen buffer through the MDU's video bursts and the SDRAM's video
//   port (v_*).
//
// VIA1 (G Table 4-6): PA7 vSCCWrReq, PA6/4/2/1 CPU.ID3-0 = 1/0/1/1 (the
//   IIci without parity, Table 4-8), PA5 vHeadSel, PA3 vSync, PA0 reserved;
//   port B as the SE/30's (ADB, the clock chip), PB7 /Par.Err high (no
//   parity option).
//
// NOT HERE YET - the cache card, NuBus cards: every slot is empty (the
//   NuChip times it out).

`timescale 1ns/1ps

module iici_machine #(
  parameter FPU_UCODE = "rtl/fpu/ucode/",
  parameter CDROM_EN  = 1,
  parameter ROM_AW    = 17                   // 512 KB
) (
  input         clk,
  input         clk_k,
  input         clk_vid,               // 57.28 MHz: the RBV's video (THE PORTRAIT DISPLAY)
  input         portrait,              // the monitor: 1 = the Portrait Display, 0 = 640 x 480 (latched at reset by the top)
  input         phi1,
  input         phi2,
  input         reset_n,
  input   [1:0] bank_a,                // 0 empty, 1 = 1 MB, 2 = 4 MB, 3 = 16 MB
  input   [1:0] bank_b,

  // the memory port, to the SDRAM controller (iici_mdu.v)
  output        mem_req,
  output        mem_we,
  output        mem_burst,
  output [24:0] mem_addr,
  output  [3:0] mem_be,
  output [31:0] mem_wdata,
  input  [31:0] mem_rdata,
  input         mem_ack,
  input         mem_soon,              // iici_sdram's m_soon (iici_mdu.v)
  output        mem_refresh,
  // the video's port: 8 longs a request (iici_mdu.v)
  output        v_req,
  output [24:0] v_addr,
  input  [31:0] v_rdata,
  input         v_ack,

  // the picture, on clk_vid
  output        ce_pix,
  output  [7:0] vid_r,
  output  [7:0] vid_g,
  output  [7:0] vid_b,
  output        hsync_n,
  output        vsync_n,
  output        hblank,
  output        vblank,
  output        poweroff_req,          // data B's v2PowerOff

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

  // the internal drive's disk (se30_fdhd's disk interface)
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

  output [15:0] audio_l,
  output [15:0] audio_r,

  // for the benches and the probe deck
  output [31:0] dbg_addr,
  output  [2:0] dbg_fc,
  output        dbg_as_n,
  output        dbg_rw_n,
  output  [1:0] dbg_dsack_n,
  output        dbg_berr,
  output        dbg_halted,
  output        reset_out_n,
  output [63:0] dbg_regs,
  output        dbg_overlay,
  output [15:0] dbg_late
);

  // ---------------------------------------------------------- the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        ecs, cpu_as_n, cpu_ds_n, cpu_rw_n, berr, halted, cbreq, cback;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k #(.KCLK(1), .BURST(1)) cpu (
    .clk(clk), .clk_k(clk_k), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .ecs(ecs), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cdis(1'b0), .coff(2'b00), .pace_en(pace_en), .post_en(1'b1),
    .reset_out_n(reset_out_n), .halted(halted),
    .cbreq(cbreq), .cback(cback),
    .dbg_d6(dbg_regs[63:32]), .dbg_d7(dbg_regs[31:0]), .dbg_trg(), .dbg_exc(), .dbg_cache(), .dbg_pace(), .dbg_mmuf(),
    .dbg_rpr(), .dbg_rpk(), .dbg_jtp(), .dbg_jte());

  assign dbg_addr = cpu_addr;  assign dbg_fc = cpu_fc;  assign dbg_as_n = cpu_as_n;
  assign dbg_rw_n = cpu_rw_n;  assign dbg_dsack_n = dsack_n;  assign dbg_berr = berr;
  assign dbg_halted = halted;

  // ------------------------------------------------------------ the MDU
  wire        c16_en, e_clk, c3m_en, dev_strobe, dev_rw, scsi_drq, scsi_irq;
  wire        via1_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, vdac_sel, rbv_sel, slot_sel;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata, dev_rdata;
  wire        fpu_sel;
  wire  [1:0] fpu_dsack_n, nb_dsack_n, nb_tm;
  wire [31:0] fpu_rdata, nb_rdata;
  wire        nb_berr;
  wire  [3:0] slot_be;
  wire        via1_irq_n, rbv_irq_n, scc_irq_n;
  wire        vid_req, vid_frame, vid_ld, asc_irq_n;
  wire [31:0] vid_data;

  iici_mdu #(.ROM_AW(ROM_AW)) mdu (
    .clk(clk), .cpu_en(phi2), .reset_n(reset_n), .c16_en(c16_en),
    .cpu_addr(cpu_addr), .ecs(ecs), .cpu_as_n(cpu_as_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc), .cpu_siz(cpu_siz),
    .cpu_dout(cpu_dout), .cpu_din(cpu_din), .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .cbreq(cbreq), .cback(cback),
    .bank_a(bank_a), .bank_b(bank_b),
    .m_req(mem_req), .m_we(mem_we), .m_burst(mem_burst), .m_addr(mem_addr), .m_be(mem_be), .m_wdata(mem_wdata),
    .m_rdata(mem_rdata), .m_ack(mem_ack), .m_soon(mem_soon), .m_refresh(mem_refresh),
    .vid_req(vid_req), .vid_frame(vid_frame), .vid_ld(vid_ld), .vid_data(vid_data),
    .v_req(v_req), .v_addr(v_addr), .v_rdata(v_rdata), .v_ack(v_ack),
    .via1_sel(via1_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack), .asc_sel(asc_sel),
    .swim_sel(swim_sel), .vdac_sel(vdac_sel), .rbv_sel(rbv_sel),
    .dev_strobe(dev_strobe), .dev_addr(dev_addr), .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(dev_rdata),
    .scsi_drq(scsi_drq), .e_clk(e_clk), .c3m_en(c3m_en),
    .fpu_sel(fpu_sel), .fpu_dsack_n(fpu_dsack_n), .fpu_rdata(fpu_rdata),
    .slot_sel(slot_sel), .nb_dsack_n(nb_dsack_n), .nb_rdata(nb_rdata), .nb_berr(nb_berr), .slot_be(slot_be),
    .via1_irq_n(via1_irq_n), .rbv_irq_n(rbv_irq_n), .scc_irq_n(scc_irq_n), .nmi_n(nmi_n),
    .overlay(dbg_overlay), .dbg_late(dbg_late));

  // ------------------------------------------------------------ the FPU
  se30_fpu #(
    .UROM_HEX({FPU_UCODE, "ucode.urom.hex"}), .NROM_HEX({FPU_UCODE, "ucode.nrom.hex"}),
    .ENTRY_HEX({FPU_UCODE, "ucode.entry.hex"}), .KROM_HEX({FPU_UCODE, "ucode.krom.hex"}),
    .NSEL_HEX({FPU_UCODE, "ucode.nsel.hex"}),
    .CVT_HEX({FPU_UCODE, "ucode.cvt.hex"}), .CVSEL_HEX({FPU_UCODE, "ucode.cvsel.hex"}), .TADJ_HEX({FPU_UCODE, "ucode.tadj.hex"})
  ) fpu (
    .clk(clk), .ce(phi2), .reset(!(reset_n && reset_out_n)),
    .cs(fpu_sel), .rw(cpu_rw_n), .a(cpu_addr[4:0]), .din(cpu_dout), .dout(fpu_rdata),
    .dsack_n(fpu_dsack_n),
    .dbg_exop(), .dbg_clocks(), .dbg_err(), .dbg_state(), .dbg_busy());

  // ------------------------------------------------------- NuBus: empty
  wire [19:0] card_addr_nc;
  iicx_nuchip #(.NB_NUM(1), .NB_DEN(5)) nuchip (                  // 10 MHz from 50
    .clk(clk), .reset_n(reset_n),
    .sel(slot_sel), .addr(cpu_addr), .rw(cpu_rw_n), .be(slot_be), .wdata(cpu_dout),
    .rdata(nb_rdata), .dsack_n(nb_dsack_n), .berr(nb_berr), .tm_pb54(nb_tm), .nb_tick(),
    .card_sel(), .card_addr(card_addr_nc), .card_rw(), .card_be(), .card_wdata(), .card_rdata(32'h0), .card_ack(1'b0));

  // ------------------------------------------------------------- RBV
  wire       via_reset_n = reset_n && reset_out_n;
  wire       vbl_n, poweroff_n;
  wire [7:0] rbv_rdata;
  iici_rbv rbv (
    .clk(clk), .clk_vid(clk_vid), .reset_n(via_reset_n), .c16_en(c16_en), .portrait(portrait),
    .rbv_sel(rbv_sel), .vdac_sel(vdac_sel), .strobe(dev_strobe && c16_en), .addr(dev_addr[4:0]), .rw(dev_rw),
    .wdata(dev_wdata), .rdata(rbv_rdata),
    .scsi_irq(scsi_irq), .scsi_drq(scsi_drq), .asc_irq_n(asc_irq_n), .exp_irq_n(1'b1),
    .slot_irq_n(3'b111), .nb_tm(nb_tm), .irq_n(rbv_irq_n), .tick_n(vbl_n),
    .cflush_n(), .cenable_n(), .poweroff_n(poweroff_n), .buslk_n(),
    .vid_req(vid_req), .vid_frame(vid_frame), .vid_ld(vid_ld), .vid_data(vid_data),
    .ce_pix(ce_pix), .r(vid_r), .g(vid_g), .b(vid_b), .hs_n(hsync_n), .vs_n(vsync_n), .hblank(hblank), .vblank(vblank),
    .dbg_underflow());
  assign poweroff_req = !poweroff_n;

  // ------------------------------------------------------------- VIA1
  wire        adb_int_n, adb_sclk, adb_dio, via1_cb2_out, via1_cb2_oe;
  wire        rtc_d_out, rtc_d_oe, rtc_1hz, rtc_d;
  wire  [7:0] via1_rdata, swim_rdata, asc_rdata, scsi_rdata, scc_rdata;
  wire        scc_w_req_n;
  wire  [7:0] via1_pa_out, via1_pa_oe, via1_pb_out, via1_pb_oe;
  // Table 4-6: PA7 vSCCWrReq, CPU.ID3-0 on PA6/4/2/1 = 1/0/1/1, PA0 reserved (reads 1)
  wire  [7:0] via1_pa_ext = {scc_w_req_n, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1};
  wire  [7:0] via1_pb_ext = {4'b1111, adb_int_n, 2'b11, rtc_d};   // PB7 /Par.Err high; PB3 ADB INT*; PB0 the clock's data
  wire  [7:0] via1_pa_pin = (via1_pa_oe & via1_pa_out) | (~via1_pa_oe & via1_pa_ext);
  wire  [7:0] via1_pb_pin = (via1_pb_oe & via1_pb_out) | (~via1_pb_oe & via1_pb_ext);

  assign dev_rdata = via1_sel ? via1_rdata : swim_sel ? swim_rdata : asc_sel ? asc_rdata :
                     (scsi_sel || scsi_dack) ? scsi_rdata : scc_sel ? scc_rdata : (rbv_sel || vdac_sel) ? rbv_rdata : 8'h00;

  se30_via via1 (
    .clk(clk), .c16_en(c16_en), .reset_n(via_reset_n), .e_clk(e_clk),
    .sel(via1_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .rw(dev_rw), .wdata(dev_wdata),
    .rdata(via1_rdata), .irq_n(via1_irq_n),
    .pa_in(via1_pa_pin), .pa_out(via1_pa_out), .pa_oe(via1_pa_oe),
    .pb_in(via1_pb_pin), .pb_out(via1_pb_out), .pb_oe(via1_pb_oe),
    .ca1(vbl_n),                                         // the RBV's 60.15 Hz tick
    .ca2_in(rtc_1hz), .ca2_out(), .ca2_oe(),
    .cb1_in(adb_sclk), .cb1_out(), .cb1_oe(),
    .cb2_in(adb_dio), .cb2_out(via1_cb2_out), .cb2_oe(via1_cb2_oe),
    .dbg_ifr(), .dbg_ier());

  // ------------------------------------------------------------- ADB
  wire xcvr_pull, kbd_pull, mouse_pull;
  wire adb_line = !(xcvr_pull | kbd_pull | mouse_pull);
  se30_adb_xcvr xcvr (
    .clk(clk), .c16_en(c16_en), .c3m_en(c3m_en), .reset_n(via_reset_n),
    .pm_we(adb_pm_we), .pm_waddr(adb_pm_waddr), .pm_wdata(adb_pm_wdata),
    .st0(via1_pb_pin[4]), .st1(via1_pb_pin[5]), .int_n(adb_int_n), .sclk(adb_sclk),
    .via_cb2_out(via1_cb2_out), .via_cb2_oe(via1_cb2_oe), .dio(adb_dio),
    .line(adb_line), .pull(xcvr_pull), .dbg());
  se30_adb_kbd kbd (
    .clk(clk), .reset(1'b0), .ps2_key(ps2_key), .line(adb_line), .pull(kbd_pull), .dbg());
  se30_adb_mouse mouse (
    .clk(clk), .reset(1'b0), .ps2_mouse(ps2_mouse), .line(adb_line), .pull(mouse_pull), .dbg());

  // ------------------------------------------------------------- RTC
  assign rtc_d = rtc_d_oe ? rtc_d_out : 1'b1;
  se30_rtc rtc (
    .clk(clk), .timestamp(timestamp),
    .cs_n(via1_pb_pin[2]), .sck(via1_pb_pin[1]), .d_in(via1_pb_pin[0]),
    .d_out(rtc_d_out), .d_oe(rtc_d_oe), .one_hz(rtc_1hz),
    .h_we(pram_h_we), .h_addr(pram_h_addr), .h_wdata(pram_h_wdata), .h_raddr(pram_h_raddr),
    .h_rdata(pram_h_rdata), .pram_wr(pram_wr), .dbg());

  // ------------------------------------------------------------- ASC
  se30_asc asc (
    .clk(clk), .c16_en(c16_en), .reset_n(via_reset_n),
    .sel(asc_sel), .strobe(dev_strobe), .rw(dev_rw), .addr(dev_addr[11:0]), .wdata(dev_wdata),
    .rdata(asc_rdata), .irq_n(asc_irq_n), .audio_l(audio_l), .audio_r(audio_r), .dbg());

  // ------------------------------------------------------------ SWIM
  wire  [3:0] swim_ph, swim_ph_oe;
  wire        enbl1_n, enbl2_n, fdhd_sense, swim_wrdata, swim_wrreq_n;
  wire  [3:0] swim_ph_pin = (swim_ph_oe & swim_ph) | ~swim_ph_oe;
  se30_swim swim (
    .clk(clk), .c16_en(c16_en), .reset_n(via_reset_n),
    .sel(swim_sel), .strobe(dev_strobe), .rs(dev_addr[12:9]), .wdata(dev_wdata), .rdata(swim_rdata),
    .ph_out(swim_ph), .ph_oe(swim_ph_oe), .ph_in(swim_ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(fdhd_sense),
    .wrdata(swim_wrdata), .wrreq_n(swim_wrreq_n), .hdsel(),
    .dbg(), .dbg_vread());
  se30_fdhd fdhd_int (
    .clk(clk), .c16_en(c16_en), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(swim_ph_pin), .sel(via1_pa_pin[5]),
    .sense(fdhd_sense), .disk_in(disk_in), .eject(disk_eject),
    .cyl(disk_cyl), .trk_cyl(trk_cyl), .trk_valid(trk_valid), .trk_addr(trk_addr), .trk_side(trk_side), .trk_bit(trk_bit),
    .hd(disk_hd), .wprot(disk_wprot), .wrreq_n(swim_wrreq_n), .wrdata(swim_wrdata),
    .trk_we(trk_we), .trk_wbit(trk_wbit), .trk_cells(trk_cells),
    .arc_done(arc_done), .arc_side(arc_side), .arc_start(arc_start), .arc_end(arc_end), .arc_whole(arc_whole),
    .dbg());

  // ------------------------------------------------------------ SCSI
  wire scsi_stb = dev_strobe && c16_en && (scsi_sel || scsi_dack);
  se30_scsi #(.CDROM_EN(CDROM_EN)) scsi (
    .clk(clk), .reset_n(via_reset_n), .sys_reset_n(reset_n),
    .cs(scsi_sel), .dack(scsi_dack), .rd(scsi_stb && dev_rw), .wr(scsi_stb && !dev_rw),
    .rs(dev_addr[6:4]), .wdata(dev_wdata), .rdata(scsi_rdata), .drq(scsi_drq), .irq(scsi_irq),
    .img_mounted(scsi_img_mounted), .img_blocks(scsi_img_blocks),
    .io_lba(scsi_io_lba), .io_rd(scsi_io_rd), .io_wr(scsi_io_wr), .io_blk_cnt(scsi_io_blk_cnt), .io_ack(scsi_io_ack),
    .sd_buff_addr(scsi_sd_buff_addr), .sd_buff_dout(scsi_sd_buff_dout), .sd_buff_din(scsi_sd_buff_din),
    .sd_buff_wr(scsi_sd_buff_wr), .dbg());

  // ------------------------------------------------------------ SCC
  wire scc_stb = dev_strobe && c16_en && scc_sel;
  se30_scc scc (
    .clk(clk), .c16_en(c16_en), .c3m_en(c3m_en), .reset_n(reset_n),
    .stb(scc_stb), .rd(dev_rw), .a1(dev_addr[1]), .a2(dev_addr[2]), .wdata(dev_wdata), .rdata(scc_rdata),
    .irq_n(scc_irq_n),
    .vsync(via1_pa_pin[3]), .w_req_n(scc_w_req_n),
    .a_rxd(scc_port_in[5]), .a_hski(scc_port_in[4]), .a_gpi(scc_port_in[3]),
    .b_rxd(scc_port_in[2]), .b_hski(scc_port_in[1]), .b_gpi(scc_port_in[0]),
    .a_txd(scc_port_out[5]), .a_txd_en(scc_port_out[4]), .a_hsko(scc_port_out[3]),
    .b_txd(scc_port_out[2]), .b_txd_en(scc_port_out[1]), .b_hsko(scc_port_out[0]),
    .dbg());

endmodule
