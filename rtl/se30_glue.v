// se30_glue.v - the SE/30's GLUE: address decode, acknowledge, RAM and ROM
// control, the E and SCC clocks, the bus-error timeout and the interrupt
// encoder, to the contract of SE30_PLAN.md 2.11.
//
// WHAT IT IS
//   GLUE (UI8) has no internal documentation; this is its contract - the
//   Guide's function list and wait-state table, the pin list, the ROM's
//   expectations - written as a cycle machine (plan 2.3, 2.11) and held to
//   sim/glue/tb_se30_glue.v.  Where 2.11 leaves a number open the choice
//   is marked OPEN below and the bench holds the envelope.
//
// THE BUS THIS IS WRITTEN TO (plan 2.13)
//   Not the 68030's pins: the TG68K wrapper's bus, which is 68000-shaped -
//   16-bit data, UDS*/LDS*, AS*, R/W*, DTACK*, VPA*, BERR, IPL - with a
//   32-bit address and a flag, lw, that marks both 16-bit beats of a
//   32-bit access.  Every 8-bit device sits on D15-D8 as it sits on D31-D24
//   of the real machine; GLUE runs one device cycle per byte of a beat,
//   high byte first, at A then A+1, which is the 68030's dynamic bus
//   sizing done here because the wrapper cannot.  A single-byte beat gets
//   its byte on both lanes.
//
// TIMING (plan 2.11.3, counted as the bench counts: AS* low to DTACK*
// low inclusive, plus one)
//   RAM, ROM      4 clocks a beat; 2 when lw, so a longword is 4 in all.
//                 The request goes out with AS*; the acknowledge is
//                 followed, not assumed, and the word beat is padded to
//                 the 68030's one-wait-state count.
//   SWIM, SCSI    4 (one wait state), the pseudo-DMA port and the
//                 acknowledged expansion window the same.
//   ASC           5 read, 4 write.
//   SCC           4 or more: the select is held off until 2.2 us after the
//                 previous SCC cycle released its select, whatever ran in
//                 between.
//   SCSI handshake  the DACK port at $50006000 strobes only when DRQ is
//                 high; no DRQ, no acknowledge, and UI6 bus-errors it.
//   VIA           E-synchronous: the select must be up before E rises, the
//                 strobe is E's last high clock, the acknowledge comes at
//                 E's fall.  12 to 32 clocks by alignment.
//   slot          the card's DSACK0*, followed; the video PALs' 5/6/7.
//   none          $50008000-$5000FFFF, $51000000-$5FFFFFFF, an empty
//                 slot, the I/O windows with A17 = 1: no acknowledge, and
//                 UI6 asserts BERR once HSYNC* has been seen high, low and
//                 high again with AS* held (18.4-63.3 us).  FC = 7 cycles
//                 are never timed out; the interrupt acknowledge (A17-A16
//                 = 11) autovectors, the rest get nothing.
//
// CLOCKS
//   E is C16M/20, ten clocks high, ten low (duty OPEN, plan 2.13); C3M is
//   15 pulses in every 64 clocks, a phase accumulator (pattern OPEN);
//   refresh is a pulse every 244 clocks, 15.6 us, with a four-clock
//   window in which a RAM request waits.

`timescale 1ns/1ps

module se30_glue (
  input         clk,
  input         c16_en,                // one clk per C16M period (15.6672 MHz)
  input         reset_n,

  // CPU
  input  [31:0] cpu_addr,
  input         cpu_as_n,
  input         cpu_uds_n,
  input         cpu_lds_n,
  input         cpu_rw_n,              // 1 = read
  input   [2:0] cpu_fc,
  input         cpu_lw,                // this beat is half of a 32-bit access
  input  [15:0] cpu_dout,              // CPU write data
  output [15:0] cpu_din,               // read data to the CPU
  output        dtack_n,
  output        berr,
  output        vpa_n,                 // interrupt acknowledge: autovector
  output  [2:0] ipl_n,

  // RAM: 16-bit word port
  output        ram_req,
  output        ram_we,
  output [25:0] ram_addr,              // word address, flat over both banks (128MB)
  output  [1:0] ram_ds,                // {upper, lower} byte enables
  output [15:0] ram_wdata,
  input  [15:0] ram_rdata,
  input         ram_ack,
  output reg    ram_refresh,           // one pulse per refresh cycle

  // ROM: 16-bit word port, 256KB
  output        rom_req,
  output [16:0] rom_addr,
  input  [15:0] rom_rdata,
  input         rom_ack,

  // 8-bit devices
  output        via1_sel,
  output        via2_sel,
  output        scc_sel,
  output        scsi_sel,              // $50010000: register file through CS*
  output        scsi_dack,             // $50012000 and $50006000: the DMA port through DACK*
  output        asc_sel,
  output        swim_sel,
  output        exp_sel,               // $50018000: acknowledged, nothing there
  output reg    dev_strobe,            // one c16 clock: the device latches (write) or must present (read)
  output [12:0] dev_addr,              // byte address within the device window
  output        dev_rw,                // 1 = read
  output  [7:0] dev_wdata,
  input   [7:0] dev_rdata,
  input         scsi_drq,
  output        e_clk,                 // 783.36 kHz to the VIAs
  output reg    c3m_en,                // 3.672 MHz average: one pulse per SCC PCLK

  // slot $E and the PDS
  output        slot_sel,              // NUBUS*, active high here
  output        slot_a0,               // A0 of the byte in progress (the bus sizing above)
  input         slot_dsack0_n,
  input   [7:0] slot_rdata,

  // interrupts
  input         via1_irq_n,
  input         via2_irq_n,
  input         scc_irq_n,
  input         nmi_n,
  input   [6:1] slot_irq_n,
  output        slot_irq_or_n,         // to VIA2 CA1

  // control
  input         overlay,               // VIA1 PA4
  input   [1:0] ramsiz,                // VIA2 PA7:6
  input         hsync_n                // from the video PALs: the UI6 timeout's clock
);

  localparam SCC_HOLD = 6'd33;         // clocks from select release to the next SCC select, 2.2 us
  localparam REF_PERIOD = 8'd244;      // 15.6 us
  localparam REF_WINDOW = 8'd4;        // one RAM access cycle

  // ------------------------------------------------------------- decode
  // Plan 2.11.2: what GLUE's pins allow.  RAM and ROM on A31-A30 and
  // OVERLAY; I/O on A31-A24 = $50 and A17-A13, A23-A18 ignored; the slots
  // on A31-A29 >= 011.  FC = 7 is CPU space: only the acknowledge answers.
  wire       fc7    = (cpu_fc == 3'd7);
  wire       iack   = fc7 && (cpu_addr[17:16] == 2'b11);
  wire       low_sp = (cpu_addr[31:30] == 2'b00);
  wire       d_ram  = !fc7 && low_sp && !overlay;
  wire       d_rom  = !fc7 && ((cpu_addr[31:28] == 4'h4) || (low_sp && overlay));
  wire       d_io   = !fc7 && (cpu_addr[31:24] == 8'h50) && !cpu_addr[17];
  wire [3:0] win    = cpu_addr[16:13];
  wire       d_via1 = d_io && (win == 4'h0);
  wire       d_via2 = d_io && (win == 4'h1);
  wire       d_scc  = d_io && (win == 4'h2);
  wire       d_hs   = d_io && (win == 4'h3);          // SCSI handshake: DACK, wait for DRQ
  wire       d_scsi = d_io && (win == 4'h8);
  wire       d_dma  = d_io && (win == 4'h9);          // SCSI pseudo-DMA: DACK, no wait
  wire       d_asc  = d_io && (win == 4'hA);
  wire       d_swim = d_io && (win == 4'hB);
  wire       d_exp  = d_io && (win[3:2] == 2'b11);    // $50018000-$5001FFFF: acknowledged
  wire       d_slot = !fc7 && (cpu_addr[31:29] >= 3'b011);
  wire       d_via  = d_via1 || d_via2;
  wire       d_mem  = d_ram || d_rom;
  wire       d_dev  = d_via || d_scc || d_hs || d_scsi || d_dma || d_asc || d_swim || d_exp || d_slot;

  // ------------------------------------------------------------ the cycle
  reg        active;                   // AS* sampled low, until sampled high
  reg        done;                     // acknowledged; DTACK* held until AS* negates
  reg        mem_done;                 // the RAM or ROM port has answered
  reg        cur_lo;                   // byte in progress: 0 = high (A), 1 = low (A+1)
  reg  [1:0] dcnt;                     // clocks into the device byte cycle
  reg        via_armed;                // the VIA select was up when E rose
  reg [15:0] din_r;
  reg  [5:0] scc_hold;
  reg        ff1, ff2, berr_r;         // UI6's timeout, below

  wire need_hi = !cpu_uds_n;
  wire need_lo = !cpu_lds_n;
  wire last_byte = cur_lo || !need_lo;

  // E and the SCC hold-off
  reg  [4:0] ecnt;                     // 0..19
  assign e_clk = (ecnt >= 5'd10);
  wire e_rise_next = (ecnt == 5'd9);
  wire e_fall_next = (ecnt == 5'd19);

  // the device byte cycle: strobe on clock cap-1, capture on clock cap.
  // The SCC's select rises with its strobe (CE with RD or WR, as an 8530
  // is driven) once the hold-off has expired, and its data is taken two
  // clocks later.
  wire [1:0] cap = (d_asc && cpu_rw_n) ? 2'd2 : 2'd1;
  wire dc_adv = active && (!d_hs || dcnt != 0 || scsi_drq);    // the handshake waits at 0 for DRQ
  wire fixed_port = d_hs || d_scsi || d_dma || d_asc || d_swim || d_exp;
  wire scc_go  = d_scc && (dcnt == 0) && (scc_hold == 0);
  wire capture = active && ( (fixed_port && dcnt == cap && dc_adv)
                          || (d_scc && dcnt == 2'd2)
                          || (d_via && via_armed && e_fall_next)
                          || (d_slot && !slot_dsack0_n) );
  wire [7:0] rbyte = d_slot ? slot_rdata : dev_rdata;

  // RAM and ROM: the request goes out with AS*, once
  reg  [7:0] refcnt;
  wire ref_busy = (refcnt < REF_WINDOW);
  assign ram_req = !cpu_as_n && d_ram && !mem_done && !ref_busy;
  assign rom_req = !cpu_as_n && d_rom && cpu_rw_n && !mem_done;
  wire mem_ack = ram_ack || rom_ack || (active && d_rom && !cpu_rw_n);   // a ROM write: acknowledged, no effect
  wire fast_ack = !cpu_as_n && cpu_lw && (ram_ack || rom_ack);          // the 2-clock beat of a longword

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      active <= 0; done <= 0; mem_done <= 0; cur_lo <= 0; dcnt <= 0;
      via_armed <= 0; din_r <= 0; dev_strobe <= 0; scc_hold <= 0;
    end else if (c16_en) begin
      dev_strobe <= 0;
      if (scc_hold != 0) scc_hold <= scc_hold - 1'b1;

      if (!active) begin
        if (!cpu_as_n) begin
          active <= 1; done <= 0; mem_done <= 0; dcnt <= 0; via_armed <= 0;
          cur_lo <= !need_hi;
          if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
        end
      end else if (cpu_as_n) begin
        active <= 0; done <= 0; mem_done <= 0; dcnt <= 0;
        if (d_scc) scc_hold <= SCC_HOLD;
      end else if (!done) begin
        // memory
        if (d_mem) begin
          if (mem_ack) begin
            mem_done <= 1;
            if (ram_ack) din_r <= ram_rdata;
            if (rom_ack) din_r <= rom_rdata;
            if (cpu_lw) done <= 1;
          end
          if (mem_done) done <= 1;
        end
        // an 8-bit port
        if (d_dev) begin
          if (d_scc) begin
            if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
            else if (dcnt != 0 && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
          end else begin
            if (dc_adv && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
            if (fixed_port && dc_adv && dcnt == cap - 1'b1) dev_strobe <= 1;
          end
          if (d_via) begin
            if (e_rise_next) via_armed <= 1;
            if (via_armed && ecnt == 5'd18) dev_strobe <= 1;
          end
          if (capture) begin
            if (need_hi && need_lo) begin
              if (cur_lo) din_r[7:0] <= rbyte; else din_r[15:8] <= rbyte;
            end else din_r <= {rbyte, rbyte};
            if (last_byte) done <= 1;
            else begin cur_lo <= 1; dcnt <= 0; via_armed <= 0; end
          end
        end
      end
    end

  assign cpu_din  = din_r;
  assign dtack_n  = !(!cpu_as_n && (done || fast_ack) && !berr_r);
  assign vpa_n    = !(!cpu_as_n && iack);

  // selects follow the cycle, as chip selects follow AS*; the slot's drops
  // with the acknowledge so the video PALs do not take a second cycle
  assign via1_sel  = active && d_via1;
  assign via2_sel  = active && d_via2;
  assign scc_sel   = active && d_scc && (dcnt != 0);
  assign scsi_sel  = active && d_scsi;
  assign scsi_dack = active && (d_dma || d_hs);
  assign asc_sel   = active && d_asc;
  assign swim_sel  = active && d_swim;
  assign exp_sel   = active && d_exp;
  assign slot_sel  = active && d_slot && !done;
  assign slot_a0   = cur_lo;
  assign dev_addr  = {cpu_addr[12:1], cur_lo};
  assign dev_rw    = cpu_rw_n;
  assign dev_wdata = cur_lo ? cpu_dout[7:0] : cpu_dout[15:8];

  // ------------------------------------------------------------ RAM, ROM
  // Bank B follows bank A at the RAMSIZ boundary (Guide Table 4-10); the
  // bits above the two banks are ignored, so the contents repeat.
  assign ram_addr  = (ramsiz == 2'd0) ? {6'b0, cpu_addr[20:1]} :
                     (ramsiz == 2'd1) ? {4'b0, cpu_addr[22:1]} :
                     (ramsiz == 2'd2) ? {2'b0, cpu_addr[24:1]} :
                                        cpu_addr[26:1];
  assign ram_we    = !cpu_rw_n;
  assign ram_ds    = {need_hi, need_lo};
  assign ram_wdata = cpu_dout;
  assign rom_addr  = cpu_addr[17:1];

  // ------------------------------------------------------------- clocks
  reg [6:0] c3m_acc;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      ecnt <= 0; refcnt <= 0; ram_refresh <= 0; c3m_acc <= 0; c3m_en <= 0;
    end else if (c16_en) begin
      ecnt <= e_fall_next ? 5'd0 : ecnt + 1'b1;
      refcnt <= (refcnt == REF_PERIOD - 1) ? 8'd0 : refcnt + 1'b1;
      ram_refresh <= (refcnt == REF_PERIOD - 1);
      if (c3m_acc + 7'd15 >= 7'd64) begin c3m_acc <= c3m_acc + 7'd15 - 7'd64; c3m_en <= 1; end
      else begin c3m_acc <= c3m_acc + 7'd15; c3m_en <= 0; end
    end

  // -------------------------------------------------- bus error: UI6
  // Plan 2.11.4.  Two flip-flops, cleared while the system AS* is
  // negated: the first sets on HSYNC* high, the second on HSYNC* low
  // after it, and BERR follows the next HSYNC* high.  FC = 7 is not a
  // system cycle, so coprocessor and acknowledge cycles never time out.
  wire sys_as = !cpu_as_n && !fc7;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin ff1 <= 0; ff2 <= 0; berr_r <= 0; end
    else if (c16_en) begin
      if (!sys_as) begin ff1 <= 0; ff2 <= 0; berr_r <= 0; end
      else begin
        if (hsync_n) ff1 <= 1;
        if (ff1 && !hsync_n) ff2 <= 1;
        if (ff1 && ff2 && hsync_n) berr_r <= 1;
      end
    end
  assign berr = berr_r && sys_as && !done;

  // --------------------------------------------------------- interrupts
  // Guide Table 3-4: the highest level only, autovectored; the slot lines
  // OR into VIA2 CA1 and do not reach IPL directly.
  assign ipl_n = !nmi_n      ? 3'b000 :
                 !scc_irq_n  ? 3'b011 :
                 !via2_irq_n ? 3'b101 :
                 !via1_irq_n ? 3'b110 : 3'b111;
  assign slot_irq_or_n = &slot_irq_n;

endmodule
