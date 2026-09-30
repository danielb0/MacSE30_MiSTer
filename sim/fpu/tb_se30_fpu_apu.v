// tb_se30_fpu_apu.v - item 7a (SE30_PLAN.md 8.9): the APU's RTL against
// tools/fpu_ucode/sim.py, on the model's vectors (plan 8.7.4).
//
// WHAT IT PROVES
//   Every vector of out/fpu_rtl.vec (rtlvec.py: the model's 19,484 with
//   the simulator's clocks) through rtl/fpu/se30_fpu_apu.v: its seven
//   results - FP2 and FP5 after, FPSR, the exception vector, pre- or
//   mid-instruction, the stored operand (or a conditional's answer), the
//   exceptional operand - equal the model's, and its clocks equal the
//   simulator's, which equal the timing tables' (vec.py, plan 8.8.19).
//   Also that the APU never raises `err` (sim.py's SimError).
//
// WHAT IT DOES AROUND THE APU
//   The BIU's part of each instruction as vec.py does it, with the RTL's
//   BIU logic where it exists: the decode (F-line for opmodes $40-$7F,
//   opclass 001, FMOVECR offsets $40-$7F); the conditionals through
//   se30_fpu_cond (the predicate, BSUN); the CU's unpacking through
//   se30_fpu_unpack; the entry-table index; the pending exception
//   (se30_fpu_fn.vh's fpu_trapvec) and the exceptional operand where the
//   model defines one.  The registers are loaded and read through the
//   register file's port B.  7b replaces this with the CU and the BIU.
//
// PLUSARGS
//   +vec=FILE      the vectors (default out/fpu_rtl.vec)
//   +only=GROUP    one group (rounding, convert, packed, fmovecr,
//                  transcend, special, cond, decode)
//   +first=N +count=M   vectors N .. N+M-1 of the file (from 0)
//   +show=N        print N failures (default 10)
//   +trace=N       print vector N's trace in rtlvec.py --trace's format

`timescale 1ns/1ps

module tb_se30_fpu_apu;
  `include "se30_fpu_fn.vh"

  reg clk = 1'b0, ce = 1'b0, reset = 1'b1;
  always #5 clk = ~clk;
  always @(posedge clk) ce <= ~ce;

  // the APU
  reg         start = 1'b0;
  reg  [9:0]  entry_idx = 10'd0;
  reg  [15:0] cmd = 16'd0;
  reg  [95:0] operand = 96'd0;
  reg         fpcr_we = 1'b0, fpsr_we = 1'b0;
  reg  [31:0] fpcr_d = 32'd0, fpsr_d = 32'd0;
  reg  [2:0]  fpb_addr = 3'd0;
  reg         fpb_we = 1'b0;
  reg  [79:0] fpb_d = 80'd0;
  wire [79:0] fpb_q;
  wire [31:0] fpcr, fpsr;
  wire [95:0] obuf;
  wire [79:0] exop;
  wire [15:0] clocks;
  wire        busy, err, t_exec;
  wire [11:0] t_upc;

  // the CU's unpacking
  reg         u_is_fp = 1'b0;
  reg  [79:0] u_fp = 80'd0;
  reg  [2:0]  u_fmt = 3'd0;
  reg  [95:0] u_operand = 96'd0;
  wire [85:0] u_word;
  wire [2:0]  u_tag;
  wire        u_snan, u_den, u_neg;
  reg         zero_src = 1'b0;          // FMOVECR: the zero word

  se30_fpu_unpack unpack (
    .is_fp(u_is_fp), .fp(u_fp), .fmt(u_fmt), .operand(u_operand),
    .word(u_word), .tag(u_tag), .snan(u_snan), .den(u_den), .neg(u_neg));

  se30_fpu_apu #(
    .UROM_HEX("../../rtl/fpu/ucode/ucode.urom.hex"),
    .NROM_HEX("../../rtl/fpu/ucode/ucode.nrom.hex"),
    .ENTRY_HEX("../../rtl/fpu/ucode/ucode.entry.hex"),
    .KROM_HEX("../../rtl/fpu/ucode/ucode.krom.hex"),
    .NSEL_HEX("../../rtl/fpu/ucode/ucode.nsel.hex")
  ) dut (
    .clk(clk), .reset(reset), .ce(ce),
    .start(start), .abort(1'b0), .entry_idx(entry_idx), .cmd(cmd),
    .cu_word(zero_src ? 86'd0 : u_word), .cu_tag(zero_src ? 3'd2 : u_tag),
    .cu_snan(zero_src ? 1'b0 : u_snan), .cu_den(zero_src ? 1'b0 : u_den),
    .cu_neg(zero_src ? 1'b0 : u_neg), .operand(operand),
    .busy(busy), .clocks(clocks), .err(err),
    .fpcr_we(fpcr_we), .fpcr_d(fpcr_d), .fpsr_we(fpsr_we), .fpsr_d(fpsr_d),
    .fpcr(fpcr), .fpsr(fpsr),
    .fpb_addr(fpb_addr), .fpb_we(fpb_we), .fpb_d(fpb_d), .fpb_q(fpb_q),
    .obuf(obuf), .exop(exop),
    .save_req(1'b0), .susp(), .in_pad(), .resume(1'b0), .ctx_we(1'b0), .ctx_d(163'd0), .ctx_q(),
    .x_taddr(4'd0), .x_twe(1'b0), .x_td(86'd0), .x_tq(), .x_exop_we(1'b0), .x_exop(80'd0),
    .x_obuf_we(1'b0), .x_obuf(96'd0),
    .t_exec(t_exec), .t_upc(t_upc));

  // the conditionals
  reg  [5:0] c_pred = 6'd0;
  reg  [3:0] c_cc = 4'd0;
  wire       c_taken, c_bsun;
  se30_fpu_cond cond (.pred(c_pred), .fpcc(c_cc), .taken(c_taken), .bsun(c_bsun));

  // -- the register file's port B: its p0 edges (ce low) are ours (7e) -----------
  task fp_write(input [2:0] i, input [79:0] v);
    begin
      fpb_addr = i; fpb_d = v; fpb_we = 1'b1;
      if (ce) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      fpb_we = 1'b0;
    end
  endtask

  task fp_read(input [2:0] i, output [79:0] v);
    begin
      fpb_addr = i;
      if (ce) begin @(posedge clk); #1; end
      @(posedge clk); #1;
      v = fpb_q;
    end
  endtask

  // -- the trace (rtlvec.py's format) ------------------------------------------
  reg        tracing = 1'b0;
  reg [11:0] tr_u;
  reg [15:0] tr_c;
  reg [85:0] tr_res;
  reg        tr_nop;
  always @(posedge clk)
    if (tracing && t_exec) begin
      tr_u = t_upc; tr_c = clocks; tr_res = dut.res; tr_nop = dut.alu_nop;
      #1;
      if (tr_nop)
        $display("U %03h C %0d F %b%b%b%b%b %b%b%b%b%b SC %02h LC %02h LZ %02h Q %017h %0d MD %017h %017h P %08h B %0d R -",
                 tr_u, tr_c, dut.fz, dut.fn, dut.fc, dut.fv, dut.fs, dut.stk, dut.inex, dut.dflag, dut.tiny,
                 dut.huge, dut.sc, dut.lc, dut.lzc, dut.q, dut.qx, dut.md, dut.md3, fpsr, dut.budget);
      else
        $display("U %03h C %0d F %b%b%b%b%b %b%b%b%b%b SC %02h LC %02h LZ %02h Q %017h %0d MD %017h %017h P %08h B %0d R %h.%05h.%017h",
                 tr_u, tr_c, dut.fz, dut.fn, dut.fc, dut.fv, dut.fs, dut.stk, dut.inex, dut.dflag, dut.tiny,
                 dut.huge, dut.sc, dut.lc, dut.lzc, dut.q, dut.qx, dut.md, dut.md3, fpsr, dut.budget,
                 tr_res[85], tr_res[84:67], tr_res[66:0]);
    end

  // -- the vectors ------------------------------------------------------------------
  integer fd, r, c, n, idx, first, count, show, trace_n, shown;
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
  // what the chip gives
  reg [79:0]      g_ry, g_rc, g_xop, tmp;
  reg [31:0]      g_fpsr;
  reg [95:0]      g_store;
  reg [7:0]       g_vector;
  reg [3:0]       g_when;
  reg [15:0]      g_clocks;
  reg             ran, bad, fline;
  reg [2:0]       opclass, rxf;
  reg [6:0]       ext;

  task run_vector;
    begin
      // the registers: FP1 the source, FP2 the destination, FP5 FSINCOS's
      // cosine register, the others a NaN (vec.py)
      for (c = 0; c < 8; c = c + 1)
        fp_write(c, (c == 1) ? v_rx : (c == 2) ? v_ry : (c == 5) ? v_rc : 80'h7FFF_FFFFFFFFFFFFFFFF);
      fpcr_d = v_fpcr; fpsr_d = v_fpsr; fpcr_we = 1'b1; fpsr_we = 1'b1;
      @(posedge clk); #1;
      fpcr_we = 1'b0; fpsr_we = 1'b0;
      g_ry = v_ry; g_rc = v_rc; g_fpsr = v_fpsr; g_vector = 8'd0; g_when = 4'd0;
      g_store = 96'd0; g_xop = 80'd0; g_clocks = 16'd0; ran = 1'b0;
      opclass = v_cmd[15:13]; rxf = v_cmd[12:10]; ext = v_cmd[6:0];
      fline = (opclass == 3'd1) || ((opclass == 3'd0 || opclass == 3'd2) && ext >= 7'h40);
      if (kind == "C") begin
        // the conditionals: the BIU's, no microcode
        c_pred = v_cmd[5:0]; c_cc = v_fpsr[27:24];
        #1;
        if (c_bsun) g_fpsr = v_fpsr | 32'h0000_8080;
        if (c_bsun && v_fpcr[15]) begin
          g_vector = 8'd48; g_when = 4'd1;
        end else
          g_store = {95'd0, c_taken};
      end else if (fline) begin
        g_vector = 8'h0B; g_when = 4'd1;
      end else begin
        zero_src = 1'b0; u_is_fp = 1'b0; u_fmt = rxf; u_operand = v_operand; operand = v_operand;
        if (opclass == 3'd0) begin
          entry_idx = {4'd0, ext[5:0]};
          fp_read(rxf, tmp); u_is_fp = 1'b1; u_fp = tmp;
        end else if (opclass == 3'd2 && rxf == 3'd7) begin
          entry_idx = 10'h200; zero_src = 1'b1;
        end else if (opclass == 3'd2) begin
          entry_idx = {1'b0, rxf + 3'd1, ext[5:0]};
        end else begin
          entry_idx = 10'h208 + rxf;
          fp_read(v_cmd[9:7], tmp); u_is_fp = 1'b1; u_fp = tmp;
          operand = {64'd0, v_dreg};
        end
        cmd = v_cmd;
        start = 1'b1;
        wait (busy);
        #1 start = 1'b0;
        wait (!busy);
        @(posedge clk); #1;
        ran = 1'b1;
        g_clocks = clocks;
        fp_read(3'd2, g_ry);
        fp_read(3'd5, g_rc);
        g_fpsr = fpsr;
        g_vector = fpu_trapvec(fpsr, fpcr);
        g_when = (g_vector == 8'd0) ? 4'd0 : (opclass == 3'd3) ? 4'd2 : 4'd1;
        g_store = (opclass == 3'd3) ? obuf : 96'd0;
        if (g_vector == 8'd54 || g_vector == 8'd52 || g_vector == 8'd50 || g_vector == 8'd53 ||
            g_vector == 8'd51 || (opclass == 3'd3 && g_vector == 8'd49 && (fpsr[12] || fpsr[11])))
          g_xop = exop;
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("vec=%s", path)) path = "out/fpu_rtl.vec";
    if (!$value$plusargs("only=%s", only)) only = "";
    if (!$value$plusargs("first=%d", first)) first = 0;
    if (!$value$plusargs("count=%d", count)) count = 1 << 30;
    if (!$value$plusargs("show=%d", show)) show = 10;
    if (!$value$plusargs("trace=%d", trace_n)) trace_n = -1;
    fd = $fopen(path, "r");
    if (fd == 0) begin $display("FAIL cannot open %0s", path); $finish; end
    repeat (4) @(posedge clk);
    reset = 1'b0;
    @(posedge clk); #1;
    n = 0; npass = 0; nfail = 0; nclk = 0; nskip = 0; shown = 0;
    while (!$feof(fd)) begin
      c = $fgetc(fd);
      if (c == "#") begin
        r = $fgets(line, fd);
      end else if (c != -1 && c != "\n") begin
        r = $ungetc(c, fd);
        r = $fscanf(fd, "%s %c %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    group, kind, v_cmd, v_fpcr, v_fpsr, v_rx, v_ry, v_rc, v_operand, v_dreg,
                    w_ry, w_rc, w_fpsr, w_vector, w_when, w_store, w_xop, v_clocks);
        if (r != 18) begin
          $display("FAIL line %0d: %0d fields", n + 1, r);
          $finish;
        end
        idx = n;
        n = n + 1;
        if (idx < first || idx >= first + count || (only != "" && group != only)) begin
          nskip = nskip + 1;
        end else begin
          tracing = (idx == trace_n);
          run_vector;
          tracing = 1'b0;
          bad = (g_ry !== w_ry) || (g_rc !== w_rc) || (g_fpsr !== w_fpsr) || (g_vector !== w_vector) ||
                (g_when !== w_when) || (g_store !== w_store) || (g_xop !== w_xop);
          if (bad) nfail = nfail + 1; else npass = npass + 1;
          if (ran && g_clocks !== v_clocks) nclk = nclk + 1;
          if ((bad || (ran && g_clocks !== v_clocks)) && shown < show) begin
            shown = shown + 1;
            $display("FAIL vector %0d (%0s %c %h):", idx, group, kind, v_cmd);
            if (g_ry !== w_ry)         $display("    ry     want %h  got %h", w_ry, g_ry);
            if (g_rc !== w_rc)         $display("    rc     want %h  got %h", w_rc, g_rc);
            if (g_fpsr !== w_fpsr)     $display("    fpsr   want %h  got %h", w_fpsr, g_fpsr);
            if (g_vector !== w_vector) $display("    vector want %h  got %h", w_vector, g_vector);
            if (g_when !== w_when)     $display("    when   want %h  got %h", w_when, g_when);
            if (g_store !== w_store)   $display("    store  want %h  got %h", w_store, g_store);
            if (g_xop !== w_xop)       $display("    xop    want %h  got %h", w_xop, g_xop);
            if (ran && g_clocks !== v_clocks)
                                       $display("    clocks want %0d  got %0d", v_clocks, g_clocks);
          end
          if (err) begin
            $display("FAIL vector %0d: the APU raised err (a SimError)", idx);
            $display("==== FAIL");
            $finish;
          end
        end
        if (n % 2000 == 0) $display("... %0d vectors", n);
      end
    end
    $display("vectors %0d: %0d pass, %0d fail, %0d with other clocks, %0d skipped",
             n, npass, nfail, nclk, nskip);
    if (nfail == 0 && nclk == 0 && npass > 0) $display("==== PASS");
    else $display("==== FAIL");
    $finish;
  end
endmodule
