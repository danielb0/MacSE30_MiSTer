// se30_rtc.v - the SE/30's clock chip (UK4, Apple 344S0042-B): a seconds
// counter, 256 bytes of parameter RAM and the one-second output.
// SE30_PLAN.md 6.5.
//
// THE SERIAL LINE (Inside Macintosh, hardware chapter, 1985, pp. 28-29)
//   CS* low for the whole transaction ("if you set it to 1, you'll abort
//   the transfer"); whole bytes, most significant bit first.  The host
//   sets D with the clock low and the chip takes it on the rising edge;
//   the chip drives each bit it sends from the falling edge ("lower the
//   data-clock and read the first (high-order) bit") and holds it through
//   the rising edge, where the ROM's reader ($4080DE44) samples.  The chip
//   drives D only in a read's data byte, from its first falling edge -
//   the ROM makes PB0 an input before that edge - until CS* rises.  The
//   ROM makes PB0 an output again ($4080DE60) before it raises CS*
//   ($4080DE2C), so for one VIA access both drive the line; the machine's
//   pin takes the VIA's (4.5), as the ROM's next write expects.
//
// THE COMMANDS (z = 1 reads)
//   z00x0001 z00x0101 z00x1001 z00x1101   seconds 0 (lowest) to 3.  Inside
//                                         Macintosh gives x = 0; the ROM
//                                         reads with x = 1 ($9D-$91,
//                                         $4080DCAE) and writes with x = 0
//                                         ($4080DCEA), so x is ignored
//   00110001                              test register, write only
//   00110101                              write protect, write only
//   z010aa01                              the original RAM $10-$13
//   z1aaaa01                              the original RAM $00-$0F
//   z0111aaa 0bbbbb00                     extended: xPRAM $aaabbbbb (the
//                                         ROM's form, $4080DD8E; plan 6.5.1)
//   Bits 6-2 of an original command, read as an address, give where its
//   byte lives in the 256: $10-$1F and $08-$0B.  The ROM's xPRAM clear
//   ($4080DC4C) spares exactly $08-$1F, which corroborates it.  Any other
//   command is ignored and a read of it leaves D undriven.
//
// WRITE PROTECT
//   "If the high-order bit (bit 7) of the write-protect register is set,
//   this prevents writing into any other register on the clock chip
//   (including parameter RAM)" - applied to both command forms (plan 6.5.1
//   records a secondary claim that the extended form wrote through).  The
//   test register is stored and does nothing: what its bits 7-6 do to the
//   counting is not documented.
//
// THE CLOCK
//   secs increments once every CLK_HZ clocks (the chip counts its 32.768
//   kHz crystal).  It is loaded once, on the first toggle of the HPS's
//   TIMESTAMP (bit 32), with the Unix time + 2,082,844,800: 1970 in
//   seconds from 1904, the Macintosh epoch (the MacPlus core's
//   conversion).  Later toggles are ignored - once the machine runs, the
//   clock is its own and the ROM may set it.  ONE_HZ falls at each
//   increment ("Each time the counter is incremented, the RTC sends an
//   interrupt request signal to the VIA", Guide p. 143; VIA1 CA2 takes the
//   falling edge) and rises half a second later - the duty cycle is not
//   documented.
//
// NO RESET
//   The chip is battery-backed and has no reset pin (sheet 4): the machine's
//   resets never reach it.  Its RAM is zero when the core loads (plan 6.5.3).

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

  function [7:0] read_target(input [2:0] k, input [7:0] a);
    case (k)
      K_SECS:  read_target = secs[8 * a[1:0] +: 8];
      K_RAM:   read_target = ram[a];
      default: read_target = 8'hFF;
    endcase
  endfunction

  reg [2:0] k1;
  reg [7:0] a1;

  always @(posedge clk) begin
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
                out <= read_target(k1, a1);
              end else phase <= WDATA;
            end
          end
          CMD2: begin
            kind <= K_RAM; xaddr <= {cmd1[2:0], inbyte[6:2]};
            if (cmd1[7]) begin phase <= RDATA; out <= ram[{cmd1[2:0], inbyte[6:2]}]; end
            else phase <= WDATA;
          end
          WDATA: begin
            phase <= DONE;
            if (kind == K_WP) wp <= inbyte[7];
            else if (!wp) case (kind)
              K_SECS: secs[8 * xaddr[1:0] +: 8] <= inbyte;
              K_TEST: test <= inbyte;
              K_RAM:  ram[xaddr] <= inbyte;
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
