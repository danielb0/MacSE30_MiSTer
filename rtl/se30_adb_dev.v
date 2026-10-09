// se30_adb_dev.v - the ADB devices: a device engine that speaks the bus at the bit-cell level,
// and the Apple Extended Keyboard and Apple Standard Mouse built on it, fed from MiSTer's PS/2.

`timescale 1ns/1ps

module se30_adb_engine #(
  parameter  [15:0] CLK_KHZ     = 16'd31334, // clk_sys, in kHz
  parameter  [3:0] DEF_ADDR     = 4'd2,
  parameter  [7:0] DEF_HANDLER  = 8'd2,
  parameter  [7:0] ALT_HANDLER  = 8'd3,     // the other handler ID it supports
  parameter integer T_RESP      = 200       // us, stop bit to start bit
) (
  input             clk,
  input             reset,                  // power-on: the core's load
  input             line,
  output            pull,
  // the device
  input             has_r0,                 // register 0 has data (and wants service)
  input      [15:0] r0_word,
  input             has_r2,
  input      [15:0] r2_word,
  output reg        r0_latch,               // the device's word is taken for a Talk
  output reg        r0_sent,                // ... and was sent without a collision
  output reg        listen_we,              // a Listen to register 0-2
  output reg  [1:0] listen_reg,
  output reg [15:0] listen_data,
  output reg        flush,
  output reg        dev_reset,              // Global Reset, SendReset or power-on
  output reg  [3:0] addr,
  output reg  [7:0] handler,
  output     [15:0] dbg
);

  // ---------------------------------------------------------- the us tick
  reg [15:0] acc = 0;
  reg        us = 0;
  always @(posedge clk) begin
    if (acc + 16'd1000 >= CLK_KHZ) begin acc <= acc + 16'd1000 - CLK_KHZ; us <= 1; end
    else begin acc <= acc + 16'd1000; us <= 0; end
  end

  // ---------------------------------------------------------- the line
  reg        ln_q = 1;
  wire       fall = ln_q && !line;
  wire       rise = !ln_q && line;
  reg [11:0] t_low = 0, t_high = 0;         // us since the last fall / rise, saturating
  reg [11:0] t = 0;                         // us in the current state

  localparam S_IDLE = 4'd0, S_SYNC = 4'd1, S_CMD = 4'd2, S_STOPW = 4'd3, S_STOP = 4'd4,
             S_TWAIT = 4'd5, S_SEND = 4'd6, S_LWAIT = 4'd7, S_LISTEN = 4'd8;
  reg  [3:0] st = S_IDLE;
  reg  [7:0] cmd = 0;
  reg  [4:0] nb = 0;
  reg        srq_en = 1, collided = 0;
  reg        drive = 0;                     // pulling the line low
  reg [11:0] srq_t = 0;
  reg        srq_on = 0;

  // sending
  reg [16:0] sh = 0;                        // start bit + 16 data bits
  reg  [4:0] sb = 0;                        // bits left to send (then the stop)
  reg        sreg0 = 0;                     // the Talk was to register 0
  reg  [6:0] low_len = 0;                   // this bit's low time, us
  reg        in_low = 0;                    // this bit's low phase
  reg  [6:0] ct = 0;                        // us into this bit

  // listening
  reg [17:0] lsh = 0;

  wire       addressed = cmd[7:4] == addr;
  wire       is_talk   = cmd[3:2] == 2'b11;
  wire       is_listen = cmd[3:2] == 2'b10;

  wire [15:0] r3_word = {1'b0, 1'b1, srq_en, 1'b0, addr, handler};

  task do_reset;
    begin
      addr <= DEF_ADDR; handler <= DEF_HANDLER; srq_en <= 1; collided <= 0;
      dev_reset <= 1; drive <= 0; srq_on <= 0; st <= S_IDLE;
    end
  endtask

  initial begin addr = DEF_ADDR; handler = DEF_HANDLER; end

  always @(posedge clk) begin
    ln_q <= line;
    r0_latch <= 0; r0_sent <= 0; listen_we <= 0; flush <= 0; dev_reset <= 0;

    if (fall) t_low <= 0; else if (us && !line && t_low != 12'hFFF) t_low <= t_low + 1'b1;
    if (rise) t_high <= 0; else if (us && line && t_high != 12'hFFF) t_high <= t_high + 1'b1;
    if (us && t != 12'hFFF) t <= t + 1'b1;
    if (us && srq_on) srq_t <= srq_t + 1'b1;

    if (reset) begin
      do_reset;
    end else if (!line && t_low >= 12'd3000 && !drive) begin
      do_reset;                                              // Global Reset
    end else if (rise && t_low >= 12'd560 && !drive) begin
      st <= S_SYNC; t <= 0; srq_on <= 0;                     // Attention: whatever was going on ends
    end else begin
      // the service request's own timer, independent of the state
      if (srq_on && srq_t >= 12'd300) begin srq_on <= 0; drive <= 0; end

      case (st)
        S_IDLE: ;
        S_SYNC: if (fall) begin st <= S_CMD; nb <= 0; t <= 0; end
                else if (line && t_high > 12'd200) st <= S_IDLE;
        S_CMD: begin
          if (rise) begin
            cmd <= {cmd[6:0], t_low < 12'd50};
            nb <= nb + 1'b1;
            if (nb == 5'd7) st <= S_STOPW;
          end else if (line && t_high > 12'd200) st <= S_IDLE;
        end
        S_STOPW: begin
          if (fall) begin
            // the stop bit begins: the command is known.  Ask for service?
            st <= S_STOP;
            if (srq_en && has_r0 && !(addressed && is_talk)) begin
              drive <= 1; srq_on <= 1; srq_t <= 0;
            end
          end else if (line && t_high > 12'd200) st <= S_IDLE;
        end
        S_STOP: if (rise) begin
          t <= 0; st <= S_IDLE;
          if (cmd[3:0] == 4'b0000) do_reset;                               // SendReset
          else if (addressed && cmd[3:0] == 4'b0001) flush <= 1;           // Flush
          else if (addressed && is_talk) begin
            if (cmd[1:0] == 2'd3)                   begin sh <= {1'b1, r3_word}; st <= S_TWAIT; end
            else if (cmd[1:0] == 2'd0 && has_r0)    begin sh <= {1'b1, r0_word}; st <= S_TWAIT; r0_latch <= 1; end
            else if (cmd[1:0] == 2'd2 && has_r2)    begin sh <= {1'b1, r2_word}; st <= S_TWAIT; end
            sreg0 <= cmd[1:0] == 2'd0;
          end else if (addressed && is_listen) begin
            st <= S_LWAIT; nb <= 0;
          end
        end
        S_TWAIT: begin
          if (fall) begin collided <= 1; st <= S_IDLE; end                 // someone else talked first
          else if (t >= T_RESP) begin
            st <= S_SEND; sb <= 5'd17; ct <= 0; in_low <= 1; drive <= 1;
            low_len <= sh[16] ? 7'd35 : 7'd65;
          end
        end
        S_SEND: if (us) begin
          ct <= ct + 1'b1;
          if (in_low) begin
            if (ct + 1'b1 >= low_len) begin in_low <= 0; drive <= 0; end
          end else begin
            // released: the line must follow us up (a collision otherwise)
            if (ct >= low_len + 7'd2 && !line) begin
              collided <= 1; drive <= 0; st <= S_IDLE;
            end else if (sb == 0) begin
              // the stop bit's low is over and the line is up: done
              if (ct >= low_len + 7'd2) begin
                st <= S_IDLE; collided <= 0;
                if (sreg0) r0_sent <= 1;
              end
            end else if (ct + 1'b1 >= 7'd100) begin
              // the next bit, or the stop bit
              sb <= sb - 1'b1; sh <= {sh[15:0], 1'b0}; ct <= 0; in_low <= 1; drive <= 1;
              low_len <= (sb == 5'd1) ? 7'd70 : (sh[15] ? 7'd35 : 7'd65);
            end
          end
        end
        S_LWAIT: begin
          if (fall) begin st <= S_LISTEN; nb <= 0; end
          else if (t > 12'd300) st <= S_IDLE;                               // the host sent nothing
        end
        S_LISTEN: begin
          if (rise) begin lsh <= {lsh[16:0], t_low < 12'd50}; nb <= nb + 1'b1; end
          else if (line && t_high > 12'd150) begin
            st <= S_IDLE;
            if (nb == 5'd18) begin                                        // start, 16 bits, stop
              if (cmd[1:0] == 2'd3) begin
                case (lsh[8:1])
                  8'hFE: if (!collided) addr <= lsh[12:9];
                  8'hFD: ;                                                // no activator
                  8'h00: begin addr <= lsh[12:9]; srq_en <= lsh[14]; end
                  8'hFF: ;                                                // self-test
                  default: if (lsh[8:1] == DEF_HANDLER || lsh[8:1] == ALT_HANDLER) handler <= lsh[8:1];
                endcase
              end else begin
                listen_we <= 1; listen_reg <= cmd[1:0]; listen_data <= lsh[16:1];
              end
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  assign pull = drive;
  assign dbg = {st, cmd, srq_en, collided, drive, srq_on};

endmodule

// ---------------------------------------------------------------------
// se30_adb_kbd - the Apple Extended Keyboard, address 2, handler 2 (3 on request). PS/2 set-2
// codes map by key position: Alt is Command, Windows is Option, Insert is Help, PrtSc/ScrLk/Pause F13-F15.

module se30_adb_kbd #(
  parameter [15:0] CLK_KHZ = 16'd31334
) (
  input         clk,
  input         reset,
  input  [10:0] ps2_key,
  input         line,
  output        pull,
  output [15:0] dbg
);

  // the PS/2 set-2 code to the transition code; 8'hFF = no such key
  function [7:0] map(input ext, input [7:0] c);
    begin
      map = 8'hFF;
      if (!ext) case (c)
        8'h76: map = 8'h35;  8'h05: map = 8'h7A;  8'h06: map = 8'h78;  8'h04: map = 8'h63;   // Esc F1 F2 F3
        8'h0C: map = 8'h76;  8'h03: map = 8'h60;  8'h0B: map = 8'h61;  8'h83: map = 8'h62;   // F4 F5 F6 F7
        8'h0A: map = 8'h64;  8'h01: map = 8'h65;  8'h09: map = 8'h6D;  8'h78: map = 8'h67;   // F8 F9 F10 F11
        8'h07: map = 8'h6F;  8'h7E: map = 8'h6B;                                           // F12, Scroll Lock = F14
        8'h0E: map = 8'h32;  8'h16: map = 8'h12;  8'h1E: map = 8'h13;  8'h26: map = 8'h14;   // ` 1 2 3
        8'h25: map = 8'h15;  8'h2E: map = 8'h17;  8'h36: map = 8'h16;  8'h3D: map = 8'h1A;   // 4 5 6 7
        8'h3E: map = 8'h1C;  8'h46: map = 8'h19;  8'h45: map = 8'h1D;  8'h4E: map = 8'h1B;   // 8 9 0 -
        8'h55: map = 8'h18;  8'h66: map = 8'h33;                                           // = Delete
        8'h0D: map = 8'h30;  8'h15: map = 8'h0C;  8'h1D: map = 8'h0D;  8'h24: map = 8'h0E;   // Tab Q W E
        8'h2D: map = 8'h0F;  8'h2C: map = 8'h11;  8'h35: map = 8'h10;  8'h3C: map = 8'h20;   // R T Y U
        8'h43: map = 8'h22;  8'h44: map = 8'h1F;  8'h4D: map = 8'h23;  8'h54: map = 8'h21;   // I O P [
        8'h5B: map = 8'h1E;  8'h5D: map = 8'h2A;                                           // ] \
        8'h58: map = 8'h39;  8'h1C: map = 8'h00;  8'h1B: map = 8'h01;  8'h23: map = 8'h02;   // Caps A S D
        8'h2B: map = 8'h03;  8'h34: map = 8'h05;  8'h33: map = 8'h04;  8'h3B: map = 8'h26;   // F G H J
        8'h42: map = 8'h28;  8'h4B: map = 8'h25;  8'h4C: map = 8'h29;  8'h52: map = 8'h27;   // K L ; '
        8'h5A: map = 8'h24;                                                                // Return
        8'h12: map = 8'h38;  8'h1A: map = 8'h06;  8'h22: map = 8'h07;  8'h21: map = 8'h08;   // Shift Z X C
        8'h2A: map = 8'h09;  8'h32: map = 8'h0B;  8'h31: map = 8'h2D;  8'h3A: map = 8'h2E;   // V B N M
        8'h41: map = 8'h2B;  8'h49: map = 8'h2F;  8'h4A: map = 8'h2C;  8'h59: map = 8'h38;   // . / right Shift
        8'h14: map = 8'h36;  8'h11: map = 8'h37;  8'h29: map = 8'h31;                       // Ctl, Alt = Cmd, Space
        8'h77: map = 8'h47;  8'h7C: map = 8'h43;  8'h7B: map = 8'h4E;  8'h79: map = 8'h45;   // Clear * - +
        8'h6C: map = 8'h59;  8'h75: map = 8'h5B;  8'h7D: map = 8'h5C;                       // 7 8 9
        8'h6B: map = 8'h56;  8'h73: map = 8'h57;  8'h74: map = 8'h58;                       // 4 5 6
        8'h69: map = 8'h53;  8'h72: map = 8'h54;  8'h7A: map = 8'h55;                       // 1 2 3
        8'h70: map = 8'h52;  8'h71: map = 8'h41;                                           // 0 .
        default: ;
      endcase else case (c)
        8'h14: map = 8'h36;  8'h11: map = 8'h37;                                           // right Ctl, right Alt = Cmd
        8'h1F: map = 8'h3A;  8'h27: map = 8'h3A;                                           // Windows keys = Opt
        8'h70: map = 8'h72;  8'h6C: map = 8'h73;  8'h7D: map = 8'h74;                       // Insert = help, home, pgup
        8'h71: map = 8'h75;  8'h69: map = 8'h77;  8'h7A: map = 8'h79;                       // del., end, pgdn
        8'h75: map = 8'h3E;  8'h6B: map = 8'h3B;  8'h74: map = 8'h3C;  8'h72: map = 8'h3D;   // arrows
        8'h4A: map = 8'h4B;  8'h5A: map = 8'h4C;                                           // keypad / and Enter
        8'h7C: map = 8'h69;  8'h77: map = 8'h71;                                           // Print Screen = F13, Pause = F15
        default: ;
      endcase
    end
  endfunction

  // the right-hand modifiers, told apart only under handler 3
  function right_mod(input ext, input [7:0] c);
    right_mod = (!ext && c == 8'h59) || (ext && (c == 8'h14 || c == 8'h27));
  endfunction

  wire [3:0] addr;
  wire [7:0] handler;
  wire       r0_latch, r0_sent, listen_we, flush, dev_reset;
  wire [1:0] listen_reg;
  wire [15:0] listen_data;

  // ---------------------------------------------------------- the queue
  reg  [7:0] q [0:15];
  reg  [3:0] qh = 0, qt = 0;
  wire [3:0] qcount = qt - qh;
  reg  [1:0] took = 0;                      // how many the latched Talk carried

  reg        caps = 0;                      // Caps Lock locked
  reg        ps2_q = 0;
  reg  [2:0] leds = 3'b111;                 // bits 2-0, 0 = on

  // register 2: 14 Delete, 13 Caps Lock, 12 Reset, 11 Control, 10 Shift, 9 Option, 8 Command,
  // 7 Num Lock/Clear, 6 Scroll Lock, 2-0 the LEDs
  reg del_n = 1, ctl_n = 1, shf_n = 1, opt_n = 1, cmd_n = 1, clr_n = 1, scr_n = 1;
  wire [15:0] r2 = {1'b1, del_n, !caps, 1'b1, ctl_n, shf_n, opt_n, cmd_n, clr_n, scr_n, 3'b111, leds};

  wire       has_r0 = qcount != 0;
  wire [15:0] r0 = {q[qh], (qcount >= 2) ? q[qh + 1'b1] : 8'hFF};

  wire [7:0] code = map(ps2_key[8], ps2_key[7:0]);
  wire [7:0] tcode = (handler == 8'd3 && right_mod(ps2_key[8], ps2_key[7:0]))
                   ? ((code == 8'h38) ? 8'h7B : (code == 8'h3A) ? 8'h7C : 8'h7D) : code;

  always @(posedge clk) begin
    ps2_q <= ps2_key[10];
    if (reset || dev_reset || flush) begin
      qh <= 0; qt <= 0;
      if (reset || dev_reset) leds <= 3'b111;
    end else begin
      if (r0_latch) took <= (qcount >= 2) ? 2'd2 : 2'd1;
      if (r0_sent) qh <= qh + took;
      if (ps2_key[10] != ps2_q && code != 8'hFF) begin
        if (code == 8'h39) begin
          // Caps Lock locks: a press toggles it, a release does nothing
          if (ps2_key[9]) begin
            caps <= !caps;
            if (qcount != 4'd15) begin q[qt] <= caps ? 8'hB9 : 8'h39; qt <= qt + 1'b1; end
          end
        end else if (qcount != 4'd15) begin
          q[qt] <= {!ps2_key[9], tcode[6:0]}; qt <= qt + 1'b1;
        end
        case (code)
          8'h33: del_n <= !ps2_key[9];
          8'h36: ctl_n <= !ps2_key[9];
          8'h38: shf_n <= !ps2_key[9];
          8'h3A: opt_n <= !ps2_key[9];
          8'h37: cmd_n <= !ps2_key[9];
          8'h47: clr_n <= !ps2_key[9];
          8'h6B: scr_n <= !ps2_key[9];
          default: ;
        endcase
      end
      if (listen_we && listen_reg == 2'd2) leds <= listen_data[2:0];
    end
  end

  se30_adb_engine #(.CLK_KHZ(CLK_KHZ), .DEF_ADDR(4'd2), .DEF_HANDLER(8'd2), .ALT_HANDLER(8'd3)) eng (
    .clk(clk), .reset(reset), .line(line), .pull(pull),
    .has_r0(has_r0), .r0_word(r0), .has_r2(1'b1), .r2_word(r2),
    .r0_latch(r0_latch), .r0_sent(r0_sent),
    .listen_we(listen_we), .listen_reg(listen_reg), .listen_data(listen_data),
    .flush(flush), .dev_reset(dev_reset), .addr(addr), .handler(handler), .dbg(dbg));

endmodule

// ---------------------------------------------------------------------
// se30_adb_mouse - the Apple Standard Mouse, address 3, handler 1 (100 cpi; 2 = 200 on request):
// PS/2 motion accumulates between Talks, each axis sent clamped to -64..+63.

module se30_adb_mouse #(
  parameter [15:0] CLK_KHZ = 16'd31334
) (
  input         clk,
  input         reset,
  input  [24:0] ps2_mouse,
  input         line,
  output        pull,
  output [15:0] dbg
);

  wire [3:0] addr;
  wire [7:0] handler;
  wire       r0_latch, r0_sent, listen_we, flush, dev_reset;
  wire [1:0] listen_reg;
  wire [15:0] listen_data;

  reg signed [11:0] dx = 0, dy = 0;         // accumulated, ADB's sense (down, right positive)
  reg               btn = 0, btn_sent = 0;
  reg               ps2_q = 0;
  reg signed  [6:0] sx = 0, sy = 0;         // what the latched Talk carries
  reg               sbtn = 0;

  function signed [6:0] clamp7(input signed [11:0] v);
    clamp7 = (v > 12'sd63) ? 7'sd63 : (v < -12'sd64) ? 7'b1000000 : v[6:0];   // -64
  endfunction

  wire signed [8:0] px = {ps2_mouse[4], ps2_mouse[15:8]};
  wire signed [8:0] py = {ps2_mouse[5], ps2_mouse[23:16]};
  wire signed [11:0] ax = (handler == 8'd2) ? {{2{px[8]}}, px, 1'b0} : {{3{px[8]}}, px};
  wire signed [11:0] ay = (handler == 8'd2) ? {{2{py[8]}}, py, 1'b0} : {{3{py[8]}}, py};

  wire has_r0 = dx != 0 || dy != 0 || btn != btn_sent;
  wire [15:0] r0 = {!btn, clamp7(dy), 1'b1, clamp7(dx)};

  function signed [11:0] sat(input signed [12:0] v);
    sat = (v > 13'sd2047) ? 12'sd2047 : (v < -13'sd2048) ? 12'h800 : v[11:0];   // -2048
  endfunction

  always @(posedge clk) begin
    ps2_q <= ps2_mouse[24];
    if (reset || dev_reset || flush) begin
      dx <= 0; dy <= 0; btn_sent <= btn;
    end else begin
      if (r0_latch) begin sx <= clamp7(dx); sy <= clamp7(dy); sbtn <= btn; end
      if (ps2_mouse[24] != ps2_q) begin
        // new motion, less anything a Talk completing now takes
        dx <= sat({dx[11], dx} + {ax[11], ax} - (r0_sent ? {{6{sx[6]}}, sx} : 13'sd0));
        dy <= sat({dy[11], dy} - {ay[11], ay} - (r0_sent ? {{6{sy[6]}}, sy} : 13'sd0));
        btn <= ps2_mouse[0];
      end else if (r0_sent) begin
        dx <= dx - {{5{sx[6]}}, sx};
        dy <= dy - {{5{sy[6]}}, sy};
      end
      if (r0_sent) btn_sent <= sbtn;
    end
  end

  se30_adb_engine #(.CLK_KHZ(CLK_KHZ), .DEF_ADDR(4'd3), .DEF_HANDLER(8'd1), .ALT_HANDLER(8'd2)) eng (
    .clk(clk), .reset(reset), .line(line), .pull(pull),
    .has_r0(has_r0), .r0_word(r0), .has_r2(1'b0), .r2_word(16'h0000),
    .r0_latch(r0_latch), .r0_sent(r0_sent),
    .listen_we(listen_we), .listen_reg(listen_reg), .listen_data(listen_data),
    .flush(flush), .dev_reset(dev_reset), .addr(addr), .handler(handler), .dbg(dbg));

endmodule
