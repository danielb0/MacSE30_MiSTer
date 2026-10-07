// se30_scsi.v - SCSI: the 53C80, the bus, two hard disks and the CD-ROM

`timescale 1ns/1ps

module se30_scsi #(
  parameter integer DESKEW = 4,
  parameter integer CDROM_EN = 1,
  parameter integer CD_SPINUP_LOG = 27
) (
  input             clk,
  input             reset_n,
  input             sys_reset_n,

  input             cs,
  input             dack,
  input             rd, wr,
  input       [2:0] rs,
  input       [7:0] wdata,
  output      [7:0] rdata,
  output            drq,
  output            irq,

  input       [2:0] img_mounted,
  input      [31:0] img_blocks,
  output     [95:0] io_lba,
  output      [2:0] io_rd,
  output      [2:0] io_wr,
  output     [17:0] io_blk_cnt,
  input       [2:0] io_ack,
  input      [12:0] sd_buff_addr,
  input      [15:0] sd_buff_dout,
  output     [47:0] sd_buff_din,
  input             sd_buff_wr,

  output     [15:0] dbg
);

  wire [7:0] c_db;
  wire       c_db_en, c_bsy, c_sel, c_rst, c_atn, c_ack;

  wire [2:0] t_bsy, t_msg, t_cd, t_io, t_req;
  wire [7:0] t_dout [0:2];

  wire       t0 = t_bsy[0];
  wire       t1 = t_bsy[1] && !t_bsy[0];
  wire       t2 = t_bsy[2] && !t_bsy[1] && !t_bsy[0];
  wire       t_any   = t0 || t1 || t2;
  wire       t_msg_b = t0 ? t_msg[0] : t1 ? t_msg[1] : t2 ? t_msg[2] : 1'b0;
  wire       t_cd_b  = t0 ? t_cd[0]  : t1 ? t_cd[1]  : t2 ? t_cd[2]  : 1'b0;
  wire       t_io_b  = t0 ? t_io[0]  : t1 ? t_io[1]  : t2 ? t_io[2]  : 1'b0;
  wire       t_req_b = t0 ? t_req[0] : t1 ? t_req[1] : t2 ? t_req[2] : 1'b0;
  wire [7:0] t_db_b  = t0 ? t_dout[0] : t1 ? t_dout[1] : t2 ? t_dout[2] : 8'h00;

  reg  [3:0] req_up;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) req_up <= 0;
    else req_up <= !t_req_b ? 4'd0 : (req_up == DESKEW[3:0]) ? req_up : req_up + 4'd1;
  wire       b_req = t_req_b && (req_up == DESKEW[3:0]);

  wire       b_bsy = c_bsy | (|t_bsy);
  wire [7:0] b_db  = (c_db_en ? c_db : 8'h00) | (t_any && t_io_b ? t_db_b : 8'h00);
  wire       b_dbp = (c_db_en || (t_any && t_io_b)) && ~^b_db;

  se30_ncr53c80 chip (
    .clk(clk), .reset_n(reset_n),
    .cs(cs), .dack(dack), .rd(rd), .wr(wr), .rs(rs), .wdata(wdata), .rdata(rdata), .drq(drq), .irq(irq),
    .b_db(b_db), .b_dbp(b_dbp), .b_bsy(b_bsy), .b_sel(c_sel), .b_rst(c_rst), .b_atn(c_atn), .b_ack(c_ack),
    .b_req(b_req), .b_msg(t_msg_b), .b_cd(t_cd_b), .b_io(t_io_b), .b_sel_other(1'b0),
    .o_db(c_db), .o_db_en(c_db_en), .o_bsy(c_bsy), .o_sel(c_sel), .o_rst(c_rst), .o_atn(c_atn), .o_ack(c_ack));

  wire [2:0] t_holdoff;

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
      .io_lba(io_lba[32*i +: 32]), .io_rd(io_rd[i]), .io_wr(io_wr[i]), .io_blk_cnt(io_blk_cnt[6*i +: 6]),
      .io_ack(io_ack[i] & t_bsy[i]),
      .sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_addr_hi(sd_buff_addr[12:8]),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[16*i +: 16]),
      .sd_buff_wr(sd_buff_wr & io_ack[i]),
      .data_holdoff(t_holdoff[i]),
      .cd_snd_l(snd_l_nc), .cd_snd_r(snd_r_nc));
  end endgenerate

  generate if (CDROM_EN != 0) begin : g_cd
    wire signed [15:0] snd_l_nc, snd_r_nc;
    scsi #(.ID(3'd3), .CDROM(1), .CD_AUDIO(0), .SPINUP_LOG(CD_SPINUP_LOG)) target (
      .clk(clk), .rst(c_rst), .sys_rst(!sys_reset_n),
      .bus_busy(|t_bsy), .cd_enable(1'b1),
      .sel(c_sel), .atn(c_atn), .ack(c_ack),
      .bsy(t_bsy[2]), .msg(t_msg[2]), .cd(t_cd[2]), .io(t_io[2]), .req(t_req[2]),
      .din(b_db), .dout(t_dout[2]),
      .img_mounted(img_mounted[2]), .img_blocks(img_blocks),
      .io_lba(io_lba[95:64]), .io_rd(io_rd[2]), .io_wr(io_wr[2]), .io_blk_cnt(io_blk_cnt[17:12]),
      .io_ack(io_ack[2] & t_bsy[2]),
      .sd_buff_addr(sd_buff_addr[7:0]), .sd_buff_addr_hi(sd_buff_addr[12:8]),
      .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din[47:32]),
      .sd_buff_wr(sd_buff_wr & io_ack[2]),
      .data_holdoff(t_holdoff[2]),
      .cd_snd_l(snd_l_nc), .cd_snd_r(snd_r_nc));
  end else begin : g_no_cd
    assign t_bsy[2] = 1'b0; assign t_msg[2] = 1'b0; assign t_cd[2] = 1'b0;
    assign t_io[2] = 1'b0;  assign t_req[2] = 1'b0; assign t_dout[2] = 8'h00;
    assign io_lba[95:64] = 32'd0; assign io_rd[2] = 1'b0; assign io_wr[2] = 1'b0;
    assign io_blk_cnt[17:12] = 6'd0; assign sd_buff_din[47:32] = 16'd0; assign t_holdoff[2] = 1'b0;
  end endgenerate

  assign dbg = {t_bsy[1:0], t_req_b, b_req, c_ack, c_sel, c_rst, c_atn, t_msg_b, t_cd_b, t_io_b, c_bsy, drq, irq, |t_holdoff, 1'b0};

endmodule
