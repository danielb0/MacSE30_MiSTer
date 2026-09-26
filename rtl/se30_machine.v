// se30_machine.v - the SE/30's logic board: the CPU, GLUE and the video
// today; the VIAs, ASC, SWIM, SCC, SCSI, ADB and RTC as their sections
// land (SE30_PLAN.md 3.5).
//
// WHAT IT IS
//   Everything of the machine that is not the MiSTer framework's, behind
//   one seam: MacSE30.sv (the emu shell) gives it the clocks, the reset,
//   the memory port to the SDRAM controller and the declaration ROM's
//   load, and takes the video; the full-system bench (sim/machine/) gives
//   it the same things without the framework.  Nothing in here knows about
//   hps_io, the scaler or the SDRAM pins.
//
// CLOCKS
//   clk is 2 x C16M (31.3344 MHz, the board's own oscillator); phi1 and
//   phi2 mark C16M's edges, one clk each, alternating.  The CPU wrapper
//   runs the 68030's states on that grid; GLUE and the video take c16_en =
//   phi1.  Nothing runs on any other clock.
//
// THE MEMORY PORT
//   GLUE's RAM and ROM ports, multiplexed onto the SDRAM controller's one
//   32-bit port: mem_start is the 68030's ECS with a RAM or ROM address
//   (GLUE's decode without AS*), mem_req is GLUE's request, and the
//   acknowledge with its data is the cycle's (plan 3.2, 3.3).  The
//   address is a longword address in the 32 MB: RAM at 0 (8 MB, GLUE's
//   flat address truncated), the ROM's 64K longwords at $200000.
//
// NOT HERE YET - the tie-offs below stand in for the VIAs (Section 4):
//   OVERLAY reads 1, as an undriven VIA1 PA4 does at reset (plan 2.11.6),
//   so the ROM is at $0 and RAM is not reachable; RAMSIZ reads 11; the
//   video's page bit reads 1 and its retrace interrupt is disabled; every
//   I/O device answers $00 and raises no interrupt.  The ROM runs from
//   reset to its first VIA access, which is where Section 4 begins.

`timescale 1ns/1ps

module se30_machine #(
  parameter DECLROM_HEX = "",          // the video's declaration ROM preload, for the benches
  parameter V_TOTAL     = 370
) (
  input         clk,
  input         phi1,
  input         phi2,
  input         reset_n,

  // the memory port, to se30_sdram
  output        mem_start,
  output        mem_req,
  output        mem_we,
  output [22:0] mem_addr,
  output  [3:0] mem_be,
  output [31:0] mem_wdata,
  input  [31:0] mem_rdata,
  input         mem_ack,

  // the declaration ROM's load (boot1.rom)
  input         declrom_we,
  input  [12:0] declrom_waddr,
  input   [7:0] declrom_wdata,

  // video, 1 = black
  output        vidout,
  output        hsync_n,
  output        vsync_n,
  output        hblank,
  output        vblank,

  // the programmer's switch
  input         nmi_n,

  // for the probe deck and the benches
  output [31:0] dbg_addr,
  output  [2:0] dbg_fc,
  output        dbg_as_n,
  output        dbg_rw_n,
  output  [1:0] dbg_dsack_n,
  output        dbg_berr,
  output        dbg_halted,
  output        reset_out_n            // the RESET instruction: the peripherals' reset
);

  // ---------------------------------------------------------- the bus
  wire [31:0] cpu_addr, cpu_dout, cpu_din;
  wire        ecs, cpu_as_n, cpu_ds_n, cpu_rw_n, berr, halted;
  wire  [2:0] cpu_fc, ipl_n;
  wire  [1:0] cpu_siz, dsack_n;

  tg68k cpu (
    .clk(clk), .phi1(phi1), .phi2(phi2), .reset_n(reset_n),
    .ecs(ecs), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n),
    .cpu_fc(cpu_fc), .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .reset_out_n(reset_out_n), .halted(halted));

  assign dbg_addr = cpu_addr;  assign dbg_fc = cpu_fc;  assign dbg_as_n = cpu_as_n;
  assign dbg_rw_n = cpu_rw_n;  assign dbg_dsack_n = dsack_n;  assign dbg_berr = berr;
  assign dbg_halted = halted;

  // ------------------------------------------------------------- GLUE
  wire        mem_early, rom_early;
  wire        ram_req, ram_we, ram_ack, rom_req, rom_ack, ram_refresh;
  wire [24:0] ram_addr;
  wire  [3:0] ram_be;
  wire [31:0] ram_wdata;
  wire [15:0] rom_addr;
  wire        via1_sel, via2_sel, scc_sel, scsi_sel, scsi_dack, asc_sel, swim_sel, exp_sel;
  wire        dev_strobe, dev_rw, e_clk, c3m_en, slot_sel, slot_irq_or_n;
  wire [12:0] dev_addr;
  wire  [7:0] dev_wdata;
  wire        vid_dsack0_n, irq6_n, vid_sel;
  wire  [7:0] vid_dout;

  // Section 4's: the VIAs' lines, as they read with the VIAs undriven
  wire        overlay   = 1'b1;        // VIA1 PA4
  wire  [1:0] ramsiz    = 2'b11;       // VIA2 PA7-PA6
  wire        vid_page  = 1'b1;        // VIA1 PA6
  wire        vsyncen_n = 1'b1;        // VIA1 PB6
  wire        via1_irq_n = 1'b1, via2_irq_n = 1'b1, scc_irq_n = 1'b1;

  se30_glue glue (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n), .cpu_ds_n(cpu_ds_n), .cpu_rw_n(cpu_rw_n), .cpu_fc(cpu_fc),
    .cpu_siz(cpu_siz), .cpu_dout(cpu_dout), .cpu_din(cpu_din),
    .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n),
    .mem_early(mem_early), .rom_early(rom_early),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_be(ram_be), .ram_wdata(ram_wdata),
    .ram_rdata(mem_rdata), .ram_ack(ram_ack), .ram_refresh(ram_refresh),
    .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdata(mem_rdata), .rom_ack(rom_ack),
    .via1_sel(via1_sel), .via2_sel(via2_sel), .scc_sel(scc_sel), .scsi_sel(scsi_sel), .scsi_dack(scsi_dack),
    .asc_sel(asc_sel), .swim_sel(swim_sel), .exp_sel(exp_sel), .dev_strobe(dev_strobe), .dev_addr(dev_addr),
    .dev_rw(dev_rw), .dev_wdata(dev_wdata), .dev_rdata(8'h00), .scsi_drq(1'b0),
    .e_clk(e_clk), .c3m_en(c3m_en),
    .slot_sel(slot_sel), .slot_dsack0_n(vid_sel ? vid_dsack0_n : 1'b1), .slot_rdata(vid_dout),
    .via1_irq_n(via1_irq_n), .via2_irq_n(via2_irq_n), .scc_irq_n(scc_irq_n), .nmi_n(nmi_n),
    .slot_irq_n({irq6_n, 5'b11111}), .slot_irq_or_n(slot_irq_or_n),
    .overlay(overlay), .ramsiz(ramsiz), .hsync_n(hsync_n));

  // ------------------------------------------------- the memory port
  // one access a cycle, RAM or ROM by GLUE's decode; the controller's
  // acknowledge is both ports' (GLUE consults the one it requested)
  assign mem_start = ecs && mem_early;
  assign mem_req   = ram_req || rom_req;
  assign mem_we    = ram_req && ram_we;
  assign mem_addr  = rom_early ? {2'b01, 5'b00000, rom_addr} : {2'b00, ram_addr[20:0]};
  assign mem_be    = ram_be;
  assign mem_wdata = ram_wdata;
  assign ram_ack   = mem_ack;
  assign rom_ack   = mem_ack;

  // ------------------------------------------------------------ video
  // slot $E: GLUE's slot select at $FExxxxxx (plan 2.10 item 2: A23-A17
  // are not decoded by the card; A16 picks the declaration ROM)
  assign vid_sel = slot_sel && (cpu_addr[31:24] == 8'hFE);

  se30_video #(.DECLROM_HEX(DECLROM_HEX), .V_TOTAL(V_TOTAL)) video (
    .clk(clk), .c16_en(phi1), .reset_n(reset_n),
    .declrom_we(declrom_we), .declrom_waddr(declrom_waddr), .declrom_wdata(declrom_wdata),
    .sel(vid_sel), .as_n(cpu_as_n), .ds_n(cpu_ds_n), .rw(cpu_rw_n), .addr(cpu_addr[16:0]),
    .din(dev_wdata), .dout(vid_dout), .dsack0_n(vid_dsack0_n),
    .page(vid_page), .vsyncen_n(vsyncen_n),
    .vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(hblank), .vblank(vblank),
    .irq6_n(irq6_n));

endmodule
