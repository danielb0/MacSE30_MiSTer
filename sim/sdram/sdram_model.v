// sdram_model.v - a behavioural SDR SDRAM for the benches, written from the
// W9825G6KH (rev. A04) and AS4C32M16SB (rev. 1.4) datasheets to the worse
// of the two at every row (SE30_PLAN.md 3.2's table).  Not a vendor model:
// Micron's carries no redistribution terms, so this is ours.
//
// WHAT IT MODELS
//   4 banks x 8192 rows x 512 columns x 16 bits (the geometry every MiSTer
//   module presents), the command set, the mode register (CAS latency 2 or
//   3, burst length 1/2/4/8 sequential, write burst or single), auto
//   precharge on reads and writes, DQM on writes (no latency) and reads
//   (two clocks), and the data pins driven with the datasheet's tAC after
//   the launch edge and held tOH after the next, with X in between - so a
//   capture outside the eye reads X, not stale data.
//
// WHAT IT CHECKS (each a $display and a count in `errors`)
//   the power-up sequence: 200 us of NOP from the first clock, PRECHARGE
//   ALL, LOAD MODE and at least two AUTO REFRESH before the first ACTIVE;
//   tRCD, tRP, tRAS min, tRC, tRFC, tMRD, tWR (auto precharge) as clocks
//   of the datasheet's nanoseconds; ACTIVE on an open bank, READ/WRITE on a
//   closed one, REFRESH or LOAD MODE with a bank open.  It also keeps the
//   refresh count and the longest interval between refreshes after
//   power-up (`max_ref_gap`, ns), for the bench to hold to tREFI.

`timescale 1ns/1ps

module sdram_model (
  input             clk,               // the chip's clock: commands and data on its rising edge
  input             cke,
  input             cs_n,
  input             ras_n,
  input             cas_n,
  input             we_n,
  input       [1:0] ba,
  input      [12:0] addr,
  input       [1:0] dqm,
  inout      [15:0] dq
);

  // --------------------------------------------------- the datasheet
  localparam real tAC   = 6.0;          // access time from the edge, CL2 (ns)
  localparam real tOH   = 2.5;          // data hold after the next edge
  localparam real tHZ   = 5.4;
  localparam real tRCD  = 21.0;
  localparam real tRP   = 21.0;
  localparam real tRAS  = 42.0;
  localparam real tRC   = 63.0;
  localparam real tRFC  = 63.0;
  localparam real tMRD  = 14.0;
  localparam real tWR   = 14.0;
  localparam real tINIT = 200000.0;     // 200 us
  localparam real tSLOP = 0.01;         // rounding on the comparisons
  parameter  real tCK   = 10.638;       // the controller's clock, for the auto-precharge tRAS check

  // ------------------------------------------------------ the array
  reg [15:0] mem [0:(1<<24)-1];        // {bank, row[12:0], col[8:0]}
  parameter PRELOAD_HEX  = "";         // an image to load before the run (the ROM, for the machine bench)
  parameter PRELOAD_WORD = 0;          // at this word address
  initial if (PRELOAD_HEX != "") $readmemh(PRELOAD_HEX, mem, PRELOAD_WORD);

  // ------------------------------------------------------- the state
  reg        open_r [0:3];             // a row is open in the bank
  reg [12:0] row_r  [0:3];
  real       t_act  [0:3];             // when the bank was activated
  real       t_pre  [0:3];             // when its precharge began
  real       t_ref, t_mode, t_first_clk;
  reg        seen_clk, seen_pall, seen_mode;
  integer    refreshes_before_act;
  reg        init_ok;
  reg  [2:0] cl;                       // CAS latency
  integer    bl;                       // burst length
  reg        wbl_single;

  integer    errors = 0;
  integer    refreshes = 0;
  real       max_ref_gap = 0.0;
  real       last_ref = 0.0;
  integer    i;

  // --------------------------------------------------- read pipeline
  // a word due on the k-th edge after this one: valid flag, address
  reg        rd_v [0:7];
  reg [23:0] rd_a [0:7];
  reg        rd_pre_v [0:7];           // the auto precharge due after the last word
  reg  [1:0] rd_pre_b [0:7];
  reg  [1:0] dqm_hist [0:1];           // read DQM: two clocks of latency
  reg        driving = 0;              // a word was launched at the previous edge

  // ---------------------------------------------------- write burst
  integer    wr_left;                  // beats still to take
  reg [23:0] wr_a;
  reg  [1:0] wr_bank;
  reg        wr_ap;

  // ------------------------------------------------------ the pins
  reg [15:0] dq_drv = 16'hzzzz;
  assign dq = dq_drv;

  task err(input [8*48-1:0] what);
    begin errors = errors + 1; $display("SDRAM MODEL ERROR t=%0t: %0s", $time, what); end
  endtask

  function [23:0] burst_col(input [23:0] a, input integer k);
    // sequential burst: the low log2(bl) column bits count, wrapping
    reg [8:0] c;
    begin
      c = a[8:0];
      case (bl)
        1: burst_col = a;
        2: burst_col = {a[23:9], c[8:1], c[0] + k[0]};
        4: burst_col = {a[23:9], c[8:2], c[1:0] + k[1:0]};
        default: burst_col = {a[23:9], c[8:3], c[2:0] + k[2:0]};
      endcase
    end
  endfunction

  initial begin
    for (i = 0; i < 4; i = i + 1) begin open_r[i] = 0; row_r[i] = 0; t_act[i] = -1000.0; t_pre[i] = -1000.0; end
    for (i = 0; i < 8; i = i + 1) begin rd_v[i] = 0; rd_a[i] = 0; rd_pre_v[i] = 0; rd_pre_b[i] = 0; end
    for (i = 0; i < 2; i = i + 1) dqm_hist[i] = 2'b11;
    seen_clk = 0; seen_pall = 0; seen_mode = 0; refreshes_before_act = 0; init_ok = 0;
    cl = 2; bl = 1; wbl_single = 0; wr_left = 0; wr_a = 0; wr_bank = 0; wr_ap = 0;
    t_ref = -1000.0; t_mode = -1000.0; t_first_clk = 0.0;
  end

  wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  real now;

  always @(posedge clk) begin
    now = $realtime;
    if (!seen_clk) begin seen_clk = 1; t_first_clk = now; end

    // ---- the data pins for this edge: the word launched at the previous
    // edge is held tOH after this one, then X; this edge's word (if any)
    // appears tAC after it, or the pins go Z at tHZ.  Read DQM has two
    // clocks of latency: the mask sampled two edges ago applies per byte.
    if (driving) dq_drv <= #(tOH) 16'hxxxx;
    if (rd_v[0])
      dq_drv <= #(tAC) { dqm_hist[1][1] ? 8'hzz : mem[rd_a[0]][15:8],
                         dqm_hist[1][0] ? 8'hzz : mem[rd_a[0]][7:0] };
    else if (driving)
      dq_drv <= #(tHZ) 16'hzzzz;
    driving = rd_v[0];
    // auto precharge falling due this edge
    if (rd_pre_v[0]) begin
      open_r[rd_pre_b[0]] = 0; t_pre[rd_pre_b[0]] = now;
    end
    // shift the pipeline
    for (i = 0; i < 7; i = i + 1) begin
      rd_v[i] = rd_v[i+1]; rd_a[i] = rd_a[i+1]; rd_pre_v[i] = rd_pre_v[i+1]; rd_pre_b[i] = rd_pre_b[i+1];
    end
    rd_v[7] = 0; rd_pre_v[7] = 0;
    dqm_hist[1] = dqm_hist[0]; dqm_hist[0] = dqm;

    // ---- a write burst in progress takes this edge's data
    if (wr_left > 0) begin
      if (!dqm[1]) mem[wr_a][15:8] = dq[15:8];
      if (!dqm[0]) mem[wr_a][7:0]  = dq[7:0];
      wr_left = wr_left - 1;
      wr_a = burst_col(wr_a, 1);       // next column of the burst (bl >= 2 only reaches here)
      if (wr_left == 0 && wr_ap) begin
        // precharge after tWR from the last data
        open_r[wr_bank] = 0; t_pre[wr_bank] = now + tWR;
      end
    end

    // ---- the command
    if (cke && !cs_n) case (cmd[2:0])
      3'b111: ;                                                   // NOP

      3'b011: begin                                               // ACTIVE
        if (!init_ok) begin
          if (!seen_pall || !seen_mode || refreshes_before_act < 2) err("ACTIVE before the power-up sequence completed");
          init_ok = 1;
        end
        if (open_r[ba]) err("ACTIVE on a bank with a row open");
        if (now - t_pre[ba] < tRP - tSLOP) err("ACTIVE before tRP");
        if (now - t_act[ba] < tRC - tSLOP) err("ACTIVE before tRC");
        if (now - t_ref < tRFC - tSLOP) err("ACTIVE before tRFC");
        if (now - t_mode < tMRD - tSLOP) err("ACTIVE before tMRD");
        open_r[ba] = 1; row_r[ba] = addr; t_act[ba] = now;
      end

      3'b101: begin                                               // READ
        if (!open_r[ba]) err("READ on a closed bank");
        if (now - t_act[ba] < tRCD - tSLOP) err("READ before tRCD");
        // CAS latency is "the number of clock cycles from the assertion of
        // the Read command to the first read data" (AS4C32M16SB 1.4, the
        // mode register; tCAC(min) <= CL x tCK), the first word "available
        // following the CAS latency after the issue of the Read command",
        // "each subsequent data-out element valid by the next positive
        // clock edge".  So the first word is VALID at edge n + cl and is
        // launched (tAC) from the edge before it, n + cl - 1.  This model
        // launched it from n + cl until 2026-09-27 - MacLC's reading, one
        // clock late - and the first board reading (SE30_PLAN.md 3.8 item
        // 15) showed the chip agreeing with the datasheet: the controller
        // built to the late model captured the burst's second word first.
        for (i = 0; i < bl; i = i + 1) begin
          rd_v[cl + i - 2] = 1;                                   // launched cl - 1 edges after this one, valid at cl
          rd_a[cl + i - 2] = burst_col({ba, row_r[ba], addr[8:0]}, i);
        end
        if (addr[10]) begin                                       // auto precharge after the last word
          rd_pre_v[cl + bl - 2] = 1; rd_pre_b[cl + bl - 2] = ba;
          if (now + (cl + bl - 1) * tCK - t_act[ba] < tRAS - tSLOP) err("READ auto-precharge would end before tRAS");
        end
      end

      3'b100: begin                                               // WRITE: this edge's data is the first beat
        if (!open_r[ba]) err("WRITE on a closed bank");
        if (now - t_act[ba] < tRCD - tSLOP) err("WRITE before tRCD");
        wr_a = {ba, row_r[ba], addr[8:0]}; wr_bank = ba; wr_ap = addr[10];
        if (!dqm[1]) mem[wr_a][15:8] = dq[15:8];
        if (!dqm[0]) mem[wr_a][7:0]  = dq[7:0];
        wr_left = (wbl_single ? 1 : bl) - 1;
        wr_a = burst_col(wr_a, 1);
        if (wr_left == 0 && wr_ap) begin open_r[ba] = 0; t_pre[ba] = now + tWR; end
      end

      3'b010: begin                                               // PRECHARGE
        if (addr[10]) begin
          for (i = 0; i < 4; i = i + 1) if (open_r[i]) begin
            if (now - t_act[i] < tRAS - tSLOP) err("PRECHARGE ALL before tRAS");
            open_r[i] = 0; t_pre[i] = now;
          end
          if (!init_ok) seen_pall = 1;
        end else begin
          if (open_r[ba]) begin
            if (now - t_act[ba] < tRAS - tSLOP) err("PRECHARGE before tRAS");
            open_r[ba] = 0; t_pre[ba] = now;
          end
        end
      end

      3'b001: begin                                               // AUTO REFRESH
        for (i = 0; i < 4; i = i + 1) if (open_r[i]) err("AUTO REFRESH with a bank open");
        for (i = 0; i < 4; i = i + 1) if (now - t_pre[i] < tRP - tSLOP) err("AUTO REFRESH before tRP");
        if (now - t_ref < tRFC - tSLOP) err("AUTO REFRESH before tRFC");
        if (!init_ok) refreshes_before_act = refreshes_before_act + 1;
        else begin
          if (last_ref > 0.0 && now - last_ref > max_ref_gap) max_ref_gap = now - last_ref;
          last_ref = now;
        end
        refreshes = refreshes + 1;
        t_ref = now;
      end

      3'b000: begin                                               // LOAD MODE
        for (i = 0; i < 4; i = i + 1) if (open_r[i]) err("LOAD MODE with a bank open");
        if (!seen_pall) err("LOAD MODE before PRECHARGE ALL");
        case (addr[6:4]) 3'b010: cl = 2; 3'b011: cl = 3; default: err("LOAD MODE: reserved CAS latency"); endcase
        case (addr[2:0]) 3'b000: bl = 1; 3'b001: bl = 2; 3'b010: bl = 4; 3'b011: bl = 8; default: err("LOAD MODE: unsupported burst length"); endcase
        if (addr[3]) err("LOAD MODE: interleaved bursts not modelled");
        if (addr[8:7] != 2'b00) err("LOAD MODE: test mode bits set");
        wbl_single = addr[9];
        seen_mode = 1; t_mode = now;
      end
    endcase

    // the power-up pause: nothing but NOP for 200 us from the first clock
    if (cke && !cs_n && cmd[2:0] != 3'b111 && !init_ok && now - t_first_clk < tINIT - tSLOP)
      err("a command inside the 200 us power-up pause");
  end

endmodule
