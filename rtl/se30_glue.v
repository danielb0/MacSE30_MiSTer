// se30_glue.v - GLUE: address decode, acknowledge, RAM/ROM control, clocks, bus-error timeout, interrupts

`timescale 1ns/1ps

module se30_glue (
  input         clk,
  input         c16_en,
  input         reset_n,

  input  [31:0] cpu_addr,
  input         cpu_as_n,
  input         cpu_ds_n,
  input         cpu_rw_n,
  input   [2:0] cpu_fc,
  input   [1:0] cpu_siz,
  input  [31:0] cpu_dout,
  output [31:0] cpu_din,
  output  [1:0] dsack_n,
  output        berr,
  output  [2:0] ipl_n,

  output        mem_early,
  output        rom_early,

  output        ram_req,
  output        ram_we,
  output [24:0] ram_addr,
  output  [3:0] ram_be,
  output [31:0] ram_wdata,
  input  [31:0] ram_rdata,
  input         ram_ack,
  output reg    ram_refresh,

  output        rom_req,
  output [15:0] rom_addr,
  input  [31:0] rom_rdata,
  input         rom_ack,

  output        via1_sel,
  output        via2_sel,
  output        scc_sel,
  output        scsi_sel,
  output        scsi_dack,
  output        asc_sel,
  output        swim_sel,
  output        exp_sel,
  output reg    dev_strobe,
  output [12:0] dev_addr,
  output        dev_rw,
  output  [7:0] dev_wdata,
  input   [7:0] dev_rdata,
  input         scsi_drq,
  output        e_clk,
  output reg    c3m_en,

  output        fpu_sel,
  input   [1:0] fpu_dsack_n,
  input  [31:0] fpu_rdata,

  output        slot_sel,
  input         slot_dsack0_n,
  input   [7:0] slot_rdata,

  input         via1_irq_n,
  input         via2_irq_n,
  input         scc_irq_n,
  input         nmi_n,
  input   [6:1] slot_irq_n,
  output        slot_irq_or_n,

  input         overlay,
  input   [1:0] ramsiz,
  input         hsync_n,

  output        dbg_hs_wait
);

  localparam SCC_HOLD = 6'd33;
  localparam REF_PERIOD = 8'd244;
  localparam REF_WINDOW = 8'd4;

  wire       fc7    = (cpu_fc == 3'd7);
  wire       d_fpu  = fc7 && (cpu_addr[19:13] == 7'b0010_001);
  wire       low_sp = (cpu_addr[31:30] == 2'b00);
  wire       d_ram  = !fc7 && low_sp && !overlay;
  wire       d_rom  = !fc7 && ((cpu_addr[31:28] == 4'h4) || (low_sp && overlay));
  wire       d_io   = !fc7 && (cpu_addr[31:24] == 8'h50);
  wire [3:0] win    = cpu_addr[16:13];
  wire       d_via1 = d_io && (win == 4'h0);
  wire       d_via2 = d_io && (win == 4'h1);
  wire       d_scc  = d_io && (win == 4'h2);
  wire       d_hs   = d_io && (win == 4'h3);
  wire       d_scsi = d_io && (win == 4'h8);
  wire       d_dma  = d_io && (win == 4'h9);
  wire       d_asc  = d_io && (win == 4'hA);
  wire       d_swim = d_io && (win == 4'hB);
  wire       d_exp  = d_io && (win[3:2] == 2'b11);
  wire       d_slot = !fc7 && (cpu_addr[31:29] >= 3'b011);
  wire       d_via  = d_via1 || d_via2;
  wire       d_mem  = d_ram || d_rom;
  wire       d_dev  = d_via || d_scc || d_hs || d_scsi || d_dma || d_asc || d_swim || d_exp || d_slot;

  wire [2:0] siz_n = (cpu_siz == 2'b00) ? 3'd4 : {1'b0, cpu_siz};
  wire [2:0] a10   = {1'b0, cpu_addr[1:0]};
  wire [3:0] be    = { (a10 == 3'd0),
                       (a10 <= 3'd1) && (a10 + siz_n > 3'd1),
                       (a10 <= 3'd2) && (a10 + siz_n > 3'd2),
                       (a10 + siz_n > 3'd3) };

  reg        active;
  reg        done;
  reg        mem_done;
  reg  [1:0] dcnt;
  reg [31:0] din_r;
  reg  [7:0] dev_q;
  reg  [5:0] scc_hold;
  reg        ff1, ff2, berr_r;

  reg  [4:0] eref;
  reg        e_r, rose, via_armed;
  reg  [3:0] eph;
  assign e_clk = e_r;
  wire via_pending = !cpu_as_n && d_via && !done;
  wire e_rise    = !e_r && !rose && (eph >= 4'd3) && (via_pending || eref >= 5'd9);
  wire e_fall    =  e_r && (via_armed ? (eph == 4'd3) : ((eref == 5'd19) || (via_pending && eph >= 4'd3)));
  wire e_strobe  =  e_r && via_armed && (eph == 4'd2);
  wire e_capture =  e_r && via_armed && (eph == 4'd3);

  wire [1:0] cap = (d_asc && cpu_rw_n) ? 2'd2 : 2'd1;
  wire dc_adv = !cpu_as_n && (!d_hs || dcnt != 0 || scsi_drq);
  wire fixed_port = d_hs || d_scsi || d_dma || d_asc || d_swim || d_exp;
  wire scc_go  = d_scc && (dcnt == 0) && (scc_hold == 0);
  wire capture = active && ( (fixed_port && dcnt == cap && dc_adv)
                          || (d_scc && dcnt == 2'd2)
                          || (d_via && e_capture)
                          || (d_slot && !slot_dsack0_n) );
  wire [7:0] rbyte = d_slot ? slot_rdata : dev_rdata;

  reg  [7:0] refcnt;
  wire ref_busy = (refcnt < REF_WINDOW);
  assign ram_req = !cpu_as_n && d_ram && !mem_done && !ref_busy;
  assign rom_req = !cpu_as_n && d_rom && cpu_rw_n && !mem_done;
  assign mem_early = d_mem;
  assign rom_early = d_rom;
  wire mem_ack = ram_ack || rom_ack || (active && d_rom && !cpu_rw_n);

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
        if (d_mem) begin
          if (mem_ack) begin
            mem_done <= 1; done <= 1;
            if (ram_ack) din_r <= ram_rdata;
            if (rom_ack) din_r <= rom_rdata;
          end
        end
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

  assign cpu_din  = d_fpu ? fpu_rdata : (active && d_dev) ? {done ? dev_q : rbyte, 24'h000000} : din_r;
  wire slot_ack = d_slot && !slot_dsack0_n;
  assign dsack_n  = d_fpu ? fpu_dsack_n :
                    (!cpu_as_n && (done || (active && slot_ack)) && !berr_r) ? (d_mem ? 2'b00 : 2'b10) : 2'b11;
  assign fpu_sel  = !cpu_as_n && d_fpu;

  assign via1_sel  = !cpu_as_n && d_via1;
  assign via2_sel  = !cpu_as_n && d_via2;
  assign scc_sel   = active && d_scc && (dcnt != 0);
  assign scsi_sel  = active && d_scsi;
  assign scsi_dack = active && (d_dma || (d_hs && dcnt != 0));
  assign dbg_hs_wait = active && d_hs && (dcnt == 0) && !scsi_drq;
  assign asc_sel   = active && d_asc;
  assign swim_sel  = active && d_swim;
  assign exp_sel   = active && d_exp;
  assign slot_sel  = !cpu_as_n && d_slot && !done;
  assign dev_addr  = cpu_addr[12:0];
  assign dev_rw    = cpu_rw_n;
  assign dev_wdata = cpu_dout[31:24];

  assign ram_addr  = (ramsiz == 2'd0) ? {6'b0, cpu_addr[20:2]} :
                     (ramsiz == 2'd1) ? {4'b0, cpu_addr[22:2]} :
                     (ramsiz == 2'd2) ? {2'b0, cpu_addr[24:2]} :
                                        cpu_addr[26:2];
  assign ram_we    = !cpu_rw_n;
  assign ram_be    = be;
  assign ram_wdata = cpu_dout;
  assign rom_addr  = cpu_addr[17:2];

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

  assign ipl_n = !nmi_n      ? 3'b000 :
                 !scc_irq_n  ? 3'b011 :
                 !via2_irq_n ? 3'b101 :
                 !via1_irq_n ? 3'b110 : 3'b111;
  assign slot_irq_or_n = &slot_irq_n;

endmodule
