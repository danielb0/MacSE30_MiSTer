// tb_se30_fpu.v - items 7b and 7c (SE30_PLAN.md 8.9): the MC68882 through
// its pins, driven by the 68030's side of the coprocessor protocol.
//
// WHAT IT PROVES
//   1. Directed dialogs, each against the manual: the reset state; the
//      null restore; FMOVEM in and out in every mode (static and dynamic
//      lists, predecrement order) and FMOVE of the control registers with
//      their primitives; the PC pass; an instruction held while the APU is
//      busy; the pending exception reported, retained after XA, not
//      reported by FMOVEM, cleared by a null restore; the F-line on an
//      illegal command (not retained); protocol violations (an unexpected
//      command write, a register select write) and their acknowledge; the
//      early operand read never acknowledged; AB; DSACK's width and the
//      synchronous reads' 1.5-2.5 clocks.
//   2. FSAVE and FRESTORE (plan 8.9.3): the null frame of the reset phase
//      and what ends it; idle frames - the BIU flags, the command image,
//      bit 27 saved, cleared by the save, re-armed by the restore, changed
//      by software both ways; invalid format words; the nested save
//      ($0238, not destructive) and AB; the middle phase (come again, then
//      busy at a checkpoint; the instruction resumed after the temporaries
//      were disturbed, in the same clocks and with the same result); an
//      abandoned save; the initial phase (busy with an operand half
//      received); a store's pending operand read in an idle frame (Table
//      6-4's 110, the operand register image); a sweep of busy saves
//      through a packed-decimal store.
//   3. Every vector of out/fpu_rtl.vec (rtlvec.py) through bus cycles, as
//      the MPU would run them: a null restore; FMOVEM of FP0-FP7 and of
//      FPCR/FPSR in; the instruction (cpGEN or a conditional) with its
//      primitives serviced; an FNOP to catch a pending exception; FSAVE;
//      FMOVEM of FP2 and FP5 and FMOVE of FPSR out.  Its results against
//      the model - FP2, FP5, FPSR, the vector, pre or mid, the store (or
//      the conditional's TF), the exceptional operand and bit 27 from the
//      idle frame - and the APU's clocks against the simulator's.
//   4. With +detour, the same with a context switch (UM Figure 6-7) at a
//      point of each vector's dialogs or run picked from its index: FSAVE,
//      everything out, a null restore, an FSIN that leaves unusual tags
//      and trashed temporaries, everything back, FRESTORE, the dialog
//      continued - every result bit for bit, the clocks the simulator's
//      (at most, where the save cut END's padding short).  Under
//      SIMULATION the APU also poisons what a busy frame leaves out.
//
// THE MPU SIDE (docs/cp030_mpu_protocol.md sections 3-5, 9-10)
//   The PC is passed first whenever a primitive asks; null CA=1 re-reads,
//   CA=0 ends; evaluate-and-transfer moves its length through the operand
//   CIR MSB-aligned (a byte or a word as one access); transfer-single
//   writes Dn; transfer-multiple reads the register select CIR and moves
//   12 bytes a set bit; take pre- or mid-instruction writes XA and ends.
//
// PLUSARGS: +vec=FILE +only=GROUP +first=N +count=M +show=N (as
// tb_se30_fpu_apu.v), +directed_only, +detour.

`timescale 1ns/1ps

module tb_se30_fpu;
  `include "se30_fpu_fn.vh"

  reg clk = 1'b0, ce = 1'b0, reset = 1'b1;
  always #5 clk = ~clk;
  always @(posedge clk) ce <= ~ce;

  reg         cs = 1'b0, rw = 1'b1;
  reg  [4:0]  a = 5'd0;
  reg  [31:0] din = 32'd0;
  wire [31:0] dout;
  wire [1:0]  dsack_n;
  wire [79:0] dbg_exop;
  wire [15:0] dbg_clocks;
  wire        dbg_err;
  wire [4:0]  dbg_state;

  se30_fpu #(
    .UROM_HEX("../../rtl/fpu/ucode/ucode.urom.hex"),
    .NROM_HEX("../../rtl/fpu/ucode/ucode.nrom.hex"),
    .ENTRY_HEX("../../rtl/fpu/ucode/ucode.entry.hex"),
    .KROM_HEX("../../rtl/fpu/ucode/ucode.krom.hex")
  ) dut (
    .clk(clk), .ce(ce), .reset(reset),
    .cs(cs), .rw(rw), .a(a), .din(din), .dout(dout), .dsack_n(dsack_n),
    .dbg_exop(dbg_exop), .dbg_clocks(dbg_clocks), .dbg_err(dbg_err), .dbg_state(dbg_state));

  integer nchk = 0, nbad = 0;
  task check(input ok, input [8*64-1:0] what);
    begin
      nchk = nchk + 1;
      if (ok !== 1'b1) begin nbad = nbad + 1; $display("FAIL  %0s", what); end   // X fails too
    end
  endtask

  // -- one bus cycle ----------------------------------------------------------------
  reg  [31:0] rd;
  reg         bus_ok;
  reg  [1:0]  bus_dsack;
  integer     bus_clks;
  task bus(input rw_, input [4:0] addr, input [31:0] wdata);
    integer t;
    begin
      @(posedge clk); #1;
      rw = rw_; a = addr; din = wdata; cs = 1'b1;
      t = 0;
      while (dsack_n == 2'b11 && t < 200) begin @(posedge clk); #1; t = t + 1; end
      bus_ok = (dsack_n != 2'b11);
      bus_dsack = dsack_n;
      bus_clks = t;
      rd = dout;
      cs = 1'b0;
      @(posedge clk); #1;
    end
  endtask
  task wr16(input [4:0] addr, input [15:0] v); bus(1'b0, addr, {v, 16'h0000}); endtask
  task wr32(input [4:0] addr, input [31:0] v); bus(1'b0, addr, v); endtask
  task rd16(input [4:0] addr); bus(1'b1, addr, 32'd0); endtask

  // -- the MPU's side of the dialogs -----------------------------------------------
  reg  [31:0] op_long [0:2];       // what an evaluate-and-transfer DR=0 writes
  reg  [31:0] st_long [0:2];       // what a DR=1 reads
  reg  [31:0] mm_in  [0:23];       // FMOVEM in: 12 bytes a register, in order
  reg  [31:0] mm_out [0:23];
  reg  [31:0] dreg_val, pc_val;
  reg  [7:0]  x_vec;               // the exception taken, 0 none
  reg  [3:0]  x_when;
  reg         x_tf;                // a conditional's answer
  reg  [15:0] prims [0:15];        // the primitives read, in order
  integer     nprim, mm_count;
  reg  [15:0] last_prim;           // the last primitive read (prims keeps the first 16)
  reg         proto_bad;

  // +detour: a context switch at the det_cnt-th hook point (below)
  reg     det_arm = 1'b0;
  integer det_cnt = 0;
  task hook;
    begin
      if (det_arm) begin
        if (det_cnt == 0) begin det_arm = 1'b0; detour; end
        else det_cnt = det_cnt - 1;
      end
    end
  endtask

  task service(input cond_kind);
    integer it, i, n, len;
    reg [15:0] p;
    reg done;
    begin
      done = 1'b0; it = 0; nprim = 0; proto_bad = 1'b0;
      while (!done && it < 200000) begin
        hook;
        rd16(5'h00);
        p = rd[31:16];
        if (nprim < 16) prims[nprim] = p;
        last_prim = p;
        nprim = nprim + 1;
        it = it + 1;
        if (p[14]) wr32(5'h18, pc_val);                           // pass the PC
        if (p[13] == 1'b0 && p[12:9] == 4'b0100) begin            // null
          if (!p[15]) begin done = 1'b1; x_tf = p[0]; end
        end else if (p[12:11] == 2'b10 && !cond_kind) begin       // evaluate <ea>, data
          len = p[7:0];
          n = (len + 3) / 4;
          for (i = 0; i < n; i = i + 1)
            if (!p[13]) begin
              hook;
              if (len == 1)      wr32(5'h10, {op_long[0][7:0], 24'd0});
              else if (len == 2) wr32(5'h10, {op_long[0][15:0], 16'd0});
              else               wr32(5'h10, op_long[i]);
            end else begin
              hook;
              bus(1'b1, 5'h10, 32'd0);
              st_long[i] = rd;
            end
          if (!p[15]) done = 1'b1;
        end else if (p[12:8] == 5'b01100 && !cond_kind) begin     // transfer single register
          hook;
          wr32(5'h10, dreg_val);
        end else if (p[12:8] == 5'b00001 && !cond_kind) begin     // transfer multiple
          rd16(5'h14);
          mm_count = 0;
          for (i = 0; i < 8; i = i + 1) if (rd[24 + i]) mm_count = mm_count + 1;
          for (i = 0; i < 3 * mm_count; i = i + 1) begin
            hook;
            if (!p[13]) wr32(5'h10, mm_in[i]);
            else begin bus(1'b1, 5'h10, 32'd0); mm_out[i] = rd; end
          end
        end else if (p[13] == 1'b0 && (p[12:8] == 5'b11100 || p[12:8] == 5'b11101)) begin
          wr16(5'h02, 16'h0002);                                  // XA
          x_vec = p[7:0];
          x_when = (p[12:8] == 5'b11100) ? 4'd1 : 4'd2;
          done = 1'b1;
        end else begin
          proto_bad = 1'b1; done = 1'b1;
          $display("  the FPU sent primitive %h, which the MPU cannot service here", p);
        end
      end
      if (!done) begin proto_bad = 1'b1; $display("  no end to the dialog"); end
    end
  endtask

  task cp_gen(input [15:0] c);
    begin
      wr16(5'h0A, c);
      service(1'b0);
    end
  endtask

  task cp_cond(input [5:0] pred);
    begin
      wr16(5'h0E, {10'd0, pred});
      service(1'b1);
    end
  endtask

  task null_restore;
    begin
      wr16(5'h06, 16'h0000);
      rd16(5'h06);
    end
  endtask

  // -- FSAVE and FRESTORE, as the MPU runs them (7c) ------------------------------
  reg  [15:0] ffmt;                // the format word saved
  reg  [31:0] fr [1:53];           // the frame, longword k at offset 4k
  integer     fca;                 // come-agains before it
  task fsave;
    integer k, nl;
    begin
      fca = 0;
      rd16(5'h04);
      while (rd[31:16] == 16'h0138 && fca < 100000) begin fca = fca + 1; rd16(5'h04); end
      ffmt = rd[31:16];
      nl = (ffmt == 16'h1F38) ? 14 : (ffmt == 16'h1FD4) ? 53 : 0;
      for (k = nl; k >= 1; k = k - 1) begin
        bus(1'b1, 5'h10, 32'd0);
        fr[k] = rd;
      end
    end
  endtask
  task frestore;                   // ffmt and fr; rd holds the word read back
    integer k, nl;
    reg [31:0] back;
    begin
      wr16(5'h06, ffmt);
      rd16(5'h06);
      back = rd;
      nl = (rd[31:16] == 16'h1F38) ? 14 : (rd[31:16] == 16'h1FD4) ? 53 : 0;
      for (k = 1; k <= nl; k = k + 1) wr32(5'h10, fr[k]);
      rd = back;
    end
  endtask

  // The context switch of UM Figure 6-7, raw bus cycles only (it runs from
  // inside service): FSAVE; FMOVEM of FP0-FP7 and FPCR/FPSR/FPIAR out; a
  // null restore and an FSIN to disturb the temporaries; the registers
  // back; FRESTORE.  det_* record what it met.
  reg  [15:0] det_fmt;
  integer     det_ca, det_done;
  reg         det_bad, det_susp;
  reg  [31:0] dfp [0:23];
  reg  [31:0] dcr [0:2];
  task dexpect(input [15:0] want, input [8*24-1:0] what);
    begin
      rd16(5'h00);
      if (rd[31:16] !== want) begin
        det_bad = 1'b1;
        $display("  detour: %0s: primitive %h, not %h", what, rd[31:16], want);
      end
    end
  endtask
  // The instruction's clocks, as the APU leaves them at its own end (an
  // abort - a save dropping a stopped APU - is not an end, and the
  // detour's FSIN is not the vector's).
  reg     det_dist = 1'b0;
  reg [15:0] last_clk = 16'd0;
  always @(posedge clk)
    if (dut.apu_was_busy && !dut.apu_busy && !dut.kill && !det_dist) last_clk = dut.dbg_clocks;

  task detour;
    integer i, k;
    begin
      det_done = 1;
      fsave;
      det_dist = 1'b1;
      det_fmt = ffmt; det_ca = fca;
      det_susp = (ffmt == 16'h1FD4) && fr[10][31];
      if (ffmt != 16'h0038 && ffmt != 16'h1F38 && ffmt != 16'h1FD4) begin
        det_bad = 1'b1; $display("  detour: FSAVE format %h", ffmt);
      end
      wr16(5'h0A, 16'hF0FF); dexpect(16'hA10C, "FMOVEM out");
      rd16(5'h14);
      for (i = 0; i < 24; i = i + 1) begin bus(1'b1, 5'h10, 32'd0); dfp[i] = rd; end
      dexpect(16'h0802, "FMOVEM out end");
      wr16(5'h0A, 16'hBC00); dexpect(16'hB20C, "FMOVEM CR out");
      for (i = 0; i < 3; i = i + 1) begin bus(1'b1, 5'h10, 32'd0); dcr[i] = rd; end
      dexpect(16'h0802, "FMOVEM CR out end");
      null_restore;
      wr16(5'h0A, 16'hD080); dexpect(16'h810C, "FMOVEM FP0 in");
      rd16(5'h14);
      // FP0 a negative denormal: every tag the vector's instruction may
      // have left is overwritten with an unusual one (8.9.3's frame keeps them)
      wr32(5'h10, 32'h8000_0000); wr32(5'h10, 32'h0000_0000); wr32(5'h10, 32'h0000_0001);
      dexpect(16'h0802, "FMOVEM FP0 in end");
      wr16(5'h0A, 16'h000E); dexpect(16'h0900, "FSIN");                 // FSIN FP0
      k = 0;
      wr16(5'h0E, 16'h0000); rd16(5'h00);                                 // FNOP
      while (rd[31:16] == 16'h8900 && k < 100000) begin k = k + 1; rd16(5'h00); end
      if (rd[31:16] != 16'h0800) begin det_bad = 1'b1; $display("  detour: FNOP %h", rd[31:16]); end
      wr16(5'h0A, 16'h9C00); dexpect(16'h960C, "FMOVEM CR in");
      for (i = 0; i < 3; i = i + 1) wr32(5'h10, dcr[i]);
      dexpect(16'h0802, "FMOVEM CR in end");
      wr16(5'h0A, 16'hD0FF); dexpect(16'h810C, "FMOVEM in");
      rd16(5'h14);
      for (i = 0; i < 24; i = i + 1) wr32(5'h10, dfp[i]);
      dexpect(16'h0802, "FMOVEM in end");
      ffmt = det_fmt;
      if (det_fmt != 16'h0038) begin
        frestore;
        if (rd[31:16] != det_fmt) begin det_bad = 1'b1; $display("  detour: FRESTORE read %h", rd[31:16]); end
      end
      det_dist = 1'b0;
    end
  endtask

  // FMOVEM.X of FP0-FP7 in (postincrement, static, all eight: $D0FF)
  task load_fp(input [79:0] f0, f1, f2, f3, f4, f5, f6, f7);
    integer i;
    reg [79:0] f;
    begin
      for (i = 0; i < 8; i = i + 1) begin
        f = (i == 0) ? f0 : (i == 1) ? f1 : (i == 2) ? f2 : (i == 3) ? f3 :
            (i == 4) ? f4 : (i == 5) ? f5 : (i == 6) ? f6 : f7;
        mm_in[3 * i] = {f[79:64], 16'd0};
        mm_in[3 * i + 1] = f[63:32];
        mm_in[3 * i + 2] = f[31:0];
      end
      cp_gen(16'hD0FF);
    end
  endtask

  // FMOVEM of FPCR and FPSR in ($9800), of FPSR out ($A800)
  task load_cr(input [31:0] c, input [31:0] s);
    begin
      op_long[0] = c; op_long[1] = s;
      cp_gen(16'h9800);
    end
  endtask

  function [79:0] img;             // an FMOVEM register image back to 80 bits
    input [31:0] l0, l1, l2;
    img = {l0[31:16], l1, l2};
  endfunction

  localparam [79:0] NAN = 80'h7FFF_FFFFFFFFFFFFFFFF;

  // -- directed dialogs -------------------------------------------------------------
  integer i, t0;
  reg [79:0] r0;
  task directed;
    begin
      $display("-- directed dialogs");
      // the reset state: idle, and the registers the null restore's
      rd16(5'h00);
      check(rd[31:16] == 16'h0802 && bus_dsack == 2'b01, "reset: response $0802 on DSACK1");
      check(bus_clks >= 2 && bus_clks <= 5, "the response read is synchronous (1.5-2.5 FPU clocks)");
      null_restore;
      check(rd[31:16] == 16'h0000, "null restore: the format word reads back");
      bus(1'b1, 5'h08, 32'd0);
      check(rd == 32'hFFFFFFFF && bus_dsack == 2'b01 && bus_clks <= 1,
            "operation word CIR reads all ones, asynchronously");
      // the reset registers: FMOVEM of all eight out
      cp_gen(16'hF0FF);
      check(prims[0] == 16'hA10C && !proto_bad, "FMOVEM out: $A10C");
      r0 = img(mm_out[21], mm_out[22], mm_out[23]);
      check(r0 == NAN && img(mm_out[0], mm_out[1], mm_out[2]) == NAN, "reset: the registers are the NaN");
      // FMOVEM in every register, out in the predecrement order
      for (i = 0; i < 8; i = i + 1) begin
        mm_in[3 * i] = {1'b0, 15'h3FFF + i[14:0], 16'd0};
        mm_in[3 * i + 1] = 32'h8000_0000 | i;
        mm_in[3 * i + 2] = 32'h1234_0000 + i;
      end
      cp_gen(16'hD0FF);
      check(prims[0] == 16'h810C && prims[1] == 16'h0802 && !proto_bad, "FMOVEM in: $810C then $0802");
      cp_gen(16'hE0FF);                                           // predecrement, FP7 first
      check(mm_out[0] == {16'h4006, 16'd0} && mm_out[21] == {16'h3FFF, 16'd0},
            "FMOVEM -(An): FP7 is sent first, FP0 last");
      cp_gen(16'hF081);                                           // postincrement: FP0 and FP7
      check(mm_out[0] == {16'h3FFF, 16'd0} && mm_out[3] == {16'h4006, 16'd0} && mm_count == 2,
            "FMOVEM (An)+ list $81: FP0 then FP7");
      dreg_val = 32'h0000_0024;                                   // dynamic: D3 holds FP2, FP5
      cp_gen(16'hF830);
      check(prims[0] == 16'h8C03 && prims[1] == 16'hA10C && mm_count == 2 &&
            mm_out[0] == {16'h4001, 16'd0} && mm_out[3] == {16'h4004, 16'd0},
            "FMOVEM dynamic list from D3: $8C03, $A10C, FP2 and FP5");
      // the control registers
      op_long[0] = 32'h0000_1230;
      cp_gen(16'h9000);                                           // FPCR alone
      check(prims[0] == 16'h9504 && prims[1] == 16'h0802, "FMOVE to FPCR: $9504 then $0802");
      op_long[0] = 32'hCAFE_0000;
      cp_gen(16'h8400);                                           // FPIAR alone
      check(prims[0] == 16'h9704, "FMOVE to FPIAR: $9704");
      cp_gen(16'hBC00);                                           // all three out
      check(prims[0] == 16'hB20C && st_long[0] == 32'h0000_1230 && st_long[1] == 32'd0 &&
            st_long[2] == 32'hCAFE_0000, "FMOVEM FPCR/FPSR/FPIAR out: $B20C, in that order");
      cp_gen(16'hA400);
      check(prims[0] == 16'hB304, "FMOVE from FPIAR: $B304");
      cp_gen(16'h8000);
      check(x_vec == 8'h0B && prims[0] == 16'h1C0B, "an empty control-register list: F-line $1C0B");
      // the PC pass: an exception enabled, register to register
      load_cr(32'h0000_0400, 32'd0);                              // DZ enabled
      pc_val = 32'h0001_2340;
      cp_gen(16'h0422);                                           // FADD FP1,FP0
      check(prims[0] == 16'h4900, "register to register with an exception enabled: $4900");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0001_2340, "the passed PC is FPIAR");
      // a divide by zero: pending, retained after XA, not reported by FMOVEM
      load_fp(80'h3FFF_8000000000000000, 80'h0000_0000000000000000, NAN, NAN, NAN, NAN, NAN, NAN);
      cp_gen(16'h0420);                                           // FDIV FP1,FP0
      x_vec = 0;
      cp_cond(6'd0);                                              // FNOP
      check(x_vec == 8'h32 && x_when == 4'd1 && last_prim == 16'h1C32,
            "FNOP reports DZ: $8900 while the divide runs, then $1C32");
      rd16(5'h00);
      check(rd[31:16] == 16'h1C32, "after XA the response still holds the take primitive");
      x_vec = 0;
      cp_gen(16'hF0FF);
      check(x_vec == 0 && prims[0] == 16'hA10C, "FMOVEM does not report it (8.6.14 item 19)");
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 8'h32, "a second FNOP reports it again");
      null_restore;
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 0 && prims[0] == 16'h0800, "a null restore clears it: FNOP $0800");
      // the F-line: reported, not retained
      cp_gen(16'h2000);
      check(x_vec == 8'h0B && prims[0] == 16'h1C0B, "opclass 001: F-line $1C0B");
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 0 && prims[0] == 16'h0800, "the F-line is not retained");
      // an instruction held while the APU is busy
      load_fp(80'h3FFF_C000000000000000, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h000E);                                      // FSIN FP0,FP0
      rd16(5'h00);
      check(rd[31:16] == 16'h0900, "FSIN: released, $0900");
      wr16(5'h0A, 16'h0022);                                      // FADD FP0,FP0
      rd16(5'h00);
      check(rd[31:16] == 16'h8900, "the next instruction waits: $8900");
      service(1'b0);
      check(last_prim == 16'h0900 && !proto_bad, "then it starts: $0900");
      // protocol violations
      load_cr(32'h0000_0400, 32'd0);
      wr16(5'h0A, 16'h0022);
      rd16(5'h00);
      check(rd[31:16] == 16'h4900, "the PC is requested");
      wr16(5'h0A, 16'h0022);                                      // not the PC: a violation
      rd16(5'h00);
      check(rd[31:16] == 16'h1D0D, "a command written instead of the PC: $1D0D");
      wr16(5'h02, 16'h0002);
      rd16(5'h00);
      check(rd[31:16] == 16'h0802 || rd[31:16] == 16'h0900, "XA: the chip is idle again");
      wr16(5'h14, 16'h0000);
      rd16(5'h00);
      check(rd[31:16] == 16'h1D0D && bus_ok, "a register select write: $1D0D");
      wr16(5'h02, 16'h0002);
      // the early operand read, never acknowledged; then AB
      load_cr(32'd0, 32'd0);
      wr16(5'h0A, 16'h6880);                                      // FMOVE.X FP1,<ea>
      bus(1'b1, 5'h10, 32'd0);
      check(!bus_ok, "an operand read before the DR=1 primitive: no DSACK (8.6.14 item 21)");
      wr16(5'h02, 16'h0001);                                      // AB
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "AB: idle");
      // AB after an evaluate-and-transfer
      wr16(5'h0A, 16'h5422);                                      // FADD.D <ea>,FP0
      rd16(5'h00);
      check(rd[31:16] == 16'h1608, "FADD.D: $1608 (CA=0)");
      wr16(5'h02, 16'h0001);
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "AB after the primitive: idle");
      // widths
      bus(1'b1, 5'h14, 32'd0);                                    // (a violation when idle)
      check(bus_dsack == 2'b00, "the register select CIR is a 32-bit access");
      wr16(5'h02, 16'h0002);
      null_restore;
    end
  endtask

  // -- directed: FSAVE and FRESTORE (7c, plan 8.9.3) ------------------------------
  localparam [79:0] ONE_5 = 80'h3FFF_C000000000000000;             // 1.5
  reg [79:0]  want_sin, got;
  reg [15:0]  want_clk;
  reg [31:0]  sfr [1:53];
  integer     j, sw_bad, sw_busy;
  task fp0_out;                    // FMOVEM of FP0 out
    begin
      cp_gen(16'hF080);
      got = img(mm_out[0], mm_out[1], mm_out[2]);
    end
  endtask
  task frames;
    begin
      $display("-- directed frames");
      null_restore;
      fsave;
      check(ffmt == 16'h0038 && bus_clks >= 2 && bus_clks <= 5, "reset phase: FSAVE null $0038, synchronous");
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "after a null save the chip is idle");
      load_cr(32'd0, 32'd0);                                      // FMOVEM: the reset phase ends
      fsave;
      check(ffmt == 16'h1F38, "after FMOVEM: FSAVE idle $1F38 (8.6.14 item 28)");
      check(fr[14] == 32'h7C0EFFFF, "idle, nothing pending: BIU flags $7C0EFFFF");
      check(fr[1] == 32'h9800_0000 && fr[13] == 32'd0, "the command image; no operand register");
      fsave;
      check(ffmt == 16'h1F38, "a second FSAVE: idle again");
      // a pending exception: saved in bit 27, cleared by the save, re-armed by the restore
      load_cr(32'h0000_0400, 32'd0);                              // DZ enabled
      load_fp(80'h3FFF_8000000000000000, 80'h0000_0000000000000000, NAN, NAN, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_1000;
      cp_gen(16'h0420);                                           // FDIV FP1,FP0
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 8'h32, "FDIV by zero: FNOP takes DZ");
      fsave;
      check(ffmt == 16'h1F38 && fr[14][27] == 1'b0, "FSAVE: bit 27 clear, an exception pending");
      check(img(fr[10], fr[11], fr[12]) == dbg_exop, "the exceptional operand at $28");
      for (j = 1; j <= 14; j = j + 1) sfr[j] = fr[j];
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 0 && prims[0] == 16'h0800, "after FSAVE nothing is pending");
      for (j = 1; j <= 14; j = j + 1) fr[j] = sfr[j];
      ffmt = 16'h1F38; frestore;
      check(rd[31:16] == 16'h1F38, "FRESTORE idle: the word reads back");
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 8'h32, "the restored frame re-arms DZ");
      fsave;
      fr[14][27] = 1'b1;
      frestore;
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 0 && prims[0] == 16'h0800, "bit 27 set by software: nothing pending (UM 6-35)");
      fsave;
      fr[14][27] = 1'b0;
      frestore;
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 8'h32, "bit 27 cleared by software: DZ pending again");
      null_restore;
      // invalid words
      wr16(5'h06, 16'h1F18); rd16(5'h06);
      check(rd[31:16] == 16'h0238, "FRESTORE $1F18 (the 68881's idle): $0238");
      wr16(5'h06, 16'h3F38); rd16(5'h06);
      check(rd[31:16] == 16'h0238, "FRESTORE of another version: $0238");
      // a nested FSAVE: $0238, not destructive; AB ends the transfer
      load_cr(32'd0, 32'd0);
      rd16(5'h04);
      check(rd[31:16] == 16'h1F38, "FSAVE starts");
      bus(1'b1, 5'h10, 32'd0); bus(1'b1, 5'h10, 32'd0);
      rd16(5'h04);
      check(rd[31:16] == 16'h0238, "a save read during the transfer: $0238 (7.5.4.6)");
      bus(1'b1, 5'h10, 32'd0);
      check(rd == dbg_exop[31:0] && bus_ok, "... not destructive: the frame continues (longword 12)");
      wr16(5'h02, 16'h0001);                                      // AB
      for (j = 0; j < 11; j = j + 1) bus(1'b1, 5'h10, 32'd0);
      check(bus_ok, "after AB the rest of the frame is acknowledged");
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "and the chip is idle, no violation");
      // the middle phase: come again, then busy at a checkpoint
      null_restore;
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      cp_gen(16'h000E);                                           // FSIN FP0 (reference)
      cp_cond(6'd0);
      want_clk = dbg_clocks;
      fp0_out; want_sin = got;
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h000E); rd16(5'h00);
      repeat (100) @(posedge clk);
      fsave;
      check(fca > 0 && ffmt == 16'h1FD4 && fr[10][31], "FSIN: come again, then busy from a checkpoint");
      check(fr[53][27] && fr[1] == 32'h000E_0000, "busy: nothing pending, the command image");
      for (j = 1; j <= 53; j = j + 1) sfr[j] = fr[j];
      fsave;
      check(ffmt == 16'h1F38, "after a busy save the chip is idle");
      fp0_out;
      check(got == ONE_5, "FP0 not yet written");
      load_fp(NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN);            // disturb T0-T10 too:
      cp_gen(16'h0022); cp_cond(6'd0);                            // FADD FP0,FP0
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      for (j = 1; j <= 53; j = j + 1) fr[j] = sfr[j];
      ffmt = 16'h1FD4; frestore;
      check(rd[31:16] == 16'h1FD4, "FRESTORE busy: the word reads back");
      cp_cond(6'd0);
      check(prims[0] == 16'h8900 && last_prim == 16'h0800, "the FSIN resumes: $8900, then $0800");
      check(dbg_clocks == want_clk, "... in the same clocks");
      fp0_out;
      check(got == want_sin, "... with the same result");
      // an abandoned save: a new instruction lets the stopped APU go on
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h000E); rd16(5'h00);
      rd16(5'h04);
      check(rd[31:16] == 16'h0138, "FSAVE while FSIN runs: come again");
      repeat (400) @(posedge clk);
      check(dut.apu_susp, "... and the APU stops at its next checkpoint");
      cp_cond(6'd0);
      check(last_prim == 16'h0800, "a conditional instead: the FSIN finishes");
      fp0_out;
      check(got == want_sin, "... with its result");
      // the initial phase: busy during an operand's transfer
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      op_long[0] = 32'h3FF8_0000; op_long[1] = 32'h0000_0000;     // 1.5 as a double
      cp_gen(16'h5422); cp_cond(6'd0);                            // FADD.D <ea>,FP0 (reference)
      fp0_out; r0 = got;
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h5422); rd16(5'h00);
      check(rd[31:16] == 16'h1608, "FADD.D: $1608");
      wr32(5'h10, 32'h3FF8_0000);
      fsave;
      check(ffmt == 16'h1FD4 && !fr[10][31], "an operand half received: busy, the APU idle");
      check(fr[53][30:28] == 3'b100, "BIU flags: a write of the operand CIR pending");
      for (j = 1; j <= 53; j = j + 1) sfr[j] = fr[j];
      load_fp(NAN, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      for (j = 1; j <= 53; j = j + 1) fr[j] = sfr[j];
      ffmt = 16'h1FD4; frestore;
      wr32(5'h10, 32'h0000_0000);
      cp_cond(6'd0);
      fp0_out;
      check(got == r0 && got == 80'h4000_C000000000000000, "the dialog continues: 1.5 + 1.5 = 3");
      // a store's operand read pending: idle, code 110, the operand register image
      load_fp(80'h4000_C000000000000123, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h6800); rd16(5'h00);                         // FMOVE.X FP0,<ea>
      while (rd[31:16] == 16'h8900) rd16(5'h00);
      check(rd[31:16] == 16'h320C, "FMOVE.X out: $320C");
      bus(1'b1, 5'h10, 32'd0);
      check(rd == 32'h4000_0000, "the first longword");
      fsave;
      check(ffmt == 16'h1F38 && fr[14][30:28] == 3'b110 && !fr[14][26] && fr[14][23:20] == 4'hF,
            "idle: an operand read pending, the transfer to memory pending");
      check(fr[13] == 32'hC000_0000, "the operand register image: the next longword");
      for (j = 1; j <= 14; j = j + 1) sfr[j] = fr[j];
      load_fp(ONE_5, NAN, NAN, NAN, NAN, NAN, NAN, NAN);            // the output buffer disturbed
      cp_gen(16'h0022); cp_cond(6'd0);
      load_fp(80'h4000_C000000000000123, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      for (j = 1; j <= 14; j = j + 1) fr[j] = sfr[j];
      ffmt = 16'h1F38;
      frestore;
      bus(1'b1, 5'h10, 32'd0); st_long[1] = rd;
      bus(1'b1, 5'h10, 32'd0); st_long[2] = rd;
      check(st_long[1] == 32'hC000_0000 && st_long[2] == 32'h0000_0123, "the store continues after FRESTORE");
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "and ends");
      // a context switch at successive points of a packed-decimal store
      // (bindec reads the source's sign after a checkpoint, 8.9.3): a
      // positive source rounded toward plus, the detour's FSIN leaving a
      // negative denormal's tags behind
      null_restore;
      load_cr(32'h0000_0030, 32'd0);                              // RND = RP
      load_fp(80'h3FFF_C90FDAA22168C235, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      cp_gen(16'h6C05);                                           // FMOVE.P FP0,<ea>{#5}
      sfr[1] = st_long[0]; sfr[2] = st_long[1]; sfr[3] = st_long[2];
      sw_bad = 0; sw_busy = 0;
      for (j = 0; j < 4000; j = j + 97) begin
        load_fp(80'h3FFF_C90FDAA22168C235, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
        wr16(5'h0A, 16'h6C05); rd16(5'h00);                       // started
        repeat (j) @(posedge clk);
        det_arm = 1'b1; det_cnt = 0; det_bad = 1'b0; det_done = 0;
        service(1'b0);
        if (det_done && det_susp) sw_busy = sw_busy + 1;
        if (det_bad || proto_bad || st_long[0] !== sfr[1] || st_long[1] !== sfr[2] || st_long[2] !== sfr[3])
          sw_bad = sw_bad + 1;
      end
      det_arm = 1'b0;
      $display("  FMOVE.P sweep: %0d busy frames at a checkpoint, %0d wrong", sw_busy, sw_bad);
      check(sw_bad == 0 && sw_busy >= 8, "FMOVE.P: a busy frame at every point restores the same string");
      null_restore;
    end
  endtask

  // -- the vectors ------------------------------------------------------------------
  integer fd, r, c, n, idx, first, count, show, shown;
  integer npass, nfail, nclk, nskip;
  reg [8*16-1:0]  group, only;
  reg [8*256-1:0] path;
  reg [8*512-1:0] line;
  reg [7:0]       kind;
  reg [15:0]      v_cmd, v_clocks;
  reg [31:0]      v_fpcr, v_fpsr, v_dreg, w_fpsr;
  reg [79:0]      v_rx, v_ry, v_rc, w_ry, w_rc, w_xop;
  reg [95:0]      v_operand, w_store;
  reg [7:0]       w_vector;
  reg [3:0]       w_when;
  reg [79:0]      g_ry, g_rc, g_xop;
  reg [31:0]      g_fpsr;
  reg [95:0]      g_store;
  reg [7:0]       g_vector;
  reg [3:0]       g_when;
  reg [15:0]      g_clocks;
  reg             ran, bad, fline, g_pend, clk_bad;
  reg [79:0]      g_xfr;
  reg [2:0]       opclass, rxf;
  integer         len;

  reg [31:0] h;
  reg        detour_on;
  integer    nd_idle, nd_busyc, nd_busyi, nd_cut, nd_null;
  task run_vector;
    begin
      null_restore;
      last_clk = 16'hFFFF;
      det_done = 0; det_bad = 1'b0; det_ca = 0; det_fmt = 16'h0000; det_susp = 1'b0;
      if (detour_on) begin
        // where the context switch lands: the loading FMOVEMs (30 hook
        // points) for one vector in eight, else the instruction's dialog
        // and its run (the FNOP's re-reads, about one per four clocks)
        h = idx * 32'h9E3779B1;
        h = h ^ (h >> 15);
        det_cnt = (idx % 8 == 0) ? h % 30 : 30 + h % (6 + v_clocks / 3);
        det_arm = 1'b1;
      end
      load_fp(NAN, v_rx, v_ry, NAN, NAN, v_rc, NAN, NAN);
      load_cr(v_fpcr, v_fpsr);
      x_vec = 0; x_when = 0; x_tf = 0;
      opclass = v_cmd[15:13]; rxf = v_cmd[12:10];
      fline = (opclass == 3'd1) || ((opclass == 3'd0 || opclass == 3'd2) && v_cmd[6]);
      pc_val = 32'h0001_0000 + idx * 4;
      ran = 1'b0;
      g_store = 96'd0;
      if (kind == "C") begin
        cp_cond(v_cmd[5:0]);
        if (x_vec == 0) g_store = {95'd0, x_tf};
      end else begin
        len = (rxf == 3'd0 || rxf == 3'd1) ? 4 : (rxf == 3'd4) ? 2 : (rxf == 3'd5) ? 8 :
              (rxf == 3'd6) ? 1 : 12;
        if (len == 12) begin op_long[0] = v_operand[95:64]; op_long[1] = v_operand[63:32]; op_long[2] = v_operand[31:0]; end
        else if (len == 8) begin op_long[0] = v_operand[63:32]; op_long[1] = v_operand[31:0]; end
        else op_long[0] = v_operand[31:0];
        dreg_val = v_dreg;
        cp_gen(v_cmd);
        ran = !fline && !(x_vec == 8'h0B);
        if (opclass == 3'd3 && x_vec == 0 || opclass == 3'd3 && x_when == 4'd2)
          g_store = (len == 1) ? {88'd0, st_long[0][31:24]} : (len == 2) ? {80'd0, st_long[0][31:16]} :
                    (len == 4) ? {64'd0, st_long[0]} : (len == 8) ? {32'd0, st_long[0], st_long[1]} :
                    {st_long[0], st_long[1], st_long[2]};
        if (x_vec == 0) cp_cond(6'd0);                            // FNOP: a pending exception
      end
      det_arm = 1'b0;
      g_vector = x_vec; g_when = x_when;
      g_clocks = last_clk;
      // FSAVE: an idle frame, bit 27 the exception left pending, and the
      // exceptional operand (UM 6.4.2.2)
      fsave;
      g_xfr = img(fr[10], fr[11], fr[12]);
      g_pend = !fr[14][27];
      if (ffmt != 16'h1F38) begin proto_bad = 1'b1; $display("  FSAVE after the vector: %h", ffmt); end
      cp_gen(16'hF024);                                           // FP2 and FP5 out
      g_ry = img(mm_out[0], mm_out[1], mm_out[2]);
      g_rc = img(mm_out[3], mm_out[4], mm_out[5]);
      cp_gen(16'hA800);                                           // FPSR out
      g_fpsr = st_long[0];
      g_xop = 80'd0;
      if (g_vector == 8'd54 || g_vector == 8'd52 || g_vector == 8'd50 || g_vector == 8'd53 ||
          g_vector == 8'd51 || (opclass == 3'd3 && g_vector == 8'd49 && (g_fpsr[12] || g_fpsr[11])))
        g_xop = g_xfr;
    end
  endtask

  reg directed_only;
  initial begin
    if (!$value$plusargs("vec=%s", path)) path = "out/fpu_rtl.vec";
    if (!$value$plusargs("only=%s", only)) only = "";
    if (!$value$plusargs("first=%d", first)) first = 0;
    if (!$value$plusargs("count=%d", count)) count = 1 << 30;
    if (!$value$plusargs("show=%d", show)) show = 10;
    directed_only = $test$plusargs("directed_only");
    detour_on = $test$plusargs("detour");
    nd_idle = 0; nd_busyc = 0; nd_busyi = 0; nd_cut = 0; nd_null = 0;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    directed;
    frames;
    $display("directed: %0d checks, %0d fail", nchk, nbad);
    if (dbg_err) begin $display("FAIL the APU raised err"); nbad = nbad + 1; end
    npass = 0; nfail = 0; nclk = 0; nskip = 0; shown = 0; n = 0;
    if (!directed_only) begin
      fd = $fopen(path, "r");
      if (fd == 0) begin $display("FAIL cannot open %0s", path); $finish; end
      while (!$feof(fd)) begin
        c = $fgetc(fd);
        if (c == "#") r = $fgets(line, fd);
        else if (c != -1 && c != "\n") begin
          r = $ungetc(c, fd);
          r = $fscanf(fd, "%s %c %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                      group, kind, v_cmd, v_fpcr, v_fpsr, v_rx, v_ry, v_rc, v_operand, v_dreg,
                      w_ry, w_rc, w_fpsr, w_vector, w_when, w_store, w_xop, v_clocks);
          if (r != 18) begin $display("FAIL line %0d: %0d fields", n + 1, r); $finish; end
          idx = n; n = n + 1;
          if (idx < first || idx >= first + count || (only != "" && group != only)) nskip = nskip + 1;
          else begin
            run_vector;
            bad = proto_bad || det_bad || (g_ry !== w_ry) || (g_rc !== w_rc) || (g_fpsr !== w_fpsr) ||
                  (g_vector !== w_vector) || (g_when !== w_when) || (g_store !== w_store) ||
                  (g_xop !== w_xop) || (g_pend !== (w_vector != 8'h00 && w_vector != 8'h0B));
            if (bad) nfail = nfail + 1; else npass = npass + 1;
            // the clocks: the simulator's, or at most them where a save
            // waited for the end (it cuts END's padding short)
            clk_bad = ran && ((det_done && det_fmt == 16'h1F38 && det_ca > 0) ? (g_clocks > v_clocks)
                                                                             : (g_clocks !== v_clocks));
            if (clk_bad) nclk = nclk + 1;
            if (det_done)
              if (det_fmt == 16'h0038)      nd_null = nd_null + 1;
              else if (det_fmt == 16'h1F38) begin if (det_ca > 0) nd_cut = nd_cut + 1; else nd_idle = nd_idle + 1; end
              else if (det_susp)            nd_busyc = nd_busyc + 1;
              else                          nd_busyi = nd_busyi + 1;
            if ((bad || clk_bad) && shown < show) begin
              shown = shown + 1;
              $display("FAIL vector %0d (%0s %c %h):", idx, group, kind, v_cmd);
              if (proto_bad)             $display("    the dialog broke");
              if (g_ry !== w_ry)         $display("    ry     want %h  got %h", w_ry, g_ry);
              if (g_rc !== w_rc)         $display("    rc     want %h  got %h", w_rc, g_rc);
              if (g_fpsr !== w_fpsr)     $display("    fpsr   want %h  got %h", w_fpsr, g_fpsr);
              if (g_vector !== w_vector) $display("    vector want %h  got %h", w_vector, g_vector);
              if (g_when !== w_when)     $display("    when   want %h  got %h", w_when, g_when);
              if (g_store !== w_store)   $display("    store  want %h  got %h", w_store, g_store);
              if (g_xop !== w_xop)       $display("    xop    want %h  got %h", w_xop, g_xop);
              if (g_pend !== (w_vector != 8'h00 && w_vector != 8'h0B)) $display("    frame bit 27 wrong");
              if (clk_bad)               $display("    clocks want %0d  got %0d", v_clocks, g_clocks);
              if (det_done)              $display("    detour: %h after %0d come-agains%0s", det_fmt, det_ca,
                                                  det_susp ? ", the APU stopped" : "");
              $display("    primitives %0d: %h %h %h %h", nprim, prims[0], prims[1], prims[2], prims[3]);
            end
            if (dbg_err) begin $display("FAIL vector %0d: the APU raised err", idx); $finish; end
          end
          if (n % 2000 == 0) $display("... %0d vectors", n);
        end
      end
      $display("vectors %0d: %0d pass, %0d fail, %0d with other clocks, %0d skipped",
               n, npass, nfail, nclk, nskip);
      if (detour_on)
        $display("detours: busy at a checkpoint %0d, busy initial %0d, idle %0d, idle after come-again %0d, null %0d",
                 nd_busyc, nd_busyi, nd_idle, nd_cut, nd_null);
    end
    if (nbad == 0 && nfail == 0 && nclk == 0 && (directed_only || npass > 0)) $display("==== PASS");
    else $display("==== FAIL");
    $finish;
  end
endmodule
