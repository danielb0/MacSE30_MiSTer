// tb_iici_machine.v - the IIci machine from reset with the IIci ROM
// (SE30_PLAN.md "THE IIci MACHINE").
//
// WHAT THIS PROVES (so far: the MDU and its memory; the RBV is a stand-in)
//   1. the reset vector comes from ROM through the overlay - $0 and $4,
//      five clocks each (G Table 5-9) - and the first fetch is at the
//      ROM's reset PC; the overlay ends at that first $4xxxxxxx access
//   2. the ROM runs on with the MDU's decode to a loop or a halt; every bus
//      error is listed (the ROM's identification probes empty windows and
//      takes the bus errors on purpose), every RBV access is listed (its
//      register offsets are documented nowhere we have), and the run's
//      RAM cycles are metered: 5 / 4 clocks, +1 back to back after a
//      write, bursts 5-2-2-2 once the ROM turns them on (CACR $3919)
//   3. the memory port is never late (dbg_late) with the first long 80 ns
//      after the request, the budget the MDU leaves the SDRAM
//   4. D6 = 0: no start-up test has failed
//   The run ends in the RAM tests' fill ($408446C8, MOVEM.L over all of RAM:
//   hours of ModelSim beyond), as sim/machine's ends in the SE/30's.  run.sh
//   skips the boot chime and shortens the checksum in the bench's ROM copy.
//
// CLOCKING: clk_sys 50 MHz, clk_k = clk_sys / 2, phi from clk_k as the
// SE/30 bench's KCLK mode makes it.  The memory is behavioural (this
// step's subject is the MDU, not the SDRAM controller): RAM banks A and B
// 4 MB each (1 MB SIMMs), never-written longs random, as a real chip's
// power-up state; the ROM image at long $600000.

`timescale 1ns/1ps

module tb_iici_machine;
  parameter PORTRAIT = 0;              // run.sh's PORTRAIT=1: the Portrait Display
  reg clk_sys = 0, clk_k = 0;
  always begin #10 clk_sys = ~clk_sys; if (clk_sys) clk_k = ~clk_k; end
  reg clk_vid = 0;
  always #8.729 clk_vid = ~clk_vid;     // 57.28 MHz
  reg tk = 0, tk_q = 0;
  always @(posedge clk_k) tk <= ~tk;
  always @(posedge clk_sys) tk_q <= tk;
  wire phi = tk ^ tk_q;
  wire phi1 = !phi, phi2 = phi;
  reg reset_n = 0;

  // ------------------------------------------------------------ memory
  localparam integer LAT = 4;          // clks from the edge that sees the request to the MDU taking the long
  reg [31:0] ram_a [0:1048575];        // bank A, 4 MB
  reg [31:0] ram_b [0:1048575];        // bank B, 4 MB
  reg [31:0] rom   [0:131071];
  reg [15:0] romw  [0:262143];
  integer i;
  initial begin
    $readmemh("rom.hex", romw);
    for (i = 0; i < 131072; i = i + 1) rom[i] = {romw[2*i], romw[2*i+1]};
    for (i = 0; i < 1048576; i = i + 1) begin ram_a[i] = $random; ram_b[i] = $random; end
  end

  wire        mem_req, mem_we, mem_burst, mem_refresh;
  wire [24:0] mem_addr;
  wire  [3:0] mem_be;
  wire [31:0] mem_wdata;
  reg  [31:0] mem_rdata = 0;
  reg         mem_ack = 0;
  integer     mreqs = 0, mbursts = 0;

  function [31:0] mread(input [24:0] ad);
    begin
      if (ad[24:21] == 4'b0011) mread = rom[ad[16:0]];
      else if (ad[23]) mread = ram_b[ad[19:0]];
      else mread = ram_a[ad[19:0]];
    end
  endfunction
  task mwrite(input [24:0] ad, input [3:0] be, input [31:0] w);
    reg [31:0] o;
    begin
      o = mread(ad);
      o = {be[3] ? w[31:24] : o[31:24], be[2] ? w[23:16] : o[23:16], be[1] ? w[15:8] : o[15:8], be[0] ? w[7:0] : o[7:0]};
      if (ad[24:21] == 4'b0011) ;                   // the ROM: no write reaches it (the MDU sends none)
      else if (ad[23]) ram_b[ad[19:0]] = o; else ram_a[ad[19:0]] = o;
    end
  endtask

  // the video port: 8 longs of bank A from v_addr, one a clk after LAT
  wire        v_req, ce_pix, hsync_n, vsync_n;
  wire [24:0] v_addr;
  reg  [31:0] v_rdata = 0;
  reg         v_ack = 0;
  integer     vbursts = 0, vsyncs = 0;
  initial begin : vport
    integer k; reg [24:0] ad;
    forever begin
      @(posedge clk_sys);
      if (v_req) begin
        vbursts = vbursts + 1; ad = v_addr;
        repeat (LAT - 1) @(posedge clk_sys);
        for (k = 0; k < 8; k = k + 1) begin
          v_rdata <= mread(ad + k); v_ack <= 1; @(posedge clk_sys); v_ack <= 0;
        end
      end
    end
  end
  reg vs_q = 1;
  always @(posedge clk_vid) begin if (!vsync_n && vs_q) vsyncs = vsyncs + 1; vs_q <= vsync_n; end

  initial begin : port
    integer k; reg [24:0] ad; reg we, bu; reg [3:0] be; reg [31:0] w;
    forever begin
      @(posedge clk_sys);
      if (mem_req) begin
        mreqs = mreqs + 1; if (mem_burst) mbursts = mbursts + 1;
        ad = mem_addr; we = mem_we; bu = mem_burst; be = mem_be; w = mem_wdata;
        repeat (LAT - 1) @(posedge clk_sys);
        for (k = 0; k < (bu ? 4 : 1); k = k + 1) begin
          if (we) mwrite(ad, be, w);
          else mem_rdata <= mread({ad[24:2], ad[1:0] + k[1:0]});
          mem_ack <= 1; @(posedge clk_sys); mem_ack <= 0;
        end
      end
    end
  end

  // ---------------------------------------------------------- machine
  wire [31:0] cpu_addr;
  wire  [2:0] cpu_fc;
  wire  [1:0] dsack_n;
  wire        cpu_as_n, cpu_rw_n, berr, halted, reset_out_n, overlay;
  wire [63:0] regs;
  wire [15:0] late;

  iici_machine #(.FPU_UCODE("../../rtl/fpu/ucode/")) machine (
    .clk(clk_sys), .clk_k(clk_k), .clk_vid(clk_vid), .portrait(PORTRAIT[0]), .phi1(phi1), .phi2(phi2), .reset_n(reset_n), .bank_a(2'd2), .bank_b(2'd2),
    .mem_req(mem_req), .mem_we(mem_we), .mem_burst(mem_burst), .mem_addr(mem_addr), .mem_be(mem_be),
    .mem_wdata(mem_wdata), .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_refresh(mem_refresh),
    .v_req(v_req), .v_addr(v_addr), .v_rdata(v_rdata), .v_ack(v_ack),
    .ce_pix(ce_pix), .vid_r(), .vid_g(), .vid_b(), .hsync_n(hsync_n), .vsync_n(vsync_n), .hblank(), .vblank(), .poweroff_req(),
    .nmi_n(1'b1), .pace_en(1'b1),
    .ps2_key(11'd0), .ps2_mouse(25'd0), .timestamp(33'd0),
    .pram_h_we(1'b0), .pram_h_addr(8'd0), .pram_h_wdata(8'd0), .pram_h_raddr(8'd0), .pram_h_rdata(), .pram_wr(),
    .adb_pm_we(1'b0), .adb_pm_waddr(9'd0), .adb_pm_wdata(12'd0),
    .disk_in(1'b0), .disk_eject(), .disk_cyl(), .trk_cyl(7'h7F), .trk_valid(1'b0),
    .trk_addr(), .trk_side(), .trk_bit(1'b0),
    .disk_wprot(1'b1), .disk_hd(1'b0), .trk_we(), .trk_wbit(), .trk_cells(), .arc_done(), .arc_side(), .arc_start(), .arc_end(), .arc_whole(),
    .scsi_img_mounted(3'b000), .scsi_img_blocks(32'd0), .scsi_io_lba(), .scsi_io_rd(), .scsi_io_wr(), .scsi_io_blk_cnt(),
    .scsi_io_ack(3'b000), .scsi_sd_buff_addr(13'd0), .scsi_sd_buff_dout(16'd0), .scsi_sd_buff_din(), .scsi_sd_buff_wr(1'b0),
    .scc_port_in(6'b110_110), .scc_port_out(), .audio_l(), .audio_r(),
    .dbg_addr(cpu_addr), .dbg_fc(cpu_fc), .dbg_as_n(cpu_as_n), .dbg_rw_n(cpu_rw_n), .dbg_dsack_n(dsack_n),
    .dbg_berr(berr), .dbg_halted(halted), .reset_out_n(reset_out_n), .dbg_regs(regs),
    .dbg_overlay(overlay), .dbg_late(late));

  wire [31:0] exp_pc = rom[1];

  // ------------------------------------------------------ cycle logger
  // at phi1 edges: a cycle's length is the clocks AS* is seen low, plus one
  localparam NLOG = 16, NIO = 400, NRING = 16, LOOP_CYCLES = 10000, NBE = 64, NRBV = 200;
  reg [31:0] log_addr [0:NLOG-1];
  reg  [2:0] log_fc   [0:NLOG-1];
  reg        log_rw   [0:NLOG-1];
  integer    log_len  [0:NLOG-1];
  integer cycles = 0, as_clocks = 0, berrs = 0, since_new = 0, ring_i = 0, io_n = 0, rbv_n = 0, be_n = 0;
  integer overlay_off = -1, ram_refd = 0, ram_vidd = 0, ram_rd = 0, ram_wr = 0, ram_rd_bad = 0, ram_wr_bad = 0, bursts = 0, burst_bad = 0;
  integer beat_k, beats, beat_last; reg [31:0] beat_gaps;
  integer len_hist [0:15];
  reg as_q = 1, prev_wr = 0, prev_bank = 0;
  reg [1:0] ds_q = 2'b11;
  integer gap = 9;
  reg [31:0] c_addr, c_data; reg [2:0] c_fc; reg c_rw, c_berr, c_ram, c_bank, c_ref, c_vid;
  reg [31:0] ring [0:NRING-1];
  reg [31:0] io_a [0:NIO-1], io_d [0:NIO-1]; reg io_rw_l [0:NIO-1]; integer io_cyc [0:NIO-1];
  reg [31:0] rbv_a [0:NRBV-1], rbv_d [0:NRBV-1]; reg rbv_rw [0:NRBV-1];
  reg [31:0] be_a [0:NBE-1], be_pc [0:NBE-1];
  reg        seen [0:131071];
  reg [31:0] last_fetch = 0;
  initial for (i = 0; i < 131072; i = i + 1) seen[i] = 0;
  initial for (i = 0; i < 16; i = i + 1) len_hist[i] = 0;

  // a cycle the MDU held (its `held`: a refresh window, or bank A behind a
  // video burst) at any clk while AS* is low: its length is not checked
  reg t_ref = 0, t_vid = 0;
  always @(posedge clk_sys) if (!cpu_as_n && machine.mdu.held) begin
    t_ref <= 1;
    if (machine.mdu.v_hold != 0 || machine.mdu.v_start) t_vid <= 1;
  end else if (cpu_as_n) begin t_ref <= 0; t_vid <= 0; end

  always @(posedge clk_sys) if (phi1 && reset_n) begin
    if (!cpu_as_n) begin if (t_ref || machine.mdu.held) c_ref = 1; if (t_vid) c_vid = 1; end
    if (!cpu_as_n && as_q) begin
      c_addr = cpu_addr; c_fc = cpu_fc; c_rw = cpu_rw_n; c_berr = 0; beats = 0; beat_k = 0; beat_gaps = 0;
      c_ram = (cpu_fc != 3'd7) && (cpu_addr[31:30] == 2'b00) && !overlay; c_bank = cpu_addr[26]; c_ref = 0; c_vid = 0;
    end
    if (!cpu_as_n) begin
      as_clocks = as_clocks + 1;
      if (dsack_n != 2'b11 && ds_q == 2'b11) begin          // a termination: DSACK* newly asserted
        c_data = c_rw ? machine.cpu_din : machine.cpu_dout;
        if (beats != 0) beat_gaps = {beat_gaps[23:0], 8'(as_clocks - beat_last)};
        else beat_k = as_clocks;
        beats = beats + 1; beat_last = as_clocks;
      end
      if (berr) c_berr = 1;
    end
    if (cpu_as_n && !as_q) begin
      if (cycles < NLOG) begin log_addr[cycles] = c_addr; log_fc[cycles] = c_fc; log_rw[cycles] = c_rw; log_len[cycles] = as_clocks + 1; end
      if (c_ram) begin
        if (c_ref) ram_refd = ram_refd + 1;
        if (c_vid) ram_vidd = ram_vidd + 1;
        // the first termination's clocks: AS* low clocks to it, plus S0 and S4/S5
        if (c_rw) begin
          ram_rd = ram_rd + 1;
          if (beat_k + 2 != ((prev_wr && prev_bank == c_bank && gap == 0) ? 6 : 5) && !c_ref) ram_rd_bad = ram_rd_bad + 1;
        end else begin
          ram_wr = ram_wr + 1;
          if (beat_k + 2 != ((prev_wr && prev_bank == c_bank && gap == 0) ? 5 : 4) && !c_ref) begin
            ram_wr_bad = ram_wr_bad + 1;
            if (ram_wr_bad <= 6) $display("      OFF: cycle %0d write %08x: %0d clocks (prev write %0d, same bank %0d, gap %0d)",
                                          cycles, c_addr, beat_k + 2, prev_wr, prev_bank == c_bank, gap);
          end
        end
        if (beats > 1) begin bursts = bursts + 1; if (beats != 4 || beat_gaps != 32'h00020202) burst_bad = burst_bad + 1; end
        if (beat_k + 2 < 16) len_hist[beat_k + 2] = len_hist[beat_k + 2] + 1;
      end
      prev_wr = c_ram && !c_rw; prev_bank = c_bank; gap = 0;
      if (c_berr) begin
        if (be_n < NBE) begin be_a[be_n] = c_addr; be_pc[be_n] = last_fetch; end
        be_n = be_n + 1; berrs = berrs + 1;
      end
      if (overlay_off < 0 && !overlay) overlay_off = cycles;
      if (c_fc != 3'd7 && c_addr[31:24] == 8'h50) begin
        if (io_n < NIO) begin io_a[io_n] = c_addr; io_d[io_n] = c_data; io_rw_l[io_n] = c_rw; io_cyc[io_n] = cycles; end
        io_n = io_n + 1;
        if (c_addr[17:13] == 5'h13) begin
          if (rbv_n < NRBV) begin rbv_a[rbv_n] = c_addr; rbv_d[rbv_n] = c_data; rbv_rw[rbv_n] = c_rw; end
          rbv_n = rbv_n + 1;
        end
      end
      if (c_fc == 3'd6) begin
        last_fetch = c_addr;
        since_new = since_new + 1;
        ring[ring_i] = c_addr; ring_i = (ring_i + 1) % NRING;
      end else since_new = since_new + 1;
      cycles = cycles + 1;
      as_clocks = 0;
    end else if (cpu_as_n) gap = gap + 1;
    as_q = cpu_as_n;
    ds_q = cpu_as_n ? 2'b11 : dsack_n;
  end

  // the loop detector: the kernel's own instruction addresses (with the
  // caches on a loop's fetches never reach the bus)
  reg [31:0] pc_q = 0;
  always @(posedge clk_sys) if (reset_n && machine.cpu.k_opcode_pc !== pc_q) begin
    pc_q = machine.cpu.k_opcode_pc;
    if (pc_q[31:28] == 4'h4 && !seen[pc_q[18:2]]) begin seen[pc_q[18:2]] = 1; since_new = 0; end
  end

  // ----------------------------------------------------------- scoring
  integer pass = 0, fails = 0;
  task check(input cond, input [8*96-1:0] what);
    begin if (cond) pass = pass + 1; else begin fails = fails + 1; $display("FAIL: %0s", what); end end
  endtask

  integer maxcyc = 200000;
  initial begin
    if (!$value$plusargs("CYCLES=%d", maxcyc)) maxcyc = 200000;
    $display("---- power-up: the ROM's vector PC %08x", exp_pc);
    repeat (20) @(posedge clk_sys); #1 reset_n = 1;
    while (!halted && since_new < LOOP_CYCLES && cycles < maxcyc) @(posedge clk_sys);
    repeat (40) @(posedge clk_sys);

    $display("---- the first %0d bus cycles", NLOG);
    for (i = 0; i < NLOG; i = i + 1)
      $display("      %3d  %08x  fc %0d  %s  %0d clocks", i, log_addr[i], log_fc[i], log_rw[i] ? "rd" : "wr", log_len[i]);
    check(log_addr[0] == 32'h0 && log_addr[1] == 32'h4 && log_fc[0] == 3'd6, "the vector from $0 and $4 (the overlay)");
    check(log_len[0] == 5 && log_len[1] == 5, "the vector reads are five clocks (ROM, G Table 5-9)");
    check((log_addr[2] == {exp_pc[31:2], 2'b00}) || (log_addr[2] == 32'h8 && log_addr[3] == {exp_pc[31:2], 2'b00}),
          "the first fetch is at the ROM's reset PC");
    check(overlay_off >= 2 && overlay_off <= 4, "the overlay ends at the first $4xxxxxxx access");

    $display("---- stopped after %0d cycles: %s", cycles,
             halted ? "the CPU HALTED" : (since_new >= LOOP_CYCLES) ? "a LOOP (no new instruction address)" : "the cycle limit");
    $display("      RAM: %0d reads (%0d off the documented length), %0d writes (%0d off), %0d bursts (%0d not 5-2-2-2)",
             ram_rd, ram_rd_bad, ram_wr, ram_wr_bad, bursts, burst_bad);
    $display("      %0d RAM cycles met a refresh window or a video burst (lengths not checked), %0d of them bank A behind a video burst", ram_refd, ram_vidd);
    $display("      video: %0d bursts (8 longs each), %0d vertical syncs, %0d FIFO underflows", vbursts, vsyncs, machine.rbv.dbg_underflow);
    $display("      RAM first-termination lengths: 4:%0d 5:%0d 6:%0d 7:%0d 8+:%0d (refresh adds up to 5)",
             len_hist[4], len_hist[5], len_hist[6], len_hist[7], len_hist[8] + len_hist[9] + len_hist[10] + len_hist[11] + len_hist[12]);
    $display("      memory port: %0d requests, %0d bursts, %0d late", mreqs, mbursts, late);
    $display("      %0d bus errors:", berrs);
    for (i = 0; i < be_n && i < NBE; i = i + 1) $display("        %08x  (last fetch %08x)", be_a[i], be_pc[i]);
    $display("      %0d RBV accesses:", rbv_n);
    for (i = 0; i < rbv_n && i < NRBV; i = i + 1) $display("        %s %08x  %02x", rbv_rw[i] ? "rd" : "wr", rbv_a[i], rbv_d[i][31:24]);
    $display("      the first %0d of %0d I/O accesses:", (io_n < NIO) ? io_n : NIO, io_n);
    for (i = 0; i < io_n && i < NIO; i = i + 1)
      $display("        %7d  %s %08x  %08x", io_cyc[i], io_rw_l[i] ? "rd" : "wr", io_a[i], io_d[i]);
    $display("      the last %0d fetch addresses:", NRING);
    for (i = 0; i < NRING; i = i + 1) $display("        %08x", ring[(ring_i + i) % NRING]);
    $display("      D6 %08x  D7 %08x", regs[63:32], regs[31:0]);

    check(late == 0, "the memory port was never late (80 ns to the first long)");
    check(vbursts > 0 && machine.rbv.dbg_underflow == 0, "the RBV fetched from bank A and its FIFO never ran dry (the run is under one frame)");
    check(ram_rd > 0 && ram_rd_bad == 0 && ram_wr_bad == 0, "every RAM read and write took its documented clocks (refresh aside: see the lengths)");
    check(burst_bad == 0, "every burst was 5-2-2-2 with four longs");
    check(!halted && since_new >= LOOP_CYCLES, "the run ends in a long loop (the RAM tests' fill), not a halt or the cycle limit");
    check(ram_wr > 1000, "the ROM wrote RAM: the RAM tests began");
    check(be_n == 5, "the only bus errors are the ROM's identification probes ($50F21C00 twice a pass, $58000000)");
    check(regs[63:32] === 32'h0, "D6 = 0: no start-up test has failed");

    if (fails == 0) $display("==== PASS: %0d checks", pass);
    else $display("==== FAIL: %0d of %0d checks failed", fails, pass + fails);
    $finish;
  end
endmodule
