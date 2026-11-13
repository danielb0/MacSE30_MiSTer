// tb_iici_mdu.v - the IIci's MDU held to SE30_PLAN.md "THE MDU" (2026-11-13).
//
// WHAT THIS PROVES
//   1. overlay: ROM at $0 from reset, no RAM cycle; the first access to
//      $4xxxxxxx ends it; $0 is RAM after                         G p.115 (READING)
//   2. ROM 5 clocks, the 512 KB repeating through $4xxxxxxx         G Table 5-9
//   3. RAM read 5, write 4; after a write to the same bank, back
//      to back, 6 / 5; the other bank and a later cycle unaffected DC3 15-3..15-6
//   4. burst 5-2-2-2 with CBREQ*, CBACK* given, the line's longs in
//      wrap order; no CBACK* for a write, the ROM or an empty bank DC3 15-5/15-6
//   5. banks: A at $0, B at $04000000, A27-A29 ignored; a bank
//      aliases modulo its size; an empty bank reads all ones and
//      sends nothing to the SDRAM; bank B at 32 MB in the SDRAM
//   6. I/O: Figure 3-8's windows acknowledged as 8-bit ports at
//      $50xxxxxx and in the $40000 images, the gaps and $51-$5F
//      bus-errored; A17 decoded                                    G Figure 3-8
//   7. the termination never comes before the documented clock, and
//      later only when the memory is late (dbg_late counts it)
//   8. refresh: a RAM cycle waits at most one refresh, about one in
//      every 15.6 us of back-to-back RAM cycles
//   9. c16_en averages 15.6672 MHz exactly
//  10. interrupts: NMI 7, SCC 4, RBV 2, VIA1 1                     G Table 3-5
//
// THE BUS (the KCLK wrapper's timing, tg68k.v CLOCKING): clk is 50 MHz,
// phi1 and phi2 alternate.  The bus changes at phi1 edges; the MDU runs at
// phi2 (cpu_en); DSACK*/BERR are taken at phi1 edges.  AS* falls at phi1
// edge 0 with the address, ECS* in the phi2 clk after it (the KCLK
// wrapper's: no earlier than AS*); a termination taken at edge k is a cycle of k + 2 clocks (GLUE's
// RAM acknowledge, a phi2 after it first sees AS*, is taken at edge 2: the
// 4-clock cycle the machine bench measures); AS* rises at edge k + 1 and
// the next cycle starts at the edge after (the bus's tightest gap).

`timescale 1ns/1ps

module tb_iici_mdu;

  reg clk = 0, reset_n = 0;
  always #10 clk = !clk;
  reg ph = 0;                            // 1: this clk is a phi2 clk
  always @(posedge clk) ph <= !ph;
  wire phi2 = ph, phi1 = !ph;

  reg  [31:0] a = 0, dout = 0;
  reg         as_n = 1, rw_n = 1, cbreq = 0, ecs_r = 0;
  wire        ecs = ecs_r && phi2;      // the KCLK wrapper's: kb_ecs in the phi2 clk after AS* falls
  reg   [2:0] fc = 3'd5;
  reg   [1:0] siz = 0;
  reg   [1:0] bank_a = 2'd3, bank_b = 2'd3;
  reg         drq = 1;
  reg   [3:0] irq = 4'hF;                // {nmi, scc, rbv, via1}, active low
  wire [31:0] din;
  wire  [1:0] dsack_n;
  wire        berr, cback, c16_en;
  wire  [2:0] ipl_n;

  wire        m_req, m_we, m_burst;
  wire [24:0] m_addr;
  wire  [3:0] m_be;
  wire [31:0] m_wdata;
  reg  [31:0] m_rdata = 0;
  reg         m_ack = 0;
  wire [15:0] late;
  reg         vid_req = 0, vid_frame = 0;
  wire        v_req;
  wire [24:0] v_addr;
  integer     v_reqs = 0;
  reg  [24:0] v_last = 0;
  always @(posedge clk) if (v_req) begin v_reqs = v_reqs + 1; v_last = v_addr; end
  wire        overlay;

  iici_mdu mdu (
    .clk(clk), .cpu_en(phi2), .reset_n(reset_n), .c16_en(c16_en),
    .cpu_addr(a), .ecs(ecs), .cpu_as_n(as_n), .cpu_rw_n(rw_n), .cpu_fc(fc), .cpu_siz(siz), .cpu_dout(dout),
    .cpu_din(din), .dsack_n(dsack_n), .berr(berr), .ipl_n(ipl_n), .cbreq(cbreq), .cback(cback),
    .bank_a(bank_a), .bank_b(bank_b),
    .m_req(m_req), .m_we(m_we), .m_burst(m_burst), .m_addr(m_addr), .m_be(m_be), .m_wdata(m_wdata),
    .m_rdata(m_rdata), .m_ack(m_ack), .m_refresh(),
    .vid_req(vid_req), .vid_frame(vid_frame), .vid_ld(), .vid_data(), .v_req(v_req), .v_addr(v_addr), .v_rdata(32'h0), .v_ack(1'b0),
    .via1_sel(), .scc_sel(), .scsi_sel(), .scsi_dack(), .asc_sel(), .swim_sel(), .vdac_sel(), .rbv_sel(),
    .dev_strobe(), .dev_addr(), .dev_rw(), .dev_wdata(), .dev_rdata(8'h5A), .scsi_drq(drq),
    .e_clk(), .c3m_en(),
    .fpu_sel(), .fpu_dsack_n(2'b11), .fpu_rdata(32'h0),
    .slot_sel(), .nb_dsack_n(2'b11), .nb_rdata(32'h0), .nb_berr(1'b0), .slot_be(),
    .via1_irq_n(irq[0]), .rbv_irq_n(irq[1]), .scc_irq_n(irq[2]), .nmi_n(irq[3]),
    .overlay(overlay), .dbg_late(late));

  // ---------------------------------------------------- the memory port
  // the SDRAM: LAT clks from the edge that sees m_req to the edge the MDU
  // takes the first long, one a clk after; a sparse store
  // keyed by the longword address
  integer LAT = 4;
  reg [31:0] store [0:65535];
  reg [24:0] key_addr [0:65535];
  integer nkeys = 0;
  function integer find(input [24:0] ad);
    integer j; begin find = -1; for (j = 0; j < nkeys; j = j + 1) if (key_addr[j] == ad) find = j; end
  endfunction
  function [31:0] rd(input [24:0] ad);
    integer j; begin j = find(ad); rd = (j < 0) ? {7'h55, ad} : store[j]; end
  endfunction
  integer reqs = 0;
  reg [24:0] last_maddr; reg last_burst, last_we;
  initial begin : port
    integer n, j, k; reg [24:0] ad; reg [31:0] w; reg [3:0] be;
    forever begin
      @(posedge clk);
      if (m_req) begin
        reqs = reqs + 1; last_maddr = m_addr; last_burst = m_burst; last_we = m_we;
        ad = m_addr; w = m_wdata; be = m_be;
        n = m_burst ? 4 : 1;
        repeat (LAT - 1) @(posedge clk);
        for (k = 0; k < n; k = k + 1) begin
          if (!last_we) m_rdata <= rd({ad[24:2], ad[1:0] + k[1:0]});
          else begin
            j = find(ad);
            if (j < 0) begin j = nkeys; nkeys = nkeys + 1; key_addr[j] = ad; store[j] = {7'h55, ad}; end
            store[j] = {be[3] ? w[31:24] : store[j][31:24], be[2] ? w[23:16] : store[j][23:16],
                        be[1] ? w[15:8] : store[j][15:8], be[0] ? w[7:0] : store[j][7:0]};
          end
          m_ack <= 1; @(posedge clk); m_ack <= 0;
        end
      end
    end
  end

  // ---------------------------------------------------------- the bus
  integer pass = 0, fails = 0;
  task check(input ok, input [8*80-1:0] what);
    begin if (ok) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0s", what); end end
  endtask

  task p_edge; begin @(posedge clk); while (!phi1) @(posedge clk); end endtask

  // one bus cycle; len = first termination's clocks; beats = the clocks
  // between the burst's terminations, packed 8 bits each; d0..d3 its data
  integer len, nbeat, gap_extra = 0;
  integer verb = 0;
  initial verb = $test$plusargs("VERB");
  reg [31:0] d [0:3];
  reg  [1:0] got_ds;
  reg        got_berr, got_cback;
  reg [31:0] beat_at;
  task cyc(input [31:0] ad, input rw, input [31:0] wd, input cb);
    integer k, last;
    begin
      repeat (gap_extra) p_edge;
      p_edge;
      a = ad; rw_n = rw; dout = wd; siz = 2'b00; cbreq = cb; ecs_r = 1; as_n = 0;
      k = 0; len = -1; nbeat = 0; got_berr = 0; got_cback = 0; beat_at = 0; last = 0;
      while (1) begin
        p_edge; k = k + 1; ecs_r = 0;
        if (berr) begin got_berr = 1; len = k + 2; as_n = 1; cbreq = 0; disable cyc; end
        if (dsack_n != 2'b11) begin
          if (nbeat == 0) begin len = k + 2; got_ds = dsack_n; got_cback = cback; end
          else beat_at = {beat_at[23:0], 8'(k - last)};
          d[nbeat] = din; nbeat = nbeat + 1; last = k;
          if (verb) $display("      %h rw %0d: beat %0d at edge %0d (len %0d) ds %b data %h", ad, rw, nbeat, k, len, dsack_n, din);
          if (!(got_cback && cb) || nbeat == 4) begin p_edge; as_n = 1; cbreq = 0; disable cyc; end
        end
        if (k > 20000) begin $display("TIMEOUT at %h", ad); as_n = 1; disable cyc; end
      end
    end
  endtask

  // ---------------------------------------------------------- the tests
  integer i, w, refd, nref, rq0, c16n, clks;
  reg [31:0] x;
  real t0, nexp;
  initial begin
    repeat (4) @(posedge clk); reset_n = 1;

    // 1, 2: overlay and ROM
    rq0 = reqs; cyc(32'h00000004, 1, 0, 0);
    check(overlay && last_maddr == 25'h600001 && !last_we && len == 5, "overlay: $4 reads ROM long 1 in 5 clocks");
    cyc(32'h4080002A, 1, 0, 0);
    check(!overlay && last_maddr[24:17] == 8'h30 && last_maddr[16:0] == 17'h0000A && len == 5, "ROM $4080002A: 5 clocks, overlay off");
    cyc(32'h4FF80010, 1, 0, 0);
    check(last_maddr == 25'h600004 && len == 5, "ROM repeats through $4xxxxxxx");
    rq0 = reqs; cyc(32'h40800000, 0, 32'h12345678, 0);
    check(reqs == rq0 && got_ds == 2'b00, "a ROM write: acknowledged, no memory cycle");

    // 3: RAM timing
    cyc(32'h00001000, 1, 0, 0);  check(len == 5 && got_ds == 2'b00 && last_maddr == 25'h000400, "RAM read 5 clocks, bank A long $400");
    cyc(32'h00001000, 0, 32'hCAFEF00D, 0); check(len == 4, "RAM write 4 clocks");
    cyc(32'h00001000, 1, 0, 0);  check(len == 6 && d[0] == 32'hCAFEF00D, "read after a write, back to back: 6, the data written");
    cyc(32'h00001004, 0, 32'h11111111, 0); check(len == 4, "write after a read: 4");
    cyc(32'h00001008, 0, 32'h22222222, 0); check(len == 5, "write after a write: 5");
    cyc(32'h04000000, 1, 0, 0);  check(len == 5, "a read in the other bank after a write: 5");
    cyc(32'h00001008, 0, 32'h33333333, 0);
    gap_extra = 1; cyc(32'h00001004, 1, 0, 0); gap_extra = 0;
    check(len == 5 && d[0] == 32'h11111111, "a read a clock later than back to back: 5");

    // 4: bursts
    for (i = 0; i < 4; i = i + 1) cyc(32'h00002000 + 4*i, 0, 32'hB0000000 + i, 0);
    gap_extra = 1; cyc(32'h00002008, 1, 0, 1); gap_extra = 0;     // not straight after the writes (+1)
    check(len == 5 && got_cback && nbeat == 4 && beat_at == 32'h00020202, "burst 5-2-2-2");
    check(d[0] == 32'hB0000002 && d[1] == 32'hB0000003 && d[2] == 32'hB0000000 && d[3] == 32'hB0000001, "burst longs in wrap order 2 3 0 1");
    check(last_burst && last_maddr == 25'h000802, "one burst request at the requested long");
    cyc(32'h00002000, 0, 32'h0, 1); check(!got_cback && len == 4, "no CBACK* for a write");
    cyc(32'h40800000, 1, 0, 1);     check(!got_cback && nbeat == 1, "no CBACK* for the ROM");

    // 5: banks
    bank_a = 2'd1; bank_b = 2'd0;
    cyc(32'h00000040, 0, 32'hA1A1A1A1, 0);
    cyc(32'h00300040, 1, 0, 0); check(d[0] == 32'hA1A1A1A1, "a 1 MB bank aliases modulo 1 MB");
    rq0 = reqs; cyc(32'h04000040, 1, 0, 0);
    check(d[0] == 32'hFFFFFFFF && reqs == rq0 && len == 5, "an empty bank B reads all ones, no SDRAM cycle");
    cyc(32'h04000040, 1, 0, 1); check(!got_cback, "no CBACK* for an empty bank");
    bank_a = 2'd3; bank_b = 2'd2;
    cyc(32'h04000080, 0, 32'hB2B2B2B2, 0);
    check(last_maddr == 25'h800020, "bank B at 32 MB in the SDRAM");
    cyc(32'h04400080, 1, 0, 0); check(d[0] == 32'hB2B2B2B2, "a 4 MB bank B aliases modulo 4 MB");
    cyc(32'h08000080, 1, 0, 0); check(last_maddr == 25'h000020, "A27 ignored: $08000080 is bank A");
    cyc(32'h3C000080, 1, 0, 0); check(last_maddr == 25'h800020, "A29-A27 ignored: $3C000080 is bank B");

    // 6: I/O
    for (i = 0; i < 32; i = i + 1) begin
      w = (i == 0 || i == 1 || i == 2 || i == 3 || i == 8 || i == 9 || i == 10 || i == 11 || i == 18 || i == 19);
      cyc(32'h50F00000 + i*32'h2000, 1, 0, 0);
      check(w ? (got_ds == 2'b10 && !got_berr && d[0][31:24] == (i == 1 ? 8'hFF : 8'h5A)) : got_berr,
            w ? "an I/O window acknowledges as an 8-bit port" : "an I/O gap bus-errors");
      if (w && i == 0) check(len >= 7 && len <= 30, "VIA1: E-synchronous");
      if (w && (i == 8 || i == 11 || i == 18 || i == 19)) check(len >= 5 && len <= 8, "one-wait-state ports: one or two C16M clocks");
    end
    cyc(32'h50040000, 1, 0, 0); check(got_ds == 2'b10, "$50040000 repeats $50000000 (VIA1)");
    cyc(32'h50020000, 1, 0, 0); check(got_berr, "$50020000 is a gap: A17 decoded");
    cyc(32'h51000000, 1, 0, 0); check(got_berr, "$51000000: no MDU acknowledge");
    cyc(32'h52000000, 1, 0, 0); check(got_berr, "$52000000 (cache card): bus error with no card");
    cyc(32'h58000000, 1, 0, 0); check(got_berr, "$58000000: bus error");
    drq = 0; cyc(32'h50F06000, 1, 0, 0); drq = 1; check(got_berr, "the handshake port with no DRQ bus-errors");

    // video bursts (THE RBV): bank A waits up to VB = 20 clocks, bank B never
    @(posedge clk); vid_frame = 1; @(posedge clk); vid_frame = 0;
    @(posedge clk); vid_req = 1; repeat (4) @(posedge clk); vid_req = 0;
    gap_extra = 2; cyc(32'h00005000, 1, 0, 0); gap_extra = 0;
    check(len > 5 && len <= 5 + 20 && v_reqs == 1 && v_last == 25'h0, "a bank-A read waits for a video burst; the burst asks for the base");
    vid_req = 1; repeat (4) @(posedge clk); vid_req = 0;
    gap_extra = 2; cyc(32'h04005000, 1, 0, 0); gap_extra = 0;
    check(len == 5 && v_reqs == 2 && v_last == 25'h8, "a bank-B read does not wait; the next burst is 8 longs on");
    repeat (60) @(posedge clk);

    // 7: a late memory delays, never advances
    LAT = 14; x = late;
    cyc(32'h00003000, 1, 0, 0); check(len > 5 && late != x, "a late SDRAM: the termination waits, counted");
    LAT = 4; x = late;
    for (i = 0; i < 20; i = i + 1) cyc(32'h00003000 + 4*i, i & 1, i, i % 3 == 0);
    check(late == x, "LAT 4 (80 ns from the request): never late");

    // 8: refresh, over 200 us of back-to-back reads
    refd = 0; nref = 0; t0 = $realtime;
    for (i = 0; i < 2000; i = i + 1) begin
      cyc(32'h00004000, 1, 0, 0);
      if (len > 5) refd = refd + 1;
      if (len > 5 + 5) nref = nref + 1;
    end
    // one refresh every 244 C16M clocks (15.574 us)
    nexp = ($realtime - t0) / (244.0 * 1000.0 / 15.6672);
    $display("      refresh: %0d of 2000 reads delayed (%0.1f refresh periods), %0d over one refresh", refd, nexp, nref);
    check(refd >= nexp - 1.5 && refd <= nexp + 1.5 && nref == 0, "refresh: one RAM cycle waits each 15.6 us, never more than one refresh");

    // 9: C16M
    c16n = 0; clks = 0;
    @(posedge clk); while (mdu.c16_acc != 0) @(posedge clk);
    repeat (312500) begin @(posedge clk); clks = clks + 1; if (c16_en) c16n = c16n + 1; end
    $display("      c16_en: %0d in %0d clks", c16n, clks);
    check(c16n == 97920, "c16_en = 15.6672 MHz exactly (97920 in 312500 clks of 50 MHz)");

    // 10: interrupts
    irq = 4'b1110; #1 check(ipl_n == 3'b110, "VIA1 level 1");
    irq = 4'b1100; #1 check(ipl_n == 3'b101, "RBV level 2");
    irq = 4'b1000; #1 check(ipl_n == 3'b011, "SCC level 4");
    irq = 4'b0000; #1 check(ipl_n == 3'b000, "NMI level 7");
    irq = 4'hF;

    if (fails == 0) $display("==== PASS: %0d checks - the MDU as the plan's THE MDU", pass);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end
endmodule
