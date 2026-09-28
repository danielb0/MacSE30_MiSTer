// tb_se30_adb.v - the ADB transceiver running Apple's program (342S0440-B)
// behind VIA1, with the keyboard and mouse on the line, driven the way the
// SE/30 ROM's ADB Manager drives it.  SE30_PLAN.md 6.9 items 3-7.
//
// WHAT THIS PROVES
//   rtl/se30_adb_xcvr.v (the PIC1654S and its wiring), running the dumped
//   program, with rtl/se30_via.v as VIA1 and rtl/se30_adb_dev.v's devices,
//   does for the ROM what the ROM expects:
//
//     3. the timing on the wire of the transceiver's own command: the
//        Attention, the bit cell, the "0" and "1" lows and the stop bit
//        within Table 8-14's host tolerances - the check of the Fosc/8
//        divider against the Guide, at C3M = 3.672 MHz
//     4. no contention on DIO: the PIC never pulls it while VIA1 drives it
//     5. ReInit's transactions ($40806DEA-$40806EDA): Talk register 3 to
//        each of the sixteen addresses - $62 $02 from the keyboard at 2,
//        $63 $01 from the mouse at 3, a time-out everywhere else, read the
//        ROM's way (INT* low after the first byte in state 1); no INT* in
//        state 0 (the ROM's service-request path) while nothing has data;
//        the Listen register 3 $FE move to a free address and back, each
//        confirmed by a Talk; then the auto-poll's entry ($4080724C: Talk
//        register 0 to address 3, state 0, then state 3), and the
//        transceiver repeating that Talk on its own every 11 ms
//     6. data through the auto-poll: the mouse moved, the transceiver
//        takes its register 0 and hands it to the ROM (a byte into the
//        shift register in state 3, then the data in states 1 and 2, INT*
//        low at the end); a key pressed while the mouse is the one polled,
//        its Service Request reaching the ROM, and a Talk to the keyboard
//        bringing the key
//     7. Listen register 2 (the keyboard's LEDs) through the transceiver
//
// THE HOST
//   The ROM's own access sequences, transcribed from the disassembly
//   (VIA1 at $50F00000, registers every $200; plan 6.7):
//     send ($408073E6)    ACR &= $E3, ACR |= $1C (two read-modify-writes:
//                         shift out under CB1), SR := the byte
//     state ($408073C0)   ORB := (ORB & $CF) | state << 4
//     the interrupt       IFR := $04 first ($40807002), then by the state
//                         last set: a read of ORB for PB3 (INT*) where the
//                         ROM reads it, ACR bit 4 cleared and SR read to
//                         shift in ($40807092), SR read or written for a
//                         byte ($408072B8), the next state
//   The interrupt is taken 10 us after IFR bit 2 rises - the level-1
//   interrupt's latency through the ROM's dispatcher, roughly.  Every VIA
//   access is a real E-synchronous device cycle (4.4).
//
//   What is not replayed: the ADB Manager's device table, queue and
//   address-resolution bookkeeping.  The sequence of transactions here is
//   the one ReInit and the auto-poll produce; which addresses the ROM
//   finally leaves each device at is the board's to show.
//
// THE PROGRAM
//   ADBROM (default C:/temp/Mac/ROMS/MacSE30/342s0440-b.bin), converted by
//   run.sh to adb.hex (one 12-bit word per line) and written into the
//   transceiver's store through its download port, as boot2.rom is.

`timescale 1ns/1ps

module tb_se30_adb;

  // ------------------------------------------------ clocks, as the machine's
  reg clk = 0;
  always #15.95745 clk = ~clk;             // 31.3344 MHz: clk_sys
  reg c16 = 0;
  always @(posedge clk) c16 <= ~c16;       // phi1: one clk in two
  reg [4:0] ecnt = 0;
  always @(posedge clk) if (c16) ecnt <= (ecnt == 5'd19) ? 5'd0 : ecnt + 1'b1;
  wire e_clk = ecnt >= 10;
  // GLUE's C3M, exactly as rtl/se30_glue.v makes it: 15 pulses in 64
  // C16M, the register updated only on C16M's enable - so c3m_en is high
  // for a whole C16M period (two clk), an enable to be qualified with
  // c16_en, as every consumer of GLUE's clocks must (compile 17's mouse,
  // plan 6.12 item 7)
  reg [6:0] c3m_acc = 0;
  reg       c3m_en = 0;
  always @(posedge clk)
    if (c16) begin
      if (c3m_acc + 7'd15 >= 7'd64) begin c3m_acc <= c3m_acc + 7'd15 - 7'd64; c3m_en <= 1; end
      else begin c3m_acc <= c3m_acc + 7'd15; c3m_en <= 0; end
    end

  reg reset_n = 0;

  // ------------------------------------------------ VIA1
  reg        sel = 0, strobe = 0, rw = 1;
  reg  [3:0] rs = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata;
  wire       irq_n;
  wire [7:0] pb_out, pb_oe;
  wire       cb2_out, cb2_oe;
  wire       int_n, sclk, dio;
  wire [7:0] pb_pin = (pb_oe & pb_out) | (~pb_oe & {4'b1111, int_n, 3'b111});
  wire [6:0] ifr, ier;

  se30_via via1 (
    .clk(clk), .c16_en(c16), .reset_n(reset_n), .e_clk(e_clk),
    .sel(sel), .strobe(strobe), .rs(rs), .rw(rw), .wdata(wdata), .rdata(rdata), .irq_n(irq_n),
    .pa_in(8'hFF), .pa_out(), .pa_oe(), .pb_in(pb_pin), .pb_out(pb_out), .pb_oe(pb_oe),
    .ca1(1'b1), .ca2_in(1'b1), .ca2_out(), .ca2_oe(),
    .cb1_in(sclk), .cb1_out(), .cb1_oe(), .cb2_in(dio), .cb2_out(cb2_out), .cb2_oe(cb2_oe),
    .dbg_ifr(ifr), .dbg_ier(ier));

  // ------------------------------------------------ the transceiver and the line
  reg        pm_we = 0;
  reg  [8:0] pm_waddr = 0;
  reg [11:0] pm_wdata = 0;
  wire       xcvr_pull, kbd_pull, mouse_pull;
  wire       line = !(xcvr_pull | kbd_pull | mouse_pull);
  wire [63:0] xdbg;

  se30_adb_xcvr xcvr (
    .clk(clk), .c16_en(c16), .c3m_en(c3m_en), .reset_n(reset_n),
    .pm_we(pm_we), .pm_waddr(pm_waddr), .pm_wdata(pm_wdata),
    .st0(pb_pin[4]), .st1(pb_pin[5]), .int_n(int_n), .sclk(sclk),
    .via_cb2_out(cb2_out), .via_cb2_oe(cb2_oe), .dio(dio),
    .line(line), .pull(xcvr_pull), .dbg(xdbg));

  reg [10:0] ps2_key = 0;
  reg [24:0] ps2_mouse = 0;
  se30_adb_kbd   kbd   (.clk(clk), .reset(1'b0), .ps2_key(ps2_key), .line(line), .pull(kbd_pull), .dbg());
  se30_adb_mouse mouse (.clk(clk), .reset(1'b0), .ps2_mouse(ps2_mouse), .line(line), .pull(mouse_pull), .dbg());

  // ------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*84-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask
  task is(input [8*84-1:0] what, input integer got, input integer want);
    begin check(got == want, what, got, want); end
  endtask

  // contention on DIO: the VIA driving it while the PIC's latch pulls it
  integer clashes = 0;
  always @(posedge clk) if (cb2_oe && cb2_out && !xcvr.rb_latch[3]) clashes = clashes + 1;

  // ------------------------------------------------ the wire, measured
  // every low on the line, with who pulled it, into a log the checks read
  integer t_fall = 0, lows_n = 0;
  integer low_len [0:4095];
  integer low_at  [0:4095];
  reg     ln_q = 1;
  always @(posedge clk) begin
    ln_q <= line;
    if (ln_q && !line) t_fall = $time;
    if (!ln_q && line && lows_n < 4096) begin
      low_len[lows_n] = ($time - t_fall) / 1000;   // us
      low_at[lows_n]  = t_fall / 1000;
      lows_n = lows_n + 1;
    end
  end

  // ------------------------------------------------ VIA1 as the CPU sees it
  localparam ORB = 4'd0, DDRB = 4'd2, SR = 4'd10, ACR = 4'd11, PCR = 4'd12, IFR = 4'd13, IER = 4'd14;
  reg [7:0] q;
  task access(input [3:0] r, input w, input [7:0] d);
    begin
      while (!(c16 && ecnt == 7)) @(posedge clk);
      #1 rs = r; rw = !w; wdata = d; sel = 1;
      while (!(c16 && ecnt == 18)) @(posedge clk);
      #1 strobe = 1;
      @(posedge clk); @(posedge clk);
      q = rdata;
      #1 strobe = 0; sel = 0; rw = 1;
    end
  endtask
  task vwr(input [3:0] r, input [7:0] d); begin access(r, 1, d); end endtask
  task vrd(input [3:0] r);                begin access(r, 0, 8'h00); end endtask

  // the ROM's routines
  reg [7:0] v;
  task rom_send(input [7:0] b);                      // $408073E6
    begin
      vrd(ACR); vwr(ACR, q & 8'hE3);                 // andi.b #$e3,$1600(a1)
      vrd(ACR); vwr(ACR, q | 8'h1C);                 // ori.b  #$1c,$1600(a1)
      vwr(SR, b);                                    // move.b d0,$1400(a1)
    end
  endtask
  reg [1:0] rom_st;                                  // the state the ROM last set ($15F)
  task rom_state(input [1:0] s);                     // $408073A2/AA/B2/BA -> $408073C0
    begin
      vrd(ORB); vwr(ORB, (q & 8'hCF) | {2'b00, s, 4'b0000});
      rom_st = s;
    end
  endtask
  task rom_shift_in;                                 // bclr #4,$1600(a1); move.b $1400(a1),d0
    begin vrd(ACR); vwr(ACR, q & 8'hEF); vrd(SR); end
  endtask
  // the interrupt: wait for IFR bit 2, the latency, then IFR := $04
  integer irq_timeout;
  reg     irq_ok;
  task wait_irq(input integer limit_us);
    integer t0;
    begin
      t0 = $time; irq_ok = 0;
      while (irq_n && ($time - t0) < limit_us * 1000) @(posedge clk);
      if (!irq_n) begin
        irq_ok = 1;
        #10_000;                                     // the level-1 interrupt's way in
        vwr(IFR, 8'h04);                             // move.b #$4,$1a00(a1)
      end
    end
  endtask
  reg pb3;
  task rd_int; begin vrd(ORB); pb3 = q[3]; end endtask

  // counters of what the ROM would have seen
  integer int_in_state0 = 0;

  // One transaction as the ROM runs it during initialisation ($15D bit 5
  // set): Talk - the command, state 0; the interrupt: INT* read, shift in,
  // state 1; the interrupt: INT* low means no reply, else the first byte,
  // state 2; the interrupt: the second byte, done.  Listen - the command,
  // state 0; the interrupt: INT* read, the first byte out, state 1; the
  // interrupt: INT* read, the second byte out, state 2; the interrupt: a
  // third write of SR ($408072B8 again, the ROM's), done.  The next
  // transaction's command then sets state 0.
  reg [15:0] reply;
  reg        replied;
  task init_txn(input [7:0] cmd, input [15:0] ldata);
    begin
      replied = 0; reply = 16'hxxxx;
      rom_send(cmd); rom_state(2'd0);
      wait_irq(20_000);
      if (!irq_ok) begin $display("     (no interrupt after the command %02h)", cmd); disable init_txn; end
      rd_int; if (!pb3) int_in_state0 = int_in_state0 + 1;
      if (cmd[3:2] == 2'b11) begin
        rom_shift_in; rom_state(2'd1);
        wait_irq(20_000);
        rd_int;
        if (!pb3) begin replied = 0; disable init_txn; end          // $408070DA: the time-out
        vrd(ACR); vrd(SR); reply[15:8] = q; rom_state(2'd2);        // $408072B8
        wait_irq(20_000);
        vrd(ACR); vrd(SR); reply[7:0] = q; replied = 1;             // $408070FC -> $408072B8
      end else begin
        vwr(SR, ldata[15:8]); rom_state(2'd1);                      // $408070A2
        wait_irq(20_000);
        rd_int;
        vrd(ACR); vwr(SR, ldata[7:0]); rom_state(2'd2);             // $408070E8 -> $408072B8
        wait_irq(20_000);
        vrd(ACR); vwr(SR, 8'h00);                                   // $408070FC -> $408072B8: a third byte
        replied = 1;
      end
    end
  endtask

  // ------------------------------------------------ the tests
  integer n, i, a, first_low, t_prev, period_min, period_max, npoll;
  reg [7:0] img [0:1023];
  reg [11:0] fw [0:511];
  reg found2, found3;
  reg srq_seen;

  initial begin
    $readmemh("out/adb.hex", fw);
    repeat (10) @(posedge clk);
    // the program, through the download port
    for (i = 0; i < 512; i = i + 1) begin
      @(posedge clk); #1 pm_we = 1; pm_waddr = i; pm_wdata = fw[i];
    end
    @(posedge clk); #1 pm_we = 0;
    repeat (2000) @(posedge clk);
    #1 reset_n = 1;
    is("RESET*: the transceiver held the line low while in reset (latches high)", lows_n > 0 || !line, 1);

    // the ROM's VIA initialisation (4.6 item 8) - the ADB lines' part
    vwr(ORB, 8'h07); vwr(DDRB, 8'h87); vwr(IER, 8'h7F);
    #2_000_000;                                           // the start-up chain until ADB (2 ms here)
    // ADB Manager's initialisation ($40806D94)
    vwr(PCR, 8'h00); vwr(IER, 8'h84); vrd(DDRB); vwr(DDRB, q | 8'h30);
    is("ST1-ST0 idle at 00 after DDRB |= $30 (ORB bits clear)", pb_pin[5:4], 2'b00);

    // ============ 5 (and 3): ReInit's Talk register 3 to every address
    first_low = lows_n;
    found2 = 0; found3 = 0;
    for (a = 0; a < 16; a = a + 1) begin
      init_txn({a[3:0], 4'b1111}, 16'h0000);
      if (a == 2) begin
        is("5: Talk R3 to 2: the keyboard answers", replied, 1);
        is("5: the keyboard's register 3 = $6202", reply, 16'h6202);
      end else if (a == 3) begin
        is("5: Talk R3 to 3: the mouse answers", replied, 1);
        is("5: the mouse's register 3 = $6301", reply, 16'h6301);
      end else if (replied)
        check(0, "5: an empty address answered", a, 0);
    end
    is("5: nobody else answered, INT* never low in state 0 (no service request)", int_in_state0, 0);

    // ---- 3: the command's timing on the wire, from the first Talk R3
    // the first low after the transactions began is the Attention
    check(low_len[first_low] >= 776 && low_len[first_low] <= 824,
          "3: Attention 800 us +/-3% (Fosc/8 at C3M)", low_len[first_low], 800);
    // then 8 command bits: lows of 35 (1) or 65 (0); $0F = 0000 1111
    check(low_len[first_low + 1] >= 60 && low_len[first_low + 1] <= 70, "3: a '0' low 65 us +/-5% of the cell", low_len[first_low + 1], 65);
    check(low_len[first_low + 5] >= 30 && low_len[first_low + 5] <= 40, "3: a '1' low 35 us +/-5% of the cell", low_len[first_low + 5], 35);
    check((low_at[first_low + 2] - low_at[first_low + 1]) >= 97 && (low_at[first_low + 2] - low_at[first_low + 1]) <= 103,
          "3: the bit cell 100 us +/-3%", low_at[first_low + 2] - low_at[first_low + 1], 100);
    check(low_len[first_low + 9] >= 60 && low_len[first_low + 9] <= 80, "3: the stop bit's low ~70 us", low_len[first_low + 9], 70);
    is("4: no contention on DIO", clashes, 0);

    // ---- 5: the $FE move, the ROM's way: Listen R3 to 3 with [new, $FE],
    // Talk R3 at the new address; and back
    init_txn(8'h3B, 16'h0FFE);                           // to 15
    init_txn(8'hFF, 16'h0000);                           // Talk R3 to 15
    is("5: after Listen R3 $FE to 15, the mouse answers at 15", replied, 1);
    is("5: its register 3 = $6F01", reply, 16'h6F01);
    init_txn(8'h3F, 16'h0000);
    is("5: nobody at 3 now", replied, 0);
    init_txn(8'hFB, 16'h03FE);                           // Listen R3 to 15: back to 3
    init_txn(8'h3F, 16'h0000);
    is("5: moved back: the mouse at 3 again", reply, 16'h6301);

    // ============ 7: Listen R2 to the keyboard (its LEDs)
    init_txn(8'h2A, 16'hFFFA);
    init_txn(8'h2E, 16'h0000);                           // Talk R2
    is("7: Listen R2 through the transceiver: LEDs read back", reply[2:0], 3'b010);

    // ============ 5: the auto-poll's entry ($4080724C, $4080705C)
    rom_send(8'h3C); rom_state(2'd0);                    // Talk R0 to 3
    wait_irq(20_000);
    rd_int;
    is("5: auto-poll entry: INT* high after the command (no data, no SRQ)", pb3, 1);
    rom_shift_in; rom_state(2'd3);                        // $4080705C: state 3, shifting in
    // the transceiver repeats the Talk on its own: Attentions ~11 ms apart
    #2_000_000;
    n = lows_n; npoll = 0; period_min = 999999; period_max = 0; t_prev = -1;
    #60_000_000;
    for (i = n; i < lows_n; i = i + 1)
      if (low_len[i] >= 560 && low_len[i] < 3000) begin
        if (t_prev >= 0) begin
          if (low_at[i] - t_prev < period_min) period_min = low_at[i] - t_prev;
          if (low_at[i] - t_prev > period_max) period_max = low_at[i] - t_prev;
        end
        t_prev = low_at[i]; npoll = npoll + 1;
      end
    check(npoll >= 4, "5: the transceiver polls on its own in state 3", npoll, 5);
    check(period_min >= 9_000 && period_max <= 13_000, "5: every ~11 ms (the Guide's 11 ms)", period_max, 11_000);
    is("5: no interrupt while nothing has data", irq_n, 1);

    // ============ 6: the mouse moves: data through the auto-poll
    ps2_mouse = {~ps2_mouse[24], 8'd0, 8'd5, 2'b00, 1'b0, 1'b0, 3'b000, 1'b0};   // right 5
    wait_irq(30_000);
    is("6: an interrupt in state 3 when the mouse has data", irq_ok, 1);
    // $40807154 -> $4080708A -> $40807092: shift in (the byte in SR is
    // thrown away), state 1
    rom_shift_in; rom_state(2'd1);
    wait_irq(20_000); rd_int;
    is("6: INT* high with the first byte (there is data)", pb3, 1);
    vrd(ACR); vrd(SR); reply[15:8] = q; rom_state(2'd2);
    wait_irq(20_000); rd_int;
    vrd(ACR); vrd(SR); reply[7:0] = q; rom_state(2'd1);
    wait_irq(20_000); rd_int;
    is("6: INT* low after the pair: the end of the data", pb3, 0);
    is("6: the mouse's register 0: button up, Y 0, X +5 = $8085", reply, 16'h8085);
    vrd(ACR); vrd(SR);                                   // $4080716E: SR read, thrown away

    // back to the auto-poll: the Talk R0 to the mouse again, state 0, then 3
    rom_send(8'h3C); rom_state(2'd0);
    wait_irq(20_000); rd_int;
    rom_shift_in; rom_state(2'd3);
    #20_000_000;
    is("6: the auto-poll resumed quietly", irq_n, 1);

    // ============ 6: a key while the mouse is the one polled: the
    // keyboard's Service Request reaches the ROM, which then Talks to it.
    // The ROM's path for the interrupt in state 3 is the same as for data;
    // what INT* says at each byte is recorded and the essential outcome
    // checked: the ROM learns of a service request (INT* low in state 2,
    // $4080711C, or a first byte with INT* low, $408070DA) and a Talk R0 to
    // the keyboard then brings the key.
    ps2_key = {~ps2_key[10], 1'b1, 1'b0, 8'h1C};         // A down
    wait_irq(30_000);
    is("6: an interrupt in state 3 on the keyboard's service request", irq_ok, 1);
    rom_shift_in; rom_state(2'd1);
    wait_irq(20_000); rd_int; srq_seen = !pb3;
    $display("     state 1, first byte: INT* %0d", pb3);
    vrd(ACR); vrd(SR); rom_state(2'd2);
    wait_irq(20_000); rd_int; srq_seen = srq_seen | !pb3;
    $display("     state 2: INT* %0d", pb3);
    vrd(ACR); vrd(SR); rom_state(2'd1);
    wait_irq(20_000); rd_int;
    $display("     state 1 again: INT* %0d", pb3);
    vrd(ACR); vrd(SR);
    is("6: the ROM saw the service request (INT* low in state 1's first byte or state 2)", srq_seen, 1);
    init_txn(8'h2C, 16'h0000);                           // Talk R0 to the keyboard
    is("6: the keyboard answers the ROM's Talk R0", replied, 1);
    is("6: the key: A down ($00), empty slot ($FF)", reply, 16'h00FF);

    $display("---- %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  initial begin #2_000_000_000 $display("==== FAIL (timeout)"); $finish; end

endmodule
