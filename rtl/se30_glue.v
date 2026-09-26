// se30_glue.v - the SE/30's GLUE: address decode, acknowledge, RAM and ROM
// control, the E and SCC clocks, the bus-error timeout and the interrupt
// encoder, to the contract of SE30_PLAN.md 2.11.
//
// STUB.  This is the port contract only, so that sim/glue/tb_se30_glue.v
// compiles and fails.  The behaviour is written next.
//
// THE BUS THIS IS WRITTEN TO
//   Not the 68030's pins: the TG68K wrapper's bus (plan 1.4, 2.13), which
//   is 68000-shaped - 16-bit data, UDS*/LDS*, AS*, R/W*, DTACK*, VPA*,
//   BERR, IPL - with a 32-bit address and a flag, lw, that marks the two
//   16-bit beats of a 32-bit access.  Every 8-bit device sits on D15-D8
//   as it sits on D31-D24 of the real machine; GLUE runs one device cycle
//   per byte of a beat, high byte first, which is the 68030's dynamic bus
//   sizing done here because the wrapper cannot do it.

`timescale 1ns/1ps

module se30_glue (
  input         clk,
  input         c16_en,                // one clk per C16M period (15.6672 MHz)
  input         reset_n,

  // CPU
  input  [31:0] cpu_addr,
  input         cpu_as_n,
  input         cpu_uds_n,
  input         cpu_lds_n,
  input         cpu_rw_n,              // 1 = read
  input   [2:0] cpu_fc,
  input         cpu_lw,                // this beat is half of a 32-bit access
  input  [15:0] cpu_dout,              // CPU write data
  output [15:0] cpu_din,               // read data to the CPU
  output        dtack_n,
  output        berr,
  output        vpa_n,                 // interrupt acknowledge: autovector
  output  [2:0] ipl_n,

  // RAM: 16-bit word port
  output        ram_req,
  output        ram_we,
  output [25:0] ram_addr,              // word address, flat over both banks (128MB)
  output  [1:0] ram_ds,                // {upper, lower} byte enables
  output [15:0] ram_wdata,
  input  [15:0] ram_rdata,
  input         ram_ack,
  output        ram_refresh,           // one pulse per refresh cycle

  // ROM: 16-bit word port, 256KB
  output        rom_req,
  output [16:0] rom_addr,
  input  [15:0] rom_rdata,
  input         rom_ack,

  // 8-bit devices
  output        via1_sel,
  output        via2_sel,
  output        scc_sel,
  output        scsi_sel,              // $50010000: register file through CS*
  output        scsi_dack,             // $50012000 and $50006000: the DMA port through DACK*
  output        asc_sel,
  output        swim_sel,
  output        exp_sel,               // $50018000: acknowledged, nothing there
  output        dev_strobe,            // one c16 clock: the device latches (write) or must present (read)
  output [12:0] dev_addr,              // byte address within the device window
  output        dev_rw,                // 1 = read
  output  [7:0] dev_wdata,
  input   [7:0] dev_rdata,
  input         scsi_drq,
  output        e_clk,                 // 783.36 kHz to the VIAs
  output        c3m_en,                // 3.672 MHz average: one pulse per SCC PCLK

  // slot $E and the PDS
  output        slot_sel,              // NUBUS*, active high here
  input         slot_dsack0_n,
  input   [7:0] slot_rdata,

  // interrupts
  input         via1_irq_n,
  input         via2_irq_n,
  input         scc_irq_n,
  input         nmi_n,
  input   [6:1] slot_irq_n,
  output        slot_irq_or_n,         // to VIA2 CA1

  // control
  input         overlay,               // VIA1 PA4
  input   [1:0] ramsiz,                // VIA2 PA7:6
  input         hsync_n                // from the video PALs: the UI6 timeout's clock
);

  assign cpu_din = 16'h0000;
  assign dtack_n = 1'b1;
  assign berr = 1'b0;
  assign vpa_n = 1'b1;
  assign ipl_n = 3'b111;
  assign ram_req = 0; assign ram_we = 0; assign ram_addr = 0; assign ram_ds = 0; assign ram_wdata = 0; assign ram_refresh = 0;
  assign rom_req = 0; assign rom_addr = 0;
  assign via1_sel = 0; assign via2_sel = 0; assign scc_sel = 0; assign scsi_sel = 0; assign scsi_dack = 0;
  assign asc_sel = 0; assign swim_sel = 0; assign exp_sel = 0; assign dev_strobe = 0; assign dev_addr = 0;
  assign dev_rw = 1; assign dev_wdata = 0; assign e_clk = 0; assign c3m_en = 0;
  assign slot_sel = 0; assign slot_irq_or_n = 1;

endmodule
