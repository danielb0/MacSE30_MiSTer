// tb_se30_rtc.v - the SE/30's clock chip (UK4, 344S0042-B) held to
// SE30_PLAN.md 6.5, items 8-12 of 6.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_rtc.v answers the ROM's own bit-bang routines, replayed
//   write for write, as Inside Macintosh (hardware chapter, 1985, pp.
//   28-29) and the ROM (6.5.1) describe the chip:
//
//     8. every command of Inside Macintosh's table, read and write, and
//        the seconds through the ROM's own form (z001aa01); Inside
//        Macintosh's reader as well as the ROM's (it pins the falling
//        edge); the
//        extended command at the corners of the 256 bytes; the original
//        20 bytes aliased onto xPRAM $10-$1F and $08-$0B (a byte written
//        through one form read back through the other)
//     9. write protect: set, a write refused through each form (and the
//        test register's); cleared, the write lands; the protect
//        register itself always writable
//    10. InitUtil ($4080DBE8) replayed from a zero RAM: the ROM's 20
//        defaults written, 'NuMc' at $0C, $20-$07 cleared, 20 bytes at
//        $76; replayed again against what the first left: nothing
//        written (the validity byte $A8 and 'NuMc' are found)
//    11. the seconds: loaded from TIMESTAMP (+2,082,844,800, the Unix to
//        Macintosh epoch) on its first toggle only, one increment per
//        CLK_HZ clocks, 1HZ falling at each increment; read twice, the
//        ROM's way ($4080DCA6)
//    12. CS* raised mid-byte aborts: no write lands
//
// THE HOST
//   The bench is VIA1's port B as the ROM drives it: ORB and DDRB bits 2
//   (CS*), 1 (clock) and 0 (data).  A pin is the ORB bit when its DDRB bit
//   is 1, else the chip's drive when the chip drives, else 1 (4.5: an
//   undriven port line reads high).  Each VIA access is 40 clocks apart -
//   a VIA cycle is about 1.3 us at C16M (4.4) and clk here is 2 x C16M -
//   so the chip sees the ROM's edges at the machine's spacing, roughly.
//
//   The routines are the ROM's, transcribed from the disassembly:
//     rom_send ($4080DE32)  per bit: ORB := {CS 0, clock 0, data}, then
//                            BSET of the clock - data set with the clock
//                            low, taken on the rising edge
//     rom_recv ($4080DE44)  DDRB bit 0 cleared; per bit: ORB clock low,
//                            ORB clock high, read ORB - the chip drives
//                            from the falling edge; DDRB bit 0 set after
//     rom_xfer ($4080DDD6)  CS* low with the first write; one command
//                            byte, or two when (cmd & $78) = $38; then
//                            send or receive a data byte by bit 7 of the
//                            first; BSET of CS* ($4080DE2C)
//     tm_bit   ($40803502)  the test manager's routine: read ORB, then
//                            write {clock 0, data}, then clock 1 - its
//                            read comes before the falling edge
//
// CLOCK
//   CLK_HZ = 1,000,000 here, so a "second" is a million clocks - long
//   enough that the seconds do not tick while item 8 writes and reads
//   them back; the machine instances it with clk_sys's 31,334,400.

`timescale 1ns/1ps

module tb_se30_rtc;

  reg clk = 0;
  always #16 clk = ~clk;

  localparam CLK_HZ = 1_000_000;

  // ------------------------------------------------ VIA1 port B, bits 2-0
  reg [2:0] orb  = 3'b111;
  reg [2:0] ddrb = 3'b111;               // the ROM's VIA initialisation: $87 (4.6 item 8)
  wire      d_out, d_oe, one_hz;
  wire [2:0] pin = { ddrb[2] ? orb[2] : 1'b1,
                     ddrb[1] ? orb[1] : 1'b1,
                     ddrb[0] ? orb[0] : (d_oe ? d_out : 1'b1) };
  reg [32:0] timestamp = 0;
  wire [31:0] dbg;

  se30_rtc #(.CLK_HZ(CLK_HZ)) dut (
    .clk(clk), .timestamp(timestamp),
    .cs_n(pin[2]), .sck(pin[1]), .d_in(pin[0]), .d_out(d_out), .d_oe(d_oe),
    .one_hz(one_hz), .dbg(dbg));

  // contention: the chip must never begin to drive while the VIA drives.
  // (The ROM itself makes PB0 an output before raising CS*, so the tail
  // of a read overlaps by one VIA access - the ROM's order, not a fault.)
  integer clashes = 0;
  reg     oe_q = 0;
  always @(posedge clk) begin
    oe_q <= d_oe;
    if (d_oe && !oe_q && ddrb[0]) clashes = clashes + 1;
  end

  // ------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*72-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask
  task is(input [8*72-1:0] what, input integer got, input integer want);
    begin check(got == want, what, got, want); end
  endtask

  // ------------------------------------------------ the ROM's routines
  task via_gap; begin repeat (40) @(posedge clk); end endtask
  task wr_orb(input [2:0] v); begin via_gap; orb = v; end endtask
  task rd_orb(output [2:0] v); begin via_gap; v = pin; end endtask

  task rom_send(input [7:0] byt);
    integer n;
    begin
      for (n = 7; n >= 0; n = n - 1) begin
        wr_orb({1'b0, 1'b0, byt[n]});                  // move.b d3,(a1): CS* 0, clock 0, data
        wr_orb({1'b0, 1'b1, byt[n]});                  // bset d4,(a1): clock 1
      end
    end
  endtask

  task rom_recv(output [7:0] byt);
    integer n;
    reg [2:0] v;
    begin
      via_gap; ddrb[0] = 0;                            // bclr #0,$400(a1)
      for (n = 7; n >= 0; n = n - 1) begin
        wr_orb({1'b0, 1'b0, orb[0]});                  // move.b d3,(a1): clock low
        wr_orb({1'b0, 1'b1, orb[0]});                  // move.b d4,(a1): clock high
        rd_orb(v); byt[n] = v[0];                      // move.b (a1),d1
      end
      via_gap; ddrb[0] = 1;                            // bset #0,$400(a1)
    end
  endtask

  // Inside Macintosh's own read procedure (p. 29): "lower the data-clock
  // (rTCClk) and read the first (high-order) bit ... Then raise the
  // data-clock, lower it again, and read the next bit" - it reads with the
  // clock low, which the ROM's reader does not, so it pins the edge the
  // chip drives on
  task im_recv(output [7:0] byt);
    integer n;
    reg [2:0] v;
    begin
      via_gap; ddrb[0] = 0;
      for (n = 7; n >= 0; n = n - 1) begin
        wr_orb({1'b0, 1'b0, orb[0]});                  // lower the clock
        rd_orb(v); byt[n] = v[0];                      // read
        wr_orb({1'b0, 1'b1, orb[0]});                  // raise it
      end
      wr_orb({1'b1, orb[1:0]});                        // raise CS*, then
      via_gap; ddrb[0] = 1;                            // the port back to output
    end
  endtask

  // one transaction: cmd (one byte, or two when cmd[7:0] & $78 = $38 -
  // cmd2 is then the second), data written or read by cmd bit 7
  task rom_xfer(input [7:0] cmd, input [7:0] cmd2, input [7:0] wdata, output [7:0] rdata);
    begin
      rdata = 8'hxx;
      rom_send(cmd);
      if ((cmd & 8'h78) == 8'h38) rom_send(cmd2);
      if (cmd[7]) rom_recv(rdata); else rom_send(wdata);
      wr_orb({1'b1, orb[1:0]});                        // bset #2,(a1)
    end
  endtask

  reg [7:0] rd;
  task wr1(input [7:0] cmd, input [7:0] v);   begin rom_xfer(cmd, 8'h00, v, rd); end endtask
  task rd1(input [7:0] cmd, output [7:0] v);  begin rom_xfer(cmd, 8'h00, 8'h00, v); end endtask
  // extended: address a
  task xwr(input [7:0] a, input [7:0] v);  begin rom_xfer({5'b00111, a[7:5]}, {1'b0, a[4:0], 2'b00}, v, rd); end endtask
  task xrd(input [7:0] a, output [7:0] v); begin rom_xfer({5'b10111, a[7:5]}, {1'b0, a[4:0], 2'b00}, 8'h00, v); end endtask
  task wp_off; begin wr1(8'h35, 8'h55); end endtask   // $4080DD1A
  task wp_on;  begin wr1(8'h35, 8'hD5); end endtask   // $4080DD12
  // the original 20 bytes: RAM $00-$0F = z1aaaa01, $10-$13 = z010aa01
  function [7:0] lcmd(input rd_, input [4:0] a);
    lcmd = a[4] ? {rd_, 3'b010, a[1:0], 2'b01} : {rd_, 1'b1, a[3:0], 2'b01};
  endfunction

  // the test manager's routine: 8 bits of d1 out, 8 bits in
  task tm_byte(input [7:0] out, output [7:0] in);
    integer n;
    reg [2:0] v;
    begin
      for (n = 7; n >= 0; n = n - 1) begin
        rd_orb(v); in[n] = v[0];
        wr_orb({1'b0, 1'b0, out[n]});
        wr_orb({1'b0, 1'b1, out[n]});
      end
    end
  endtask

  // ------------------------------------------------ InitUtil ($4080DBE8)
  // the ROM's defaults ($4080DBD4) and the xPRAM block ($4080DC92)
  reg [7:0] dflt [0:19];
  reg [7:0] xblk [0:19];
  reg [7:0] sysparam [0:19];
  integer writes_seen;
  task init_util;
    integer n;
    reg [7:0] v;
    reg [31:0] numc;
    begin
      wp_off; wr1(8'h31, 8'h00); wp_on;                 // $4080DBEA-$4080DBF6
      for (n = 0; n < 20; n = n + 1) begin              // $4080DBB0: the 20 bytes
        rd1(lcmd(1'b1, n[4:0]), v); sysparam[n] = v;
      end
      if (sysparam[0] != 8'hA8) begin                   // $4080DC06
        wp_off;                                          // $4080DD22
        for (n = 0; n < 20; n = n + 1) wr1(lcmd(1'b0, n[4:0]), dflt[n]);
        wp_on;
      end
      for (n = 0; n < 4; n = n + 1) begin xrd(8'h0C + n, v); numc = {numc[23:0], v}; end
      if (numc != 32'h4E754D63) begin                   // 'NuMc'
        wp_off;
        xwr(8'h0C, 8'h4E); xwr(8'h0D, 8'h75); xwr(8'h0E, 8'h4D); xwr(8'h0F, 8'h63);
        for (n = 8'h20; n != 8'h08; n = (n + 1) & 8'hFF) xwr(n[7:0], 8'h00);
        for (n = 0; n < 20; n = n + 1) xwr(8'h76 + n, xblk[n]);
        wp_on;
      end
    end
  endtask

  // ------------------------------------------------ the tests
  integer n, t0;
  reg [7:0] v, v2;
  reg [31:0] s1, s2;

  initial begin
    {dflt[0], dflt[1], dflt[2], dflt[3], dflt[4], dflt[5], dflt[6], dflt[7], dflt[8], dflt[9]} =
      80'hA8_00_00_00_CC_0A_CC_0A_00_00;
    {dflt[10], dflt[11], dflt[12], dflt[13], dflt[14], dflt[15], dflt[16], dflt[17], dflt[18], dflt[19]} =
      80'h00_00_00_02_63_00_03_88_00_4C;
    {xblk[0], xblk[1], xblk[2], xblk[3], xblk[4], xblk[5], xblk[6], xblk[7], xblk[8], xblk[9]} =
      80'h00_01_FF_FF_FF_DF_00_00_00_00;
    for (n = 10; n < 20; n = n + 1) xblk[n] = 8'h00;
    repeat (20) @(posedge clk);

    // ======================== 8: the commands
    wp_off;
    // the seconds, written low byte first (Inside Macintosh's order)
    wr1(8'h01, 8'h44); wr1(8'h05, 8'h33); wr1(8'h09, 8'h22); wr1(8'h0D, 8'h11);
    rd1(8'h81, v); is("seconds 0 read back", v, 8'h44);
    rd1(8'h85, v); is("seconds 1", v, 8'h33);
    rd1(8'h89, v); is("seconds 2", v, 8'h22);
    rd1(8'h8D, v); is("seconds 3", v, 8'h11);
    // the original RAM, every byte
    for (n = 0; n < 20; n = n + 1) wr1(lcmd(1'b0, n[4:0]), 8'hC0 + n);
    for (n = 0; n < 20; n = n + 1) begin
      rd1(lcmd(1'b1, n[4:0]), v);
      check(v == 8'hC0 + n, "original RAM byte read back", v, 8'hC0 + n);
    end
    // the aliasing: original $00-$0F = xPRAM $10-$1F, $10-$13 = $08-$0B
    xrd(8'h10, v); is("original $00 = xPRAM $10", v, 8'hC0);
    xrd(8'h1F, v); is("original $0F = xPRAM $1F", v, 8'hCF);
    xrd(8'h08, v); is("original $10 = xPRAM $08", v, 8'hD0);
    xrd(8'h0B, v); is("original $13 = xPRAM $0B", v, 8'hD3);
    xwr(8'h12, 8'h5E); rd1(lcmd(1'b1, 5'h02), v); is("xPRAM $12 = original $02", v, 8'h5E);
    rom_send(lcmd(1'b1, 5'h07)); im_recv(v);
    is("Inside Macintosh's reader (clock low): the chip drives from the fall", v, 8'hC7);
    // the extended command at the corners
    xwr(8'h00, 8'hA0); xwr(8'h07, 8'hA7); xwr(8'h0C, 8'hAC); xwr(8'hFF, 8'hAF); xwr(8'h80, 8'hA8);
    xrd(8'h00, v); is("xPRAM $00", v, 8'hA0);
    xrd(8'h07, v); is("xPRAM $07 (not the seconds)", v, 8'hA7);
    xrd(8'h0C, v); is("xPRAM $0C (not the test register)", v, 8'hAC);
    xrd(8'hFF, v); is("xPRAM $FF", v, 8'hAF);
    xrd(8'h80, v); is("xPRAM $80", v, 8'hA8);
    rd1(8'h81, v); is("the extended $00-$07 left the seconds alone", v, 8'h44);
    is("no contention on the data line", clashes, 0);

    // ======================== 9: write protect
    wp_on;
    wr1(lcmd(1'b0, 5'h03), 8'h00); rd1(lcmd(1'b1, 5'h03), v);
    is("protected: an original-form write refused", v, 8'hC3);
    xwr(8'h40, 8'h99); xrd(8'h40, v);
    is("protected: an extended write refused (Inside Macintosh's rule)", v, 8'h00);
    wr1(8'h01, 8'h00); rd1(8'h81, v);
    is("protected: a seconds write refused", v, 8'h44);
    wp_off;
    xwr(8'h40, 8'h99); xrd(8'h40, v);
    is("unprotected: the extended write lands", v, 8'h99);

    // ======================== 12: CS* mid-byte aborts
    rom_send(lcmd(1'b0, 5'h05));                        // the command, then four data bits
    for (n = 7; n >= 4; n = n - 1) begin wr_orb({1'b0, 1'b0, 1'b0}); wr_orb({1'b0, 1'b1, 1'b0}); end
    wr_orb(3'b111);                                     // CS* high
    rd1(lcmd(1'b1, 5'h05), v);
    is("CS* high mid-byte: no write", v, 8'hC5);

    // the test manager's writer ($40803528): extended write to $F0 + n,
    // then its clear of write protect ($40803576)
    wr_orb({1'b0, orb[1:0]});                           // bclr #2
    tm_byte(8'h3F, v); tm_byte(8'h40 + 8'd4 * 3, v); tm_byte(8'h5A, v);
    wr_orb({1'b1, orb[1:0]});
    xrd(8'hF3, v); is("the test manager's extended write: $F3", v, 8'h5A);

    // ======================== 10: InitUtil from zero
    for (n = 0; n < 256; n = n + 1) dut.ram[n] = 8'h00;
    init_util;
    xrd(8'h10, v); is("InitUtil: validity byte $A8 at xPRAM $10", v, 8'hA8);
    rd1(lcmd(1'b1, 5'h13), v); is("InitUtil: default original $13 = $4C", v, 8'h4C);
    rd1(lcmd(1'b1, 5'h0E), v); is("InitUtil: default original $0E = $63", v, 8'h63);
    xrd(8'h0C, v); is("InitUtil: 'NuMc' N", v, 8'h4E);
    xrd(8'h0F, v); is("InitUtil: 'NuMc' c", v, 8'h63);
    xrd(8'h78, v); is("InitUtil: the block at $76 ($78 = FF)", v, 8'hFF);
    xrd(8'h7B, v); is("InitUtil: the block at $76 ($7B = DF)", v, 8'hDF);
    // the second start: nothing rewritten.  Mark a byte the first pass
    // would have cleared and see it survive.
    wp_off; xwr(8'h30, 8'h77); wp_on;
    init_util;
    xrd(8'h30, v); is("InitUtil again: valid PRAM left alone", v, 8'h77);
    is("still no contention", clashes, 0);

    // ======================== 11: the seconds and 1HZ
    // TIMESTAMP: the first toggle loads Unix + 2,082,844,800; a later
    // toggle does not (the Mac owns the clock once it runs)
    timestamp = {1'b1, 32'd1_000_000_000};
    repeat (4) @(posedge clk);
    is("TIMESTAMP loads seconds + 2082844800", dbg_secs, 32'd1_000_000_000 + 32'd2_082_844_800);
    timestamp = {1'b0, 32'd5};
    repeat (4) @(posedge clk);
    is("a second TIMESTAMP toggle is ignored", dbg_secs, 32'd1_000_000_000 + 32'd2_082_844_800);
    // one increment per CLK_HZ clocks, 1HZ falling with it
    @(negedge one_hz); t0 = $time; s1 = dbg_secs;
    @(negedge one_hz); s2 = dbg_secs;
    is("one increment per 1HZ fall", s2 - s1, 1);
    is("1HZ period = CLK_HZ clocks", ($time - t0) / 32, CLK_HZ);
    @(posedge one_hz);
    is("1HZ high half the second", ($time - t0) / 32 - CLK_HZ, CLK_HZ / 2);
    // read the time the ROM's way ($4080DCA6): seconds 3..0, twice, agree
    for (n = 0; n < 2; n = n + 1) begin
      rd1(8'h9D, v); s1[31:24] = v; rd1(8'h99, v); s1[23:16] = v;
      rd1(8'h95, v); s1[15:8] = v;  rd1(8'h91, v); s1[7:0] = v;
      if (n == 0) s2 = s1;
    end
    check(s1 - (32'd1_000_000_000 + 32'd2_082_844_800) < 32'd10, "the ROM's time read ($9D..$91)", s1, 32'd1_000_000_000 + 32'd2_082_844_800);
    is("no contention on the data line, the whole run", clashes, 0);

    $display("---- %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  wire [31:0] dbg_secs = dut.secs;

  initial begin #400_000_000 $display("==== FAIL (timeout)"); $finish; end

endmodule
