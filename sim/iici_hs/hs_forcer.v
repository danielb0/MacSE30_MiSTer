// hs_forcer.v - beside tb_iici_machine (a second top): the SCSI chip's CPU
// side replaced by a byte source, to hold the wrapper and the MDU to the
// ROM's blind read - MOVE.L from the handshake port ($50F06060), four byte
// cycles back to back for each long (SE30_PLAN.md "THE SCSI DISK").
//   Every DACK read strobe hands over the next byte (a counter from $10);
//   DRQ falls with DACK and comes back DRQ_LAT clk after DACK is gone, as
//   the 53C80's does once the target has the next byte up.
`timescale 1ns/1ps
module hs_forcer;
  parameter integer DRQ_LAT = 12;
  parameter integer STOP_NS = 400000;
  reg  [7:0] cnt = 8'h10;
  reg        drq = 1;
  integer    wait_n = 0, strobes = 0, cycles = 0;
  wire clk  = tb_iici_machine.clk_sys;
  wire dack = tb_iici_machine.machine.scsi_dack;
  wire stb  = tb_iici_machine.machine.scsi_stb && tb_iici_machine.machine.dev_rw && dack;
  wire wstb = tb_iici_machine.machine.scsi_stb && !tb_iici_machine.machine.dev_rw && dack;
  reg [63:0] wlog = 0;
  integer wstrobes = 0;
  wire as_n = tb_iici_machine.machine.cpu_as_n;
  wire hs   = (tb_iici_machine.machine.cpu_addr[31:24] == 8'h50) && (tb_iici_machine.machine.cpu_addr[17:13] == 5'h03);
  reg  as_q = 1;
  initial begin
    force tb_iici_machine.machine.scsi_drq   = drq;
    force tb_iici_machine.machine.scsi_rdata = cnt;
  end
  always @(posedge clk) begin
    as_q <= as_n;
    if (as_q && !as_n && hs) cycles = cycles + 1;
    if (stb) begin cnt <= cnt + 8'd1; strobes = strobes + 1; end
    if (wstb) begin wlog = {wlog[55:0], tb_iici_machine.machine.dev_wdata}; wstrobes = wstrobes + 1; end
    if (dack) begin drq <= 0; wait_n = DRQ_LAT; end
    else if (wait_n != 0) wait_n = wait_n - 1;
    else drq <= 1;
  end
  // a log of the first bus cycles and a stop: a cycle that never ends must not run the simulator for ever
  integer nlog = 0;
  wire [1:0] ds = tb_iici_machine.machine.dsack_n;
  always @(posedge clk) begin
    if (as_q && !as_n && nlog < 60) begin
      nlog = nlog + 1;
      $display("      %0t: AS* %08x fc %0d rw %0d siz %0d", $time, tb_iici_machine.machine.cpu_addr, tb_iici_machine.machine.cpu_fc,
               tb_iici_machine.machine.cpu_rw_n, tb_iici_machine.machine.cpu_siz);
    end
    if (!as_q && as_n && nlog < 60) $display("      %0t:   ended, din %08x dsack %b berr %b", $time, tb_iici_machine.machine.cpu_din, ds, tb_iici_machine.machine.berr);
  end
  initial begin #(STOP_NS); $display("---- stopped by the bench's time limit"); $finish; end
  integer k, bad;
  reg [31:0] w, e;
  final begin
    bad = 0;
    $display("---- the handshake port: %0d bus cycles, %0d DACK strobes", cycles, strobes);
    for (k = 0; k < 8; k = k + 1) begin
      w = tb_iici_machine.ram_a[(32'h2000 >> 2) + k];
      e = {8'h10 + 8'(4*k), 8'h11 + 8'(4*k), 8'h12 + 8'(4*k), 8'h13 + 8'(4*k)};
      if (w !== e) bad = bad + 1;
      $display("      long %0d: %08x%s", k, w, (w === e) ? "" : "   <-- not the next four bytes");
    end
    w = tb_iici_machine.ram_a[(32'h2020 >> 2)];
    $display("      then two byte reads and the marker: %08x %08x", w, tb_iici_machine.ram_a[(32'h2024 >> 2)]);
    $display("      two long writes: %0d write strobes, the bytes %016x", wstrobes, wlog);
    if (bad == 0 && cycles == strobes + wstrobes && strobes == 34 && wstrobes == 8 && w[31:16] === 16'h3031 &&
        wlog === 64'hA1A2A3A4B1B2B3B4) $display("==== HS PASS: every byte once, in order, reads and writes");
    else $display("==== HS FAIL: %0d longs wrong, %0d cycles, %0d read strobes, %0d write strobes", bad, cycles, strobes, wstrobes);
  end
endmodule
