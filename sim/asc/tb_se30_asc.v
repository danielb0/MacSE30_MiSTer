// tb_se30_asc - the ASC (rtl/se30_asc.v) held to its specification
// (C:\temp\Mac\SE30\Docs\asc\spec_asc.md) and to the SE/30's own use of it
// (audit_se30_asc_software.md).  SE30_PLAN.md 11.4 item 1.
//
// The bus is driven as GLUE drives the device port in the machine: clk =
// clk_sys, c16_en every other clk, the address and select up for two C16M
// before the strobe, the strobe for one C16M, the read byte taken on the
// strobe's edge.  VIA2 CB1 is modelled as System 7.5.5 programs it: a flag
// set by a falling edge of SNDINT*, cleared by the handler.
//
// WHAT THIS PROVES
//   1  the registers: $800 = $00, read-back, $802 bit 7, the voices', $830
//   2  idle: $804 reads $00 and SNDINT* stays high (HW: IIci 804Idle $00,
//      no idle interrupt)
//   3  the hardware's own fill-and-drain test (ASCTester's
//      Test_FIFOFullHalfFullEmpty, stereo): full after 1,024-odd frames,
//      half-empty 0 while full, half-empty set as it drains with full 0,
//      no "empty"; with CB1: one full and one half-empty interrupt, no
//      repeats; $804 cleared by a read, ORed by a write
//   4  System 7.5.5's sound path replayed (sdev 'asc ' +$A28, lpch 28
//      +$126): the handler reads $804 once and refills on bit 2 - 512
//      frames blind as word writes at $3FF (two byte cycles), then a frame
//      at a time while bit 3 is 0 - for 0.5 s of sound: every sample out in
//      order, the FIFO never empty mid-sound, about 43 refills a second; then
//      the sound stops and the chip stays quiet (no storm)
//   5  the wavetable mode: four voices stepped by their increments, the
//      sum (mono) and the pairs (stereo), saturation; the ROM chime's
//      increment $18000 at 22,254.5 Hz is 130.4 Hz (3 samples a tick)
//   6  mono FIFO (A on both), the volume, $803's clear, a mode change,
//      address-direct writes outside FIFO mode, the 22,254.5 Hz tick

`timescale 1ns/1ps

module tb_se30_asc;

  reg clk = 0;
  always #15.958 clk = !clk;
  reg c16_en = 0;
  always @(posedge clk) c16_en <= !c16_en;
  reg reset_n = 0;

  reg sel = 0, strobe = 0, rw = 1;
  reg [11:0] addr = 0;
  reg [7:0] wdata = 0;
  wire [7:0] rdata;
  wire irq_n;
  wire [15:0] aud_l, aud_r;
  wire [31:0] dbg;

  se30_asc dut (.clk(clk), .c16_en(c16_en), .reset_n(reset_n), .sel(sel), .strobe(strobe), .rw(rw),
                .addr(addr), .wdata(wdata), .rdata(rdata), .irq_n(irq_n), .audio_l(aud_l), .audio_r(aud_r), .dbg(dbg));

  integer npass = 0, nfail = 0;
  task chk (input ok, input [8*100-1:0] what);
    begin if (ok) npass = npass + 1; else begin nfail = nfail + 1; $display("FAIL %0s", what); end end
  endtask
  task chk8 (input [7:0] got, input [7:0] want, input [8*90-1:0] what);
    begin if (got === want) npass = npass + 1; else begin nfail = nfail + 1; $display("FAIL %0s: got %02h want %02h", what, got, want); end end
  endtask

  // ------------------------------------------------------------ GLUE's cycle
  task c16 (input integer n); integer k; begin for (k = 0; k < n; k = k + 1) begin @(posedge clk); while (!c16_en) @(posedge clk); end end endtask
  reg [7:0] q;
  task access (input r, input [11:0] a, input [7:0] d);
    begin
      @(posedge clk); while (!c16_en) @(posedge clk);
      #1 sel = 1; rw = r; addr = a; wdata = d;
      c16(1); #1 strobe = 1;
      @(posedge clk); while (!c16_en) @(posedge clk);   // the strobe's edge
      q = rdata;                                        // GLUE's capture, the same edge (values before it)
      #1 strobe = 0; sel = 0; rw = 1;
      c16(1);
    end
  endtask
  task wr8 (input [11:0] a, input [7:0] d); access(0, a, d); endtask
  task rd8 (input [11:0] a, output [7:0] v); begin access(1, a, 8'h00); v = q; end endtask
  // the 68030's misaligned word write at $3FF: a byte cycle at $3FF, then one at $400
  task frame (input [7:0] l, input [7:0] r); begin wr8(12'h3FF, l); wr8(12'h400, r); end endtask

  // ------------------------------------------------------------ VIA2 CB1 (falling edge, as lpch 28 sets PCR)
  reg cb1_q = 1, cb1_flag = 0;
  integer cb1_edges = 0;
  always @(posedge clk) begin
    cb1_q <= irq_n;
    if (cb1_q && !irq_n) begin cb1_flag <= 1; cb1_edges = cb1_edges + 1; end
  end

  // ------------------------------------------------------------ the output, sample by sample
  // a record of each tick's two output bytes in FIFO mode (taken when the sequencer finishes)
  reg  [7:0] got_l [0:65535];
  reg  [7:0] got_r [0:65535];
  integer ngot = 0, rec = 0;
  // a pop moves the read pointer and the output on the same edge: take the
  // output the clock after the pointer moves
  reg  [9:0] rpa_q = 0, rpb_q = 0;
  reg        newa = 0, newb = 0;
  integer    ngot_r = 0;
  always @(posedge clk) begin
    rpa_q <= dut.rp[0]; rpb_q <= dut.rp[1];
    newa <= rec && (dut.rp[0] != rpa_q); newb <= rec && (dut.rp[1] != rpb_q);
    if (newa && ngot < 65536)   begin got_l[ngot] <= dut.out_l; ngot = ngot + 1; end
    if (newb && ngot_r < 65536) begin got_r[ngot_r] <= dut.out_r; ngot_r = ngot_r + 1; end
  end
  integer min_cnt_b = 2000, track_min = 0;
  always @(posedge clk) if (track_min && dut.cnt[1] < min_cnt_b) min_cnt_b = dut.cnt[1];

  // ------------------------------------------------------------ the tests
  reg  [7:0] v;
  integer    k, n, t0, ticks, fed, refills, irqs, full_at, e0, half_seen;
  real       hz;

  initial begin
    $display("tb_se30_asc: the ASC against its specification and System 7.5.5's use");
    c16(4); reset_n = 1; c16(4);

    // ================================================== 1 registers
    rd8(12'h800, v); chk8(v, 8'h00, "1 $800 version $00 (HW, SW)");
    wr8(12'h801, 8'h02); rd8(12'h801, v); chk8(v, 8'h02, "1 $801 reads back 2");
    wr8(12'h801, 8'h00);
    wr8(12'h802, 8'h83); rd8(12'h802, v); chk8(v, 8'h03, "1 $802 reads back, bit 7 reads 0");
    wr8(12'h806, 8'hE0); rd8(12'h806, v); chk8(v, 8'hE0, "1 $806 reads back");
    wr8(12'h815, 8'h01); wr8(12'h816, 8'h80); wr8(12'h817, 8'h00);
    rd8(12'h816, v); chk8(v, 8'h80, "1 voice 0's increment byte reads back");
    chk(dut.inc[0][23:0] == 24'h018000, "1 voice 0's increment = $018000");
    wr8(12'h82D, 8'h03); chk(dut.inc[3][23:0] == 24'h030000, "1 $82D is voice 3's increment, bits 23:16");
    wr8(12'h830, 8'hFE); rd8(12'h830, v); chk8(v, 8'hFE, "1 $830 stored (SW writes it)");
    wr8(12'h802, 8'h00); wr8(12'h806, 8'h00);

    // ================================================== 2 idle
    wr8(12'h807, 8'h00); wr8(12'h802, 8'h02); wr8(12'h801, 8'h01);
    rd8(12'h804, v); rd8(12'h804, v); chk8(v, 8'h00, "2 idle: $804 = $00 (HW 804Idle)");
    e0 = cb1_edges; c16(704 * 300);
    chk(cb1_edges == e0 && irq_n, "2 idle, FIFO mode, 300 sample ticks: no interrupt (HW)");

    // ================================================== 3 ASCTester's fill and drain, stereo
    wr8(12'h803, 8'h80); wr8(12'h803, 8'h00);
    rd8(12'h804, v); chk8(v & 8'h0A, 8'h0A, "3 the clear sets the full bits (M; snth 2053's discarded read)");
    rd8(12'h804, v); chk8(v, 8'h00, "3 ... and the read cleared them");
    for (k = 0; k < 256; k = k + 1) frame(k[7:0], k[7:0]);
    rd8(12'h804, v); chk8(v & 8'h0A, 8'h00, "3 after 256 frames: not full");
    full_at = 0; e0 = cb1_edges;
    for (k = 0; k < 4096 && full_at == 0; k = k + 1) begin
      frame(k[7:0], k[7:0]); rd8(12'h804, v);
      if (v & 8'h08) begin full_at = 257 + k; chk8(v & 8'h04, 8'h00, "3 half-empty B is 0 when full"); end
    end
    $display("  3 full after %0d frames (HW: IIci 1,105-1,119)", full_at);
    chk(full_at > 1024 && full_at < 1200, "3 full after a little more than 1,024 frames (it drains while filling)");
    half_seen = 0;
    for (k = 0; k < 2000 && !half_seen; k = k + 1) begin
      c16(704); rd8(12'h804, v);
      if (v & 8'h04) begin half_seen = 1; chk8(v & 8'h08, 8'h00, "3 full B is 0 when half empty"); end
    end
    chk(half_seen, "3 half empty comes as it drains");
    for (k = 0; k < 700; k = k + 1) begin c16(704); rd8(12'h804, v); chk(v == 8'h00 || v == 8'h05 || v == 8'h04 || v == 8'h01, "3 no other bits while it empties"); end
    chk(dut.cnt[1] == 0, "3 the FIFO ran empty");
    rd8(12'h804, v); chk8(v, 8'h00, "3 empty: no 'empty' bit on the original ASC (HW)");
    // the interrupts of one fill and drain
    e0 = cb1_edges;
    for (k = 0; k < 700; k = k + 1) frame(8'h80, 8'h80);
    for (k = 0; k < 600 && irq_n; k = k + 1) frame(8'h80, 8'h80);
    chk(!irq_n, "3 filling to full raises SNDINT*");
    c16(4); chk(cb1_edges == e0 + 1, "3 one CB1 edge for full");
    rd8(12'h804, v); chk(v[3], "3 $804 shows full"); c16(2); chk(irq_n, "3 the read releases SNDINT*");
    c16(704 * 600);
    chk(cb1_edges == e0 + 2, "3 one more edge, at half empty - no repeats (HW)");
    rd8(12'h804, v); chk(v[2] && !v[3], "3 $804 shows half empty");
    c16(704 * 600); chk(cb1_edges == e0 + 2 && irq_n, "3 drained to empty: no further interrupt");
    wr8(12'h804, 8'h04); rd8(12'h804, v); chk8(v, 8'h04, "3 a write ORs bits in (lpch 4)");
    c16(2); chk(irq_n, "3 ... and the read clears them again");

    // ================================================== 4 System 7.5.5's path, replayed
    // InitOutputDevice: $807 = 0, $802 = 2, $801 = 1 (already); sound: frames n = 0, 1, 2 ...
    // carrying L = n, R = ~n; the CB1 handler and the refill as sdev +$A28 runs them
    wr8(12'h803, 8'h80); wr8(12'h803, 8'h00); rd8(12'h804, v);
    c16(704 * 4);
    fed = 0; refills = 0; ngot = 0; ngot_r = 0; rec = 1; cb1_flag = 0;
    // StartSource primes the FIFO by calling the refill directly
    for (k = 0; k < 512; k = k + 1) begin frame(fed[7:0], ~fed[7:0]); fed = fed + 1; end
    begin : poll0
      for (k = 0; k < 2000; k = k + 1) begin rd8(12'h804, v); if (v[3]) disable poll0; frame(fed[7:0], ~fed[7:0]); fed = fed + 1; end
    end
    refills = 1; t0 = $time; track_min = 1; min_cnt_b = 2000;
    // half a second of sound (22,254.5 Hz x 0.5 = 11,127 frames)
    while (fed < 11127) begin
      @(posedge clk);
      if (cb1_flag) begin
        cb1_flag = 0;                                       // ack the VIA ($90 to IFR)
        rd8(12'h804, v);                                    // the one read
        if (v[2]) begin                                     // output: refill
          refills = refills + 1;
          for (k = 0; k < 512 && fed < 11127; k = k + 1) begin frame(fed[7:0], ~fed[7:0]); fed = fed + 1; end
          begin : pollr
            for (k = 0; k < 2000 && fed < 11127; k = k + 1) begin
              rd8(12'h804, v); if (v[3]) disable pollr;
              frame(fed[7:0], ~fed[7:0]); fed = fed + 1;
            end
          end
        end
      end
    end
    track_min = 0;
    hz = refills * 1.0e9 / ($time - t0);
    $display("  4 %0d frames fed, %0d refills in %0.3f s: %0.1f a second; FIFO B never below %0d mid-sound",
             fed, refills, ($time - t0) / 1.0e9, hz, min_cnt_b);
    chk(hz > 30.0 && hz < 60.0, "4 refill rate about 43 a second (half a 1 KB FIFO at 22 kHz)");
    chk(min_cnt_b > 0, "4 the FIFO never ran empty mid-sound");
    // let it play out, then the chip must stay quiet with CB1 still on
    c16(704 * 1200);
    rec = 0;
    begin : order
      integer bad, start; bad = 0;
      // the recording starts with the stream's first frame (frame 0): every frame in order, none lost
      for (k = 0; k < fed && k < ngot; k = k + 1)
        if (got_l[k] !== k[7:0] || got_r[k] !== ~k[7:0]) bad = bad + 1;
      $display("  4 %0d samples recorded, %0d out of order", ngot, bad);
      chk(ngot >= fed && ngot_r >= fed && bad == 0, "4 every frame out in order, left and right (FIFO A left, B right)");
    end
    rd8(12'h804, v);
    e0 = cb1_edges; c16(704 * 4000);
    chk(cb1_edges == e0, "4 after the sound, FIFO mode and CB1 still on: no interrupt at all (the stub stormed here)");

    // ================================================== 5 wavetable
    wr8(12'h801, 8'h00); wr8(12'h802, 8'h00);
    // tables: voice n at n x $200 holds byte = n*16 + (index & 15) (address-direct in mode 0)
    for (k = 0; k < 2048; k = k + 1) wr8(k[11:0], {2'b00, k[10:9], k[3:0]});
    rd8(12'h205, v); chk8(v, 8'h15, "5 address-direct write outside FIFO mode (voice 1's table)");
    for (k = 0; k < 32; k = k + 1) wr8(12'h810 + k[11:0], 8'h00);
    wr8(12'h815, 8'h01); wr8(12'h816, 8'h80);              // voice 0: $018000 (the chime's C3)
    wr8(12'h801, 8'h02);
    c16(704 * 10 + 50);
    // voice 0 steps $18000 a tick; voices 1-3 stay at index 0
    chk(dut.ph[0][23:0] % 24'h018000 == 0 && dut.ph[0][23:0] >= 24'h0D8000 && dut.ph[0][23:0] <= 24'h108000,
        "5 voice 0's phase after about 10 ticks is a multiple of $18000");
    chk8(dut.out_l, {4'd0, dut.ph[0][18:15]} + 8'h10 + 8'h20 + 8'h30, "5 mono: the four voices summed");
    begin : pitch
      real f; f = 22254.545 * 3.0 / 512.0;
      $display("  5 increment $18000: 3 samples a tick, %0.1f Hz (C3 = 130.8)", f);
    end
    wr8(12'h802, 8'h02); c16(704 * 2 + 50);
    chk8(dut.out_l, {4'd0, dut.ph[0][18:15]} + 8'h10, "5 stereo: voices 0+1 left");
    chk8(dut.out_r, 8'h20 + 8'h30, "5 stereo: voices 2+3 right");
    for (k = 0; k < 2048; k = k + 1) if (k[8:0] == 0) wr8(k[11:0], 8'hC0);
    wr8(12'h802, 8'h00); for (k = 0; k < 32; k = k + 1) wr8(12'h810 + k[11:0], 8'h00); c16(704 * 2 + 50);
    chk8(dut.out_l, 8'hFF, "5 mono sum over $FF saturates (4 x $C0)");
    wr8(12'h801, 8'h00);

    // ================================================== 6 mono FIFO, the volume, the tick
    wr8(12'h802, 8'h00); wr8(12'h801, 8'h01); rd8(12'h804, v);
    for (k = 0; k < 64; k = k + 1) wr8(12'h000, 8'hA0);
    c16(704 * 3 + 50);
    chk8(dut.out_l, 8'hA0, "6 mono: FIFO A plays"); chk8(dut.out_r, 8'hA0, "6 mono: A on both channels");
    wr8(12'h806, 8'hE0); c16(704 + 50);
    chk($signed(aud_l) == 32 * 7 * 36, "6 volume 7: ($A0 - $80) x 7 x 36");
    wr8(12'h806, 8'h20); c16(704 + 50);
    chk($signed(aud_l) == 32 * 1 * 36, "6 volume 1");
    wr8(12'h806, 8'h00); c16(704 + 50); chk(aud_l == 16'd0, "6 volume 0: silent");
    // the tick: 22,254.5 Hz = 704 C16M
    begin : tick
      integer a, b; @(posedge dut.tick); a = $time; @(posedge dut.tick); b = $time;
      $display("  6 sample period %0d ns (704 C16M = 44,934 ns)", b - a);
      chk(b - a > 44900 && b - a < 44970, "6 the sample tick is C16M/704: 22,254.5 Hz");
    end
    wr8(12'h807, 8'h03);
    begin : tick44
      integer a, b; @(posedge dut.tick); a = $time; @(posedge dut.tick); b = $time;
      $display("  6 $807 = 3: period %0d ns (44.1 kHz = 22,676 ns)", b - a);
      chk(b - a > 22500 && b - a < 22850, "6 $807 = 3: about 44.1 kHz");
    end
    wr8(12'h807, 8'h00);
    wr8(12'h801, 8'h02); chk(dut.cnt[0] == 0, "6 a change of mode empties the FIFOs");

    $display("tb_se30_asc: %0d checks passed, %0d failed", npass, nfail);
    if (nfail == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  initial begin #2_000_000_000; $display("TIMEOUT"); $display("==== FAIL"); $finish; end

endmodule
