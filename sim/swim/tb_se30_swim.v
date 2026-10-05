// tb_se30_swim.v - the SWIM and the internal FDHD drive held to
// SE30_PLAN.md 5.2 and 5.5, item by item of 5.9's list (rung 1: the
// register sets and an empty drive; no flux).
//
// WHAT THIS PROVES
//   rtl/se30_swim.v is the SWIM as Apple's documents describe its two
//   register sets, and rtl/se30_fdhd.v is a Sony FDHD drive with no disk
//   as the ROM's .Sony driver reads it:
//
//     1. reset: IWM latches and mode 0, ISM mode/setup/error 0, phases
//        $F0 (all outputs, all low), the enables off              5.2.1-2
//     2. the sixteen IWM latch addresses, each setting or clearing its
//        latch, seen on the pins                                    5.2.1
//     3. the IWM register table by {L7, L6, MotorOn}, the new state
//        choosing the register, writes only at L6 = L7 = 1 with A0 = 1
//                                                                   5.2.1
//     4. the ROM's mode-set loop ($408006AA) exits with mode $17 in
//        two passes from reset                                     5.6.1
//     5. the MotorOn timer: 2^23 + 100 FCLK with mode bit 2 clear, the
//        mode register unreachable while it runs, none with bit 2 set,
//        doubled by M16/M8, ended early by OVERRIDE and a drive-select
//        toggle                                                 5.2.1, 5.2.3
//     6. the switch: $57/$17/$57/$57 enters the ISM; a wrong fourth
//        write or MotorOn on does not; write-zeros bit 6 returns, and
//        not while the ISM's MotorOn is left set                    5.2.3
//     7. the phase register read back whole; the direction bits in
//        force in both sets (the chip spec's reading)          5.2.2-3
//     8. mode write-zeros/write-ones, bit 6 reading 1, status = mode 5.2.2
//     9. the parameter RAM: sixteen bytes auto-incrementing, the index
//        reset by a write-zeros write                               5.2.2
//    10. setup read back; the IWM configuration bits through register
//        2 with ACTION low                                      5.2.2-3
//    11. the drive through the ROM's encoding ($4082E0EC/$4082E12E):
//        the empty internal FDHD and the absent external             5.5
//    12. the drive's commands through $4082E150's PH3 pulse           5.5
//    13. the ROM's SWIM probe in the .Sony Open ($4082E6A2), end to
//        end, then Open's drive reads                              5.6.3
//
//   and, since rung 2 (plan 5.12.2, 5.12.9 item 1), the IWM's read path:
//
//    15. the window table (IWM Spec Rev 19 p. 10) in mode $17 (slow,
//        8M): an interval of Nclks 7-8 and 23 shifts a 1, 24 and 39 a 01,
//        40 and 55 a 001, 56 a 0001; the B revision's blanking (SWIM
//        drawing sheet 53, 12 FCLK in slow mode) ignoring an edge 10 FCLK
//        after the last and taking one at 14; the data register holding a
//        byte until a valid read and clearing 14 FCLK after it; self-sync
//        groups locking the shifter onto D5 AA 96 DE AA from any bit
//        offset; the fast 8M and slow 7M bands
//
//   and, since rung 3 (plan 5.15.2, 5.15.9 item 1), the IWM's write path:
//
//    16. the write state entered the ROM's way (L6 set, then L7 set with
//        the first byte, $4082E52E-$4082E536): /WRREQ low, the buffer
//        full until the first load 7 CLK after entry (sheet 52), then a
//        load every 8 cells (256 FCLK in mode $17); WRDATA toggling on the
//        ones at the cell boundaries, MSB first, every edge on the 32-FCLK
//        grid, the ROM's sector bytes recovered whole from the edges; the
//        handshake's bit 7 rising at each load and falling at a write;
//        the last write before a load winning; writes ignored for 9 FCLK
//        after a load (IWM undocumented features, 1984); an underrun
//        clearing bit 6 and raising /WRREQ, L7's clear resetting it;
//        /WRREQ high with L7 set and the motor off (IWM Spec p. 7); the
//        28-FCLK cell in 7M slow and the 16-FCLK cell in 8M fast
//
//   Rung 2's bytes are read the ROM's way: the data register at $1800
//   (L6 cleared by the access, L7 and MotorOn as they are), polled until
//   its MSB is set ($40831C2E: move.b (a4),d5 / bpl).  The flux reaches
//   the chip on SENSE, which is RDDATA on this board (plan 5.3): the bench
//   ANDs its own pulses into the drive's line, with the drive addressed
//   to a register that reads 1.
//
// THE BUS
//   GLUE's device port (plan 5.4): the select is up for the access, the
//   strobe is its one latch clock, and the read is taken there.  The chip
//   has no R/W pin, so a "read" and a "write" differ here only in what
//   the bench puts on the data lanes (a CPU read leaves them holding
//   whatever they hold; $A5 stands for it).  c16_en is tied high: one
//   clock is one FCLK.  An access is five clocks, one apart - further
//   apart than the 4-FCLK rule needs (User's Ref p. 13).
//
//   The drive's SEL is VIA1 PA5, a bench register here as it is a VIA
//   pin on the board; SENSE is the internal drive's line wired-AND with
//   the absent external's pulled-up 1.

`timescale 1ns/1ps

module tb_se30_swim;

  reg clk = 0;
  always #31.9149 clk = ~clk;              // 15.6672 MHz: one clock is one FCLK
  reg reset_n = 0;

  // ---------------------------------------------------------- the bus
  reg        sel = 0, strobe = 0;
  reg  [3:0] rs = 0;
  reg  [7:0] wdata = 8'hA5;
  wire [7:0] rdata;

  // ------------------------------------------------------ the drive side
  wire [3:0] ph_out, ph_oe;
  reg  [3:0] ph_ext = 4'b1111;             // an input phase line reads its pull-up
  wire [3:0] ph_pin = (ph_oe & ph_out) | (~ph_oe & ph_ext);
  wire       enbl1_n, enbl2_n, wrdata, wrreq_n, hdsel;
  reg        via_sel = 0;                  // VIA1 PA5, HDSEL on sheet 6
  wire       sense_int;
  reg        flux_n = 1;                  // rung 2: the bench's flux pulses, low-going (plan 5.12.3)
  wire       sense = sense_int & flux_n;   // the external drive is absent: its line reads 1
  wire [47:0] dbg_swim;
  wire [15:0] dbg_drive;

  se30_swim swim (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .sel(sel), .strobe(strobe), .rs(rs), .wdata(wdata), .rdata(rdata),
    .ph_out(ph_out), .ph_oe(ph_oe), .ph_in(ph_pin),
    .enbl1_n(enbl1_n), .enbl2_n(enbl2_n), .sense(sense),
    .wrdata(wrdata), .wrreq_n(wrreq_n), .hdsel(hdsel), .dbg(dbg_swim));

  se30_fdhd drive (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),
    .enbl_n(enbl1_n), .ph(ph_pin), .sel(via_sel),
    .sense(sense_int), .disk_in(1'b0), .eject(),
    .cyl(), .trk_cyl(7'h7F), .trk_valid(1'b0), .trk_addr(), .trk_side(), .trk_bit(1'b0),
    .dbg(dbg_drive));

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask

  // -------------------------------------------------------- bus access
  // one device-port cycle at offset `off` (the SWIM window's A12-A9);
  // q is the byte the chip presented at the strobe
  reg [7:0] q;
  integer cyc = 0, t_latch = 0;
  always @(posedge clk) cyc <= cyc + 1;
  task access(input [15:0] off, input [7:0] d);
    begin
      @(posedge clk); #1 rs = off[12:9]; wdata = d; sel = 1;
      @(posedge clk); @(posedge clk);
      #1 strobe = 1;
      @(posedge clk);                                  // the latch edge
      q = rdata; t_latch = cyc;
      #1 strobe = 0; sel = 0; wdata = 8'hA5;
    end
  endtask
  task rd(input [15:0] off);               begin access(off, 8'hA5); end endtask   // tst.b / move.b from
  task wr(input [15:0] off, input [7:0] d); begin access(off, d); end endtask      // move.b to

  // the IWM latches as the chip holds them: {L7, L6, drive select, MotorOn, PH3-0}
  wire [7:0] latches = dbg_swim[46:39];
  wire       ism     = dbg_swim[47];

  // ------------------------------------------------ the ROM's drive access
  // $4082E0EC: CA0 and CA1 high, then register bits 0-3 to CA2, SEL, CA0, CA1
  task drv_addr(input [3:0] n);
    begin
      rd(16'h0200); rd(16'h0600);                          // CA0, CA1 high
      if (n[0]) rd(16'h0A00); else rd(16'h0800);           // CA2
      #1 via_sel = n[1];                                   // SEL: VIA1 ORA bit 5
      if (!n[2]) rd(16'h0000);                             // CA0 low
      if (!n[3]) rd(16'h0400);                             // CA1 low
    end
  endtask
  // $4082E12E: L6 on, status at $1C00 (bit 7 = SENSE), L6 off
  reg sns;
  task drv_read(input [3:0] n);
    begin drv_addr(n); rd(16'h1A00); rd(16'h1C00); sns = q[7]; rd(16'h1800); end
  endtask
  // $4082E150: PH3 high, two NOPs, PH3 low
  task drv_cmd(input [3:0] n);
    begin drv_addr(n); rd(16'h0E00); repeat (4) @(posedge clk); rd(16'h0C00); end
  endtask
  // the ROM's seek ($4082E17A): a step, then $4 polled until /STEP reads 1
  // (the drive holds it low up to 72 us, and a step inside that is not
  // counted - plan 5.12.3)
  task drv_step;
    integer w;
    begin
      drv_cmd(4'h4); w = 0;
      drv_read(4'h4);
      while (!sns && w < 1000) begin drv_read(4'h4); w = w + 1; end
    end
  endtask

  // --------------------------------------------------- timing helpers
  // clocks from the latch edge at t0 until /ENBL1 is seen high (limit clocks)
  integer t0, n;
  task clocks_until_enbl1_high(input integer limit);
    begin
      while (!enbl1_n && cyc - t0 < limit) @(posedge clk);
      #1 n = cyc - t0;
    end
  endtask

  integer i, bad;
  reg [7:0] b;

  // ------------------------------------------------ rung 2: flux and bytes
  // set the IWM mode register the ROM's way (MotorOn off first; the timer
  // is disabled by every mode used here, bit 2)
  task set_mode(input [7:0] m);
    begin rd(16'h1000); rd(16'h1A00); wr(16'h1E00, m); rd(16'h1C00); rd(16'h1800); end
  endtask
  // one falling transition now: the line low 8 FCLK (the ERS's 0.3-0.8 us)
  task edge_now;
    begin #1 flux_n = 0; repeat (8) @(posedge clk); #1 flux_n = 1; end
  endtask
  // wait so that the next edge falls `gap` FCLK after the previous one
  // (edge_now spends 8 of them low)
  task gap_then_edge(input integer gap);
    begin repeat (gap - 8) @(posedge clk); edge_now; end
  endtask
  // the ROM's poll: read $1800 until the MSB is set; limit in FCLK.  After
  // a byte the ROM spends well over 14 FCLK before its next read of the
  // chip (table lookups and the VIA1 PA7 poll, $40831C48-$40831C70) - the
  // data register has cleared by then; so does the bench
  reg [7:0] got;
  task poll_byte(input integer limit);
    integer t;
    begin
      t = cyc; got = 8'h00;
      while (!got[7] && cyc - t < limit) begin rd(16'h1800); got = q; end
      if (got[7]) repeat (20) @(posedge clk);
    end
  endtask
  // a long quiet stretch: any partial byte drains (zeros shift it out, a
  // stray one latches), and the latch is read away
  task idle_flush;
    begin
      repeat (600) @(posedge clk);
      rd(16'h1800); repeat (20) @(posedge clk); rd(16'h1800);
    end
  endtask
  // a leading 1, the interval under test, then 1s every `cw` FCLK until the
  // byte is complete; the byte the ROM would read is checked
  task band(input integer x, input integer cw, input [7:0] want, input [8*88-1:0] what);
    integer k;
    begin
      idle_flush;
      fork
        begin
          edge_now;                                    // the leading 1 (after the long gap: 0s, then 1)
          gap_then_edge(x);                            // the interval under test
          for (k = 0; k < 8; k = k + 1) gap_then_edge(cw);
        end
        poll_byte(40000);
      join
      check(got == want, what, got, want);
    end
  endtask
  // the blanking: a leading 1, an extra edge `extra` FCLK later, then an
  // edge 48 FCLK after the extra one; the 1s at 32 FCLK complete the byte.
  // Ignored: from the leading 1 the next edge is at extra + 48 (a 01), then
  // 1s: 1 01 11111 = $BF.  Taken: 1 1 01 1111 = $DF.
  task blank_test(input integer extra, input [7:0] want, input [8*88-1:0] what);
    integer k;
    begin
      idle_flush;
      fork
        begin
          edge_now;
          repeat (extra - 8) @(posedge clk); edge_now;
          gap_then_edge(48);
          for (k = 0; k < 8; k = k + 1) gap_then_edge(32);
        end
        poll_byte(40000);
      join
      check(got == want, what, got, want);
    end
  endtask
  // play `n` bits MSB first at the 32-FCLK cell, a 1 as an edge
  task play_bits(input [31:0] bits, input integer n);
    integer k;
    begin
      for (k = n - 1; k >= 0; k = k - 1)
        if (bits[k]) begin edge_now; repeat (24) @(posedge clk); end
        else repeat (32) @(posedge clk);
    end
  endtask
  // self-sync: `off` bits of noise, five ten-bit groups (FF and two 0s),
  // then D5 AA 96 DE AA; the bytes the ROM would read must end with them
  reg [7:0] seen [0:31];
  integer nseen;
  task sync_test(input integer off);
    integer k, p;                                      // one counter per fork branch: a shared one
                                                       // let the poller cut the sync groups short
    reg [39:0] tail;
    begin
      idle_flush;
      nseen = 0;
      fork
        begin
          play_bits(32'b101, off);
          for (k = 0; k < 5; k = k + 1) play_bits(32'b1111111100, 10);
          play_bits(32'hD5AA96DE, 32); play_bits(32'hAA, 8);
          repeat (64) @(posedge clk);
        end
        begin
          for (p = 0; p < 12; p = p + 1) begin
            poll_byte(4000);
            if (got[7] && nseen < 32) begin seen[nseen] = got; nseen = nseen + 1; end
          end
        end
      join
      tail = (nseen >= 5) ? {seen[nseen-5], seen[nseen-4], seen[nseen-3], seen[nseen-2], seen[nseen-1]} : 40'h0;
      check(tail == 40'hD5AA96DEAA, "self-sync locks: D5 AA 96 DE AA after the sync groups", tail[31:0], 32'hAA96DEAA);
    end
  endtask

  // ------------------------------------------------ rung 3: the write path
  // every WRDATA transition, by clock, while logging is on
  integer ed [0:8191];
  integer ned = 0;
  reg     wlog = 0, wrdata_q = 0;
  always @(posedge clk) begin
    wrdata_q <= wrdata;
    if (wlog && wrdata !== wrdata_q && ned < 8192) begin ed[ned] = cyc; ned = ned + 1; end
  end
  // the ROM's entry ($4082E52E-$4082E536): L6 set (the sense state), then
  // L7 set with the first byte; MotorOn is already on
  integer t_enter;
  task wr_enter(input [7:0] b0);
    begin rd(16'h1A00); wr(16'h1E00, b0); t_enter = t_latch; end
  endtask
  // the ROM's byte loop: the handshake polled at $1800 (L6 cleared), the
  // byte written at $1A00 (L6 set, with L7 already set: the data register).
  // At the ROM's pace: the bench's accesses are 5 FCLK apart, but the
  // machine's shortest SWIM strobe-to-strobe gap is 15 FCLK (plan 1.17.5's
  // measurement), so the write's strobe comes 15 after the poll's
  task wr_byte(input [7:0] b);
    integer t;
    begin
      t = cyc; rd(16'h1800);
      while (!q[7] && cyc - t < 4000) rd(16'h1800);
      repeat (10) @(posedge clk);
      wr(16'h1A00, b);
    end
  endtask
  // the bits on WRDATA from edge `e0` on, cell `cw` FCLK: bit k is 1 when
  // an edge falls at ed[e0] + k*cw; `wbad` counts edges off that grid
  reg [7:0] wbits [0:255];
  integer wbad;
  task wr_decode(input integer e0, input integer cw, input integer nbytes);
    integer k, d;
    begin
      wbad = 0;
      for (k = 0; k < nbytes; k = k + 1) wbits[k] = 8'h00;
      for (k = e0; k < ned; k = k + 1) begin
        d = ed[k] - ed[e0];
        if (d % cw != 0) wbad = wbad + 1;
        else if (d / cw < nbytes * 8) wbits[(d / cw) / 8] = wbits[(d / cw) / 8] | (8'h80 >> ((d / cw) % 8));
      end
    end
  endtask
  // a sector's opening as the ROM writes it ($4082E4FA, $4082E65E): the
  // entry byte FF, five sync bytes, the data mark, a sector code, a few
  // data codes, the closing bytes
  reg [7:0] wexp [0:31];
  integer nexp;
  integer t1, t2;

  initial begin
    repeat (10) @(posedge clk); #1 reset_n = 1;
    repeat (3) @(posedge clk);

    // ---- 1. reset
    $display("---- 1. reset (5.2.1, 5.2.2)");
    check(ism == 0, "the IWM register set is selected out of reset", ism, 0);
    check(latches == 8'h00, "the eight IWM latches are 0", latches, 0);
    check(swim.iwm_mode == 5'h00, "the IWM mode register is 0 (the timer enabled)", swim.iwm_mode, 0);
    check(swim.ism_mode == 8'h00 && swim.ism_setup == 8'h00 && swim.ism_error == 8'h00,
          "ISM mode, setup and error are 0", swim.ism_mode | swim.ism_setup | swim.ism_error, 0);
    check({swim.ph_dir, swim.ph_lvl} == 8'hF0, "the phases $F0: all outputs, all low", {swim.ph_dir, swim.ph_lvl}, 8'hF0);
    check(ph_oe == 4'hF && ph_out == 4'h0, "the phase pins driven low", {ph_oe, ph_out}, 8'hF0);
    check(enbl1_n && enbl2_n, "neither drive enabled", {enbl1_n, enbl2_n}, 3);
    check(wrreq_n == 1, "/WRREQ inactive", wrreq_n, 1);

    // ---- 2. the latches
    $display("---- 2. the sixteen IWM latch addresses (5.2.1)");
    rd(16'h1A00); wr(16'h1E00, 8'h04); rd(16'h1C00); rd(16'h1800);   // mode bit 2: the timer off, so MotorOn off is immediate
    bad = 0;
    for (i = 0; i < 16; i = i + 1) begin
      rd(i << 9);
      if (latches[i >> 1] != i[0]) bad = bad + 1;
    end
    check(bad == 0, "each address sets its latch to A0", bad, 0);
    rd(16'h1000); rd(16'h1C00); rd(16'h1800); rd(16'h1400);
    rd(16'h0200); rd(16'h0400); rd(16'h0A00); rd(16'h0E00);
    check(ph_out == 4'b1101 && ph_oe == 4'hF, "PH0-3 latches on the pins (1101)", ph_out, 4'b1101);
    rd(16'h0000); rd(16'h0C00); rd(16'h0800);
    check(ph_out == 4'b0000, "and back to 0", ph_out, 0);
    rd(16'h1200);
    check(!enbl1_n && enbl2_n, "MotorOn with drive select 0: /ENBL1 (internal) low", {enbl1_n, enbl2_n}, 1);
    rd(16'h1600);
    check(enbl1_n && !enbl2_n, "drive select 1: /ENBL2 (external) low instead", {enbl1_n, enbl2_n}, 2);
    rd(16'h1400);
    rd(16'h1000);
    check(enbl1_n && enbl2_n, "MotorOn off with the timer disabled: both enables off at once", {enbl1_n, enbl2_n}, 3);

    // ---- 3. the IWM register table
    $display("---- 3. the IWM registers by {L7, L6, MotorOn} (5.2.1)");
    rd(16'h1C00); rd(16'h1800);                          // L7 0, L6 0, MotorOn 0
    rd(16'h1000);   check(q == 8'hFF, "000: read all ones", q, 8'hFF);
    rd(16'h1200);   rd(16'h1800);
                    check(q == swim.sr, "001: read data (mode 0 is synchronous: the live shift register)", q, swim.sr);
    rd(16'h1000);   rd(16'h1A00); rd(16'h1C00);
                    check(q[4:0] == 5'h04 && q[6] == 0 && q[7] == sense, "01x: status = {SENSE, 0, enable, mode[4:0]}", q, {sense, 7'h04});
    wr(16'h1E00, 8'h1F);                                 // L7 set with L6 = 1, A0 = 1: the mode register
    rd(16'h1C00);   check(q[4:0] == 5'h1F, "a write at $1E00 from L6 = 1 reaches the mode register", q[4:0], 5'h1F);
    rd(16'h1800);   wr(16'h1E00, 8'h00);                 // L6 0, then L7 1: not a write (L6 is 0)
    rd(16'h1800);   check(q == 8'hFF, "10x: the write-handshake (idle: empty, no underrun, reserved 1s)", q, 8'hFF);
    wr(16'h1A00, 8'h04);                                 // L6 being set with L7 = 1 and A0 = 1: a mode write
    rd(16'h1C00);   check(q[4:0] == 5'h04, "a write at $1A00 from L7 = 1 also reaches the mode register", q[4:0], 5'h04);
    wr(16'h1E00, 8'h04); wr(16'h0200, 8'h17);                 // L6 = L7 = 1: ANY A0 = 1 address writes
    rd(16'h1C00);   check(q[4:0] == 5'h17 && latches[0] == 1, "... and so does PH0-on ($0200), setting PH0 too", q[4:0], 5'h17);
    wr(16'h1E00, 8'h17); wr(16'h0000, 8'h00);                 // A0 = 0 with L6 = L7 = 1: a read, not a write
    rd(16'h1C00);   check(q[4:0] == 5'h17, "an A0 = 0 access does not write", q[4:0], 5'h17);
    rd(16'h1800);   wr(16'h1E00, 8'h04); rd(16'h1C00);   // L6 0, L7 1: the handshake - a write there is nothing
    rd(16'h1A00);   rd(16'h1C00);
                    check(q[4:0] == 5'h17, "a write at $1E00 with L6 = 0 writes nothing", q[4:0], 5'h17);

    // ---- 4. the mode-set loop
    $display("---- 4. the ROM's mode-set loop, $408006AA (5.6 item 1)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    n = 0;
    begin : modeloop
      forever begin
        n = n + 1;
        rd(16'h1000); rd(16'h1A00); rd(16'h1C00); b = q;
        if (n == 1) check(b[7] == 1, "no drive enabled: SENSE (status bit 7) reads 1", b[7], 1);
        if (b[5]) begin if (n > 50) disable modeloop; end
        else if ((b & 8'h17) == 8'h17) disable modeloop;
        else begin wr(16'h1E00, 8'h17); rd(16'h1C00); end
        if (n > 50) disable modeloop;
      end
    end
    rd(16'h1800);
    check(n == 2, "the loop exits on its second pass", n, 2);
    check(swim.iwm_mode == 5'h17, "with mode $17: latch, async, timer off, 8 MHz, slow", swim.iwm_mode, 5'h17);
    check(latches[7:6] == 2'b00 && latches[4] == 0, "and leaves L7, L6 and MotorOn clear", latches, 0);

    // ---- 5. the MotorOn timer
    $display("---- 5. the MotorOn timer (5.2.1, 5.2.3)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1400); rd(16'h1200);                          // drive 1, MotorOn: mode 0, the timer enabled
    check(!enbl1_n, "/ENBL1 low with MotorOn", enbl1_n, 0);
    rd(16'h1000); t0 = t_latch;                          // MotorOn off: the timer starts at this strobe
    clocks_until_enbl1_high(20);
    check(!enbl1_n, "held after MotorOn clears (mode bit 2 = 0)", enbl1_n, 0);
    rd(16'h1A00); rd(16'h1C00);
    check(q[5] == 1, "status bit 5 still 1 while the timer runs", q[5], 1);
    wr(16'h1E00, 8'h1F);                                 // L6 = L7 = 1 with the delayed MotorOn up: the DATA register
    rd(16'h1C00);
    check(q[4:0] == 5'h00, "the mode register is unreachable while the timer runs", q[4:0], 0);
    rd(16'h1800);
    clocks_until_enbl1_high(9_000_000);
    check(n >= 8388708 - 2 && n <= 8388708 + 8, "released 2^23 + 100 FCLK after MotorOn cleared", n, 8388708);
    rd(16'h1A00); rd(16'h1C00);
    check(q[5] == 0, "status bit 5 back to 0", q[5], 0);
    rd(16'h1800);
    // M16/M8 through the ISM's register 2, ACTION low; then OVERRIDE
    rd(16'h1A00);                                        // L6 1 first: the four writes need L6 = L7 = 1
    wr(16'h1E00, 8'h40); wr(16'h1E00, 8'h00); wr(16'h1E00, 8'h40); wr(16'h1E00, 8'h40);
    check(ism == 1, "(the ISM entered for the configuration write)", ism, 1);
    wr(16'h0400, 8'h40);                                 // M16/M8
    wr(16'h0C00, 8'hF8); rd(16'h1C00); rd(16'h1800);
    check(ism == 0, "(and left)", ism, 0);
    rd(16'h1200); rd(16'h1000); t0 = t_latch;
    clocks_until_enbl1_high(18_000_000);
    check(n >= 2 * 8388708 - 2 && n <= 2 * 8388708 + 8, "M16/M8: the timer takes twice as long", n, 2 * 8388708);
    rd(16'h1A00); wr(16'h1E00, 8'h40); wr(16'h1E00, 8'h00); wr(16'h1E00, 8'h40); wr(16'h1E00, 8'h40);
    wr(16'h0400, 8'h80);                                 // OVERRIDE, M16/M8 off
    wr(16'h0C00, 8'hF8); rd(16'h1C00); rd(16'h1800);
    rd(16'h1200); rd(16'h1000);
    repeat (100) @(posedge clk);
    check(!enbl1_n, "OVERRIDE: the timer still runs after MotorOn clears", enbl1_n, 0);
    rd(16'h1600); rd(16'h1400);                          // toggle the drive select
    check(enbl1_n && enbl2_n, "... and a drive-select toggle kills it", {enbl1_n, enbl2_n}, 3);

    // ---- 6. the switch
    $display("---- 6. the switch between the register sets (5.2.3)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1400); rd(16'h1C00); rd(16'h1000); rd(16'h1A00);
    wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17);
    check(ism == 0, "1, 0, 1, 0: no switch", ism, 0);
    wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    check(ism == 1, "1, 0, 1, 1 (the ROM's $57, $17, $57, $57): the ISM", ism, 1);
    wr(16'h0C00, 8'h40);
    check(ism == 0, "write-zeros with bit 6: the IWM again", ism, 0);
    rd(16'h1C00); rd(16'h1800);
    wr(16'h0C00, 8'h00);                                 // (an IWM PH3-low access, data ignored)
    rd(16'h1200);                                        // MotorOn on
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    check(ism == 0, "with MotorOn set the four writes reach the data register: no switch", ism, 0);
    rd(16'h1C00); rd(16'h1800);
    rd(16'h1000); t0 = t_latch;                          // MotorOn off (mode $17 from the writes above: the timer is off)
    clocks_until_enbl1_high(20);
    check(enbl1_n, "(the enable drops at once: mode bit 2 is set)", enbl1_n, 1);
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    check(ism == 1, "with the timer run out, the same writes switch", ism, 1);
    wr(16'h0E00, 8'h82);                                 // ISM MotorOn and drive 1
    check(!enbl1_n, "ISM mode bits 7 and 1: /ENBL1 low", enbl1_n, 0);
    wr(16'h0C00, 8'h40);
    check(ism == 1, "write-zeros bit 6 with MotorOn left set: refused (MOTOREN must be low)", ism, 1);
    wr(16'h0C00, 8'hC0);
    check(ism == 0 && enbl1_n, "write-zeros $C0 clears MotorOn and switches", {ism, enbl1_n}, 1);

    // ---- 7. phases
    $display("---- 7. the phase register (5.2.2, 5.2.3)");
    rd(16'h1C00); rd(16'h1800);
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    bad = 0;
    for (i = 5; i < 8; i = i + 1) begin
      wr(16'h0800, 8'hF0 | i); rd(16'h1800); if (q != (8'hF0 | i)) bad = bad + 1;
    end
    check(bad == 0, "$F5, $F6, $F7 each read back whole (the ROM's echo)", bad, 0);
    wr(16'h0800, 8'h3A);                                 // PH3, PH2 inputs; PH1 out 1, PH0 out 0
    check(ph_oe == 4'b0011 && ph_out[1:0] == 2'b10, "direction bits 7-4 gate the pins", {ph_oe, ph_out}, 8'h3A);
    #1 ph_ext = 4'b0100;
    rd(16'h1800);
    check(q == 8'h36, "an input line reads its pin, an output its level", q, 8'h36);
    wr(16'h0C00, 8'hF8); rd(16'h1C00); rd(16'h1800);
    rd(16'h0E00);                                        // IWM: PH3 latch on - but the line is an input
    check(ph_oe[3] == 0, "the ISM's direction bits still hold in the IWM (the chip spec)", ph_oe, 4'b0011);
    #1 ph_ext = 4'b1111;
    rd(16'h0C00);

    // ---- 8. the mode register
    $display("---- 8. mode write-zeros and write-ones (5.2.2)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1A00); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    rd(16'h1C00);   check(q == 8'h40, "status after the switch: bit 6 reads 1", q, 8'h40);
    wr(16'h0E00, 8'h30); rd(16'h1C00);
    check(q == 8'h70, "write-ones $30: bits 5 and 4 set", q, 8'h70);
    wr(16'h0C00, 8'h10); rd(16'h1C00);
    check(q == 8'h60, "write-zeros $10: bit 4 cleared, the rest kept", q, 8'h60);
    wr(16'h0C00, 8'h20);

    // ---- 9. the parameter RAM
    $display("---- 9. the parameter RAM (5.2.2)");
    for (i = 0; i < 16; i = i + 1) wr(16'h0600, 8'h10 + i * 3);
    wr(16'h0C00, 8'h00);                                 // write-zeros: the index to 0
    bad = 0;
    for (i = 0; i < 16; i = i + 1) begin rd(16'h1600); if (q != 8'h10 + i * 3) bad = bad + 1; end
    check(bad == 0, "sixteen bytes written and read back in order", bad, 0);
    rd(16'h1600);   check(q == 8'h10, "the index wraps after sixteen", q, 8'h10);
    wr(16'h0C00, 8'h00); rd(16'h1600); rd(16'h1600);
    wr(16'h0C00, 8'h00); rd(16'h1600);
    check(q == 8'h10, "a write-zeros write resets the index", q, 8'h10);

    // ---- 10. setup, the IWM configuration
    $display("---- 10. setup and the IWM configuration (5.2.2, 5.2.3)");
    wr(16'h0A00, 8'h20); rd(16'h1A00);
    check(q == 8'h20, "setup $20 reads back", q, 8'h20);
    wr(16'h0A00, 8'h00);
    wr(16'h0400, 8'hE0);
    check(swim.iwm_cfg == 3'b111, "register 2 with ACTION low: OVERRIDE, M16/M8, MODIFY", swim.iwm_cfg, 7);
    wr(16'h0400, 8'h00);
    rd(16'h1400);   check(q == 8'h00, "the error register reads 0 (nothing has happened)", q, 0);
    wr(16'h0C00, 8'hF8); rd(16'h1C00); rd(16'h1800);

    // ---- 11. the drive through the ROM's encoding
    $display("---- 11. the empty internal FDHD and the absent external (5.5)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1400); rd(16'h1200);                          // drive 1 enabled, as the ROM's $B40 vector does
    drv_read(4'hD); check(sns == 0, "$D rNoDriveAdr: 0, a drive is present", sns, 0);
    drv_read(4'h9); check(sns == 1, "$9 rDoubleSidedAdr: 1", sns, 1);
    drv_read(4'hF); check(sns == 1, "$F r1MegMediaAdr: 1 (no HD medium)", sns, 1);
    drv_read(4'h5); check(sns == 1, "$5 rMFMDriveAdr: 1, a SuperDrive", sns, 1);
    drv_read(4'h2); check(sns == 1, "$2 rNoDiskInPlAdr: 1, no disk", sns, 1);
    drv_read(4'hC); check(sns == 0, "$C rEjectOnAdr: 0", sns, 0);
    drv_read(4'h8); check(sns == 1, "$8 rMotorOffAdr: 1, the spindle off", sns, 1);
    drv_read(4'h4); check(sns == 1, "$4 rStepOffAdr: 1, not stepping", sns, 1);
    drv_read(4'hA); check(sns == 0, "$A rNotTrack0Adr: 0, at track 0 from power-up", sns, 0);
    drv_read(4'h7); check(sns == 0, "$7 rMFMModeOnAdr: 0, GCR from power-up", sns, 0);
    drv_read(4'hB); check(sns == 1, "$B rNotReadyAdr: 1", sns, 1);
    rd(16'h1600); bad = 0;                               // drive 2: nothing there
    for (i = 0; i < 16; i = i + 1) begin drv_read(i); if (sns != 1) bad = bad + 1; end
    check(!enbl2_n, "(drive 2 enabled)", enbl2_n, 0);
    check(bad == 0, "the absent external reads 1 at all sixteen", bad, 0);
    rd(16'h1400);

    // ---- 12. commands
    $display("---- 12. the drive's commands (5.5)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1400); rd(16'h1200);
    drv_cmd(4'h8);  drv_read(4'h8); check(sns == 0, "command $8 motor on: $8 reads 0", sns, 0);
    drv_cmd(4'h9);  drv_read(4'h8); check(sns == 1, "command $9 motor off: $8 reads 1", sns, 1);
    drv_cmd(4'h0);  drv_step;
    drv_read(4'hA); check(sns == 1, "direction inward, a step: off track 0", sns, 1);
    check(drive.track == 1, "(track 1)", drive.track, 1);
    drv_read(4'h0); check(sns == 0, "$0 reads the direction: inward", sns, 0);
    drv_cmd(4'h1);  drv_read(4'h0); check(sns == 1, "direction outward", sns, 1);
    drv_step;       drv_read(4'hA); check(sns == 0, "a step out: track 0", sns, 0);
    drv_step;       check(drive.track == 0, "no step below track 0", drive.track, 0);
    drv_cmd(4'h6);  drv_read(4'h7); check(sns == 1, "command $6: MFM mode", sns, 1);
    drv_cmd(4'h7);  drv_read(4'h7); check(sns == 0, "command $7: GCR mode", sns, 0);
    drv_cmd(4'h3);  drv_read(4'hC); check(sns == 0, "command $3 (the eject-latch reset): $C still 0", sns, 0);
    drv_cmd(4'hD);  drv_read(4'h2); check(sns == 1, "command $D (eject) with no disk: still no disk", sns, 1);
    rd(16'h1000);

    // ---- 13. the SWIM probe of the .Sony Open, then its drive reads
    $display("---- 13. the ROM's SWIM probe, $4082E6A2, and Open's drive reads (5.6 item 3)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    rd(16'h1400); rd(16'h1C00); rd(16'h1000); rd(16'h1A00);
    wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h17); wr(16'h1E00, 8'h57); wr(16'h1E00, 8'h57);
    bad = 0;
    wr(16'h0800, 8'hF5); rd(16'h1800); if (q != 8'hF5) bad = bad + 1;
    wr(16'h0800, 8'hF6); rd(16'h1800); if (q != 8'hF6) bad = bad + 1;
    wr(16'h0800, 8'hF7); rd(16'h1800); if (q != 8'hF7) bad = bad + 1;
    check(bad == 0, "the three echoes match: the ROM sets $134 (a SWIM)", bad, 0);
    wr(16'h0C00, 8'hF8); rd(16'h1C00); rd(16'h1800); rd(16'h1200);
    check(ism == 0 && latches[7:6] == 2'b00, "back in the IWM with L7 and L6 clear", {ism, latches[7:6]}, 0);
    check(latches[3:0] == 4'h7 && !enbl1_n, "the phases carried over (0111) and drive 1 enabled", {latches[3:0], enbl1_n}, 5'b01110);
    drv_read(4'hD); check(sns == 0, "Open: drive 1 present", sns, 0);
    drv_read(4'h9); check(sns == 1, "Open: double-sided", sns, 1);
    drv_read(4'h5); check(sns == 1, "Open: a SuperDrive", sns, 1);
    rd(16'h1600);
    drv_read(4'hD); check(sns == 1, "Open: drive 2 absent", sns, 1);

    // ---- 15. rung 2: the IWM's read path
    $display("---- 15. the IWM read path: windows, blanking, the latch, self-sync (5.12.2)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    set_mode(8'h17);                                     // slow, 8M: the ROM's mode
    rd(16'h1200);                                        // MotorOn: /ENBL1, the data register selected
    drv_addr(4'h1);                                      // the drive at RdData0: reads 1 with no disk
    rd(16'h1C00); rd(16'h1800);                          // L7 and L6 clear: the read state

    // 8 ones at the cell: $FF
    band(32, 32, 8'hFF, "eight 1s at the 32-FCLK cell: $FF");
    // the bands, each after a leading 1, then 1s: 1 X 1... (slow 8M: CLK = FCLK/2)
    band(2*7,  32, 8'hFF, "Nclks 7 (below the table, above the blanking): a 1");
    band(2*8,  32, 8'hFF, "Nclks 8: a 1");
    band(2*23, 32, 8'hFF, "Nclks 23: a 1");
    band(2*24, 32, 8'hBF, "Nclks 24: a 01");
    band(2*39, 32, 8'hBF, "Nclks 39: a 01");
    band(2*40, 32, 8'h9F, "Nclks 40: a 001");
    band(2*55, 32, 8'h9F, "Nclks 55: a 001");
    band(2*56, 32, 8'h8F, "Nclks 56: a 0001 (past the table: one more window)");

    // the blanking: an extra falling edge 10 FCLK after a transition is
    // ignored, one 14 FCLK after is taken (then a 01 either way follows)
    // (sheet 53: in slow mode under 12 FCLK always ignored, 12-14 "sometimes",
    // over 14 always taken - the RTL ignores 12 and 13; neither is checked)
    blank_test(10, 8'hBF, "an edge 10 FCLK after the last is ignored (blanking 12 FCLK)");
    blank_test(11, 8'hBF, "an edge 11 FCLK after the last is ignored (under 12: always)");
    blank_test(14, 8'hDF, "an edge 14 FCLK after the last is taken");

    // the latch: held until read, cleared 14 FCLK after a valid read
    idle_flush;
    play_bits(8'b11010101, 8);                          // $D5, no reads while it plays
    repeat (400) @(posedge clk);
    rd(16'h1800);
    check(q == 8'hD5, "the byte holds in the data register until it is read", q, 8'hD5);
    rd(16'h1800);
    check(q == 8'hD5, "and still reads within 14 FCLK of the valid read", q, 8'hD5);
    repeat (20) @(posedge clk);
    rd(16'h1800);
    check(q == 8'h00, "then clears: 14 FCLK after a valid read", q, 0);
    // a valid read is D7 = 1 out of the data register (sheet 53): reading
    // the status register with the byte latched starts no clear
    idle_flush;
    play_bits(8'b11010101, 8);
    repeat (400) @(posedge clk);
    rd(16'h1A00);                                       // L6 set: the status register
    repeat (20) @(posedge clk);
    rd(16'h1800);                                       // L6 clear: the data register again
    check(q == 8'hD5, "a status read is not a valid read: the byte survives it", q, 8'hD5);
    // OUR READING, pinned (Daniel 2026-09-28): the drawing says only
    // "cleared 14 FCLK periods ... after a valid data read", and the ROM,
    // reading each byte once 256 FCLK apart, reaches neither case below.
    // The clear counts from the latest valid read (a second one re-arms it)
    idle_flush;
    play_bits(8'b11010101, 8);
    repeat (400) @(posedge clk);
    rd(16'h1800);                                       // valid read at T
    repeat (6) @(posedge clk); rd(16'h1800);            // T+10: valid again, re-arms
    repeat (6) @(posedge clk); rd(16'h1800);            // T+20: past T+14, before T+24
    check(q == 8'hD5, "our reading: a second valid read re-arms the clear", q, 8'hD5);
    // and a byte latching while a clear is pending cancels it: the new
    // byte waits for its own valid read
    idle_flush;
    fork
      begin play_bits(16'hD5FF, 16); repeat (64) @(posedge clk); end
      begin
        wait (swim.sr == 8'h7F);                         // seven 1s of $FF: its last edge is 32 FCLK off
        repeat (24) @(posedge clk);
        rd(16'h1800);                                    // $D5, a valid read, a few FCLK before $FF latches
        b = q;
        repeat (30) @(posedge clk);
        rd(16'h1800);
      end
    join
    check(b == 8'hD5, "our reading: the first byte read just before the next latches", b, 8'hD5);
    check(q == 8'hFF, "our reading: a new byte cancels the pending clear", q, 8'hFF);

    // self-sync from three bit offsets
    for (i = 0; i < 3; i = i + 1) sync_test(i);

    // the fast 8M and slow 7M bands (CLK = FCLK; FCLK/2 with the 7M windows)
    set_mode(8'h1F);                                    // fast, 8M
    rd(16'h1200); drv_addr(4'h1); rd(16'h1C00); rd(16'h1800);
    band(23, 16, 8'hFF, "fast 8M: Nclks 23 a 1 (the 16-FCLK cell)");
    band(24, 16, 8'hBF, "fast 8M: Nclks 24 a 01");
    set_mode(8'h07);                                    // slow, 7M
    rd(16'h1200); drv_addr(4'h1); rd(16'h1C00); rd(16'h1800);
    band(2*20, 28, 8'hFF, "slow 7M: Nclks 20 a 1 (the 28-FCLK cell)");
    band(2*21, 28, 8'hBF, "slow 7M: Nclks 21 a 01");
    rd(16'h1000);

    $display("---- 16. the IWM write path: the state, the loads, WRDATA, the handshake (5.15.2)");
    reset_n = 0; repeat (3) @(posedge clk); #1 reset_n = 1; @(posedge clk);
    set_mode(8'h17);                                     // slow, 8M: the ROM's mode
    rd(16'h1200);                                        // MotorOn
    check(wrreq_n == 1, "/WRREQ high before the write state", wrreq_n, 1);
    ned = 0; #1 wlog = 1;
    wr_enter(8'hFF);
    @(posedge clk); #1;
    check(wrreq_n == 0, "/WRREQ low once L7 is set with MotorOn (IWM Spec p. 7)", wrreq_n, 0);
    rd(16'h1800);                                        // the handshake, before the first load
    check(q[7] == 0 && q[6] == 1 && q[5:0] == 6'h3F,
          "the handshake at entry: buffer full (the entry's byte), no underrun, bits 5-0 read 1", q, 8'h7F);
    // the ROM's sector opening, written at the ROM's pace
    nexp = 0;
    wexp[nexp] = 8'hFF; nexp = nexp + 1;
    for (i = 0; i < 5; i = i + 1) begin wexp[nexp] = (i == 0) ? 8'h3F : (i == 1) ? 8'hCF : (i == 2) ? 8'hF3 : (i == 3) ? 8'hFC : 8'hFF; nexp = nexp + 1; end
    wexp[nexp] = 8'hD5; nexp = nexp + 1; wexp[nexp] = 8'hAA; nexp = nexp + 1; wexp[nexp] = 8'hAD; nexp = nexp + 1;
    wexp[nexp] = 8'h9A; nexp = nexp + 1;                 // a sector code
    for (i = 0; i < 6; i = i + 1) begin wexp[nexp] = 8'h96 + i; nexp = nexp + 1; end
    wexp[nexp] = 8'hDE; nexp = nexp + 1; wexp[nexp] = 8'hAA; nexp = nexp + 1;
    wexp[nexp] = 8'hFF; nexp = nexp + 1; wexp[nexp] = 8'hFF; nexp = nexp + 1;
    for (i = 1; i < nexp; i = i + 1) wr_byte(wexp[i]);
    rd(16'h1800);
    while (!q[7]) rd(16'h1800);                          // the last byte loaded
    b = q;
    repeat (300) @(posedge clk);                         // and shifted out
    rd(16'h1C00);                                        // L7 cleared: out of the write state ($4082E656)
    #1 wlog = 0;
    check(b[6] == 1, "no underrun at the ROM's pace (handshake bit 6)", b, 8'hFF);
    // (the log sees an edge a clock after it happens)
    check(ned > 0 && ed[0] - t_enter >= 14 && ed[0] - t_enter <= 16,
          "the first transition (FF's MSB) 7 CLK after entry: 14 FCLK in slow mode", ed[0] - t_enter, 15);
    wr_decode(0, 32, nexp);
    check(wbad == 0, "every transition on the 32-FCLK cell grid (mode $17)", wbad, 0);
    bad = 0;
    for (i = 0; i < nexp; i = i + 1) if (wbits[i] !== wexp[i]) bad = bad + 1;
    check(bad == 0, "the ROM's bytes recovered whole from WRDATA, MSB first, a one a transition", bad, 0);
    check(wrreq_n == 1, "/WRREQ high again with L7 clear", wrreq_n, 1);

    // the loads every 8 cells, and the handshake's bit 7 with them
    wr_enter(8'hFF);
    @(posedge swim.wload); t1 = cyc;
    @(posedge swim.wload); t2 = cyc;
    check(t2 - t1 == 256, "a load every 8 cells: 256 FCLK in mode $17", t2 - t1, 256);
    rd(16'h1800);
    check(q[7] == 1, "bit 7 set after a load with nothing written: buffer empty", q, 8'hFF);
    repeat (10) @(posedge clk);
    wr(16'h1A00, 8'h96);
    rd(16'h1800);
    check(q[7] == 0, "a write clears bit 7", q, 8'h7F);
    // the last write before a load is the one used
    @(posedge swim.wload);
    repeat (20) @(posedge clk);
    ned = 0; #1 wlog = 1;
    wr(16'h1A00, 8'hAA); wr(16'h1A00, 8'hD5);           // two writes in one buffer window
    @(posedge swim.wload); repeat (2) @(posedge clk);
    check(swim.wsr_last == 8'hD5, "the last write before the load is the byte shifted (User's Ref p. 12)", swim.wsr_last, 8'hD5);
    // the 9-FCLK lock: a write whose strobe lands within 9 FCLK of a load
    // is ignored, one after it is taken
    #1 wlog = 0;
    @(posedge swim.wload);                               // the strobe 4 FCLK after this load
    wr(16'h1A00, 8'hB5);
    rd(16'h1800);
    check(q[7] == 1, "a write 4 FCLK after a load is ignored (the 9-FCLK lock)", q, 8'hFF);
    @(posedge swim.wload);
    repeat (8) @(posedge clk);                           // the strobe 12 FCLK after the load
    wr(16'h1A00, 8'hB5);
    rd(16'h1800);
    check(q[7] == 0, "a write 12 FCLK after a load is taken", q, 8'h7F);
    // the underrun: no write before the next load
    @(posedge swim.wload);                               // B5 loaded; the buffer is empty
    @(posedge swim.wload);                               // nothing written: the underrun
    @(posedge clk); #1;
    check(wrreq_n == 1, "an underrun raises /WRREQ (sheet 52)", wrreq_n, 1);
    rd(16'h1800);
    check(q[6] == 0, "and clears the handshake's bit 6", q, 8'h80);
    wr(16'h1A00, 8'h96);
    @(posedge clk); #1;
    check(wrreq_n == 1, "a later write does not lower /WRREQ again", wrreq_n, 1);
    rd(16'h1C00);                                        // L7 cleared
    rd(16'h1E00);                                        // L7 set again from L6 = 0: the handshake, before any load
    check(q[6] == 1 && q[7] == 1, "clearing L7 resets the underrun and empties the buffer (handshake $FF)", q, 8'hFF);
    rd(16'h1C00);
    wr_enter(8'hFF);
    @(posedge clk); #1;
    check(wrreq_n == 0, "the next write state lowers /WRREQ again", wrreq_n, 0);
    rd(16'h1C00);
    // /WRREQ needs MotorOn: L7 set with MotorOn off and the timer disabled
    rd(16'h1000); rd(16'h1800); rd(16'h1E00);            // MotorOn off, L6 clear, L7 set: the handshake state
    @(posedge clk); #1;
    check(wrreq_n == 1, "/WRREQ high with L7 set and MotorOn off", wrreq_n, 1);
    rd(16'h1C00);

    // the cell in the other modes: 7M slow (28 FCLK) and 8M fast (16)
    set_mode(8'h07); rd(16'h1200);
    ned = 0; #1 wlog = 1;
    wr_enter(8'hFF); wr_byte(8'hFF);
    @(posedge swim.wload); repeat (40) @(posedge clk);
    #1 wlog = 0; rd(16'h1C00);
    check(ned >= 9 && ed[1] - ed[0] == 28 && ed[8] - ed[7] == 28, "7M slow: the 28-FCLK cell", ed[1] - ed[0], 28);
    set_mode(8'h1F); rd(16'h1200);
    ned = 0; #1 wlog = 1;
    wr_enter(8'hFF); wr_byte(8'hFF);
    @(posedge swim.wload); repeat (40) @(posedge clk);
    #1 wlog = 0; rd(16'h1C00);
    check(ned >= 9 && ed[1] - ed[0] == 16 && ed[8] - ed[7] == 16, "8M fast: the 16-FCLK cell", ed[1] - ed[0], 16);
    check(ned >= 1 && ed[0] - t_enter == 8, "8M fast: the first load 7 CLK (7 FCLK) after entry (+1 for the log)", ed[0] - t_enter, 8);
    rd(16'h1000);

    // ---- verdict
    if (fails == 0) $display("==== PASS: %0d checks, the SWIM holds to plan 5.2 and 5.5", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin
    #5_000_000_000;
    $display("==== FAIL: bench timed out (5 s)");
    $finish;
  end

endmodule
