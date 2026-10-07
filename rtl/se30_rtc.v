// se30_rtc.v - the real-time clock and parameter RAM (344S0042-B)

`timescale 1ns/1ps

module se30_rtc #(
  parameter integer CLK_HZ = 31_334_400
) (
  input             clk,
  input      [32:0] timestamp,
  input             cs_n,
  input             sck,
  input             d_in,
  output reg        d_out,
  output reg        d_oe,
  output reg        one_hz,
  input             h_we,
  input       [7:0] h_addr,
  input       [7:0] h_wdata,
  input       [7:0] h_raddr,
  output reg  [7:0] h_rdata,
  output            pram_wr,
  output     [31:0] dbg
);

  reg  [31:0] secs = 0;
  reg   [7:0] ram [0:255];
  reg         wp = 0;
  reg   [7:0] test = 0;

  integer i;
  initial for (i = 0; i < 256; i = i + 1) ram[i] = 8'h00;

  reg  [31:0] pre = 0;
  reg         ts_q = 0, loaded = 0;
  initial one_hz = 1;

  localparam CMD = 3'd0, CMD2 = 3'd1, WDATA = 3'd2, RDATA = 3'd3, DONE = 3'd4;
  reg   [2:0] phase = CMD;
  reg   [2:0] nbit = 0;
  reg   [7:0] sh = 0;
  reg   [7:0] cmd1 = 0;
  reg   [7:0] xaddr = 0;
  reg   [2:0] kind = 0;
  localparam K_NONE = 3'd0, K_SECS = 3'd1, K_TEST = 3'd2, K_WP = 3'd3, K_RAM = 3'd4;
  reg   [7:0] out = 0;
  reg   [7:0] ntrans = 0;
  reg         sck_q = 1;

  wire rise = sck && !sck_q;
  wire fall = !sck && sck_q;
  wire [7:0] inbyte = {sh[6:0], d_in};

  task decode1(input [7:0] c, output [2:0] k, output [7:0] a);
    begin
      k = K_NONE; a = 8'h00;
      if (c[1:0] == 2'b01) begin
        if (c[6:5] == 2'b00)             begin k = K_SECS; a = {6'd0, c[3:2]}; end
        else if (c[6:0] == 7'b0110001)   begin k = K_TEST; end
        else if (c[6:0] == 7'b0110101)   begin k = K_WP;   end
        else if (c[6:4] == 3'b010)       begin k = K_RAM;  a = {3'b000, c[6:2]}; end
        else if (c[6])                   begin k = K_RAM;  a = {3'b000, c[6:2]}; end
      end
    end
  endtask

  reg  [7:0] raddr = 0, ram_q = 0;
  reg        we = 0;
  reg  [7:0] waddr = 0, wdat = 0;
  reg        load = 0, load2 = 0;
  always @(posedge clk) begin
    ram_q <= ram[raddr];
    h_rdata <= ram[h_raddr];
    if (h_we) ram[h_addr] <= h_wdata;
    else if (we) ram[waddr] <= wdat;
  end
  assign pram_wr = we;

  reg [2:0] k1;
  reg [7:0] a1;

  always @(posedge clk) begin
    we <= 0; load <= 0; load2 <= load;
    if (load2) out <= (kind == K_RAM) ? ram_q : secs[8 * xaddr[1:0] +: 8];

    ts_q <= timestamp[32];
    if (timestamp[32] != ts_q && !loaded) begin
      secs <= timestamp[31:0] + 32'd2_082_844_800;
      loaded <= 1; pre <= 0; one_hz <= 1;
    end else if (pre == CLK_HZ - 1) begin
      pre <= 0; secs <= secs + 1'b1; one_hz <= 0;
    end else begin
      pre <= pre + 1'b1;
      if (pre == CLK_HZ / 2 - 1) one_hz <= 1;
    end

    sck_q <= sck;
    if (cs_n) begin
      phase <= CMD; nbit <= 0; d_oe <= 0;
    end else if (rise && phase != RDATA && phase != DONE) begin
      sh <= inbyte;
      nbit <= nbit + 1'b1;
      if (nbit == 3'd7) begin
        case (phase)
          CMD: begin
            cmd1 <= inbyte; ntrans <= ntrans + 1'b1;
            if ((inbyte & 8'h78) == 8'h38) phase <= CMD2;
            else begin
              decode1(inbyte, k1, a1);
              kind <= k1; xaddr <= a1;
              if (inbyte[7]) begin
                phase <= (k1 == K_SECS || k1 == K_RAM) ? RDATA : DONE;
                raddr <= a1; load <= 1;
              end else phase <= WDATA;
            end
          end
          CMD2: begin
            kind <= K_RAM; xaddr <= {cmd1[2:0], inbyte[6:2]};
            if (cmd1[7]) begin phase <= RDATA; raddr <= {cmd1[2:0], inbyte[6:2]}; load <= 1; end
            else phase <= WDATA;
          end
          WDATA: begin
            phase <= DONE;
            if (kind == K_WP) wp <= inbyte[7];
            else if (!wp) case (kind)
              K_SECS: secs[8 * xaddr[1:0] +: 8] <= inbyte;
              K_TEST: test <= inbyte;
              K_RAM:  begin we <= 1; waddr <= xaddr; wdat <= inbyte; end
              default: ;
            endcase
          end
          default: ;
        endcase
      end
    end else if (fall && phase == RDATA) begin
      d_out <= out[7]; out <= {out[6:0], 1'b1}; d_oe <= 1;
      nbit <= nbit + 1'b1;
      if (nbit == 3'd7) phase <= DONE;
    end
  end

  assign dbg = {secs[7:0], cmd1, ntrans, wp, test[7:1]};

endmodule
