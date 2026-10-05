// tb_se30_flp_dkmux.v - the eight-requester disk-port mux (SE30_PLAN.md
// 5.14, 5.15.5 item 9): the two drives' loaders, encoders, decoders and
// SD writers against a controller that keeps se30_sdram's dk_* contract.
//
// WHAT THIS PROVES
//   The controller model: it samples the request two clocks late (as
//   se30_sdram's synchronised view), starts a word only with its
//   acknowledge down, raises the acknowledge 3-14 clocks later (a read's
//   word with it) and drops it only after it has sampled the request low.
//   The requesters: each holds request, address and data until its
//   acknowledge, drops the request, and raises the next only after its
//   acknowledge has fallen (5.12.5's rule); the writers (loaders and
//   decoders) write ascending words of their own data into their own
//   regions, the readers (encoders and SD writers) read random words of a
//   preloaded region.  Checked, in phases (all eight saturating; random
//   gaps; one requester alone; two or three at a time):
//     1. what the controller started is what it finishes: the port's
//        address, direction and data do not change from the start of a
//        word to its acknowledge (no request moved from under it)
//     2. every acknowledge reaches the requester whose word it was - its
//        address and direction - and only one requester; a read's word
//        is the memory's; no acknowledge to a requester without its
//        request up
//     3. every write lands: the loaders' regions hold their data at the end
//     4. every requester finishes its words; none waits longer than
//        seven other words' worth (round robin: no starving)
//
// +seed=N  the random seed (1 by default)

`timescale 1ns/1ps

module tb_se30_flp_dkmux;

  reg clk = 0;
  always #15.957 clk = ~clk;
  reg reset_n = 0;

  integer seed = 1;
  integer fails = 0, passes = 0;

  // ------------------------------------------------------------ the requesters
  reg  [7:0]  rq = 0;                    // 0 ld0, 1 en0, 2 ld1, 3 en1, 4 de0, 5 wr0, 6 de1, 7 wr1
  reg  [23:0] ra [0:7];
  reg  [15:0] rd [0:7];
  wire [7:0]  ack;
  wire [15:0] en0_rdata, en1_rdata, wr0_rdata, wr1_rdata;
  function [15:0] rdat; input integer k;
    rdat = (k == 1) ? en0_rdata : (k == 3) ? en1_rdata : (k == 5) ? wr0_rdata : wr1_rdata;
  endfunction
  // each requester's region: the writers' (even) and the readers' (odd)
  function [23:0] base; input integer k;
    case (k)
      0: base = 24'h800000; 1: base = 24'h801000; 2: base = 24'h900000; 3: base = 24'h901000;
      4: base = 24'h802000; 5: base = 24'h803000; 6: base = 24'h902000; default: base = 24'h903000;
    endcase
  endfunction

  wire        dk_req, dk_we;
  wire [23:0] dk_addr;
  wire [15:0] dk_wdata;
  reg  [15:0] dk_rdata = 0;
  reg         dk_ack = 0;

  se30_flp_dkmux dut (
    .clk(clk), .reset_n(reset_n),
    .ld0_req(rq[0]), .ld0_addr(ra[0]), .ld0_wdata(rd[0]), .ld0_ack(ack[0]),
    .en0_req(rq[1]), .en0_addr(ra[1]), .en0_rdata(en0_rdata), .en0_ack(ack[1]),
    .ld1_req(rq[2]), .ld1_addr(ra[2]), .ld1_wdata(rd[2]), .ld1_ack(ack[2]),
    .en1_req(rq[3]), .en1_addr(ra[3]), .en1_rdata(en1_rdata), .en1_ack(ack[3]),
    .de0_req(rq[4]), .de0_addr(ra[4]), .de0_wdata(rd[4]), .de0_ack(ack[4]),
    .wr0_req(rq[5]), .wr0_addr(ra[5]), .wr0_rdata(wr0_rdata), .wr0_ack(ack[5]),
    .de1_req(rq[6]), .de1_addr(ra[6]), .de1_wdata(rd[6]), .de1_ack(ack[6]),
    .wr1_req(rq[7]), .wr1_addr(ra[7]), .wr1_rdata(wr1_rdata), .wr1_ack(ack[7]),
    .dk_req(dk_req), .dk_we(dk_we), .dk_addr(dk_addr), .dk_wdata(dk_wdata), .dk_rdata(dk_rdata), .dk_ack(dk_ack));

  // ------------------------------------------------------------ the memory
  // {addr[20] (the drive), addr[13:12] (the requester's region), addr[9:0]}
  reg [15:0] mem [0:8191];
  function [12:0] mi; input [23:0] a; mi = {a[20], a[13:12], a[9:0]}; endfunction
  function [15:0] pre; input [23:0] a; pre = a[15:0] ^ 16'h5A3C ^ {a[20], 15'd0}; endfunction

  // ------------------------------------------------------------ the controller
  reg  [1:0]  req_sh = 0;                // the request, two clocks late
  wire        req_q = req_sh[1];
  integer     lat = 0;
  reg         busy = 0;
  reg  [23:0] c_addr; reg c_we; reg [15:0] c_wdata;
  integer     words = 0;
  always @(posedge clk) begin
    req_sh <= {req_sh[0], dk_req};
    if (!req_q) dk_ack <= 0;
    if (!busy && req_q && !dk_ack) begin
      busy <= 1; c_addr <= dk_addr; c_we <= dk_we; c_wdata <= dk_wdata;
      lat <= 3 + ($random(seed) & 32'h7) + (($random(seed) & 32'h3) == 0 ? 4 : 0);
    end else if (busy) begin
      // 1: the port does not move under a word in progress
      if (dk_addr !== c_addr || dk_we !== c_we || (c_we && dk_wdata !== c_wdata) || !dk_req) begin
        fails = fails + 1;
        if (fails < 10) $display("FAIL %0t: the port moved under a word: %h/%b -> %h/%b req %b", $time, c_addr, c_we, dk_addr, dk_we, dk_req);
      end
      if (lat <= 1) begin
        busy <= 0; dk_ack <= 1; words = words + 1;
        if (c_we) mem[mi(c_addr)] <= c_wdata;
        else dk_rdata <= mem[mi(c_addr)];
      end else lat <= lat - 1;
    end
  end

  // ------------------------------------------------------------ the checks on the acknowledges
  reg  [7:0] ack_q = 0;
  integer    acks = 0, k;
  always @(posedge clk) begin
    ack_q <= ack;
    if ((ack & (ack - 1)) != 0) begin
      fails = fails + 1; $display("FAIL %0t: two acknowledges at once %b", $time, ack);
    end
    for (k = 0; k < 8; k = k + 1)
      if (ack[k] && !ack_q[k]) begin
        acks = acks + 1;
        if (!rq[k] || ra[k] !== c_addr || c_we !== !k[0]) begin
          fails = fails + 1;
          if (fails < 10) $display("FAIL %0t: requester %0d acknowledged for %h/%b (its %h, req %b)", $time, k, c_addr, c_we, ra[k], rq[k]);
        end
        if (k[0] && (rdat(k) !== mem[mi(ra[k])])) begin
          fails = fails + 1;
          if (fails < 10) $display("FAIL %0t: requester %0d read %h, the memory %h", $time, k, rdat(k), mem[mi(ra[k])]);
        end
      end
  end

  // ------------------------------------------------------------ the requesters' behaviour
  integer left [0:7];                    // words still to do
  integer gap_max [0:7];                 // the idle gap's range (0: none)
  integer wrote [0:7];                   // a writer's next word
  integer wait_t [0:7], wait_max [0:7];
  reg [15:0] exp_ld [0:4095];            // each writer word's last data, {writer, addr[9:0]}
  integer ph;
  always @(posedge clk) begin : reqs
    integer j;
    for (j = 0; j < 8; j = j + 1) begin
      if (rq[j]) wait_t[j] = wait_t[j] + 1;
      if (rq[j] && ack[j]) begin
        rq[j] <= 0;
        if (wait_t[j] > wait_max[j]) wait_max[j] = wait_t[j];
      end else if (!rq[j] && !ack[j] && left[j] > 0 &&
                   (gap_max[j] == 0 || ($random(seed) % gap_max[j]) == 0)) begin
        // the next word: the acknowledge has fallen
        left[j] = left[j] - 1;
        wait_t[j] = 0;
        if (!j[0]) begin
          ra[j] <= base(j) + (wrote[j] & 1023);
          rd[j] <= (wrote[j] * 16'd40503) ^ (j << 12);
          exp_ld[{j[2:1], wrote[j][9:0]}] = (wrote[j] * 16'd40503) ^ (j << 12);
          wrote[j] = wrote[j] + 1;
        end else
          ra[j] <= base(j) + ($random(seed) & 1023);
        rq[j] <= 1;
      end
    end
  end

  task phase(input [8*28-1:0] name, input integer n0, n1, n2, n3, n4, n5, n6, n7, input integer g);
    integer j, t, bound;
    begin
      left[0] = n0; left[1] = n1; left[2] = n2; left[3] = n3;
      left[4] = n4; left[5] = n5; left[6] = n6; left[7] = n7;
      for (j = 0; j < 8; j = j + 1) begin gap_max[j] = g; wait_max[j] = 0; end
      t = 0;
      while ((left[0] || left[1] || left[2] || left[3] || left[4] || left[5] || left[6] || left[7] || rq || ack)
             && t < 4000000) begin @(posedge clk); t = t + 1; end
      // a word is at most 3 (sampling) + 14 (latency) + 3 (the acknowledge's fall) clocks;
      // round robin: at most seven others' before one's own
      bound = 8 * 26;
      if (t >= 4000000) begin fails = fails + 1; $display("FAIL %0s: words left %0d %0d %0d %0d %0d %0d %0d %0d", name,
                                 left[0], left[1], left[2], left[3], left[4], left[5], left[6], left[7]); end
      else passes = passes + 1;
      for (j = 0; j < 8; j = j + 1)
        if (wait_max[j] > bound) begin
          fails = fails + 1; $display("FAIL %0s: requester %0d waited %0d clocks (bound %0d)", name, j, wait_max[j], bound);
        end
      $display("phase %0s: %0d clocks, longest waits %0d %0d %0d %0d %0d %0d %0d %0d", name, t,
               wait_max[0], wait_max[1], wait_max[2], wait_max[3], wait_max[4], wait_max[5], wait_max[6], wait_max[7]);
    end
  endtask

  initial begin : run
    integer j, bad;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    for (j = 0; j < 8192; j = j + 1) mem[j] = 16'hDEAD;
    for (j = 0; j < 1024; j = j + 1) begin
      mem[mi(base(1) + j)] = pre(base(1) + j); mem[mi(base(3) + j)] = pre(base(3) + j);
      mem[mi(base(5) + j)] = pre(base(5) + j); mem[mi(base(7) + j)] = pre(base(7) + j);
    end
    for (j = 0; j < 8; j = j + 1) begin left[j] = 0; wrote[j] = 0; wait_t[j] = 0; wait_max[j] = 0; ra[j] = 0; rd[j] = 0; end
    repeat (4) @(posedge clk); reset_n = 1; repeat (4) @(posedge clk);
    phase("all eight, saturating", 3000, 3000, 3000, 3000, 3000, 3000, 3000, 3000, 0);
    phase("random gaps", 2000, 2000, 2000, 2000, 2000, 2000, 2000, 2000, 7);
    phase("ld1 alone", 0, 0, 1024, 0, 0, 0, 0, 0, 0);
    phase("en0 alone", 0, 1500, 0, 0, 0, 0, 0, 0, 0);
    phase("de0 alone", 0, 0, 0, 0, 1024, 0, 0, 0, 0);
    phase("wr0 alone", 0, 0, 0, 0, 0, 1500, 0, 0, 0);
    phase("en0 and ld1", 0, 2000, 2000, 0, 0, 0, 0, 0, 3);
    phase("ld0 and en1", 2000, 0, 0, 2000, 0, 0, 0, 0, 0);
    phase("en0, de0 and wr0 (a write)", 0, 2000, 0, 0, 2000, 2000, 0, 0, 0);
    phase("de1 and wr1", 0, 0, 0, 0, 0, 0, 2000, 2000, 5);
    phase("ld0 with the rest sparse", 1024, 300, 300, 300, 300, 300, 300, 300, 0);
    // 3: every write landed (each writer's last 1024 words)
    bad = 0;
    for (j = 0; j < 1024; j = j + 1)
      for (k = 0; k < 4; k = k + 1)
        if (mem[mi(base(2 * k) + j)] !== exp_ld[{k[1:0], j[9:0]}]) bad = bad + 1;
    if (bad) begin fails = fails + 1; $display("FAIL %0d writer words not as last written", bad); end
    else passes = passes + 1;
    if (acks != words) begin fails = fails + 1; $display("FAIL %0d words served, %0d acknowledges seen", words, acks); end
    else passes = passes + 1;
    $display("%0d words through the port", words);
    if (fails == 0) $display("==== PASS: %0d checks, %0d words - the eight requesters share the disk port", passes, words);
    else $display("==== FAIL: %0d failures", fails);
    $finish;
  end

endmodule
