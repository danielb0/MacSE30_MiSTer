// tb_se30_via.v - the 6523 VIA held to SE30_PLAN.md 4.2, item by item of
// 4.9's list.
//
// WHAT THIS PROVES
//   rtl/se30_via.v is Apple's 6523 (a 65C22) as the VIA Cell spec's
//   un-boxed text and the R6522 data sheet describe it:
//
//     1. reset: the eight registers $00, IER reads $80, all lines inputs,
//        IRQ high                                                    4.2.1
//     2. ports: DDR gates the pin; an input bit reads the pin, an output
//        bit reads OR; a write to an input bit leaves OR alone;
//        register 15 is register 1 without the flag clears            4.2.3
//     3. T1 one-shot: IFR6 N+1 E cycles after the T1CH write, once;
//        T1CL read clears; the latches reload; T1LH write clears
//        without a transfer                                           4.2.4
//     4. T1 free-run: IFR6 every N+1; PB7 inverts at each time-out
//        under ACR7; $196E gives 6511                                 4.2.4
//     5. T2: one-shot IFR5 at N+1 then free roll-over; re-armed by
//        T2CH; PB6 pulse counting                                     4.2.4
//     6. CA1/CA2/CB1/CB2: PCR edge selects, port-access clears unless
//        independent, the CA2/CB2 output modes                        4.2.3
//     7. the shift register: the external-clock modes bit by bit, the
//        9th bit, IFR2 every eight; mode 000 dead; the internal modes
//        to their one line                                            4.2.5
//     8. IFR/IER: bit 7, the 1s-clear and the set/clear write, IRQ     4.2.6
//     9. input latching under ACR0                                    4.2.3
//    10. the ROM's sequences: overlay off, the box ID reading index 4,
//        the VBL from VIA2's T1 to VIA1's CA1 every 13022 E cycles    4.6
//
// THE BUS
//   GLUE's device port as 2.13 and 4.8 have it: the select rises while E
//   is low and holds through the E-high phase; the strobe is E's last
//   high clock; a write lands there and a read is taken there.  E here is
//   the bench's own 10/10 divider (4.4's re-phasing is GLUE's business,
//   held in sim/glue).  Two instances, as on the board: VIA2's PB7 pin is
//   VIA1's CA1.  The pins are computed as the machine module computes
//   them (4.5): OR where DDR says output, the external level otherwise,
//   the external level 1 where nothing drives.
//
//   Intervals are measured in E falling edges (e_falls, counted at the
//   edge that ends E's last high clock, which is also the edge a write
//   lands on), so an access in the middle of a measurement does not
//   disturb it.

`timescale 1ns/1ps

module tb_se30_via;

  reg clk = 0;
  always #31.9149 clk = ~clk;              // 15.6672 MHz; c16_en tied high
  reg reset_n = 0;

  // ------------------------------------------------------------------ E
  reg [4:0] ecnt = 0;
  always @(posedge clk) ecnt <= (ecnt == 19) ? 0 : ecnt + 1;
  wire e_clk = (ecnt >= 10);              // low 0-9, high 10-19
  integer e_falls = 0;
  always @(posedge clk) if (ecnt == 19) e_falls = e_falls + 1;

  // ---------------------------------------------------------- the bus
  reg        sel1 = 0, sel2 = 0, strobe = 0, rw = 1;
  reg  [3:0] rs = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata1, rdata2;
  wire       irq1_n, irq2_n;

  // ---------------------------------------------------------- the pins
  wire [7:0] pa1_out, pa1_oe, pb1_out, pb1_oe, pa2_out, pa2_oe, pb2_out, pb2_oe;
  reg  [7:0] pa1_ext = 8'hFF, pb1_ext = 8'hFF, pa2_ext = 8'hFF, pb2_ext = 8'b1011_0111;   // VIA2 PB6, PB3 tied low
  wire [7:0] pa1_pin = (pa1_oe & pa1_out) | (~pa1_oe & pa1_ext);
  wire [7:0] pb1_pin = (pb1_oe & pb1_out) | (~pb1_oe & pb1_ext);
  wire [7:0] pa2_pin = (pa2_oe & pa2_out) | (~pa2_oe & pa2_ext);
  wire [7:0] pb2_pin = (pb2_oe & pb2_out) | (~pb2_oe & pb2_ext);
  reg        ca1_1 = 1, ca2_1 = 1, cb1_1 = 1, cb2_1 = 1;      // VIA1's control inputs
  reg        ca1_2 = 1, ca2_2 = 0, cb1_2 = 1, cb2_2 = 0;      // VIA2's (the SCSI lines idle low, 4.7)
  reg        ca1_from_pb7 = 0;                                // item 10: VIA1 CA1 = VIA2 PB7 pin
  wire       ca2o1, ca2oe1, cb1o1, cb1oe1, cb2o1, cb2oe1;
  wire       ca2o2, ca2oe2, cb1o2, cb1oe2, cb2o2, cb2oe2;
  wire       via1_ca1 = ca1_from_pb7 ? pb2_pin[7] : ca1_1;

  se30_via via1 (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n), .e_clk(e_clk),
    .sel(sel1), .strobe(strobe), .rs(rs), .rw(rw), .wdata(wdata), .rdata(rdata1), .irq_n(irq1_n),
    .pa_in(pa1_pin), .pa_out(pa1_out), .pa_oe(pa1_oe),
    .pb_in(pb1_pin), .pb_out(pb1_out), .pb_oe(pb1_oe),
    .ca1(via1_ca1), .ca2_in(ca2_1), .ca2_out(ca2o1), .ca2_oe(ca2oe1),
    .cb1_in(cb1_1), .cb1_out(cb1o1), .cb1_oe(cb1oe1),
    .cb2_in(cb2_1), .cb2_out(cb2o1), .cb2_oe(cb2oe1));

  se30_via via2 (
    .clk(clk), .c16_en(1'b1), .reset_n(reset_n), .e_clk(e_clk),
    .sel(sel2), .strobe(strobe), .rs(rs), .rw(rw), .wdata(wdata), .rdata(rdata2), .irq_n(irq2_n),
    .pa_in(pa2_pin), .pa_out(pa2_out), .pa_oe(pa2_oe),
    .pb_in(pb2_pin), .pb_out(pb2_out), .pb_oe(pb2_oe),
    .ca1(ca1_2), .ca2_in(ca2_2), .ca2_out(ca2o2), .ca2_oe(ca2oe2),
    .cb1_in(cb1_2), .cb1_out(cb1o2), .cb1_oe(cb1oe2),
    .cb2_in(cb2_2), .cb2_out(cb2o2), .cb2_oe(cb2oe2));

  // ------------------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*88-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0d", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0d, want %0d", what, got, want); end
    end
  endtask

  // -------------------------------------------------------- bus access
  // one E-synchronous device cycle: select up while E is low, strobe in
  // E's last high clock, the read taken there, select down after
  reg [7:0] q;
  task access(input inst, input [3:0] r, input w, input [7:0] d);
    begin
      while (ecnt != 7) @(posedge clk);
      #1 rs = r; rw = !w; wdata = d;
      if (inst) sel2 = 1; else sel1 = 1;
      while (ecnt != 18) @(posedge clk);
      #1 strobe = 1;
      @(posedge clk);                                  // this edge ends clock 19: the write lands
      q = inst ? rdata2 : rdata1;                      // what was on the bus through clock 19
      #1 strobe = 0; sel1 = 0; sel2 = 0; rw = 1;
    end
  endtask
  task wr(input inst, input [3:0] r, input [7:0] d); begin access(inst, r, 1, d); end endtask
  task rd(input inst, input [3:0] r);               begin access(inst, r, 0, 8'h00); end endtask

  task wait_e(input integer n); begin repeat (n) begin while (ecnt != 19) @(posedge clk); @(posedge clk); end end endtask
  function flag(input inst, input integer b); begin flag = inst ? via2.ifr[b] : via1.ifr[b]; end endfunction

  // E falls from now until IFR bit b of the instance is set (limit falls)
  integer n, f0;
  task falls_until_flag(input inst, input integer b, input integer limit);
    begin
      f0 = e_falls;
      while (e_falls - f0 < limit && !flag(inst, b)) @(posedge clk);
      #1 n = e_falls - f0;
    end
  endtask
  // E falls between two settings of IFR bit b, the flag cleared by an IFR write in between
  task flag_period(input inst, input integer b, input integer limit);
    begin
      f0 = e_falls;
      while (e_falls - f0 < limit && !flag(inst, b)) @(posedge clk);
      #1 f0 = e_falls;
      wr(inst, 13, 8'h01 << b);
      while (e_falls - f0 < limit && !flag(inst, b)) @(posedge clk);
      #1 n = e_falls - f0;
    end
  endtask
  // E falls between two consecutive changes of the instance's PB7 pin
  reg pv;
  task pb7_period(input inst, input integer limit);
    begin
      f0 = e_falls; pv = inst ? pb2_pin[7] : pb1_pin[7];
      while (e_falls - f0 < limit && (inst ? pb2_pin[7] : pb1_pin[7]) == pv) @(posedge clk);
      #1 f0 = e_falls; pv = inst ? pb2_pin[7] : pb1_pin[7];
      while (e_falls - f0 < limit && (inst ? pb2_pin[7] : pb1_pin[7]) == pv) @(posedge clk);
      #1 n = e_falls - f0;
    end
  endtask
  task pulse_ca1_1_low; begin #1 ca1_1 = 0; repeat (3) @(posedge clk); #1 ca1_1 = 1; repeat (3) @(posedge clk); end endtask
  task cb1_1_pulse_low; begin #1 cb1_1 = 0; repeat (3) @(posedge clk); #1 cb1_1 = 1; repeat (3) @(posedge clk); end endtask

  localparam ORB = 0, ORA = 1, DDRB = 2, DDRA = 3, T1CL = 4, T1CH = 5, T1LL = 6, T1LH = 7,
             T2CL = 8, T2CH = 9, SR = 10, ACR = 11, PCR = 12, IFR = 13, IER = 14, ORA_NH = 15;

  integer i, lo, hi, idx;
  reg [7:0] b0, b1;
  reg [7:0] serial_out;

  initial begin
    repeat (30) @(posedge clk); #1 reset_n = 1;
    repeat (5) @(posedge clk);

    // ---- 1. reset
    $display("---- 1. reset (4.2.1)");
    lo = 0;
    for (i = 0; i < 4; i = i + 1) begin rd(0, i); if (q != 0) lo = lo + 1; end
    rd(0, ACR); if (q != 0) lo = lo + 1;
    rd(0, PCR); if (q != 0) lo = lo + 1;
    rd(0, IFR); if (q != 0) lo = lo + 1;
    check(lo == 0, "ORB ORA DDRB DDRA ACR PCR IFR read $00 after reset", lo, 0);
    rd(0, IER); check(q == 8'h80, "IER reads $80 after reset (bit 7 always 1)", q, 8'h80);
    check(pa1_oe == 0 && pb1_oe == 0 && pa2_oe == 0 && pb2_oe == 0, "every port line an input", pa1_oe | pb1_oe, 0);
    check(irq1_n == 1 && irq2_n == 1, "IRQ high", irq1_n, 1);
    check(ca2oe1 == 0 && cb1oe1 == 0 && cb2oe1 == 0, "CA2, CB1, CB2 inputs (PCR, ACR zero)", ca2oe1, 0);

    // ---- 2. ports
    $display("---- 2. ports (4.2.3)");
    pa1_ext = 8'hA5;
    wr(0, DDRA, 8'h0F); check(pa1_oe == 8'h0F, "DDRA $0F: PA3-0 outputs", pa1_oe, 8'h0F);
    wr(0, ORA, 8'hFF);  check((pa1_out & pa1_oe) == 8'h0F, "ORA $FF: the four outputs drive 1", pa1_out & pa1_oe, 8'h0F);
    rd(0, ORA);         check(q == 8'hAF, "ORA reads pins for inputs (A) and OR for outputs (F)", q, 8'hAF);
    wr(0, DDRA, 8'h00); wr(0, ORA, 8'h00); wr(0, DDRA, 8'h0F);
    check((pa1_out & pa1_oe) == 8'h0F, "a write to input bits leaves OR unchanged: outputs still 1", pa1_out & pa1_oe, 8'h0F);
    wr(0, ORA, 8'h03);  check((pa1_out & 8'h0F) == 8'h03, "ORA $03 with DDRA $0F: outputs 0011", pa1_out & 8'h0F, 3);
    pb1_ext = 8'h3C; wr(0, DDRB, 8'hF0); wr(0, ORB, 8'h55);
    rd(0, ORB);         check(q == 8'h5C, "ORB reads pins for inputs (C) and OR for outputs (5)", q, 8'h5C);
    wr(0, PCR, 8'h01);                                  // CA1 positive edge
    #1 ca1_1 = 0; repeat (3) @(posedge clk); #1 ca1_1 = 1; repeat (3) @(posedge clk);
    check(via1.ifr[1] == 1, "CA1 positive edge sets IFR1", via1.ifr[1], 1);
    rd(0, ORA_NH);      check(via1.ifr[1] == 1, "reading register 15 leaves IFR1 set", via1.ifr[1], 1);
    rd(0, ORA);         check(via1.ifr[1] == 0, "reading register 1 clears IFR1", via1.ifr[1], 0);
    wr(0, PCR, 8'h00); wr(0, DDRA, 0); wr(0, DDRB, 0); pa1_ext = 8'hFF; pb1_ext = 8'hFF;

    // ---- 3. T1 one-shot
    $display("---- 3. T1 one-shot (4.2.4)");
    wr(0, ACR, 8'h00);
    wr(0, T1CL, 8'd100); wr(0, T1CH, 8'd0);
    falls_until_flag(0, 6, 400);
    check(n == 101, "T1 = 100: IFR6 set 101 E cycles after the T1CH write (N+1)", n, 101);
    check(irq1_n == 1, "IRQ stays high with T1 not enabled", irq1_n, 1);
    rd(0, T1CL);        check(via1.ifr[6] == 0, "reading T1CL clears IFR6", via1.ifr[6], 0);
    wait_e(250);        check(via1.ifr[6] == 0, "one-shot: no second flag 250 cycles on", via1.ifr[6], 0);
    rd(0, T1CH); b1 = q; rd(0, T1CL); b0 = q;
    check({b1, b0} <= 16'd100, "the counter reloaded from the latches and is counting", {b1, b0}, 100);
    wr(0, T1CL, 8'd50); wr(0, T1CH, 8'd0);
    falls_until_flag(0, 6, 200); check(n == 51, "T1 = 50: 51 cycles", n, 51);
    wr(0, T1LH, 8'hFF); check(via1.ifr[6] == 0, "writing T1LH clears IFR6", via1.ifr[6], 0);
    rd(0, T1CH);        check(q < 8'hFF, "... without transferring the latch into the counter", q, 0);
    rd(0, T1LH);        check(q == 8'hFF, "T1LH reads the latch", q, 8'hFF);
    wr(0, T1CL, 8'd7);  rd(0, T1LL); check(q == 7, "a T1CL write is a T1LL write", q, 7);

    // ---- 4. T1 free-run and PB7
    $display("---- 4. T1 free-run, PB7 (4.2.4)");
    wr(0, DDRB, 8'h80); wr(0, ACR, 8'hC0);
    wr(0, T1CL, 8'd20); wr(0, T1CH, 8'd0);
    falls_until_flag(0, 6, 100); check(n == 21, "free-run: first IFR6 at N+1 = 21", n, 21);
    flag_period(0, 6, 100);      check(n == 21, "... and every 21 cycles after", n, 21);
    pb7_period(0, 100);          check(n == 21, "PB7 inverts every 21 E cycles (a square wave under ACR7)", n, 21);
    wr(0, IER, 8'hC0);
    falls_until_flag(0, 6, 100); #2 check(irq1_n == 0, "T1 enabled: IRQ low with IFR6 and IER6", irq1_n, 0);
    rd(0, T1CL);        #2 check(irq1_n == 1, "IRQ high once the flag is read away", irq1_n, 1);
    wr(0, IER, 8'h40);
    wr(0, T1CL, 8'h6E); wr(0, T1CH, 8'h19);            // the ROM's $196E
    falls_until_flag(0, 6, 7000); check(n == 6511, "$196E: 6511 E cycles per time-out", n, 6511);
    rd(0, T1CL); wr(0, ACR, 8'h00); wr(0, DDRB, 8'h00);

    // ---- 5. T2
    $display("---- 5. T2 (4.2.4)");
    wr(0, T2CL, 8'd60); wr(0, T2CH, 8'd0);
    falls_until_flag(0, 5, 200); check(n == 61, "T2 = 60: IFR5 at N+1 = 61", n, 61);
    rd(0, T2CL);        check(via1.ifr[5] == 0, "reading T2CL clears IFR5", via1.ifr[5], 0);
    wait_e(70);         check(via1.ifr[5] == 0, "no second flag: T2 rolls over freely", via1.ifr[5], 0);
    rd(0, T2CH); b1 = q; rd(0, T2CL); b0 = q;
    check({b1, b0} > 16'hFF00, "the counter is in $FFxx, rolled over past zero", {b1, b0}, 16'hFF80);
    wr(0, T2CH, 8'd0);
    falls_until_flag(0, 5, 200); check(n == 61, "re-armed by a T2CH write: 61 again (T2LL kept)", n, 61);
    rd(0, T2CL);
    wr(0, ACR, 8'h20);                                  // pulse counting on PB6
    wr(0, T2CL, 8'd3); wr(0, T2CH, 8'd0);
    wait_e(20);         check(via1.ifr[5] == 0, "pulse mode: E does not count", via1.ifr[5], 0);
    lo = 0;
    for (i = 0; i < 4; i = i + 1) begin #1 pb1_ext[6] = 0; wait_e(2); #1 pb1_ext[6] = 1; wait_e(2); if (i == 2) lo = via1.ifr[5]; end
    check(lo == 0 && via1.ifr[5] == 1, "T2 = 3 counts PB6 falling edges: flag on the fourth", via1.ifr[5], 1);
    rd(0, T2CL); wr(0, ACR, 8'h00);

    // ---- 6. the control lines
    $display("---- 6. CA1, CA2, CB1, CB2 (4.2.3)");
    wr(0, PCR, 8'h00);
    #1 ca1_1 = 1; repeat (3) @(posedge clk); #1 ca1_1 = 0; repeat (3) @(posedge clk);
    check(via1.ifr[1] == 1, "PCR0 = 0: CA1 negative edge sets IFR1", via1.ifr[1], 1);
    rd(0, ORA);
    #1 ca1_1 = 1; repeat (3) @(posedge clk);
    check(via1.ifr[1] == 0, "... and the positive edge does not", via1.ifr[1], 0);
    #1 ca2_1 = 0; repeat (3) @(posedge clk);
    check(via1.ifr[0] == 1, "PCR3-1 = 000: CA2 negative edge sets IFR0", via1.ifr[0], 1);
    rd(0, ORA);         check(via1.ifr[0] == 0, "an ORA read clears IFR0", via1.ifr[0], 0);
    #1 ca2_1 = 1; repeat (3) @(posedge clk);
    wr(0, PCR, 8'h02);                                  // CA2 independent, negative edge
    #1 ca2_1 = 0; repeat (3) @(posedge clk);
    rd(0, ORA);         check(via1.ifr[0] == 1, "independent CA2: an ORA read does not clear IFR0", via1.ifr[0], 1);
    wr(0, IFR, 8'h01);  check(via1.ifr[0] == 0, "an IFR write of $01 does", via1.ifr[0], 0);
    #1 ca2_1 = 1; repeat (3) @(posedge clk);
    wr(0, PCR, 8'h04);                                  // CA2 positive edge
    #1 ca2_1 = 0; repeat (3) @(posedge clk); lo = via1.ifr[0];
    #1 ca2_1 = 1; repeat (3) @(posedge clk);
    check(lo == 0 && via1.ifr[0] == 1, "PCR3-1 = 010: the positive edge, not the negative", via1.ifr[0], 1);
    rd(0, ORA);
    wr(0, PCR, 8'h10);                                  // CB1 positive edge, CB2 negative
    #1 cb1_1 = 0; repeat (3) @(posedge clk); lo = via1.ifr[4];
    #1 cb1_1 = 1; repeat (3) @(posedge clk);
    check(lo == 0 && via1.ifr[4] == 1, "PCR4 = 1: CB1 positive edge sets IFR4", via1.ifr[4], 1);
    #1 cb2_1 = 0; repeat (3) @(posedge clk);
    check(via1.ifr[3] == 1, "CB2 negative edge sets IFR3", via1.ifr[3], 1);
    rd(0, ORB);         check(via1.ifr[4] == 0 && via1.ifr[3] == 0, "an ORB read clears IFR4 and IFR3", via1.ifr[4], 0);
    #1 cb2_1 = 1; repeat (3) @(posedge clk);
    wr(0, PCR, 8'h08);                                  // CA2 handshake output
    check(ca2oe1 == 1 && ca2o1 == 1, "CA2 handshake mode: an output, high", ca2o1, 1);
    rd(0, ORA);         check(ca2o1 == 0, "... low after an ORA read", ca2o1, 0);
    pulse_ca1_1_low;    check(ca2o1 == 1, "... high again on CA1's active edge", ca2o1, 1);
    rd(0, ORA);
    wr(0, PCR, 8'h0A);                                  // CA2 pulse output
    wr(0, ORA, 8'h00); lo = ca2o1; wait_e(2); hi = ca2o1;
    check(lo == 0 && hi == 1, "CA2 pulse mode: low for one E cycle after an ORA access", lo, 0);
    wr(0, PCR, 8'h0C);  check(ca2o1 == 0 && ca2oe1 == 1, "CA2 manual low", ca2o1, 0);
    wr(0, PCR, 8'h0E);  check(ca2o1 == 1 && ca2oe1 == 1, "CA2 manual high", ca2o1, 1);
    wr(0, PCR, 8'hC0);  check(cb2o1 == 0 && cb2oe1 == 1, "CB2 manual low (PCR7-5 = 110)", cb2o1, 0);
    wr(0, PCR, 8'h00);  check(ca2oe1 == 0 && cb2oe1 == 0, "PCR $00: both inputs again", ca2oe1, 0);
    wr(0, IFR, 8'h7F);

    // ---- 7. the shift register
    $display("---- 7. the shift register (4.2.5)");
    wr(0, ACR, 8'h1C);                                  // 111: shift out under CB1
    check(cb2oe1 == 1 && cb1oe1 == 0, "mode 111: CB2 an output, CB1 an input", cb2oe1, 1);
    wr(0, SR, 8'hA5);
    serial_out = 0;
    for (i = 0; i < 8; i = i + 1) begin
      #1 cb1_1 = 0; repeat (3) @(posedge clk); #1 serial_out = {serial_out[6:0], cb2o1};
      #1 cb1_1 = 1; repeat (3) @(posedge clk);
    end
    check(serial_out == 8'hA5, "eight CB1 falling edges shift $A5 out on CB2, MSB first", serial_out, 8'hA5);
    check(via1.ifr[2] == 1, "IFR2 set after the eighth shift", via1.ifr[2], 1);
    rd(0, SR);          check(q == 8'hA5 && via1.ifr[2] == 0, "SR reads $A5 (rotated back) and the read clears IFR2", q, 8'hA5);
    for (i = 0; i < 7; i = i + 1) cb1_1_pulse_low;
    check(via1.ifr[2] == 0, "seven more edges: no flag", via1.ifr[2], 0);
    cb1_1_pulse_low;
    check(via1.ifr[2] == 1, "the eighth: flag (the counter runs modulo 8 without stopping)", via1.ifr[2], 1);
    wr(0, ACR, 8'h0C);                                  // 011: shift in under CB1
    check(cb2oe1 == 0, "mode 011: CB2 an input", cb2oe1, 0);
    rd(0, SR);
    for (i = 0; i < 8; i = i + 1) begin
      #1 cb2_1 = (8'h3C >> (7 - i)) & 1; #1 cb1_1 = 0; repeat (3) @(posedge clk);
      #1 cb1_1 = 1; repeat (3) @(posedge clk);
    end
    check(via1.ifr[2] == 1, "eight CB1 rising edges: IFR2", via1.ifr[2], 1);
    rd(0, SR);          check(q == 8'h3C, "the byte shifted in MSB first, entering at bit 0", q, 8'h3C);
    wr(0, ACR, 8'h00);
    for (i = 0; i < 9; i = i + 1) cb1_1_pulse_low;
    check(via1.ifr[2] == 0, "mode 000: CB1 edges never set IFR2", via1.ifr[2], 0);
    wr(0, IFR, 8'h7F);
    // the internal modes, to the R6522 table's one line each
    wr(0, ACR, 8'h18); wr(0, SR, 8'h55);                // 110: out under E
    check(cb1oe1 == 1, "mode 110: CB1 is the VIA's clock output", cb1oe1, 1);
    falls_until_flag(0, 2, 40); check(n <= 20, "... eight bits out under E within 20 cycles", n, 16);
    rd(0, SR);
    wr(0, ACR, 8'h08); rd(0, SR);                       // 010: in under E
    falls_until_flag(0, 2, 40); check(n <= 20, "mode 010: eight bits in under E within 20 cycles", n, 16);
    rd(0, SR);
    wr(0, T2CL, 8'd4); wr(0, ACR, 8'h14); wr(0, SR, 8'h0F);   // 101: out under T2
    falls_until_flag(0, 2, 200); check(n > 20 && n <= 100, "mode 101: eight bits out under T2 (latch 4), slower than E", n, 80);
    rd(0, SR);
    wr(0, ACR, 8'h10); wr(0, SR, 8'hF0);                // 100: free-running out under T2
    falls_until_flag(0, 2, 200); check(n == 200, "mode 100: free-running, IFR2 never set", n, 200);
    wr(0, ACR, 8'h00); rd(0, SR); wr(0, IFR, 8'h7F);

    // ---- 8. IFR / IER
    $display("---- 8. IFR and IER (4.2.6)");
    wr(0, IER, 8'hC0); rd(0, IER); check(q == 8'hC0, "IER write $C0 sets bit 6; reads $C0", q, 8'hC0);
    wr(0, IER, 8'h81); rd(0, IER); check(q == 8'hC1, "IER write $81 sets bit 0, bit 6 untouched", q, 8'hC1);
    wr(0, IER, 8'h01); rd(0, IER); check(q == 8'hC0, "IER write $01 clears bit 0 only", q, 8'hC0);
    wr(0, T1CL, 8'd5); wr(0, T1CH, 8'd0); falls_until_flag(0, 6, 20);
    rd(0, IFR);         check(q == 8'hC0, "IFR reads $C0: T1 flag with bit 7, T1 enabled", q, 8'hC0);
    #2 check(irq1_n == 0, "IRQ low", irq1_n, 0);
    wr(0, IER, 8'h40); rd(0, IFR); #2
    check(q == 8'h40 && irq1_n == 1, "T1 disabled: IFR $40, bit 7 clear, IRQ high, the flag kept", q, 8'h40);
    wr(0, IFR, 8'h40); rd(0, IFR); check(q == 8'h00, "IFR write $40 clears the flag", q, 0);
    wr(0, IFR, 8'hFF); wr(0, IER, 8'h7F);

    // ---- 9. latching
    $display("---- 9. input latching under ACR0 (4.2.3)");
    wr(0, DDRA, 8'h00); wr(0, PCR, 8'h00); wr(0, ACR, 8'h01);
    pa1_ext = 8'h11; pulse_ca1_1_low;
    pa1_ext = 8'h22; rd(0, ORA); check(q == 8'h11, "IRA holds the pins as of CA1's edge", q, 8'h11);
    pulse_ca1_1_low;     rd(0, ORA); check(q == 8'h22, "... until the next edge", q, 8'h22);
    pa1_ext = 8'h33; wr(0, ACR, 8'h00); rd(0, ORA); check(q == 8'h33, "latching off: live pins", q, 8'h33);
    pa1_ext = 8'hFF; wr(0, IFR, 8'h7F);

    // ---- 10. the ROM's sequences
    $display("---- 10. the ROM's sequences (4.6)");
    // overlay off: DDRA $3D, ORA read, bits 4 and 3 cleared, written back
    wr(0, DDRA, 8'h3D); rd(0, ORA); b0 = q;
    check(b0 == 8'hC2, "after DDRA $3D the ROM reads ORA as $C2 (inputs high, outputs 0)", b0, 8'hC2);
    wr(0, ORA, b0 & ~8'h18);
    check(pa1_pin[4] == 0 && pa1_pin[3] == 0 && pa1_pin[6] == 1, "OVERLAY and SYNC pins low, PA6 still high (undriven)", pa1_pin, 8'hC2);
    // the strap test: PA0 cleared then set, PA1 read each time
    rd(0, ORA); wr(0, ORA, q & ~8'h01); rd(0, ORA); lo = q[1];
    wr(0, ORA, q | 8'h01); rd(0, ORA); hi = q[1];
    check(lo == 1 && hi == 1, "PA1 reads 1 both times: the normal path", lo, 1);
    // the box ID: PA6 of VIA1, PB3 of VIA2 made an input and read
    rd(0, ORA_NH); idx = 2 + (q[6] ? 2 : 0);
    rd(1, DDRB); b1 = q; wr(1, DDRB, b1 & ~8'h08); rd(1, ORB); idx = idx + (q[3] ? 1 : 0); wr(1, DDRB, b1);
    check(idx == 4, "the box-ID index is 4 (PA6 undriven high, PB3 tied low): the SE/30's", idx, 4);
    // the RAMSIZ prelude and the init
    wr(1, DDRA, 8'hC0); rd(1, ORA); wr(1, ORA, q | 8'hC0);
    check(pa2_pin[7:6] == 2'b11, "RAMSIZ pins 11", pa2_pin[7:6], 3);
    wr(1, DDRA, 8'h00); check(pa2_pin[7:6] == 2'b11, "DDRA restored to 0: the pins undriven, still 11", pa2_pin[7:6], 3);
    wr(1, DDRA, 8'hC0); wr(1, ORB, 8'h05); wr(1, DDRB, 8'h80); wr(1, IER, 8'h7F);
    check(pb2_pin[0] == 1 && pb2_pin[2] == 1 && pb2_pin[7] == 0, "VIA2 init: CDIS* and PWROFF high, PB7 driven 0", pb2_pin, 8'h35);
    // the VBL: VIA2 T1 $196E free-running onto PB7, VIA1 CA1 negative edge, IER $83
    ca1_from_pb7 = 1;
    wr(0, PCR, 8'h00); wr(0, IER, 8'h83); wr(0, IFR, 8'h7F);
    wr(1, ACR, 8'hC0); wr(1, T1CL, 8'h6E); wr(1, T1CH, 8'h19);
    pb7_period(1, 8000);         check(n == 6511, "VIA2 PB7 inverts every 6511 E cycles", n, 6511);
    flag_period(0, 1, 15000);    check(n == 13022, "VIA1 CA1 (VBL) every 13022 E cycles = 2 x 6511: 60.15 Hz", n, 13022);
    #2 check(irq1_n == 0, "and VIA1's IRQ is low for it (IER $83)", irq1_n, 0);
    rd(0, ORA); #2 check(irq1_n == 1, "cleared by the ORA read the handler does", irq1_n, 1);

    // ---- verdict
    if (fails == 0) $display("==== PASS: %0d checks, the VIA holds to plan 4.2", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

  initial begin
    #200_000_000;
    $display("==== FAIL: bench timed out (200 ms)");
    $finish;
  end

endmodule
