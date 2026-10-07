// se30_flp_dkmux.v - the SDRAM disk port shared by the floppy image blocks

`timescale 1ns/1ps

module se30_flp_dkmux (
  input             clk,
  input             reset_n,

  input             ld0_req,
  input      [23:0] ld0_addr,
  input      [15:0] ld0_wdata,
  output            ld0_ack,

  input             en0_req,
  input      [23:0] en0_addr,
  output     [15:0] en0_rdata,
  output            en0_ack,

  input             ld1_req,
  input      [23:0] ld1_addr,
  input      [15:0] ld1_wdata,
  output            ld1_ack,

  input             en1_req,
  input      [23:0] en1_addr,
  output     [15:0] en1_rdata,
  output            en1_ack,

  input             de0_req,
  input      [23:0] de0_addr,
  input      [15:0] de0_wdata,
  output            de0_ack,

  input             wr0_req,
  input      [23:0] wr0_addr,
  output     [15:0] wr0_rdata,
  output            wr0_ack,

  input             de1_req,
  input      [23:0] de1_addr,
  input      [15:0] de1_wdata,
  output            de1_ack,

  input             wr1_req,
  input      [23:0] wr1_addr,
  output     [15:0] wr1_rdata,
  output            wr1_ack,

  output            dk_req,
  output            dk_we,
  output     [23:0] dk_addr,
  output     [15:0] dk_wdata,
  input      [15:0] dk_rdata,
  input             dk_ack
);

  reg  [2:0] owner;
  wire [7:0] req = {wr1_req, de1_req, wr0_req, de0_req, en1_req, ld1_req, en0_req, ld0_req};

  reg  [2:0] nxt;
  reg        found;
  integer    i;
  always @* begin
    nxt = owner; found = 1'b0;
    for (i = 1; i < 8; i = i + 1)
      if (!found && req[(owner + i) & 7]) begin nxt = owner + i[2:0]; found = 1'b1; end
  end

  always @(posedge clk or negedge reset_n)
    if (!reset_n)                       owner <= 3'd1;
    else if (!dk_req && !dk_ack && found) owner <= nxt;

  reg [23:0] a;
  reg [15:0] d;
  always @* begin
    case (owner)
      3'd0: a = ld0_addr; 3'd1: a = en0_addr; 3'd2: a = ld1_addr; 3'd3: a = en1_addr;
      3'd4: a = de0_addr; 3'd5: a = wr0_addr; 3'd6: a = de1_addr; default: a = wr1_addr;
    endcase
    case (owner[2:1])
      2'd0: d = ld0_wdata; 2'd1: d = ld1_wdata; 2'd2: d = de0_wdata; default: d = de1_wdata;
    endcase
  end

  assign dk_req   = req[owner];
  assign dk_we    = !owner[0];
  assign dk_addr  = a;
  assign dk_wdata = d;
  assign ld0_ack  = owner == 3'd0 && dk_ack;
  assign en0_ack  = owner == 3'd1 && dk_ack;
  assign ld1_ack  = owner == 3'd2 && dk_ack;
  assign en1_ack  = owner == 3'd3 && dk_ack;
  assign de0_ack  = owner == 3'd4 && dk_ack;
  assign wr0_ack  = owner == 3'd5 && dk_ack;
  assign de1_ack  = owner == 3'd6 && dk_ack;
  assign wr1_ack  = owner == 3'd7 && dk_ack;
  assign en0_rdata = dk_rdata;
  assign en1_rdata = dk_rdata;
  assign wr0_rdata = dk_rdata;
  assign wr1_rdata = dk_rdata;

endmodule
