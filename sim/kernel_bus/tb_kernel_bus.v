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
//   PORT selects the shape and the device (run.sh, +define+PORT):
//     16  the kernel's 16-bit shape (DATA_WIDTH=16) on a 16-bit memory -
//         the oracle's 16-bit-port rows; strobes checked as lanes 0-1
//     32  the 32-bit shape on a 32-bit memory answering DSACK "00"
//     8   the 32-bit shape with the operand area an 8-bit device on D31:24
//         answering "10", and code in 32-bit memory
//   In the 32-bit shape there are no strobes: the contract is the address,
//   SIZ, and the bytes on the lanes the port takes (UM Table 7-7), which
//   is what the device model stores and the bench checks.
//
// THE DRIVER
//   As upstream's own kernel benches do it: clkena_in held high, a 64K-word
//   memory answering combinationally from addr_out, one beat per clock.
//   Beats are sampled on the falling edge, mid-beat, when everything the
//   kernel drives is stable; writes land then too.  busstate 00 (fetch)
//   beats are not checked (1.14: the prefetch contract is step 2c).
//
// MIXED LANGUAGE
//   Verilog bench, VHDL kernel, ModelSim (Starter Edition; the kernel is
//   over its line limit, which slows it and nothing more).  run.sh.

`timescale 1ns/1ps

`ifndef PORT
`define PORT 16
`endif

module tb_kernel_bus;

  localparam PORT = `PORT;
  localparam DW = (PORT == 16) ? 16 : 32;

  reg clk = 0;
  always #5 clk = ~clk;
  reg nReset = 0;

  // ---------------------------------------------------------------- kernel
  wire [DW-1:0] data_in;
  wire [DW-1:0] data_write;
  wire [31:0] addr_out;
  wire        nWr, nUDS, nLDS;
  wire [1:0]  busstate, siz;
  wire [2:0]  FC;
  wire [5:0]  dbg_memmask;
  wire [31:0] dbg_d1, dbg_dr, dbg_ldr;
  wire [15:0] dbg_opc;
  // PORT 8: the operand area $2000-$20FF is the 8-bit device; code, vectors
  // and result slots are 32-bit memory (as on the SE/30; the kernel fetches
  // a word a beat until 1.15 step 2c)
  wire        dev8  = (PORT == 8) && (addr_out[31:8] == 24'h20);
  wire [1:0]  dsack = dev8 ? 2'b10 : 2'b00;

  TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(1), .extAddr_Mode(1), .MUL_Hardware(1), .BarrelShifter(2),
    .DATA_WIDTH(DW)
  ) dut (
    .clk(clk), .nReset(nReset), .clkena_in(1'b1), .beat_valid(1'b1),
    .data_in(data_in), .dsack(dsack), .IPL(3'b111), .IPL_autovector(1'b1), .berr(1'b0), .CPU(2'b10),
    .addr_out(addr_out), .data_write(data_write), .siz(siz), .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS),
    .busstate(busstate), .FC(FC),
    .pmmu_walker_ack(1'b0), .pmmu_walker_data(32'd0), .pmmu_walker_berr(1'b0),
    .debug_memmask(dbg_memmask), .debug_regfile_d1(dbg_d1),
    .debug_data_read(dbg_dr), .debug_last_data_read(dbg_ldr), .debug_last_opc_read(dbg_opc)
  );

  // ---------------------------------------------------------------- memory
  // 64K words.  The device: a 16-bit memory on D15:8/D7:0 (PORT 16); a
  // 32-bit memory presenting the long at addr & ~3 (PORT 32); an 8-bit
  // device presenting the byte at addr on D31:24 (PORT 8).
  reg [15:0] mem [0:65535];
  wire [15:0] w_even = mem[{addr_out[16:2], 1'b0}];
  wire [15:0] w_odd  = mem[{addr_out[16:2], 1'b1}];
  wire [7:0]  byte_at = addr_out[0] ? mem[addr_out[16:1]][7:0] : mem[addr_out[16:1]][15:8];
  generate
    if (PORT == 16) begin : g16
      assign data_in = mem[addr_out[16:1]];
    end else begin : g32
      assign data_in = dev8 ? {byte_at, 24'h0} : {w_even, w_odd};
    end
  endgenerate
  // the write lanes a port takes (UM Table 7-7): lane 0 = D31:24
  wire [7:0] lane0 = (DW == 32) ? data_write[DW-1 -: 8] : data_write[15:8];
  wire [7:0] lane1 = (DW == 32) ? data_write[DW-9 -: 8] : data_write[7:0];
  wire [7:0] lane2 = (DW == 32) ? data_write[15:8] : 8'hxx;
  wire [7:0] lane3 = (DW == 32) ? data_write[7:0]  : 8'hxx;
  wire [2:0] siz_n = (siz == 2'b00) ? 3'd4 : {1'b0, siz};

  // ---------------------------------------------------------------- oracle
  integer pass = 0, fails = 0, beats = 0, nexp = 0, fails_bf5 = 0;
  reg [31:0] stop_at;
  reg [8*16-1:0] e_label [0:4095];
  reg [8*3-1:0]  e_cat   [0:4095];
  reg [31:0] e_addr  [0:4095];
  reg [1:0]  e_siz   [0:4095];
  reg [3:0]  e_lanes [0:4095];        // bit 3 = lane 0
  reg        e_wr    [0:4095];
  reg [7:0]  e_b     [0:4*4096-1];    // 4 per beat
  reg        e_bx    [0:4*4096-1];
  reg [5:0]  e_mask  [0:4095];

  task load_expect;
    integer fd, r, k; reg [8*16-1:0] lab; reg [8*3-1:0] cat; reg [31:0] a; reg [7:0] d; reg [8*2-1:0] sz, bs [0:3]; reg [8*4-1:0] ln; reg [8*6-1:0] ms; reg [1023:0] line;
    begin
      fd = $fopen("expect.txt", "r");
      if (fd == 0) begin $display("FAIL: expect.txt missing"); $finish; end
      r = $fgets(line, fd);                              // the header comment
      while (!$feof(fd)) begin
        r = $fscanf(fd, "%s %s %h %s %s %s %s %s %s %s %s\n", lab, cat, a, sz, ln, d, bs[0], bs[1], bs[2], bs[3], ms);
        if (r == 11) begin
          e_label[nexp] = lab; e_cat[nexp] = cat; e_addr[nexp] = a;
          r = $sscanf(sz, "%b", e_siz[nexp]);
          r = $sscanf(ln, "%b", e_lanes[nexp]);
          e_wr[nexp] = (d == "w");
          for (k = 0; k < 4; k = k + 1) begin
            e_bx[4*nexp+k] = (bs[k] == "xx");
            if (!e_bx[4*nexp+k]) r = $sscanf(bs[k], "%h", e_b[4*nexp+k]);
          end
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
  reg done = 0, ok; integer tail = -1;
  always @(negedge clk) if (nReset && !done) begin
`ifdef TRACE
    if (busstate != 2'b01)
      $display("t=%0t bs=%b addr=%08x siz=%b wr=%b din=%0h dout=%0h mask=%b dr=%08x ldr=%08x opc=%04x",
               $time, busstate, addr_out, siz, !nWr, data_in, data_write, dbg_memmask, dbg_dr, dbg_ldr, dbg_opc);
`endif
    if (busstate == 2'b00 && addr_out == stop_at && tail < 0) tail = 100;
    if (tail > 0) tail = tail - 1;
    if (tail == 0) done <= 1;
    if (busstate == 2'b10 || busstate == 2'b11) begin
      if (beats >= nexp) begin
        fails = fails + 1;
        $display("FAIL beat %0d: unexpected  addr %08x siz %b uds %b lds %b wr %b data %08x mask %b", beats, addr_out, siz, nUDS, nLDS, !nWr, data_write, dbg_memmask);
      end else begin
        ok = (addr_out == e_addr[beats]) && (siz == e_siz[beats]) && ((!nWr) == e_wr[beats]) && (dbg_memmask == e_mask[beats]);
        if (PORT == 16) ok = ok && (nUDS == !e_lanes[beats][3]) && (nLDS == !e_lanes[beats][2]);
        if (!e_bx[4*beats+0] && e_lanes[beats][3] && lane0 !== e_b[4*beats+0]) ok = 0;
        if (!e_bx[4*beats+1] && e_lanes[beats][2] && lane1 !== e_b[4*beats+1]) ok = 0;
        if (!e_bx[4*beats+2] && e_lanes[beats][1] && lane2 !== e_b[4*beats+2]) ok = 0;
        if (!e_bx[4*beats+3] && e_lanes[beats][0] && lane3 !== e_b[4*beats+3]) ok = 0;
        if (ok) pass = pass + 1;
        else begin
          fails = fails + 1;
          if (e_cat[beats] == "bf5") fails_bf5 = fails_bf5 + 1;
          $display("FAIL beat %0d %0s: got addr %08x siz %b uds %b lds %b wr %b data %08x mask %b; expected addr %08x siz %b lanes %b wr %b bytes %02x %02x %02x %02x mask %b",
                   beats, e_label[beats], addr_out, siz, nUDS, nLDS, !nWr, data_write, dbg_memmask,
                   e_addr[beats], e_siz[beats], e_lanes[beats], e_wr[beats], e_b[4*beats], e_b[4*beats+1], e_b[4*beats+2], e_b[4*beats+3], e_mask[beats]);
        end
      end
      beats = beats + 1;
      if (busstate == 2'b11 && !nWr) begin
        if (PORT == 16) begin
          if (!nUDS) mem[addr_out[16:1]][15:8] = data_write[15:8];
          if (!nLDS) mem[addr_out[16:1]][7:0]  = data_write[7:0];
        end else if (!dev8) begin
          // lanes A1A0 .. A1A0+SIZ-1, capped at the long's end (Table 7-7)
          if (addr_out[1:0] == 2'd0)                                   mem[{addr_out[16:2], 1'b0}][15:8] = lane0;
          if (addr_out[1:0] <= 2'd1 && addr_out[1:0] + siz_n > 1)      mem[{addr_out[16:2], 1'b0}][7:0]  = lane1;
          if (addr_out[1:0] <= 2'd2 && addr_out[1:0] + siz_n > 2)      mem[{addr_out[16:2], 1'b1}][15:8] = lane2;
          if (addr_out[1:0] + siz_n > 3)                               mem[{addr_out[16:2], 1'b1}][7:0]  = lane3;
        end else begin
          if (addr_out[0]) mem[addr_out[16:1]][7:0] = lane0; else mem[addr_out[16:1]][15:8] = lane0;
        end
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
    if (fails == 0) $display("==== PASS: %0d checks, %0d beats - the kernel's beats match UM 7.2's table on a %0d-bit port", pass, beats, PORT);
    else if (fails == fails_bf5) $display("==== FAIL: %0d failures, all in the five-byte bit fields (the kernel's one operand cycle against 1.14's two); %0d passes, %0d beats", fails, pass, beats);
    else $display("==== FAIL: %0d failures (%0d in five-byte bit fields), %0d passes, %0d beats", fails, fails_bf5, pass, beats);
    $finish;
  end

endmodule
