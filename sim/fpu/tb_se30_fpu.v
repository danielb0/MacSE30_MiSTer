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
//   5. The overlap (7e, plan 8.9.6): directed (the CU taking an
//      instruction, a third waiting, take mid- and pre-instruction with
//      the CU's instruction in the frame, an operand ending after an
//      exception); with +pairs=2|3 every vector followed by one or two
//      others without waiting, against the same one at a time.
//
// THE MPU SIDE (docs/cp030_mpu_protocol.md sections 3-5, 9-10)
//   The PC is passed first whenever a primitive asks; null CA=1 re-reads,
//   CA=0 ends; evaluate-and-transfer moves its length through the operand
//   CIR MSB-aligned (a byte or a word as one access); transfer-single
//   writes Dn; transfer-multiple reads the register select CIR and moves
//   12 bytes a set bit; take pre- or mid-instruction writes XA and ends.
//
// PLUSARGS: +vec=FILE +only=GROUP +first=N +count=M +show=N (as
// tb_se30_fpu_apu.v), +directed_only, +detour, +pairs=2|3 (the overlap, 7e:
// see run_pairs; with +detour a context switch in each overlapped run).

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
    .KROM_HEX("../../rtl/fpu/ucode/ucode.krom.hex"),
    .NSEL_HEX("../../rtl/fpu/ucode/ucode.nsel.hex")
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

  reg [31:0] dsv_fr [1:53];        // the caller's frame buffer (a handler's frame, 7e)
  reg [15:0] dsv_fmt;
  task detour;
    integer i, k;
    begin
      det_done = 1;
      for (i = 1; i <= 53; i = i + 1) dsv_fr[i] = fr[i];
      dsv_fmt = ffmt;
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
      for (i = 1; i <= 53; i = i + 1) fr[i] = dsv_fr[i];
      ffmt = dsv_fmt;
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
      // an instruction taken by the CU while the APU is busy, a third one
      // held (7e; more in overlap)
      load_fp(80'h3FFF_C000000000000000, NAN, NAN, NAN, NAN, NAN, NAN, NAN);
      wr16(5'h0A, 16'h000E);                                      // FSIN FP0,FP0
      rd16(5'h00);
      check(rd[31:16] == 16'h0900, "FSIN: released, $0900");
      wr16(5'h0A, 16'h0022);                                      // FADD FP0,FP0
      rd16(5'h00);
      check(rd[31:16] == 16'h0900 && dut.apu_busy, "the next one goes to the CU: $0900, the APU busy");
      wr16(5'h0A, 16'h0022);
      rd16(5'h00);
      check(rd[31:16] == 16'h8900, "a third waits: $8900");
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
      sw_bad = 0;
      for (j = 1; j <= 14; j = j + 1) if (^fr[j] === 1'bx) sw_bad = sw_bad + 1;
      check(sw_bad == 0, "every longword of the idle frame defined (the CU's registers reset, 7e)");
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

  // -- directed: the overlap (7e, plan 8.9.6) -----------------------------------------
  reg [79:0] ov_fp [0:7];
  reg [31:0] ov_sr, ov_iar;
  task all_out;                    // FP0-FP7, FPSR and FPIAR, after an FNOP
    integer q;
    begin
      cp_cond(6'd0);
      cp_gen(16'hF0FF);
      for (q = 0; q < 8; q = q + 1) ov_fp[q] = img(mm_out[3 * q], mm_out[3 * q + 1], mm_out[3 * q + 2]);
      cp_gen(16'hA800); ov_sr = st_long[0];
      cp_gen(16'hA400); ov_iar = st_long[0];
    end
  endtask
  reg [79:0] sq_fp [0:7];
  reg [31:0] sq_sr, sq_iar;
  reg        same;
  task overlap;
    begin
      $display("-- directed overlap");
      // FSIN, FADD FP0,FP0 (in the CU, released), FMUL.S #2 (a third,
      // held, then in the CU while the FADD runs), against the same with
      // an FNOP after each
      for (j = 0; j < 2; j = j + 1) begin
        null_restore;
        load_fp(ONE_5, 80'h3FFF_8000000000000000, NAN, NAN, NAN, NAN, NAN, NAN);
        cp_gen(16'h000E);                                         // FSIN FP0
        if (j == 0) cp_cond(6'd0);
        cp_gen(16'h0022);                                         // FADD FP0,FP0
        if (j == 0) cp_cond(6'd0);
        op_long[0] = 32'h4000_0000;                               // 2.0 single
        cp_gen(16'h44A3);                                         // FMUL.S <ea>,FP1
        if (j == 1) check(prims[0] == 16'h8900 && last_prim == 16'h1504,
                          "FMUL.S a third: $8900 until the CU is free, then its operand, $1504");
        all_out;
        if (j == 0) begin
          for (i = 0; i < 8; i = i + 1) sq_fp[i] = ov_fp[i];
          sq_sr = ov_sr; sq_iar = ov_iar;
        end
      end
      same = (ov_sr == sq_sr);
      for (i = 0; i < 8; i = i + 1) same = same && (ov_fp[i] == sq_fp[i]);
      check(same && ov_fp[1] == 80'h4000_8000000000000000, "three in a row: the registers and FPSR as run one at a time");
      // an exception in the APU while a B source waits in the CU: the
      // CU's instruction reports it mid-instruction (UM 7.5, Figure 7-32)
      null_restore;
      load_cr(32'h0000_0400, 32'd0);                              // DZ enabled
      load_fp(80'h3FFF_8000000000000000, 80'h0000_0000000000000000, NAN, NAN, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_1000;
      cp_gen(16'h0420);                                           // FDIV FP1,FP0: DZ
      check(prims[0] == 16'h4900, "FDIV: released with the PC");
      pc_val = 32'h0000_1004;
      op_long[0] = 32'h0000_0003;                                 // the byte 3
      x_vec = 0;
      cp_gen(16'h58A2);                                           // FADD.B <ea>,FP1
      check(x_vec == 8'h32 && x_when == 4'd2, "FADD.B in the CU: the FDIV's DZ as take mid-instruction $1D32");
      rd16(5'h00);
      check(rd[31:16] == 16'h1D32, "after XA the response still holds it");
      wr16(5'h02, 16'h0002);                                      // (the MPU takes it again: XA)
      fsave;                                                      // the handler, FSAVE first (5.2.2)
      check(ffmt == 16'h1F38 && !fr[14][27], "FSAVE: idle, the exception pending");
      check(fr[5][3] && fr[5][31:27] == 5'd20 && fr[6][15:0] == 16'h58A2 && fr[7] == 32'h0000_1004,
            "... the FADD.B in the CU's slot: held, its command, its PC");
      check(fr[4][7:0] == 8'h03, "... its operand");
      rd16(5'h00);
      check(rd[31:16] == 16'h0802, "after FSAVE: idle");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_1000, "FPIAR is the FDIV's");
      fr[14][27] = 1'b1;                                          // the handler: serviced
      ffmt = 16'h1F38; frestore;
      service(1'b0);                                              // RTE: the dialog again
      check(!proto_bad && last_prim == 16'h0900, "after FRESTORE the FADD.B goes on: $0900");
      cp_cond(6'd0);
      cp_gen(16'hF040); r0 = img(mm_out[0], mm_out[1], mm_out[2]);
      check(r0 == 80'h4000_C000000000000000, "... FP1 = 0 + 3");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_1004, "... and FPIAR is now its PC");
      // the same with a register source: released, so the next
      // instruction reports it (pre-instruction), the FADD held meanwhile
      null_restore;
      load_cr(32'h0000_0400, 32'd0);
      load_fp(80'h3FFF_8000000000000000, 80'h0000_0000000000000000,
              80'h4000_8000000000000000, 80'h4001_A000000000000000, NAN, NAN, NAN, NAN);
      cp_gen(16'h0420);                                           // FDIV FP1,FP0
      cp_gen(16'h0D22);                                           // FADD FP3,FP2: 2 + 5
      check(prims[0] == 16'h4900, "FADD FP3,FP2 in the CU: released");
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 8'h32 && x_when == 4'd1, "FNOP: take pre-instruction $1C32");
      fsave;
      check(fr[5][3] && fr[6][15:0] == 16'h0D22, "FSAVE: the FADD in the CU's slot");
      cp_gen(16'hF020); r0 = img(mm_out[0], mm_out[1], mm_out[2]);
      check(r0 == 80'h4000_8000000000000000, "... FP2 not yet written");
      fr[14][27] = 1'b1;
      ffmt = 16'h1F38; frestore;
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 0 && last_prim == 16'h0800, "FNOP restarted: $0800");
      cp_gen(16'hF020); r0 = img(mm_out[0], mm_out[1], mm_out[2]);
      check(r0 == 80'h4001_E000000000000000, "... after the FADD ran: FP2 = 7");
      // an operand whose transfer began under the FDIV and ends after its
      // exception: the instruction waits in the slot, it does not start
      null_restore;
      load_cr(32'h0000_0400, 32'd0);
      load_fp(80'h3FFF_8000000000000000, 80'h0000_0000000000000000, NAN, NAN, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_2000;
      cp_gen(16'h0420);                                           // FDIV FP1,FP0
      wr16(5'h0A, 16'h5500); rd16(5'h00);                         // FMOVE.D <ea>,FP2
      if (rd[31:16] == 16'h5608) wr32(5'h18, 32'h0000_2004);      // (the PC)
      wr32(5'h10, 32'h4000_0000);                                 // 2.0, its high long
      while (!dut.pend) @(posedge clk);                           // the FDIV ends: DZ pending
      wr32(5'h10, 32'h0000_0000);                                 // its low long
      check(dut.cu_v && !dut.apu_busy, "the operand's last long after the exception: in the slot, not started");
      x_vec = 0;
      cp_cond(6'd0);
      check(x_vec == 8'h32 && x_when == 4'd1, "... the FNOP reports DZ");
      fsave;
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_2000, "... FPIAR the FDIV's");
      null_restore;
    end
  endtask

  // -- directed: the CU's moves (7e-2, plan 8.9.6) --------------------------------
  //    Each program run twice, with an FNOP after each instruction and
  //    without, the registers, FPSR and FPIAR compared (the stores too);
  //    and what the CU did, where it shows.
  localparam [79:0] X_1 = 80'h3FFF_8000000000000000, X_3 = 80'h4000_C000000000000000,
                    X_M25 = 80'hC000_A000000000000000, X_0 = 80'd0;
  integer    mv_n, mv_j, mv_cu;
  reg [95:0] mv_st [0:3];
  reg [95:0] sq_st [0:3];
  reg        mv_ok, mv_busy;
  reg        cu_seen;
  always @(posedge clk) if (dut.cu_fin) mv_cu = mv_cu + 1;
  task mv_gen(input [15:0] c, input [31:0] pc);   // one instruction, then an FNOP in the sequential run
    begin
      pc_val = pc;
      cp_gen(c);
      if (c[15:13] == 3'd3 && mv_n < 4) begin
        mv_st[mv_n] = (c[12:10] == 3'd1) ? {64'd0, st_long[0]} : (c[12:10] == 3'd5) ? {32'd0, st_long[0], st_long[1]}
                                         : {st_long[0], st_long[1], st_long[2]};
        mv_n = mv_n + 1;
      end
      if (mv_j == 0) cp_cond(6'd0);
    end
  endtask
  task mv_begin;
    begin
      null_restore;
      load_fp(X_1, X_3, X_0, X_M25, NAN, NAN, NAN, NAN);
      mv_n = 0; mv_cu = 0;
    end
  endtask
  task mv_end(input [8*64-1:0] what);   // the sequential run first (mv_j 0), then the overlapped
    integer q;
    begin
      all_out;
      if (mv_j == 0) begin
        for (q = 0; q < 8; q = q + 1) sq_fp[q] = ov_fp[q];
        for (q = 0; q < 4; q = q + 1) sq_st[q] = mv_st[q];
        sq_sr = ov_sr; sq_iar = ov_iar;
      end else begin
        mv_ok = (ov_sr == sq_sr) && (ov_iar == sq_iar);
        for (q = 0; q < 8; q = q + 1) mv_ok = mv_ok && (ov_fp[q] == sq_fp[q]);
        for (q = 0; q < mv_n; q = q + 1) mv_ok = mv_ok && (mv_st[q] == sq_st[q]);
        if (!mv_ok) $display("    fpsr seq %h ov %h, fpiar seq %h ov %h", sq_sr, ov_sr, sq_iar, ov_iar);
        check(mv_ok, what);
      end
    end
  endtask

  task moves;
    begin
      $display("-- directed CU moves");
      // FMOVE FP3,FP2 behind an FDIV: released, FP2 written, FPSR held
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        load_cr(32'h0000_0400, 32'd0);                              // DZ enabled: the PCs pass
        mv_gen(16'h0420, 32'h0000_3000);                            // FDIV FP1,FP0
        mv_gen(16'h0D00, 32'h0000_3004);                            // FMOVE FP3,FP2
        if (mv_j == 1) begin
          mv_busy = dut.apu_busy;
          repeat (8) @(posedge clk);
          check(mv_busy && last_prim == 16'h4900, "FMOVE FP3,FP2 behind the FDIV: released with the PC ($4900)");
          check(dut.apu_busy && dut.apu.fp[2] == X_M25 && dut.hv && mv_cu == 1,
                "... by the CU, FP2 written while the FDIV runs, its FPSR effect held");
        end
        mv_end("... the registers, FPSR (FPCC the move's) and FPIAR (its PC) as one at a time");
      end
      // (a): FPm the FDIV's destination - it waits for the FDIV
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        mv_gen(16'h0420, 32'h0000_3100);                            // FDIV FP1,FP0
        mv_gen(16'h0100, 32'h0000_3104);                            // FMOVE FP0,FP2
        if (mv_j == 1)
          check(!dut.apu_busy && nprim > 2 && mv_cu == 1, "(a) FMOVE FP0,FP2: $8900 until the FDIV ends, then the CU's");
        mv_end("... FP2 the quotient");
      end
      // (f): FPn the FDIV's destination - to the APU through the slot
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        mv_gen(16'h0420, 32'h0000_3200);                            // FDIV FP1,FP0
        mv_gen(16'h0C00, 32'h0000_3204);                            // FMOVE FP3,FP0
        if (mv_j == 1) check(dut.cu_v && mv_cu == 0, "(f) FMOVE FP3,FP0: in the slot, for the APU");
        mv_end("... FP0 the move's, not the quotient");
      end
      // FSINCOS's FPc is a destination too: (a) against FP5
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        mv_gen(16'h0135, 32'h0000_3300);                            // FSINCOS FP0,FP5:FP2
        mv_gen(16'h1700, 32'h0000_3304);                            // FMOVE FP5,FP6
        if (mv_j == 1) check(!dut.apu_busy && nprim > 2, "(a) FMOVE FP5,FP6 behind FSINCOS FP0,FP5:FP2 waits");
        mv_end("... FP6 the cosine");
      end
      // the APU's source overwritten by a move in right after it starts
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        mv_gen(16'h0420, 32'h0000_3400);                            // FDIV FP1,FP0: 1/3
        op_long[0] = 32'h4000_0000;
        mv_gen(16'h4480, 32'h0000_3404);                            // FMOVE.S #2,FP1
        if (mv_j == 1) repeat (8) @(posedge clk);
        if (mv_j == 1) check(dut.apu_busy && mv_cu == 1, "FMOVE.S <ea>,FP1 by the CU while the FDIV (from FP1) runs");
        mv_end("... the FDIV divided by 3, FP1 = 2");
      end
      // stores: S rounded, D and X, behind the FDIV
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        load_fp(X_1, X_3, 80'h3FFD_AAAAAAAAAAAAAAAB, X_M25, NAN, NAN, NAN, NAN);
        load_cr(32'h0000_0020, 32'd0);                              // RM
        mv_gen(16'h0420, 32'h0000_3500);                            // FDIV FP1,FP0
        mv_gen(16'h6500, 32'h0000_3504);                            // FMOVE.S FP2,<ea>: inexact
        if (mv_j == 1) check(dut.apu_busy && last_prim == 16'h3104 && mv_cu == 1,
                             "FMOVE.S FP2,<ea> by the CU behind the FDIV: CA = 0 ($3104)");
        mv_gen(16'h7580, 32'h0000_3508);                            // FMOVE.D FP3,<ea>
        op_long[0] = 32'h4000_0000; op_long[1] = 32'h8000_0000; op_long[2] = 32'd0;
        mv_gen(16'h4A00, 32'h0000_350C);                            // FMOVE.X #2,FP4
        mv_gen(16'h6900, 32'h0000_3510);                            // FMOVE.X FP2,<ea>
        if (mv_j == 1) check(mv_cu == 4, "... four moves, all the CU's");
        mv_end("... the stores, FPSR (INEX2, AEXC INEX) and the registers as one at a time");
      end
      // (d) INEX2 enabled: the store goes the APU's way
      mv_begin;
      load_cr(32'h0000_0200, 32'd0);
      load_fp(X_1, X_3, 80'h3FFD_AAAAAAAAAAAAAAAB, X_M25, NAN, NAN, NAN, NAN);
      mv_j = 1;
      mv_gen(16'h6500, 32'h0000_3600);
      check(mv_cu == 0 && x_vec == 8'd49 && x_when == 4'd2, "(d) FMOVE.S with INEX2 enabled: the APU's, INEX2 mid-instruction");
      // (e) judged before rounding (the model's UNFL): just below the least
      // normal single, rounding up to it, is the APU's - UNFL and INEX2
      mv_begin;
      load_fp(X_1, X_3, 80'h3F80_FFFFFFFFFFFFFFFF, X_M25, NAN, NAN, NAN, NAN);
      mv_j = 1;
      mv_gen(16'h6500, 32'h0000_3680);                            // FMOVE.S FP2,<ea>
      cp_gen(16'hA800);
      check(mv_cu == 0 && mv_st[0] == 96'h0080_0000 && st_long[0][11] && st_long[0][9],
            "(e) FMOVE.S of 2^-126 less an ulp of X: the APU's, UNFL before rounding");
      // the held effect across a pending exception: the handler sees the
      // FDIV's FPSR and FPIAR; FRESTORE with bit 27 applies the move's
      mv_begin;
      load_cr(32'h0000_0400, 32'd0);
      load_fp(X_1, X_0, NAN, X_M25, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_3700; cp_gen(16'h0420);                   // FDIV FP1,FP0: DZ
      pc_val = 32'h0000_3704; cp_gen(16'h0D00);                   // FMOVE FP3,FP2
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 8'h32 && x_when == 4'd1 && dut.apu.fp[2] == X_M25,
            "FNOP after FDIV (DZ), FMOVE: take pre-instruction, FP2 already written");
      fsave;
      check(ffmt == 16'h1F38 && fr[8][31] && fr[8][29] && fr[9] == 32'h0000_3704,
            "FSAVE: the move's effect held in longword 8, its PC in 9");
      cp_gen(16'hA800);
      check(st_long[0] == 32'h0000_0410, "... the handler's FPSR: the FDIV's (DZ, FPCC left by the trap)");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_3700, "... FPIAR the FDIV's");
      ffmt = 16'h1F38; frestore;                                  // not serviced: still pending
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 8'h32, "FRESTORE without bit 27: the FNOP reports it again");
      fsave;
      fr[14][27] = 1'b1; ffmt = 16'h1F38; frestore;
      x_vec = 0; cp_cond(6'd0);
      check(x_vec == 0, "FRESTORE with bit 27: the FNOP goes on");
      cp_gen(16'hA800);
      check(st_long[0][27] && !st_long[0][25] && st_long[0][15:8] == 8'd0 && st_long[0][4],
            "... FPSR the move's: FPCC N, EXC clear, AEXC DZ kept");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_3704, "... FPIAR the move's");
      // FSAVE between a CU store's image and its transfer, the FDIV running:
      // come again, then an idle frame carrying the image; restored, it goes on
      mv_begin;
      load_fp(X_1, X_3, NAN, X_M25, NAN, NAN, NAN, NAN);
      cp_gen(16'h0420);                                           // FDIV FP1,FP0
      wr16(5'h0A, 16'h6580);                                      // FMOVE.S FP3,<ea>
      rd16(5'h00); while (rd[31:16] == 16'h8900 && !dut.cu_st) rd16(5'h00);
      check(dut.cu_st && dut.apu_busy, "a CU store made while the FDIV runs");
      fsave;
      check(ffmt == 16'h1F38 && fca > 0 && fr[8][27] && fr[4] == 32'hC020_0000,
            "FSAVE: come again, then idle with the store's image (-2.5) and the flag");
      null_restore;
      frestore;
      rd16(5'h00);
      check(rd[31:16] == 16'h3104, "FRESTORE: the store's transfer, CA = 0");
      bus(1'b1, 5'h10, 32'd0);
      check(rd == 32'hC020_0000, "... -2.5 single");
      // the FDIV's exception pending before the CU store's transfer: its
      // first real response is the take mid-instruction (UM 7.5.4.2)
      mv_begin;
      load_cr(32'h0000_0400, 32'd0);
      load_fp(X_1, X_0, NAN, X_M25, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_3800; cp_gen(16'h0420);                   // FDIV FP1,FP0: DZ
      wr16(5'h0A, 16'h6580);                                      // FMOVE.S FP3,<ea>
      rd16(5'h00); while (rd[31] && !dut.cu_st) begin
        if (rd[30]) wr32(5'h18, 32'h0000_3804);
        rd16(5'h00);
      end
      if (rd[30]) wr32(5'h18, 32'h0000_3804);
      while (!dut.pend) @(posedge clk);
      rd16(5'h00);
      check(rd[31:16] == 16'h1D32, "a CU store, the FDIV's DZ pending since: take mid-instruction $1D32");
      wr16(5'h02, 16'h0002);                                      // XA
      fsave;
      check(ffmt == 16'h1F38 && fr[5][31:27] == 5'd7 && fr[8][27] && fr[4] == 32'hC020_0000,
            "... FSAVE: the store in B_CONV, its image, back there after XA");
      fr[14][27] = 1'b1; frestore;
      rd16(5'h00);
      check(rd[31:16] == 16'h3104, "... FRESTORE with bit 27: the transfer, CA = 0");
      bus(1'b1, 5'h10, 32'd0);
      check(rd == 32'hC020_0000, "... -2.5 single");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_3804, "... FPIAR the store's");
      // (a) across a busy frame: a store of the FMOD's destination waits;
      // FSAVE stops the FMOD, an FSIN runs, FRESTORE resumes it - the clock
      // after the frame's end the APU's own command is still the FSIN's,
      // the conflict must be the frame's (found by +pairs=2 +detour)
      for (mv_j = 0; mv_j < 2; mv_j = mv_j + 1) begin
        mv_begin;
        load_fp(X_1, X_3, 80'h43E8_E000000000000000, X_M25, NAN, NAN, NAN, NAN);
        mv_gen(16'h0521, 32'h0000_3900);                          // FMOD FP1,FP2
        if (mv_j == 1) begin
          wr16(5'h0A, 16'h6900);                                  // FMOVE.X FP2,<ea>
          rd16(5'h00);
          fsave;
          check(ffmt == 16'h1FD4 && fr[10][31], "FSAVE under a waiting store: busy, the FMOD stopped");
          for (i = 1; i <= 53; i = i + 1) dsv_fr[i] = fr[i];
          null_restore;
          cp_gen(16'h000E);                                       // FSIN FP0 (the APU's command now)
          cp_cond(6'd0);
          load_fp(X_1, X_3, 80'h43E8_E000000000000000, X_M25, NAN, NAN, NAN, NAN);   // the registers back
          for (i = 1; i <= 53; i = i + 1) fr[i] = dsv_fr[i];
          ffmt = 16'h1FD4; frestore;
          service(1'b0);                                          // the store's dialog goes on
          mv_st[0] = {st_long[0], st_long[1], st_long[2]}; mv_n = 1;
          cp_gen(16'hF020); r0 = img(mm_out[0], mm_out[1], mm_out[2]);
        end else begin
          mv_gen(16'h6900, 32'h0000_3904);
          cp_gen(16'hF020); r0 = img(mm_out[0], mm_out[1], mm_out[2]);
          sq_st[0] = mv_st[0];
        end
      end
      check(mv_st[0] == sq_st[0] && mv_st[0] == {r0[79:64], 16'd0, r0[63:0]},
            "... after FRESTORE the store is the FMOD's result");
      // BSUN's PC is FPIAR even when the last dialog put an instruction in
      // the slot (found by the full +pairs=3: FPIAR held the slot's PC)
      mv_begin;
      load_cr(32'h0000_8000, 32'd0);                              // BSUN enabled: the PCs pass
      load_fp(X_1, X_3, X_0, NAN, NAN, NAN, NAN, NAN);
      pc_val = 32'h0000_3A00; cp_gen(16'h0420);                   // FDIV FP1,FP0
      pc_val = 32'h0000_3A04; cp_gen(16'h0D22);                   // FADD FP3,FP2: a NaN, into the slot
      check(prims[0] == 16'h4900, "FADD behind the FDIV: into the slot, released with its PC");
      pc_val = 32'h0000_3A08; x_vec = 0;
      cp_cond(6'h10);                                             // FBSF: a NaN, BSUN
      check(x_vec == 8'd48, "the conditional after it: BSUN");
      cp_gen(16'hA400);
      check(st_long[0] == 32'h0000_3A08, "... FPIAR the conditional's, not the FADD's");
      // a conditional straight after a move to a register sees its FPCC
      mv_begin;
      cp_gen(16'h0900);                                           // FMOVE FP2,FP2 (+0)
      x_tf = 0; cp_cond(6'd1);                                    // FBEQ
      check(x_tf == 1'b1 && mv_cu == 1, "FBEQ after the CU's FMOVE of +0: true");
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

  // -- the CU's moves (7e-2, plan 8.9.6): which vectors the CU did itself.
  //    Their clocks are the CU's, counted apart until 7e-3 (Table 8-3); the
  //    route is checked against UM Table 5-5, (e) taken from the model's
  //    own OVFL and UNFL
  reg        cu_did;
  integer    ncu, napu_mv, nroute;
  always @(posedge clk) if (dut.cu_fin) cu_did = 1'b1;
  function [1:0] t_cls;            // 0 handed over, 1 zero, 2 infinity, 3 normalized
    input [79:0] x;
    t_cls = (x[78:0] == 79'd0) ? 2'd1 : (x[78:64] == 15'h7FFF) ? ((x[63:0] == 64'd0) ? 2'd2 : 2'd0)
          : x[63] ? 2'd3 : 2'd0;
  endfunction
  function [79:0] t_reg;           // the register a vector loads (load_fp: FP1, FP2, FP5)
    input [2:0] r;
    t_reg = (r == 3'd1) ? v_rx : (r == 3'd2) ? v_ry : (r == 3'd5) ? v_rc : NAN;
  endfunction
  function [79:0] t_in;            // an S, D or X operand as a register image
    input [2:0]  f;
    input [95:0] o;
    t_in = (f == 3'd1) ? ((o[30:23] == 8'hFF) ? {o[31], 15'h7FFF, (o[22:0] == 0) ? 64'd0 : {1'b1, o[22:0], 40'd0}}
                         : (o[30:23] == 8'd0) ? ((o[22:0] == 0) ? {o[31], 79'd0} : {o[31], 79'd1})
                         : {o[31], 15'h3FFF, 1'b1, 63'd0})
         : (f == 3'd5) ? ((o[62:52] == 11'h7FF) ? {o[63], 15'h7FFF, (o[51:0] == 0) ? 64'd0 : {1'b1, o[51:0], 11'd0}}
                         : (o[62:52] == 11'd0) ? ((o[51:0] == 0) ? {o[63], 79'd0} : {o[63], 79'd1})
                         : {o[63], 15'h3FFF, 1'b1, 63'd0})
         : {o[95], o[94:80], o[63:0]};
  endfunction
  function exp_cu;                 // Table 5-5: the CU does it (one instruction, nothing before it)
    input [15:0] w;
    reg   [2:0]  oc, f;
    reg          sdx;
    begin
      oc = w[15:13]; f = w[12:10];
      sdx = (f == 3'd1) || (f == 3'd5) || (f == 3'd2);
      exp_cu = 1'b0;
      if (oc == 3'd0 && w[6:0] == 7'd0)
        exp_cu = (v_fpcr[7:6] == 2'd0) && t_cls(t_reg(f)) != 2'd0;                 // b, c
      else if (oc == 3'd2 && w[6:0] == 7'd0 && sdx)
        exp_cu = (v_fpcr[7:6] == 2'd0) && t_cls(t_in(f, v_operand)) != 2'd0;       // b, c
      else if (oc == 3'd3 && sdx)
        exp_cu = t_cls(t_reg(w[9:7])) != 2'd0 &&                                   // b
                 !(f != 3'd2 && v_fpcr[9]) &&                                       // d
                 !(f != 3'd2 && t_cls(t_reg(w[9:7])) == 2'd3 && (w_fpsr[12] || w_fpsr[11]));   // e
    end
  endfunction

  task run_vector;
    begin
      null_restore;
      last_clk = 16'hFFFF;
      cu_did = 1'b0;
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
        if (cu_did) ran = 1'b0;                                   // the CU's clocks: 7e-3 (a move in
      end                                                         // is done after its dialog)
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

  // -- +pairs=2|3 (7e, plan 8.9.6): each vector's instruction, then one or
  //    two others picked from the file, issued without waiting, against
  //    the same with an FNOP after each - the overlap must leave the same
  //    registers, FPSR, FPIAR, stores, answers and exceptions (in order);
  //    only when an exception is reported may differ.  The handler for a
  //    take: FSAVE, bit 27 set (serviced), FRESTORE, then the dialog goes on
  //    (mid) or the instruction starts again (pre); the F-line and BSUN
  //    skip the instruction instead.  Under +detour a context switch lands
  //    at a point of the overlapped run.
  localparam NVMAX = 32768;
  reg [7:0]  a_kind  [0:NVMAX-1];
  reg [15:0] a_cmd   [0:NVMAX-1];
  reg [31:0] a_fpcr  [0:NVMAX-1];
  reg [31:0] a_fpsr  [0:NVMAX-1];
  reg [79:0] a_rx    [0:NVMAX-1];
  reg [79:0] a_ry    [0:NVMAX-1];
  reg [79:0] a_rc    [0:NVMAX-1];
  reg [95:0] a_opnd  [0:NVMAX-1];
  reg [31:0] a_dreg  [0:NVMAX-1];
  integer    nv, npairs;
  // what a run leaves
  reg [79:0] pr_fp  [0:7];
  reg [31:0] pr_sr, pr_iar;
  reg [95:0] pr_st  [0:2];
  reg [7:0]  pr_x   [0:7];
  reg [31:0] pr_xi  [0:7];         // FPIAR in each handler
  integer    pr_nx;
  reg        pr_bad;
  // ... the sequential run's copy
  reg [79:0] ps_fp  [0:7];
  reg [31:0] ps_sr, ps_iar;
  reg [95:0] ps_st  [0:2];
  reg [7:0]  ps_x   [0:7];
  reg [31:0] ps_xi  [0:7];
  integer    ps_nx;

  reg [31:0] hs0;
  task handler_take;               // after a take primitive and its XA
    begin
      if (pr_nx < 8) pr_x[pr_nx] = x_vec;
      if (x_when == 4'd2) mid_uses = mid_uses + 1;
      pr_nx = pr_nx + 1;
      fsave;
      if (ffmt != 16'h1F38 && ffmt != 16'h1FD4) pr_bad = 1'b1;
      hs0 = st_long[0];                                           // (a store's data, kept)
      cp_gen(16'hA400);                                           // FPIAR: the excepting instruction's
      if (pr_nx <= 8) pr_xi[pr_nx - 1] = st_long[0];
      st_long[0] = hs0;
      if (ffmt == 16'h1F38) fr[14][27] = 1'b1; else fr[53][27] = 1'b1;
      frestore;
    end
  endtask

  task issue(input integer v, input integer slot);   // one instruction, its exceptions handled
    integer tries, ln;
    reg [2:0] oc, fx;
    reg go;
    begin
      oc = a_cmd[v][15:13]; fx = a_cmd[v][12:10];
      ln = (fx == 3'd0 || fx == 3'd1) ? 4 : (fx == 3'd4) ? 2 : (fx == 3'd5) ? 8 : (fx == 3'd6) ? 1 : 12;
      if (ln == 12) begin op_long[0] = a_opnd[v][95:64]; op_long[1] = a_opnd[v][63:32]; op_long[2] = a_opnd[v][31:0]; end
      else if (ln == 8) begin op_long[0] = a_opnd[v][63:32]; op_long[1] = a_opnd[v][31:0]; end
      else op_long[0] = a_opnd[v][31:0];
      dreg_val = a_dreg[v];
      pc_val = 32'h0002_0000 + slot * 16;
      tries = 0; go = 1'b1;
      pr_st[slot] = 96'd0;
      while (go && tries < 8) begin
        tries = tries + 1;
        x_vec = 0; x_when = 0; x_tf = 0;
        if (a_kind[v] == "C") cp_cond(a_cmd[v][5:0]); else cp_gen(a_cmd[v]);
        while (x_vec != 0 && x_when == 4'd2 && tries < 8) begin      // mid: the handler, then on
          tries = tries + 1;
          handler_take;
          x_vec = 0; x_when = 0;
          service(a_kind[v] == "C");
        end
        if (proto_bad) pr_bad = 1'b1;
        if (x_vec == 0) begin
          go = 1'b0;
          if (a_kind[v] == "C") pr_st[slot] = {95'd0, x_tf};
          else if (oc == 3'd3)
            pr_st[slot] = (ln == 1) ? {88'd0, st_long[0][31:24]} : (ln == 2) ? {80'd0, st_long[0][31:16]} :
                          (ln == 4) ? {64'd0, st_long[0]} : (ln == 8) ? {32'd0, st_long[0], st_long[1]} :
                          {st_long[0], st_long[1], st_long[2]};
        end else begin
          handler_take;
          if (x_vec == 8'h0B || x_vec == 8'd48) go = 1'b0;           // skipped
        end
      end
      if (go) pr_bad = 1'b1;
    end
  endtask

  task fnop_h;                     // an FNOP, its exceptions handled
    integer t;
    begin
      t = 0; x_vec = 1;
      while (x_vec != 0 && t < 8) begin
        t = t + 1;
        x_vec = 0;
        cp_cond(6'd0);
        if (proto_bad) pr_bad = 1'b1;
        if (x_vec != 0) handler_take;
      end
    end
  endtask

  task run_group(input integer n3, input integer v0, input integer v1, input integer v2, input seq);
    integer q;
    begin
      null_restore;
      pr_nx = 0; pr_bad = 1'b0;
      load_fp(NAN, a_rx[v0], a_ry[v0], NAN, NAN, a_rc[v0], NAN, NAN);
      load_cr(a_fpcr[v0], a_fpsr[v0]);
      if (!seq && detour_on) begin
        h = v0 * 32'h9E3779B1; h = h ^ (h >> 15);
        det_cnt = h % 40; det_arm = 1'b1;
        det_done = 0; det_bad = 1'b0;
      end
      issue(v0, 0); if (seq) fnop_h;
      issue(v1, 1); if (seq) fnop_h;
      if (n3 == 3) begin issue(v2, 2); if (seq) fnop_h; end
      else pr_st[2] = 96'd0;
      fnop_h;
      det_arm = 1'b0;
      if (det_bad) pr_bad = 1'b1;
      cp_gen(16'hF0FF);
      for (q = 0; q < 8; q = q + 1) pr_fp[q] = img(mm_out[3 * q], mm_out[3 * q + 1], mm_out[3 * q + 2]);
      cp_gen(16'hA800); pr_sr = st_long[0];
      cp_gen(16'hA400); pr_iar = st_long[0];
    end
  endtask

  integer pn_pass, pn_fail, pn_show, pn_det, pv1, pv2, pq;
  integer pn_cu, pn_mid, cu_uses, mid_uses;
  reg     cu_v_q = 1'b0;
  always @(posedge clk) begin                     // the CU's take-overs, for the statistics
    cu_v_q <= dut.cu_v;
    if (dut.cu_v && !cu_v_q) cu_uses = cu_uses + 1;
  end
  reg     pn_bad;
  task run_pairs(input integer n3);
    begin
      pn_pass = 0; pn_fail = 0; pn_show = 0; pn_det = 0; pn_cu = 0; pn_mid = 0;
      for (idx = first; idx < nv && idx < first + count; idx = idx + 1) begin
        pv1 = (idx * 7919 + 13) % nv;
        pv2 = (idx * 104729 + 71) % nv;
        run_group(n3, idx, pv1, pv2, 1'b1);
        for (pq = 0; pq < 8; pq = pq + 1) ps_fp[pq] = pr_fp[pq];
        ps_sr = pr_sr; ps_iar = pr_iar;
        ps_st[0] = pr_st[0]; ps_st[1] = pr_st[1]; ps_st[2] = pr_st[2];
        for (pq = 0; pq < 8; pq = pq + 1) begin ps_x[pq] = pr_x[pq]; ps_xi[pq] = pr_xi[pq]; end
        ps_nx = pr_nx;
        pn_bad = pr_bad;
        cu_uses = 0; mid_uses = 0;
        run_group(n3, idx, pv1, pv2, 1'b0);
        if (cu_uses > 0) pn_cu = pn_cu + 1;
        if (mid_uses > 0) pn_mid = pn_mid + 1;
        if (det_done) pn_det = pn_det + 1;
        pn_bad = pn_bad || pr_bad || (pr_sr !== ps_sr) || (pr_iar !== ps_iar) || (pr_nx !== ps_nx) ||
                 (pr_st[0] !== ps_st[0]) || (pr_st[1] !== ps_st[1]) || (pr_st[2] !== ps_st[2]);
        for (pq = 0; pq < 8; pq = pq + 1) pn_bad = pn_bad || (pr_fp[pq] !== ps_fp[pq]);
        for (pq = 0; pq < 8 && pq < pr_nx; pq = pq + 1)
          pn_bad = pn_bad || (pr_x[pq] !== ps_x[pq]) || (pr_xi[pq] !== ps_xi[pq]);
        if (dbg_err) begin $display("FAIL group %0d: the APU raised err", idx); $finish; end
        if (pn_bad) begin
          pn_fail = pn_fail + 1;
          if (pn_show < show) begin
            pn_show = pn_show + 1;
            $display("FAIL group %0d: %h %h%0s", idx, a_cmd[idx], a_cmd[pv1],
                     (n3 == 3) ? "" : " (pair)");
            if (n3 == 3) $display("    third %h", a_cmd[pv2]);
            if (pr_bad)          $display("    a dialog broke (overlapped run)");
            if (pr_sr !== ps_sr)  $display("    fpsr  seq %h  ov %h", ps_sr, pr_sr);
            if (pr_iar !== ps_iar) $display("    fpiar seq %h  ov %h", ps_iar, pr_iar);
            if (pr_nx !== ps_nx)  $display("    exceptions seq %0d  ov %0d", ps_nx, pr_nx);
            for (pq = 0; pq < 8 && (pq < pr_nx || pq < ps_nx); pq = pq + 1)
              if (pr_x[pq] !== ps_x[pq] || pr_xi[pq] !== ps_xi[pq])
                $display("    exception %0d  seq vec %0d fpiar %h  ov vec %0d fpiar %h", pq, ps_x[pq], ps_xi[pq], pr_x[pq], pr_xi[pq]);
            for (pq = 0; pq < 8; pq = pq + 1)
              if (pr_fp[pq] !== ps_fp[pq]) $display("    fp%0d  seq %h  ov %h", pq, ps_fp[pq], pr_fp[pq]);
            for (pq = 0; pq < 3; pq = pq + 1)
              if (pr_st[pq] !== ps_st[pq]) $display("    store %0d  seq %h  ov %h", pq, ps_st[pq], pr_st[pq]);
          end
        end else pn_pass = pn_pass + 1;
        if ((idx - first + 1) % 1000 == 0) $display("... %0d groups", idx - first + 1);
      end
      $display("%0s %0d: %0d pass, %0d fail%0s", (n3 == 3) ? "triples" : "pairs",
               pn_pass + pn_fail, pn_pass, pn_fail, detour_on ? "" : "");
      $display("  the CU took an instruction in %0d, a take mid-instruction in %0d", pn_cu, pn_mid);
      if (detour_on) $display("  with a context switch in %0d", pn_det);
    end
  endtask

  reg directed_only;
  integer pairs_n;
  initial begin
    if (!$value$plusargs("vec=%s", path)) path = "out/fpu_rtl.vec";
    if (!$value$plusargs("only=%s", only)) only = "";
    if (!$value$plusargs("first=%d", first)) first = 0;
    if (!$value$plusargs("count=%d", count)) count = 1 << 30;
    if (!$value$plusargs("show=%d", show)) show = 10;
    directed_only = $test$plusargs("directed_only");
    if (!$value$plusargs("pairs=%d", pairs_n)) pairs_n = 0;
    nv = 0;
    detour_on = $test$plusargs("detour");
    nd_idle = 0; nd_busyc = 0; nd_busyi = 0; nd_cut = 0; nd_null = 0;
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    directed;
    frames;
    overlap;
    moves;
    $display("directed: %0d checks, %0d fail", nchk, nbad);
    if (dbg_err) begin $display("FAIL the APU raised err"); nbad = nbad + 1; end
    npass = 0; nfail = 0; nclk = 0; nskip = 0; shown = 0; n = 0;
    ncu = 0; napu_mv = 0; nroute = 0;
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
          if (pairs_n != 0) begin                                 // +pairs: load only
            if (nv < NVMAX) begin
              a_kind[nv] = kind; a_cmd[nv] = v_cmd; a_fpcr[nv] = v_fpcr; a_fpsr[nv] = v_fpsr;
              a_rx[nv] = v_rx; a_ry[nv] = v_ry; a_rc[nv] = v_rc; a_opnd[nv] = v_operand;
              a_dreg[nv] = v_dreg;
              nv = nv + 1;
            end
            nskip = nskip + 1;
          end else if (idx < first || idx >= first + count || (only != "" && group != only)) nskip = nskip + 1;
          else begin
            run_vector;
            bad = proto_bad || det_bad || (g_ry !== w_ry) || (g_rc !== w_rc) || (g_fpsr !== w_fpsr) ||
                  (g_vector !== w_vector) || (g_when !== w_when) || (g_store !== w_store) ||
                  (g_xop !== w_xop) || (g_pend !== (w_vector != 8'h00 && w_vector != 8'h0B));
            // the route (7e-2): the CU's moves, the rest the APU's
            if (kind != "C" && (exp_cu(v_cmd) !== cu_did)) begin
              bad = 1'b1; nroute = nroute + 1;
            end
            if (cu_did) ncu = ncu + 1;
            else if (kind != "C" && ((v_cmd[15:13] == 3'd0 || v_cmd[15:13] == 3'd2 && v_cmd[12:10] != 3'd7) &&
                                     v_cmd[6:0] == 7'd0 || v_cmd[15:13] == 3'd3)) napu_mv = napu_mv + 1;
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
              if (kind != "C" && exp_cu(v_cmd) !== cu_did)
                                         $display("    route  want %0s  got %0s", exp_cu(v_cmd) ? "CU" : "APU",
                                                  cu_did ? "CU" : "APU");
              if (det_done)             $display("    detour: %h after %0d come-agains%0s", det_fmt, det_ca,
                                                  det_susp ? ", the APU stopped" : "");
              $display("    primitives %0d: %h %h %h %h", nprim, prims[0], prims[1], prims[2], prims[3]);
            end
            if (dbg_err) begin $display("FAIL vector %0d: the APU raised err", idx); $finish; end
          end
          if (n % 2000 == 0) $display("... %0d vectors", n);
        end
      end
      if (pairs_n != 0) begin
        $display("-- %0d vectors loaded for +pairs=%0d", nv, pairs_n);
        run_pairs(pairs_n == 3 ? 3 : 2);
      end else begin
        $display("vectors %0d: %0d pass, %0d fail, %0d with other clocks, %0d skipped",
                 n, npass, nfail, nclk, nskip);
        $display("  moves by the CU %0d (clocks not compared), FMOVE and stores by the APU %0d, wrong route %0d",
                 ncu, napu_mv, nroute);
        if (detour_on)
          $display("detours: busy at a checkpoint %0d, busy initial %0d, idle %0d, idle after come-again %0d, null %0d",
                   nd_busyc, nd_busyi, nd_idle, nd_cut, nd_null);
      end
    end
    if (pairs_n != 0 && !directed_only) begin
      if (nbad == 0 && pn_fail == 0 && pn_pass > 0) $display("==== PASS"); else $display("==== FAIL");
    end else if (nbad == 0 && nfail == 0 && nclk == 0 && (directed_only || npass > 0)) $display("==== PASS");
    else $display("==== FAIL");
    $finish;
  end
endmodule
