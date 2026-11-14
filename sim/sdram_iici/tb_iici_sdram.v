// tb_iici_sdram.v - rtl/iici_sdram.v against sim/sdram/sdram_model.v at 100 MHz
// (SE30_PLAN.md "THE MacIIci TOP AND ITS SDRAM").
//
// WHAT THIS PROVES
//   1. the power-up ladder and the training at CL2 (the model checks every
//      datasheet interval at tCK 10 ns), both captures inside the eye
//   2. a CPU read's m_soon is seen at the fifth clk_sys edge after the one
//      its request follows - the MDU's termination for a 5-clock read (P0 +
//      100 ns) - and its long by the sixth, where the KCLK wrapper takes it
//   3. write/read pairs at a tight spacing stay on time and right
//   4. writes with byte masks land, acknowledged once (posted)
//   5. a burst of four in wrap order, each long by the MDU's beat (5-2-2-2)
//   6. a video burst of eight in order
//   7. the MDU's refresh window brings two AUTO REFRESH
//   8. a CPU read behind a video burst: how late (reported)
// THE PIN DELAYS: as sim/sdram's bench (CLK_TO_PIN 4, OUT_TO_PIN 4,
// DQ_TO_REG 2); the chip's clock clk + SDC inverted; captures A = clk +
// CAPA, B = clk + CAPB (PROVISIONAL: the controller's header).

`timescale 1ns/1ps

module tb_iici_sdram;
  reg clk = 0, clk_sys = 0;
  // one process: clk_sys's edges are clk's even ones
  always begin #5.0 clk = ~clk; if (clk) clk_sys = ~clk_sys; end
  parameter real SDC = 2.5, CAPA = 1.667, CAPB = 0.3125;
  reg clk_sdc = 0, clk_capa = 0, clk_capb = 0;
  always @(clk) begin
    clk_sdc  <= #(SDC) clk;
    clk_capa <= #(CAPA) clk;
    clk_capb <= #(CAPB) clk;
  end
  reg phi = 0;
  always @(posedge clk_sys) phi <= ~phi;
  reg reset_n = 0;
  parameter real CLK_TO_PIN = 4.0, OUT_TO_PIN = 4.0, DQ_TO_REG = 2.0;

  reg         m_req = 0, m_we = 0, m_burst = 0, m_refresh = 0, v_req = 0;
  reg  [24:0] m_addr = 0, v_addr = 0;
  reg   [3:0] m_be = 4'hF;
  reg  [31:0] m_wdata = 0;
  wire [31:0] m_rdata, v_rdata;
  wire        m_ack, m_soon, v_ack, ready, cap_sel, c1_ok;
  wire  [1:0] cap_ok;
  wire [13:0] cap_fail_a, cap_fail_b, c1_fail;
  reg         dl_req = 0;
  reg  [23:0] dl_addr = 0;
  reg  [15:0] dl_data = 0;
  wire        dl_ack, dk_ack;
  wire [15:0] dk_rdata;
  wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_addr;
  wire  [1:0] sd_ba, sd_dqm;
  wire [15:0] sd_dq;

  iici_sdram #(.TR_READS_LOG2(5)) dut (
    .clk(clk), .clk_sdc(clk_sdc), .clk_capa(clk_capa), .clk_capb(clk_capb), .phi(phi), .reset_n(reset_n),
    .ready(ready), .cap_sel(cap_sel), .cap_ok(cap_ok), .cap_fail_a(cap_fail_a), .cap_fail_b(cap_fail_b),
    .c1_ok(c1_ok), .c1_fail(c1_fail),
    .m_req(m_req), .m_we(m_we), .m_burst(m_burst), .m_addr(m_addr), .m_be(m_be), .m_wdata(m_wdata),
    .m_rdata(m_rdata), .m_ack(m_ack), .m_soon(m_soon), .m_refresh(m_refresh), .v_req(v_req), .v_addr(v_addr), .v_rdata(v_rdata), .v_ack(v_ack),
    .dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_ack(dl_ack),
    .dk_req(1'b0), .dk_we(1'b0), .dk_addr(24'd0), .dk_wdata(16'd0), .dk_rdata(dk_rdata), .dk_ack(dk_ack),
    .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dq(sd_dq), .sd_dqm(sd_dqm),
    .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n));

  // transport delays: an assign's delay is inertial, and at 150 MHz it
  // swallowed the 3.33 ns clock half-periods behind a 4 ns delay
  reg         sd_clk_chip = 0, cke_c = 1, cs_n_c = 1, ras_n_c = 1, cas_n_c = 1, we_n_c = 1, oe_c = 0;
  reg  [12:0] addr_c = 0;
  reg   [1:0] ba_c = 0;
  reg  [15:0] dq_out_c = 0;
  wire [15:0] dq_chip;
  always @(sd_clk) sd_clk_chip <= #(CLK_TO_PIN) sd_clk;
  always @(sd_cke or sd_cs_n or sd_ras_n or sd_cas_n or sd_we_n or sd_addr or sd_ba or dut.dq_oe or dut.dq_out) begin
    {cke_c, cs_n_c, ras_n_c, cas_n_c, we_n_c, addr_c, ba_c} <= #(OUT_TO_PIN) {sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_addr, sd_ba};
    oe_c <= #(OUT_TO_PIN) dut.dq_oe;
    dq_out_c <= #(OUT_TO_PIN) dut.dq_out;
  end
  assign dq_chip = oe_c ? dq_out_c : 16'hzzzz;
  reg  [15:0] dq_back = 16'hzzzz;
  always @(dq_chip or dut.dq_oe) dq_back <= #(DQ_TO_REG) (dut.dq_oe ? 16'hzzzz : dq_chip);
  assign sd_dq = dq_back;
  sdram_model #(.COL_BITS(9), .tCK(10.0), .tAC(6.0)) chip (
    .clk(sd_clk_chip), .cke(cke_c), .cs_n(cs_n_c), .ras_n(ras_n_c), .cas_n(cas_n_c), .we_n(we_n_c),
    .ba(ba_c), .addr(addr_c), .dqm(addr_c[12:11]), .dq(dq_chip));

  integer trn = 0;
  always @(posedge clk) if ($test$plusargs("VTRACE") && dut.state == 4'd4)
    $display("VT t=%0.2f seq %0d cmd %b a_n %0d rd_cnt %0d vb_in %0d vb_out %0d v_hold %0d v_ack %b dq_r %h", $realtime, dut.seq, dut.cmd, dut.a_n, dut.rd_cnt, dut.vb_in, dut.vb_out, dut.v_hold, dut.v_ack, dut.dq_r);
  integer pass = 0, fails = 0;
  task check(input ok, input [8*96-1:0] what);
    begin if (ok) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0s", what); end end
  endtask

  // the MDU's side, at clk_sys edges
  integer edge_n = 0, acks = 0, vacks = 0, refs = 0, soon_at = -1;
  integer ack_at [0:7];
  reg [31:0] got [0:7], vgot [0:7];
  always @(posedge clk_sys) begin
    edge_n = edge_n + 1;
    if (m_soon && soon_at < 0) soon_at = edge_n;
    if (m_ack) begin if (acks < 8) begin ack_at[acks] = edge_n; got[acks] = m_rdata; end acks = acks + 1; end
    if (v_ack) begin if (vacks < 8) vgot[vacks] = v_rdata; vacks = vacks + 1; end
  end
  always @(posedge clk) if (!sd_cs_n && !sd_ras_n && !sd_cas_n && sd_we_n) refs = refs + 1;

  integer e0;
  task req(input we, input burst, input [24:0] a, input [3:0] be, input [31:0] wd);
    begin
      @(posedge clk_sys); #1;
      m_we = we; m_burst = burst; m_addr = a; m_be = be; m_wdata = wd; m_req = 1; acks = 0; soon_at = -1; e0 = edge_n;
      @(posedge clk_sys); #1 m_req = 0;
    end
  endtask
  task wait_acks(input integer n);
    integer t; begin t = 0; while (acks < n && t < 200) begin @(posedge clk_sys); t = t + 1; end end
  endtask
  task dl(input [23:0] a, input [15:0] d);
    begin
      @(posedge clk_sys); #1 dl_addr = a; dl_data = d; dl_req = 1;
      while (!dl_ack) @(posedge clk_sys);
      #1 dl_req = 0; while (dl_ack) @(posedge clk_sys);
    end
  endtask

  integer i, bad;
  initial begin
    repeat (5) @(posedge clk); #1 reset_n = 1;
    while (!ready) @(posedge clk);
    $display("      ready at %0.1f us: cap_ok %b (A %0d failures, B %0d), chose %s", $realtime / 1000.0, cap_ok, cap_fail_a, cap_fail_b, cap_sel ? "B" : "A");
    check(cap_ok == 2'b11 && cap_sel == 0, "the training: both captures clean in the model, A chosen");

    dl(24'hC00000, 16'h1122); dl(24'hC00001, 16'h3344); dl(24'hC00002, 16'h5566); dl(24'hC00003, 16'h7788);
    req(0, 0, 25'h600000, 4'hF, 0); wait_acks(1);
    $display("      a read: m_soon at clk_sys edge %0d, the long at %0d after its request's, %08x", soon_at - e0, ack_at[0] - e0, got[0]);
    check(got[0] == 32'h11223344 && soon_at - e0 == 5 && ack_at[0] - e0 == 6,
          "a read: m_soon at the fifth clk_sys edge (the MDU's termination), the long by the sixth (the wrapper's edge)");

    req(1, 0, 25'h000100, 4'hF, 32'hDEADBEEF); wait_acks(1); check(acks == 1, "a write: acknowledged once");
    req(1, 0, 25'h000100, 4'b0101, 32'h00AA00BB); wait_acks(1);
    req(0, 0, 25'h000100, 4'hF, 0); wait_acks(1);
    check(got[0] == 32'hDEAABEBB && soon_at - e0 == 5 && ack_at[0] - e0 == 6, "a masked write lands by its bytes; read back on time");

    bad = 0;
    for (i = 0; i < 6; i = i + 1) begin
      req(1, 0, 25'h000200 + i, 4'hF, 32'h10000000 + i); wait_acks(1);
      req(0, 0, 25'h000200 + i, 4'hF, 0); wait_acks(1);
      if (got[0] != 32'h10000000 + i || soon_at - e0 != 5 || ack_at[0] - e0 != 6) bad = bad + 1;
    end
    check(bad == 0, "write/read pairs back to back: every read on time and right");

    for (i = 0; i < 4; i = i + 1) begin req(1, 0, 25'h000300 + i, 4'hF, 32'hB0000000 + i); wait_acks(1); end
    repeat (4) @(posedge clk_sys);
    req(0, 1, 25'h000302, 4'hF, 0); wait_acks(4);
    $display("      burst: acks at %0d %0d %0d %0d, %08x %08x %08x %08x", ack_at[0] - e0, ack_at[1] - e0, ack_at[2] - e0, ack_at[3] - e0, got[0], got[1], got[2], got[3]);
    check(got[0] == 32'hB0000002 && got[1] == 32'hB0000003 && got[2] == 32'hB0000000 && got[3] == 32'hB0000001, "a burst: the line in wrap order 2 3 0 1");
    check(soon_at - e0 == 5 && ack_at[0] - e0 == 6 && ack_at[1] - e0 <= 9 && ack_at[2] - e0 <= 13 && ack_at[3] - e0 <= 17, "a burst: m_soon at 5, each long by the MDU's beat (5-2-2-2)");

    for (i = 0; i < 8; i = i + 1) begin req(1, 0, 25'h000400 + i, 4'hF, 32'hC0000000 + i); wait_acks(1); end
    repeat (4) @(posedge clk_sys);
    @(posedge clk_sys); #1 v_addr = 25'h000400; v_req = 1; vacks = 0; @(posedge clk_sys); #1 v_req = 0;
    i = 0; while (vacks < 8 && i < 200) begin @(posedge clk_sys); i = i + 1; end
    $display("      video: %0d longs: %08x %08x %08x %08x %08x %08x %08x %08x", vacks, vgot[0], vgot[1], vgot[2], vgot[3], vgot[4], vgot[5], vgot[6], vgot[7]);
    check(vacks == 8 && vgot[0] == 32'hC0000000 && vgot[3] == 32'hC0000003 && vgot[7] == 32'hC0000007, "a video burst: eight longs in order");

    @(posedge clk_sys); #1 v_addr = 25'h000400; v_req = 1; vacks = 0; @(posedge clk_sys); #1 v_req = 0;
    req(0, 0, 25'h000100, 4'hF, 0); wait_acks(1);
    $display("      a read right behind a video burst: m_soon at clk_sys edge %0d (5 is on time)", soon_at - e0);
    check(got[0] == 32'hDEAABEBB, "a read behind a video burst: the right data");
    repeat (40) @(posedge clk_sys);

    i = refs; @(posedge clk_sys); #1 m_refresh = 1; @(posedge clk_sys); #1 m_refresh = 0;
    repeat (20) @(posedge clk_sys);
    check(refs - i >= 2, "the refresh window: two AUTO REFRESH");

    check(chip.errors == 0, "the model saw no datasheet violation");
    if (fails == 0) $display("==== PASS: %0d checks - the IIci's SDRAM at 100 MHz", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end
  initial begin #3000000; $display("==== FAIL: timeout"); $finish; end
endmodule
