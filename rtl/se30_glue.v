// se30_glue.v - GLUE: address decode, acknowledge, RAM and ROM control, the E and SCC clocks,
// the bus-error timeout (UI6) and the interrupt encoder.

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

  // RAM: 32-bit port; mem_early is the decode without AS*, for the SDRAM controller's early start on ECS
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

  // the 68882: CPU space type 2, coprocessor ID 1; the FPU terminates its own cycles
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
  input         hsync_n,               // from the video PALs: the UI6 timeout's clock

  output        dbg_hs_wait            // the CPU held at $50006000 waiting for DRQ
);

  localparam SCC_HOLD = 6'd33;         // clocks from select release to the next SCC select, 2.2 us
  localparam REF_PERIOD = 8'd244;      // 15.6 us
  localparam REF_WINDOW = 8'd4;        // one RAM access cycle

  // ------------------------------------------------------------- decode
  // RAM and ROM on A31-A30 and OVERLAY; I/O at $50xxxxxx on A17-A13; slots on A31-A29 >= 011;
  // FC = 7 is CPU space, where only the FPU answers
  wire       fc7    = (cpu_fc == 3'd7);
  wire       d_fpu  = fc7 && (cpu_addr[19:13] == 7'b0010_001);
  wire       low_sp = (cpu_addr[31:30] == 2'b00);
  wire       d_ram  = !fc7 && low_sp && !overlay;
  wire       d_rom  = !fc7 && ((cpu_addr[31:28] == 4'h4) || (low_sp && overlay));
  // A23-A18 ignored: the I/O space wraps (Guide Figure 3-6)
  wire       d_io   = !fc7 && (cpu_addr[31:24] == 8'h50);
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

  // E: a 20-clock reference, high for 10; a waiting VIA access cuts the high phase to four
  // clocks, and the strobe is its last high clock
  reg  [4:0] eref;
  reg        e_r, rose, via_armed;
  reg  [3:0] eph;                      // clocks in E's current phase, saturating
  assign e_clk = e_r;
  wire via_pending = !cpu_as_n && d_via && !done;
  wire e_rise    = !e_r && !rose && (eph >= 4'd3) && (via_pending || eref >= 5'd9);
  wire e_fall    =  e_r && (via_armed ? (eph == 4'd3) : ((eref == 5'd19) || (via_pending && eph >= 4'd3)));
  wire e_strobe  =  e_r && via_armed && (eph == 4'd2);   // the next clock is the access's last high one
  wire e_capture =  e_r && via_armed && (eph == 4'd3);

  // the device cycle, counted from the clock AS* is first seen: strobe on clock cap-1, capture
  // and the acknowledge on clock cap; the SCC's data two clocks later
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

  // a device's byte is taken on the capture clock and held for the processor, which latches it a
  // clock after DSACK*; memory data is registered with the port's acknowledge
  assign cpu_din  = d_fpu ? fpu_rdata : (active && d_dev) ? {done ? dev_q : rbyte, 24'h000000} : din_r;
  // the slot's DSACK0* is the card's own, as UE6 drives it on the board
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
  // SCSIDACK*: at $50006000 only once DRQ has been seen - DACK clears the 53C80's DRQ
  assign scsi_dack = active && (d_dma || (d_hs && dcnt != 0));
  assign dbg_hs_wait = active && d_hs && (dcnt == 0) && !scsi_drq;   // dc_adv's wait, measured only
  assign asc_sel   = active && d_asc;
  assign swim_sel  = active && d_swim;
  assign exp_sel   = active && d_exp;
  // NUBUS* with AS*, at the falling edge starting S1, as the video PALs see it
  assign slot_sel  = !cpu_as_n && d_slot && !done;
  assign dev_addr  = cpu_addr[12:0];
  assign dev_rw    = cpu_rw_n;
  assign dev_wdata = cpu_dout[31:24];

  // ------------------------------------------------------------ RAM, ROM
  // bank B follows bank A at the RAMSIZ boundary (Guide Table 4-10); higher bits are ignored
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
  // two flip-flops, cleared while the system AS* is negated: the first sets on HSYNC* high, the
  // second on HSYNC* low after it, BERR on the next HSYNC* high; FC = 7 cycles never time out
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
  // the highest level only, autovectored; the slot lines go to VIA2 CA1, not IPL (Guide Table 3-4)
  assign ipl_n = !nmi_n      ? 3'b000 :
                 !scc_irq_n  ? 3'b011 :
                 !via2_irq_n ? 3'b101 :
                 !via1_irq_n ? 3'b110 : 3'b111;
  assign slot_irq_or_n = &slot_irq_n;

endmodule
