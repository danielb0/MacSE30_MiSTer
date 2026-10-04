// scsi_idle.v - for sim/machine only: an idle stand-in for the MacPlus
// core's `scsi` target (rtl/scsi.v, kept byte-exact, SE30_PLAN.md 9.8).
// ModelSim's vlog rejects rtl/scsi.v's forward references (vlog-2730,
// `data_cnt` used before its declaration) in Verilog and SystemVerilog
// mode alike; Quartus and Icarus accept them.  The machine bench mounts no
// disk, so its targets never answer selection - which is what this does.
// The real target is benched in sim/scsi_seam (Icarus) and elaborated by
// Quartus.

`timescale 1ns/1ps

module scsi #(
  parameter [2:0] ID = 0,
  parameter CDROM = 0
) (
  input         clk,
  input         rst,
  input         sys_rst,
  input         bus_busy,
  input         cd_enable,
  input         sel,
  input         atn,
  output        bsy,
  output        msg,
  output        cd,
  output        io,
  output        req,
  input         ack,
  input   [7:0] din,
  output  [7:0] dout,
  input         img_mounted,
  input  [31:0] img_blocks,
  output [31:0] io_lba,
  output        io_rd,
  output reg    io_wr,
  output  [5:0] io_blk_cnt,
  input         io_ack,
  input   [7:0] sd_buff_addr,
  input   [4:0] sd_buff_addr_hi,
  input  [15:0] sd_buff_dout,
  output [15:0] sd_buff_din,
  input         sd_buff_wr,
  output        data_holdoff,
  output signed [15:0] cd_snd_l,
  output signed [15:0] cd_snd_r
);
  assign {bsy, msg, cd, io, req} = 5'b00000;
  assign dout = 8'h00;
  assign io_lba = 32'd0;
  assign io_rd = 1'b0;
  initial io_wr = 1'b0;
  assign io_blk_cnt = 6'd0;
  assign sd_buff_din = 16'd0;
  assign data_holdoff = 1'b0;
  assign cd_snd_l = 16'sd0;
  assign cd_snd_r = 16'sd0;
endmodule
