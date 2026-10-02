// tb_fpu_timing.v - item 7e-3 (SE30_PLAN.md 8.9.6): the MC68882's clocks
// under UM Section 8's reference conditions, set against Table 8-3.
//
// WHAT IT MEASURES
//   The chip (se30_fpu) driven by an MC68020 on the same clock (UM 8.1): a
//   bus cycle is S0-S5, three clocks with no wait states; the strobe rises
//   half a clock in, DSACK is sampled at the falling edges from S2 on, and
//   the cycle ends a clock and a half after the edge that saw it.  The chip's
//   own synchronous response and save reads then take five clocks, the
//   manual's figure.  Each instruction starts with a three-clock prefetch
//   (Figure 8-2: PREFETCH, WRITE COMMAND, READ RESPONSE - the 11 clocks of
//   interface overhead) and its dialog runs back to back, the PC passed and
//   the operand moved as the primitives ask.  For each:
//     total  from the prefetch to the later of the MPU's release (the end of
//            the dialog's last cycle) and the FPU's end (the APU and the CU
//            idle, a CU move written);
//     tail   from the instruction's release - the later of the MPU's (the
//            end of its last dialog cycle) and the CU's (the hand-off to the
//            APU: on the 68882 the next instruction, FP or MPU, may begin
//            only then, UM 8.2) - to the FPU's end;
//     head   UM 8.2's "begins when the instruction is initiated by the MPU,
//            and ends when [it] can no longer operate under the tail of a
//            previous instruction": the same instruction issued after an
//            FSIN (a 373-clock tail), head = total - (its end - the FSIN's end).
//   Printed one line an instruction, with Table 8-3's H, T and total beside
//   (table8_3.csv, transcribed from the page images: plan 8.6.13).  It
//   measures; it passes or fails nothing - 7e-3 decides what must equal what.
//
// PLUSARGS  +only=NAME  one row

`timescale 1ns/1ps

module tb_fpu_timing;
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
    .NSEL_HEX("../../rtl/fpu/ucode/ucode.nsel.hex"),
    .CVT_HEX("../../rtl/fpu/ucode/ucode.cvt.hex"), .CVSEL_HEX("../../rtl/fpu/ucode/ucode.cvsel.hex"), .TADJ_HEX("../../rtl/fpu/ucode/ucode.tadj.hex")
  ) dut (
    .clk(clk), .ce(ce), .reset(reset),
    .cs(cs), .rw(rw), .a(a), .din(din), .dout(dout), .dsack_n(dsack_n),
    .dbg_exop(dbg_exop), .dbg_clocks(dbg_clocks), .dbg_err(dbg_err), .dbg_state(dbg_state));

  // -- time, in FPU clocks (two clk) --------------------------------------------------
  integer hc = 0;                  // half clocks since the start
  always @(posedge clk) hc <= hc + 1;
  task rise;                       // to the next FPU rising edge (ce high before the edge)
    begin @(posedge clk); while (ce !== 1'b1) @(posedge clk); end
  endtask

  // the FPU's end: nothing running in the APU or the CU, no move in progress
  wire fpu_quiet = !dut.apu_busy && !dut.apu_was_busy && !dut.cu_busy && !dut.apu_start &&
                   !dut.cu_v && (dut.mi == 2'd0) && !dut.fpb_we && !dut.hv;
  integer t_quiet;                 // the half clock the FPU last went quiet
  integer t_cu;                    // ... the instruction last left the CU (a hand-off or a start)
  reg     cub_prev = 1'b0;
  always @(posedge clk) begin
    if (dut.cu_busy && !cub_prev) t_cu = hc;
    cub_prev <= dut.cu_busy;
  end
  reg     q_prev = 1'b1;
  always @(posedge clk) begin
    if (fpu_quiet && !q_prev) t_quiet = hc;
    q_prev <= fpu_quiet;
  end

  // -- one MC68020 bus cycle: S0 at a rising edge, the strobe at S1, DSACK
  //    sampled at the falling edges from S2, the end 1.5 clocks after -----------------
  reg  [31:0] rd;
  task bus(input rw_, input [4:0] addr, input [31:0] wdata);
    integer w;
    begin
      rise;                                               // S0
      @(posedge clk); #1;                                 // S1: the strobe
      rw = rw_; a = addr; din = wdata; cs = 1'b1;
      @(posedge clk); @(posedge clk);                     // S2's falling edge
      w = 0;
      while (dsack_n == 2'b11 && w < 400) begin @(posedge clk); @(posedge clk); w = w + 1; end
      rd = dout;                                          // (latched at S4 in the chip's terms)
      @(posedge clk); @(posedge clk); #1;                 // S4's falling edge: the strobe off
      cs = 1'b0;
      @(posedge clk);                                     // S5 ends at the next rising edge
    end
  endtask
  integer t_pf;                    // the prefetch's S0
  task prefetch; begin rise; t_pf = hc; @(posedge clk); @(posedge clk); @(posedge clk); @(posedge clk); @(posedge clk); end endtask

  // -- the MPU's side of a general instruction ---------------------------------------
  // UM 8.4: "the main processor reads the response register at exactly the
  // moment when the FPCP is prepared to return a service request primitive"
  // - after a $8900 in a wait (a store converting, an integer held, FMOVECR
  // to its end) the next read starts when the chip is ready, not at the
  // next of a polling MPU's reads, five clocks apart (+poll: as a real MPU)
  reg         poll;
  reg  [15:0] gcmd;
  wire [7:0]  st_need = (gcmd[12:10] == 3'd1) ? dut.MO_S : (gcmd[12:10] == 3'd5) ? dut.MO_D : dut.MO_X;
  wire        fpu_ready = (dut.bst == 5'd7)  ? (dut.cu_st ? (dut.mv_el >= st_need) : dut.conv_ok)
                        : (dut.bst == 5'd20) ? (!dut.cu_v && dut.hold_ok)
                        : (dut.bst == 5'd5)  ? dut.hold_ok : 1'b1;
  reg  [31:0] op_long [0:2];
  integer     t_rel;
  task cp_gen(input [15:0] c);
    reg [15:0] p;
    integer i, n, len, it;
    reg done;
    begin
      bus(1'b0, 5'h0A, {c, 16'd0});
      gcmd = c;
      done = 1'b0; it = 0;
      while (!done && it < 100000) begin
        if (!poll && it > 0 && p == 16'h8900)
          while (!fpu_ready) @(posedge clk);              // (the ideal read, 8.4)
        bus(1'b1, 5'h00, 32'd0);
        p = rd[31:16]; it = it + 1;
        if (p[14]) bus(1'b0, 5'h18, 32'h0000_1000);
        if (p[13] == 1'b0 && p[12:9] == 4'b0100) begin    // null
          if (!p[15]) done = 1'b1;
        end else if (p[12:11] == 2'b10) begin             // evaluate and transfer
          len = p[7:0]; n = (len + 3) / 4;
          for (i = 0; i < n; i = i + 1)
            if (!p[13]) bus(1'b0, 5'h10, (len == 1) ? {op_long[0][7:0], 24'd0} :
                                         (len == 2) ? {op_long[0][15:0], 16'd0} : op_long[i]);
            else bus(1'b1, 5'h10, 32'd0);
          if (!p[15]) done = 1'b1;
        end else if (p[12:8] == 5'b01100) bus(1'b0, 5'h10, 32'd0);   // Dn (a dynamic k)
        else begin $display("  unexpected primitive %h", p); done = 1'b1; end
      end
      t_rel = hc;
    end
  endtask

  task null_restore; begin bus(1'b0, 5'h06, 32'd0); bus(1'b1, 5'h06, 32'd0); end endtask
  task load_fp(input [2:0] r, input [79:0] v);       // FMOVEM.X of one register in
    begin
      bus(1'b0, 5'h0A, {16'hD000 | (16'h0080 >> r), 16'd0});
      bus(1'b1, 5'h00, 32'd0);                           // $810C
      bus(1'b1, 5'h14, 32'd0);
      bus(1'b0, 5'h10, {v[79:64], 16'd0}); bus(1'b0, 5'h10, v[63:32]); bus(1'b0, 5'h10, v[31:0]);
      bus(1'b1, 5'h00, 32'd0);                           // $0802
    end
  endtask
  task wait_quiet; begin rise; while (!fpu_quiet) rise; repeat (4) rise; end endtask

  // -- one row: alone (total, tail) and behind an FSIN (head) -------------------------
  // the typical operands (8.9.7 point 6): source 3.0 and destination 2.25 -
  // normalized, the same exponent (FADD's base case), the memory sources' 3.0
  localparam [79:0] X_075 = 80'h4000_C000000000000000, X_225 = 80'h4000_9000000000000000,
                    X_1   = 80'h3FFF_8000000000000000;
  integer t0, tot, tail, t_l, t_i, head;
  // the FSIN's end: the APU's busy falling with FSIN's command in it
  integer t_fsin_end;
  always @(posedge clk) if (dut.apu_was_busy && !dut.apu_busy && dut.acmd == 16'h000E) t_fsin_end = hc;
  reg [8*12-1:0] nm, onlyname;
  reg [79:0] src_x = 80'h4000_C000000000000000, dst_x = 80'h4000_9000000000000000;
  task setup;
    begin
      null_restore;
      load_fp(3'd0, X_1); load_fp(3'd1, src_x); load_fp(3'd2, dst_x);
      wait_quiet;
    end
  endtask
  task row(input [8*12-1:0] name, input [8*8-1:0] fmt, input [15:0] c,
           input [31:0] o0, input [31:0] o1, input [31:0] o2);
    begin
      if (onlyname == "" || onlyname == name) begin
        op_long[0] = o0; op_long[1] = o1; op_long[2] = o2;
        // alone
        setup;
        prefetch; t0 = t_pf;
        t_cu = 0;
        cp_gen(c);
        wait_quiet;
        tot  = ((t_quiet > t_rel ? t_quiet : t_rel) - t0) / 2;
        t_l  = (t_cu > t_rel) ? t_cu : t_rel;               // the release, as UM 8.2 means it
        if (t_cu == 0) t_l = (t_quiet > t_rel) ? t_quiet : t_rel;   // (a CU move: no APU)
        tail = (t_quiet > t_l) ? (t_quiet - t_l) / 2 : 0;
        // behind an FSIN FP0 (its tail covers any head)
        setup;
        prefetch; cp_gen(16'h000E);                       // FSIN FP0
        prefetch; cp_gen(c);
        wait_quiet;
        t_i = (t_quiet > t_rel ? t_quiet : t_rel);
        // the FSIN's own end: when the APU started this instruction's work
        head = (t_i <= t_fsin_end) ? tot : tot - (t_i - t_fsin_end) / 2;   // (all of it under the FSIN: fully concurrent)
        $display("TIMING %-12s %-8s total %5d  tail %5d  head %5d", name, fmt, tot, tail, head);
      end
    end
  endtask

  // one operation in every source format: FP1, S, D, X, L (B and W are L's
  // column), its typical source v (0: 3.0, 1: 2.5 - a fraction, for FINT; 2:
  // 0.5 - inside the inverse functions' domain) and destination (2.25, or
  // 7.25 for FMOD and FREM: a one-chunk quotient)
  task op5(input [8*12-1:0] name, input [6:0] om, input [1:0] v, input big);
    begin
      src_x = (v == 2'd0) ? 80'h4000_C000000000000000 : (v == 2'd1) ? 80'h4000_A000000000000000
                                                      : 80'h3FFE_8000000000000000;
      dst_x = big ? 80'h4001_E800000000000000 : 80'h4000_9000000000000000;
      row(name, "FPm", 16'h0500 | om, 0, 0, 0);
      row(name, "S", 16'h4500 | om, (v == 2'd0) ? 32'h4040_0000 : (v == 2'd1) ? 32'h4020_0000 : 32'h3F00_0000, 0, 0);
      row(name, "D", 16'h5500 | om, (v == 2'd0) ? 32'h4008_0000 : (v == 2'd1) ? 32'h4004_0000 : 32'h3FE0_0000, 0, 0);
      row(name, "X", 16'h4900 | om, (v == 2'd2) ? 32'h3FFE_0000 : 32'h4000_0000,
          (v == 2'd0) ? 32'hC000_0000 : (v == 2'd1) ? 32'hA000_0000 : 32'h8000_0000, 0);
      row(name, "L", 16'h4100 | om, (v == 2'd2) ? 32'd1 : 32'd3, 0, 0);
      // packed: 3.0E0, 2.5E0, 5.0E-1
      row(name, "P", 16'h4D00 | om, (v == 2'd2) ? 32'h4001_0005 : (v == 2'd1) ? 32'h0000_0002 : 32'h0000_0003,
          (v == 2'd1) ? 32'h5000_0000 : 32'd0, 0);
      src_x = 80'h4000_C000000000000000; dst_x = 80'h4000_9000000000000000;
    end
  endtask

  initial begin
    if (!$value$plusargs("only=%s", onlyname)) onlyname = "";
    poll = $test$plusargs("poll");
    if ($test$plusargs("matrix")) begin
      repeat (4) @(posedge clk); reset = 1'b0; repeat (40) @(posedge clk);
      op5("FABS", 7'h18, 0, 0);    op5("FNEG", 7'h1A, 0, 0);    op5("FADD", 7'h22, 0, 0);
      op5("FSUB", 7'h28, 0, 0);    op5("FMUL", 7'h23, 0, 0);    op5("FDIV", 7'h20, 0, 0);
      op5("FCMP", 7'h38, 0, 0);    op5("FTST", 7'h3A, 0, 0);    op5("FSQRT", 7'h04, 0, 0);
      op5("FINT", 7'h01, 1, 0);    op5("FINTRZ", 7'h03, 1, 0);  op5("FGETEXP", 7'h1E, 0, 0);
      op5("FGETMAN", 7'h1F, 0, 0); op5("FSCALE", 7'h26, 0, 0);  op5("FSGLMUL", 7'h27, 0, 0);
      op5("FSGLDIV", 7'h24, 0, 0); op5("FMOD", 7'h21, 0, 1);    op5("FREM", 7'h25, 0, 1);
      op5("FSIN", 7'h0E, 0, 0);    op5("FCOS", 7'h1D, 0, 0);    op5("FTAN", 7'h0F, 0, 0);
      op5("FSINCOS", 7'h33, 0, 0); op5("FATAN", 7'h0A, 0, 0);   op5("FASIN", 7'h0C, 2, 0);
      op5("FACOS", 7'h1C, 2, 0);   op5("FATANH", 7'h0D, 2, 0);  op5("FSINH", 7'h02, 0, 0);
      op5("FCOSH", 7'h19, 0, 0);   op5("FTANH", 7'h09, 0, 0);   op5("FETOX", 7'h10, 0, 0);
      op5("FETOXM1", 7'h08, 0, 0); op5("FTWOTOX", 7'h11, 0, 0); op5("FTENTOX", 7'h12, 0, 0);
      op5("FLOGN", 7'h14, 0, 0);   op5("FLOGNP1", 7'h06, 0, 0); op5("FLOG10", 7'h15, 0, 0);
      op5("FLOG2", 7'h16, 0, 0);   op5("FMOVE", 7'h00, 0, 0);
      $display("TIMING done");
      $finish;
    end
    repeat (4) @(posedge clk);
    reset = 1'b0;
    repeat (40) @(posedge clk);
    // register to register (FP1 = 0.75 source, FP2 = 2.25 destination)
    row("FMOVE",   "FPm", 16'h0500, 0, 0, 0);
    row("FABS",    "FPm", 16'h0518, 0, 0, 0);
    row("FNEG",    "FPm", 16'h051A, 0, 0, 0);
    row("FADD",    "FPm", 16'h0522, 0, 0, 0);
    row("FSUB",    "FPm", 16'h0528, 0, 0, 0);
    row("FMUL",    "FPm", 16'h0523, 0, 0, 0);
    row("FDIV",    "FPm", 16'h0520, 0, 0, 0);
    row("FCMP",    "FPm", 16'h0538, 0, 0, 0);
    row("FTST",    "FPm", 16'h053A, 0, 0, 0);
    row("FSQRT",   "FPm", 16'h0504, 0, 0, 0);
    row("FINT",    "FPm", 16'h0501, 0, 0, 0);
    row("FINTRZ",  "FPm", 16'h0503, 0, 0, 0);
    row("FGETEXP", "FPm", 16'h051E, 0, 0, 0);
    row("FGETMAN", "FPm", 16'h051F, 0, 0, 0);
    row("FSCALE",  "FPm", 16'h0526, 0, 0, 0);
    row("FSGLMUL", "FPm", 16'h0527, 0, 0, 0);
    row("FSGLDIV", "FPm", 16'h0524, 0, 0, 0);
    row("FMOD",    "FPm", 16'h0521, 0, 0, 0);
    row("FREM",    "FPm", 16'h0525, 0, 0, 0);
    row("FSIN",    "FPm", 16'h050E, 0, 0, 0);
    row("FCOS",    "FPm", 16'h051D, 0, 0, 0);
    row("FTAN",    "FPm", 16'h050F, 0, 0, 0);
    row("FSINCOS", "FPm", 16'h0533, 0, 0, 0);
    row("FATAN",   "FPm", 16'h050A, 0, 0, 0);
    row("FASIN",   "FPm", 16'h050C, 0, 0, 0);
    row("FACOS",   "FPm", 16'h051C, 0, 0, 0);
    row("FATANH",  "FPm", 16'h050D, 0, 0, 0);
    row("FSINH",   "FPm", 16'h0502, 0, 0, 0);
    row("FCOSH",   "FPm", 16'h0519, 0, 0, 0);
    row("FTANH",   "FPm", 16'h0509, 0, 0, 0);
    row("FETOX",   "FPm", 16'h0510, 0, 0, 0);
    row("FETOXM1", "FPm", 16'h0508, 0, 0, 0);
    row("FTWOTOX", "FPm", 16'h0511, 0, 0, 0);
    row("FTENTOX", "FPm", 16'h0512, 0, 0, 0);
    row("FLOGN",   "FPm", 16'h0514, 0, 0, 0);
    row("FLOGNP1", "FPm", 16'h0506, 0, 0, 0);
    row("FLOG10",  "FPm", 16'h0515, 0, 0, 0);
    row("FLOG2",   "FPm", 16'h0516, 0, 0, 0);
    row("FMOVECR", "ROM", 16'h5D00, 0, 0, 0);
    // FADD <ea>,FP2 in every format (3.0)
    row("FADD",    "L",   16'h4122, 32'h0000_0003, 0, 0);
    row("FADD",    "W",   16'h5122, 32'h0000_0003, 0, 0);
    row("FADD",    "B",   16'h5922, 32'h0000_0003, 0, 0);
    row("FADD",    "S",   16'h4522, 32'h4040_0000, 0, 0);
    row("FADD",    "D",   16'h5522, 32'h4008_0000, 32'h0, 0);
    row("FADD",    "X",   16'h4922, 32'h4000_0000, 32'hC000_0000, 32'h0);
    row("FADD",    "P",   16'h4D22, 32'h0000_0003, 32'h0, 32'h0);
    // FMOVE <ea>,FP2
    row("FMOVE",   "L",   16'h4100, 32'h0000_0003, 0, 0);
    row("FMOVE",   "S",   16'h4500, 32'h4040_0000, 0, 0);
    row("FMOVE",   "D",   16'h5500, 32'h4008_0000, 32'h0, 0);
    row("FMOVE",   "X",   16'h4900, 32'h4000_0000, 32'hC000_0000, 32'h0);
    row("FMOVE",   "P",   16'h4D00, 32'h0000_0003, 32'h0, 32'h0);
    // FMOVE FP2,<ea>
    row("FMOVEout","L",   16'h6100, 0, 0, 0);
    row("FMOVEout","S",   16'h6500, 0, 0, 0);
    row("FMOVEout","D",   16'h7500, 0, 0, 0);
    row("FMOVEout","X",   16'h6900, 0, 0, 0);
    row("FMOVEout","P",   16'h6D00, 0, 0, 0);
    $display("TIMING done");
    $finish;
  end
endmodule
