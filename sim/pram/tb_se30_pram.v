// tb_se30_pram.v - persistent PRAM (SE30_PLAN.md 13.3 item 1): rtl/se30_pram.v
// and the real rtl/se30_rtc.v, with a model hps_io slot serving a 512-byte
// image, the timers shortened (SETTLE 2,000 clocks, WD 3,000, BACKSTOP
// 20,000).  The Mac's side is the ROM's own bit-bang over VIA1 port B, the
// routines of sim/rtc (plan 6.7: $4080DD8E's extended form).
//
// WHAT THIS PROVES
//    1. a load: the image's 256 bytes reach the RTC byte-exact; READY rises
//       with it; no RESTART (the machine was still held); the Mac reads them
//    2. a mount without a size (no image): READY at once
//    3. no mount at all: READY after the backstop
//    4. an HPS that never serves the read: four requests (one and three
//       retries), then READY, and the RAM untouched
//    5. a write by the Mac: one save SETTLE after it, holding the new byte
//       and every other byte of the RAM, the padding zero
//    6. a burst of writes closer than SETTLE: one save
//    7. the OSD opening: no save when nothing changed; a save at once when
//       something did
//    8. wipe: the RAM zero, a save of zeros, a RESTART
//    9. a load landing after READY: the new bytes, and a RESTART
//   10. wipe with no image mounted: the RAM zero, no save, a RESTART

`timescale 1ns/1ps

module tb_se30_pram;

  reg clk = 0;
  always #16 clk = ~clk;

  localparam SETTLE = 2000, WD = 3000, BACKSTOP = 20000;

  // ------------------------------------------------ VIA1 port B, bits 2-0
  reg [2:0] orb  = 3'b111;
  reg [2:0] ddrb = 3'b111;
  wire      d_out, d_oe, one_hz;
  wire [2:0] pin = { ddrb[2] ? orb[2] : 1'b1,
                     ddrb[1] ? orb[1] : 1'b1,
                     ddrb[0] ? orb[0] : (d_oe ? d_out : 1'b1) };
  wire [31:0] rtc_dbg;

  wire       h_we, pram_wr;
  wire [7:0] h_addr, h_wdata, h_raddr, h_rdata;

  se30_rtc #(.CLK_HZ(1_000_000)) rtc (
    .clk(clk), .timestamp(33'd0),
    .cs_n(pin[2]), .sck(pin[1]), .d_in(pin[0]), .d_out(d_out), .d_oe(d_oe), .one_hz(one_hz),
    .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata), .h_raddr(h_raddr), .h_rdata(h_rdata),
    .pram_wr(pram_wr), .dbg(rtc_dbg));

  // ------------------------------------------------ the PRAM block and its slot
  reg        reset = 1, osd_open = 0, wipe = 0;
  reg        img_mounted = 0, img_present = 0;
  wire       sd_rd, sd_wr;
  reg        sd_ack = 0;
  reg  [7:0] sd_buff_addr = 0;
  reg [15:0] sd_buff_dout = 0;
  reg        sd_buff_wr = 0;
  wire [15:0] sd_buff_din;
  wire       ready, restart;
  wire [15:0] pdbg;

  se30_pram #(.SETTLE(SETTLE), .WD(WD), .BACKSTOP(BACKSTOP), .RST_LEN(8)) dut (
    .clk(clk), .reset(reset), .osd_open(osd_open), .wipe(wipe),
    .img_mounted(img_mounted), .img_present(img_present),
    .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din),
    .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata), .h_raddr(h_raddr), .h_rdata(h_rdata),
    .pram_wr(pram_wr), .ready(ready), .restart(restart), .dbg(pdbg));

  // ------------------------------------------------ the model hps_io slot
  reg [7:0] img [0:511];
  reg       serve = 1;                    // 0: requests are never picked up
  integer   n_rd_req = 0, n_loads = 0, n_saves = 0, n_restarts = 0, w;
  reg       rd_q = 0, rs_q = 0;
  always @(posedge clk) begin
    rd_q <= sd_rd; rs_q <= restart;
    if (sd_rd && !rd_q) n_rd_req = n_rd_req + 1;
    if (restart && !rs_q) n_restarts = n_restarts + 1;
  end
  always begin
    @(negedge clk);
    if (serve && (sd_rd || sd_wr)) begin
      repeat (50) @(negedge clk);
      if (sd_rd) begin
        sd_ack = 1;
        for (w = 0; w < 256; w = w + 1) begin
          @(negedge clk); sd_buff_addr = w; sd_buff_dout = {img[2*w + 1], img[2*w]};
          sd_buff_wr = 1; @(negedge clk); sd_buff_wr = 0;
        end
        @(negedge clk); sd_ack = 0; n_loads = n_loads + 1;
      end else begin
        sd_ack = 1;
        for (w = 0; w < 256; w = w + 1) begin
          @(negedge clk); sd_buff_addr = w; repeat (2) @(negedge clk);
          img[2*w] = sd_buff_din[7:0]; img[2*w + 1] = sd_buff_din[15:8];
        end
        @(negedge clk); sd_ack = 0; n_saves = n_saves + 1;
      end
      repeat (4) @(negedge clk);
    end
  end

  // ------------------------------------------------ scoring
  integer checks = 0, fails = 0, k, bad;
  task check(input cond, input [8*80-1:0] what);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s", what);
      else begin fails = fails + 1; $display("FAIL %0s (t=%0t)", what, $time); end
    end
  endtask
  task ticks(input integer n); begin repeat (n) @(posedge clk); end endtask
  task wait_ready(input integer limit, output ok);
    integer n; begin ok = 0; for (n = 0; n < limit && !ok; n = n + 1) begin @(posedge clk); if (ready) ok = 1; end end
  endtask
  task mount(input present);
    begin @(negedge clk); img_present = present; img_mounted = 1; @(negedge clk); img_mounted = 0; end
  endtask
  task core_reset; begin @(negedge clk); reset = 1; ticks(4); @(negedge clk); reset = 0; ticks(2); end endtask
  function integer ram_vs_img(input dummy);
    integer i, b; begin b = 0; for (i = 0; i < 256; i = i + 1) if (rtc.ram[i] !== img[i]) b = b + 1; ram_vs_img = b; end
  endfunction

  // ------------------------------------------------ the ROM's routines (sim/rtc)
  task via_gap; begin repeat (40) @(posedge clk); end endtask
  task wr_orb(input [2:0] v); begin via_gap; orb = v; end endtask
  task rd_orb(output [2:0] v); begin via_gap; v = pin; end endtask
  task rom_send(input [7:0] byt);
    integer n; begin for (n = 7; n >= 0; n = n - 1) begin wr_orb({1'b0, 1'b0, byt[n]}); wr_orb({1'b0, 1'b1, byt[n]}); end end
  endtask
  task rom_recv(output [7:0] byt);
    integer n; reg [2:0] v;
    begin
      via_gap; ddrb[0] = 0;
      for (n = 7; n >= 0; n = n - 1) begin wr_orb({1'b0, 1'b0, orb[0]}); wr_orb({1'b0, 1'b1, orb[0]}); rd_orb(v); byt[n] = v[0]; end
      via_gap; ddrb[0] = 1;
    end
  endtask
  task rom_xfer(input [7:0] cmd, input [7:0] cmd2, input [7:0] wdata, output [7:0] rdata);
    begin
      rdata = 8'hxx;
      rom_send(cmd);
      if ((cmd & 8'h78) == 8'h38) rom_send(cmd2);
      if (cmd[7]) rom_recv(rdata); else rom_send(wdata);
      wr_orb({1'b1, orb[1:0]});
    end
  endtask
  reg [7:0] rd;
  task wr1(input [7:0] cmd, input [7:0] v); begin rom_xfer(cmd, 8'h00, v, rd); end endtask
  task xwr(input [7:0] a, input [7:0] v);  begin rom_xfer({5'b00111, a[7:5]}, {1'b0, a[4:0], 2'b00}, v, rd); end endtask
  task xrd(input [7:0] a, output [7:0] v); begin rom_xfer({5'b10111, a[7:5]}, {1'b0, a[4:0], 2'b00}, 8'h00, v); end endtask
  task wp_off; begin wr1(8'h35, 8'h55); end endtask

  reg ok;
  reg [7:0] v;
  integer s0, r0;
  initial begin
    for (k = 0; k < 512; k = k + 1) img[k] = (k < 256) ? (k * 7 + 3) & 8'hFF : 8'hEE;
    ticks(5); reset = 0; ticks(5);

    // 1. a load
    mount(1);
    wait_ready(10000, ok);
    check(ok && n_loads == 1, "1. a load: READY after the sector arrived");
    check(ram_vs_img(0) == 0, "1. the RTC holds the image's 256 bytes, byte-exact");
    check(n_restarts == 0, "1. no RESTART: the machine was still held");
    xrd(8'h00, v); check(v == 8'h03, "1. the Mac reads xPRAM $00 = $03");
    xrd(8'hC5, v); check(v == ((8'hC5 * 7 + 3) & 8'hFF), "1. the Mac reads xPRAM $C5");
    xrd(8'hFF, v); check(v == ((8'hFF * 7 + 3) & 8'hFF), "1. the Mac reads xPRAM $FF");
    ticks(SETTLE + 1000);
    check(n_saves == 0, "1. the Mac's reads make no save");

    // 2. no image
    core_reset; check(!ready, "2. READY low after the core's reset");
    mount(0); ticks(3);
    check(ready, "2. a mount without a size: READY at once");

    // 3. no mount at all
    core_reset; ticks(BACKSTOP / 2);
    check(!ready, "3. no mount: not yet READY at half the backstop");
    ticks(BACKSTOP / 2 + 10);
    check(ready, "3. no mount: READY after the backstop");

    // 4. an HPS that never answers
    core_reset; serve = 0; n_rd_req = 0;
    for (k = 0; k < 256; k = k + 1) img[k] = 8'h99;           // a different image, never delivered
    mount(1);
    wait_ready(5 * WD + 1000, ok);
    check(ok, "4. the read never served: READY in the end");
    check(n_rd_req == 4, "4. ... after four requests (one and three retries)");
    bad = 0; for (k = 0; k < 256; k = k + 1) if (rtc.ram[k] !== ((k * 7 + 3) & 8'hFF)) bad = bad + 1;
    check(bad == 0, "4. ... and the RAM untouched");
    serve = 1; ticks(200);

    // load properly again for what follows (a late load: READY is high)
    for (k = 0; k < 256; k = k + 1) img[k] = (k * 5 + 1) & 8'hFF;
    core_reset; mount(1); wait_ready(10000, ok); ticks(100);
    check(ok && ram_vs_img(0) == 0, "   (reloaded: the RAM holds the image)");

    // 5. a write by the Mac
    s0 = n_saves; wp_off; xwr(8'h40, 8'h5A);
    ticks(SETTLE / 2);
    check(n_saves == s0, "5. no save before the settle time");
    ticks(SETTLE + 2000);
    check(n_saves == s0 + 1, "5. one save after it");
    check(img[8'h40] == 8'h5A, "5. ... holding the byte the Mac wrote");
    check(ram_vs_img(0) == 0, "5. ... and every other byte of the RAM");
    bad = 0; for (k = 256; k < 512; k = k + 1) if (img[k] !== 8'h00) bad = bad + 1;
    check(bad == 0, "5. ... the sector's padding zero");

    // 6. a burst
    s0 = n_saves;
    for (k = 0; k < 5; k = k + 1) begin xwr(8'h80 + k, 8'hA0 + k); end
    ticks(SETTLE + 3000);
    check(n_saves == s0 + 1, "6. five writes closer than the settle time: one save");
    check(img[8'h84] == 8'hA4 && ram_vs_img(0) == 0, "6. ... holding all five");

    // 7. the OSD
    s0 = n_saves;
    @(negedge clk); osd_open = 1; ticks(2000); @(negedge clk); osd_open = 0;
    check(n_saves == s0, "7. the OSD opens, nothing changed: no save");
    xwr(8'h10, 8'h77); ticks(50);
    @(negedge clk); osd_open = 1; ticks(1500);
    check(n_saves == s0 + 1 && img[8'h10] == 8'h77, "7. changed, the OSD opens: a save at once, before the settle time");
    @(negedge clk); osd_open = 0; ticks(SETTLE + 2000);
    check(n_saves == s0 + 1, "7. ... and no second save at the settle time");

    // 8. wipe
    s0 = n_saves; r0 = n_restarts;
    @(negedge clk); wipe = 1; ticks(4); @(negedge clk); wipe = 0;
    ticks(3000);
    bad = 0; for (k = 0; k < 256; k = k + 1) if (rtc.ram[k] !== 8'h00) bad = bad + 1;
    check(bad == 0, "8. wipe: the RAM zero");
    check(n_saves == s0 + 1, "8. ... one save");
    bad = 0; for (k = 0; k < 512; k = k + 1) if (img[k] !== 8'h00) bad = bad + 1;
    check(bad == 0, "8. ... of zeros");
    check(n_restarts == r0 + 1, "8. ... and a RESTART");

    // 9. a late load (READY is high)
    for (k = 0; k < 256; k = k + 1) img[k] = (k * 11 + 9) & 8'hFF;
    r0 = n_restarts;
    mount(1); ticks(4000);
    check(ram_vs_img(0) == 0, "9. a load landing after READY: the new bytes");
    check(n_restarts == r0 + 1, "9. ... and a RESTART");

    // 10. wipe with no image mounted
    mount(0); ticks(10);
    s0 = n_saves; r0 = n_restarts;
    @(negedge clk); wipe = 1; ticks(4); @(negedge clk); wipe = 0;
    ticks(3000);
    bad = 0; for (k = 0; k < 256; k = k + 1) if (rtc.ram[k] !== 8'h00) bad = bad + 1;
    check(bad == 0 && n_saves == s0 && n_restarts == r0 + 1, "10. wipe with no image: the RAM zero, no save, a RESTART");

    if (fails == 0) $display("==== PASS: %0d checks, persistent PRAM", checks);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin #200000000; $display("==== FAIL: timeout"); $finish; end

endmodule
