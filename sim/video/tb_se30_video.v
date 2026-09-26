// tb_se30_video.v - the SE/30's built-in video, held to the documentation.
//
// WHAT THIS PROVES
//   rtl/se30_video.v is the six video PALs, the counters, the shifter, the
//   VRAM and the declaration ROM of schematic sheet 5 (SE30_PLAN.md 2.6).
//   This bench holds it to the numbers the documentation gives and to what
//   the declaration ROM's own driver code does (plan 2.9, 2.10, 2.11):
//
//     1. 704 pixel clocks per line                       Guide 12
//     2. 370 lines per frame, 342 of them active, each
//        fetching 64 bytes; active lines are 1..342       Guide 12; 2.12
//     3. HSYNC* low 288 clocks from pixel 535             2.12 (UG7 run)
//     4. VSYNC* low 4 lines from line 343                 2.12 (UG6 run)
//     5. VRAM through the slot port: the first active
//        line shows row 1 (offset $40) of the page PA6
//        selects, PA6 = 1 being the upper 32KB; MSB
//        first; 1 = black                                 2.10 items 2-3; Guide 12
//     6. blanking shows black                             2.9 (shifter fill)
//     7. DSACK0* is driven only during an access          2.9 (UE6 read)
//     8. the declaration ROM is the A16 = 1 half, 8KB,
//        mirrored, byte-exact against the image           2.6, 2.10
//     9. IRQ6*: set by VSYNC* while PB6 = 0, held,
//        cleared by PB6 = 1, not re-fired by PB6 = 0
//        until the next VSYNC*                            2.9 item 3; 2.10 item 1
//    10. PrimaryInit's grey fill: 43,776 byte writes
//        through the port, rows alternating $AA/$55,
//        then the first, second and last active lines
//        show the right rows                              2.10
//
//    11. the slot access, as UE7 does it (plan 2.12): 6 or 7
//        clocks alternating with the idle phase; a request
//        at pixel 535 waits for the row transfer and is
//        acknowledged at pixel 560; at 556 it takes 7, at
//        557 6; the same in a blank line                  2.12 (UE7/UE6 run)
//
//   Cycle length here is counted from the clock sel is first seen to the
//   clock after the one in which DSACK0* is sampled, plus the release
//   clock: a 2-wait-state cycle reads as 6.
//
// THE 370/372 QUESTION
//   The DUT is built to the Guide's 370 (parameter V_TOTAL).  Plan 2.9
//   records why Bolle's PAL reads as 372 and what would close it.  The
//   frame count here follows V_TOTAL, so the switch is one number in the
//   DUT and none here.
//
// HOW IT DRIVES THE DUT
//   A CPU cycle is sel/AS*/DS* asserted together with the address, R/W and
//   (for a write) the data, held until DSACK0* is seen, released one clock
//   later; read data is sampled the clock after DSACK0*, where the 68030
//   latches it (end of S4).  The slot-E decode itself (A31-A25 ones,
//   A24 = 0, A23-A17 ignored) is GLUE's and is not in this DUT: the bench
//   presents A16-A0 only.
//
// ROM
//   Reads declrom.hex from the working directory: the 8KB Apple 341-0650
//   image (MAME's se30vrom.uk6, CRC32 b74c3463), one byte per line.
//   run.sh makes it.  Not in the repo.

`timescale 1ns/1ps

module tb_se30_video;

  // ---------------------------------------------------------------- clock
  // 15.6672 MHz: 63.8298 ns per pixel.
  reg clk = 0;
  always #31.9149 clk = ~clk;
  reg reset_n = 0;

  // ------------------------------------------------------------ constants
  localparam H_TOTAL      = 704;
  localparam H_ACTIVE     = 512;
  localparam V_TOTAL      = 370;
  localparam V_ACTIVE     = 342;
  localparam FIRST_ACTIVE = 1;                   // line 0 is blank (2.12: pixel 0 = clock after HCTRRST, line 0 = first full line after LCTRRST)
  localparam LAST_ACTIVE  = FIRST_ACTIVE + V_ACTIVE - 1;   // 342
  localparam HSYNC_START  = 535;
  localparam HSYNC_LEN    = 288;
  localparam VSYNC_START  = 343;
  localparam VSYNC_LEN    = 4;
  localparam BERR_MIN_CLK = 288;                 // 18.4 us, the earliest UI6 bus error (2.11.4)

  // -------------------------------------------------------------- DUT
  reg         sel = 0, as_n = 1, ds_n = 1, rw = 1;
  reg  [16:0] addr = 0;
  reg   [7:0] din = 0;
  wire  [7:0] dout;
  wire        dsack0_n;
  reg         page = 1, vsyncen_n = 1;
  wire        vidout, hsync_n, vsync_n, hblank, vblank, irq6_n;

  se30_video #(.DECLROM_HEX("declrom.hex"), .V_TOTAL(V_TOTAL)) uut (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n),                // clocked at C16M here
    .declrom_we(1'b0), .declrom_waddr(13'd0), .declrom_wdata(8'd0),  // the image is preloaded
    .sel(sel), .as_n(as_n), .ds_n(ds_n), .rw(rw), .addr(addr), .din(din),
    .dout(dout), .dsack0_n(dsack0_n),
    .page(page), .vsyncen_n(vsyncen_n),
    .vidout(vidout), .hsync_n(hsync_n), .vsync_n(vsync_n),
    .hblank(hblank), .vblank(vblank), .irq6_n(irq6_n));

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*72-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // ---------------------------------------------------- position tracking
  // Pixel and line counters kept by the bench from the DUT's own counter
  // clears, so every measurement is relative to hctrrst/lctrrst as the
  // PALs define them.
  integer px = 0, line = 0, fetches = 0;
  integer line_fetches [0:1023];
  integer i;
  initial for (i = 0; i < 1024; i = i + 1) line_fetches[i] = 0;
  always @(posedge clk) begin
    if (uut.hctrrst) begin
      line_fetches[line] <= fetches;
      fetches <= uut.fetch ? 1 : 0;
      px   <= 0;
      line <= uut.lctrrst ? 0 : line + 1;
    end else begin
      px <= px + 1;
      if (uut.fetch) fetches <= fetches + 1;
      if (uut.lctrrst) line <= 0;
    end
  end

  task wait_hctrrst; begin @(posedge clk); while (!uut.hctrrst) @(posedge clk); end endtask
  task wait_lctrrst; begin @(posedge clk); while (!uut.lctrrst) @(posedge clk); end endtask
  task wait_line(input integer n); begin while (line != n) @(posedge clk); end endtask

  // ------------------------------------------------------------ CPU port
  integer cyc_len, cyc_min = 1000000, cyc_max = 0, cyc_n = 0, dsack_px;
  reg cyc_timeout = 0;

  // Chained writes with the 68030's back-to-back timing: the next cycle's
  // address and data replace the last one's at the edge after DSACK0* was
  // sampled, with sel and AS* held, so the DUT sees the new request one
  // clock earlier than cpu_cycle's release-then-assert would give.  Rows
  // alternate $AA/$55 like PrimaryInit's fill.  ack_gap[i] is the clocks
  // between DSACK0* of write i-1 and write i.
  integer ack_gap [0:7];
  task cpu_burst(input [16:0] base, input integer count, output integer clocks);
    integer i, t, last;
    begin
      @(posedge clk);
      sel <= 1; as_n <= 0; ds_n <= 0; rw <= 0; addr <= base; din <= 8'hAA;
      t = 0; last = 0;
      for (i = 0; i < count; i = i + 1) begin
        @(posedge clk); t = t + 1;
        while (dsack0_n) begin @(posedge clk); t = t + 1; end
        if (i < 8) ack_gap[i] = t - last;
        last = t;
        @(posedge clk); t = t + 1;      // the 68030 latches / the DUT writes; then the next request
        if (i < count - 1) begin addr <= base + i + 1; din <= (((i + 1) / 64) % 2) ? 8'h55 : 8'hAA; end
        else begin sel <= 0; as_n <= 1; ds_n <= 1; end
      end
      @(posedge clk); t = t + 1;
      clocks = t;
    end
  endtask

  task cpu_cycle(input is_read, input [16:0] a, input [7:0] d, output [7:0] q);
    integer n;
    begin
      @(posedge clk);
      sel <= 1; as_n <= 0; ds_n <= 0; rw <= is_read; addr <= a; din <= d;
      n = 0;
      @(posedge clk);
      while (dsack0_n && n < 4000) begin n = n + 1; @(posedge clk); end
      if (n >= 4000) cyc_timeout = 1;
      dsack_px = px;                    // the pixel in which DSACK0* was sampled low
      q = dout;                         // the 68030 latches at the end of S4: one clock after DSACK
      @(posedge clk);
      q = dout;
      sel <= 0; as_n <= 1; ds_n <= 1;
      @(posedge clk);
      cyc_len = n + 3;
      if (cyc_len < cyc_min) cyc_min = cyc_len;
      if (cyc_len > cyc_max) cyc_max = cyc_len;
      cyc_n = cyc_n + 1;
    end
  endtask

  task cpu_write(input [16:0] a, input [7:0] d);
    reg [7:0] q; begin cpu_cycle(0, a, d, q); end
  endtask
  task cpu_read(input [16:0] a, output [7:0] q);
    begin cpu_cycle(1, a, 8'h00, q); end
  endtask

  // A read whose sel is first seen by the DUT during pixel s of the
  // current line (px tracks the DUT's horizontal count).
  task slot_at(input integer s, output [7:0] q);
    begin
      while (px != s - 2) @(posedge clk);
      cpu_cycle(1, 17'h00000, 8'h00, q);
    end
  endtask

  // DSACK0* must never be low outside an access (test 7).
  integer dsack_idle_low = 0;
  always @(posedge clk) if (!sel && !dsack0_n) dsack_idle_low = dsack_idle_low + 1;

  // -------------------------------------------------- the reference ROM
  reg [7:0] rom_file [0:8191];
  initial $readmemh("declrom.hex", rom_file);

  // ---------------------------------------------------------- line capture
  reg [0:H_TOTAL-1] cap;                // one whole line of vidout, pixel 0 first
  task capture_line(input integer n);
    integer k;
    begin
      wait_line(n);
      while (px != 0) @(posedge clk);
      for (k = 0; k < H_TOTAL; k = k + 1) begin cap[k] = vidout; @(posedge clk); end
    end
  endtask

  // Expected pixels of a 64-byte row: byte b, bit 7 first.
  function [0:H_ACTIVE-1] row_pixels(input [7:0] b0, input [7:0] b_other);
    integer k;
    begin
      for (k = 0; k < H_ACTIVE; k = k + 1)
        row_pixels[k] = (k < 8) ? b0[7 - k] : b_other[7 - (k % 8)];
    end
  endfunction

  // ------------------------------------------------------------ the tests
  integer n, lo, hi, cnt, first, last, bad, t0;
  reg [7:0] q, q2;
  reg ok;
  reg [0:H_ACTIVE-1] want;

  initial begin
    repeat (4) @(posedge clk);
    reset_n = 1;

    // ---- 1. line length
    $display("---- 1. line: %0d clocks", H_TOTAL);
    wait_hctrrst;
    for (i = 0; i < 3; i = i + 1) begin
      n = 0;
      @(posedge clk); n = n + 1;
      while (!uut.hctrrst) begin @(posedge clk); n = n + 1; end
      check(n == H_TOTAL, "clocks per line", n, H_TOTAL);
    end

    // ---- 2. frame length, active lines, bytes per line
    $display("---- 2. frame: %0d lines, %0d active, 64 bytes each", V_TOTAL, V_ACTIVE);
    wait_lctrrst;
    n = 0; cnt = 0; first = -1; last = -1; bad = 0; ok = 0;
    while (!ok) begin
      @(posedge clk);
      if (uut.hctrrst) begin              // the edge ending line `line`: `fetches` is its count
        n = n + 1;
        if (fetches == 64) begin cnt = cnt + 1; if (first < 0) first = line; last = line; end
        else if (fetches != 0) bad = bad + 1;
        if (uut.lctrrst) ok = 1;
      end
    end
    check(n == V_TOTAL, "lines per frame", n, V_TOTAL);
    check(cnt == V_ACTIVE, "active lines (64 fetches)", cnt, V_ACTIVE);
    check(bad == 0, "lines with a fetch count other than 0 or 64", bad, 0);
    check(first == FIRST_ACTIVE, "first active line", first, FIRST_ACTIVE);
    check(last == LAST_ACTIVE, "last active line", last, LAST_ACTIVE);

    // ---- 3. HSYNC*
    $display("---- 3. HSYNC*: low %0d clocks from pixel %0d", HSYNC_LEN, HSYNC_START);
    wait_line(100);
    while (px != 0) @(posedge clk);
    while (hsync_n) @(posedge clk);               // the low that began in the previous line
    while (!hsync_n) @(posedge clk);
    while (hsync_n) @(posedge clk);
    lo = px; n = 0;
    while (!hsync_n) begin @(posedge clk); n = n + 1; end
    check(lo == HSYNC_START, "HSYNC* falls at pixel", lo, HSYNC_START);
    check(n == HSYNC_LEN, "HSYNC* low clocks", n, HSYNC_LEN);

    // ---- 4. VSYNC*
    $display("---- 4. VSYNC*: low %0d lines from line %0d", VSYNC_LEN, VSYNC_START);
    wait_lctrrst;
    while (vsync_n) @(posedge clk);
    lo = line; n = 0;
    while (!vsync_n) begin @(posedge clk); if (uut.hctrrst) n = n + 1; end
    check(lo == VSYNC_START, "VSYNC* falls in line", lo, VSYNC_START);
    check(n == VSYNC_LEN, "VSYNC* low lines", n, VSYNC_LEN);

    // ---- 5. VRAM through the slot port; row 1 is the first visible row; PA6 picks the page
    $display("---- 5. VRAM mapping: page 0 = upper 32KB, first line = row 1, MSB first, 1 = black");
    cpu_write(17'h08000, 8'hF0);                   // page 0 row 0
    for (i = 1; i < 64; i = i + 1) cpu_write(17'h08000 + i, 8'hF0);
    cpu_write(17'h08040, 8'hC3);                   // page 0 row 1
    for (i = 1; i < 64; i = i + 1) cpu_write(17'h08040 + i, 8'h81);
    cpu_write(17'h00040, 8'h3C);                   // page 1 row 1
    for (i = 1; i < 64; i = i + 1) cpu_write(17'h00040 + i, 8'h7E);
    cpu_read(17'h08040, q);
    check(q == 8'hC3, "read back page 0 row 1 byte 0 (want $C3)", q, 8'hC3);
    cpu_read(17'h00041, q);
    check(q == 8'h7E, "read back page 1 row 1 byte 1 (want $7E)", q, 8'h7E);
    check(!cyc_timeout, "every slot cycle acknowledged", cyc_timeout, 0);
    check(cyc_max < BERR_MIN_CLK, "slot cycle inside the bus-error window (clocks)", cyc_max, BERR_MIN_CLK);
    $display("info slot cycles so far: %0d, %0d..%0d clocks each (test 11 checks the timing at known phases)", cyc_n, cyc_min, cyc_max);

    page = 1;
    wait_lctrrst;
    capture_line(FIRST_ACTIVE);
    want = row_pixels(8'hC3, 8'h81);
    check(cap[0:H_ACTIVE-1] == want, "page 0: first active line shows row 1 (C3 81..)", cap[0:15], want[0:15]);
    page = 0;
    wait_lctrrst;
    capture_line(FIRST_ACTIVE);
    want = row_pixels(8'h3C, 8'h7E);
    check(cap[0:H_ACTIVE-1] == want, "page 1: first active line shows row 1 (3C 7E..)", cap[0:15], want[0:15]);
    page = 1;

    // ---- 6. blanking is black
    $display("---- 6. blanking: black (1) outside 512 x 342");
    bad = 0;
    for (i = H_ACTIVE; i < H_TOTAL; i = i + 1) if (!cap[i]) bad = bad + 1;
    check(bad == 0, "horizontal blanking pixels that are not black", bad, 0);
    capture_line(0);
    bad = 0; for (i = 0; i < H_TOTAL; i = i + 1) if (!cap[i]) bad = bad + 1;
    capture_line(LAST_ACTIVE + 1);
    for (i = 0; i < H_TOTAL; i = i + 1) if (!cap[i]) bad = bad + 1;
    check(bad == 0, "vertical blanking pixels that are not black", bad, 0);

    // ---- 7. DSACK0* idle
    $display("---- 7. DSACK0* driven only during an access");
    check(dsack_idle_low == 0, "clocks with DSACK0* low and no access", dsack_idle_low, 0);

    // ---- 8. declaration ROM
    $display("---- 8. declaration ROM: A16 = 1, 8KB, mirrored, byte-exact");
    bad = 0;
    for (i = 0; i < 8192; i = i + 64) begin
      cpu_read(17'h1E000 + i, q);
      if (q !== rom_file[i]) bad = bad + 1;
    end
    check(bad == 0, "bytes differing from the image at $1E000 (every 64th)", bad, 0);
    cpu_read(17'h1FFFF, q);
    check(q == rom_file[8191], "last byte, ByteLanes", q, rom_file[8191]);
    cpu_read(17'h10000, q); cpu_read(17'h12000, q2);
    check(q == rom_file[0] && q2 == rom_file[0], "mirrors at $10000 and $12000", q, rom_file[0]);
    cpu_write(17'h1E000, 8'h00);
    cpu_read(17'h1E000, q);
    check(q == rom_file[0], "write to the ROM has no effect", q, rom_file[0]);

    // ---- 9. IRQ6* latch
    $display("---- 9. IRQ6*: VSYNC* latched while PB6 = 0, cleared by PB6 = 1");
    vsyncen_n = 1;
    wait_lctrrst; wait_line(VSYNC_START + VSYNC_LEN + 2);
    check(irq6_n == 1, "disabled: no interrupt after VSYNC*", irq6_n, 1);
    vsyncen_n = 0;
    wait_line(VSYNC_START - 2);
    check(irq6_n == 1, "enabled, before VSYNC*: none", irq6_n, 1);
    wait_line(VSYNC_START + 1);
    check(irq6_n == 0, "enabled: asserted during VSYNC*", irq6_n, 0);
    wait_line(VSYNC_START + VSYNC_LEN + 10);
    check(irq6_n == 0, "held after VSYNC* ends", irq6_n, 0);
    vsyncen_n = 1; repeat (4) @(posedge clk);
    check(irq6_n == 1, "PB6 = 1 clears it", irq6_n, 1);
    vsyncen_n = 0; repeat (4) @(posedge clk);
    check(irq6_n == 1, "PB6 = 0 again: not re-fired until the next VSYNC*", irq6_n, 1);
    wait_lctrrst; wait_line(VSYNC_START + 1);
    check(irq6_n == 0, "next frame: fires again", irq6_n, 0);
    vsyncen_n = 1; repeat (4) @(posedge clk);

    // ---- 10. PrimaryInit's grey fill
    $display("---- 10. PrimaryInit: 43,776 byte writes, rows AA/55, both pages");
    cpu_burst(17'h08040, 342 * 64, lo);
    cpu_burst(17'h00040, 342 * 64, hi);
    n = lo + hi;
    $display("info fill: 43776 chained writes in %0d clocks, %0d us (the PAL run, plan 2.12: 7.21 clocks per write, 20.14 ms)", n, n * 64 / 1000);
    check(n > 314600 && n < 316500, "fill takes 7.21 clocks per write, within 0.3%", n, 315537);
    page = 1;
    wait_lctrrst;
    // the fill's first row (VRAM row 1, offset $40) is $AA, then they alternate
    capture_line(FIRST_ACTIVE);
    want = row_pixels(8'hAA, 8'hAA);
    check(cap[0:H_ACTIVE-1] == want, "first active line is fill row 0 = $AA", cap[0:15], want[0:15]);
    capture_line(FIRST_ACTIVE + 1);
    want = row_pixels(8'h55, 8'h55);
    check(cap[0:H_ACTIVE-1] == want, "second active line is fill row 1 = $55", cap[0:15], want[0:15]);
    capture_line(LAST_ACTIVE);
    want = row_pixels(8'h55, 8'h55);
    check(cap[0:H_ACTIVE-1] == want, "last active line is fill row 341 = $55", cap[0:15], want[0:15]);

    // ---- 11. the slot access timing, as UE7 does it
    $display("---- 11. slot access: 6/7 clocks alternating; the row transfer at pixel 535 answers at 560");
    wait_lctrrst; wait_line(100);
    slot_at(100, q); lo = cyc_len;
    slot_at(120, q); hi = cyc_len;
    check((lo == 6 && hi == 7) || (lo == 7 && hi == 6), "even/odd start, one of each of 6 and 7 clocks", lo * 10 + hi, 67);
    slot_at(121, q);
    check(cyc_len == lo, "start 21 clocks later: same as start 100", cyc_len, lo);
    slot_at(535, q);
    check(cyc_len == 28, "request at pixel 535: waits for the transfer, 28 clocks", cyc_len, 28);
    check(dsack_px == 560, "and DSACK0* comes in pixel 560", dsack_px, 560);
    wait_line(101);
    slot_at(556, q);
    check(cyc_len == 7, "request at pixel 556: 7 clocks", cyc_len, 7);
    wait_line(102);
    slot_at(557, q);
    check(cyc_len == 6, "request at pixel 557: 6 clocks", cyc_len, 6);
    wait_line(350);
    slot_at(535, q);
    check(cyc_len == 28, "blank line, pixel 535: the transfer runs there too, 28 clocks", cyc_len, 28);
    wait_line(351);
    while (px != 300) @(posedge clk);
    cpu_burst(17'h00100, 4, n);
    check(ack_gap[1] == 7 && ack_gap[2] == 7 && ack_gap[3] == 7, "chained writes: DSACK0* every 7 clocks", ack_gap[1] * 100 + ack_gap[2] * 10 + ack_gap[3], 777);

    // ---- verdict
    if (fails == 0) $display("==== PASS: %0d checks, the SE/30 video holds to the Guide and the declaration ROM", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  // A stuck DUT must not hang the run: the whole bench is ~250 ms of video.
  initial begin
    #600_000_000;
    $display("==== FAIL: bench timed out (600 ms of simulated video)");
    $finish;
  end

endmodule
