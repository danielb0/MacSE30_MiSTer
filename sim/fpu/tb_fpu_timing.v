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
//     tail   from the release to the FPU's end;
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
    .NSEL_HEX("../../rtl/fpu/ucode/ucode.nsel.hex")
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
  reg  [31:0] op_long [0:2];
  integer     t_rel;
  task cp_gen(input [15:0] c);
    reg [15:0] p;
    integer i, n, len, it;
    reg done;
    begin
      bus(1'b0, 5'h0A, {c, 16'd0});
      done = 1'b0; it = 0;
      while (!done && it < 100000) begin
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
  localparam [79:0] X_075 = 80'h3FFE_C000000000000000, X_225 = 80'h4000_9000000000000000,
                    X_1   = 80'h3FFF_8000000000000000;
  integer t0, tot, tail, t_l, t_i, head;
  // the FSIN's end: the APU's busy falling with FSIN's command in it
  integer t_fsin_end;
  always @(posedge clk) if (dut.apu_was_busy && !dut.apu_busy && dut.acmd == 16'h000E) t_fsin_end = hc;
  reg [8*12-1:0] nm, onlyname;
  task setup;
    begin
      null_restore;
      load_fp(3'd0, X_1); load_fp(3'd1, X_075); load_fp(3'd2, X_225);
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
        cp_gen(c);
        wait_quiet;
        tot  = ((t_quiet > t_rel ? t_quiet : t_rel) - t0) / 2;
        tail = (t_quiet > t_rel) ? (t_quiet - t_rel) / 2 : 0;
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

  initial begin
    if (!$value$plusargs("only=%s", onlyname)) onlyname = "";
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
