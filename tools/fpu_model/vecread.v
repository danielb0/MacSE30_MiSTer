// Reads the model's test-vector file the way item 7's bench will (plan
// 8.7.4): every field of every line through $fscanf into registers of its
// width, then prints a count per group and a checksum of each field, which
// run.sh compares with the same sums computed in Python (vecsum.py).  A
// format a Verilog bench cannot read would fail here first.
//
//   iverilog -g2005 -o vecread.vvp vecread.v && vvp vecread.vvp +vec=fpu.vec

`timescale 1ns/1ps
module vecread;
  integer fd, r, n;
  reg [8*16-1:0] group;
  reg [7:0]      kind;
  reg [15:0]     cmd;
  reg [31:0]     fpcr, fpsr, dreg, fpsr2;
  reg [79:0]     rx, ry, rc, ry2, rc2, xop;
  reg [95:0]     operand, store;
  reg [7:0]      vector;
  reg [3:0]      when;
  reg [8*512-1:0] line;
  reg [127:0]    sum [0:16];
  integer        i, c;
  reg [8*256-1:0] path;

  initial begin
    if (!$value$plusargs("vec=%s", path)) path = "fpu.vec";
    fd = $fopen(path, "r");
    if (fd == 0) begin $display("FAIL cannot open %0s", path); $finish; end
    for (i = 0; i < 17; i = i + 1) sum[i] = 0;
    n = 0;
    while (!$feof(fd)) begin
      c = $fgetc(fd);
      if (c == "#") begin
        r = $fgets(line, fd);                   // a comment line
      end else if (c != -1 && c != "\n") begin
        r = $ungetc(c, fd);
        r = $fscanf(fd, "%s %c %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                    group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg,
                    ry2, rc2, fpsr2, vector, when, store, xop);
        if (r != 17) begin
          $display("FAIL line %0d: %0d fields", n + 1, r);
          $finish;
        end
        n = n + 1;
        sum[2]  = sum[2]  + cmd;     sum[3]  = sum[3]  + fpcr;   sum[4]  = sum[4]  + fpsr;
        sum[5]  = sum[5]  + rx;      sum[6]  = sum[6]  + ry;     sum[7]  = sum[7]  + rc;
        sum[8]  = sum[8]  + operand; sum[9]  = sum[9]  + dreg;   sum[10] = sum[10] + ry2;
        sum[11] = sum[11] + rc2;     sum[12] = sum[12] + fpsr2;  sum[13] = sum[13] + vector;
        sum[14] = sum[14] + when;    sum[15] = sum[15] + store;  sum[16] = sum[16] + xop;
        sum[1]  = sum[1]  + (kind == "C");
      end
    end
    $display("vectors %0d", n);
    for (i = 1; i < 17; i = i + 1) $display("sum%0d %h", i, sum[i]);
    $finish;
  end
endmodule
