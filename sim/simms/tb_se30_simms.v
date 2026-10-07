// tb_se30_simms: the SE/30 ROM's RAM sizing, run against se30_simms
// (plan 13.4).
//
// The sizing is the ROM's own, step for step as read in plan 13.4.1:
//   phase 1 ($408035A4): (probe MB, RAMSIZ) = (32, 11), (8, 10), (2, 01),
//     (1, 00); the first probe that passes keeps its RAMSIZ;
//   phase 2 ($408035E0): the size table at $4080366E with the reference
//     addresses at $40803682; the size is the first entry whose probe
//     fails (128 MB if none);
//   the probe ($40803610): CLR.L (R); eight times: pattern to S MB, fail if
//     (R) changed, $FFFFFFFF to $4 twice, read back, pass if any byte lane
//     matches; pattern rotated left by 1.
// GLUE's ram_addr is its own expression (se30_glue.v, "RAM, ROM"); the
// SDRAM is a longword array; a read hands the CPU all ones when the module
// flags an empty bank, as se30_machine.v does.
//
// What it proves:
//   1. 8 MB: the ROM sets RAMSIZ 01 and finds 8 MB.
//   2. 16 MB: the ROM sets RAMSIZ 10 and finds 16 MB.
//   3. 8 MB at RAMSIZ 01: every address maps to ram_addr[20:0], as before
//      the module (a sweep of every bit plus random addresses).
//   4. 16 MB: bank B keeps nothing and reads all ones; bank A aliases at
//      16 MB.
`timescale 1ns/1ps

module tb_se30_simms;
  reg         clk = 0;
  always #5 clk = ~clk;

  reg         big;
  reg   [1:0] ramsiz;
  reg  [31:0] cpu_addr;
  reg         start = 0, sel = 1;
  wire [24:0] ram_addr = (ramsiz == 2'd0) ? {6'b0, cpu_addr[20:2]} :      // se30_glue.v
                         (ramsiz == 2'd1) ? {4'b0, cpu_addr[22:2]} :
                         (ramsiz == 2'd2) ? {2'b0, cpu_addr[24:2]} :
                                            cpu_addr[26:2];
  wire [21:0] phys;
  wire        empty, empty_q;

  se30_simms dut (.clk(clk), .big(big), .ramsiz(ramsiz), .ram_addr(ram_addr), .start(start), .sel(sel),
                  .phys(phys), .empty(empty), .empty_q(empty_q));

  reg [31:0] mem [0:(1 << 22) - 1];

  integer fails = 0, checks = 0;
  task check(input ok, input [8*96-1:0] what);
    begin
      checks = checks + 1;
      if (ok) $display("PASS %0s", what);
      else begin fails = fails + 1; $display("FAIL %0s", what); end
    end
  endtask

  // one RAM cycle, as the machine makes it: start with the address, the
  // write dropped for an empty bank, the read ORed with empty_q
  task wr(input [31:0] a, input [31:0] d);
    begin
      cpu_addr = a; #1;
      @(posedge clk); start <= 1; @(posedge clk); start <= 0;
      if (!empty) mem[phys] = d;
    end
  endtask
  task rd(input [31:0] a, output [31:0] d);
    begin
      cpu_addr = a; #1;
      @(posedge clk); start <= 1; @(posedge clk); start <= 0; #1;
      d = mem[phys] | {32{empty_q}};
    end
  endtask

  // the probe, $40803610: size S MB against the reference R
  task probe(input [7:0] s, input [31:0] r, output ok);
    reg [31:0] d2, d1, a; integer i, lane; reg any;
    begin
      ok = 1;
      d2 = {4{s}};
      a = {4'b0, s, 20'b0};
      wr(r, 32'd0);                                   // CLR.L (A4)
      for (i = 0; i < 8 && ok; i = i + 1) begin
        wr(a, d2);                                    // MOVE.L D2,(A1)
        rd(r, d1);                                    // TST.L (A4)
        if (d1 != 0) ok = 0;
        else begin
          wr(32'h4, 32'hFFFFFFFF);                    // MOVE.L D3,$4.W, twice
          wr(32'h4, 32'hFFFFFFFF);
          rd(a, d1);                                  // MOVE.L (A1),D1
          any = 0;
          for (lane = 0; lane < 4; lane = lane + 1)
            if (d1[8*lane +: 8] == d2[8*lane +: 8]) any = 1;
          if (!any) ok = 0;
          d2 = {d2[30:0], d2[31]};                    // ROL.L #1,D2
        end
      end
    end
  endtask

  // the ROM's sizing, $408035A4: returns the RAMSIZ it leaves and the size
  reg  [7:0] p1_size [0:3];
  reg  [1:0] p1_rs   [0:3];
  reg  [7:0] p2_size [0:13];
  reg [31:0] p2_ref  [0:13];
  task size_ram(output [1:0] rs, output [31:0] mb);
    integer i; reg ok;
    begin
      ok = 0;
      for (i = 0; i < 4 && !ok; i = i + 1) begin
        ramsiz = p1_rs[i];                            // ORA := ORA & $3F | bits
        probe(p1_size[i], 32'd0, ok);                 // A4 = ($4080367E) = 0
      end
      rs = ramsiz;
      mb = 128;
      ok = 1;
      for (i = 0; i < 13 && ok; i = i + 1) begin      // the 14th (128) is not probed
        probe(p2_size[i], p2_ref[i], ok);
        if (!ok) mb = p2_size[i];
      end
    end
  endtask

  reg  [1:0] rs;
  reg [31:0] mb, d, exp_addr;
  integer i, n, errs;

  initial begin
    p1_size[0] = 32; p1_rs[0] = 2'd3;  p1_size[1] = 8; p1_rs[1] = 2'd2;
    p1_size[2] = 2;  p1_rs[2] = 2'd1;  p1_size[3] = 1; p1_rs[3] = 2'd0;
    p2_size[0] = 8'h01; p2_size[1] = 8'h02; p2_size[2] = 8'h04; p2_size[3] = 8'h05;
    p2_size[4] = 8'h08; p2_size[5] = 8'h10; p2_size[6] = 8'h11; p2_size[7] = 8'h14;
    p2_size[8] = 8'h20; p2_size[9] = 8'h40; p2_size[10] = 8'h41; p2_size[11] = 8'h44;
    p2_size[12] = 8'h50; p2_size[13] = 8'h80;
    for (i = 0; i < 14; i = i + 1) p2_ref[i] = 0;
    p2_ref[3] = 32'h00400000;
    p2_ref[6] = 32'h01000000; p2_ref[7] = 32'h01000000;
    p2_ref[10] = 32'h04000000; p2_ref[11] = 32'h04000000; p2_ref[12] = 32'h04000000;

    // 1. 8 MB
    for (i = 0; i < (1 << 22); i = i + 1) mem[i] = 32'h5A5A5A5A;
    big = 0; ramsiz = 2'd3;                          // RAMSIZ undriven reads 11
    size_ram(rs, mb);
    $display("     8 MB: RAMSIZ %0d, %0d MB", rs, mb);
    check(rs == 2'd1, "1. 8 MB: the ROM sets RAMSIZ 01 (4 MB banks)");
    check(mb == 8,    "1. ... and finds 8 MB");

    // 2. 16 MB
    for (i = 0; i < (1 << 22); i = i + 1) mem[i] = 32'h5A5A5A5A;
    big = 1; ramsiz = 2'd3;
    size_ram(rs, mb);
    $display("     16 MB: RAMSIZ %0d, %0d MB", rs, mb);
    check(rs == 2'd2, "2. 16 MB: the ROM sets RAMSIZ 10 (16 MB banks)");
    check(mb == 16,   "2. ... and finds 16 MB");

    // 3. 8 MB at RAMSIZ 01 maps as ram_addr[20:0]
    big = 0; ramsiz = 2'd1; errs = 0; n = 0;
    for (i = 2; i < 32; i = i + 1) begin
      cpu_addr = 32'h1 << i; #1; n = n + 1;
      if (phys != {1'b0, ram_addr[20:0]} || empty) errs = errs + 1;
    end
    for (i = 0; i < 100000; i = i + 1) begin
      cpu_addr = $random; #1; n = n + 1;
      if (phys != {1'b0, ram_addr[20:0]} || empty) errs = errs + 1;
    end
    $display("     %0d addresses, %0d differ", n, errs);
    check(errs == 0, "3. 8 MB, RAMSIZ 01: every address maps as ram_addr[20:0], never empty");

    // 4. 16 MB at RAMSIZ 10: bank B empty, bank A aliases at 16 MB
    big = 1; ramsiz = 2'd2;
    wr(32'h00000100, 32'h11111111);
    wr(32'h01000100, 32'h22222222);                   // bank B: lost
    rd(32'h01000100, d);
    check(d == 32'hFFFFFFFF, "4. 16 MB: bank B reads all ones");
    rd(32'h00000100, d);
    check(d == 32'h11111111, "4. ... and its write did not land in bank A");
    rd(32'h02000100, d);                              // A25: above both banks
    check(d == 32'h11111111, "4. bank A repeats above the two banks (A25 ignored)");
    rd(32'h01000100, d);                              // empty_q set ...
    sel = 0; @(posedge clk); start <= 1; @(posedge clk); start <= 0; sel = 1; #1;   // ... a ROM access
    check(!empty_q, "4. a ROM access after an empty-bank read clears the all-ones flag (one data bus)");
    wr(32'h00FFFFFC, 32'h33333333);
    rd(32'h00FFFFFC, d);
    check(d == 32'h33333333 && phys == 22'h3FFFFF, "4. the top longword of bank A is the top of 16 MB");

    if (fails == 0) $display("==== PASS: %0d checks", checks);
    else            $display("==== FAIL: %0d of %0d checks", fails, checks);
    $finish;
  end
endmodule
