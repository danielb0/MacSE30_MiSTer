// tb_se30_adb_dev.v - the ADB keyboard and mouse on a modelled line, held
// to the Guide's chapter 8 by a host that speaks Table 8-14 (SE30_PLAN.md
// 6.4; the device half of 6.9 item 6, runnable without the transceiver's
// program).
//
// WHAT THIS PROVES
//   rtl/se30_adb_dev.v's devices answer an ADB host as the Guide
//   specifies:
//
//     a. Talk register 3: the keyboard $6202 and the mouse $6301 (Table
//        8-15: bit 14 1, SRQ enable 1, address, handler); an empty
//        address times out
//     b. the reply's timing on the wire: 140-260 us from the stop bit's
//        rise to the start bit's fall; "1" low 35 us and "0" 65 us, +/-5%
//        of the cell; the cell 100 us; the stop bit's low 70 us  Table 8-14
//     c. the keyboard: a key down and up through Talk register 0, two
//        transitions in one reply, $FF in an empty slot (Table 8-10); the
//        Service Request - the keyboard with a key waiting holds the stop
//        bit of a Talk to the mouse low for 300 us (Figure 8-15); none when
//        it is itself the one told to Talk
//     d. the mouse: motion and the button through register 0, Y inverted
//        to the Mac's sense, each axis clamped to +/-63 with the remainder
//        kept, no reply when nothing moved (Table 8-4)
//     e. Listen register 3: $FE moves the mouse to address 5 (no collision
//        seen); a new handler stored when supported (keyboard 3, then the
//        right Shift sends $7B, Table 8-9), ignored when not
//     f. Listen register 2 sets the keyboard's LEDs, read back in
//        register 2 (Table 8-11); the modifiers there, 0 = down
//     g. Flush empties the keyboard; SendReset and a Global Reset (3.2 ms
//        low) return both devices to their defaults
//     h. a collision: two keyboards at one address with different keys
//        waiting; the one whose released line is pulled low stops, and the
//        other's reply arrives intact (p. 324)
//
// THE HOST
//   Nominal Table 8-14 timing: Attention 800 us, Sync 65 us, "0" 65/35,
//   "1" 35/65, stop 70 us low.  After a Talk it waits 260 us for a start
//   bit (the maximum stop-to-start time) and then decodes bits by low time
//   until the line has been high 150 us.
//
// CLOCK
//   CLK_KHZ = 4000 (one clock is 250 ns) to keep the bench fast; the
//   engine's microsecond tick is derived from it as it is from clk_sys.

`timescale 1ns/1ps

module tb_se30_adb_dev;

  localparam CLK_KHZ = 4000;
  reg clk = 0;
  always #125 clk = ~clk;

  reg        reset = 1, reset2 = 1;
  reg        host_pull = 0;
  wire       kbd_pull, kbd2_pull, mouse_pull;
  wire       line = !(host_pull | kbd_pull | kbd2_pull | mouse_pull);
  reg [10:0] ps2_key = 0, ps2_key2 = 0;
  reg [24:0] ps2_mouse = 0;

  se30_adb_kbd   #(.CLK_KHZ(CLK_KHZ)) kbd   (.clk(clk), .reset(reset),  .ps2_key(ps2_key),  .line(line), .pull(kbd_pull),  .dbg());
  se30_adb_kbd   #(.CLK_KHZ(CLK_KHZ)) kbd2  (.clk(clk), .reset(reset2), .ps2_key(ps2_key2), .line(line), .pull(kbd2_pull), .dbg());
  se30_adb_mouse #(.CLK_KHZ(CLK_KHZ)) mouse (.clk(clk), .reset(reset),  .ps2_mouse(ps2_mouse), .line(line), .pull(mouse_pull), .dbg());

  // ------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*80-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask
  task is(input [8*80-1:0] what, input integer got, input integer want);
    begin check(got == want, what, got, want); end
  endtask

  // ------------------------------------------------ the host
  task low_us(input integer us);  begin host_pull = 1; #(us * 1000); end endtask
  task high_us(input integer us); begin host_pull = 0; #(us * 1000); end endtask
  task hbit(input b); begin if (b) begin low_us(35); high_us(65); end else begin low_us(65); high_us(35); end end endtask

  // the stop bit: low 70 us, then released.  srq_low = how long the line
  // stayed low from the stop's fall (70 without a service request)
  integer srq_low;
  task hstop;
    integer t0;
    begin
      t0 = $time;
      low_us(70); host_pull = 0;
      while (!line) #1000;
      srq_low = ($time - t0) / 1000;
    end
  endtask

  task command(input [7:0] c);
    integer n;
    begin
      low_us(800); high_us(65);                           // Attention, Sync
      for (n = 7; n >= 0; n = n - 1) hbit(c[n]);
      hstop;
    end
  endtask

  // after a Talk: take the reply, if any.  got_bits = the number of bits
  // (start + 16 + stop = 18 for a register); rbits their values.  The
  // reply's timing is measured as it comes.
  integer got_bits, resp_us, low_min1, low_max1, low_min0, low_max0, stop_low, cell_min, cell_max;
  reg [63:0] rbits;
  task talk(input [3:0] a, input [1:0] r, output [15:0] word, output ok);
    integer nbits;
    begin
      command({a, 2'b11, r});
      take_reply_named;
      nbits = got_bits;
      ok = (nbits == 18);                                  // start + 16 + stop
      word = rbits[16:1];
    end
  endtask

  // the reply reader
  task take_reply_named;
    integer t_rise, t_fall, t_prevfall, lo, n;
    reg first, done;
    begin
      got_bits = 0; rbits = 0; resp_us = -1;
      low_min1 = 999; low_max1 = 0; low_min0 = 999; low_max0 = 0; cell_min = 999; cell_max = 0;
      t_rise = $time;
      while (line && ($time - t_rise) < 260_000) #250;
      if (!line) begin
        resp_us = ($time - t_rise) / 1000;
        n = 0; first = 1; done = 0; t_prevfall = $time;
        while (!done) begin
          t_fall = $time;
          if (!first) begin
            if ((t_fall - t_prevfall) / 1000 < cell_min) cell_min = (t_fall - t_prevfall) / 1000;
            if ((t_fall - t_prevfall) / 1000 > cell_max) cell_max = (t_fall - t_prevfall) / 1000;
          end
          t_prevfall = t_fall;
          while (!line) #250;
          lo = ($time - t_fall) / 1000;
          rbits = {rbits[62:0], lo < 50};
          n = n + 1; first = 0; stop_low = lo;
          if (n > 1) begin                                   // not the start bit's
            if (lo < 50) begin if (lo < low_min1) low_min1 = lo; if (lo > low_max1) low_max1 = lo; end
            else if (lo < 69) begin if (lo < low_min0) low_min0 = lo; if (lo > low_max0) low_max0 = lo; end
          end
          t_rise = $time;
          while (line && ($time - t_rise) < 150_000) #250;
          if (line) done = 1;
          else if (n >= 64) done = 1;
        end
        got_bits = n;
      end
    end
  endtask

  task listen(input [3:0] a, input [1:0] r, input [15:0] word);
    integer n;
    begin
      command({a, 2'b10, r});
      high_us(200);
      hbit(1'b1);                                          // start
      for (n = 15; n >= 0; n = n - 1) hbit(word[n]);
      low_us(70); host_pull = 0;                           // stop
      high_us(300);
    end
  endtask

  task key(input ext, input [7:0] c, input down);
    begin ps2_key = {~ps2_key[10], down, ext, c}; #20_000; end
  endtask
  task move(input signed [8:0] x, input signed [8:0] y, input b);
    begin ps2_mouse = {~ps2_mouse[24], y[7:0], x[7:0], 2'b00, y[8], x[8], 3'b000, b}; #20_000; end
  endtask

  // ------------------------------------------------ the tests
  reg [15:0] w;
  reg        ok;
  integer n;

  initial begin
    #5_000; reset = 0;
    high_us(500);

    // ============ a. Talk register 3
    talk(4'd2, 2'd3, w, ok); is("a: keyboard Talk R3 answers", ok, 1); is("a: keyboard R3 = $6202", w, 16'h6202);
    // ============ b. the timing of that reply
    check(resp_us >= 140 && resp_us <= 260, "b: stop rise to start fall 140-260 us", resp_us, 200);
    check(low_min1 >= 33 && low_max1 <= 37, "b: a '1' low 35 us +/-5% of the cell", low_max1, 35);
    check(low_min0 >= 63 && low_max0 <= 67, "b: a '0' low 65 us +/-5% of the cell", low_max0, 65);
    check(cell_min >= 97 && cell_max <= 103, "b: the bit cell 100 us", cell_max, 100);
    check(stop_low >= 68 && stop_low <= 72, "b: the stop bit's low 70 us", stop_low, 70);
    talk(4'd3, 2'd3, w, ok); is("a: mouse Talk R3 answers", ok, 1); is("a: mouse R3 = $6301", w, 16'h6301);
    talk(4'd5, 2'd3, w, ok); is("a: nobody at 5: time-out", got_bits, 0);
    // no data: the mouse stays silent on register 0
    talk(4'd3, 2'd0, w, ok); is("d: mouse, nothing moved: no reply", got_bits, 0);
    check(srq_low >= 68 && srq_low <= 74, "c: no service request with nothing waiting (stop low 70)", srq_low, 70);

    // ============ c. the keyboard
    key(0, 8'h1C, 1);                                      // A down
    talk(4'd3, 2'd0, w, ok);                               // a Talk to the mouse
    check(srq_low >= 280 && srq_low <= 320, "c: the keyboard's service request, 300 us", srq_low, 300);
    talk(4'd2, 2'd0, w, ok);
    check(srq_low >= 68 && srq_low <= 74, "c: no service request from the device told to Talk", srq_low, 70);
    is("c: keyboard R0 answers", ok, 1); is("c: A down = $00, empty slot $FF", w, 16'h00FF);
    key(0, 8'h1C, 0); key(0, 8'h1B, 1);                    // A up, S down
    talk(4'd2, 2'd0, w, ok); is("c: two transitions: A up $80, S down $01", w, 16'h8001);
    talk(4'd2, 2'd0, w, ok); is("c: the queue is empty after", got_bits, 0);
    key(0, 8'h1B, 0);
    talk(4'd2, 2'd0, w, ok); is("c: S up", w, 16'h81FF);
    key(1, 8'h75, 1); key(1, 8'h75, 0);                    // up arrow (extended)
    talk(4'd2, 2'd0, w, ok); is("c: up arrow $3E down and up", w, 16'h3EBE);
    key(0, 8'h58, 1); key(0, 8'h58, 0);                    // Caps Lock pressed: locks
    talk(4'd2, 2'd0, w, ok); is("c: Caps Lock locks: down only", w, 16'h39FF);
    talk(4'd2, 2'd2, w, ok); is("f: register 2 shows Caps Lock (bit 13 = 0)", w[13], 0);
    key(0, 8'h58, 1); key(0, 8'h58, 0);                    // and unlocks
    talk(4'd2, 2'd0, w, ok); is("c: Caps Lock unlocks: up", w, 16'hB9FF);

    // ============ d. the mouse
    move(9'sd10, 9'sd3, 1'b0);                             // right 10, up 3
    talk(4'd3, 2'd0, w, ok);
    is("d: mouse R0 answers", ok, 1);
    is("d: button up (bit 15 = 1)", w[15], 1);
    is("d: bit 7 always 1", w[7], 1);
    is("d: X +10", w[6:0], 7'd10);
    is("d: Y up 3 = -3", w[14:8], 7'h7D);
    move(9'sd100, -9'sd5, 1'b1);                           // right 100, down 5, button down
    talk(4'd3, 2'd0, w, ok);
    is("d: button down (bit 15 = 0)", w[15], 0);
    is("d: X clamped +63", w[6:0], 7'd63);
    is("d: Y down 5 = +5", w[14:8], 7'd5);
    talk(4'd3, 2'd0, w, ok);
    is("d: the remainder, +37", w[6:0], 7'd37);
    is("d: Y done", w[14:8], 7'd0);
    move(9'sd0, 9'sd0, 1'b0);                              // release
    talk(4'd3, 2'd0, w, ok); is("d: button up alone is data", w, 16'h8080);
    talk(4'd3, 2'd0, w, ok); is("d: then nothing", got_bits, 0);

    // ============ e. Listen register 3
    listen(4'd3, 2'd3, 16'h05FE);                          // move to 5 if no collision
    talk(4'd3, 2'd3, w, ok); is("e: nobody at 3 after the move", got_bits, 0);
    talk(4'd5, 2'd3, w, ok); is("e: the mouse at 5: $6501", w, 16'h6501);
    listen(4'd5, 2'd3, 16'h0502);                          // handler 2 (200 cpi)
    talk(4'd5, 2'd3, w, ok); is("e: mouse handler 2 stored", w, 16'h6502);
    listen(4'd5, 2'd3, 16'h0507);                          // unsupported
    talk(4'd5, 2'd3, w, ok); is("e: unsupported handler ignored", w, 16'h6502);
    move(9'sd4, 9'sd0, 1'b0);
    talk(4'd5, 2'd0, w, ok); is("d: handler 2 doubles the counts", w[6:0], 7'd8);
    listen(4'd2, 2'd3, 16'h0203);                          // keyboard handler 3
    talk(4'd2, 2'd3, w, ok); is("e: keyboard handler 3", w, 16'h6203);
    key(0, 8'h59, 1); key(0, 8'h59, 0);                    // right Shift
    talk(4'd2, 2'd0, w, ok); is("e: handler 3: right Shift $7B", w, 16'h7BFB);
    key(0, 8'h12, 1); key(0, 8'h12, 0);                    // left Shift
    talk(4'd2, 2'd0, w, ok); is("e: left Shift still $38", w, 16'h38B8);

    // ============ f. Listen register 2: the LEDs; the modifiers
    listen(4'd2, 2'd2, 16'hFFFA);                          // LED 0 and 2 on (0 = on)
    talk(4'd2, 2'd2, w, ok); is("f: LEDs read back", w[2:0], 3'b010);
    key(0, 8'h14, 1);                                      // Control down
    talk(4'd2, 2'd2, w, ok); is("f: Control down in register 2 (bit 11 = 0)", w[11], 0);
    key(0, 8'h14, 0);
    talk(4'd2, 2'd2, w, ok); is("f: Control up", w[11], 1);

    // ============ g. Flush, SendReset, Global Reset
    key(0, 8'h1C, 1); key(0, 8'h1C, 0);
    command(8'h21);                                        // Flush address 2
    talk(4'd2, 2'd0, w, ok);
    // (the Control transitions of f are also flushed)
    is("g: Flush empties the keyboard", got_bits, 0);
    command(8'h00);                                        // SendReset
    high_us(300);
    talk(4'd3, 2'd3, w, ok); is("g: SendReset: the mouse back at 3, handler 1", w, 16'h6301);
    talk(4'd2, 2'd3, w, ok); is("g: SendReset: keyboard handler 2", w, 16'h6202);
    listen(4'd3, 2'd3, 16'h07FE);                          // move the mouse away again
    low_us(3200); high_us(300);                            // Global Reset
    talk(4'd3, 2'd3, w, ok); is("g: Global Reset: the mouse back at 3", w, 16'h6301);

    // ============ h. a collision: a second keyboard at address 2
    #5_000; reset2 = 0; high_us(300);
    key(0, 8'h1C, 1);                                      // keyboard 1: A down ($00)
    ps2_key2 = {~ps2_key2[10], 1'b1, 1'b0, 8'h1B}; #20_000; // keyboard 2: S down ($01)
    talk(4'd2, 2'd0, w, ok);
    // $00FF against $01FF: they part at bit 8 of the word, where keyboard
    // 1 sends 0 (holding the line low) and keyboard 2 releases for a 1 and
    // finds the line low - keyboard 2 loses
    is("h: the reply arrives intact", ok, 1);
    is("h: keyboard 1 (A down) wins", w, 16'h00FF);
    is("h: keyboard 2 kept its data and set its collision flag", kbd2.eng.collided, 1);
    talk(4'd2, 2'd0, w, ok);
    is("h: keyboard 2's key on the next Talk", w, 16'h01FF);

    $display("---- %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  initial begin #2_000_000_000 $display("==== FAIL (timeout)"); $finish; end

endmodule
