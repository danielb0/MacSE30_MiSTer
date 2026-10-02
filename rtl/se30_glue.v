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
// THE BUS (plan 2.11.1, verbatim since 1.13 item 4)
//   The 68030's: a 32-bit address, AS*, DS*, R/W*, FC, SIZ1-0, 32-bit
//   data, DSACK1*/DSACK0* back, BERR, IPL.  RAM and ROM are 32-bit ports
//   and answer DSACK "00"; every I/O device is an 8-bit port on D31-D24
//   and answers DSACK0* alone ("10"); the processor splits a word or a
//   longword into the byte cycles itself (dynamic bus sizing, UM 7.2), so
//   GLUE runs exactly one device cycle per bus cycle.  RAM's byte enables
//   are Table 7-7's for a 32-bit port: lanes A1A0 to the end of SIZ or of
//   the long, whichever comes first.  AVEC is grounded on the board and
//   UI6 keeps AS* from the system for FC = 7, so an interrupt acknowledge
//   gets no answer from GLUE at all: the processor autovectors.
//
// TIMING (plan 2.11.3, counted as the 68030 cycle runs: S0 to S5 in C16M
// clocks; GLUE first sees AS*, asserted at S1, a clock after S0, and the
// processor takes DSACK* at the falling edge of the clock it appears in,
// then runs S4/S5 - so a one-wait-state cycle is 4 clocks with DSACK*
// asserted in the clock after GLUE first sees AS*)
//   RAM, ROM      4 clocks: the request goes out with AS*; the port's
//                 acknowledge, a clock later, is the cycle's.
//   SWIM, SCSI    4 (one wait state), the pseudo-DMA port and the
//                 acknowledged expansion window the same.
//   ASC           5 read, 4 write.
//   SCC           4 or more: the select is held off until 2.2 us after the
//                 previous SCC cycle released its select, whatever ran in
//                 between.
//   SCSI handshake  the DACK port at $50006000 strobes only when DRQ is
//                 high; no DRQ, no acknowledge, and UI6 bus-errors it.
//   VIA           E-synchronous, E re-phased to the access (plan 4.4): the
//                 select is up a clock before E rises, the access's high
//                 phase is four clocks with the strobe in the last, the
//                 acknowledge follows the fall.  7 to 16 clocks by phase,
//                 about 10 on average - the Guide's "average of 0.5 us".
//   slot          the card's DSACK0*, followed; the video PALs' 5/6/7.
//   none          $50008000-$5000FFFF, $51000000-$5FFFFFFF, an empty
//                 slot, the I/O windows with A17 = 1: no acknowledge, and
//                 UI6 asserts BERR once HSYNC* has been seen high, low and
//                 high again with AS* held (18.4-63.3 us).  FC = 7 cycles
//                 are never timed out.
//   The 68030's write data is valid from S2, the clock in which GLUE
//   first sees AS*, so a write's device strobe does not wait for DS*
//   (which the processor asserts a clock later); DS* is on the bus and
//   unused by these timings.
//
// CLOCKS
//   E averages C16M/20 exactly - one rise per 20-clock reference period,
//   ten high and ten low when idle, the rise taken early and the high
//   phase cut to four for a VIA access (plan 4.4; the 4-clock phase
//   minimum is OPEN); C3M is
//   15 pulses in every 64 clocks, a phase accumulator (pattern OPEN);
//   refresh is a pulse every 244 clocks, 15.6 us, with a four-clock
//   window in which a RAM request waits.

`timescale 1ns/1ps

module se30_glue (
  input         clk,
  input         c16_en,                // one clk per C16M period (15.6672 MHz)
  input         reset_n,

  // CPU: the 68030's bus
  input  [31:0] cpu_addr,
  input         cpu_as_n,
  input         cpu_ds_n,
  input         cpu_rw_n,              // 1 = read
  input   [2:0] cpu_fc,
  input   [1:0] cpu_siz,               // SIZ1 SIZ0: bytes remaining, 00 = four
  input  [31:0] cpu_dout,              // CPU write data, lane 0 = D31:24
  output [31:0] cpu_din,               // read data to the CPU
  output  [1:0] dsack_n,               // {DSACK1*, DSACK0*}: 00 a 32-bit port, 10 an 8-bit one, 11 wait
  output        berr,
  output  [2:0] ipl_n,

  // RAM: 32-bit port
  // the address decode without AS*, for the SDRAM controller's early
  // start on the 68030's ECS (plan 3.2): RAM or ROM, and which of them
  output        mem_early,
  output        rom_early,

  output        ram_req,
  output        ram_we,
  output [24:0] ram_addr,              // longword address, flat over both banks (128MB)
  output  [3:0] ram_be,                // byte enables, bit 3 = D31:24
  output [31:0] ram_wdata,
  input  [31:0] ram_rdata,
  input         ram_ack,
  output reg    ram_refresh,           // one pulse per refresh cycle

  // ROM: 32-bit port, 256KB
  output        rom_req,
  output [15:0] rom_addr,              // longword address
  input  [31:0] rom_rdata,
  input         rom_ack,

  // 8-bit devices, on D31-D24
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

  // the 68882 (plan 8.6.12, 8.9 item 7d): CPU space type 2, coprocessor
  // ID 1 - "the GLUE decodes the address and asserts the device select to
  // the FPU" (Guide p. 107); the FPU terminates its own cycles
  output        fpu_sel,
  input   [1:0] fpu_dsack_n,
  input  [31:0] fpu_rdata,

  // slot $E and the PDS
  output        slot_sel,              // NUBUS*, active high here
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
  // on A31-A29 >= 011.  FC = 7 is CPU space: the FPU's cycles (A19-A16 =
  // 0010, A15-A13 = its ID 001) and nothing else answers.
  wire       fc7    = (cpu_fc == 3'd7);
  wire       d_fpu  = fc7 && (cpu_addr[19:13] == 7'b0010_001);
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

  // the byte enables of a 32-bit port (UM Table 7-7): lanes A1A0 to the
  // end of SIZ or of the long
  wire [2:0] siz_n = (cpu_siz == 2'b00) ? 3'd4 : {1'b0, cpu_siz};
  wire [2:0] a10   = {1'b0, cpu_addr[1:0]};
  wire [3:0] be    = { (a10 == 3'd0),
                       (a10 <= 3'd1) && (a10 + siz_n > 3'd1),
                       (a10 <= 3'd2) && (a10 + siz_n > 3'd2),
                       (a10 + siz_n > 3'd3) };

  // ------------------------------------------------------------ the cycle
  reg        active;                   // AS* sampled low, until sampled high
  reg        done;                     // acknowledged; DSACK* held until AS* negates
  reg        mem_done;                 // the RAM or ROM port has answered
  reg  [1:0] dcnt;                     // clocks into the device cycle
  reg [31:0] din_r;
  reg  [7:0] dev_q;                    // a device's byte, as it presented it on the capture clock
  reg  [5:0] scc_hold;
  reg        ff1, ff2, berr_r;         // UI6's timeout, below

  // E (plan 4.4).  eref is the 20-clock reference, E nominally high for
  // eref 10-19; e_r is the E driven.  Each reference period has one rise:
  // at eref 9 -> 10 if nothing asked earlier, or as soon as a VIA access
  // is waiting with E low for four clocks; a period whose rise has been
  // taken (rose) does not rise again, so after an access E stays low
  // until the next period's.  A high phase is the reference's ten clocks,
  // or four when it serves an access (via_armed: a VIA access was waiting
  // when E rose), or is cut to four when an access arrives during it.
  // The strobe is the access phase's last high clock.
  reg  [4:0] eref;
  reg        e_r, rose, via_armed;
  reg  [3:0] eph;                      // clocks in E's current phase, saturating
  assign e_clk = e_r;
  wire via_pending = !cpu_as_n && d_via && !done;
  wire e_rise    = !e_r && !rose && (eph >= 4'd3) && (via_pending || eref >= 5'd9);
  wire e_fall    =  e_r && (via_armed ? (eph == 4'd3) : ((eref == 5'd19) || (via_pending && eph >= 4'd3)));
  wire e_strobe  =  e_r && via_armed && (eph == 4'd2);   // the next clock is the access's last high one
  wire e_capture =  e_r && via_armed && (eph == 4'd3);

  // the device cycle, counted from the clock AS* is first seen: strobe on
  // clock cap-1, capture (and the acknowledge) on clock cap.  The SCC's
  // select rises with its strobe (CE with RD or WR, as an 8530 is driven)
  // once the hold-off has expired, and its data is taken two clocks later.
  wire [1:0] cap = (d_asc && cpu_rw_n) ? 2'd2 : 2'd1;
  wire dc_adv = !cpu_as_n && (!d_hs || dcnt != 0 || scsi_drq);          // the handshake waits at 0 for DRQ
  wire fixed_port = d_hs || d_scsi || d_dma || d_asc || d_swim || d_exp;
  wire scc_go  = d_scc && (dcnt == 0) && (scc_hold == 0);
  wire capture = active && ( (fixed_port && dcnt == cap && dc_adv)
                          || (d_scc && dcnt == 2'd2)
                          || (d_via && e_capture)
                          || (d_slot && !slot_dsack0_n) );
  wire [7:0] rbyte = d_slot ? slot_rdata : dev_rdata;

  // RAM and ROM: the request goes out with AS*, once
  reg  [7:0] refcnt;
  wire ref_busy = (refcnt < REF_WINDOW);
  assign ram_req = !cpu_as_n && d_ram && !mem_done && !ref_busy;
  assign rom_req = !cpu_as_n && d_rom && cpu_rw_n && !mem_done;
  assign mem_early = d_mem;
  assign rom_early = d_rom;
  wire mem_ack = ram_ack || rom_ack || (active && d_rom && !cpu_rw_n);   // a ROM write: acknowledged, no effect

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      active <= 0; done <= 0; mem_done <= 0; dcnt <= 0;
      din_r <= 0; dev_q <= 0; dev_strobe <= 0; scc_hold <= 0;
    end else if (c16_en) begin
      dev_strobe <= 0;
      if (scc_hold != 0) scc_hold <= scc_hold - 1'b1;

      if (!active) begin
        if (!cpu_as_n) begin
          active <= 1; done <= 0; mem_done <= 0; dcnt <= 0;
          if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
          if (fixed_port && dc_adv) begin dcnt <= 1; if (cap == 2'd1) dev_strobe <= 1; end
        end
      end else if (cpu_as_n) begin
        active <= 0; done <= 0; mem_done <= 0; dcnt <= 0;
        if (d_scc) scc_hold <= SCC_HOLD;
      end else if (!done) begin
        // memory: one 32-bit access; the port's acknowledge is the cycle's
        if (d_mem) begin
          if (mem_ack) begin
            mem_done <= 1; done <= 1;
            if (ram_ack) din_r <= ram_rdata;
            if (rom_ack) din_r <= rom_rdata;
          end
        end
        // an 8-bit port: one device cycle, the byte on D31-D24
        if (d_dev) begin
          if (d_scc) begin
            if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
            else if (dcnt != 0 && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
          end else begin
            if (dc_adv && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
            if (fixed_port && dc_adv && dcnt == cap - 1'b1) dev_strobe <= 1;
          end
          if (d_via && e_strobe) dev_strobe <= 1;
          if (capture) begin done <= 1; dev_q <= rbyte; end
        end
      end
    end

  // a device's byte is taken on the capture clock - the clock on which
  // the device acts on the strobe (the SCC's two later) - and held for
  // the processor, which latches it at the end of S4, a clock after it
  // takes DSACK*.  Taken live, a byte that changed in that clock reached
  // the processor without the device having seen it read: the SWIM's
  // data register, whose clear follows only a read the chip saw, gave
  // the ROM the same byte twice (sim/gcrread, plan 5.12.12 item 6).
  // Memory data is registered with the port's acknowledge.
  assign cpu_din  = d_fpu ? fpu_rdata : (active && d_dev) ? {done ? dev_q : rbyte, 24'h000000} : din_r;
  // the slot's DSACK0* is the card's own, on the processor's bus as UE6
  // drives it on the board (plan 2.12), not relayed through `done` - that
  // cost every video access a clock; `done` then holds it until AS* rises
  wire slot_ack = d_slot && !slot_dsack0_n;
  assign dsack_n  = d_fpu ? fpu_dsack_n :
                    (!cpu_as_n && (done || (active && slot_ack)) && !berr_r) ? (d_mem ? 2'b00 : 2'b10) : 2'b11;
  assign fpu_sel  = !cpu_as_n && d_fpu;

  // selects follow the cycle, as chip selects follow AS*; the slot's drops
  // with the acknowledge so the video PALs do not take a second cycle
  assign via1_sel  = !cpu_as_n && d_via1;             // with AS*, as a chip select: a clock before E can rise
  assign via2_sel  = !cpu_as_n && d_via2;
  assign scc_sel   = active && d_scc && (dcnt != 0);
  assign scsi_sel  = active && d_scsi;
  assign scsi_dack = active && (d_dma || d_hs);
  assign asc_sel   = active && d_asc;
  assign swim_sel  = active && d_swim;
  assign exp_sel   = active && d_exp;
  // NUBUS* with AS*, at the falling edge starting S1, as plan 2.12 drove it
  // into the video PALs to read their 5/6/7-clock access; registered on
  // `active` it came a clock late, and an AS* landing on UE7's taking
  // state waited a full alternation - 7 clocks for every such byte
  // (plan 1.16.3, Speedometer's graphics; sim/system vramtest)
  assign slot_sel  = !cpu_as_n && d_slot && !done;
  assign dev_addr  = cpu_addr[12:0];
  assign dev_rw    = cpu_rw_n;
  assign dev_wdata = cpu_dout[31:24];

  // ------------------------------------------------------------ RAM, ROM
  // Bank B follows bank A at the RAMSIZ boundary (Guide Table 4-10); the
  // bits above the two banks are ignored, so the contents repeat.
  assign ram_addr  = (ramsiz == 2'd0) ? {6'b0, cpu_addr[20:2]} :
                     (ramsiz == 2'd1) ? {4'b0, cpu_addr[22:2]} :
                     (ramsiz == 2'd2) ? {2'b0, cpu_addr[24:2]} :
                                        cpu_addr[26:2];
  assign ram_we    = !cpu_rw_n;
  assign ram_be    = be;
  assign ram_wdata = cpu_dout;
  assign rom_addr  = cpu_addr[17:2];

  // ------------------------------------------------------------- clocks
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      eref <= 0; e_r <= 0; rose <= 0; via_armed <= 0; eph <= 4'd15;
    end else if (c16_en) begin
      eref <= (eref == 5'd19) ? 5'd0 : eref + 1'b1;
      if (eref == 5'd19) rose <= 0;
      if (e_rise)      begin e_r <= 1; rose <= 1; via_armed <= via_pending; eph <= 0; end
      else if (e_fall) begin e_r <= 0; via_armed <= 0; eph <= 0; end
      else if (eph != 4'd15) eph <= eph + 1'b1;
    end

  reg [6:0] c3m_acc;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      refcnt <= 0; ram_refresh <= 0; c3m_acc <= 0; c3m_en <= 0;
    end else if (c16_en) begin
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
