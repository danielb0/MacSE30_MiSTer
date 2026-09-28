// tb_se30_pic1654.v - the PIC1654S core held to its data sheet (Microchip
// DS33013A, 1990) and General Instrument's 1983 PIC Series Microcomputer
// Data Manual, item by item of SE30_PLAN.md 6.9 items 1-4 (the CPU alone;
// no firmware).  Where the two differ the data sheet wins: the PIC1654S
// has no OV bit, and port A's high bits read 0.
//
// WHAT THIS PROVES
//   rtl/se30_pic1654.v executes the PIC1650-family instruction set as the
//   manual's chapter 3 and the data sheet's summary (pp. 4-41, 4-42)
//   define it, at the data sheet's cycle counts, with its register file
//   (p. 4-40) and I/O lines (p. 4-44):
//
//     1. every instruction of the p. 48 table: result, destination (W or
//        f), the status bits it sets and the ones it must leave alone -
//        the manual's own worked examples where it gives one (ADDWF
//        242+117, SUBWF 104-50 and 50-104, RLF 65, COMF 166, INCF 127);
//        status bits 7-3 "defined as logic ones" (no OV)     ch. 3, p. 4-40
//     2. cycle counts: one machine cycle each, two for GOTO, CALL, RETLW,
//        a write to F2 and a taken skip ("ADDWF PC ... Two Cycles"), and a
//        machine cycle of eight OSC1 periods                p. 47, 6.3.1
//     3. the file's corners: the FSR's three high bits read 111, indirect
//        addressing through F0, F2 read = the next instruction's address,
//        F2 as a destination clearing PC bit 8, CALL's 8-bit target, the
//        two-level stack, the RTCC counting falling edges on its pin and
//        wrapping without carry                 2.1.2-2.1.4, 2.1.8, p. 64
//     4. the ports: a read returns the pin; a latched 0 pulls the pin low;
//        a latched 1 lets an external 0 through; a read-modify-write reads
//        the pins (p. 4-42 note 2); port A's high bits read 0 (p. 4-40);
//        MCLR sets every latch high and the PC to 777 octal     p. 4-39
//
// THE PROGRAM MEMORY
//   A 512 x 12 array read synchronously, as the core's BRAM will be: the
//   word at pm_addr appears one clk later.  Programs are hand-assembled by
//   the functions below from the p. 48 binary table.  Addresses are
//   decimal here; the manual writes octal.
//
// THE CLOCK
//   osc_en is one clk in four: one OSC1 period.  A machine cycle is eight
//   of them (6.3.1).  The bench counts osc_en pulses between events.

`timescale 1ns/1ps

module tb_se30_pic1654;

  reg clk = 0;
  always #5 clk = ~clk;
  reg [1:0] div = 0;
  always @(posedge clk) div <= div + 1'b1;
  wire osc_en = (div == 2'd3);

  reg mclr_n = 0;

  // ------------------------------------------------ program memory
  reg  [11:0] pm [0:511];
  wire  [8:0] pm_addr;
  reg  [11:0] pm_q;
  always @(posedge clk) pm_q <= pm[pm_addr];

  // ------------------------------------------------ the pins
  wire [3:0] ra_latch;
  wire [7:0] rb_latch;
  reg  [3:0] ra_ext = 4'hF;              // 0 = something outside pulls the line low
  reg  [7:0] rb_ext = 8'hFF;
  wire [3:0] ra_pin = ra_latch & ra_ext; // Figure 7: pull-up, latch pull-down, wired-AND
  wire [7:0] rb_pin = rb_latch & rb_ext;
  reg        rtcc_pin = 1;
  wire [63:0] dbg;

  se30_pic1654 dut (
    .clk(clk), .osc_en(osc_en), .mclr_n(mclr_n),
    .pm_addr(pm_addr), .pm_data(pm_q),
    .ra_latch(ra_latch), .ra_pin(ra_pin), .rb_latch(rb_latch), .rb_pin(rb_pin),
    .rtcc_pin(rtcc_pin), .dbg(dbg));

  // dbg: {pc[8:0], w[7:0], status[7:0], fsr_read[7:0], rtcc[7:0], stk0[8:0], stk1[8:0], cycles[6:0]}
  wire [8:0] pc     = dbg[63:55];
  wire [7:0] w      = dbg[54:47];
  wire [7:0] status = dbg[46:39];
  wire [7:0] fsr_rd = dbg[38:31];
  wire [7:0] rtcc   = dbg[30:23];

  // ------------------------------------------------ scoring
  integer checks = 0, fails = 0;
  task check(input cond, input [8*72-1:0] what, input integer got, input integer want);
    begin
      checks = checks + 1;
      if (cond) $display("pass %0s: %0h", what, got);
      else begin fails = fails + 1; $display("FAIL %0s: got %0h, want %0h", what, got, want); end
    end
  endtask
  task is(input [8*72-1:0] what, input integer got, input integer want);
    begin check(got == want, what, got, want); end
  endtask

  // ------------------------------------------------ the assembler (p. 48)
  function [11:0] NOP;                           input dummy; NOP = 12'o0000; endfunction
  function [11:0] MOVWF(input [4:0] f);          MOVWF  = 12'o0040 | f; endfunction
  function [11:0] CLRW;                          input dummy; CLRW = 12'o0100; endfunction
  function [11:0] CLRF(input [4:0] f);           CLRF   = 12'o0140 | f; endfunction
  function [11:0] BYTE(input [3:0] op, input [4:0] f, input d); BYTE = {2'b00, op, d, f}; endfunction
  function [11:0] SUBWF(input [4:0] f, input d); SUBWF  = BYTE(4'b0010, f, d); endfunction
  function [11:0] DECF(input [4:0] f, input d);  DECF   = BYTE(4'b0011, f, d); endfunction
  function [11:0] IORWF(input [4:0] f, input d); IORWF  = BYTE(4'b0100, f, d); endfunction
  function [11:0] ANDWF(input [4:0] f, input d); ANDWF  = BYTE(4'b0101, f, d); endfunction
  function [11:0] XORWF(input [4:0] f, input d); XORWF  = BYTE(4'b0110, f, d); endfunction
  function [11:0] ADDWF(input [4:0] f, input d); ADDWF  = BYTE(4'b0111, f, d); endfunction
  function [11:0] MOVF(input [4:0] f, input d);  MOVF   = BYTE(4'b1000, f, d); endfunction
  function [11:0] COMF(input [4:0] f, input d);  COMF   = BYTE(4'b1001, f, d); endfunction
  function [11:0] INCF(input [4:0] f, input d);  INCF   = BYTE(4'b1010, f, d); endfunction
  function [11:0] DECFSZ(input [4:0] f, input d); DECFSZ = BYTE(4'b1011, f, d); endfunction
  function [11:0] RRF(input [4:0] f, input d);   RRF    = BYTE(4'b1100, f, d); endfunction
  function [11:0] RLF(input [4:0] f, input d);   RLF    = BYTE(4'b1101, f, d); endfunction
  function [11:0] SWAPF(input [4:0] f, input d); SWAPF  = BYTE(4'b1110, f, d); endfunction
  function [11:0] INCFSZ(input [4:0] f, input d); INCFSZ = BYTE(4'b1111, f, d); endfunction
  function [11:0] BCF(input [4:0] f, input [2:0] b);   BCF   = {4'b0100, b, f}; endfunction
  function [11:0] BSF(input [4:0] f, input [2:0] b);   BSF   = {4'b0101, b, f}; endfunction
  function [11:0] BTFSC(input [4:0] f, input [2:0] b); BTFSC = {4'b0110, b, f}; endfunction
  function [11:0] BTFSS(input [4:0] f, input [2:0] b); BTFSS = {4'b0111, b, f}; endfunction
  function [11:0] RETLW(input [7:0] k); RETLW = {4'b1000, k}; endfunction
  function [11:0] CALL(input [7:0] k);  CALL  = {4'b1001, k}; endfunction
  function [11:0] GOTO(input [8:0] k);  GOTO  = {3'b101, k};  endfunction
  function [11:0] MOVLW(input [7:0] k); MOVLW = {4'b1100, k}; endfunction
  function [11:0] IORLW(input [7:0] k); IORLW = {4'b1101, k}; endfunction
  function [11:0] ANDLW(input [7:0] k); ANDLW = {4'b1110, k}; endfunction
  function [11:0] XORLW(input [7:0] k); XORLW = {4'b1111, k}; endfunction

  localparam F_IND = 5'd0, F_RTCC = 5'd1, F_PC = 5'd2, F_ST = 5'd3, F_FSR = 5'd4,
             F_A = 5'd5, F_B = 5'd6, R10 = 5'd10, R11 = 5'd11, R12 = 5'd12, R20 = 5'd20;
  localparam W_ = 1'b0, F_ = 1'b1;
  localparam C = 0, DC = 1, Z = 2;

  // ------------------------------------------------ running programs
  integer a;                                   // the assembly pointer
  task org(input integer at); begin a = at; end endtask
  task emit(input [11:0] word); begin pm[a] = word; a = a + 1; end endtask

  // a "halt" is GOTO self; the program ends there
  reg [8:0] hpc;                               // where the last program halts
  task halt; begin hpc = a; emit(GOTO(a[8:0])); end endtask
  // clear the program memory, keeping the reset vector's GOTO 0
  task clear_pm; begin for (i = 0; i < 512; i = i + 1) pm[i] = 12'o0000; pm[511] = GOTO(9'd0); end endtask

  integer oscs;                                // osc_en pulses since reset release
  always @(posedge clk) if (mclr_n && osc_en) oscs <= oscs + 1;

  // reset, run until the PC sits at `stop` (a halt), with a time limit
  task run_to(input [8:0] stop, input integer limit_oscs);
    begin
      mclr_n = 0; oscs = 0;
      repeat (40) @(posedge clk);
      #1 mclr_n = 1;
      while (!(pc == stop || pc == stop + 1) && oscs < limit_oscs) @(posedge clk);
      repeat (64) @(posedge clk);              // let the halt's own GOTO settle
    end
  endtask

  // the register file as the program sees it: read it back through W
  // with a MOVF f,W at the halt, run separately (keeps the core opaque)
  reg [7:0] regs [0:31];
  integer i;

  // ------------------------------------------------ the tests
  integer t0, t1;
  reg [7:0] b8;

  initial begin
    clear_pm;

    // ======================== 4 (first): reset and the ports' latches
    // MCLR low: every latch high (p. 41: "During power on reset (MCLR low),
    // the latches in the I/O ports will be set high")
    repeat (20) @(posedge clk);
    is("MCLR: port A latches high", ra_latch, 4'hF);
    is("MCLR: port B latches high", rb_latch, 8'hFF);

    // ======================== the reset vector, as a parameter (6.3.1: the dump decides)
    // "Master Clear.  Used to initialize the internal ROM program to
    // address 777(8)" (p. 4-39)
    org(511); emit(GOTO(9'd5));
    org(0);   emit(GOTO(9'd0));
    org(5);   halt;
    run_to(hpc, 200);
    check(pc == 9'd5 || pc == 9'd6, "reset starts at 777 octal", pc, 5);
    pm[511] = GOTO(9'd0);

    // ======================== 1: the instructions, results and flags
    // ADDWF: the manual's example, 242 + 117 octal = 361 octal; C 0, DC 1, Z 0
    // capture status straight after ADDWF instead: rewrite with the status
    // read immediately (MOVF affects Z only, and Z is what it copies)
    org(0);
    emit(MOVLW(8'o242)); emit(MOVWF(R10));
    emit(MOVLW(8'o117)); emit(ADDWF(R10, W_));
    emit(MOVWF(R11));                            // W -> F11 (no flags)
    emit(SWAPF(F_ST, W_));                       // status -> W, swapped (SWAPF: no flags)
    emit(MOVWF(R12));
    emit(MOVF(R11, W_));                         // leave the sum in W
    halt;
    run_to(hpc, 400);
    is("ADDWF 242+117 octal = 361 octal (W)", w, 8'o361);
    b8 = unswap(R12);
    is("ADDWF 242+117: C 0", b8[C], 0);
    is("ADDWF 242+117: DC 1", b8[DC], 1);
    is("ADDWF 242+117: Z 0", b8[Z], 0);
    is("ADDWF d=0 leaves F10", dut_ram(R10), 8'o242);

    // ADDWF to f: F10 += W
    org(0);
    emit(MOVLW(8'h7F)); emit(MOVWF(R10)); emit(MOVLW(8'h01)); emit(ADDWF(R10, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    is("ADDWF d=1: 7F+01 -> F10 = 80", dut_ram(R10), 8'h80);
    b8 = unswap(R12);
    is("status bits 7-3 read as ones (no OV on the PIC1654S)", b8[7:3], 5'b11111);
    is("ADDWF 7F+01: C 0", b8[C], 0);
    is("ADDWF 7F+01: DC 1", b8[DC], 1);

    org(0);
    emit(MOVLW(8'h80)); emit(MOVWF(R10)); emit(ADDWF(R10, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    b8 = unswap(R12);
    is("ADDWF 80+80 = 00", dut_ram(R10), 8'h00);
    is("ADDWF 80+80: C 1", b8[C], 1);
    is("ADDWF 80+80: Z 1", b8[Z], 1);
    is("status bits 7-3 still ones after a carry out", b8[7:3], 5'b11111);

    org(0);
    emit(MOVLW(8'h01)); emit(MOVWF(R10)); emit(ADDWF(R10, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    b8 = unswap(R12);
    is("ADDWF 01+01: C 0, Z 0", b8[2:0], 3'b000);

    // SUBWF: the manual's examples.  104 - 50 octal = 34 octal, C 1, DC 0
    org(0);
    emit(MOVLW(8'o104)); emit(MOVWF(R10)); emit(MOVLW(8'o50)); emit(SUBWF(R10, W_));
    emit(MOVWF(R11)); emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    is("SUBWF 104-50 octal = 34 octal", dut_ram(R11), 8'o34);
    b8 = unswap(R12);
    is("SUBWF 104-50: C 1 (no borrow)", b8[C], 1);
    is("SUBWF 104-50: DC 0 (digit borrow)", b8[DC], 0);
    // 50 - 104 octal = 344 octal (two's complement), C 0, DC 1
    org(0);
    emit(MOVLW(8'o50)); emit(MOVWF(R10)); emit(MOVLW(8'o104)); emit(SUBWF(R10, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    is("SUBWF 50-104 octal = 344 octal (to f)", dut_ram(R10), 8'o344);
    b8 = unswap(R12);
    is("SUBWF 50-104: C 0 (borrow)", b8[C], 0);
    is("SUBWF 50-104: DC 1", b8[DC], 1);
    // 50 - 50: Z 1, C 1
    org(0);
    emit(MOVLW(8'o50)); emit(MOVWF(R10)); emit(SUBWF(R10, W_));
    emit(MOVWF(R11)); emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    b8 = unswap(R12);
    is("SUBWF 50-50 = 0", dut_ram(R11), 0);
    is("SUBWF 50-50: Z 1", b8[Z], 1);
    is("SUBWF 50-50: C 1", b8[C], 1);

    // INCF 127 octal -> 130 octal; DECF 1 -> 0 with Z; COMF 166 -> 211
    org(0);
    emit(MOVLW(8'o127)); emit(MOVWF(R10)); emit(INCF(R10, F_));
    emit(MOVLW(8'h01)); emit(MOVWF(R11)); emit(DECF(R11, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12));
    emit(MOVLW(8'o166)); emit(MOVWF(R20)); emit(COMF(R20, F_));
    halt;
    run_to(hpc, 400);
    is("INCF 127 octal -> 130 octal", dut_ram(R10), 8'o130);
    is("DECF 1 -> 0", dut_ram(R11), 0);
    b8 = unswap(R12);
    is("DECF to 0: Z 1", b8[Z], 1);
    is("COMF 166 octal -> 211 octal", dut_ram(R20), 8'o211);

    // Z only: INCF/DECF/COMF leave C and DC alone.  Set C and DC with
    // BSF, DECF to zero, and read them back.
    org(0);
    emit(BSF(F_ST, 3'd0)); emit(BSF(F_ST, 3'd1));
    emit(MOVLW(8'h01)); emit(MOVWF(R10)); emit(DECF(R10, F_));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12)); halt;
    run_to(hpc, 400);
    b8 = unswap(R12);
    is("DECF leaves C", b8[C], 1);
    is("DECF leaves DC", b8[DC], 1);
    is("DECF sets Z", b8[Z], 1);

    // logical: ANDWF, IORWF, XORWF, the literals, CLRW, CLRF, MOVF Z
    org(0);
    emit(MOVLW(8'hF0)); emit(MOVWF(R10));
    emit(MOVLW(8'h3C)); emit(ANDWF(R10, W_)); emit(MOVWF(R11));     // 30
    emit(MOVLW(8'h0F)); emit(IORWF(R10, F_));                       // F10 = FF
    emit(MOVLW(8'hFF)); emit(XORWF(R10, F_));                       // F10 = 00, Z
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12));
    emit(MOVLW(8'h55)); emit(IORLW(8'hAA)); emit(ANDLW(8'h0F)); emit(XORLW(8'h03)); // W = 0C
    emit(MOVWF(R20));
    halt;
    run_to(hpc, 600);
    is("ANDWF F0 & 3C", dut_ram(R11), 8'h30);
    is("IORWF then XORWF to f -> 00", dut_ram(R10), 8'h00);
    b8 = unswap(R12);
    is("XORWF to zero: Z 1", b8[Z], 1);
    is("MOVLW/IORLW/ANDLW/XORLW chain", dut_ram(R20), 8'h0C);

    org(0);
    emit(MOVLW(8'h5A)); emit(MOVWF(R10)); emit(CLRF(R10));
    emit(SWAPF(F_ST, W_)); emit(MOVWF(R12));
    emit(MOVLW(8'h77)); emit(CLRW(0));
    halt;
    run_to(hpc, 400);
    is("CLRF", dut_ram(R10), 0);
    b8 = unswap(R12);
    is("CLRF: Z 1", b8[Z], 1);
    is("CLRW", w, 0);
    is("CLRW: Z 1", status[Z], 1);

    // MOVWF: no flags.  Z set, then MOVWF of a nonzero W leaves it set.
    org(0);
    emit(BSF(F_ST, 3'd2)); emit(MOVLW(8'h12)); emit(MOVWF(R10)); halt;
    run_to(hpc, 400);
    is("MOVWF moves", dut_ram(R10), 8'h12);
    is("MOVWF leaves Z", status[Z], 1);
    is("MOVLW leaves Z", status[Z], 1);

    // MOVF f,f: tests for zero (TSTF, 3.5.2)
    org(0);
    emit(CLRF(R10)); emit(BCF(F_ST, 3'd2)); emit(MOVF(R10, F_)); halt;
    run_to(hpc, 400);
    is("TSTF of 0: Z 1", status[Z], 1);

    // rotates: RLF 65 octal with C 0 -> 152 octal, C 0 (the manual's example)
    org(0);
    emit(MOVLW(8'o65)); emit(MOVWF(R10)); emit(BCF(F_ST, 3'd0)); emit(RLF(R10, F_)); halt;
    run_to(hpc, 400);
    is("RLF 65 octal -> 152 octal", dut_ram(R10), 8'o152);
    is("RLF 65: C 0", status[C], 0);
    // RLF of 80 with C 1 -> 01, C 1; RRF of 01 with C 1 -> 80, C 1; to W
    org(0);
    emit(MOVLW(8'h80)); emit(MOVWF(R10)); emit(BSF(F_ST, 3'd0)); emit(RLF(R10, W_));
    emit(MOVWF(R11)); emit(SWAPF(F_ST, W_)); emit(MOVWF(R12));
    emit(MOVLW(8'h01)); emit(MOVWF(R20)); emit(BSF(F_ST, 3'd0)); emit(RRF(R20, F_));
    halt;
    run_to(hpc, 600);
    is("RLF 80 with C -> 01 (to W)", dut_ram(R11), 8'h01);
    b8 = unswap(R12);
    is("RLF 80: C 1", b8[C], 1);
    is("RLF to W leaves F10", dut_ram(R10), 8'h80);
    is("RRF 01 with C -> 80", dut_ram(R20), 8'h80);
    is("RRF 01: C 1", status[C], 1);
    // SWAPF, no flags
    org(0);
    emit(MOVLW(8'h3C)); emit(MOVWF(R10)); emit(BCF(F_ST, 3'd2)); emit(SWAPF(R10, F_)); halt;
    run_to(hpc, 400);
    is("SWAPF 3C -> C3", dut_ram(R10), 8'hC3);

    // the skips skip: each skipped word would mark R20 (INCF), each word
    // run after a skip not taken marks R11
    org(0);
    emit(CLRF(R11)); emit(CLRF(R20));
    emit(MOVLW(8'd1)); emit(MOVWF(R10));
    emit(DECFSZ(R10, F_)); emit(INCF(R20, F_));      // 1 -> 0: skips
    emit(DECFSZ(R10, F_)); emit(INCF(R11, F_));      // 0 -> FF: runs
    emit(INCFSZ(R10, F_)); emit(INCF(R20, F_));      // FF -> 0: skips
    emit(INCFSZ(R10, F_)); emit(INCF(R11, F_));      // 0 -> 1: runs
    emit(BTFSC(R10, 3'd1)); emit(INCF(R20, F_));     // bit 1 of 01 clear: skips
    emit(BTFSC(R10, 3'd0)); emit(INCF(R11, F_));     // bit 0 set: runs
    emit(BTFSS(R10, 3'd0)); emit(INCF(R20, F_));     // bit 0 set: skips
    emit(BTFSS(R10, 3'd7)); emit(INCF(R11, F_));     // bit 7 clear: runs
    emit(DECFSZ(R10, W_)); emit(INCF(R20, F_));      // to W: 01 -> 0 skips, F10 kept
    halt;
    run_to(hpc, 800);
    is("skipped words never run (DECFSZ, INCFSZ, BTFSC, BTFSS)", dut_ram(R20), 0);
    is("words after untaken skips run", dut_ram(R11), 4);
    is("DECFSZ to W leaves f", dut_ram(R10), 1);
    is("DECFSZ to W writes W", w, 0);

    // BCF/BSF on RAM
    org(0);
    emit(MOVLW(8'hFF)); emit(MOVWF(R10)); emit(BCF(R10, 3'd2));
    emit(CLRF(R11)); emit(BSF(R11, 3'd7)); halt;
    run_to(hpc, 400);
    is("BCF 10,2 (the manual's example on F7)", dut_ram(R10), 8'hFB);
    is("BSF 11,7", dut_ram(R11), 8'h80);

    // ======================== 3: the file's corners
    // FSR reads its three high bits as 111; indirect through F0
    org(0);
    emit(MOVLW(8'h0A)); emit(MOVWF(F_FSR));          // FSR = 12 octal = R10
    emit(MOVLW(8'h99)); emit(MOVWF(F_IND));          // (FSR) = 99 -> F10
    emit(MOVF(F_FSR, W_)); emit(MOVWF(R11));
    emit(INCF(F_IND, F_));                           // F10 = 9A
    halt;
    run_to(hpc, 400);
    is("indirect write through F0 reaches F10", dut_ram(R10), 8'h9A);
    is("FSR reads 111 in bits 7-5", dut_ram(R11), 8'hEA);

    // F2 reads the next instruction's address: MOVF 2,W at address 5 -> 6
    org(0);
    emit(NOP(0)); emit(NOP(0)); emit(NOP(0)); emit(NOP(0)); emit(NOP(0));
    emit(MOVF(F_PC, W_)); emit(MOVWF(R10)); halt;
    run_to(hpc, 400);
    is("F2 read = address of the next instruction", dut_ram(R10), 8'd6);

    // a computed jump: ADDWF 2 (W = 2) skips two words
    org(0);
    emit(MOVLW(8'd2)); emit(ADDWF(F_PC, F_));        // at 1: PC = 2 + 2 = 4
    emit(MOVLW(8'hEE)); emit(MOVLW(8'hEE));          // 2, 3: skipped
    emit(MOVLW(8'h44)); emit(MOVWF(R10)); halt;       // 4
    run_to(hpc, 400);
    is("ADDWF PC jumps", dut_ram(R10), 8'h44);

    // F2 as a destination clears PC bit 8: from 300 (bit 8 set) a
    // MOVWF 2 of 10 goes to 10, not 266
    org(0);   emit(GOTO(9'd300));
    org(300); emit(MOVLW(8'd10)); emit(MOVWF(F_PC));
    org(10);  emit(MOVLW(8'h10)); emit(MOVWF(R10)); halt;
    org(266); emit(MOVLW(8'h66)); emit(MOVWF(R10)); emit(GOTO(9'd268));
    run_to(hpc, 600);
    is("MOVWF 2 clears PC bit 8", dut_ram(R10), 8'h10);

    // CALL's target is 8 bits (p. 64: bit 8 is zero for a CALL); the stack
    // is 9 bits wide, so a CALL from 400 returns to 401
    clear_pm;
    org(0);   emit(GOTO(9'd400));
    org(400); emit(CALL(8'd20)); emit(MOVWF(R10)); halt;
    org(20);  emit(RETLW(8'h5C));
    org(276); emit(RETLW(8'hBD));                    // 256 + 20: must not be reached
    run_to(hpc, 600);
    is("CALL from 400 targets 20, RETLW returns to 401", dut_ram(R10), 8'h5C);

    // two levels: CALL, CALL, RETLW, RETLW
    org(0);   emit(CALL(8'd30)); emit(MOVWF(R10)); halt;
    org(30);  emit(CALL(8'd40)); emit(MOVWF(R11)); emit(RETLW(8'h01));
    org(40);  emit(RETLW(8'h02));
    run_to(hpc, 600);
    is("nested CALL: inner RETLW value", dut_ram(R11), 8'h02);
    is("nested CALL: outer RETLW value", dut_ram(R10), 8'h01);

    // a third CALL overwrites the oldest return address: two levels only
    // (2.1.3).  0 calls 50 calls 60 calls 70; the return to 2 is lost, so
    // the program never reaches the code at 2 that marks R10.
    clear_pm;
    org(0);   emit(CLRF(R10)); emit(CALL(8'd50));
    org(2);   emit(MOVLW(8'hA0)); emit(MOVWF(R10)); halt;
    org(50);  emit(CALL(8'd60)); emit(RETLW(8'h00));
    org(60);  emit(CALL(8'd70)); emit(RETLW(8'h00));
    org(70);  emit(RETLW(8'h00));
    run_to(hpc, 1000);
    is("a third CALL loses the first return address", dut_ram(R10), 8'h00);

    // RTCC: counts falling edges of its pin; presettable; wraps without C
    clear_pm;
    org(0); emit(MOVLW(8'hFE)); emit(MOVWF(F_RTCC)); emit(BCF(F_ST, 3'd0)); halt;
    run_to(hpc, 400);
    is("RTCC preset", rtcc, 8'hFE);
    #1 rtcc_pin = 0; repeat (8) @(posedge clk); rtcc_pin = 1; repeat (8) @(posedge clk);
    is("RTCC +1 on a falling edge", rtcc, 8'hFF);
    rtcc_pin = 0; repeat (8) @(posedge clk);
    is("RTCC wraps FF -> 00", rtcc, 8'h00);
    is("RTCC wrap does not set C", status[C], 0);
    rtcc_pin = 1; repeat (8) @(posedge clk);
    is("RTCC ignores a rising edge", rtcc, 8'h00);

    // ======================== 2: cycle counts, in OSC1 periods
    // a loop BSF 6,0 / BCF 6,0 / GOTO: 1 + 1 + 2 = 4 cycles = 32 OSC1
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(GOTO(9'd0));
    measure_rb0_period(t0);
    is("BSF+BCF+GOTO loop = 32 OSC1 (GOTO two cycles, eight OSC1 each)", t0, 32);
    // + a NOP: 40
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(NOP(0)); emit(GOTO(9'd0));
    measure_rb0_period(t0);
    is("+NOP = 40 OSC1", t0, 40);
    // + a CALL/RETLW pair: 1+1+2+2+2 = 8 cycles
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(CALL(8'd100)); emit(GOTO(9'd0));
    org(100); emit(RETLW(8'h00));
    measure_rb0_period(t0);
    is("+CALL+RETLW = 64 OSC1", t0, 64);
    // a skip not taken (1) and taken (2): BTFSC on a set bit, BTFSS on a set bit
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(BTFSC(F_B, 3'd7)); emit(GOTO(9'd0));
    measure_rb0_period(t0);            // RB7 reads 1: BTFSC not taken, 1 cycle
    is("BTFSC not taken = 1 cycle (40 OSC1)", t0, 40);
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(BTFSS(F_B, 3'd7)); emit(NOP(0)); emit(GOTO(9'd0));
    measure_rb0_period(t0);            // taken: 2 cycles, the NOP skipped
    is("BTFSS taken = 2 cycles (48 OSC1)", t0, 48);
    // DECFSZ taken and not
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(MOVLW(8'd1)); emit(MOVWF(R10));
    emit(DECFSZ(R10, F_)); emit(NOP(0)); emit(GOTO(9'd0));
    measure_rb0_period(t0);            // 1+1+1+1+2(skip)+2 = 8 cycles
    is("DECFSZ to zero skips (64 OSC1)", t0, 64);
    // ADDWF PC: two cycles ("Two Cycles", the manual's RTCC example)
    org(0); emit(BSF(F_B, 3'd0)); emit(BCF(F_B, 3'd0)); emit(MOVLW(8'd4)); emit(ADDWF(F_PC, F_));
    org(5); emit(GOTO(9'd0));           // ADDWF at 3: PC = 4 + 4 = 8? no: F2 reads 4, 4+4 = 8
    org(8); emit(GOTO(9'd0));
    measure_rb0_period(t0);            // 1+1+1+2+2 = 7 cycles
    is("ADDWF PC = 2 cycles (56 OSC1)", t0, 56);

    // ======================== 4: the ports
    // a read returns the pin: RB1 latch 1, pulled low outside -> reads 0
    clear_pm;
    org(0); emit(MOVF(F_B, W_)); emit(MOVWF(R10)); halt;
    rb_ext = 8'hFD;
    run_to(hpc, 400);
    is("port B read = pins (RB1 pulled low outside)", dut_ram(R10), 8'hFD);
    is("port B latches still high", rb_latch, 8'hFF);
    // a read-modify-write reads the pins: BSF 6,0 with RB1 held low
    // outside writes RB1's latch low (the p. 29 warning)
    org(0); emit(BSF(F_B, 3'd0)); halt;
    run_to(hpc, 400);
    is("BSF on port B latches the pins: RB1 now 0", rb_latch, 8'hFD);
    rb_ext = 8'hFF;
    // a latched 0 pulls the pin low
    org(0); emit(MOVLW(8'hF0)); emit(MOVWF(F_B)); emit(MOVF(F_B, W_)); emit(MOVWF(R10)); halt;
    run_to(hpc, 400);
    is("latched 0 pulls the pin: port B reads F0", dut_ram(R10), 8'hF0);
    // port A: four lines; the high bits read 1
    org(0); emit(MOVLW(8'h0A)); emit(MOVWF(F_A)); emit(MOVF(F_A, W_)); emit(MOVWF(R10)); halt;
    ra_ext = 4'b0111;
    run_to(hpc, 400);
    is("port A latch", ra_latch, 4'hA);
    is("port A read = {0000, pins} (RA4-RA7 read as zeros)", dut_ram(R10), 8'h02);
    ra_ext = 4'hF;
    // MCLR sets the latches high again
    mclr_n = 0; repeat (8) @(posedge clk);
    is("MCLR: port A latches high again", ra_latch, 4'hF);
    is("MCLR: port B latches high again", rb_latch, 8'hFF);

    $display("---- %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("==== PASS"); else $display("==== FAIL");
    $finish;
  end

  // the RAM, read through the core's own hierarchy (a peek; the program
  // never sees it)
  function [7:0] dut_ram(input [4:0] f);
    dut_ram = dut.ram[f];
  endfunction
  // a status byte captured with SWAPF 3,W / MOVWF: put its halves back
  function [7:0] unswap(input [4:0] f);
    reg [7:0] t;
    begin t = dut.ram[f]; unswap = {t[3:0], t[7:4]}; end
  endfunction

  // period of RB0's rising edges, in OSC1 periods
  task measure_rb0_period(output integer period);
    integer r1, r2;
    begin
      mclr_n = 0; oscs = 0; repeat (40) @(posedge clk); #1 mclr_n = 1;
      @(posedge rb_latch[0]); @(posedge clk); r1 = oscs;
      @(posedge rb_latch[0]); @(posedge clk); r2 = oscs;
      period = r2 - r1;
    end
  endtask

  initial begin #50_000_000 $display("==== FAIL (timeout)"); $finish; end

endmodule
