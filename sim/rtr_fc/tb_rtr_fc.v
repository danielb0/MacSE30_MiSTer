// tb_rtr_fc.v - the function code of RTR's stack pops (KNOWN ISSUES 19).
//
// WHAT THIS PROVES
//   RTR is unprivileged: it pops the CCR word and the PC from the active
//   stack in the address space of the CURRENT privilege level - FC 1 (user
//   data) from the USP in user mode, FC 5 from the supervisor stack in
//   supervisor mode - and takes only the CCR bits of the stacked word (UM
//   3.6, Table 3-14: "(SP) -> CCR; SP+2 -> SP; (SP) -> PC; SP+4 -> SP").
//
//   Found on A/UX 3.1 (2026-10-13): /etc/init's core held a format $B frame
//   at the RTR of its signal-return trampoline - a word read of the user
//   stack with SSW FC = 5, which the kernel's PMMU refused (the user stack
//   is not mapped in supervisor space) - so every process returning from a
//   signal handler died: telinit "Illegal instruction", errdemon exit 0204,
//   the Mac environment's "System" bus error.  The kernel forced the
//   supervisor FC for every rte micro-state, which RTR shares with RTE.
//
//   The program (gen_program.py): a supervisor RTR first (the control:
//   its pops carry FC 5), then MOVE #0,SR and a user RTR whose stacked
//   word is $2715 (S and IPL bits set, CCR $15).  Checked on the bus: the
//   user RTR's two pops ($6FF8 word, $6FFA long) carry FC 1; the fetches
//   and the data beats of the user code after it carry FC 2 and 1; the
//   user code's MOVE CCR,D0 stored $0015 (the high byte was ignored, S
//   stayed clear); the end marker $4E77 reached slot $3000.
//
// THE DRIVER
//   tb_kernel_bus.v's: clkena_in high, a 64K-word memory answering as a
//   32-bit port (DSACK 00) combinationally, one beat per clock, sampled on
//   the falling edge.  No PMMU: the FC is read on the bus, where the real
//   machine's PMMU would read it.

`timescale 1ns/1ps

module tb_rtr_fc;

  reg clk = 0;
  always #5 clk = ~clk;
  reg nReset = 0;

  wire [31:0] data_in, data_write, addr_out;
  wire        nWr, nUDS, nLDS;
  wire [1:0]  busstate, siz;
  wire [2:0]  FC;

  TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(1), .extAddr_Mode(1), .MUL_Hardware(1), .BarrelShifter(2),
    .DATA_WIDTH(32)
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

  // ---------------------------------------------------------------- checks
  integer pass = 0, fails = 0, beats = 0;
  reg done = 0; integer tail = -1;
  reg seen_sup_ccr = 0, seen_sup_pc = 0, seen_usr_ccr = 0, seen_usr_pc = 0, seen_marker = 0;
  task check(input cond, input [8*64-1:0] what);
    begin
      if (cond) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL: %0s - addr %08x busstate %b wr %b FC %0d", what, addr_out, busstate, !nWr, FC); end
    end
  endtask

  always @(negedge clk) if (nReset && !done) begin
`ifdef TRACE
    if (busstate != 2'b01)
      $display("t=%0t bs=%b addr=%08x siz=%b wr=%b FC=%0d din=%08x dout=%08x", $time, busstate, addr_out, siz, !nWr, FC, data_in, data_write);
`endif
    if (busstate == 2'b10 || busstate == 2'b11) beats = beats + 1;
    // the supervisor RTR's pops: $7FFA (CCR word), $7FFC (PC) - FC 5
    if (busstate == 2'b10 && addr_out == 32'h7FFA) begin seen_sup_ccr = 1; check(FC == 3'd5, "supervisor RTR CCR pop with FC 5"); end
    if (busstate == 2'b10 && addr_out == 32'h7FFC) begin seen_sup_pc  = 1; check(FC == 3'd5, "supervisor RTR PC pop with FC 5"); end
    // the user RTR's pops: $6FF8 (CCR word), $6FFA (PC) - FC 1
    if (busstate == 2'b10 && addr_out == 32'h6FF8) begin seen_usr_ccr = 1; check(FC == 3'd1, "user RTR CCR pop with FC 1 (user data)"); end
    if (busstate == 2'b10 && addr_out == 32'h6FFA) begin seen_usr_pc  = 1; check(FC == 3'd1, "user RTR PC pop with FC 1 (user data)"); end
    // the user code after it: fetches FC 2, data FC 1
    if (busstate == 2'b00 && addr_out >= 32'h1100 && addr_out < 32'h1200) check(FC == 3'd2, "user code fetch with FC 2 (user program)");
    if (busstate == 2'b11 && addr_out[31:4] == 28'h300) check(FC == 3'd1, "user code write with FC 1 (user data)");
    // writes land
    if (busstate == 2'b11 && !nWr) begin
      if (addr_out[1:0] == 2'd0)                                   mem[{addr_out[16:2], 1'b0}][15:8] = lane0;
      if (addr_out[1:0] <= 2'd1 && addr_out[1:0] + siz_n > 1)      mem[{addr_out[16:2], 1'b0}][7:0]  = lane1;
      if (addr_out[1:0] <= 2'd2 && addr_out[1:0] + siz_n > 2)      mem[{addr_out[16:2], 1'b1}][15:8] = lane2;
      if (addr_out[1:0] + siz_n > 3)                               mem[{addr_out[16:2], 1'b1}][7:0]  = lane3;
      if (addr_out == 32'h3000 && tail < 0) begin seen_marker = 1; tail = 20; end
    end
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
  end

  // ---------------------------------------------------------------- run
  integer i; reg [31:0] v;
  initial begin
    $readmemh("program.hex", mem);
    repeat (20) @(posedge clk);
    nReset = 1;
    i = 0;
    while (!done && i < 20000) begin @(posedge clk); i = i + 1; end
    check(seen_sup_ccr && seen_sup_pc, "the supervisor RTR popped $7FFA and $7FFC");
    check(seen_usr_ccr && seen_usr_pc, "the user RTR popped $6FF8 and $6FFA");
    check(seen_marker, "the user code ran to its end marker (RTR returned to $1100)");
    v = {mem[32'h3004 >> 1], mem[32'h3006 >> 1]};
    check(v[31:16] == 16'h0015, "MOVE CCR,D0 after the user RTR read $0015 (the stacked word's high byte ignored)");
    v = {mem[32'h3000 >> 1], mem[32'h3002 >> 1]};
    check(v == 32'h00004E77, "slot $3000 holds the end marker");
    if (fails == 0) $display("==== PASS: %0d checks, %0d data beats - RTR pops in the address space of its own privilege level", pass, beats);
    else $display("==== FAIL: %0d failures, %0d passes, %0d data beats", fails, pass, beats);
    $finish;
  end

endmodule
