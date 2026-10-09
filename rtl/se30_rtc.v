// se30_rtc.v - the clock chip (344S0042-B): a seconds counter, 256 bytes of parameter RAM and
// the one-second output, on the ROM's serial line (CS*, clock, data; whole bytes, MSB first).

`timescale 1ns/1ps

module se30_rtc #(
  parameter integer CLK_HZ = 31_334_400    // clk_sys
) (
  input             clk,
  input      [32:0] timestamp,             // hps_io's TIMESTAMP
  input             cs_n,                  // VIA1 PB2 pin
  input             sck,                   // VIA1 PB1 pin
  input             d_in,                  // VIA1 PB0 pin
  output reg        d_out,
  output reg        d_oe,
  output reg        one_hz,
  // the host port (persistent PRAM)
  input             h_we,
  input       [7:0] h_addr,
  input       [7:0] h_wdata,
  input       [7:0] h_raddr,
  output reg  [7:0] h_rdata,
  output            pram_wr,
  // {secs[7:0], last command byte, transactions[7:0], wp, test[6:0] (7:1)}
  output     [31:0] dbg
);

  reg  [31:0] secs = 0;
  reg   [7:0] ram [0:255];
  reg         wp = 0;
  reg   [7:0] test = 0;

  integer i;
  initial for (i = 0; i < 256; i = i + 1) ram[i] = 8'h00;

  // ---------------------------------------------------------- the time
  reg  [31:0] pre = 0;                     // clocks into the current second
  reg         ts_q = 0, loaded = 0;
  initial one_hz = 1;

  // ---------------------------------------------------------- the line
  localparam CMD = 3'd0, CMD2 = 3'd1, WDATA = 3'd2, RDATA = 3'd3, DONE = 3'd4;
  reg   [2:0] phase = CMD;
  reg   [2:0] nbit = 0;                    // bits taken or given in this byte
  reg   [7:0] sh = 0;                      // the byte coming in
  reg   [7:0] cmd1 = 0;
  reg   [7:0] xaddr = 0;                   // the target: an xPRAM address, or a register
  reg   [2:0] kind = 0;                    // what the command reaches
  localparam K_NONE = 3'd0, K_SECS = 3'd1, K_TEST = 3'd2, K_WP = 3'd3, K_RAM = 3'd4;
  reg   [7:0] out = 0;                     // the byte going out
  reg   [7:0] ntrans = 0;
  reg         sck_q = 1;

  wire rise = sck && !sck_q;
  wire fall = !sck && sck_q;
  wire [7:0] inbyte = {sh[6:0], d_in};     // the byte, with this rising edge's bit

  // decode an original-form command: what it reaches and where
  task decode1(input [7:0] c, output [2:0] k, output [7:0] a);
    begin
      k = K_NONE; a = 8'h00;
      if (c[1:0] == 2'b01) begin
        if (c[6:5] == 2'b00)             begin k = K_SECS; a = {6'd0, c[3:2]}; end
        else if (c[6:0] == 7'b0110001)   begin k = K_TEST; end
        else if (c[6:0] == 7'b0110101)   begin k = K_WP;   end
        else if (c[6:4] == 3'b010)       begin k = K_RAM;  a = {3'b000, c[6:2]}; end   // $08-$0B
        else if (c[6])                   begin k = K_RAM;  a = {3'b000, c[6:2]}; end   // $10-$1F
      end
    end
  endtask

  // the RAM: one registered read port, one write port (block RAM); a read's byte is taken two
  // clocks after its address is set
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

    // the seconds
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

    // the serial line
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
      if (nbit == 3'd7) phase <= DONE;     // the last bit stays driven until CS* rises
    end
  end

  assign dbg = {secs[7:0], cmd1, ntrans, wp, test[7:1]};

endmodule
