// tb_se30_asc_stub.v - the ASC stub held to SE30_PLAN.md 7.3.
//
// WHAT THIS PROVES
//   rtl/se30_asc_stub.v, driven as GLUE's device port drives it in the
//   machine (clk = clk_sys, c16_en = phi1, the strobe one C16M = two clk):
//
//     1. $800 reads $00 (the original ASC), and a write to it changes nothing
//     2. $801-$80F other than $804 read back what was written
//     3. $804 reads $0F - both FIFOs half empty and empty - before and after
//        2,048 bytes written to the FIFOs, and a write to it changes nothing
//     4. writes to the FIFOs leave the registers alone
//     5. SNDINT* never in mode 0 or mode 2 (the boot chime's), over three
//        sample periods
//     6. in mode 1 (FIFO): SNDINT* within a sample period, held until $804
//        is read, cleared by that read, raised again at the next tick -
//        704 C16M apart; a read of another register does not clear it
//     7. mode back to 0: SNDINT* drops at once

`timescale 1ns/1ps

module tb_se30_asc_stub;

  reg clk = 0;
  always #15.957 clk = ~clk;
  reg phi = 0;
  always @(posedge clk) phi <= ~phi;
  wire c16_en = !phi;
  reg reset_n = 0;

  reg         sel = 0, strobe = 0, rw = 1;
  reg  [11:0] addr = 0;
  reg   [7:0] wdata = 0;
  wire  [7:0] rdata;
  wire        irq_n;

  se30_asc_stub dut (
    .clk(clk), .c16_en(c16_en), .reset_n(reset_n),
    .sel(sel), .strobe(strobe), .rw(rw), .addr(addr), .wdata(wdata), .rdata(rdata),
    .irq_n(irq_n));

  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask

  // C16M edges, counted
  integer c16s = 0;
  always @(posedge clk) if (c16_en) c16s <= c16s + 1;
  task c16; begin @(posedge clk); #1; while (!phi) begin @(posedge clk); #1; end end endtask

  // one device cycle, GLUE's shape: the select up, the strobe for one C16M
  // (two clk), the byte taken on the edge the strobe acts on
  reg [7:0] q;
  task access(input r, input [11:0] a, input [7:0] d);
    begin
      c16; #1 sel = 1; rw = r; addr = a; wdata = d; strobe = 1;
      @(posedge clk); @(posedge clk); q = rdata; #1 strobe = 0;
      c16; #1 sel = 0;
    end
  endtask
  task rd(input [11:0] a); begin access(1, a, 8'hA5); end endtask
  task wr(input [11:0] a, input [7:0] d); begin access(0, a, d); end endtask

  integer i, bad, t0, t1, n;

  initial begin
    repeat (4) @(posedge clk); #1 reset_n = 1;

    $display("---- 1. the version");
    rd(12'h800); check(q == 8'h00, "$800 reads $00, the original ASC", q, 8'h00);
    wr(12'h800, 8'hE8); rd(12'h800); check(q == 8'h00, "a write to $800 changes nothing", q, 8'h00);

    $display("---- 2. the registers read back");
    bad = 0;
    for (i = 1; i < 16; i = i + 1) if (i != 4) wr(12'h800 + i, 8'h30 + 7 * i);
    for (i = 1; i < 16; i = i + 1) if (i != 4) begin rd(12'h800 + i); if (q != 8'h30 + 7 * i) bad = bad + 1; end
    check(bad == 0, "$801-$80F (not $804) read back what was written", bad, 0);
    wr(12'h801, 8'h00);

    $display("---- 3, 4. the FIFO status, and the FIFOs");
    rd(12'h804); check(q == 8'h0F, "$804 reads $0F: both FIFOs half empty and empty", q, 8'h0F);
    for (i = 0; i < 2048; i = i + 1) wr(i, i);
    rd(12'h804); check(q == 8'h0F, "$804 still $0F after 2,048 bytes to the FIFOs", q, 8'h0F);
    wr(12'h804, 8'h00); rd(12'h804); check(q == 8'h0F, "a write to $804 changes nothing", q, 8'h0F);
    bad = 0;
    for (i = 2; i < 16; i = i + 1) if (i != 4) begin rd(12'h800 + i); if (q != 8'h30 + 7 * i) bad = bad + 1; end
    check(bad == 0, "the FIFO writes left the registers alone", bad, 0);

    $display("---- 5. no interrupt in modes 0 and 2");
    wr(12'h801, 8'h00); n = 0;
    repeat (3 * 704) begin c16; if (!irq_n) n = n + 1; end
    check(n == 0, "mode 0: SNDINT* idle over three sample periods", n, 0);
    wr(12'h801, 8'h02); n = 0;
    repeat (3 * 704) begin c16; if (!irq_n) n = n + 1; end
    check(n == 0, "mode 2 (the boot chime's): SNDINT* idle", n, 0);

    $display("---- 6. FIFO mode");
    wr(12'h801, 8'h01); t0 = c16s;
    while (irq_n && c16s - t0 < 2000) c16;
    check(!irq_n && c16s - t0 <= 704, "mode 1: SNDINT* within a sample period", c16s - t0, 704);
    repeat (2000) c16;
    check(!irq_n, "held until $804 is read", irq_n, 0);
    rd(12'h802); c16;
    check(!irq_n, "a read of another register leaves it", irq_n, 0);
    rd(12'h804); c16;
    check(irq_n, "a read of $804 clears it", irq_n, 1);
    while (irq_n && c16s - t0 < 20000) c16;
    t0 = c16s; rd(12'h804); c16;
    while (irq_n && c16s - t0 < 2000) c16;
    t1 = c16s;
    check(!irq_n && t1 - t0 >= 700 && t1 - t0 <= 704, "raised again at the next tick: 704 C16M apart", t1 - t0, 704);

    $display("---- 7. out of FIFO mode");
    wr(12'h801, 8'h00); c16;
    check(irq_n, "mode 0: SNDINT* drops at once", irq_n, 1);

    if (fails == 0) $display("==== PASS: %0d checks, the ASC stub holds to plan 7.3", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

endmodule
