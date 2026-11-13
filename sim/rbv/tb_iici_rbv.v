// tb_iici_rbv.v - the IIci's RBV held to SE30_PLAN.md "THE RBV".
//
// WHAT THIS PROVES
//   1. data B: the outputs as written, SNDEXT low, the NuChip's TM bits in
//   2. $12 / $13: VIA IER semantics; $02 the slot lines active low with
//      the unused bits high; $03 the flags follow their lines, bit 7 the
//      enabled OR, irq_n with it                          G Tables 4-9, 4-27
//   3. $10: the sense 110 read only, depth and bit 6 as written  Table 12-8
//   4. the video interrupt: the latch at vertical sync's start only while
//      $12 bit 6 is set, cleared by writing $40 to $12; $02 bit 6 low
//      during vertical sync even with it off (the driver's VBL wait)
//   5. timing: 864 x 525 dots a frame, HS 64 dots from 704, VS 3 lines
//      from 483, blanking 640 / 480, 66.67 Hz at 30.24 MHz  Tables 12-5/6
//   6. the Bt478: write address, R G B, readback through the read
//      address, the pixel mask
//   7. pixels: a frame at 1 bpp and one at 8 bpp from a frame buffer, each
//      dot the CLUT entry of its bits (1 bpp: entries 254-255), the FIFO
//      never empty when a pixel is due, a frame's longs fetched
//   8. the 60.15 Hz tick on VIA1 CA1
//
// The MDU's part is the bench's: on vid_req it delivers 8 longs from an
// address counter that vid_frame restarts, LAT clks after the request.

`timescale 1ns/1ps

module tb_iici_rbv;
  reg clk = 0, reset_n = 0;
  always #10 clk = !clk;
  reg [5:0] c16_acc = 0; reg c16_en = 0;      // 15.6672 MHz-ish: 5 in 16 (enough for the registers)
  always @(posedge clk) begin c16_acc <= c16_acc + 1; c16_en <= (c16_acc[1:0] == 0); end

  reg        rbv_sel = 0, vdac_sel = 0, strobe = 0, rw = 1;
  reg  [4:0] addr = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata;
  reg        scsi_irq = 0, scsi_drq = 0, asc_irq_n = 1, exp_irq_n = 1;
  reg  [2:0] slot_irq_n = 3'b111;
  reg  [1:0] nb_tm = 2'b00;
  wire       irq_n, tick_n, cflush_n, cenable_n, poweroff_n, buslk_n;
  wire       vid_req, vid_frame, ce_pix, hs_n, vs_n, hblank, vblank;
  reg        vid_ld = 0;
  reg [31:0] vid_data = 0;
  wire [7:0] r, g, b;
  wire [15:0] under;

  iici_rbv rbv (
    .clk(clk), .reset_n(reset_n), .c16_en(c16_en),
    .rbv_sel(rbv_sel), .vdac_sel(vdac_sel), .strobe(strobe), .addr(addr), .rw(rw), .wdata(wdata), .rdata(rdata),
    .scsi_irq(scsi_irq), .scsi_drq(scsi_drq), .asc_irq_n(asc_irq_n), .exp_irq_n(exp_irq_n),
    .slot_irq_n(slot_irq_n), .nb_tm(nb_tm), .irq_n(irq_n), .tick_n(tick_n),
    .cflush_n(cflush_n), .cenable_n(cenable_n), .poweroff_n(poweroff_n), .buslk_n(buslk_n),
    .vid_req(vid_req), .vid_frame(vid_frame), .vid_ld(vid_ld), .vid_data(vid_data),
    .ce_pix(ce_pix), .r(r), .g(g), .b(b), .hs_n(hs_n), .vs_n(vs_n), .hblank(hblank), .vblank(vblank),
    .dbg_underflow(under));

  // ---------------------------------------------- the frame buffer (MDU's part)
  reg [31:0] fb [0:76799];             // 640 x 480 x 8 bpp
  integer vaddr = 0, fetched = 0, LAT = 12;
  reg req_q = 0;
  initial begin : mdu
    integer k;
    forever begin
      @(posedge clk);
      if (vid_frame) vaddr = 0;
      if (vid_req && !req_q) begin
        repeat (LAT) @(posedge clk);
        for (k = 0; k < 8; k = k + 1) begin
          vid_data <= fb[vaddr]; vaddr = vaddr + 1; fetched = fetched + 1;
          vid_ld <= 1; @(posedge clk); vid_ld <= 0;
          @(posedge clk);
        end
      end
      req_q = vid_req;
    end
  end

  // ------------------------------------------------------------ the CPU
  task wr8(input dac, input [4:0] a, input [7:0] d);
    begin
      @(posedge clk); while (!c16_en) @(posedge clk);
      rbv_sel = !dac; vdac_sel = dac; addr = a; rw = 0; wdata = d; strobe = 1;
      @(posedge clk); strobe = 0; rbv_sel = 0; vdac_sel = 0; rw = 1;
      #1;                                       // the register has taken it
    end
  endtask
  reg [7:0] q;
  task rd8(input dac, input [4:0] a);
    begin
      @(posedge clk); while (!c16_en) @(posedge clk);
      rbv_sel = !dac; vdac_sel = dac; addr = a; rw = 1; strobe = 1;
      #1 q = rdata;
      @(posedge clk); strobe = 0; rbv_sel = 0; vdac_sel = 0;
    end
  endtask

  integer pass = 0, fails = 0;
  task check(input ok, input [8*90-1:0] what);
    begin if (ok) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0s", what); end end
  endtask

  // ------------------------------------------------------- the picture
  // every displayed dot of a frame against the frame buffer and the CLUT
  integer px = 0, py = 0, bad = 0, frames = 0, dots = 0, hs_w = 0, hs_at = -1, vs_lines = 0, act = 0;
  integer depth_t = 0;
  reg [23:0] exp_clut [0:255];
  reg        checking = 0;
  reg        vb_q = 1, hb_q = 1, vs_q = 1, hs_q = 1;
  integer    cx = 0, cy = 0;
  function [7:0] expect_idx(input integer x, input integer y);
    reg [31:0] l; integer bit0, bits;
    begin
      bits = 1 << depth_t;
      l = fb[(y * 640 * bits + x * bits) / 32];
      bit0 = (x * bits) % 32;
      case (depth_t)
        0: expect_idx = {7'h7F, l[31 - bit0]};
        3: expect_idx = l[31 - bit0 -: 8];
        default: expect_idx = 8'h00;
      endcase
    end
  endfunction
  always @(posedge clk) if (ce_pix && reset_n) begin
    // the output stage is two dots behind the counters: follow its blanking
    if (!hblank && hb_q) cx = 0;
    if (!vblank && vb_q) cy = 0;
    if (!hblank && !vblank && checking) begin
      if ({r, g, b} !== exp_clut[expect_idx(cx, cy)]) begin
        if (bad < 5) $display("      dot (%0d,%0d): %06x, expected %06x (index %02x)", cx, cy, {r, g, b}, exp_clut[expect_idx(cx, cy)], expect_idx(cx, cy));
        bad = bad + 1;
      end
      act = act + 1;
    end
    if (!hblank && !vblank) cx = cx + 1;
    if (hblank && !hb_q && !vblank) cy = cy + 1;
    if (!hs_n) hs_w = hs_w + 1;
    hb_q = hblank; vb_q = vblank; hs_q = hs_n;
  end

  // ------------------------------------------------------------ tests
  integer i, t0, t1, n;
  real fr;
  initial begin
    for (i = 0; i < 76800; i = i + 1) fb[i] = {$random} ;
    repeat (4) @(posedge clk); reset_n = 1;

    // 1: data B
    wr8(0, 5'h00, 8'h8F); rd8(0, 5'h00);
    check(q == 8'h8F && cflush_n && cenable_n && poweroff_n && buslk_n, "data B: $8F as written, SNDEXT low");
    nb_tm = 2'b10; rd8(0, 5'h00); check(q == 8'hAF, "data B: v2TM0A in bit 5");
    nb_tm = 2'b00; wr8(0, 5'h00, 8'h86); check(!cenable_n && cflush_n == 0 && poweroff_n, "data B: /CEnable 0 and /CFLUSH 0 drive their pins");
    wr8(0, 5'h00, 8'h8F);

    // 2: enables, slots, flags
    wr8(0, 5'h13, 8'h7F); wr8(0, 5'h12, 8'hFF);
    rd8(0, 5'h12); check(q == 8'hFF, "$12 <- $FF sets every slot enable");
    rd8(0, 5'h13); check(q == 8'h80, "$13 <- $7F clears every enable");
    rd8(0, 5'h02); check(q == 8'hFF, "$02: no slot line low reads $FF");
    slot_irq_n = 3'b101; rd8(0, 5'h02); check(q == 8'hEF, "$02: slot $D's line low in bit 4");
    rd8(0, 5'h03); check(q == 8'h02, "$03: the slot flag follows the line, bit 7 off with it disabled");
    check(irq_n, "no interrupt while $13 has bit 1 off");
    wr8(0, 5'h13, 8'h82); rd8(0, 5'h03); check(q == 8'h82 && !irq_n, "$13 <- $82: the slot flag interrupts, $03 bit 7 set");
    wr8(0, 5'h03, 8'h82); rd8(0, 5'h03); check(q == 8'h82, "a write to $03 clears nothing a line still holds");
    wr8(0, 5'h12, 8'h10); check(irq_n, "$12 <- $10 disables slot $D: its flag drops");
    slot_irq_n = 3'b111; wr8(0, 5'h12, 8'h90);
    scsi_irq = 1; asc_irq_n = 0; scsi_drq = 1; exp_irq_n = 0;
    rd8(0, 5'h03); check(q == 8'h1D, "$03: ASC 4, SCSI IRQ 3, /EXP.IRQ 2, DRQ 0 (Table 4-27)");
    wr8(0, 5'h13, 8'h91); check(!irq_n, "an enabled ASC flag interrupts");
    scsi_irq = 0; asc_irq_n = 1; scsi_drq = 0; exp_irq_n = 1; wr8(0, 5'h13, 8'h7F);

    // 3: $10
    wr8(0, 5'h10, 8'h40); rd8(0, 5'h10); check(q == 8'h70, "$10: sense 110 read only, bit 6 as written");
    wr8(0, 5'h10, 8'hFF); rd8(0, 5'h10); check(q == 8'hF7, "$10: the sense bits ignore writes");

    // 6: the Bt478
    wr8(1, 5'h00, 8'h10); wr8(1, 5'h04, 8'h12); wr8(1, 5'h04, 8'h34); wr8(1, 5'h04, 8'h56);
    wr8(1, 5'h04, 8'h78); wr8(1, 5'h04, 8'h9A); wr8(1, 5'h04, 8'hBC);
    wr8(1, 5'h0C, 8'h10); rd8(1, 5'h04); n = q; rd8(1, 5'h04); n = (n << 8) | q; rd8(1, 5'h04); n = (n << 8) | q;
    rd8(1, 5'h04); check(n == 24'h123456 && q == 8'h78, "Bt478: entries $10 and $11 written, read back in turn");
    rd8(1, 5'h00); check(q == 8'h12, "Bt478: the write address advanced past each entry");

    // the CLUT for the pictures: every entry distinct
    wr8(1, 5'h00, 8'h00);
    for (i = 0; i < 256; i = i + 1) begin
      exp_clut[i] = {i[7:0], ~i[7:0], i[7:0] ^ 8'h5A};
      wr8(1, 5'h04, exp_clut[i][23:16]); wr8(1, 5'h04, exp_clut[i][15:8]); wr8(1, 5'h04, exp_clut[i][7:0]);
    end

    // 4: the video interrupt
    wr8(0, 5'h12, 8'h40);                      // off
    while (vs_n) @(posedge clk);
    rd8(0, 5'h02); check(q[6] == 1'b0, "$02 bit 6 low during vertical sync with the interrupt off");
    while (!vs_n) @(posedge clk);
    rd8(0, 5'h02); check(q[6] == 1'b1, "... and high after it: no latch while $12 bit 6 is off");
    wr8(0, 5'h12, 8'hC0); wr8(0, 5'h13, 8'h82);
    while (vs_n) @(posedge clk); while (!vs_n) @(posedge clk);
    rd8(0, 5'h02); check(q[6] == 1'b0 && !irq_n, "with $12 bit 6 on, the latch holds bit 6 low after sync, interrupting");
    wr8(0, 5'h12, 8'h40); rd8(0, 5'h02); check(q[6] == 1'b1 && irq_n, "$12 <- $40 clears the latch (the driver's handler)");
    wr8(0, 5'h13, 8'h7F);

    // 5 and 7: timing and pictures, 1 bpp then 8 bpp
    for (depth_t = 0; depth_t <= 3; depth_t = depth_t + 3) begin
      wr8(0, 5'h10, depth_t[7:0]);
      while (vblank) @(posedge clk); while (!vblank) @(posedge clk);   // a whole frame with the depth set
      while (vblank) @(posedge clk);
      bad = 0; act = 0; fetched = 0; hs_w = 0; n = under; checking = 1; t0 = $time; dots = 0;
      while (!vblank) begin @(posedge clk); if (ce_pix) dots = dots + 1; end
      while (vblank) begin @(posedge clk); if (ce_pix) dots = dots + 1; end
      t1 = $time; checking = 0;
      $display("      %0d bpp: %0d dots a frame, %0d displayed, %0d wrong, %0d longs fetched, %0d underflows, HS %0d dots in all",
               1 << depth_t, dots, act, bad, fetched, under - n, hs_w);
      check(dots == 864 * 525, "a frame is 864 x 525 dots");
      check(act == 640 * 480, "640 x 480 displayed");
      check(bad == 0, "every dot is its CLUT entry");
      check(under == n, "the FIFO never ran dry");
      check(hs_w == 64 * 525, "HS is 64 dots a line");
      fr = 1.0e9 / (t1 - t0);
      if (depth_t == 0) begin $display("      %0.3f Hz", fr); check(fr > 66.6 && fr < 66.75, "66.67 Hz"); end
    end

    // 8: the 60.15 Hz tick (C16M here is clk/4: 12.5 MHz, so TICK clocks are 20.8 ms)
    while (tick_n) @(posedge clk); t0 = $time; while (!tick_n) @(posedge clk);
    while (tick_n) @(posedge clk); t1 = $time;
    check((t1 - t0) == 260469 * 80, "the tick is TICK C16M clocks apart");

    if (fails == 0) $display("==== PASS: %0d checks - the RBV as the plan's THE RBV", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

  // VS width, separately: 3 lines
  integer vs_dots = 0; reg vs_seen = 0;
  always @(posedge clk) if (ce_pix) begin
    if (!vs_n) vs_dots = vs_dots + 1;
    if (vs_n && !vs_q && !vs_seen) begin
      vs_seen = 1;
      if (vs_dots != 3 * 864) begin fails = fails + 1; $display("FAIL: VS is %0d dots, not 3 lines", vs_dots); end
      else pass = pass + 1;
    end
    vs_q = vs_n;
  end
endmodule
