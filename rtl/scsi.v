// scsi.v - SCSI target: hard disks and the AppleCD SC (from the MiSTer MacPlus core)

module scsi
(
	input      clk,

	input 	  rst,
	input 	  sys_rst,
	input 	  bus_busy,
	input 	  cd_enable,
	input 	  sel,
	input 	  atn,
	output 	  bsy,

	output 	  msg,
	output 	  cd,
	output 	  io,

	output 	  req,
	input 	  ack,

	input   [7:0] din,
	output  [7:0] dout,

	input         img_mounted,
	input  [31:0] img_blocks,
	output [31:0] io_lba,
	output        io_rd,
	output reg 	  io_wr,
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

parameter [2:0] ID = 0;

parameter CDROM = 0;

parameter CD_AUDIO = 0;

parameter  RING_LOG    = 5;
localparam RING_BLOCKS = 1 << RING_LOG;
localparam [5:0] RING_BLOCKS6 = RING_BLOCKS;
localparam BUF_AW      = 8 + RING_LOG;

wire any_rst = rst | sys_rst;

localparam PHASE_IDLE        = 3'd0;
localparam PHASE_CMD_IN      = 3'd1;
localparam PHASE_DATA_OUT    = 3'd2;
localparam PHASE_DATA_IN     = 3'd3;
localparam PHASE_STATUS_OUT  = 3'd4;
localparam PHASE_MESSAGE_OUT = 3'd5;
reg [2:0]  phase;

reg [22:0] rd_hps_blk;
reg [22:0] wr_fill;
reg [22:0] wr_done;
reg  [5:0] wr_n;
reg        wr_busy;
wire [22:0] wr_pend = wr_fill - wr_done;

wire [22:0] rd_cur_blk = data_cnt[31:9];
wire [RING_LOG-1:0] rd_hps_slot = rd_hps_blk[RING_LOG-1:0];
wire [12:0] hps_word = {sd_buff_addr_hi, sd_buff_addr};
wire [BUF_AW-1:0] hps_addr_wr = {wr_done[RING_LOG-1:0], 8'd0} + hps_word[BUF_AW-1:0];
wire [BUF_AW-1:0] hps_addr = cmd_write ? hps_addr_wr : {rd_hps_slot, sd_buff_addr};
wire [BUF_AW-1:0] mac_addr = data_cnt[BUF_AW:1];

wire [7:0] buffer0_dout;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer0
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(sd_buff_dout[7:0]),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(sd_buff_din[7:0]),

	.address_b(mac_addr),
	.data_b(din),
	.wren_b(buffer0_wr),
	.q_b(buffer0_dout)
);

wire [7:0] buffer1_dout;
scsi_dpram #(.ADDRWIDTH(BUF_AW)) buffer1
(
	.clock(clk),

	.address_a(hps_addr),
	.data_a(sd_buff_dout[15:8]),
	.wren_a(sd_buff_wr && !ca_io_active),
	.q_a(sd_buff_din[15:8]),

	.address_b(mac_addr),
	.data_b(din),
	.wren_b(buffer1_wr),
	.q_b(buffer1_dout)
);

reg old_io_ack;
always @(posedge clk) begin
	old_io_ack <= io_ack;

	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT)
		rd_hps_blk <= 23'd0;
	else if (old_io_ack & ~io_ack & cmd_read & ~ca_io_active)
		rd_hps_blk <= rd_hps_blk + 23'd1;

	if (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN &&
	    phase != PHASE_STATUS_OUT && phase != PHASE_MESSAGE_OUT) begin
		wr_fill <= 23'd0;
		wr_done <= 23'd0;
	end else begin
		if (phase == PHASE_DATA_IN && cmd_write) wr_fill <= data_cnt[31:9];
		if (old_io_ack & ~io_ack & wr_busy & ~ca_io_active) wr_done <= wr_done + {17'd0, wr_n};
	end
end

reg [7:0]  status;
`define STATUS_OK 8'h00
`define STATUS_CHECK_CONDITION 8'h02

`define MSG_CMD_COMPLETE 8'h00

assign msg = (phase == PHASE_MESSAGE_OUT);
assign cd = (phase == PHASE_CMD_IN) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);
assign io = (phase == PHASE_DATA_OUT) || (phase == PHASE_STATUS_OUT) || (phase == PHASE_MESSAGE_OUT);

wire   rd_cur_unfilled = (rd_cur_blk >= rd_hps_blk);
wire   wr_ring_full    = ((data_cnt[31:9] - wr_done) >= RING_BLOCKS);
wire   wr_unsent       = cmd_write && !cmd_aborted && (wr_pend != 23'd0);
wire   io_busy = (phase == PHASE_DATA_OUT && cmd_read && mounted && rd_cur_unfilled) ||
                 (phase == PHASE_DATA_IN  && cmd_write && wr_ring_full && !data_done) ||
                 (phase != PHASE_DATA_OUT && phase != PHASE_DATA_IN && (io_rd_d | io_wr | wr_unsent | (io_ack & ~ca_io_active)));

wire   data_done = data_complete || (data_len == 32'd0);
wire   data_phase_complete = ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN)) && data_done;

assign req = (phase != PHASE_IDLE) && !ack && !io_busy && !data_phase_complete;

assign data_holdoff = !any_rst && ((phase == PHASE_DATA_OUT) || (phase == PHASE_DATA_IN)) && io_busy;

assign bsy = (phase != PHASE_IDLE);

assign dout = (phase == PHASE_STATUS_OUT)?status:
	 (phase == PHASE_MESSAGE_OUT)?`MSG_CMD_COMPLETE:
	 (phase == PHASE_DATA_OUT)?cmd_dout:
	 8'h00;

wire [7:0] cmd_dout =
		cmd_read?(data_cnt[0] ? buffer1_dout : buffer0_dout):
		cmd_inquiry?inquiry_dout:
		cmd_read_capacity?read_capacity_dout:
		cmd_mode_sense?mode_sense_dout:
		cmd_request_sense?request_sense_dout:
		cmd_cd_toc?cd_toc_dout:
		(cmd_cd_t43f2 || cmd_cd_t43f1)?cd_toc2_dout:
		cmd_cd_toc43?cd_toc43_dout:
		cmd_cd_subq?cd_subq_dout:
		cmd_cd_subq43?cd_subq43_dout:
		cmd_cd_astat?cd_astat_dout:
		cmd_cd_hdr?cd_hdr_byte(data_cnt, cd_hdr_addr_r):
		8'h00;

wire [7:0] request_sense_dout =
		(data_cnt == 32'd0 )?8'h70:
		(data_cnt == 32'd2 )?{4'd0, sense_key}:
		(data_cnt == 32'd7 )?((CDROM != 0) ? 8'h08 : 8'h0a):
		(data_cnt == 32'd12)?sense_asc:
		8'h00;

function [7:0] cd_inquiry_byte;
	input [31:0] cnt;
	input        lun_bad;
	begin
		cd_inquiry_byte =
			(cnt == 32'd0 )?(lun_bad ? 8'h7f : 8'h05):
			(cnt == 32'd1 )?8'h80:
			(cnt == 32'd2 )?8'h01:
			(cnt == 32'd3 )?8'h01:
			(cnt == 32'd4 )?8'h31:
			(cnt == 32'd8 )?"S":(cnt == 32'd9 )?"O":
			(cnt == 32'd10)?"N":(cnt == 32'd11)?"Y":
			((cnt >= 32'd12) && (cnt <= 32'd15))?" ":
			(cnt == 32'd16)?"C":(cnt == 32'd17)?"D":
			(cnt == 32'd18)?"-":(cnt == 32'd19)?"R":
			(cnt == 32'd20)?"O":(cnt == 32'd21)?"M":
			(cnt == 32'd22)?" ":(cnt == 32'd23)?"C":
			(cnt == 32'd24)?"D":(cnt == 32'd25)?"U":
			(cnt == 32'd26)?"-":(cnt == 32'd27)?"8":
			(cnt == 32'd28)?"0":(cnt == 32'd29)?"0":
			(cnt == 32'd30)?"1":(cnt == 32'd31)?" ":
			(cnt == 32'd32)?"3":(cnt == 32'd33)?".":
			(cnt == 32'd34)?"2":(cnt == 32'd35)?"i":
			(cnt == 32'd39)?8'hd0:(cnt == 32'd40)?8'h90:
			(cnt == 32'd41)?8'h27:(cnt == 32'd42)?8'h3e:
			(cnt == 32'd43)?8'h01:(cnt == 32'd44)?8'h04:
			(cnt == 32'd45)?8'h91:(cnt == 32'd47)?8'h18:
			(cnt == 32'd48)?8'h06:(cnt == 32'd49)?8'hf0:
			(cnt == 32'd50)?8'hfc:(cnt == 32'd53)?8'hff:
			8'h00;
	end
endfunction

wire [7:0] inquiry_dout = (CDROM != 0) ? cd_inquiry_byte(data_cnt, cd_lun_bad_r) : hd_inquiry_dout;
wire [7:0] hd_inquiry_dout =
		(data_cnt == 32'd4 )?8'd32:

		(data_cnt == 32'd8 )?" ":(data_cnt == 32'd9 )?"S":
		(data_cnt == 32'd10)?"E":(data_cnt == 32'd11)?"A":
		(data_cnt == 32'd12)?"G":(data_cnt == 32'd13)?"A":
		(data_cnt == 32'd14)?"T":(data_cnt == 32'd15)?"E":
		(data_cnt == 32'd16)?" ":(data_cnt == 32'd17)?" ":
		(data_cnt == 32'd18)?" ":(data_cnt == 32'd19)?" ":
		(data_cnt == 32'd20)?" ":(data_cnt == 32'd21)?" ":
		(data_cnt == 32'd22)?" ":(data_cnt == 32'd23)?" ":
		(data_cnt == 32'd24)?" ":(data_cnt == 32'd25)?" ":

		(data_cnt == 32'd26)?"S":(data_cnt == 32'd27)?"T":
		(data_cnt == 32'd28)?"2":(data_cnt == 32'd29)?"2":
		(data_cnt == 32'd30)?"5":(data_cnt == 32'd31)?"N" + {5'd0, ID}:
		8'h00;

reg [31:0] capacity = 32'd0;
reg        mounted = 0;
always @(posedge clk) begin
	if (img_mounted) begin
		if (|img_blocks) begin
			capacity <= (CDROM != 0) ? ({2'b00, img_blocks[31:2]} - 1'd1)
			                         : (img_blocks - 1'd1);
			if (!mounted) $display("Image mounted on target %d, size: %d", ID, img_blocks);
			mounted <= 1;
		end else
			mounted <= 0;
	end else if ((CDROM != 0) && cd_eject_pulse)
		mounted <= 0;
end

reg         cd_bs512 = 1'b0;
wire [31:0] capacity_cur = ((CDROM != 0) && cd_bs512) ? {capacity[29:0], 2'b11} : capacity;

wire [7:0] read_capacity_dout =
		(data_cnt == 32'd0 )?capacity_cur[31:24]:
		(data_cnt == 32'd1 )?capacity_cur[23:16]:
		(data_cnt == 32'd2 )?capacity_cur[15:8]:
		(data_cnt == 32'd3 )?capacity_cur[7:0]:
		(data_cnt == 32'd6 )?(((CDROM != 0) && !cd_bs512)?8'h08:8'd2):
		8'h00;

function [7:0] cd_page_byte;
	input [5:0] pg;
	input [4:0] off;
	input       chg;
	begin
		case (pg)
		6'h00: cd_page_byte = (off == 5'd1) ? 8'h02 : (off == 5'd2) ? 8'h10 : 8'h00;
		6'h01: cd_page_byte = (off == 5'd0) ? 8'h01 : (off == 5'd1) ? 8'h06 :
		                      (chg && (off == 5'd2 || off == 5'd3)) ? 8'hff : 8'h00;
		6'h02: cd_page_byte = (off == 5'd0) ? 8'h02 : (off == 5'd1) ? 8'h0a :
		                      (off == 5'd2) ? (chg ? 8'hff : 8'h08) :
		                      (chg && (off >= 5'd4) && (off <= 5'd9)) ? 8'hff : 8'h00;
		6'h20: cd_page_byte = (off == 5'd0) ? 8'h20 : (off == 5'd1) ? 8'h02 :
		                      (off == 5'd3) ? (chg ? 8'h0f : 8'h05) : 8'h00;
		6'h30: cd_page_byte = (off == 5'd0) ? 8'h30 : (off == 5'd1) ? 8'h16 :
		                      chg ? 8'h00 :
		                      (off == 5'd2 )?"A":(off == 5'd3 )?"P":(off == 5'd4 )?"P":
		                      (off == 5'd5 )?"L":(off == 5'd6 )?"E":(off == 5'd7 )?" ":
		                      (off == 5'd8 )?"C":(off == 5'd9 )?"O":(off == 5'd10)?"M":
		                      (off == 5'd11)?"P":(off == 5'd12)?"U":(off == 5'd13)?"T":
		                      (off == 5'd14)?"E":(off == 5'd15)?"R":(off == 5'd16)?",":
		                      (off == 5'd17)?" ":(off == 5'd18)?"I":(off == 5'd19)?"N":
		                      (off == 5'd20)?"C":" ";
		default: cd_page_byte = 8'h00;
		endcase
	end
endfunction

function [6:0] cd_ms_total;
	input [5:0] pg;
	cd_ms_total = (pg == 6'h00) ? 7'd16 : (pg == 6'h01) ? 7'd20 : (pg == 6'h02) ? 7'd24 :
	              (pg == 6'h20) ? 7'd16 : (pg == 6'h30) ? 7'd36 : (pg == 6'h3f) ? 7'd64 : 7'd0;
endfunction

function [7:0] cd_mode_sense_byte;
	input [31:0] cnt;
	input [5:0]  page;
	input [1:0]  pc;
	input        bs512;
	input [7:0]  sent;
	input        bd;
	reg   [5:0]  c;
	begin
		c = cnt[5:0];
		cd_mode_sense_byte =
			(cnt >= 32'd64) ? 8'h00 :
			(c == 6'd0 ) ? sent - 8'd1 :
			(c == 6'd3 ) ? (bd ? 8'd8 : 8'd0) :
			(c == 6'd9 ) ? ((pc == 2'd1) ? 8'hff : 8'h00) :
			(c == 6'd10) ? ((pc == 2'd1) ? 8'hff : ((pc == 2'd0) && bs512) ? 8'h02 : 8'h08) :
			(c == 6'd11) ? ((pc == 2'd1) ? 8'hff : 8'h00) :
			(c <  6'd12) ? 8'h00 :
			(page != 6'h3f) ? cd_page_byte(page, c - 6'd12, pc == 2'd1) :
			(c < 6'd16) ? cd_page_byte(6'h00, c - 6'd12, pc == 2'd1) :
			(c < 6'd24) ? cd_page_byte(6'h01, c - 6'd16, pc == 2'd1) :
			(c < 6'd36) ? cd_page_byte(6'h02, c - 6'd24, pc == 2'd1) :
			(c < 6'd40) ? cd_page_byte(6'h20, c - 6'd36, pc == 2'd1) :
			              cd_page_byte(6'h30, c - 6'd40, pc == 2'd1);
	end
endfunction

wire [31:0] cd_ms_total32 = {25'd0, cd_ms_total(cd_page_r)};
wire [31:0] cd_ms_len = (alloc_len < cd_ms_total32) ? alloc_len : cd_ms_total32;
wire [7:0] mode_sense_dout =
		(CDROM == 0) ? hd_mode_sense_dout :
		cd_mode_sense_byte(data_cnt, cd_page_r, cd_pc_r, cd_bs512, cd_ms_len[7:0], alloc_len >= 32'd5);
wire [7:0] hd_mode_sense_dout =
		(data_cnt == 32'd3 )?8'd8:
		(data_cnt == 32'd5 )?capacity[23:16]:
		(data_cnt == 32'd6 )?capacity[15:8]:
		(data_cnt == 32'd7 )?capacity[7:0]:
		(data_cnt == 32'd10 )?8'd2:
		8'h00;

reg [1:0]  c1_op_r        = 2'b00;
reg [7:0]  c1_trk_r       = 8'd0;
reg [7:0]  t43_start_r    = 8'd0;
reg [7:0]  t43_fmt_r      = 8'd0;
reg [5:0]  cd_page_r      = 6'd0;
reg [1:0]  cd_pc_r        = 2'd0;
reg        cd_lun_bad_r   = 1'b0;
reg        cd_astat_vol_r = 1'b0;
reg [31:0] cd_alloc10_r   = 32'd0;
reg [31:0] cd_hdr_addr_r  = 32'd0;

localparam [7:0] CD_AST_STOPPED = 8'h13;

function [7:0] cd_bin2bcd;
	input [7:0] v;
	reg [3:0] tens;
	reg [3:0] units;
	begin
		tens  = (v >= 8'd90) ? 4'd9 : (v >= 8'd80) ? 4'd8 :
		        (v >= 8'd70) ? 4'd7 : (v >= 8'd60) ? 4'd6 :
		        (v >= 8'd50) ? 4'd5 : (v >= 8'd40) ? 4'd4 :
		        (v >= 8'd30) ? 4'd3 : (v >= 8'd20) ? 4'd2 :
		        (v >= 8'd10) ? 4'd1 : 4'd0;
		units = v - ({4'd0, tens} * 8'd10);
		cd_bin2bcd = {tens, units};
	end
endfunction

function [7:0] cd_subq_byte;
	input [31:0] cnt;
	input [7:0]  trk;
	input [7:0]  rm, rs, rf;
	input [7:0]  am, as_, af;
	begin
		cd_subq_byte = (cnt == 32'd1) ? cd_bin2bcd(trk) :
		               (cnt == 32'd2) ? 8'h01 :
		               (cnt == 32'd3) ? cd_bin2bcd(rm) :
		               (cnt == 32'd4) ? cd_bin2bcd(rs) :
		               (cnt == 32'd5) ? cd_bin2bcd(rf) :
		               (cnt == 32'd6) ? cd_bin2bcd(am) :
		               (cnt == 32'd7) ? cd_bin2bcd(as_) :
		               (cnt == 32'd8) ? cd_bin2bcd(af) : 8'h00;
	end
endfunction

function [7:0] cd_subq43_byte;
	input [31:0] cnt;
	input [7:0]  ast;
	input [7:0]  ctrl, trk;
	input [7:0]  am, as_, af;
	input [7:0]  rm, rs, rf;
	begin
		cd_subq43_byte =
			(cnt == 32'd1 )?ast:
			(cnt == 32'd3 )?8'd12:
			(cnt == 32'd4 )?8'h01:
			(cnt == 32'd5 )?ctrl:
			(cnt == 32'd6 )?trk:
			(cnt == 32'd7 )?8'h01:
			(cnt == 32'd9 )?am:
			(cnt == 32'd10)?as_:
			(cnt == 32'd11)?af:
			(cnt == 32'd13)?rm:
			(cnt == 32'd14)?rs:
			(cnt == 32'd15)?rf:
			8'h00;
	end
endfunction

function [7:0] cd_astat_byte;
	input [31:0] cnt;
	input        vol_form;
	input [7:0]  ast_raw;
	input [7:0]  ctrl;
	input [7:0]  am, as_, af;
	begin
		if (vol_form)
			cd_astat_byte = ((cnt == 32'd4) || (cnt == 32'd5)) ? 8'hff : 8'h00;
		else
			cd_astat_byte = (cnt == 32'd0) ? ast_raw :
			                (cnt == 32'd2) ? ctrl :
			                (cnt == 32'd3) ? cd_bin2bcd(am) :
			                (cnt == 32'd4) ? cd_bin2bcd(as_) :
			                (cnt == 32'd5) ? cd_bin2bcd(af) : 8'h00;
	end
endfunction

function [7:0] cd_hdr_byte;
	input [31:0] cnt;
	input [31:0] addr;
	begin
		cd_hdr_byte = (cnt == 32'd0) ? 8'h01 :
		              (cnt == 32'd4) ? addr[31:24] :
		              (cnt == 32'd5) ? addr[23:16] :
		              (cnt == 32'd6) ? addr[15:8]  :
		              (cnt == 32'd7) ? addr[7:0]   : 8'h00;
	end
endfunction

reg [3:0]  cmd_cnt;
reg [7:0]  cmd [9:0];

assign io_lba = ca_io_active ? ca_io_lba : lba;

wire [22:0] rd_blk_total  = {7'd0, tlen};
wire        rd_blk_remain = (rd_hps_blk < rd_blk_total);
wire        rd_ring_space = ((rd_hps_blk - rd_cur_blk) < RING_BLOCKS);
wire req_rd = (phase == PHASE_DATA_OUT) && cmd_read && (data_len != 32'd0) &&
              !data_complete && rd_blk_remain && rd_ring_space && !cmd_aborted;

wire req_wr = cmd_write && (data_len != 32'd0) && !cmd_aborted &&
              ((phase == PHASE_DATA_IN) || (phase == PHASE_STATUS_OUT)) && (wr_pend != 23'd0);

assign io_blk_cnt = wr_busy ? (wr_n - 6'd1) : 6'd0;

reg io_rd_d;
assign io_rd = io_rd_d | ca_io_rd_w;

always @(posedge clk) begin
	reg rd_busy;

	if(any_rst || wdog_abort) begin
		io_rd_d    <= 1'b0;
		io_wr      <= 1'b0;
		rd_busy    <= 1'b0;
		wr_busy    <= 1'b0;
		wr_n       <= 6'd1;
	end else begin

		if(io_ack) io_rd_d <= 1'b0;
		else if(req_rd && !io_rd && !rd_busy) begin io_rd_d <= 1'b1; rd_busy <= 1'b1; end
		if(old_io_ack & ~io_ack) rd_busy <= 1'b0;

		if(io_ack) io_wr <= 1'b0;
		else if(req_wr && !io_wr && !io_rd && !wr_busy) begin
			io_wr   <= 1'b1;
			wr_busy <= 1'b1;
			wr_n    <= (wr_pend >= RING_BLOCKS) ? RING_BLOCKS6 : wr_pend[5:0];
		end
		if(old_io_ack & ~io_ack) wr_busy <= 1'b0;
	end
end

reg  stb_ack;
reg  stb_adv;
always @(posedge clk) begin
	reg old_ack;

	old_ack <= ack;
	stb_ack <= (~old_ack & ack);
	stb_adv <= (old_ack & ~ack);
end

reg buffer0_wr, buffer1_wr;

always @(posedge clk) begin
	buffer0_wr <= 0;
	buffer1_wr <= 0;
	if(stb_ack) begin
		if(phase == PHASE_CMD_IN)  cmd[cmd_cnt] <= din;
		if(phase == PHASE_DATA_IN) begin
			buffer0_wr <= ~data_cnt[0];
			buffer1_wr <=  data_cnt[0];
		end
	end
end

always @(posedge clk) begin
	if(phase == PHASE_IDLE) cmd_cnt <= 4'd0;
	else if(stb_adv && (phase == PHASE_CMD_IN) && (cmd_cnt != 15)) cmd_cnt <= cmd_cnt + 4'd1;
end

reg [31:0] data_cnt;
reg        data_complete;

wire [31:0] alloc_len = (tlen == 16'd256) ? 32'd0 : {16'd0, tlen};
wire [31:0] sense_len = (tlen == 16'd256) ? 32'd4 : {16'd0, tlen};
localparam [31:0] INQUIRY_LEN = (CDROM != 0) ? 32'd54 : 32'd36;
localparam [31:0] SENSE_LEN = (CDROM != 0) ? 32'd16 : 32'd18;

wire [31:0] data_len =
		 cmd_read_capacity?32'd8:
		 cmd_read?{ 7'd0, tlen, 9'd0 }:
		 cmd_write?{ 7'd0, tlen, 9'd0 }:
		 cmd_inquiry?((alloc_len < INQUIRY_LEN) ? alloc_len : INQUIRY_LEN):
		 cmd_request_sense?((sense_len < SENSE_LEN) ? sense_len : SENSE_LEN):
		 ((CDROM != 0) && (CD_AUDIO == 0) && cmd_cd_toc)?((cd_alloc10_r < 32'd4) ? cd_alloc10_r : 32'd4):
		 ((CDROM != 0) && cmd_mode_sense)?cd_ms_len:
		 cmd_cd_toc?cd_alloc10_r:
		 cmd_cd_toc43?cd_alloc10_r:
		 cmd_cd_subq43?cd_alloc10_r:
		 cmd_cd_subq?cd_alloc10_r:
		 cmd_cd_astat?cd_alloc10_r:
		 cmd_cd_hdr?cd_alloc10_r:
		 cmd_cd_actl?cd_alloc10_r:
		 ((CDROM != 0) && cmd_mode_select)?alloc_len:
		 { 16'd0, tlen };

always @(posedge clk) begin
	if((phase != PHASE_DATA_OUT) && (phase != PHASE_DATA_IN) && (phase != PHASE_STATUS_OUT) && (phase != PHASE_MESSAGE_OUT)) begin
		data_cnt <= 0;
		data_complete <= 0;
	end else begin
		if(stb_adv)begin
			if(!data_complete) data_cnt <= data_cnt + 1'd1;
			data_complete <= (data_len - 1'd1) == data_cnt;
		end
	end
end

reg status_sent;
always @(posedge clk) begin
	if(phase != PHASE_STATUS_OUT) status_sent <= 0;
	else if(stb_adv) status_sent <= 1;
end

reg message_sent;
always @(posedge clk) begin
	if(phase != PHASE_MESSAGE_OUT) message_sent <= 0;
	else if(stb_adv) message_sent <= 1;
end

reg status_done;
always @(posedge clk) begin
	if(phase == PHASE_IDLE) status_done <= 0;
	else if((phase == PHASE_STATUS_OUT) && stb_adv) status_done <= 1;
end

reg cmd_aborted;
always @(posedge clk) begin
	if(any_rst || (phase == PHASE_IDLE)) cmd_aborted <= 0;
	else if(wdog_abort) cmd_aborted <= 1;
end

wire [7:0] op_code = cmd[0];
wire [2:0] cmd_group = op_code[7:5];

wire       cmd_cpl = cmd6_cpl || cmd10_cpl || cmd12_cpl || cmd1_cpl;
wire       cmd_cd_badgrp = (CDROM != 0) && !((op_code[7:6] == 2'b00) || (op_code[7:4] == 4'hc));
wire       cmd1_cpl = cmd_cd_badgrp && (cmd_cnt == 1);
wire       cmd6_cpl = (cmd_group == 3'b000) && (cmd_cnt == 6);
wire       cmd_apple_cd_op = (CDROM != 0) && (op_code[7:4] == 4'hc);
wire       cmd10_cpl = (((cmd_group == 3'b010) || (cmd_group == 3'b001)) && (cmd_cnt == 10) && !cmd_cd_badgrp)
                       || (cmd_apple_cd_op && (cmd_cnt == 10));
wire       cmd12_cpl = (cmd_group == 3'b101) && (cmd_cnt == 12) && !cmd_cd_badgrp;

wire       cmd_read = cmd_read6 || cmd_read10;
wire       cmd_read6 = (op_code == 8'h08);
wire       cmd_read10 = (op_code == 8'h28);
wire       cmd_write = cmd_write6 || cmd_write10;
wire       cmd_write6 = (op_code == 8'h0a);
wire       cmd_write10 = (op_code == 8'h2a);
wire       cmd_inquiry = (op_code == 8'h12);
wire       cmd_format = (op_code == 8'h04);
wire       cmd_mode_select = (op_code == 8'h15);
wire       cmd_mode_sense = (op_code == 8'h1a);
wire       cmd_test_unit_ready = (op_code == 8'h00);
wire       cmd_read_capacity = (op_code == 8'h25);
wire       cmd_read_buffer = (op_code == 8'h3b);
wire       cmd_write_buffer = (op_code == 8'h3c);
wire       cmd_verify6 = (op_code == 8'h13);
wire       cmd_verify10 = (op_code == 8'h2f);
wire       cmd_request_sense = (op_code == 8'h03);

wire       cmd_cd_eject     = (CDROM != 0) && (op_code == 8'hc0);
wire       cmd_cd_toc       = (CDROM != 0) && (op_code == 8'hc1);
wire       cmd_cd_subq      = (CDROM != 0) && (op_code == 8'hc2);
wire       cmd_cd_astat     = (CDROM != 0) && (op_code == 8'hcc);
wire       cmd_cd_prevent   = (CDROM != 0) && (op_code == 8'h1e);
wire       cmd_cd_startstop = (CDROM != 0) && (op_code == 8'h1b);
wire       cmd_cd_reserve   = (CDROM != 0) && ((op_code == 8'h16) || (op_code == 8'h17));
wire       cmd_cd_actl      = 1'b0;
wire       cmd_cd_toc43     = 1'b0;
wire       cmd_cd_t43f2     = 1'b0;
wire       cmd_cd_t43f1     = 1'b0;
wire       cmd_cd_subq43    = 1'b0;
wire       cmd_cd_hdr       = 1'b0;
wire       cmd_cd_audio_nop = (CDROM != 0) && ((op_code == 8'hc8) || (op_code == 8'hc9) ||
                                               (op_code == 8'hca) || (op_code == 8'hcb) ||
                                               (op_code == 8'hcd) ||
                                               (op_code == 8'h01) ||
                                               (op_code == 8'h0b) || (op_code == 8'h2b) ||
                                               (op_code == 8'h2f));
wire       cmd_cd_eject_any = cmd_cd_eject ||
                              (cmd_cd_startstop && cmd[4][1] && !cmd[4][0]);

wire  cmd_ok_hd = cmd_read || cmd_write || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_format || cmd_mode_sense ||
		  cmd_read_buffer || cmd_write_buffer || cmd_verify6 || cmd_verify10 ||
		  cmd_request_sense;

wire  cmd_ok_cd = !cmd_cd_badgrp && (cmd_read || cmd_inquiry || cmd_test_unit_ready ||
		  cmd_read_capacity || cmd_mode_select || cmd_mode_sense ||
		  cmd_request_sense || cmd_cd_eject || cmd_cd_toc || cmd_cd_subq ||
		  cmd_cd_astat || cmd_cd_audio_nop || cmd_cd_reserve ||
		  cmd_cd_prevent || cmd_cd_startstop);
wire  cmd_ok = (CDROM != 0) ? cmd_ok_cd : cmd_ok_hd;

wire [3:0] cd_nomedia_key = 4'h2;
wire [7:0] cd_nomedia_asc = 8'hb7;

wire  cd_needs_media = cmd_test_unit_ready || cmd_read || cmd_read_capacity ||
		  cmd_cd_toc || cmd_cd_subq || cmd_cd_astat || cmd_cd_audio_nop ||
		  (cmd_cd_startstop && !cmd_cd_eject_any);
wire  cd_ua_cmds = cd_needs_media || cmd_mode_sense || cmd_mode_select || cmd_cd_prevent;

wire  cd_toc_ok;
wire  cd_no_media = (CDROM != 0) && (!mounted || !cd_toc_ok) && cd_needs_media;

wire  cd_lun_rej = (CDROM != 0) && (cmd[1][7:5] != 3'd0) && !cmd_inquiry && !cmd_request_sense;

reg   cd_unit_attn = 1'b0;
wire  cd_unit_attn_rej = (CDROM != 0) && cd_unit_attn && cd_ua_cmds;
wire  cd_sense_empty = (sense_key == 4'd0) && (sense_asc == 8'd0);
wire  cd_rs_report = (CDROM != 0) && cmd_request_sense && cd_sense_empty;
always @(posedge clk) begin
	if (any_rst)                                         cd_unit_attn <= (CDROM != 0);
	else if (new_cmd && ((cd_unit_attn_rej && !cd_lun_rej) || cd_rs_report)) cd_unit_attn <= 1'b0;
end

reg  [SPINUP_LOG:0] cd_spinup = 0;
wire cd_insert      = (CDROM != 0) && img_mounted && (|img_blocks);
wire cd_spinning_up = (CDROM != 0) && !cd_spinup[SPINUP_LOG];
wire cd_spinup_rej  = cd_spinning_up && cd_needs_media;
always @(posedge clk) begin
	if (any_rst || cd_insert)        cd_spinup <= 0;
	else if (!cd_spinup[SPINUP_LOG]) cd_spinup <= cd_spinup + 1'd1;
end

reg   cd_media_attn = 1'b0;
wire  cd_media_attn_rej = (CDROM != 0) && cd_media_attn && !cd_spinning_up && cd_ua_cmds;
wire  cd_rs_media = cd_rs_report && !cd_unit_attn && !cd_spinning_up && cd_media_attn;
always @(posedge clk) begin
	if (CDROM == 0)                                       cd_media_attn <= 1'b0;
	else if (img_mounted || cd_eject_pulse)               cd_media_attn <= 1'b1;
	else if (new_cmd && ((cd_media_attn_rej && !cd_lun_rej && !cd_unit_attn_rej) || cd_rs_media))
		cd_media_attn <= 1'b0;
end

wire [3:0] cd_cur_key = cd_unit_attn ? 4'h6 : cd_spinning_up ? 4'h2 : cd_media_attn ? 4'h6 :
                        !mounted ? cd_nomedia_key : 4'h0;
wire [7:0] cd_cur_asc = cd_unit_attn ? 8'h29 : cd_spinning_up ? 8'h04 : cd_media_attn ? 8'h28 :
                        !mounted ? cd_nomedia_asc : 8'h00;

wire  cd_tur_bad   = cmd_test_unit_ready && ((cmd[1][4:0] != 5'd0) || (cmd[2] != 8'd0) ||
                     (cmd[3] != 8'd0) || (cmd[4] != 8'd0) || (cmd[5][7:2] != 6'd0));
wire  cd_toc_bad   = cmd_cd_toc && ((cmd[1][4:0] != 5'd0) || (cmd[2] != 8'd0) || (cmd[3] != 8'd0) ||
                     (cmd[4] != 8'd0) || (cmd[6] != 8'd0) ||
                     ((cmd[9][7:6] == 2'b00 || cmd[9][7:6] == 2'b01) && (cmd[5] != 8'h00)) ||
                     ((cmd[9][7:6] == 2'b10) && (cmd[5] != 8'h01)) ||
                     (cmd[9][7:6] == 2'b11));
wire  cd_eject_bad = cmd_cd_eject && ((cmd[1][4:1] != 4'd0) || (cmd[2] != 8'd0) || (cmd[3] != 8'd0) ||
                     (cmd[4] != 8'd0) || (cmd[5] != 8'd0) || (cmd[6] != 8'd0) || (cmd[7] != 8'd0) ||
                     (cmd[8] != 8'd0) || (cmd[9] != 8'd0));
wire  cd_ms_bad    = cmd_mode_sense && (cd_ms_total(cmd[2][5:0]) == 7'd0);
wire  cd_ss_bad    = cmd_cd_startstop && (cmd[4][1:0] == 2'b11);
wire  cd_field_rej = (CDROM != 0) && (cd_tur_bad || cd_toc_bad || cd_eject_bad || cd_ms_bad || cd_ss_bad);

wire  cd_hdr_msf_rej = cmd_cd_hdr && cmd[1][1];

wire [31:0] cdb_lba  = cmd6_cpl ? {11'd0, lba6} : lba10;
wire [16:0] cdb_blks = cmd6_cpl ? {8'd0, tlen6} : {1'b0, tlen10};
wire [32:0] cdb_end  = {1'b0, cdb_lba} + {16'd0, cdb_blks};
wire  lba_out_of_range = (cmd_read || cmd_write) && mounted && (cdb_blks != 0) &&
                         (cdb_end > ({1'b0, capacity_cur} + 33'd1));

reg [3:0] sense_key = 4'd0;
reg [7:0] sense_asc = 8'd0;
reg       cd_prevent = 1'b0;

reg  cmd_cpl_d = 1'b0;
always @(posedge clk) cmd_cpl_d <= (phase == PHASE_CMD_IN) && cmd_cpl;
wire new_cmd = (phase == PHASE_CMD_IN) && cmd_cpl && !cmd_cpl_d;

wire cd_eject_pulse = new_cmd && cmd_cd_eject_any && !cd_prevent;

wire frontier_breach = stb_ack && (phase == PHASE_DATA_OUT) && cmd_read
                       && mounted && rd_cur_unfilled && !data_phase_complete;

reg frontier_violated = 1'b0;
always @(posedge clk) begin
	if (any_rst || new_cmd)   frontier_violated <= 1'b0;
	else if (frontier_breach) frontier_violated <= 1'b1;
end

always @(posedge clk) begin
	if (any_rst) begin
		sense_key  <= 4'd0;
		sense_asc  <= 8'd0;
		cd_prevent <= 1'b0;
	end else if (wdog_abort) begin
		sense_key <= 4'hB;
		sense_asc <= op_code;
	end else if (frontier_breach) begin
		sense_key <= 4'hB;
		sense_asc <= 8'h4b;
	end else if (cd_msel_end && cd_msel_bad) begin
		sense_key <= 4'h5;
		sense_asc <= 8'h26;
	end else if (new_cmd) begin
		if (!cmd_ok) begin
			sense_key <= 4'h5;
			sense_asc <= 8'h20;
		end else if (cd_lun_rej) begin
			sense_key <= 4'h5;
			sense_asc <= 8'h25;
		end else if (cd_unit_attn_rej) begin
			sense_key <= 4'h6;
			sense_asc <= 8'h29;
		end else if (cd_spinup_rej) begin
			sense_key <= 4'h2;
			sense_asc <= 8'h04;
		end else if (cd_media_attn_rej) begin
			sense_key <= 4'h6;
			sense_asc <= 8'h28;
		end else if (cd_no_media) begin
			sense_key <= cd_nomedia_key;
			sense_asc <= cd_nomedia_asc;
		end else if (cd_field_rej || cd_hdr_msf_rej) begin
			sense_key <= 4'h5;
			sense_asc <= 8'h24;
		end else if (lba_out_of_range) begin
			sense_key <= 4'h5;
			sense_asc <= 8'h21;
		end else if (cmd_cd_eject_any) begin
			if (cd_prevent) begin
				sense_key <= 4'h5;
				sense_asc <= 8'h80;
			end else begin
				sense_key <= 4'd0;
				sense_asc <= 8'd0;
			end
		end else if (cmd_cd_prevent) begin
			cd_prevent <= cmd[4][0];
			sense_key  <= 4'd0;
			sense_asc  <= 8'd0;
		end else if (cmd_request_sense) begin
			if (cd_rs_report) begin
				sense_key <= cd_cur_key;
				sense_asc <= cd_cur_asc;
			end
		end else begin
			sense_key <= 4'd0;
			sense_asc <= 8'd0;
		end
	end else if ((CDROM != 0) && cmd_request_sense && (phase == PHASE_MESSAGE_OUT)) begin
		sense_key <= 4'd0;
		sense_asc <= 8'd0;
	end
end

reg  [7:0] cd_msel_b3, cd_msel_b9, cd_msel_b10, cd_msel_b11;
always @(posedge clk) begin
	if (new_cmd) cd_msel_b3 <= 8'd0;
	else if (stb_ack && (phase == PHASE_DATA_IN) && cmd_mode_select) begin
		if (data_cnt == 32'd3)  cd_msel_b3  <= din;
		if (data_cnt == 32'd9)  cd_msel_b9  <= din;
		if (data_cnt == 32'd10) cd_msel_b10 <= din;
		if (data_cnt == 32'd11) cd_msel_b11 <= din;
	end
end
wire        cd_msel_end = (CDROM != 0) && cmd_mode_select && (phase == PHASE_DATA_IN) && data_done;
wire        cd_msel_bd  = (data_len >= 32'd12) && (cd_msel_b3 >= 8'd8);
wire [23:0] cd_msel_bl  = {cd_msel_b9, cd_msel_b10, cd_msel_b11};
wire        cd_msel_bad = cd_msel_bd && (cd_msel_bl != 24'h000200) && (cd_msel_bl != 24'h000800);
always @(posedge clk) begin
	if (any_rst) cd_bs512 <= 1'b0;
	else if (cd_msel_end && cd_msel_bd && !cd_msel_bad) cd_bs512 <= (cd_msel_bl == 24'h000200);
end

reg [31:0] lba;
reg [15:0] tlen;

always @(posedge clk) begin
	if (old_io_ack & ~io_ack) lba <= lba + (wr_busy ? {26'd0, wr_n} : 32'd1);
	if(cmd_cpl && (phase == PHASE_CMD_IN)) begin
		if ((CDROM != 0) && cmd_read && !cd_bs512) begin
			lba  <= (cmd6_cpl?{11'd0, lba6}:lba10) << 2;
			tlen <= (cmd6_cpl?{7'd0, tlen6}:tlen10) << 2;
		end else begin
			lba <= cmd6_cpl?{11'd0, lba6}:lba10;
			tlen <= cmd6_cpl?{7'd0, tlen6}:tlen10;
		end

		c1_op_r        <= cmd[9][7:6];
		c1_trk_r       <= cmd[5];
		t43_start_r    <= cmd[6];
		t43_fmt_r      <= cmd[9];
		cd_page_r      <= cmd[2][5:0];
		cd_pc_r        <= cmd[2][7:6];
		cd_lun_bad_r   <= (cmd[1][7:5] != 3'd0);
		cd_astat_vol_r <= (cmd[3] == 8'h01);
		cd_alloc10_r   <= {16'd0, cmd[7], cmd[8]};
		cd_hdr_addr_r  <= {cmd[2], cmd[3], cmd[4], cmd[5]};
	end
end

wire [7:0] cmd1 = cmd[1];
wire [20:0] lba6 = { cmd1[4:0], cmd[2], cmd[3] };
wire [31:0] lba10 = { cmd[2], cmd[3], cmd[4], cmd[5] };

wire [8:0]  tlen6 = (cmd[4] == 0)?9'd256:{1'b0,cmd[4]};
wire [15:0] tlen10 = { cmd[7], cmd[8] };

parameter SPINUP_LOG = 27;
parameter WDOG_LOG = 22;

parameter IOWDOG_LOG = 24;
reg [IOWDOG_LOG-1:0] iowdog = 0;
wire iowdog_expired = &iowdog;
wire iostall_abort  = iowdog_expired;
always @(posedge clk) begin
	if (any_rst || !io_busy || (phase == PHASE_IDLE) || iostall_abort)
		iowdog <= 0;
	else
		iowdog <= iowdog + 1'd1;
end
reg [WDOG_LOG-1:0] wdog = 0;
wire wdog_expired = &wdog;
wire wdog_abort   = (wdog_expired && (phase != PHASE_IDLE)) || iostall_abort;

always @(posedge clk) begin
	if (any_rst || (phase == PHASE_IDLE) || stb_ack || stb_adv || io_busy || wdog_abort)
		wdog <= 0;
	else if (!wdog_expired)
		wdog <= wdog + 1'd1;
end

always @(posedge clk) begin
	ca_cmd_stb <= 1'b0; ca_read_stb <= 1'b0; ca_eject_stb <= 1'b0;
	if(any_rst) begin
		phase <= PHASE_IDLE;
	end else if (wdog_abort) begin
		if (status_done || cmd_aborted)
			phase <= PHASE_IDLE;
		else begin
			status <= `STATUS_CHECK_CONDITION;
			phase  <= PHASE_STATUS_OUT;
		end
	end else begin
		if(phase == PHASE_IDLE) begin
			if(sel && din[ID] && ((CDROM != 0) ? cd_enable : mounted) && !bus_busy)
				phase <= PHASE_CMD_IN;
		end

		else if(phase == PHASE_CMD_IN) begin
			if(cmd_cpl) begin
				$display("New command on target %d: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x", ID, cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7], cmd[8], cmd[9]);
				if(cmd_ok && !cd_lun_rej && !cd_unit_attn_rej && !cd_spinup_rej && !cd_media_attn_rej && !cd_no_media &&
				   !cd_field_rej && !cd_audio_read_rej && !cd_hdr_msf_rej && !lba_out_of_range) begin
					status <= (cmd_cd_eject_any && cd_prevent) ? `STATUS_CHECK_CONDITION : `STATUS_OK;

					ca_cmd_stb   <= cmd_cd_audio_nop;
					ca_read_stb  <= cmd_read && (CDROM != 0);
					ca_eject_stb <= cmd_cd_eject_any && !cd_prevent;

					if(cmd_read || cmd_inquiry || cmd_read_capacity || cmd_mode_sense || cmd_read_buffer || cmd_request_sense ||
					   cmd_cd_toc || cmd_cd_toc43 || cmd_cd_subq || cmd_cd_subq43 || cmd_cd_astat || cmd_cd_hdr) phase <= PHASE_DATA_OUT;
					else if(cmd_write || cmd_mode_select || cmd_write_buffer || cmd_cd_actl) phase <= PHASE_DATA_IN;
					else phase <= PHASE_STATUS_OUT;
				end else begin
					status <= `STATUS_CHECK_CONDITION;
					phase <= PHASE_STATUS_OUT;
				end
			end
		end

		else if(phase == PHASE_DATA_OUT) begin
			if(data_done) begin
				if(frontier_violated) status <= `STATUS_CHECK_CONDITION;
				phase <= PHASE_STATUS_OUT;
			end
		end

		else if(phase == PHASE_DATA_IN) begin
			if(data_done) begin
				if(cd_msel_end && cd_msel_bad) status <= `STATUS_CHECK_CONDITION;
				phase <= PHASE_STATUS_OUT;
			end
		end

		else if(phase == PHASE_STATUS_OUT) begin
			if(status_sent) phase <= PHASE_MESSAGE_OUT;
		end

		else if(phase == PHASE_MESSAGE_OUT) begin
			if(message_sent) phase <= PHASE_IDLE;
		end

		else
			phase <= PHASE_IDLE;
	end
end

wire        ca_io_active, ca_io_rd_w;
wire [31:0] ca_io_lba;
wire  [7:0] ca_ast_code, ca_cur_ctrl, ca_cur_trk;
wire  [7:0] ca_abs_m, ca_abs_s, ca_abs_f, ca_rel_m, ca_rel_s, ca_rel_f;
wire  [7:0] ca_toc_q0, ca_toc_q1, ca_toc_q2, ca_toc_q3;
wire        ca_toc_ready;
wire  [7:0] ca_t43_q0, ca_t43_q1, ca_t43_q2, ca_t43_q3;
wire  [9:0] ca_t43_len;
wire  [7:0] ca_t2_q0, ca_t2_q1, ca_t2_q2, ca_t2_q3;
wire  [9:0] ca_t2_len;
wire        ca_disc_audio;

function [7:0] cd_bcd2bin;
	input [7:0] v;
	cd_bcd2bin = (v[7:4] * 8'd10) + {4'd0, v[3:0]};
endfunction

wire  [7:0] ca_toc_trk_bin = cd_bcd2bin(c1_trk_r);
wire  [8:0] ca_toc_trk_k   = (ca_toc_trk_bin == 8'd0)  ? 9'd0  :
                             (ca_toc_trk_bin >  8'd99) ? 9'd98 :
                             {1'b0, ca_toc_trk_bin} - 9'd1;
wire  [8:0] ca_toc_base    = (c1_op_r == 2'b01) ? 9'd4 :
                             (c1_op_r == 2'b10) ? (9'd8 + {ca_toc_trk_k[6:0], 2'b00}) :
                                                  9'd0;
wire  [8:0] ca_toc_raw     = ca_toc_base + data_cnt[8:0];
wire  [8:0] ca_toc_addr    = (ca_toc_raw < 9'd404) ? ca_toc_raw
                                                   : (9'd400 + {7'd0, ca_toc_raw[1:0]});
wire  [7:0] cd_toc_dout    = (CD_AUDIO == 0) ? cd_c1_byte(data_cnt, c1_op_r, cd_lo_m, cd_lo_s, cd_lo_f)
                           : ca_toc_ready ? ca_toc_q0 : 8'h00;

function [7:0] cd_c1_byte;
	input [31:0] cnt;
	input [1:0]  op;
	input [6:0]  m, s, f;
	begin
		cd_c1_byte =
			(cnt >= 32'd4) ? 8'h00 :
			(op == 2'b00) ? ((cnt == 32'd0 || cnt == 32'd1) ? 8'h01 : 8'h00) :
			(op == 2'b01) ? ((cnt == 32'd0) ? cd_bin2bcd({1'b0, m}) :
			                 (cnt == 32'd1) ? cd_bin2bcd({1'b0, s}) :
			                 (cnt == 32'd2) ? cd_bin2bcd({1'b0, f}) : 8'h00) :
			                ((cnt == 32'd0) ? 8'h14 : (cnt == 32'd2) ? 8'h02 : 8'h00);
	end
endfunction

reg  [6:0]  cd_lo_m = 7'd0, cd_lo_s = 7'd0, cd_lo_f = 7'd0;
reg  [31:0] cd_lo_v = 32'd0;
reg         cd_lo_run = 1'b0, cd_lo_ok = 1'b0;
always @(posedge clk) begin
	if ((CDROM != 0) && (CD_AUDIO == 0) && img_mounted) begin
		cd_lo_v   <= {2'b00, img_blocks[31:2]} + 32'd150;
		cd_lo_m   <= 7'd0;
		cd_lo_s   <= 7'd0;
		cd_lo_run <= |img_blocks;
		cd_lo_ok  <= 1'b0;
	end else if (cd_lo_run) begin
		if ((cd_lo_v >= 32'd4500) && (cd_lo_m != 7'd99)) begin
			cd_lo_v <= cd_lo_v - 32'd4500; cd_lo_m <= cd_lo_m + 7'd1;
		end else if (cd_lo_v >= 32'd75) begin
			cd_lo_v <= cd_lo_v - 32'd75;   cd_lo_s <= cd_lo_s + 7'd1;
		end else begin
			cd_lo_f <= cd_lo_v[6:0]; cd_lo_run <= 1'b0; cd_lo_ok <= 1'b1;
		end
	end
end
assign cd_toc_ok = (CD_AUDIO != 0) ? ca_toc_ready : cd_lo_ok;

wire  [6:0] ca_t43_nreal = (ca_t43_len >= 10'd14) ? ((ca_t43_len - 10'd14) >> 3) + 7'd1 : 7'd1;
wire  [6:0] ca_t43_soff  =
	(t43_start_r == 8'h00 || t43_start_r == 8'h01) ? 7'd0 :
	(t43_start_r == 8'hAA)                          ? ca_t43_nreal :
	(t43_start_r >  {1'b0, ca_t43_nreal})           ? ca_t43_nreal :
	                                                  t43_start_r[6:0] - 7'd1;
wire  [9:0] ca_t43_flen  = {(7'd1 + ca_t43_nreal - ca_t43_soff), 3'b000} + 10'd2;
wire  [9:0] ca_t43_tot   = ca_t43_flen + 10'd2;
wire  [8:0] ca_t43_addr  = (data_cnt < 32'd4) ? data_cnt[8:0]
                         : (9'd4 + {ca_t43_soff, 3'b000} + (data_cnt[8:0] - 9'd4));
function [7:0] t43_hdr_fix;
	input [31:0] cnt;
	input [9:0]  tot;
	input [9:0]  flen;
	input [7:0]  raw;
	t43_hdr_fix = (cnt >= {22'd0, tot}) ? 8'h00 :
	              (cnt == 32'd0) ? {6'd0, flen[9:8]} :
	              (cnt == 32'd1) ? flen[7:0] : raw;
endfunction
wire  [7:0] cd_toc43_dout = ca_toc_ready
                          ? t43_hdr_fix(data_cnt, ca_t43_tot, ca_t43_flen, ca_t43_q0)
                          : 8'h00;

wire  [8:0] ca_t2_addr = (cmd_cd_t43f1 ? 9'd496 : 9'd0) + data_cnt[8:0];
function [7:0] t2_fix;
	input [31:0] cnt;
	input [9:0]  len;
	input [7:0]  raw;
	t2_fix = (cnt >= {22'd0, len}) ? 8'h00 : raw;
endfunction
function [7:0] sess_fix;
	input [31:0] cnt;
	input [7:0]  raw;
	sess_fix = (cnt >= 32'd12) ? 8'h00 : raw;
endfunction
wire  [7:0] cd_toc2_dout = !ca_toc_ready ? 8'h00 :
                           cmd_cd_t43f1 ? sess_fix(data_cnt, ca_t2_q0)
                                        : t2_fix(data_cnt, ca_t2_len, ca_t2_q0);

wire  [7:0] ca_ast_std  = (ca_ast_code == 8'd0) ? 8'h11 :
                          (ca_ast_code == 8'd1) ? 8'h12 : CD_AST_STOPPED;

wire  [7:0] cd_subq_dout   = cd_subq_byte(data_cnt, ca_cur_trk,
                                          ca_rel_m, ca_rel_s, ca_rel_f,
                                          ca_abs_m, ca_abs_s, ca_abs_f);
wire  [7:0] cd_subq43_dout = cd_subq43_byte(data_cnt, ca_ast_std,
                                            ca_cur_ctrl, ca_cur_trk,
                                            ca_abs_m, ca_abs_s, ca_abs_f,
                                            ca_rel_m, ca_rel_s, ca_rel_f);
wire  [7:0] cd_astat_dout  = cd_astat_byte(data_cnt, cd_astat_vol_r,
                                           ca_ast_code, ca_cur_ctrl,
                                           ca_abs_m, ca_abs_s, ca_abs_f);

wire        cd_audio_read_rej = (CDROM != 0) && mounted && cmd_read && ca_disc_audio;

reg         ca_cmd_stb   = 1'b0;
reg         ca_read_stb  = 1'b0;
reg         ca_eject_stb = 1'b0;

wire  [7:0] cd_ap_ch0 = 8'h01, cd_ap_vol0 = 8'hff;
wire  [7:0] cd_ap_ch1 = 8'h02, cd_ap_vol1 = 8'hff;

wire ca_grant = (phase == PHASE_IDLE || (cmd_read && phase == PHASE_DATA_OUT))
                && !io_rd_d && !io_wr && !io_ack && mounted;

generate if ((CDROM != 0) && (CD_AUDIO != 0)) begin : g_cd_audio
	cd_audio #(.CLK_HZ(32'd32_500_000)) cd_audio_i (
		.clk(clk), .rst(sys_rst), .bus_rst(rst),
		.mounted(mounted), .img_mounted(img_mounted), .img_blocks(img_blocks),
		.cmd_stb(ca_cmd_stb), .cmd_op(cmd[0]),
		.cdb1(cmd[1]), .cdb2(cmd[2]), .cdb3(cmd[3]), .cdb4(cmd[4]),
		.cdb5(cmd[5]), .cdb6(cmd[6]), .cdb7(cmd[7]), .cdb8(cmd[8]), .cdb9(cmd[9]),
		.read_stb(ca_read_stb), .eject_stb(ca_eject_stb),
		.ap_ch0(cd_ap_ch0), .ap_vol0(cd_ap_vol0),
		.ap_ch1(cd_ap_ch1), .ap_vol1(cd_ap_vol1),
		.ch_grant(ca_grant),
		.ca_io_active(ca_io_active), .ca_io_rd(ca_io_rd_w), .ca_io_lba(ca_io_lba),
		.io_ack(io_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_addr_hi(sd_buff_addr_hi),
		.sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
		.ast_code(ca_ast_code), .cur_ctrl(ca_cur_ctrl), .cur_trk(ca_cur_trk),
		.abs_m(ca_abs_m), .abs_s(ca_abs_s), .abs_f(ca_abs_f),
		.rel_m(ca_rel_m), .rel_s(ca_rel_s), .rel_f(ca_rel_f),
		.toc_base(ca_toc_addr),
		.toc_q0(ca_toc_q0), .toc_q1(ca_toc_q1), .toc_q2(ca_toc_q2), .toc_q3(ca_toc_q3),
		.toc_ready(ca_toc_ready),
		.toc43_base(ca_t43_addr),
		.toc43_q0(ca_t43_q0), .toc43_q1(ca_t43_q1),
		.toc43_q2(ca_t43_q2), .toc43_q3(ca_t43_q3),
		.toc43_len(ca_t43_len),
		.toc2_base(ca_t2_addr),
		.toc2_q0(ca_t2_q0), .toc2_q1(ca_t2_q1),
		.toc2_q2(ca_t2_q2), .toc2_q3(ca_t2_q3),
		.toc2_len(ca_t2_len),
		.disc_audio(ca_disc_audio),
		.snd_l(cd_snd_l), .snd_r(cd_snd_r)
	);
end else begin : g_no_cd_audio
	assign ca_io_active = 1'b0;
	assign ca_io_rd_w   = 1'b0;
	assign ca_io_lba    = 32'd0;
	assign ca_ast_code  = 8'h05;
	assign ca_cur_ctrl  = 8'd0;
	assign ca_cur_trk   = 8'd0;
	assign {ca_abs_m, ca_abs_s, ca_abs_f} = 24'd0;
	assign {ca_rel_m, ca_rel_s, ca_rel_f} = 24'd0;
	assign {ca_toc_q0, ca_toc_q1, ca_toc_q2, ca_toc_q3} = 32'd0;
	assign ca_toc_ready = 1'b0;
	assign {ca_t43_q0, ca_t43_q1, ca_t43_q2, ca_t43_q3} = 32'd0;
	assign ca_t43_len   = 10'd0;
	assign {ca_t2_q0, ca_t2_q1, ca_t2_q2, ca_t2_q3} = 32'd0;
	assign ca_t2_len    = 10'd0;
	assign ca_disc_audio = 1'b0;
	assign cd_snd_l     = 16'sd0;
	assign cd_snd_r     = 16'sd0;
end
endgenerate

endmodule

module scsi_dpram #(parameter DATAWIDTH=8, ADDRWIDTH=9)
(
	input	                clock,

	input	[ADDRWIDTH-1:0] address_a,
	input	[DATAWIDTH-1:0] data_a,
	input	                wren_a,
	output reg [DATAWIDTH-1:0] q_a,

	input	[ADDRWIDTH-1:0] address_b,
	input	[DATAWIDTH-1:0] data_b,
	input	                wren_b,
	output reg [DATAWIDTH-1:0] q_b
);

reg [DATAWIDTH-1:0] ram[0:(1<<ADDRWIDTH)-1];

always @(posedge clock) begin
	if(wren_a) begin
		ram[address_a] <= data_a;
		q_a <= data_a;
	end else begin
		q_a <= ram[address_a];
	end
end

always @(posedge clock) begin
	if(wren_b) begin
		ram[address_b] <= data_b;
		q_b <= data_b;
	end else begin
		q_b <= ram[address_b];
	end
end

endmodule
