// tb_kernel_bus.v - the kernel's bus beats held to the oracle of UM 7.2.
//
// WHAT THIS PROVES
//   SE30_PLAN.md 1.14 wrote the 68030's beat contract as a table
//   (beats.txt, from scripts/se30_bus_beats.py, nothing from the kernel).
//   gen_program.py turns it into the beats a fixed program must produce on
//   a port of one width: every byte, word and long operand at every
//   offset, read and written; three- and five-byte bit fields; the reset
//   vector reads.  This bench runs that program on TG68KdotC_Kernel alone,
//   one beat per clock, and checks each data beat against the expected
//   line: the word address, which lanes are strobed, the direction, the
//   bytes on the strobed lanes for a write, and the kernel's own byte mask
//   (memmask) before the beat - the oracle's `mask` column, which for the
//   16-bit port gen_program.py restates in the kernel's word-a-beat
//   convention (its own rule, from the oracle's operand-start mask).
//   At the end it checks the result slots: every read came back as the
//   bytes that were written.
//
//   On the kernel's present 16-bit shape (plan 1.13 step 2 not yet made)
//   the expected beats are the oracle's 16-bit-port rows, so passing here
//   says the oracle and the kernel agree about every 16-bit case - the
//   two consumptions of a long, the byte-word-byte of a misaligned long,
//   the mask sequence.  The 32-bit shape runs the same bench with the
//   port set to 32 and 8.
//
// THE DRIVER
//   As upstream's own kernel benches do it: clkena_in held high, a 64K-word
//   memory answering combinationally from addr_out, one beat per clock.
//   Beats are sampled on the falling edge, mid-beat, when everything the
//   kernel drives is stable; writes land then too.  busstate 00 (fetch)
//   beats are not checked (1.14: the prefetch contract is the adopted
//   change, and the 16-bit kernel fetches words).
//
// MIXED LANGUAGE
//   Verilog bench, VHDL kernel, ModelSim (Starter Edition; the kernel is
//   over its line limit, which slows it and nothing more).  run.sh.

`timescale 1ns/1ps

module tb_kernel_bus;

  reg clk = 0;
  always #5 clk = ~clk;
  reg nReset = 0;

  // ---------------------------------------------------------------- kernel
  wire [15:0] data_in;
  wire [15:0] data_write;
  wire [31:0] addr_out;
  wire        nWr, nUDS, nLDS;
  wire [1:0]  busstate;
  wire [2:0]  FC;
  wire [5:0]  dbg_memmask;
  wire [31:0] dbg_d1;

  TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(1), .extAddr_Mode(1), .MUL_Hardware(1), .BarrelShifter(2)
  ) dut (
    .clk(clk), .nReset(nReset), .clkena_in(1'b1), .beat_valid(1'b1),
    .data_in(data_in), .IPL(3'b111), .IPL_autovector(1'b1), .berr(1'b0), .CPU(2'b10),
    .addr_out(addr_out), .data_write(data_write), .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
    .busstate(busstate), .FC(FC),
    .pmmu_walker_ack(1'b0), .pmmu_walker_data(32'd0), .pmmu_walker_berr(1'b0),
    .debug_memmask(dbg_memmask), .debug_regfile_d1(dbg_d1)
  );

  // ---------------------------------------------------------------- memory
  reg [15:0] mem [0:65535];
  assign data_in = mem[addr_out[16:1]];

  // ---------------------------------------------------------------- oracle
  integer pass = 0, fails = 0, beats = 0, nexp = 0, fails_bf5 = 0;
  reg [31:0] stop_at;
  reg [8*16-1:0] e_label [0:4095];
  reg [8*3-1:0]  e_cat   [0:4095];
  reg [31:0] e_addr  [0:4095];
  reg        e_uds   [0:4095];
  reg        e_lds   [0:4095];
  reg        e_wr    [0:4095];
  reg [7:0]  e_hi    [0:4095];
  reg        e_hi_x  [0:4095];
  reg [7:0]  e_lo    [0:4095];
  reg        e_lo_x  [0:4095];
  reg [5:0]  e_mask  [0:4095];

  task load_expect;
    integer fd, r; reg [8*16-1:0] lab; reg [8*3-1:0] cat; reg [31:0] a; reg [7:0] u, l, d; reg [8*2-1:0] hs, ls; reg [8*6-1:0] ms; reg [1023:0] line;
    begin
      fd = $fopen("expect.txt", "r");
      if (fd == 0) begin $display("FAIL: expect.txt missing"); $finish; end
      r = $fgets(line, fd);                              // the header comment
      while (!$feof(fd)) begin
        r = $fscanf(fd, "%s %s %h %d %d %s %s %s %s\n", lab, cat, a, u, l, d, hs, ls, ms);
        if (r == 9) begin
          e_label[nexp] = lab; e_cat[nexp] = cat; e_addr[nexp] = a; e_uds[nexp] = u[0]; e_lds[nexp] = l[0];
          e_wr[nexp] = (d == "w");
          e_hi_x[nexp] = (hs == "xx"); e_lo_x[nexp] = (ls == "xx");
          if (!e_hi_x[nexp]) r = $sscanf(hs, "%h", e_hi[nexp]);
          if (!e_lo_x[nexp]) r = $sscanf(ls, "%h", e_lo[nexp]);
          r = $sscanf(ms, "%b", e_mask[nexp]);
          nexp = nexp + 1;
        end
      end
      $fclose(fd);
      fd = $fopen("stop_at.txt", "r");
      r = $fscanf(fd, "%h", stop_at);
      $fclose(fd);
    end
  endtask

  // ---------------------------------------------------------------- beats
  // The kernel prefetches the STOP word before the previous instruction's
  // data beats have run, so seeing it fetched is not the end: run on for
  // 100 clocks after it (a STOPped kernel makes no beats).
  reg done = 0; integer tail = -1;
  always @(negedge clk) if (nReset && !done) begin
    if (busstate == 2'b00 && addr_out == stop_at && tail < 0) tail = 100;
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
    if (busstate == 2'b10 || busstate == 2'b11) begin
      if (beats >= nexp) begin
        fails = fails + 1;
        $display("FAIL beat %0d: unexpected  addr %08x uds %b lds %b wr %b data %04x mask %b", beats, addr_out, nUDS, nLDS, !nWr, data_write, dbg_memmask);
      end else begin
        if (addr_out[31:1] == e_addr[beats][31:1] && nUDS == e_uds[beats] && nLDS == e_lds[beats] &&
            (!nWr) == e_wr[beats] && dbg_memmask == e_mask[beats] &&
            (e_hi_x[beats] || nUDS || data_write[15:8] == e_hi[beats]) &&
            (e_lo_x[beats] || nLDS || data_write[7:0] == e_lo[beats]))
          pass = pass + 1;
        else begin
          fails = fails + 1;
          if (e_cat[beats] == "bf5") fails_bf5 = fails_bf5 + 1;
          $display("FAIL beat %0d %0s: got addr %08x uds %b lds %b wr %b data %04x mask %b; expected addr %08x uds %b lds %b wr %b hi %02x lo %02x mask %b",
                   beats, e_label[beats], addr_out, nUDS, nLDS, !nWr, data_write, dbg_memmask,
                   e_addr[beats], e_uds[beats], e_lds[beats], e_wr[beats], e_hi[beats], e_lo[beats], e_mask[beats]);
        end
      end
      beats = beats + 1;
      if (busstate == 2'b11 && !nWr) begin
        if (!nUDS) mem[addr_out[16:1]][15:8] = data_write[15:8];
        if (!nLDS) mem[addr_out[16:1]][7:0]  = data_write[7:0];
      end
    end
  end

  // ---------------------------------------------------------------- run
  integer i, k; reg [31:0] v, want;
  initial begin
    $readmemh("program.hex", mem);
    load_expect;
    $display("---- %0d expected beats, STOP at %08x", nexp, stop_at);
    repeat (20) @(posedge clk);
    nReset = 1;
    i = 0;
    while (!done && i < 200000) begin @(posedge clk); i = i + 1; end
    if (!done) begin fails = fails + 1; $display("FAIL: STOP not reached after %0d clocks (%0d beats seen)", i, beats); end
    if (beats != nexp) begin fails = fails + 1; $display("FAIL: %0d beats seen, %0d expected", beats, nexp); end
    else pass = pass + 1;
    // result slots: byte reads give ...04 (upper bytes from the previous
    // D1), word 0304, long 01020304; D1 starts at 0, so the byte slots hold
    // 00000004, then 00000304, then 01020304 for every size after
    for (k = 0; k < 12; k = k + 1) begin
      v = {mem[(32'h3000 + 4*k) >> 1], mem[((32'h3000 + 4*k) >> 1) + 1]};
      want = (k < 4) ? 32'h00000004 : (k < 8) ? 32'h00000304 : 32'h01020304;
      if (v === want) pass = pass + 1;
      else begin fails = fails + 1; $display("FAIL slot %0d: %08x, expected %08x", k, v, want); end
    end
    if (fails == 0) $display("==== PASS: %0d checks, %0d beats - the kernel's beats match UM 7.2's table on this port", pass, beats);
    else if (fails == fails_bf5) $display("==== FAIL: %0d failures, all in the five-byte bit fields (the kernel's one operand cycle against 1.14's two); %0d passes, %0d beats", fails, pass, beats);
    else $display("==== FAIL: %0d failures (%0d in five-byte bit fields), %0d passes, %0d beats", fails, fails_bf5, pass, beats);
    $finish;
  end

endmodule
