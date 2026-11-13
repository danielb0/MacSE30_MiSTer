// iici_mdu.v - the Macintosh IIci's MDU (Memory Decode Unit): address
// decode, the overlay, the acknowledges, the two RAM banks' cycles and
// bursts, refresh, the E and SCC clocks, the bus-error timeout and the
// interrupt encoder, to SE30_PLAN.md "THE MDU" (2026-11-13).
//
// WHAT IT IS
//   No MDU data sheet exists among our documents.  This is its contract
//   from the Guide (G, 2e: Figure 3-8, pp.115-116, Tables 3-5 and 5-9) and
//   Designing Cards and Drivers 3e Figures 15-3..15-6 (the MDU's RAM
//   timing), written as a cycle machine; where they leave a point open the
//   choice is marked READING with its basis.  GLUE (se30_glue.v) is the
//   relative the 8-bit device cycles are taken from: the same chips on the
//   same 15.6672 MHz clock.
//
// CLOCKS
//   clk is clk_sys (50 MHz).  cpu_en marks one clk per CPU clock (25 MHz;
//   the KCLK machine's phi2, the edge the devices of se30_machine.v take):
//   RAM and ROM are timed in it.  c16_en is made here, 15.6672 MHz on
//   average (a phase accumulator, C16_NUM/C16_DEN of clk; 4896/15625 of
//   50 MHz is exact): "used for bus error and refresh timing" (G p.116);
//   the 8-bit devices, E and C3M run on it as GLUE's do.
//
// RAM AND ROM (cycle lengths in CPU clocks, AS* to the end of S5; GLUE's
// ram acknowledge in the clock after it first sees AS* is a 4-clock cycle
// on the KCLK wrapper, so a cycle of L clocks acknowledges L-3 clocks in)
//   RAM read 5, write 4, each 6 / 5 when it follows a write to the same
//   bank before its precharge has passed (DC3 Figures 15-3..15-6; READING:
//   "after a write" as a recovery of REC clocks from the write's end);
//   burst read 5-2-2-2 when CBREQ* (CBACK* with the first termination);
//   ROM 5 (G Table 5-9: 20.0 MB/s at 25 MHz).  The memory port answers
//   each long with m_ack; the termination is at the documented clock, or
//   later if the data is late (counted in dbg_late), never earlier.
//   Bank A at $00000000, bank B at $04000000 (A26), A27-A29 ignored
//   (READING); a bank aliases modulo its SIMMs' size and an empty bank
//   reads all ones (se30_simms's rule).  In the SDRAM: bank A at long 0,
//   bank B at 32 MB, the ROM at 24 MB (the SE/30's layout).
//   Refresh: every 15.6 us (244 C16M clocks) one RAM cycle's time (REF
//   CPU clocks) in which a RAM cycle waits; a cycle in progress first ends.
//
// I/O (G Figure 3-8): $50000000-$50007FFF, $50010000-$50017FFF and
//   $50024000-$50027FFF acknowledged as 8-bit ports (DSACK0*), the rest of
//   each $40000 not, and the whole repeating every $40000 to $50FFFFFF -
//   A17 decoded (the ROM's identification checks it, $40803064/$40803082).
//   $2000 windows on A17-A13: VIA1 0, SCC 2, SCSI handshake 3, SCSI 8,
//   pseudo-DMA 9, sound A, SWIM B, VDAC 12, RBV 13; window 1 (VIA2's place
//   on the II family) acknowledged with nothing there, reads $FF
//   (READING).  $51000000-$5FFFFFFF: no acknowledge from the MDU (the
//   RBV's chip select, the cache card, expansion and test: their own).
//   Device timings are GLUE's, in C16M clocks: VIA1 E-synchronous; SCC
//   with its 2.2 us hold-off; SWIM, SCSI, pseudo-DMA, VDAC, RBV one wait
//   state; sound 5 read / 4 write; the handshake port waits for DRQ.
//
// OVERLAY (READING, plan "THE MDU"): set at power-on reset (ROM at $0 as
//   at $40000000), cleared by the first access to $4xxxxxxx, as the
//   documented automatic overlays (the SE's BBU, the Portable's CPUGLU).
//
// BUS ERROR: no acknowledge within UI6's rule on a 22.25 kHz tick (as the
//   IIcx GLUE; the MDU's length is not documented).  FC = 7 never.
//
// INTERRUPTS (G Table 3-5): NMI 7, SCC 4, RBV 2, VIA1 1, autovectored.

`timescale 1ns/1ps

module iici_mdu #(
  parameter ROM_AW  = 17,              // the ROM's longword address bits: 512 KB
  parameter C16_NUM = 4896,            // c16_en = C16_NUM / C16_DEN of clk (15.6672 MHz from 50)
  parameter C16_DEN = 15625,
  parameter REC     = 1,               // CPU clocks after a RAM write's end in which its bank adds a clock (back to back: calibrated to the wrapper's gap)
  parameter REF     = 5,               // CPU clocks a refresh holds the RAM
  parameter VB      = 20               // CPU clocks a video burst holds bank A (5 + 7 x 2 + 1)
) (
  input         clk,
  input         cpu_en,                // one clk per CPU clock
  input         reset_n,               // power-on reset (the overlay's)
  output reg    c16_en,                // 15.6672 MHz average

  // the 68030's bus
  input  [31:0] cpu_addr,
  input         ecs,                   // ECS*, active high: the cycle's first clk (on the KCLK wrapper, with AS*)
  input         cpu_as_n,
  input         cpu_rw_n,
  input   [2:0] cpu_fc,
  input   [1:0] cpu_siz,
  input  [31:0] cpu_dout,
  output [31:0] cpu_din,
  output  [1:0] dsack_n,
  output        berr,
  output  [2:0] ipl_n,
  input         cbreq,                 // CBREQ*, active high
  output        cback,                 // CBACK*, active high

  // the RAM banks: 0 empty, 1 = 1 MB (256K SIMMs), 2 = 4 MB, 3 = 16 MB
  input   [1:0] bank_a,
  input   [1:0] bank_b,

  // the memory port: one request a RAM or ROM cycle; m_ack per long
  output        m_req,                 // one clk, from ECS* (combinational): the port takes m_we ... m_wdata with it
  output        m_we,
  output        m_burst,               // four longs, from m_addr wrapping in its 16-byte line
  output [24:0] m_addr,                // longword address in the SDRAM
  output  [3:0] m_be,
  output [31:0] m_wdata,
  input  [31:0] m_rdata,
  input         m_ack,
  input         m_soon,                // the port's word: a read's first long will be on m_rdata by the next clk edge
  output reg    m_refresh,             // one clk: the RAM's refresh starts (the SDRAM refreshes in its window)

  // the RBV's screen buffer: 8 longs a request, from bank A's base on
  // (G p.413); the longs from the SDRAM's video port, passed through
  input         vid_req,
  input         vid_frame,
  output reg    vid_ld,
  output reg [31:0] vid_data,
  output reg    v_req,                 // one clk: 8 longs from v_addr
  output [24:0] v_addr,
  input  [31:0] v_rdata,
  input         v_ack,

  // 8-bit devices, on D31-D24
  output        via1_sel,
  output        scc_sel,
  output        scsi_sel,
  output        scsi_dack,
  output        asc_sel,
  output        swim_sel,
  output        vdac_sel,
  output        rbv_sel,
  output reg    dev_strobe,            // one c16_en: the device latches (write) or must present (read)
  output [12:0] dev_addr,
  output        dev_rw,
  output  [7:0] dev_wdata,
  input   [7:0] dev_rdata,
  input         scsi_drq,
  output        e_clk,
  output reg    c3m_en,

  // the 68882: CPU space type 2, ID 1
  output        fpu_sel,
  input   [1:0] fpu_dsack_n,
  input  [31:0] fpu_rdata,

  // NuBus (the NuChip30): it terminates every slot cycle
  output        slot_sel,
  input   [1:0] nb_dsack_n,
  input  [31:0] nb_rdata,
  input         nb_berr,
  output  [3:0] slot_be,

  // interrupts
  input         via1_irq_n,
  input         rbv_irq_n,
  input         scc_irq_n,
  input         nmi_n,

  output        overlay,
  output [15:0] dbg_late               // RAM/ROM terminations the memory port made late
);

  // ------------------------------------------------------------ C16M
  reg [15:0] c16_acc;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin c16_acc <= 0; c16_en <= 0; end
    else if (c16_acc + C16_NUM >= C16_DEN) begin c16_acc <= c16_acc + C16_NUM - C16_DEN; c16_en <= 1; end
    else begin c16_acc <= c16_acc + C16_NUM; c16_en <= 0; end

  // ------------------------------------------------------------ decode
  reg        ovl;
  assign overlay = ovl;
  wire       fc7    = (cpu_fc == 3'd7);
  wire       d_fpu  = fc7 && (cpu_addr[19:13] == 7'b0010_001);
  wire       low_sp = (cpu_addr[31:30] == 2'b00);
  wire       d_ram  = !fc7 && low_sp && !ovl;
  wire       d_rom  = !fc7 && ((cpu_addr[31:28] == 4'h4) || (low_sp && ovl));
  wire       d_io   = !fc7 && (cpu_addr[31:24] == 8'h50);
  wire [4:0] win    = cpu_addr[17:13];
  wire       d_via1 = d_io && (win == 5'h00);
  wire       d_nil  = d_io && (win == 5'h01);              // acknowledged, nothing there
  wire       d_scc  = d_io && (win == 5'h02);
  wire       d_hs   = d_io && (win == 5'h03);
  wire       d_scsi = d_io && (win == 5'h08);
  wire       d_dma  = d_io && (win == 5'h09);
  wire       d_asc  = d_io && (win == 5'h0A);
  wire       d_swim = d_io && (win == 5'h0B);
  wire       d_vdac = d_io && (win == 5'h12);
  wire       d_rbv  = d_io && (win == 5'h13);
  wire       d_slot = !fc7 && (cpu_addr[31:29] >= 3'b011);
  wire       d_mem  = d_ram || d_rom;
  wire       fixed_port = d_nil || d_hs || d_scsi || d_dma || d_asc || d_swim || d_vdac || d_rbv;
  wire       d_dev  = d_via1 || d_scc || fixed_port;

  // the byte enables of a 32-bit port (UM Table 7-7)
  wire [2:0] siz_n = (cpu_siz == 2'b00) ? 3'd4 : {1'b0, cpu_siz};
  wire [2:0] a10   = {1'b0, cpu_addr[1:0]};
  wire [3:0] be    = { (a10 == 3'd0),
                       (a10 <= 3'd1) && (a10 + siz_n > 3'd1),
                       (a10 <= 3'd2) && (a10 + siz_n > 3'd2),
                       (a10 + siz_n > 3'd3) };

  // AS* seen high on any clk since the last enable that looked: the
  // enables are slower than the gap between two cycles (c16_en's 64 ns
  // against one CPU clock)
  reg as_hi_c, as_hi_d;

  // ------------------------------------------------------------ RAM, ROM
  // the bank and its offset: a bank aliases modulo its SIMMs' size
  wire       bank   = cpu_addr[26];
  wire [1:0] kind   = bank ? bank_b : bank_a;
  wire       empty  = d_ram && (kind == 2'd0);
  wire [21:0] off   = (kind == 2'd1) ? {4'b0, cpu_addr[19:2]} :
                      (kind == 2'd2) ? {2'b0, cpu_addr[21:2]} : cpu_addr[23:2];
  wire [24:0] ram_phys = {1'b0, bank, 1'b0, off};
  wire [24:0] rom_phys = {4'b0011, {(21-ROM_AW){1'b0}}, cpu_addr[ROM_AW+1:2]};
  wire       burst_ok = d_ram && !empty && cpu_rw_n && cbreq;
  assign cback = burst_ok;

  reg        m_act;                    // a RAM/ROM cycle: AS* seen with a memory address
  reg        m_done;                   // terminated (a single cycle: DSACK* held to AS*'s rise)
  reg        m_brst;                   // the cycle is a burst
  reg  [3:0] m_cnt;                    // CPU clocks since the cycle was first seen
  reg  [3:0] m_due;                    // the clock its first termination is due
  reg  [2:0] m_got;                    // longs the port has delivered
  reg  [2:0] m_used;                   // longs handed to the CPU
  reg [31:0] m_buf [0:3];
  reg  [1:0] b_ph;                     // the burst's beat phase
  reg        b_on;                     // DSACK* for this beat's clock
  reg [31:0] m_din;
  reg  [2:0] rec_a, rec_b;             // write recovery, CPU clocks left
  reg        m_wr_end;                 // the cycle ending was a RAM write: start its bank's recovery
  reg        m_bank;
  reg [15:0] late;
  assign dbg_late = late;

  // refresh: a tick every 244 C16M clocks; it runs REF CPU clocks once no
  // RAM cycle is in progress, and a RAM cycle waits for it
  reg  [7:0] refcnt;
  reg        ref_pend;
  reg  [2:0] ref_run;

  // the request goes out with ECS*, combinationally, as se30_machine's
  // mem_start does (plan 3.2): on the KCLK wrapper ECS* comes with AS*, and
  // the data is due with the termination - a 5-clock read leaves the SDRAM
  // 80 ns (four clks) from the clk edge that first sees the request.  A
  // refresh in progress only delays the termination: the SDRAM takes its
  // own then (m_refresh).
  wire mem_start = ecs && d_mem && !empty && !(d_rom && !cpu_rw_n);
  wire ref_go    = (ref_run == 0) && ref_pend && !m_act;     // a refresh starts at this cpu_en, before any new cycle
  // the video's bursts (THE RBV): a request starts a burst at a CPU clock
  // no CPU bank-A cycle holds; the burst holds bank A VB clocks
  reg        v_q, v_pend, m_ram_a;
  reg  [4:0] v_hold;
  reg [21:0] v_ptr, v_base;
  wire v_start   = (v_hold == 0) && v_pend && !(m_act && m_ram_a);
  assign v_addr  = {3'b000, v_base};
  wire held      = d_ram && ((ref_run != 0) || ref_go ||
                             (!bank && ((v_hold != 0) || v_start)));   // a RAM cycle waits out a refresh; bank A a video burst
  wire rec_hit   = d_ram && (bank ? (rec_b != 0) : (rec_a != 0));
  wire [3:0] due0 = d_rom ? 4'd2 : (cpu_rw_n ? 4'd2 : 4'd1);   // 5 / 4 clocks: L - 3

  // the longs in, counting the one arriving on this clk (taken straight
  // off the port: the SDRAM's 100 ns are to the termination's clock)
  // A write is posted: terminated at its clock, its acknowledge awaited
  // before the next request goes out (the SDRAM keeps the order).
  reg        m_wpend, m_hold;
  reg        q_we, q_burst;            // a request held for a posted write's acknowledge
  reg [24:0] q_addr;
  reg  [3:0] q_be;
  reg [31:0] q_wdata;
  wire       ack_w  = m_ack && m_wpend;
  wire       ack_r  = m_ack && !m_wpend;
  wire [2:0] m_have = m_got + (ack_r ? 3'd1 : 3'd0);
  // The request and the decision both read the registered pending flag, so
  // they always agree; a held request goes out as a registered pulse a whole
  // clk long (the controller samples it at its own edges, iici_sdram.v).
  reg        q_go;
  wire       blocked = m_wpend;
  assign m_req   = (mem_start && !blocked) || q_go;
  assign m_we    = q_go ? q_we    : !cpu_rw_n;
  assign m_burst = q_go ? q_burst : burst_ok;
  assign m_addr  = q_go ? q_addr  : (d_rom ? rom_phys : ram_phys);
  assign m_be    = q_go ? q_be    : be;
  assign m_wdata = q_go ? q_wdata : cpu_dout;
  // m_soon, latched: the termination may come on it, and the CPU then takes
  // the long straight off m_rdata at the wrapper's edge after (m_live) -
  // the KCLK wrapper takes a cycle's data a clk after its termination
  reg        soon_l, m_live;
  wire [31:0] m_next = (m_used == m_got) ? m_rdata : m_buf[m_used[1:0]];

  integer i;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      ovl <= 1; m_act <= 0; m_done <= 0; m_refresh <= 0; m_wpend <= 0; m_hold <= 0; q_go <= 0; soon_l <= 0; m_live <= 0; m_brst <= 0; m_cnt <= 0; m_due <= 0;
      m_got <= 0; m_used <= 0; b_ph <= 0; b_on <= 0; m_din <= 0; rec_a <= 0; rec_b <= 0;
      q_we <= 0; q_burst <= 0; q_addr <= 0; q_be <= 0; q_wdata <= 0; m_bank <= 0;
      late <= 0; m_wr_end <= 0; as_hi_c <= 0;
      v_q <= 0; v_pend <= 0; v_hold <= 0; v_ptr <= 0; v_base <= 0; v_req <= 0; vid_ld <= 0; vid_data <= 0; m_ram_a <= 0;
      refcnt <= 0; ref_pend <= 0; ref_run <= 0;
      for (i = 0; i < 4; i = i + 1) m_buf[i] <= 0;
    end else begin
      m_refresh <= 0; v_req <= 0;
      v_q <= vid_req;
      if (vid_req && !v_q) v_pend <= 1;
      if (vid_frame) v_ptr <= 0;
      vid_ld <= v_ack; vid_data <= v_rdata;
      if (cpu_as_n) as_hi_c <= 1;
      // the overlay ends at the first access to the ROM's own range
      if (!cpu_as_n && !fc7 && cpu_addr[31:28] == 4'h4) ovl <= 0;
      // the port's longs, in order
      if (ack_w) m_wpend <= 0;
      if (ack_r && m_got != 3'd4) begin m_buf[m_got[1:0]] <= m_rdata; m_got <= m_got + 1'b1; end
      q_go <= 0;
      if (mem_start || q_go) soon_l <= 0;
      else if (m_soon) soon_l <= 1;
      if (mem_start) begin
        m_got <= 0;
        if (blocked) begin
          m_hold <= 1; q_we <= !cpu_rw_n; q_burst <= burst_ok;
          q_addr <= d_rom ? rom_phys : ram_phys; q_be <= be; q_wdata <= cpu_dout;
        end else m_wpend <= !cpu_rw_n;
      end else if (m_hold && !m_wpend) begin
        m_hold <= 0; q_go <= 1; m_wpend <= q_we;
      end
      if (c16_en) begin
        refcnt <= (refcnt == 8'd243) ? 8'd0 : refcnt + 1'b1;
        if (refcnt == 8'd243) ref_pend <= 1;
      end
      if (cpu_en) begin
        as_hi_c <= 0;
        if (rec_a != 0) rec_a <= rec_a - 1'b1;
        if (rec_b != 0) rec_b <= rec_b - 1'b1;
        if (v_hold != 0) v_hold <= v_hold - 1'b1;
        else if (v_start) begin v_pend <= 0; v_hold <= VB - 1; v_req <= 1; v_base <= v_ptr; v_ptr <= v_ptr + 22'd8; end
        if (ref_run != 0) ref_run <= ref_run - 1'b1;
        else if (ref_go) begin ref_pend <= 0; ref_run <= REF - 1; m_refresh <= 1; end
        m_live <= 0;
        if (!m_act) begin
          // first seen: start counting once a refresh has let go of the RAM
          if (!cpu_as_n && d_mem && !held) begin
            m_act <= 1; m_done <= 0; m_cnt <= 4'd1; m_used <= 0; b_ph <= 0; b_on <= 0;
            m_brst <= burst_ok; m_bank <= bank; m_ram_a <= d_ram && !bank;
            m_due <= due0 + (rec_hit ? 4'd1 : 4'd0);
            if (d_ram && !cpu_rw_n) m_wr_end <= 1; else m_wr_end <= 0;
          end
        end else if (cpu_as_n || as_hi_c) begin
          // the cycle is over: a RAM write starts its bank's recovery
          m_act <= 0; m_done <= 0; b_on <= 0; m_brst <= 0; m_ram_a <= 0;
          if (m_wr_end) begin if (m_bank) rec_b <= REC; else rec_a <= REC; end
          m_wr_end <= 0;
        end else begin
          if (m_cnt != 4'hF) m_cnt <= m_cnt + 1'b1;
          if (!m_done) begin
            // the first termination: due, and the data in (an empty bank
            // and a write need none)
            if (m_cnt >= m_due) begin
              if (empty || !cpu_rw_n || (m_have != 0) || soon_l || m_soon) begin
                m_done <= 1; b_on <= 1; m_used <= 3'd1;
                m_live <= !empty && cpu_rw_n && (m_have == 0);
                m_din <= empty ? 32'hFFFFFFFF : (m_got == 0) ? m_rdata : m_buf[0];
                if (m_cnt > m_due) late <= late + 1'b1;
              end
            end
          end else if (m_brst && m_used != 3'd4) begin
            // the fill beats: DSACK* for one clock in every two
            if (b_on) b_on <= 0;
            else if (m_have > m_used) begin
              b_on <= 1; m_din <= m_next; m_used <= m_used + 1'b1;
            end else late <= late + 1'b1;
          end else if (m_brst) b_on <= 0;
        end
      end
    end

  // a single cycle's DSACK* is held until AS* rises; a burst's beats are pulses
  wire mem_ack = m_act && m_done && (m_brst ? b_on : 1'b1);

  // ------------------------------------------------- 8-bit devices (GLUE's)
  localparam SCC_HOLD = 6'd33;         // C16M clocks from select release to the next SCC select, 2.2 us
  reg        active, done;
  reg  [1:0] dcnt;
  reg  [7:0] dev_q;
  reg  [5:0] scc_hold;
  reg        ff1, ff2, berr_r;
  reg        scc_sel_q;

  reg  [4:0] eref;
  reg        e_r, rose, via_armed;
  reg  [3:0] eph;
  assign e_clk = e_r;
  wire via_pending = !cpu_as_n && d_via1 && !done;
  wire e_rise    = !e_r && !rose && (eph >= 4'd3) && (via_pending || eref >= 5'd9);
  wire e_fall    =  e_r && (via_armed ? (eph == 4'd3) : ((eref == 5'd19) || (via_pending && eph >= 4'd3)));
  wire e_strobe  =  e_r && via_armed && (eph == 4'd2);
  wire e_capture =  e_r && via_armed && (eph == 4'd3);

  wire [1:0] cap = (d_asc && cpu_rw_n) ? 2'd2 : 2'd1;
  wire dc_adv = !cpu_as_n && (!d_hs || dcnt != 0 || scsi_drq);
  wire scc_go  = d_scc && (dcnt == 0) && (scc_hold == 0);
  wire capture = active && ( (fixed_port && dcnt == cap && dc_adv)
                          || (d_scc && dcnt == 2'd2)
                          || (d_via1 && e_capture) );
  wire [7:0] rbyte = d_nil ? 8'hFF : dev_rdata;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      active <= 0; done <= 0; dcnt <= 0; dev_q <= 0; dev_strobe <= 0; scc_hold <= 0; as_hi_d <= 0;
    end else begin
      if (cpu_as_n) as_hi_d <= 1;
      if (c16_en) begin
        as_hi_d <= 0;
        dev_strobe <= 0;
        if (scc_hold != 0) scc_hold <= scc_hold - 1'b1;
        if (!active) begin
          if (!cpu_as_n && d_dev) begin
            active <= 1; done <= 0; dcnt <= 0;
            if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
            if (fixed_port && dc_adv) begin dcnt <= 1; if (cap == 2'd1) dev_strobe <= 1; end
          end
        end else if (cpu_as_n || as_hi_d) begin
          active <= 0; done <= 0; dcnt <= 0;
          if (d_scc || scc_sel_q) scc_hold <= SCC_HOLD;
        end else if (!done) begin
          if (d_scc) begin
            if (scc_go) begin dev_strobe <= 1; dcnt <= 1; end
            else if (dcnt != 0 && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
          end else begin
            if (dc_adv && dcnt != 2'd3) dcnt <= dcnt + 1'b1;
            if (fixed_port && dc_adv && dcnt == cap - 1'b1) dev_strobe <= 1;
          end
          if (d_via1 && e_strobe) dev_strobe <= 1;
          if (capture) begin done <= 1; dev_q <= rbyte; end
        end
      end
    end

  // the SCC's hold-off starts when its select drops, even if the address
  // has moved on by the clock the device machine sees AS* high
  always @(posedge clk or negedge reset_n)
    if (!reset_n) scc_sel_q <= 0;
    else if (c16_en) scc_sel_q <= scc_sel;

  // ------------------------------------------------------------ the bus
  wire dev_ack = !cpu_as_n && active && done && d_dev;
  assign cpu_din  = d_fpu ? fpu_rdata : d_slot ? nb_rdata :
                    d_dev ? {(active && done) ? dev_q : rbyte, 24'h000000} : m_live ? m_rdata : m_din;
  assign dsack_n  = d_fpu ? fpu_dsack_n : d_slot ? nb_dsack_n :
                    berr_r ? 2'b11 :
                    (!cpu_as_n && d_mem && mem_ack) ? 2'b00 :
                    dev_ack ? 2'b10 : 2'b11;
  assign fpu_sel  = !cpu_as_n && d_fpu;

  assign via1_sel  = !cpu_as_n && d_via1;
  assign scc_sel   = active && d_scc && (dcnt != 0);
  assign scsi_sel  = active && d_scsi;
  assign scsi_dack = active && (d_dma || (d_hs && dcnt != 0));
  assign asc_sel   = active && d_asc;
  assign swim_sel  = active && d_swim;
  assign vdac_sel  = active && d_vdac;
  assign rbv_sel   = active && d_rbv;
  assign slot_sel  = !cpu_as_n && d_slot;
  assign slot_be   = be;
  assign dev_addr  = cpu_addr[12:0];
  assign dev_rw    = cpu_rw_n;
  assign dev_wdata = cpu_dout[31:24];

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
    if (!reset_n) begin c3m_acc <= 0; c3m_en <= 0; end
    else if (c16_en) begin
      if (c3m_acc + 7'd15 >= 7'd64) begin c3m_acc <= c3m_acc + 7'd15 - 7'd64; c3m_en <= 1; end
      else begin c3m_acc <= c3m_acc + 7'd15; c3m_en <= 0; end
    end

  // -------------------------------------------------------- bus error
  // UI6's rule (se30_glue.v) on GLUE's 22.25 kHz tick: BERR after the
  // tick has been seen high, low and high again with AS* held and no
  // acknowledge.  The NuChip times out its own slot cycles.
  reg  [9:0] lt;
  reg        lt_hs_n;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin lt <= 0; lt_hs_n <= 1; end
    else if (c16_en) begin
      lt <= (lt == 10'd703) ? 10'd0 : lt + 1'b1;
      lt_hs_n <= (lt < 10'd416);
    end
  wire sys_as = !cpu_as_n && !fc7 && !d_slot;
  wire acked  = (d_mem && m_done) || (d_dev && done);
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin ff1 <= 0; ff2 <= 0; berr_r <= 0; end
    else if (c16_en) begin
      if (!sys_as) begin ff1 <= 0; ff2 <= 0; berr_r <= 0; end
      else begin
        if (lt_hs_n) ff1 <= 1;
        if (ff1 && !lt_hs_n) ff2 <= 1;
        if (ff1 && ff2 && lt_hs_n) berr_r <= 1;
      end
    end
  assign berr = (berr_r && sys_as && !acked) || (d_slot && nb_berr);

  // ------------------------------------------------------- interrupts
  assign ipl_n = !nmi_n      ? 3'b000 :
                 !scc_irq_n  ? 3'b011 :
                 !rbv_irq_n  ? 3'b101 :
                 !via1_irq_n ? 3'b110 : 3'b111;

endmodule
