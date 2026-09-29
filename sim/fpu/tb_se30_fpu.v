// tb_se30_fpu.v - item 7b (SE30_PLAN.md 8.9): the MC68882 through its pins,
// driven by the 68030's side of the coprocessor protocol.
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
//   2. Every vector of out/fpu_rtl.vec (rtlvec.py) through bus cycles, as
//      the MPU would run them: a null restore; FMOVEM of FP0-FP7 and of
//      FPCR/FPSR in; the instruction (cpGEN or a conditional) with its
//      primitives serviced; an FNOP to catch a pending exception; FMOVEM of
//      FP2 and FP5 and FMOVE of FPSR out.  Its seven results against the
//      model - FP2, FP5, FPSR, the vector, pre or mid, the store (or the
//      conditional's TF), the exceptional operand (read from the APU until
//      FSAVE shows it, 7c) - and the APU's clocks against the simulator's.
//
// THE MPU SIDE (docs/cp030_mpu_protocol.md sections 3-5, 9-10)
//   The PC is passed first whenever a primitive asks; null CA=1 re-reads,
//   CA=0 ends; evaluate-and-transfer moves its length through the operand
//   CIR MSB-aligned (a byte or a word as one access); transfer-single
//   writes Dn; transfer-multiple reads the register select CIR and moves
//   12 bytes a set bit; take pre- or mid-instruction writes XA and ends.
//
// PLUSARGS: +vec=FILE +only=GROUP +first=N +count=M +show=N (as
// tb_se30_fpu_apu.v), +directed_only.

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
      if (!ok) begin nbad = nbad + 1; $display("FAIL  %0s", what); end
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
  reg         proto_bad;

  task service(input cond_kind);
    integer it, i, n, len;
    reg [15:0] p;
    reg done;
    begin
      done = 1'b0; it = 0; nprim = 0; proto_bad = 1'b0;
      while (!done && it < 200000) begin
        rd16(5'h00);
        p = rd[31:16];
        if (nprim < 16) prims[nprim] = p;
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
              if (len == 1)      wr32(5'h10, {op_long[0][7:0], 24'd0});
              else if (len == 2) wr32(5'h10, {op_long[0][15:0], 16'd0});
              else               wr32(5'h10, op_long[i]);
            end else begin
              bus(1'b1, 5'h10, 32'd0);
              st_long[i] = rd;
            end
          if (!p[15]) done = 1'b1;
        end else if (p[12:8] == 5'b01100 && !cond_kind) begin     // transfer single register
          wr32(5'h10, dreg_val);
        end else if (p[12:8] == 5'b00001 && !cond_kind) begin     // transfer multiple
          rd16(5'h14);
          mm_count = 0;
          for (i = 0; i < 8; i = i + 1) if (rd[24 + i]) mm_count = mm_count + 1;
          for (i = 0; i < 3 * mm_count; i = i + 1)
            if (!p[13]) wr32(5'h10, mm_in[i]);
            else begin bus(1'b1, 5'h10, 32'd0); mm_out[i] = rd; end
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
      check(x_vec == 8'h32 && x_when == 4'd1 && prims[nprim - 1] == 16'h1C32,
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
      check(prims[nprim - 1] == 16'h0900 && !proto_bad, "then it starts: $0900");
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
  reg             ran, bad, fline;
  reg [2:0]       opclass, rxf;
  integer         len;

  task run_vector;
    begin
      null_restore;
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
      g_vector = x_vec; g_when = x_when;
      g_clocks = dbg_clocks;
      cp_gen(16'hF024);                                           // FP2 and FP5 out
      g_ry = img(mm_out[0], mm_out[1], mm_out[2]);
      g_rc = img(mm_out[3], mm_out[4], mm_out[5]);
      cp_gen(16'hA800);                                           // FPSR out
      g_fpsr = st_long[0];
      g_xop = 80'd0;
      if (g_vector == 8'd54 || g_vector == 8'd52 || g_vector == 8'd50 || g_vector == 8'd53 ||
          g_vector == 8'd51 || (opclass == 3'd3 && g_vector == 8'd49 && (g_fpsr[12] || g_fpsr[11])))
        g_xop = dbg_exop;
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
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (20) @(posedge clk);
    directed;
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
            bad = proto_bad || (g_ry !== w_ry) || (g_rc !== w_rc) || (g_fpsr !== w_fpsr) ||
                  (g_vector !== w_vector) || (g_when !== w_when) || (g_store !== w_store) ||
                  (g_xop !== w_xop);
            if (bad) nfail = nfail + 1; else npass = npass + 1;
            if (ran && g_clocks !== v_clocks) nclk = nclk + 1;
            if ((bad || (ran && g_clocks !== v_clocks)) && shown < show) begin
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
              if (ran && g_clocks !== v_clocks) $display("    clocks want %0d  got %0d", v_clocks, g_clocks);
              $display("    primitives %0d: %h %h %h %h", nprim, prims[0], prims[1], prims[2], prims[3]);
            end
            if (dbg_err) begin $display("FAIL vector %0d: the APU raised err", idx); $finish; end
          end
          if (n % 2000 == 0) $display("... %0d vectors", n);
        end
      end
      $display("vectors %0d: %0d pass, %0d fail, %0d with other clocks, %0d skipped",
               n, npass, nfail, nclk, nskip);
    end
    if (nbad == 0 && nfail == 0 && nclk == 0 && (directed_only || npass > 0)) $display("==== PASS");
    else $display("==== FAIL");
    $finish;
  end
endmodule
