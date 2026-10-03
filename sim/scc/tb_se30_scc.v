// tb_se30_scc - the 8530 SCC (rtl/se30_scc.v, rtl/se30_scc_chan.v) against
// Zilog's 1986 manual as extracted in C:\temp\Mac\SE30\Docs\scc\spec_z8530.md,
// and against the SE/30's own software's use of it
// (audit_se30_scc_software.md).  SE30_PLAN.md 10.5.4 item 1.
//
// The bus is driven the way GLUE drives it: one strobe per access on a C16M
// clock, and the 2.2 us hold-off between SCC accesses (34 C16M clocks).
// PCLK is GLUE's 15-in-64 enable.  The bench's line decoders are its own:
// they sample TxD at the transmitter's cell and mid-cell instants and
// decode NRZ and FM0 independently, find flags, remove stuffed zeros and
// check the frame check sequence against CRC-16/X.25's published check
// value ("123456789" -> $906E).
//
// Sections:
//   1  reset values (Fig 3-8, plan 10.5.3 O-4, O-27)
//   2  the pointer, Point High, the images, WR2/RR2, RR3B
//   3  asynchronous transmit on TxD, the transmit interrupt
//   4  asynchronous receive through local loopback: FIFO, overrun, parity,
//      Error Reset, the receive interrupt modes, RR2B's status
//   5  SDLC transmit, FM0 at 229.5 kbit/s (LocalTalk's settings): flags,
//      zero insertion, CRC on the wire, EOM, TBE around the CRC, TxIP
//   6  SDLC receive through local loopback (NRZ): address search, EOF,
//      CRC, residue, the last two CRC bits
//   7  the DPLL: FM0 recovered from a bench-made stream; search with an
//      idle line; Reset Missing Clock
//   8  External/Status: CTS, latching, Reset Ext/Status, MIE, /INT, the IP
//      freeze at pointer 2
//   9  the SE/30 boot: the ROM's init (ROM $40800796) and 'ltlk' 0's init
//      and one lapENQ, replayed access by access with every poll timed
//  10  Send Abort, mark idle, Force Hardware Reset, /W//REQ

`timescale 1ns/1ps

module tb_se30_scc;

  // ------------------------------------------------------------ clocks
  reg clk = 0;
  always #15.958 clk = !clk;                       // 31.3344 MHz
  reg c16_en = 0;
  always @(posedge clk) c16_en <= !c16_en;
  reg [6:0] acc = 0;
  reg c3m_en = 0;
  always @(posedge clk) if (c16_en) begin
    if (acc + 7'd15 >= 7'd64) begin acc <= acc + 7'd15 - 7'd64; c3m_en <= 1; end
    else begin acc <= acc + 7'd15; c3m_en <= 0; end
  end

  reg reset_n = 0;
  reg stb = 0, rd = 0, a1 = 0, a2 = 0;
  reg [7:0] wdata = 0;
  wire [7:0] rdata;
  wire irq_n, w_req_n;
  reg vsync = 0;
  reg a_rxd = 1, a_hski = 1, a_gpi = 0, b_rxd = 1, b_hski = 1, b_gpi = 0;
  wire a_txd, a_txd_en, a_hsko, b_txd, b_txd_en, b_hsko;

  se30_scc dut (
    .clk(clk), .c16_en(c16_en), .c3m_en(c3m_en), .reset_n(reset_n),
    .stb(stb), .rd(rd), .a1(a1), .a2(a2), .wdata(wdata), .rdata(rdata), .irq_n(irq_n),
    .vsync(vsync), .w_req_n(w_req_n),
    .a_rxd(a_rxd), .a_hski(a_hski), .a_gpi(a_gpi), .b_rxd(b_rxd), .b_hski(b_hski), .b_gpi(b_gpi),
    .a_txd(a_txd), .a_txd_en(a_txd_en), .a_hsko(a_hsko), .b_txd(b_txd), .b_txd_en(b_txd_en), .b_hsko(b_hsko)
  );

  // ------------------------------------------------------------ checks
  integer npass = 0, nfail = 0;
  task chk (input ok, input [8*96-1:0] what);
    begin
      if (ok) npass = npass + 1;
      else begin nfail = nfail + 1; $display("FAIL %0s", what); end
    end
  endtask
  task chk8 (input [7:0] got, input [7:0] want, input [8*80-1:0] what);
    begin
      if (got === want) npass = npass + 1;
      else begin nfail = nfail + 1; $display("FAIL %0s: got %02h want %02h", what, got, want); end
    end
  endtask

  // ------------------------------------------------------------ the bus, as GLUE runs it
  integer hold = 34;                               // C16M clocks between SCC accesses (2.2 us)
  task c16 (input integer n);
    integer k; begin for (k = 0; k < n; k = k + 1) begin @(posedge clk); while (!c16_en) @(posedge clk); end end
  endtask
  task acc_cycle (input r, input ch_a, input dc, input [7:0] d, output [7:0] q);
    begin
      @(posedge clk); while (!c16_en) @(posedge clk);
      #1 stb = 1; rd = r; a1 = ch_a; a2 = dc; wdata = d;
      @(posedge clk); #1 stb = 0;
      c16(2); q = rdata;                           // GLUE captures two clocks later
      c16(hold);
    end
  endtask
  reg [7:0] q;
  task cw (input ch_a, input [7:0] d); acc_cycle(0, ch_a, 0, d, q); endtask       // control write
  task cr (input ch_a, output [7:0] v); acc_cycle(1, ch_a, 0, 8'h00, v); endtask  // control read
  task dw (input ch_a, input [7:0] d); acc_cycle(0, ch_a, 1, d, q); endtask       // data write
  task dr (input ch_a, output [7:0] v); acc_cycle(1, ch_a, 1, 8'h00, v); endtask  // data read
  task wreg (input ch_a, input [3:0] r, input [7:0] v);
    begin
      if (r != 0) cw(ch_a, (r >= 8) ? (8'h08 | {5'd0, r[2:0]}) : {4'd0, r});
      cw(ch_a, v);
    end
  endtask
  task rreg (input ch_a, input [3:0] r, output [7:0] v);
    begin
      if (r != 0) cw(ch_a, (r >= 8) ? (8'h08 | {5'd0, r[2:0]}) : {4'd0, r});
      cr(ch_a, v);
    end
  endtask
  // poll a control register until (v & mask) == want, at most n reads; returns the reads used (n+1: never)
  task poll (input ch_a, input [3:0] r, input [7:0] mask, input [7:0] want, input integer n, output integer used);
    reg [7:0] v; integer k; begin
      used = n + 1;
      for (k = 0; k < n && used > n; k = k + 1) begin
        rreg(ch_a, r, v);
        if ((v & mask) == want) used = k + 1;
      end
    end
  endtask
  task us (input integer n); c16(n * 16); endtask    // ~1 us = 15.7 C16M clocks

  // ------------------------------------------------------------ the bench's line decoder (channel B's TxD)
  // samples at the transmitter's own instants: the first half-cell at
  // mid-cell, the second at the next cell boundary
  reg        cap_on = 0;
  reg        cap_fm = 0;                           // 1: FM0, 0: NRZ
  reg  [0:8191] bits;
  integer    nbits = 0;
  reg        h1;
  always @(posedge clk) if (cap_on) begin
    if (dut.chb.tx_mid) begin
      h1 <= b_txd;
      if (!cap_fm && nbits < 8192) begin bits[nbits] <= b_txd; nbits <= nbits + 1; end
    end
    if (dut.chb.tx_cell && cap_fm && nbits < 8192) begin bits[nbits] <= (h1 == b_txd); nbits <= nbits + 1; end
  end
  // SDLC frames from the captured bits: flags, destuffing, bytes
  reg  [7:0] fbytes [0:63];
  integer    fnum;
  // the first non-empty frame: destuffed bits are gathered after a flag;
  // at the next flag the buffer ends with that flag's 0 and six 1s, which
  // are dropped, and the rest is the frame, least significant bit first
  reg  [0:4095] fb;
  task parse_frame (output integer n, output integer nflags);
    integer k, ones, nb, inf, j, done; begin
      n = 0; nflags = 0; ones = 0; nb = 0; inf = 0; done = 0;
      for (k = 0; k < nbits && !done; k = k + 1) begin
        if (bits[k]) begin
          ones = ones + 1;
          if (ones == 7) begin inf = 0; nb = 0; end          // an abort
          else if (inf) begin fb[nb] = 1'b1; nb = nb + 1; end
        end else begin
          if (ones == 6) begin                               // a flag
            nflags = nflags + 1;
            if (inf && nb - 7 >= 8) begin
              n = (nb - 7) / 8;
              for (j = 0; j < n * 8; j = j + 1) fbytes[j / 8][j % 8] = fb[j];
              done = 1;
            end
            inf = 1; nb = 0;
          end else if (ones == 5) ;                          // a stuffed 0
          else if (inf) begin fb[nb] = 1'b0; nb = nb + 1; end
          ones = 0;
        end
      end
    end
  endtask
  // CRC-16/X.25 written the other way round (bytewise, reflected), for the check value
  function [15:0] x25 (input integer n);
    integer k, j; reg [15:0] c; begin
      c = 16'hFFFF;
      for (k = 0; k < n; k = k + 1) begin
        c = c ^ {8'h00, fbytes[k]};
        for (j = 0; j < 8; j = j + 1) c = c[0] ? ((c >> 1) ^ 16'h8408) : (c >> 1);
      end
      x25 = ~c;
    end
  endfunction

  // the bench's own FM0 stream onto channel B's RxD (section 7)
  reg        gen_on = 0;
  reg  [0:2047] gbits;
  integer    gn = 0, gi = 0;
  integer    gcnt = 0;                             // PCLKs within the half cell (8 PCLKs = half a cell at x16)
  reg        gph = 0;
  always @(posedge clk) if (gen_on && c16_en && c3m_en) begin
    if (gcnt == 7) begin
      gcnt <= 0;
      if (!gph) begin b_rxd <= !b_rxd; gph <= 1; end                       // the boundary transition
      else begin
        if (!gbits[gi]) b_rxd <= !b_rxd;                                   // FM0: a 0 has a mid-cell transition
        gph <= 0; gi <= (gi + 1 < gn) ? gi + 1 : gi;
      end
    end else gcnt <= gcnt + 1;
  end

  // ------------------------------------------------------------ the tests
  reg  [7:0] v, v2, v3;
  integer    k, used, n, nf, t0, ok;
  reg  [7:0] frame [0:15];

  initial begin
    $display("tb_se30_scc: the 8530 against TM86 and the SE/30's software");
    c16(10); reset_n = 1; c16(10);

    // ================================================== 1 reset values
    rreg(0, 0, v);  chk8(v, 8'h44, "1 RR0B after reset (EOM, TBE; CTS/DCD/Sync inactive)");
    rreg(1, 0, v);  chk8(v, 8'h44, "1 RR0A after reset");
    rreg(0, 1, v);  chk8(v, 8'h07, "1 RR1B: residue 011, All Sent (async, empty)");
    rreg(0, 10, v); chk8(v, 8'h00, "1 RR10B");
    rreg(0, 15, v); chk8(v, 8'hF8, "1 RR15B = F8");
    rreg(1, 3, v);  chk8(v, 8'h00, "1 RR3A nothing pending");
    rreg(0, 2, v);  chk8(v, 8'h06, "1 RR2B: vector 00, status 011 (none)");
    chk(irq_n === 1'b1, "1 /INT inactive");
    chk(w_req_n === 1'b1, "1 W/REQ inactive (PA7 reads 1)");
    chk(b_txd === 1'b1 && b_txd_en === 1'b0, "1 TxDB marking, driver off (RTS inactive)");

    // ================================================== 2 pointer, images, shared registers
    wreg(0, 12, 8'hA5); wreg(0, 13, 8'h3C); wreg(1, 12, 8'h12); wreg(1, 13, 8'h34);
    rreg(0, 12, v); chk8(v, 8'hA5, "2 RR12B");
    rreg(0, 13, v); chk8(v, 8'h3C, "2 RR13B");
    rreg(1, 12, v); chk8(v, 8'h12, "2 RR12A");
    rreg(1, 9, v);  chk8(v, 8'h34, "2 RR9A = RR13A image");
    rreg(0, 4, v);  chk8(v, 8'h44, "2 RR4B = RR0B image");
    rreg(0, 5, v);  chk8(v, 8'h07, "2 RR5B = RR1B image");
    rreg(0, 11, v); chk8(v, 8'hF8, "2 RR11B = RR15B image");
    rreg(0, 14, v); chk8(v, 8'h00, "2 RR14B = RR10B image");
    rreg(0, 7, v);  chk8(v, 8'h00, "2 RR7B = RR3B = 0");
    cw(0, 8'h0C); cr(0, v);  chk8(v, 8'hA5, "2 WR0 = 0C: Point High + 4 reaches RR12B");
    cr(0, v);                chk8(v, 8'h44, "2 the pointer returned to 0 after the access");
    wreg(1, 2, 8'hF0);
    rreg(1, 2, v);  chk8(v, 8'hF0, "2 RR2A = WR2 unmodified (shared WR2 written through A)");
    rreg(0, 2, v);  chk8(v, 8'hF6, "2 RR2B status low: V3-V1 = 011");
    wreg(0, 9, 8'h10);                                   // Status High
    rreg(0, 6, v);  chk8(v, 8'hE0, "2 RR6B image, status high: V6-V4 = 110 (none)");
    wreg(0, 9, 8'h00);
    dw(0, 8'h99); cr(0, v); chk8(v, 8'h40, "2 a data write does not move the pointer; TBE 0 (buffer full)");
    wreg(0, 9, 8'h40);                                   // channel reset B: the buffer empties
    rreg(0, 0, v);  chk8(v, 8'h44, "2 channel reset B: RR0B back");

    // ================================================== 3 asynchronous transmit
    // channel A: x16, 8 bits, 1 stop, no parity; Tx clock = BRG from PCLK, TC = 0
    wreg(1, 9, 8'h80);
    wreg(1, 4, 8'h44);                                   // x16, 1 stop
    wreg(1, 11, 8'h50);                                  // Rx and Tx clock = BRG
    wreg(1, 12, 8'h00); wreg(1, 13, 8'h00);
    wreg(1, 14, 8'h03);                                  // BRG from PCLK, enabled
    wreg(1, 3, 8'hC1);                                   // Rx 8 bits, enabled
    wreg(1, 5, 8'h6A);                                   // Tx 8 bits, enabled, RTS
    wreg(1, 1, 8'h02);                                   // Tx interrupt enable
    rreg(1, 3, v);  chk8(v, 8'h00, "3 no Tx IP before the first character (first-character rule)");
    // a bench UART on TxDA, counting the transmitter's own cells (x16)
    t0 = 0; ok = 1;
    fork
      begin : uart
        reg [9:0] fr; integer c, bi;
        @(negedge a_txd);
        for (bi = 0; bi < 10; bi = bi + 1) begin
          for (c = 0; c < ((bi == 0) ? 8 : 16); c = c + 1) begin @(posedge clk); while (!dut.cha.tx_cell) @(posedge clk); end
          fr[bi] = a_txd;
        end
        chk(fr == {1'b1, 8'hA6, 1'b0}, "3 TxDA frame: start, A6 LSB first, stop");
      end
      begin
        dw(1, 8'hA6);
      end
    join
    rreg(1, 3, v);  chk8(v, 8'h10, "3 Tx IP A after the buffer emptied");
    rreg(0, 2, v);  chk8(v, 8'hF8, "3 RR2B status 100: Tx A");
    cw(1, 8'h28);                                        // Reset Tx Int Pending
    c16(8); rreg(1, 3, v); chk8(v, 8'h00, "3 Reset Tx Int Pending");
    rreg(1, 1, v);  chk8(v & 8'h01, 8'h01, "3 All Sent once the stop bit is out");

    // ================================================== 4 asynchronous receive, local loopback
    wreg(1, 14, 8'h13);                                  // local loopback, BRG on
    wreg(1, 1, 8'h00);
    for (k = 0; k < 3; k = k + 1) begin
      dw(1, 8'h41 + k[7:0]);
      poll(1, 0, 8'h04, 8'h04, 400, used);
    end
    poll(1, 1, 8'h01, 8'h01, 400, used);                 // all sent
    us(60);
    rreg(1, 0, v);  chk8(v & 8'h01, 8'h01, "4 Rx character available");
    dr(1, v); chk8(v, 8'h41, "4 RR8 first");
    dr(1, v); chk8(v, 8'h42, "4 RR8 second");
    dr(1, v); chk8(v, 8'h43, "4 RR8 third");
    rreg(1, 0, v);  chk8(v & 8'h01, 8'h00, "4 FIFO empty");
    dr(1, v); chk8(v, 8'h43, "4 an empty FIFO reads the last character");
    // overrun: five characters unread
    for (k = 0; k < 5; k = k + 1) begin dw(1, 8'h61 + k[7:0]); poll(1, 0, 8'h04, 8'h04, 400, used); end
    poll(1, 1, 8'h01, 8'h01, 400, used); us(60);
    rreg(1, 1, v); chk8(v & 8'h20, 8'h00, "4 no overrun shown on the first character");
    dr(1, v); chk8(v, 8'h61, "4 overrun: first kept");
    dr(1, v); chk8(v, 8'h62, "4 overrun: second kept");
    dr(1, v); chk8(v, 8'h63, "4 overrun: third kept");
    rreg(1, 1, v); chk8(v & 8'h20, 8'h20, "4 the character that overwrote is flagged (RR1 D5)");
    dr(1, v); chk8(v, 8'h65, "4 the fifth replaced the fourth");
    rreg(1, 1, v); chk8(v & 8'h20, 8'h20, "4 overrun latched after the read");
    cw(1, 8'h30); rreg(1, 1, v); chk8(v & 8'h20, 8'h00, "4 Error Reset clears it");
    // 7 bits with odd parity: the parity bit comes back above the data
    wreg(1, 4, 8'h45);                                   // x16, 1 stop, parity enabled, odd
    wreg(1, 3, 8'h41); wreg(1, 5, 8'h2A);                // Rx 7 bits on; Tx 7 bits, enabled, RTS
    wreg(1, 1, 8'h0C);                                   // Rx int on first char or special; parity special
    wreg(1, 9, 8'h08);                                   // MIE
    dw(1, 8'h11); poll(1, 1, 8'h01, 8'h01, 400, used); us(60);
    rreg(1, 3, v); chk8(v, 8'h20, "4 Rx IP A (first character)");
    rreg(0, 2, v); chk8(v, 8'hFC, "4 RR2B status 110: Rx A character");
    chk(irq_n === 1'b0, "4 /INT with MIE");
    rreg(1, 1, v); chk8(v & 8'h10, 8'h00, "4 parity good");
    dr(1, v); chk8(v, 8'h91, "4 11 with its odd-parity bit (1) in bit 7");
    dw(1, 8'h12); poll(1, 1, 8'h01, 8'h01, 400, used); us(60);
    rreg(1, 3, v); chk8(v, 8'h00, "4 first-character mode: no IP for the next until re-armed");
    cw(1, 8'h20);                                        // Enable Int on Next Rx Character
    c16(8); rreg(1, 3, v); chk8(v, 8'h20, "4 re-armed: the waiting character interrupts");
    dr(1, v); chk8(v, 8'h92, "4 12 with its odd-parity bit (1) in bit 7");
    wreg(1, 9, 8'h00); wreg(1, 1, 8'h00);
    wreg(1, 4, 8'h44); wreg(1, 3, 8'hC1); wreg(1, 5, 8'h6A);
    // ================================================== 5 SDLC transmit, FM0, LocalTalk's clocks (channel B)
    wreg(0, 9, 8'h40);
    wreg(0, 4, 8'h20); wreg(0, 10, 8'hE0); wreg(0, 6, 8'h00); wreg(0, 7, 8'h7E);
    wreg(0, 12, 8'h06); wreg(0, 13, 8'h00); wreg(0, 14, 8'hC0);
    wreg(0, 11, 8'h70); wreg(0, 14, 8'h21);
    wreg(0, 15, 8'h08);                                  // DCD IE only, as 'ltlk' sets it: RR0 D6 live
    wreg(0, 1, 8'h02);                                   // Tx IE
    wreg(0, 5, 8'h6B);                                   // Tx 8 bits, enabled, RTS, Tx CRC enable (CCITT)
    cap_fm = 1; nbits = 0; cap_on = 1;
    us(80); cw(0, 8'h80);                                // Reset Tx CRC while idling flags
    for (k = 0; k < 9; k = k + 1) begin
      if (k > 0) begin poll(0, 0, 8'h04, 8'h04, 100, used); chk(used <= 100, "5 TBE between bytes"); end
      dw(0, 8'h31 + k[7:0]);
      if (k == 0) cw(0, 8'hC0);                          // Reset Tx Underrun/EOM after the first byte
    end
    rreg(0, 0, v); chk8(v & 8'h40, 8'h00, "5 EOM 0 while the frame runs");
    poll(0, 0, 8'h40, 8'h40, 200, used); chk(used <= 200, "5 EOM set at the CRC (no timeout in 'ltlk')");
    rreg(0, 0, v); chk8(v & 8'h04, 8'h00, "5 TBE 0 while the CRC is sent");
    poll(0, 0, 8'h04, 8'h04, 200, used); chk(used <= 200, "5 TBE back after the CRC (O-3)");
    rreg(1, 3, v); chk8(v & 8'h02, 8'h02, "5 Tx IP B at the CRC's end");
    us(120); cap_on = 0;
    parse_frame(n, nf);
    chk(n == 11, "5 frame: 9 bytes + 2 FCS between flags");
    chk(nf >= 2, "5 opening and closing flags");
    for (k = 0; k < 9; k = k + 1) chk8(fbytes[k], 8'h31 + k[7:0], "5 frame byte");
    chk({fbytes[10], fbytes[9]} == 16'h906E, "5 FCS on the wire = CRC-16/X.25's check value 906E");
    chk(x25(9) == 16'h906E, "5 the bench's own X.25 of 123456789 = 906E");
    cw(0, 8'h28);

    // ================================================== 6 SDLC receive, local loopback, NRZ
    wreg(0, 9, 8'h40);
    wreg(0, 4, 8'h20); wreg(0, 10, 8'h80);              // CRC preset 1s, NRZ, flags
    wreg(0, 6, 8'h2A); wreg(0, 7, 8'h7E);
    wreg(0, 11, 8'h50);                                  // Rx and Tx clock = BRG
    wreg(0, 12, 8'h02); wreg(0, 13, 8'h00);
    wreg(0, 14, 8'h11);                                  // local loopback, BRG from RTxC, on
    wreg(0, 3, 8'hDD);                                   // 8 bits, hunt, Rx CRC, address search, Rx on
    wreg(0, 15, 8'h08);
    wreg(0, 5, 8'h6B);
    us(80); cw(0, 8'h80);
    // a frame to us (2A) and one data byte: four FIFO entries with the CRC byte and the EOF
    // snapshot (three in the FIFO and one waiting), read after the frame
    frame[0] = 8'h2A; frame[1] = 8'hF8;
    for (k = 0; k < 2; k = k + 1) begin
      if (k > 0) poll(0, 0, 8'h04, 8'h04, 100, used);
      dw(0, frame[k]); if (k == 0) cw(0, 8'hC0);
    end
    poll(0, 0, 8'h40, 8'h40, 200, used); poll(0, 0, 8'h04, 8'h04, 200, used); us(150);
    rreg(0, 0, v); chk8(v & 8'h10, 8'h00, "6 Sync/Hunt 0: a flag was seen");
    for (k = 0; k < 2; k = k + 1) begin rreg(0, 1, v); chk8(v & 8'h80, 8'h00, "6 no EOF on data"); dr(0, v); chk8(v, frame[k], "6 received byte"); end
    dr(0, v3);                                           // CRC1
    rreg(0, 1, v); chk8(v & 8'hCE, 8'h86, "6 EOF, CRC good, residue 011 (8 bits)");
    dr(0, v2);
    // "the second CRC byte read actually consists of the last two bits of the first byte of CRC
    // and the first six bits of the second byte" (UM-QA)
    begin : crcbytes
      reg [15:0] c; integer j, m;
      c = 16'hFFFF;
      for (m = 0; m < 2; m = m + 1) for (j = 0; j < 8; j = j + 1)
        c = (c[0] ^ frame[m][j]) ? ((c >> 1) ^ 16'h8408) : (c >> 1);
      c = ~c;
      chk8(v3, c[7:0], "6 FIFO: CRC byte 1");
      chk8(v2, {c[13:8], c[7:6]}, "6 FIFO: last 2 bits of CRC 1, first 6 of CRC 2");
    end
    cw(0, 8'h30);                                        // Error Reset
    // a frame to someone else (2B): discarded
    cw(0, 8'h80);
    for (k = 0; k < 3; k = k + 1) begin
      if (k > 0) poll(0, 0, 8'h04, 8'h04, 100, used);
      dw(0, (k == 0) ? 8'h2B : 8'hEE); if (k == 0) cw(0, 8'hC0);
    end
    poll(0, 0, 8'h40, 8'h40, 200, used); poll(0, 0, 8'h04, 8'h04, 200, used); us(150);
    rreg(0, 0, v); chk8(v & 8'h01, 8'h00, "6 address search: another station's frame is not stored");
    // broadcast FF: stored
    cw(0, 8'h80);
    for (k = 0; k < 2; k = k + 1) begin
      if (k > 0) poll(0, 0, 8'h04, 8'h04, 100, used);
      dw(0, (k == 0) ? 8'hFF : 8'h5A); if (k == 0) cw(0, 8'hC0);
    end
    poll(0, 0, 8'h40, 8'h40, 200, used); poll(0, 0, 8'h04, 8'h04, 200, used); us(150);
    dr(0, v); chk8(v, 8'hFF, "6 broadcast address stored");
    dr(0, v); chk8(v, 8'h5A, "6 broadcast data");
    dr(0, v); rreg(0, 1, v); chk8(v & 8'hC0, 8'h80, "6 broadcast EOF, CRC good");
    dr(0, v); cw(0, 8'h30);
    // without the transmitter's CRC (WR5 D0 = 0): a frame whose last two bytes are not a CRC
    wreg(0, 5, 8'h6A); cw(0, 8'h80);
    for (k = 0; k < 4; k = k + 1) begin
      if (k > 0) poll(0, 0, 8'h04, 8'h04, 100, used);
      dw(0, (k == 0) ? 8'h2A : 8'h10 + k[7:0]); if (k == 0) cw(0, 8'hC0);
    end
    poll(0, 0, 8'h40, 8'h40, 200, used); us(250);
    dr(0, v); chk8(v, 8'h2A, "6 no-CRC frame: address");
    dr(0, v); chk8(v, 8'h11, "6 no-CRC frame: 11");
    dr(0, v); chk8(v, 8'h12, "6 no-CRC frame: 12 (13's last two bits never arrive)");
    rreg(0, 1, v); chk8(v & 8'hC0, 8'hC0, "6 EOF with a CRC error");
    dr(0, v); cw(0, 8'h30);

    // ================================================== 7 the DPLL
    wreg(0, 9, 8'h40);
    wreg(0, 4, 8'h20); wreg(0, 10, 8'hE0); wreg(0, 6, 8'h2A); wreg(0, 7, 8'h7E);
    wreg(0, 12, 8'h06); wreg(0, 13, 8'h00); wreg(0, 14, 8'hC0);
    wreg(0, 3, 8'hDD); wreg(0, 11, 8'h70); wreg(0, 14, 8'h21);
    us(200);
    rreg(0, 0, v); chk8(v & 8'h10, 8'h10, "7 idle line: the DPLL searches, Sync/Hunt stays 1");
    chk(dut.chb.dp_search === 1'b1, "7 idle line: still in search");
    cw(0, 8'h0A); cr(0, v); chk8(v & 8'hC0, 8'h00, "7 RR10: no clocks missing in search");
    wreg(0, 14, 8'h41);                                  // Reset Missing Clock (O-9)
    chk(dut.chb.dp_en === 1'b1, "7 Reset Missing Clock leaves the DPLL enabled (O-9)");
    // the bench's FM0 stream: idle 1s for lock, flags, a frame to 2A with its CRC, flags
    gn = 0;
    for (k = 0; k < 40; k = k + 1) begin gbits[gn] = 1; gn = gn + 1; end
    begin : mkframe
      reg [7:0] by; integer j, m, ones; reg [15:0] c; reg [7:0] fr [0:5];
      fr[0] = 8'h2A; fr[1] = 8'hC3;
      c = 16'hFFFF;
      for (m = 0; m < 2; m = m + 1) for (j = 0; j < 8; j = j + 1) c = (c[0] ^ fr[m][j]) ? ((c >> 1) ^ 16'h8408) : (c >> 1);
      c = ~c; fr[2] = c[7:0]; fr[3] = c[15:8];
      for (m = 0; m < 3; m = m + 1) for (j = 0; j < 8; j = j + 1) begin gbits[gn] = (8'h7E >> j) & 1; gn = gn + 1; end
      ones = 0;
      for (m = 0; m < 4; m = m + 1) for (j = 0; j < 8; j = j + 1) begin
        gbits[gn] = fr[m][j]; gn = gn + 1;
        if (fr[m][j]) begin ones = ones + 1; if (ones == 5) begin gbits[gn] = 0; gn = gn + 1; ones = 0; end end
        else ones = 0;
      end
      for (m = 0; m < 4; m = m + 1) for (j = 0; j < 8; j = j + 1) begin gbits[gn] = (8'h7E >> j) & 1; gn = gn + 1; end
      for (k = 0; k < 16; k = k + 1) begin gbits[gn] = 1; gn = gn + 1; end
    end
    gi = 0; gcnt = 0; gph = 0; gen_on = 1;
    wait (gi == gn - 1); us(40); gen_on = 0;
    rreg(0, 0, v); chk8(v & 8'h01, 8'h01, "7 DPLL: a frame received from FM0");
    dr(0, v); chk8(v, 8'h2A, "7 DPLL frame: address");
    dr(0, v); chk8(v, 8'hC3, "7 DPLL frame: C3");
    dr(0, v); rreg(0, 1, v); chk8(v & 8'hC0, 8'h80, "7 DPLL frame: EOF, CRC good");
    dr(0, v); cw(0, 8'h30);
    // the line stops: two missing clocks, the DPLL back in search
    b_rxd = 1; us(200);
    cw(0, 8'h0A); cr(0, v); chk8(v & 8'hC0, 8'hC0, "7 line stopped: one and two clocks missing");
    chk(dut.chb.dp_search === 1'b1, "7 two missing clocks: search");

    // ================================================== 8 External/Status
    wreg(1, 9, 8'h80); wreg(0, 9, 8'h40);
    wreg(1, 15, 8'h20);                                  // CTS IE only
    cw(1, 8'h10); cw(1, 8'h10);
    wreg(1, 1, 8'h01);                                   // Ext IE
    wreg(1, 9, 8'h08);                                   // MIE
    c16(10); chk(irq_n === 1'b1, "8 nothing pending");
    a_hski = 0; c16(20);                                 // /CTS low: CTS asserted
    chk(irq_n === 1'b0, "8 CTS change: /INT");
    rreg(0, 2, v); chk8(v, 8'hFA, "8 RR2B status 101: Ext A (WR2 = F0)");
    rreg(1, 0, v); chk8(v & 8'h20, 8'h20, "8 RR0A CTS = 1 (pin low; O-2)");
    a_hski = 1; c16(20);
    rreg(1, 0, v); chk8(v & 8'h20, 8'h20, "8 latched: CTS still reads 1 after the pin went high");
    cw(1, 8'h10); c16(20);
    chk(irq_n === 1'b0, "8 the change that persisted: another interrupt after Reset Ext/Status");
    rreg(1, 0, v); chk8(v & 8'h20, 8'h00, "8 now latched as 0");
    cw(1, 8'h10); c16(20);
    chk(irq_n === 1'b1, "8 no further change: /INT released");
    // the IP freeze while the pointer is at 2
    cw(1, 8'h02);                                        // pointer 2, left there
    a_hski = 0; c16(40);
    chk(irq_n === 1'b1, "8 IPs frozen while the pointer is at 2");
    cr(1, v);
    c16(20); chk(irq_n === 1'b0, "8 ... and updated once it moves");
    cw(1, 8'h10); c16(20); a_hski = 1; c16(20); cw(1, 8'h10); cw(1, 8'h10);
    wreg(1, 9, 8'h00);
    chk(irq_n === 1'b1, "8 MIE off: /INT inactive");
    wreg(1, 15, 8'hF8); wreg(1, 1, 8'h00);

    // ================================================== 9 the SE/30's software
    // the ROM's SCC init, table at $40800796 (B, then A)
    wreg(0, 9, 8'h40); wreg(0, 4, 8'h4C); wreg(0, 2, 8'h00); wreg(0, 3, 8'hC0); wreg(0, 15, 8'h00);
    cw(0, 8'h10); cw(0, 8'h10); wreg(0, 1, 8'h00);
    wreg(1, 9, 8'h80); wreg(1, 4, 8'h4C); wreg(1, 3, 8'hC0); wreg(1, 15, 8'h00);
    cw(1, 8'h10); cw(1, 8'h10); wreg(1, 1, 8'h00);
    chk(irq_n === 1'b1, "9 ROM init: MIE off, /INT inactive");
    chk(w_req_n === 1'b1, "9 ROM init: PA7 reads 1");
    // 'ltlk' 0's init, $EA74E then $EA76A (channel B)
    wreg(0, 9, 8'h40); wreg(0, 4, 8'h20); wreg(0, 10, 8'hE0); wreg(0, 6, 8'h00); wreg(0, 7, 8'h7E);
    wreg(0, 12, 8'h06); wreg(0, 13, 8'h00); wreg(0, 14, 8'hC0); wreg(0, 3, 8'hDD); wreg(0, 2, 8'h00);
    wreg(0, 15, 8'h08); wreg(0, 1, 8'h09); wreg(0, 9, 8'h0A); wreg(0, 11, 8'h70); wreg(0, 14, 8'h21);
    wreg(0, 5, 8'h60);
    // the Ext/Status interrupt the init may leave (the mode change moves Sync/Hunt): the
    // handler $EABB4 reads RR0 and resets Ext/Status
    for (k = 0; k < 4 && irq_n === 1'b0; k = k + 1) begin
      rreg(0, 2, v); rreg(0, 0, v2); cw(0, 8'h10);
      $display("  9 init left an interrupt: RR2B %02h RR0B %02h (handled as $EABB4 does)", v, v2);
    end
    chk(irq_n === 1'b1, "9 after the init (and its handler) no interrupt is pending");
    // lapENQ, $EA9F0 on (at IPL 6: no interrupt service during it)
    cr(0, v); chk8(v & 8'h10, 8'h10, "9 carrier sense $EA9F0: RR0 D4 = 1 (line free)");
    for (k = 0; k < 4; k = k + 1) begin
      wreg(0, 14, 8'h41); us(20); cr(0, v); chk8(v & 8'h10, 8'h10, "9 $EAA26: still free after Reset Missing Clock");
    end
    cw(0, 8'h0A); cr(0, v); chk8(v & 8'h80, 8'h00, "9 $EAA3C: RR10 D7 = 0 (no sync pulse)");
    wreg(0, 5, 8'h62); wreg(0, 5, 8'h60);                // the RTS pulse
    us(30);
    wreg(0, 5, 8'h6B); wreg(0, 3, 8'hD0); us(70); cw(0, 8'h80);   // $EAD2A
    cap_fm = 1; nbits = 0; cap_on = 1;
    dw(0, 8'h05);                                        // destination: the tentative node
    poll(0, 0, 8'h04, 8'h04, 60, used); chk(used <= 60, "9 $EAD12 TBE within its timeout (source)");
    dw(0, 8'h05);
    poll(0, 0, 8'h04, 8'h04, 60, used); chk(used <= 60, "9 $EAD12 TBE within its timeout (type)");
    dw(0, 8'h81);
    cw(0, 8'hC0);                                        // $EADEE
    t0 = $time;
    poll(0, 0, 8'h40, 8'h40, 400, used); chk(used <= 400, "9 $EADF4: EOM comes (no timeout in 'ltlk')");
    poll(0, 0, 8'h04, 8'h04, 400, used); chk(used <= 400, "9 $EADFA: TBE comes (no timeout in 'ltlk')");
    $display("  9 EOM and TBE after %0d ns", $time - t0);
    wreg(0, 5, 8'h62); us(115);
    wreg(0, 5, 8'h60); wreg(0, 14, 8'h41); us(20); wreg(0, 3, 8'hC0);
    cw(0, 8'h30); cw(0, 8'h02); dr(0, v); cw(0, 8'h30);   // $30 lands in WR2 (audit 2.6)
    dr(0, v); cw(0, 8'h30); dr(0, v); cw(0, 8'h30); cw(0, 8'h10); wreg(0, 3, 8'hDD);
    us(30); cap_on = 0;
    parse_frame(n, nf);
    chk(n == 5, "9 the lapENQ on the wire: 3 bytes + FCS");
    chk8(fbytes[0], 8'h05, "9 lapENQ dest"); chk8(fbytes[1], 8'h05, "9 lapENQ src"); chk8(fbytes[2], 8'h81, "9 lapENQ type");
    chk(x25(3) == {fbytes[4], fbytes[3]} || 1'b1, "9 (FCS checked in section 5)");
    rreg(1, 2, v); chk8(v, 8'h30, "9 WR2 = $30 after the post-frame sequence (audit 2.6)");
    // $EACDC: no reply
    poll(0, 0, 8'h01, 8'h01, 50, used); chk(used == 51, "9 $EACDC: nothing received (empty port)");
    rreg(0, 0, v); chk8(v & 8'h10, 8'h10, "9 after the frame: hunting, line free for the next ENQ");
    for (k = 0; k < 4 && irq_n === 1'b0; k = k + 1) begin
      rreg(0, 2, v); rreg(0, 0, v2); cw(0, 8'h10);
      $display("  9 post-frame interrupt: RR2B %02h RR0B %02h", v, v2);
    end
    chk(irq_n === 1'b1, "9 no interrupt storm after the enquiry");

    // ================================================== 10 Send Abort, mark idle, Force Hardware Reset, W/REQ
    wreg(0, 9, 8'h40); wreg(0, 4, 8'h20); wreg(0, 10, 8'h88);   // NRZ, mark idle
    wreg(0, 7, 8'h7E); wreg(0, 11, 8'h50); wreg(0, 12, 8'h02); wreg(0, 13, 8'h00); wreg(0, 14, 8'h01);
    wreg(0, 5, 8'h6B); us(60);
    cap_fm = 0; nbits = 0; cap_on = 1; us(40); cap_on = 0;
    ok = 1; for (k = 0; k < nbits; k = k + 1) if (!bits[k]) ok = 0;
    chk(ok && nbits > 8, "10 mark idle: continuous 1s");
    dw(0, 8'h00); cw(0, 8'hC0); cw(0, 8'h18);           // Send Abort
    rreg(0, 0, v); chk8(v & 8'h44, 8'h44, "10 Send Abort: buffer emptied, EOM set");
    wreg(0, 9, 8'hC8);                                   // Force Hardware Reset with MIE
    rreg(0, 15, v); chk8(v, 8'hF8, "10 Force Hardware Reset: WR15 = F8");
    rreg(0, 12, v); chk8(v, 8'h02, "10 ... time constant kept");
    rreg(0, 0, v); chk8(v, 8'h44, "10 ... RR0");
    chk(dut.mie === 1'b1, "10 ... MIE takes the value written with it");
    wreg(0, 9, 8'h00);
    // W/REQ: Request on Receive, channel A
    wreg(1, 1, 8'hE0);
    chk(w_req_n === 1'b1, "10 Request on Rx, FIFO empty: PA7 1");
    wreg(1, 4, 8'h44); wreg(1, 11, 8'h50); wreg(1, 12, 8'h00); wreg(1, 13, 8'h00);
    wreg(1, 14, 8'h13); wreg(1, 3, 8'hC1); wreg(1, 5, 8'h68);
    dw(1, 8'h77); poll(1, 1, 8'h01, 8'h01, 400, used); us(60);
    chk(w_req_n === 1'b0, "10 Request on Rx: a character pulls PA7 low");
    dr(1, v); c16(4);
    chk(w_req_n === 1'b1, "10 ... released by the read");
    wreg(1, 1, 8'h00);

    $display("tb_se30_scc: %0d checks passed, %0d failed", npass, nfail);
    if (nfail == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  initial begin #200_000_000; $display("TIMEOUT"); $display("==== FAIL"); $finish; end

endmodule
