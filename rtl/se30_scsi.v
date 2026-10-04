// se30_scsi.v - the SE/30's SCSI: the 53C80 (se30_ncr53c80.v, ours), the
// bus, and the drives - the MacPlus core's scsi.v targets, byte-exact
// (SE30_PLAN.md 9.5).  Stage 1: two hard disks at IDs 0 and 1.
//
// THE BUS
//   Active high inside the core (1 = asserted).  BSY is everyone's; SEL,
//   ATN, ACK and RST are the initiator's (the targets never arbitrate or
//   reselect); the phase lines, REQ and the target's data come from the
//   target holding BSY, as the MacPlus core composes its bus.  The data
//   bus is the chip's drive OR the selected target's in a data-to-initiator
//   phase (I/O true); the targets' data input is the bus.
//
// REQ AND THE DESKEW
//   A SCSI target puts its data on the bus and waits a deskew delay before
//   asserting REQ; the 53C80 latches the byte "when REQ goes active"
//   (SP-1051 6.1.3, 11.6).  scsi.v's REQ is combinational (`!ack && ...`)
//   and rises the clock ACK falls, while its data pointer advances on a
//   registered strobe a clock later and its buffer read takes another:
//   for two or three clocks REQ is up over the previous byte, and when the
//   next byte lies in a sector not yet fetched, io_busy pulls REQ down
//   again.  So the bus REQ here rises only once the target's REQ has been
//   up for DESKEW clocks, and falls at once.  This is the seam's
//   adaptation (plan 9.8); the target file stays byte-exact.

`timescale 1ns/1ps

module se30_scsi #(
  parameter integer DESKEW = 4          // clocks the target's REQ must hold before the bus sees it
) (
  input             clk,
  input             reset_n,           // RESET*: the 53C80's /RESET (the CPU's RESET instruction included)
  input             sys_reset_n,       // the core's reset: the drives' (they never see RESET*; a SCSI RST resets them)

  // the CPU side, from GLUE
  input             cs,                // SCSI* ($50010000)
  input             dack,              // SCSIDACK* ($50012000, $50006000 once DRQ is seen)
  input             rd, wr,            // one clock per access
  input       [2:0] rs,                // A6-A4
  input       [7:0] wdata,             // D31-D24
  output      [7:0] rdata,
  output            drq,               // SCSIDRQ: GLUE and VIA2 CA2
  output            irq,               // SCSIIRQ: VIA2 CB2

  // the images: hps_io slots, one per disk
  input       [1:0] img_mounted,
  input      [31:0] img_blocks,        // hps_io's img_size in 512-byte blocks
  output     [63:0] io_lba,            // {disk 1, disk 0}
  output      [1:0] io_rd,
  output      [1:0] io_wr,
  input       [1:0] io_ack,
  input       [7:0] sd_buff_addr,
  input      [15:0] sd_buff_dout,
  output     [31:0] sd_buff_din,       // {disk 1, disk 0}
  input             sd_buff_wr,

  output     [15:0] dbg                // {target BSY[1:0], REQ raw, REQ bus, ACK, SEL, RST, ATN, MSG, C/D, I/O, chip BSY, DRQ, IRQ, hold-off, 0}
);

  // ------------------------------------------------------------ the chip
  wire [7:0] c_db;
  wire       c_db_en, c_bsy, c_sel, c_rst, c_atn, c_ack;

  wire [1:0] t_bsy, t_msg, t_cd, t_io, t_req;
  wire [7:0] t_dout [0:1];

  // the target holding the bus
  wire       t0 = t_bsy[0];
  wire       t1 = t_bsy[1] && !t_bsy[0];
  wire       t_msg_b = t0 ? t_msg[0] : t1 ? t_msg[1] : 1'b0;
  wire       t_cd_b  = t0 ? t_cd[0]  : t1 ? t_cd[1]  : 1'b0;
  wire       t_io_b  = t0 ? t_io[0]  : t1 ? t_io[1]  : 1'b0;
  wire       t_req_b = t0 ? t_req[0] : t1 ? t_req[1] : 1'b0;
  wire [7:0] t_db_b  = t0 ? t_dout[0] : t1 ? t_dout[1] : 8'h00;

  // REQ's deskew: up for DESKEW clocks before the bus sees it, down at once
  reg  [3:0] req_up;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) req_up <= 0;
    else req_up <= !t_req_b ? 4'd0 : (req_up == DESKEW[3:0]) ? req_up : req_up + 4'd1;
  wire       b_req = t_req_b && (req_up == DESKEW[3:0]);

  wire       b_bsy = c_bsy | (|t_bsy);
  wire [7:0] b_db  = (c_db_en ? c_db : 8'h00) | ((t0 || t1) && t_io_b ? t_db_b : 8'h00);

  se30_ncr53c80 chip (
    .clk(clk), .reset_n(reset_n),
    .cs(cs), .dack(dack), .rd(rd), .wr(wr), .rs(rs), .wdata(wdata), .rdata(rdata), .drq(drq), .irq(irq),
    .b_db(b_db), .b_bsy(b_bsy), .b_sel(c_sel), .b_rst(c_rst), .b_atn(c_atn), .b_ack(c_ack),
    .b_req(b_req), .b_msg(t_msg_b), .b_cd(t_cd_b), .b_io(t_io_b), .b_sel_other(1'b0),
    .o_db(c_db), .o_db_en(c_db_en), .o_bsy(c_bsy), .o_sel(c_sel), .o_rst(c_rst), .o_atn(c_atn), .o_ack(c_ack));

  // ------------------------------------------------------------ the drives
  // the targets' data_holdoff: in a data phase and unable to serve the next
  // byte (a sector not yet fetched, a flush in flight) - not wired to the
  // bus (GLUE's handshake waits on DRQ), measured only (PSCT, plan 10.4
  // item 3)
  wire [1:0] t_holdoff;

  genvar i;
  generate for (i = 0; i < 2; i = i + 1) begin : g_disk
    wire signed [15:0] snd_l_nc, snd_r_nc;
    scsi #(.ID(i[2:0]), .CDROM(0)) target (
      .clk(clk), .rst(c_rst), .sys_rst(!sys_reset_n),
      .bus_busy(|t_bsy), .cd_enable(1'b0),
      .sel(c_sel), .atn(c_atn), .ack(c_ack),
      .bsy(t_bsy[i]), .msg(t_msg[i]), .cd(t_cd[i]), .io(t_io[i]), .req(t_req[i]),
      .din(b_db), .dout(t_dout[i]),
      .img_mounted(img_mounted[i]), .img_blocks(img_blocks),
      .io_lba(io_lba[32*i +: 32]), .io_rd(io_rd[i]), .io_wr(io_wr[i]),
      // as the MacPlus core frames its disks: the ack blanked once the
      // target has left the bus; the buffer writes framed by this slot's ack
      .io_ack(io_ack[i] & t_bsy[i]),
      .sd_buff_addr(sd_buff_addr), .sd_buff_addr_hi(5'd0),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[16*i +: 16]),
      .sd_buff_wr(sd_buff_wr & io_ack[i]),
      .data_holdoff(t_holdoff[i]),
      .cd_snd_l(snd_l_nc), .cd_snd_r(snd_r_nc));
  end endgenerate

  assign dbg = {t_bsy, t_req_b, b_req, c_ack, c_sel, c_rst, c_atn, t_msg_b, t_cd_b, t_io_b, c_bsy, drq, irq, |t_holdoff, 1'b0};

endmodule
