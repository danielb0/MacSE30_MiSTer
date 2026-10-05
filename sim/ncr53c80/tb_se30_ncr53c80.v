// tb_se30_ncr53c80.v - the 53C80 (rtl/se30_ncr53c80.v) against NCR's
// SP-1051 manual (SE30_PLAN.md 9.5-9.6 item 1).  A scripted target drives
// the SCSI bus; the CPU side does register accesses (cs) and DMA accesses
// (dack, a level for the whole access, one strobe in it, as GLUE does).
//
// WHAT THIS PROVES (each check names its section)
//    1. reset: every register clear (9.1)
//    2. read back: ICR's assert bits, the Mode Register, TCR's low four
//       bits with LAST BYTE SENT 0 (6.2-6.4); CSR and Current SCSI Data
//       follow the bus, with odd parity (6.1.1, 6.5)
//    3. drive: ICR's assert bits reach the bus; ASSERT DATA BUS drives the
//       Output Data Register only with I/O false and the phase matching
//       (6.2 bit 0, 8.5); TEST MODE removes every driver (6.2 bit 6)
//    4. arbitration: none while BSY is on the bus; 400 ns of bus free, then
//       AIP with BSY and the ODR on the bus; LA when another device
//       asserts SEL; AIP clears with ARBITRATE (6.2, 6.3 bit 0, 7)
//    5. bus reset: ICR RST asserts RST, interrupts and clears every
//       register but RST and the IRQ latch; released by writing 0; IRQ
//       cleared by reading register 7; a received RST the same (8.3, 9.2,
//       9.3)
//    6. initiator receive: a target already requesting when Start DMA
//       Initiator Receive is written; each byte latched on REQ into the
//       Input Data Register, DRQ and ACK with it, DRQ cleared by DACK, ACK
//       held until DACK has cycled and REQ is false; BSR bit 6 is the DRQ
//       pin (6.1.3, 6.7, 6.8.3, 11.6)
//    7. phase mismatch: a REQ in another phase raises no DRQ and no ACK,
//       interrupts, and PHASE MATCH reads 0 (8.5)
//    8. send: Start DMA Send raises DRQ; a DACK write loads the ODR and
//       drops DRQ; REQ gets ACK with the byte on the bus; REQ false raises
//       DRQ; ACK holds until DACK cycles; resetting DMA MODE releases the
//       last ACK and DRQ (6.8.1, 10.5.2-3, 11.4)
//    9. loss of BSY with MONITOR BUSY: BUSY ERROR, the interrupt, ICR's
//       low bits and DMA MODE cleared (6.3 bit 2, 6.7 bit 2, 8.6)
//   10. selection interrupt through the Select Enable Register (8.1)
//   11. END OF DMA never sets (no /EOP on the SE/30), hardware reset clears
//       the interrupt (6.7 bit 7, 9.1)

`timescale 1ns/1ps

module tb_se30_ncr53c80;

  reg clk = 0;
  always #15.9574 clk = ~clk;           // 31.3344 MHz, the core's clk
  reg reset_n = 0;

  // CPU side
  reg        cs = 0, dack = 0, rd = 0, wr = 0;
  reg  [2:0] rs = 0;
  reg  [7:0] wdata = 0;
  wire [7:0] rdata;
  wire       drq, irq;

  // the target's drive
  reg  [7:0] t_db = 0;
  reg        t_dben = 0, t_bsy = 0, t_sel = 0, t_rst = 0, t_req = 0, t_msg = 0, t_cd = 0, t_io = 0;

  wire [7:0] o_db;
  wire       o_db_en, o_bsy, o_sel, o_rst, o_atn, o_ack;
  wire [7:0] b_db  = (o_db_en ? o_db : 8'h00) | (t_dben ? t_db : 8'h00);
  wire       b_dbp = (o_db_en || t_dben) && ~^b_db;          // driven with the data, else released
  wire       b_bsy = o_bsy | t_bsy, b_sel = o_sel | t_sel, b_rst = o_rst | t_rst;

  se30_ncr53c80 dut (
    .clk(clk), .reset_n(reset_n),
    .cs(cs), .dack(dack), .rd(rd), .wr(wr), .rs(rs), .wdata(wdata), .rdata(rdata), .drq(drq), .irq(irq),
    .b_db(b_db), .b_dbp(b_dbp), .b_bsy(b_bsy), .b_sel(b_sel), .b_rst(b_rst), .b_atn(o_atn), .b_ack(o_ack),
    .b_req(t_req), .b_msg(t_msg), .b_cd(t_cd), .b_io(t_io), .b_sel_other(t_sel),
    .o_db(o_db), .o_db_en(o_db_en), .o_bsy(o_bsy), .o_sel(o_sel), .o_rst(o_rst), .o_atn(o_atn), .o_ack(o_ack));

  integer fails = 0, checks = 0;
  task check(input cond, input [8*96-1:0] what);
    begin checks = checks + 1; if (!cond) begin fails = fails + 1; $display("FAIL %0s (t=%0t)", what, $time); end end
  endtask
  task ticks(input integer n); begin repeat (n) @(negedge clk); end endtask

  // a register access through /CS: cs for 4 clocks, the strobe in the second
  reg [7:0] rv;
  task reg_wr(input [2:0] r, input [7:0] d);
    begin
      @(negedge clk); cs = 1; rs = r; wdata = d;
      @(negedge clk); wr = 1; @(negedge clk); wr = 0;
      @(negedge clk); cs = 0;
    end
  endtask
  task reg_rd(input [2:0] r);
    begin
      @(negedge clk); cs = 1; rs = r;
      @(negedge clk); rv = rdata; rd = 1; @(negedge clk); rd = 0;
      @(negedge clk); cs = 0;
    end
  endtask
  // a DMA access through /DACK, the same shape
  task dma_wr(input [7:0] d);
    begin
      @(negedge clk); dack = 1; wdata = d;
      @(negedge clk); wr = 1; @(negedge clk); wr = 0;
      @(negedge clk); dack = 0;
    end
  endtask
  task dma_rd;
    begin
      @(negedge clk); dack = 1;
      @(negedge clk); rv = rdata; rd = 1; @(negedge clk); rd = 0;
      @(negedge clk); dack = 0;
    end
  endtask
  task wait_drq(input integer limit, output ok);
    integer k;
    begin ok = 0; for (k = 0; k < limit && !ok; k = k + 1) begin @(negedge clk); if (drq) ok = 1; end end
  endtask
  task wait_ack(input v, input integer limit, output ok);
    integer k;
    begin ok = 0; for (k = 0; k < limit && !ok; k = k + 1) begin @(negedge clk); if (o_ack == v) ok = 1; end end
  endtask

  reg ok;
  integer i;
  reg [7:0] got [0:7];
  initial begin
    ticks(3); reset_n = 1; ticks(2);

    // 1. reset
    reg_rd(1); check(rv == 8'h00, "1. ICR clear after reset (9.1)");
    reg_rd(2); check(rv == 8'h00, "1. Mode Register clear");
    reg_rd(3); check(rv == 8'h00, "1. TCR clear");
    reg_rd(5); check(rv == 8'h08, "1. BSR: only PHASE MATCH (bus phase 000 = TCR 000)");
    reg_rd(4); check(rv == 8'h00, "1. CSR on a free bus: $00 - no one drives DBP (6.5, 4.2)");
    check(!irq && !drq, "1. no IRQ, no DRQ");

    // 2. read back
    reg_wr(1, 8'h1F); reg_rd(1); check(rv == 8'h1F, "2. ICR ACK/BSY/SEL/ATN/DATA read back (6.2)");
    check(o_ack && o_bsy && o_sel && o_atn, "3. ICR assert bits reach the bus");
    check(o_db_en, "3. ASSERT DATA BUS drives with I/O false and phase match");
    reg_wr(0, 8'hA5); check(b_db == 8'hA5, "3. the ODR on the bus");
    reg_rd(0); check(rv == 8'hA5, "2. Current SCSI Data reads the bus (6.1.1)");
    reg_rd(4); check(rv[6] && rv[1] && rv[0] == ~^8'hA5, "2. CSR: BSY, SEL, odd parity (6.5)");
    t_io = 1; ticks(1); check(!o_db_en, "3. no data drive with I/O true (6.2 bit 0)");
    t_io = 0; reg_wr(3, 8'h02); ticks(1); check(!o_db_en, "3. no data drive on a phase mismatch (8.5)");
    reg_rd(5); check(rv[3] == 0, "2. PHASE MATCH 0 on a mismatch (6.7)");
    reg_wr(3, 8'h8F); reg_rd(3); check(rv == 8'h0F, "2. TCR low four bits; LAST BYTE SENT reads 0 (6.4)");
    reg_wr(3, 8'h00);
    reg_wr(1, 8'h40); ticks(1); check(!o_db_en && !o_bsy, "3. TEST MODE removes the drivers (6.2 bit 6)");
    reg_rd(1); check(rv[6] == 0, "2. ICR read bit 6 is AIP, not TEST MODE");
    reg_wr(1, 8'h00);
    reg_wr(2, 8'hFE); reg_rd(2); check(rv == 8'hFE, "2. Mode Register reads back (6.3)");
    reg_wr(2, 8'h00);

    // 4. arbitration
    t_bsy = 1; reg_wr(0, 8'h80); reg_wr(2, 8'h01); ticks(40);
    reg_rd(1); check(rv[6] == 0, "4. no arbitration while BSY is on the bus (7)");
    t_bsy = 0; ticks(5); reg_rd(1); check(rv[6] == 0, "4. not before 400 ns of bus free");
    ticks(20); reg_rd(1); check(rv[6] == 1, "4. AIP after the bus-free delay (6.2 bit 6)");
    check(o_bsy && b_db == 8'h80, "4. BSY and the ODR on the bus while arbitrating");
    t_sel = 1; ticks(2); reg_rd(1); check(rv[5] == 1, "4. LA when another device asserts SEL (6.2 bit 5)");
    t_sel = 0; reg_wr(2, 8'h00); reg_rd(1); check(rv[6:5] == 2'b00, "4. AIP and LA clear with ARBITRATE");

    // 5. bus reset, issued
    reg_wr(2, 8'h3C); reg_wr(3, 8'h05); reg_wr(1, 8'h86);
    ticks(2); check(o_rst && irq, "5. ICR RST asserts RST and interrupts (6.2 bit 7, 8.3)");
    reg_rd(1); check(rv == 8'h80, "5. every ICR bit cleared but ASSERT RST (9.3)");
    reg_rd(2); check(rv == 8'h00, "5. Mode Register cleared by the reset");
    reg_rd(3); check(rv == 8'h00, "5. TCR cleared by the reset");
    reg_wr(1, 8'h00); ticks(2); check(!o_rst && irq, "5. RST released by writing 0; IRQ still latched");
    reg_rd(5); check(rv[4] == 1, "5. BSR INTERRUPT REQUEST");
    reg_rd(7); check(!irq, "5. reading register 7 clears IRQ (6.9)");
    // received
    t_rst = 1; ticks(3); check(irq, "5. a received RST interrupts (8.3, 9.2)"); t_rst = 0; ticks(2);
    reg_rd(7); check(!irq, "5. and clears");

    // 6. initiator receive (data in: I/O true)
    t_bsy = 1; t_io = 1; t_dben = 1; t_db = 8'h11; t_req = 1;           // the target already requests
    reg_wr(3, 8'h01);                                                    // TCR = data in
    reg_wr(2, 8'h02);                                                    // DMA MODE
    reg_wr(7, 8'h00);                                                    // Start DMA Initiator Receive
    wait_drq(20, ok); check(ok, "6. DRQ for a REQ already true at Start DMA (11.6 T7)");
    check(o_ack, "6. ACK with it (T9)");
    reg_rd(5); check(rv[6] == 1, "6. BSR bit 6 is the DRQ pin (6.7)");
    t_db = 8'hEE; t_req = 0; ticks(3);                                   // the target drops REQ, changes its data
    check(o_ack, "6. ACK held until DACK has cycled (T8)");
    dma_rd; check(rv == 8'h11, "6. the byte latched on REQ, not the live bus (6.1.3)");
    ticks(2); check(!o_ack, "6. ACK false after DACK and REQ false (T8/T10)");
    for (i = 0; i < 6; i = i + 1) begin
      t_db = 8'h20 + i; t_req = 1;
      wait_drq(20, ok); check(ok, "6. DRQ for each REQ");
      wait_ack(1, 20, ok); t_req = 0;
      dma_rd; got[i] = rv;
      wait_ack(0, 20, ok); check(ok, "6. ACK released for each byte");
    end
    check(got[0] == 8'h20 && got[3] == 8'h23 && got[5] == 8'h25, "6. six bytes in order");
    // DACK clears DRQ at once
    t_db = 8'h55; t_req = 1; wait_drq(20, ok);
    @(negedge clk); dack = 1; @(negedge clk); check(!drq, "6. DACK clears DRQ (4.1, T1)");
    rd = 1; @(negedge clk); rd = 0; @(negedge clk); dack = 0; t_req = 0; ticks(4);

    // 7. phase mismatch: status phase (C/D, I/O) with TCR still data in
    t_cd = 1; t_db = 8'h00; ticks(2); t_req = 1; ticks(4);
    check(!drq && !o_ack, "7. a REQ in another phase: no DRQ, no ACK (8.5)");
    check(irq, "7. the phase mismatch interrupts with DMA MODE set (8.5)");
    reg_rd(5); check(rv[3] == 0, "7. PHASE MATCH 0");
    reg_wr(2, 8'h00); reg_rd(7); t_req = 0; t_cd = 0; t_io = 0; t_dben = 0; ticks(2);

    // 8. send (data out: I/O false)
    reg_wr(3, 8'h00); reg_wr(1, 8'h01);                                  // ASSERT DATA BUS for DMA send (6.3 bit 1)
    reg_wr(2, 8'h02); reg_wr(5, 8'h00);                                  // DMA MODE, Start DMA Send
    ticks(1); check(drq, "8. Start DMA Send raises DRQ for the first byte");
    for (i = 0; i < 4; i = i + 1) begin
      wait_drq(40, ok); check(ok, "8. DRQ for each byte");
      dma_wr(8'hC0 + i);
      ticks(1); check(!drq, "8. the DACK write drops DRQ");
      t_req = 1; wait_ack(1, 20, ok); check(ok, "8. REQ gets ACK (11.4)");
      got[i] = b_db; t_req = 0; ticks(2);
      if (i < 3) check(o_ack, "8. ACK held after REQ false until DACK cycles (10.5.2)");
    end
    check(got[0] == 8'hC0 && got[1] == 8'hC1 && got[3] == 8'hC3, "8. each byte on the bus under ACK");
    wait_drq(20, ok); check(ok && o_ack, "8. after the last byte: DRQ for more, ACK still held");
    reg_wr(2, 8'h00); ticks(1); check(!o_ack && !drq, "8. resetting DMA MODE releases ACK and DRQ (10.5.3)");
    // 8b. the target already requesting as each DACK write lands (the ROM
    // waits for REQ before Start DMA Send): ACK and REQ's fall come while
    // DACK is still active, and DRQ must follow DACK going false (T2)
    reg_wr(2, 8'h02); t_req = 1; reg_wr(5, 8'h00);
    for (i = 0; i < 4; i = i + 1) begin
      wait_drq(40, ok); check(ok, "8b. DRQ for each byte, REQ already true");
      @(negedge clk); dack = 1; wdata = 8'hD0 + i; @(negedge clk); wr = 1; @(negedge clk); wr = 0;
      wait_ack(1, 10, ok); check(ok, "8b. ACK while DACK is still active");
      got[i] = b_db; t_req = 0; ticks(2);
      check(!drq, "8b. no DRQ while DACK is active");
      @(negedge clk); dack = 0; ticks(2);
      check(drq, "8b. DRQ once DACK goes false (T2)");
      check(!o_ack, "8b. ACK released as DACK went false");
      t_req = 1;
    end
    check(got[0] == 8'hD0 && got[3] == 8'hD3, "8b. the bytes under ACK");
    t_req = 0; reg_wr(2, 8'h00); ticks(2);
    reg_wr(1, 8'h00);

    // 9. loss of BSY
    reg_wr(1, 8'h02); reg_wr(2, 8'h06);                                  // ATN, MONITOR BUSY + DMA MODE
    t_bsy = 0; ticks(25);
    check(irq, "9. losing BSY interrupts with MONITOR BUSY (8.6)");
    reg_rd(5); check(rv[2] == 1, "9. BUSY ERROR (6.7 bit 2)");
    reg_rd(1); check(rv[5:0] == 6'b000000, "9. ICR's low bits cleared");
    reg_rd(2); check(rv[1] == 0, "9. DMA MODE reset");
    reg_wr(2, 8'h00); reg_rd(7); check(!irq, "9. cleared by register 7");
    reg_rd(5); check(rv[2] == 0, "9. BUSY ERROR cleared by register 7 (6.9)");

    // 10. selection interrupt
    reg_wr(4, 8'h80); t_dben = 1; t_db = 8'h81; t_sel = 1; ticks(25);
    check(irq, "10. SEL, BSY false and an enabled ID interrupt (8.1)");
    t_sel = 0; t_dben = 0; reg_wr(4, 8'h00); reg_rd(7);

    // 11. END OF DMA never; hardware reset clears IRQ
    reg_rd(5); check(rv[7] == 0, "11. END OF DMA never sets without /EOP");
    t_rst = 1; ticks(2); t_rst = 0; ticks(2); check(irq, "11. (an interrupt pending)");
    reset_n = 0; ticks(2); reset_n = 1; ticks(1); check(!irq, "11. hardware reset clears IRQ (9.1)");

    if (fails == 0) $display("==== PASS: %0d checks, the 53C80 holds to SP-1051", checks);
    else $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end

endmodule
