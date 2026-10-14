// tb_insn_probe.v - the jump-table loader's instructions on the kernel
// (SE30_PLAN.md KNOWN ISSUES 20; the program and its checks: gen_program.py).
//
// WHAT THIS LOOKS FOR
//   On the board (compiles 62 and 64, 2026-10-14) A/UX's jump-table loader -
//   code startmac builds on its stack - loses D1/A1 between saving them
//   around its callback and its next ADDA, with no fault in between and
//   with the caches on or off.  Each of its unusual instructions runs here
//   with operands that tell the right result from the plausible wrong ones;
//   the program stores the results and the CCR, the bench compares them
//   with expect.txt (slot, value, mask) when the end marker is written.
//
// THE DRIVER
//   sim/rtr_fc's: the kernel alone, clkena_in high, a 64K-word memory
//   answering as a 32-bit port combinationally.  No PMMU, no caches: the
//   kernel's own semantics.

`timescale 1ns/1ps

module tb_insn_probe;

  reg clk = 0;
  always #5 clk = ~clk;
  reg nReset = 0;

  wire [31:0] data_in, data_write, addr_out;
  wire        nWr, nUDS, nLDS;
  wire [1:0]  busstate, siz;
  wire [2:0]  FC;

  TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2), .MUL_Mode(2), .DIV_Mode(2),
    .BitField(2), .BarrelShifter(2), .MUL_Hardware(1), .DATA_WIDTH(32)
  ) dut (
    .clk(clk), .nReset(nReset), .clkena_in(1'b1), .beat_valid(1'b1),
    .data_in(data_in), .dsack(2'b00), .IPL(3'b111), .IPL_autovector(1'b1), .berr(1'b0), .CPU(2'b10),
    .addr_out(addr_out), .data_write(data_write), .siz(siz), .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
    .busstate(busstate), .FC(FC),
    .pmmu_walker_ack(1'b0), .pmmu_walker_data(32'd0), .pmmu_walker_berr(1'b0),
    .debug_memmask(), .debug_regfile_d1(), .debug_data_read(), .debug_last_data_read(), .debug_last_opc_read()
  );

  // ---------------------------------------------------------------- memory
  reg [15:0] mem [0:65535];
  wire [15:0] w_even = mem[{addr_out[16:2], 1'b0}];
  wire [15:0] w_odd  = mem[{addr_out[16:2], 1'b1}];
  assign data_in = {w_even, w_odd};
  wire [7:0] lane0 = data_write[31:24], lane1 = data_write[23:16], lane2 = data_write[15:8], lane3 = data_write[7:0];
  wire [2:0] siz_n = (siz == 2'b00) ? 3'd4 : {1'b0, siz};

  integer pass = 0, fails = 0, beats = 0;
  reg done = 0; integer tail = -1;
  always @(negedge clk) if (nReset && !done) begin
`ifdef TRACE
    if (busstate != 2'b01)
      $display("t=%0t bs=%b addr=%08x siz=%b wr=%b FC=%0d din=%08x dout=%08x", $time, busstate, addr_out, siz, !nWr, FC, data_in, data_write);
`endif
    if (busstate == 2'b10 || busstate == 2'b11) beats = beats + 1;
    if (busstate == 2'b11 && !nWr) begin
      if (addr_out[1:0] == 2'd0)                                   mem[{addr_out[16:2], 1'b0}][15:8] = lane0;
      if (addr_out[1:0] <= 2'd1 && addr_out[1:0] + siz_n > 1)      mem[{addr_out[16:2], 1'b0}][7:0]  = lane1;
      if (addr_out[1:0] <= 2'd2 && addr_out[1:0] + siz_n > 2)      mem[{addr_out[16:2], 1'b1}][15:8] = lane2;
      if (addr_out[1:0] + siz_n > 3)                               mem[{addr_out[16:2], 1'b1}][7:0]  = lane3;
      if (addr_out == 32'h3FFC && tail < 0) tail = 20;
    end
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
  end

  // ---------------------------------------------------------------- run
  integer i, fd, r; reg [31:0] slot, want, mask, v; reg [8*200-1:0] what;
  initial begin
    $readmemh("program.hex", mem);
    repeat (20) @(posedge clk);
    nReset = 1;
    i = 0;
    while (!done && i < 200000) begin @(posedge clk); i = i + 1; end
    v = {mem[32'h3FFC >> 1], mem[32'h3FFE >> 1]};
    if (!done) begin fails = fails + 1; $display("FAIL: the end marker was never written"); end
    else if (v != 32'h600D600D) begin fails = fails + 1; $display("FAIL: an exception (marker %08x)", v); end
    fd = $fopen("expect.txt", "r");
    mask = 32'hFFFFFFFF;
    while ($fscanf(fd, "%h %h", slot, want) == 2) begin
      r = $fgets(what, fd);
      while (what[7:0] == 8'h0A || what[7:0] == 8'h0D) what = what >> 8;   // the line's end
      v = {mem[slot[16:1]], mem[slot[16:1] + 1]};
      if ((v & mask) === (want & mask)) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0s - got %08x, want %08x (mask %08x)", what[8*199-1:0], v & mask, want & mask, mask); end
    end
    $fclose(fd);
    if (fails == 0) $display("==== PASS: %0d checks, %0d data beats - the jump-table loader's instructions as the UM has them", pass, beats);
    else $display("==== FAIL: %0d failures, %0d passes", fails, pass);
    $finish;
  end

endmodule
