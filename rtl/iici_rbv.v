// iici_rbv.v - the Macintosh IIci's RBV (RAM-Based Video controller): the
// VIA2-emulation registers, the interrupts, the 60.15 Hz tick, the built-in
// video's timing, FIFO and pixel shifter, and the Bt478 CLUT DAC behind it
// (SE30_PLAN.md "THE RBV" and "THE PORTRAIT DISPLAY", 2026-11-13).
//
// WHAT IT IS
//   Apple's specification of the chip, drawing 343S1019-A "IC, RAM-BASED
//   VIDEO (RBV), 128-PIN QFP" (S below; its section 6.2 the registers),
//   with the Guide's tables (G: 4-9, 4-15, 4-27, 12-5, 12-6, 12-8).  The
//   registers are decoded on A4, A1, A0 (S 6.1): eight of them.
//
// REGISTERS (S 6.2.1-6.2.8)
//   $00 VIA2 data  0 CEN*, 1 BUS.LOCK*, 2 PWR.OFF*, 3 CFLUSH*, 7 EXP.OUT*
//                out, as written, all 1 at reset; 4 TM1A*, 5 TM0A* in (the
//                NuChip's); 6 SND.EXT* in (0 = the external jack in use:
//                tied low here, MiSTer's output is the jack, as the IIcx
//                build ties it)
//   $01          reserved: always reads 0
//   $02 slots    read only, the lines' levels: 5-3 slots $E-$C (SLOT6-4),
//                2-0 SLOT3-1 (no such slots: high), 6 SLOT0.IRQ* "normally
//                follows the level of the internal video's vertical
//                blanking signal" (0 in blanking; with VID.3ST the SLOT0
//                pin, not connected: 1), 7 always 0
//   $03 flags    0 SCSI.DRQ, 1 ANY.SLOT*, 2 EXP.IRQ*, 3 SCSI.IRQ, 4
//                SND.IRQ*; 5-6 read 0; 7 any enabled flag set.  Each flag
//                is SET BY AN EDGE (ANY.SLOT*, EXP.IRQ*, SND.IRQ* falling;
//                SCSI.DRQ, SCSI.IRQ rising) whether enabled or not, and
//                cleared by writing its 1 with bit 7 a 1 (bit 7 a 0: no
//                effect); reset clears them.  ANY.SLOT* is the OR of the
//                slot lines enabled in $12.
//   $10 monitor  2-0 COLORS (bit 2 always 0: 0-3 = 1-8 bpp), 5-3 MON.ID
//                read only (110 the 640 x 480 monitor, 001 the Portrait
//                Display), 6 VID.OFF, 7 VID.3ST
//   $11 chip test  as written; its functions need the TEST* pin low
//   $12 slot enables  6-0, set / clear on bit 7; reads bit 7 as 0
//   $13 flag enables  4-0, set / clear on bit 7; reads bit 7 as 1, 5-6 as 0
//   The level-2 interrupt (VIA2.IRQ*): any enabled flag set (S 6.2.11).
//
// VIDEO (G Tables 12-5, 12-6), on its own clock clk_vid = 57.28 MHz:
//   640 x 480: a dot on PIX_NUM of every PIX_DEN clocks (30.24 MHz), 864 x
//              525 (HFP 64, HS 64, HBP 96; VFP 3, VS 3, VBP 39), 66.67 Hz
//   640 x 870: a dot every clock (57.28 MHz), 832 x 918 (HFP 32, HS 80,
//              HBP 80; VFP 3, VS 3, VBP 42), 75.0 Hz; 1, 2, 4 bpp
//   `portrait` picks the monitor; the top latches it at reset.
//
// THE FIFO: 16 longs, written in clk from the MDU's bursts, read in clk_vid
//   (Gray-coded pointers, two flip-flops each way).  Whenever 8 or fewer
//   are held (10 at the two fastest modes, S 6.3.2) and no burst is under
//   way, vid_req asks the MDU for 8, which arrive on vid_ld.  The frame restart is a handshake at vertical
//   blanking: the video side asks (f_req); clk's side, once no burst is
//   under way, pulses vid_frame (the MDU's address back to the screen
//   buffer's base), stops asking and answers (f_ack); the video side lets
//   the write pointer settle, empties the FIFO (read pointer to it) and
//   answers (f_go); the filling restarts.  Pixels leave the long most
//   significant first; the DAC gets the pixel with its unused high bits 1
//   (1 bpp: entries 254-255), then the pixel read mask.
//
// CROSSINGS: depth, video off and the monitor reach clk_vid through two
//   flip-flops (they change only between frames, the ROM's driver in
//   VBL); vertical sync comes back the same way.  The CLUT is written in
//   clk and read in clk_vid (a dual-clock block RAM), with a copy read in
//   clk for the DAC's readback.
//
// THE Bt478: RS2-0 = A4-A2: 0 write address, 1 colour data (R, G, B, then
//   the address advances), 2 pixel read mask, 3 read address; the overlay
//   registers (4-7) are kept but drive nothing.  8-bit colours.

`timescale 1ns/1ps

module iici_rbv #(
  parameter PIX_NUM = 189,             // 640 x 480: ce_pix on PIX_NUM / PIX_DEN of clk_vid (30.24 of 57.28 MHz)
  parameter PIX_DEN = 358,
  parameter TICK    = 260469,          // C16M clocks per 60.15 Hz tick (16.63 ms)
  parameter EARLY   = 1                // the FIFO's earlier request at the two fastest modes (S 6.3.2); 0 for the bench's comparison
) (
  input             clk,
  input             clk_vid,           // 57.28 MHz
  input             reset_n,           // RESET* (the machine's, and the RESET instruction's)
  input             c16_en,
  input             portrait,          // the monitor: 1 = the Portrait Display (latched at reset by the top)

  // the CPU, through the MDU: 8-bit ports
  input             rbv_sel,
  input             vdac_sel,
  input             strobe,            // dev_strobe && c16_en
  input       [4:0] addr,
  input             rw,
  input       [7:0] wdata,
  output      [7:0] rdata,

  // interrupt sources
  input             scsi_irq,
  input             scsi_drq,
  input             asc_irq_n,
  input             exp_irq_n,
  input       [2:0] slot_irq_n,        // slots $E, $D, $C
  input       [1:0] nb_tm,             // {v2TM0A, v2TM1A}
  output            irq_n,
  output reg        tick_n,            // 60.15 Hz to VIA1 CA1

  // data B's outputs
  output            cflush_n,
  output            cenable_n,
  output            poweroff_n,
  output            buslk_n,

  // the screen buffer, through the MDU (clk)
  output            vid_req,           // a burst of 8 longs wanted
  output reg        vid_frame,         // one clk: the address restarts at the base
  input             vid_ld,            // one long
  input      [31:0] vid_data,

  // the picture (clk_vid)
  output reg        ce_pix,
  output reg  [7:0] r,
  output reg  [7:0] g,
  output reg  [7:0] b,
  output reg        hs_n,
  output reg        vs_n,
  output reg        hblank,
  output reg        vblank,
  output     [15:0] dbg_underflow,     // dots the FIFO could not give (clk_vid)
  output     [31:0] dbg_reg,           // {slots, 0, sier, 0, ifr, 0, ier}: the probes'
  output     [31:0] dbg_fifo           // the FIFO's fill side and the pixels shown with it empty, for the probes (PFIF)
);

  // =================================================================
  // clk: the registers, the interrupts, the tick, the DAC's CPU side and
  // the FIFO's write side
  // =================================================================
  reg  [7:0] datab, monp, r11;
  reg  [6:0] sier;
  reg  [4:0] ier, ifr;
  reg  [2:0] vs_sync;                  // vertical sync from clk_vid
  reg  [2:0] vb_sync;                  // vertical blanking from clk_vid
  wire       vsync_c = vs_sync[1];

  wire [2:0] sense = portrait ? 3'b001 : 3'b110;
  wire       vblank_c = vb_sync[1];
  // S 6.2.3, 6.2.10: the lines' levels; bit 6 the vertical blanking's (VID.3ST: the SLOT0.IRQ* pin, high)
  wire [7:0] slots = {1'b0, monp[7] || !vblank_c, slot_irq_n, 3'b111};
  wire       any_slot = |(~slots[6:0] & sier);            // ANY.SLOT*, active high here
  // S 6.2.11: the five flags' lines, each active high here; a flag is set by its line's leading edge
  wire [4:0] fl_in = {!asc_irq_n, scsi_irq, !exp_irq_n, any_slot, scsi_drq};
  reg  [4:0] fl_q;
  wire       any = |(ifr & ier);
  assign irq_n = !any;
  assign dbg_reg = {slots, 1'b0, sier, 3'b000, ifr, 3'b000, ier};

  wire [7:0] datab_rd = {datab[7], 1'b0, nb_tm, datab[3:0]};
  reg  [7:0] reg_rd;
  always @* begin
    case (addr)
      5'h00: reg_rd = datab_rd;
      5'h01: reg_rd = 8'h00;
      5'h02: reg_rd = slots;
      5'h03: reg_rd = {any, 2'b00, ifr};
      5'h10: reg_rd = {monp[7:6], sense, 1'b0, monp[1:0]};
      5'h11: reg_rd = r11;
      5'h12: reg_rd = {1'b0, sier};
      5'h13: reg_rd = {3'b100, ier};
      default: reg_rd = 8'hFF;
    endcase
  end

  assign cflush_n   = datab[3];
  assign cenable_n  = datab[0];
  assign poweroff_n = datab[2];
  assign buslk_n    = datab[1];

  wire wr = rbv_sel && strobe && !rw;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      datab <= 8'hFF; monp <= 0; r11 <= 0; sier <= 0; ier <= 0;
    end else if (wr) begin
      case (addr)
        5'h00: datab <= wdata;
        5'h10: monp <= wdata;
        5'h11: r11 <= wdata;
        5'h12: sier <= wdata[7] ? (sier | wdata[6:0]) : (sier & ~wdata[6:0]);
        5'h13: ier  <= wdata[7] ? (ier  | wdata[4:0]) : (ier  & ~wdata[4:0]);
        default: ;
      endcase
    end

  // the 60.15 Hz tick: a short low pulse every TICK C16M clocks
  reg [17:0] tick_cnt;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin tick_cnt <= 0; tick_n <= 1; end
    else if (c16_en) begin
      tick_cnt <= (tick_cnt == TICK - 1) ? 18'd0 : tick_cnt + 1'b1;
      tick_n <= !(tick_cnt < 18'd16);
    end

  // the flags (S 6.2.11): set by an edge, cleared by writing a 1 with bit 7 set; an edge on the clearing clock wins
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin ifr <= 0; fl_q <= 0; end
    else begin
      fl_q <= fl_in;
      ifr <= ((wr && addr == 5'h03 && wdata[7]) ? (ifr & ~wdata[4:0]) : ifr) | (fl_in & ~fl_q);
    end

  // ---------------------------------------------------- the Bt478, CPU side
  reg  [7:0] dac_wa, dac_ra, dac_mask, dac_r, dac_g;
  reg  [1:0] dac_wc, dac_rc;
  reg  [7:0] ovl_reg [0:3];
  reg [23:0] clut_c [0:255];           // the copy read in clk (readback)
  reg [23:0] clut_v [0:255];           // the copy read in clk_vid (the picture)
  reg [23:0] dac_rd_q;
  wire [2:0] rs = addr[4:2];
  wire       dwr = vdac_sel && strobe && !rw;
  wire       drd = vdac_sel && strobe && rw;
  reg  [7:0] dac_rd;
  always @* begin
    case (rs)
      3'd0: dac_rd = dac_wa;
      3'd1: dac_rd = (dac_rc == 2'd0) ? dac_rd_q[23:16] : (dac_rc == 2'd1) ? dac_rd_q[15:8] : dac_rd_q[7:0];
      3'd2: dac_rd = dac_mask;
      3'd3: dac_rd = dac_ra;
      default: dac_rd = ovl_reg[rs[1:0]];
    endcase
  end
  always @(posedge clk) dac_rd_q <= clut_c[dac_ra];
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      dac_wa <= 0; dac_ra <= 0; dac_mask <= 8'hFF; dac_wc <= 0; dac_rc <= 0; dac_r <= 0; dac_g <= 0;
    end else begin
      if (dwr) case (rs)
        3'd0: begin dac_wa <= wdata; dac_wc <= 0; end
        3'd1: begin
          if (dac_wc == 2'd0) begin dac_r <= wdata; dac_wc <= 2'd1; end
          else if (dac_wc == 2'd1) begin dac_g <= wdata; dac_wc <= 2'd2; end
          else begin dac_wc <= 0; dac_wa <= dac_wa + 1'b1; end
        end
        3'd2: dac_mask <= wdata;
        3'd3: begin dac_ra <= wdata; dac_rc <= 0; end
        default: ovl_reg[rs[1:0]] <= wdata;
      endcase
      if (drd && rs == 3'd1) begin
        if (dac_rc == 2'd2) begin dac_rc <= 0; dac_ra <= dac_ra + 1'b1; end
        else dac_rc <= dac_rc + 1'b1;
      end
    end
  wire clut_we = dwr && rs == 3'd1 && dac_wc == 2'd2;
  always @(posedge clk) if (clut_we) begin
    clut_c[dac_wa] <= {dac_r, dac_g, wdata};
    clut_v[dac_wa] <= {dac_r, dac_g, wdata};
  end

  assign rdata = vdac_sel ? dac_rd : reg_rd;

  // ---------------------------------------------- the FIFO's write side
  reg [31:0] fifo [0:15];
  reg  [4:0] wp;                       // binary, one bit over the depth
  reg  [4:0] wp_g;                     // its Gray code, for clk_vid
  reg  [4:0] rp_g_s1, rp_g_s2;         // the read pointer's Gray code, from clk_vid
  function [4:0] g2b(input [4:0] gr);
    begin
      g2b[4] = gr[4]; g2b[3] = g2b[4] ^ gr[3]; g2b[2] = g2b[3] ^ gr[2];
      g2b[1] = g2b[2] ^ gr[1]; g2b[0] = g2b[1] ^ gr[0];
    end
  endfunction
  wire [4:0] rp_c  = g2b(rp_g_s2);
  wire [4:0] cnt_c = wp - rp_c;        // longs held
  reg  [3:0] got;
  reg        busy, hold;
  reg        f_req_s1, f_req_s2, f_seen, f_ack;    // the frame handshake
  reg        f_go_s1, f_go_s2, f_go_seen;
  reg        f_req, f_go;                          // (clk_vid's)
  reg  [4:0] rp_g;                                 // (clk_vid's: the read pointer's Gray code)
  reg        vsync_v;                              // (clk_vid's: vertical sync)
  reg        vblk_v;                               // (clk_vid's: vertical blanking)
  // S 6.3.2: a half is asked for when its last long has been used, "or three long words earlier, for
  // 8-bit 13-inch or 4-bit 15-inch video".  Ours asks TWO earlier, at 10 held: the chip's burst brings a
  // long every two CPU clocks, so its three are used before the sixth arrives; the SDRAM brings all eight
  // within 240 ns of the first, and 11 + 8 could pass the 16 held when the first comes quickly
  wire       fast = (EARLY != 0) && (portrait ? (monp[1:0] == 2'd2) : (monp[1:0] == 2'd3));
  assign vid_req = busy && (got != 4'd8);
  assign dbg_fifo = {dbg_underflow, busy, hold, vid_req, got, cnt_c, monp[7:6], monp[1:0]};   // (the count is clk_vid's, read at rest)
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      wp <= 0; wp_g <= 0; rp_g_s1 <= 0; rp_g_s2 <= 0; got <= 0; busy <= 0; hold <= 1;
      f_req_s1 <= 0; f_req_s2 <= 0; f_seen <= 0; f_ack <= 0; f_go_s1 <= 0; f_go_s2 <= 0; f_go_seen <= 0;
      vid_frame <= 0; vs_sync <= 0; vb_sync <= 0;
    end else begin
      vid_frame <= 0;
      rp_g_s1 <= rp_g; rp_g_s2 <= rp_g_s1;
      f_req_s1 <= f_req; f_req_s2 <= f_req_s1;
      f_go_s1 <= f_go;   f_go_s2 <= f_go_s1;
      vs_sync <= {vs_sync[1:0], vsync_v};
      vb_sync <= {vb_sync[1:0], vblk_v};
      if (vid_ld && busy) begin
        fifo[wp[3:0]] <= vid_data; wp <= wp + 1'b1; wp_g <= (wp + 1'b1) ^ ((wp + 1'b1) >> 1);
        got <= got + 1'b1;
        if (got == 4'd7) busy <= 0;
      end else if (f_req_s2 != f_seen && !busy) begin
        // the frame's end: restart the address, stop, answer
        f_seen <= f_req_s2; vid_frame <= 1; hold <= 1; f_ack <= !f_ack;
      end else if (f_go_s2 != f_go_seen) begin
        f_go_seen <= f_go_s2; hold <= 0;
      end else if (!busy && !hold && cnt_c <= (fast ? 5'd10 : 5'd8)) begin
        busy <= 1; got <= 0;
      end
    end

  // =================================================================
  // clk_vid: the timing, the FIFO's read side, the pixels
  // =================================================================
  reg  [2:0] port_s, voff_s;
  reg  [1:0] dep_s1, dep_s2;
  // The monitor's choice sets where this side starts (port_s, vc below).  A
  // register cannot be reset to a signal's value: Quartus built port_s[2]
  // and vc[7] as latch loops, which the timing analyzer cannot time (the
  // IIci's compiles 1 to 9: "analyzing 2 combinational loops as latches").
  // So the reset is to constants and the first clock after it loads them
  // (v_init): the same start, one clk_vid clock later.
  reg        v_init;
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) v_init <= 1; else v_init <= 0;
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin port_s <= 0; voff_s <= 0; dep_s1 <= 0; dep_s2 <= 0; end
    else if (v_init) port_s <= {3{portrait}};
    else begin
      port_s <= {port_s[1:0], portrait};
      voff_s <= {voff_s[1:0], monp[6]};
      dep_s1 <= monp[1:0]; dep_s2 <= dep_s1;
    end
  wire       port_v = port_s[2];
  wire       voff   = voff_s[2];
  wire [1:0] depth  = dep_s2;

  // the monitor's numbers (G Tables 12-5, 12-6)
  wire [9:0] HT  = port_v ? 10'd832 : 10'd864;    // dots a line
  wire [9:0] HS0 = port_v ? 10'd672 : 10'd704;    // sync from (640 + front porch)
  wire [9:0] HS1 = port_v ? 10'd752 : 10'd768;    // ... to
  wire [9:0] VT  = port_v ? 10'd918 : 10'd525;    // lines a frame
  wire [9:0] VV  = port_v ? 10'd870 : 10'd480;    // visible lines
  wire [9:0] VS0 = VV + 10'd3;                    // sync after a 3-line front porch, 3 lines

  reg [9:0] pacc;
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin pacc <= 0; ce_pix <= 0; end
    else if (v_init) ;
    else if (port_v) ce_pix <= 1;
    else if (pacc + PIX_NUM >= PIX_DEN) begin pacc <= pacc + PIX_NUM - PIX_DEN; ce_pix <= 1; end
    else begin pacc <= pacc + PIX_NUM; ce_pix <= 0; end

  reg  [9:0] hc, vc;
  wire       h_act = (hc < 10'd640);
  wire       v_act = (vc < VV);
  // from reset at vertical blanking: the FIFO fills before line 0
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin hc <= 0; vc <= 10'd870; end
    else if (v_init) vc <= portrait ? 10'd870 : 10'd480;
    else if (ce_pix) begin
      if (hc >= HT - 1'b1) begin hc <= 0; vc <= (vc >= VT - 1'b1) ? 10'd0 : vc + 1'b1; end
      else hc <= hc + 1'b1;
    end
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin vsync_v <= 0; vblk_v <= 0; end
    else begin vsync_v <= (vc >= VS0) && (vc < VS0 + 10'd3); vblk_v <= !v_act; end

  // the FIFO's read side and the frame handshake
  reg  [4:0] rp;
  reg  [4:0] wp_g_s1, wp_g_s2;
  reg        f_ack_s1, f_ack_s2, f_ack_seen;
  reg  [2:0] settle;
  wire [4:0] wp_v  = g2b(wp_g_s2);
  wire       empty = (wp_v == rp);
  wire       pop;
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin
      rp <= 0; rp_g <= 0; wp_g_s1 <= 0; wp_g_s2 <= 0; f_ack_s1 <= 0; f_ack_s2 <= 0; f_ack_seen <= 0;
      settle <= 0; f_req <= 0; f_go <= 0;
    end else begin
      wp_g_s1 <= wp_g; wp_g_s2 <= wp_g_s1;
      f_ack_s1 <= f_ack; f_ack_s2 <= f_ack_s1;
      if (ce_pix && hc == 10'd0 && vc == VV) f_req <= !f_req;          // vertical blanking begins
      if (f_ack_s2 != f_ack_seen) begin f_ack_seen <= f_ack_s2; settle <= 3'd5; end
      else if (settle > 3'd1) settle <= settle - 1'b1;
      else if (settle == 3'd1) begin
        settle <= 0; rp <= wp_v; rp_g <= wp_v ^ (wp_v >> 1); f_go <= !f_go;   // empty it, let it fill
      end else if (pop) begin
        rp <= rp + 1'b1; rp_g <= (rp + 1'b1) ^ ((rp + 1'b1) >> 1);
      end
    end

  // the pixels
  reg [31:0] sh;                       // the long being shifted out
  reg  [5:0] left;                     // its bits still to show
  reg [15:0] under;
  assign dbg_underflow = under;
  wire [5:0] bpp = 6'd1 << depth;
  wire       need = (left == 0);
  wire       showing = h_act && v_act;
  assign pop = ce_pix && showing && need && !empty && (settle == 0);
  wire [31:0] cur = need ? fifo[rp[3:0]] : sh;
  reg  [7:0] cur_pix;
  always @* begin
    case (depth)
      2'd0: cur_pix = {7'h7F, cur[31]};
      2'd1: cur_pix = {6'h3F, cur[31:30]};
      2'd2: cur_pix = {4'hF,  cur[31:28]};
      default: cur_pix = cur[31:24];
    endcase
  end
  reg  [7:0] idx, mask_s1, mask_s2;
  reg        s_hb, s_vb, s_hs, s_vs, s_on;
  always @(posedge clk_vid) begin mask_s1 <= dac_mask; mask_s2 <= mask_s1; end
  always @(posedge clk_vid or negedge reset_n)
    if (!reset_n) begin
      sh <= 0; left <= 0; under <= 0; idx <= 0;
      s_hb <= 1; s_vb <= 1; s_hs <= 1; s_vs <= 1; s_on <= 0;
      hs_n <= 1; vs_n <= 1; hblank <= 1; vblank <= 1; r <= 0; g <= 0; b <= 0;
    end else begin
      if (settle != 0) left <= 0;
      if (ce_pix) begin
        // stage 1: the pixel and the timing
        if (showing) begin
          if (need && empty) under <= under + 1'b1;
          idx <= cur_pix & mask_s2;
          sh <= cur << bpp;
          left <= (need ? 6'd32 : left) - bpp;
        end
        s_on <= showing && !voff;
        s_hb <= !h_act; s_vb <= !v_act;
        s_hs <= !((hc >= HS0) && (hc < HS1));
        s_vs <= !vsync_v;
        // stage 2: the CLUT
        r <= s_on ? clut_v[idx][23:16] : 8'd0;
        g <= s_on ? clut_v[idx][15:8]  : 8'd0;
        b <= s_on ? clut_v[idx][7:0]   : 8'd0;
        hblank <= s_hb; vblank <= s_vb; hs_n <= s_hs; vs_n <= s_vs;
      end
    end

endmodule
