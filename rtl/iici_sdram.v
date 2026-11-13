// iici_sdram.v - the SDRAM controller behind the IIci's MDU (SE30_PLAN.md
// "THE MacIIci TOP AND ITS SDRAM", 2026-11-13: Daniel chose 150 MHz and the
// documented 5-clock RAM read).
//
// WHAT IT IS
//   se30_sdram.v's controller (its header has the board's lessons, all kept:
//   THE MASK IS ON A12/A11, single-location writes, THE DATA PINS ARE
//   LOADED A CLOCK AHEAD, the two read captures and THE TRAINING, THE
//   SECOND CHIP) re-timed for 150 MHz = 3 x clk_sys and given the MDU's
//   ports: a long or a burst of four for the CPU, a burst of eight for the
//   RBV's screen buffer, refresh in the MDU's window.  The raw experiment
//   port and the IIcx card's VRAM port are not here.
//
// THE CHIP AT 150 MHz: CAS latency 3 (the -6 and -7 parts' CL2 stops at
//   133 MHz), burst length 2, single-location writes (MODE $0231); tRCD 21
//   ns = 4 clocks, tRP 3, tRAS 42 ns = 7, tRC 63 ns = 10, tRFC 63 = 10,
//   tWR 2, tMRD 2.  Power-up: 200 us of NOP, PRECHARGE ALL, eight AUTO
//   REFRESH, LOAD MODE, the training.
//
// THE CPU'S READ (clocks of clk; edge 0 is the clk_sys edge after which
// the MDU's m_req appears, with AS*, on the KCLK wrapper)
//    1  m_req sampled (a 6.67 ns path from the wrapper's kb_* registers
//       through the MDU's decode)
//    2  ACTIVE
//    6  READ, auto-precharged (or the first of a burst's four)
//    9.6, 10.6  the chip's two words valid (CL3)
//   13, 14  through the capture chain (dq_q, dq_w, dq_m): the board's
//       delays are 2.4 of these clocks (one more than at 94 MHz)
//   14  m_rdata and m_ack on the low word's own clock, the acknowledge
//       held three clocks: exactly one clk_sys edge (15) sees it - the
//       MDU's termination clock for a 5-clock read (P0 + 100 ns)
//   A burst's longs follow two clocks apart from the chip and leave three
//   apart (one clk_sys edge each), from a four-long buffer.  A write is
//   two WRITEs at 6 and 7 and acknowledged at 6 (posted; the MDU holds
//   the next request for the acknowledge).
//
// THE VIDEO PORT: v_req (one clk_sys clock) asks for eight longs from
//   v_addr, one row (the RBV's bursts are 32-byte aligned): eight READs
//   two clocks apart; each long leaves on v_ack, three clocks apart.  The
//   CPU comes first at every decision; a CPU request that arrives during
//   a video burst waits for it (on the IIci bank B never waits for video:
//   those late cycles are the MDU's dbg_late).
//
// REFRESH: two AUTO REFRESH (each to both chips) in each of the MDU's
//   windows (m_refresh, every 15.57 us: one per 7.79 us, inside tREFI's
//   7.81); a counter forces one if the windows stop (before the CPU
//   runs).
//
// THE READ CAPTURE: the SE/30's arrangement (one I/O-cell register on A
//   or B through a clock control block, dq_w, dq_m on clk's falling edge),
//   the phases PROVISIONAL: the bench's board delays put the 150 MHz eye
//   2.9-5.7 ns after our edge, so A = clk - 1.2 ns and B = clk - 2.6 ns
//   in the bench; the compile's STA re-derives them, as plan 3.8 item 18
//   did for 94 MHz.
//
// PORTS: m_* the MDU's (clk_sys domain; iici_mdu.v), v_* the video port,
//   dl_* the HPS download, dk_* the floppy image's words (se30_sdram's
//   level handshakes), ready/cap_* the training's verdict.

`timescale 1ns/1ps

module iici_sdram #(
  parameter TR_READS_LOG2 = 16
) (
  input             clk,               // 150 MHz, 3 x clk_sys
  input             clk_sdc,           // the chip's clock, inverted at the pin
  input             clk_capa,          // read-data capture A
  input             clk_capb,          // read-data capture B
  input             phi,               // the top's clk_sys toggle: where the clk_sys edges are
  input             reset_n,
  output            ready,
  output reg        cap_sel,
  output reg  [1:0] cap_ok,
  output reg [13:0] cap_fail_a,
  output reg [13:0] cap_fail_b,
  output reg        c1_ok,
  output reg [13:0] c1_fail,

  // the MDU's port (clk_sys domain)
  input             m_req,             // one clk_sys clock
  input             m_we,
  input             m_burst,
  input      [24:0] m_addr,            // longword address
  input       [3:0] m_be,
  input      [31:0] m_wdata,
  output reg [31:0] m_rdata,
  output reg        m_ack,             // three clocks: one clk_sys edge
  output reg        m_soon,            // three clocks, three before a read's first m_ack: the long will be on m_rdata by the next clk_sys edge
  input             m_refresh,         // one clk_sys clock: the MDU's refresh window
  input             v_req,             // one clk_sys clock: eight longs from v_addr
  input      [24:0] v_addr,
  output reg [31:0] v_rdata,
  output reg        v_ack,

  // the download and the disk image (clk_sys domain, level handshakes)
  input             dl_req,
  input      [23:0] dl_addr,
  input      [15:0] dl_data,
  output reg        dl_ack,
  input             dk_req,
  input             dk_we,
  input      [23:0] dk_addr,
  input      [15:0] dk_wdata,
  output reg [15:0] dk_rdata,
  output reg        dk_ack,

  // the chip
  output            sd_clk,
  output            sd_cke,
  output reg [12:0] sd_addr,
  output reg  [1:0] sd_ba,
  inout      [15:0] sd_dq,
  output      [1:0] sd_dqm,
  output            sd_cs_n,
  output            sd_ras_n,
  output            sd_cas_n,
  output            sd_we_n
);

  localparam [3:0] CMD_INHIBIT   = 4'b1111,
                   CMD_NOP       = 4'b0111,
                   CMD_ACTIVE    = 4'b0011,
                   CMD_READ      = 4'b0101,
                   CMD_WRITE     = 4'b0100,
                   CMD_PRECHARGE = 4'b0010,
                   CMD_REFRESH   = 4'b0001,
                   CMD_LOAD_MODE = 4'b0000;
  // A9 = 1 single-location writes, A6-A4 = 011 CL3, A3 = 0 sequential, A2-A0 = 001 BL2
  localparam [12:0] MODE = 13'h0231;
  localparam INIT_PAUSE = 15'd30100;            // 200.7 us
  localparam REF_FORCE  = 11'd1150;             // 7.67 us with no refresh: one now
  localparam T_RCD      = 4'd4;                 // READ/WRITE this many clocks after ACTIVE
  localparam ACT_BUSY   = 5'd11;                // ACTIVE to the next ACTIVE or refresh: tRC 10 + 1
  localparam REF_BUSY   = 5'd11;                // tRFC 10 + 1 (the second chip's copy)
  // a READ's first word reaches dq_m for our edge this many clocks after
  // the READ: CL 3, the board's delays (clock out, tAC, data in: 2.4 of
  // these clocks in the benches' numbers, the board's STA), dq_q, dq_w,
  // dq_m - one more than the SE/30's at 94 MHz
  localparam [4:0] RD_LAT  = 5'd8;
  localparam [15:0] TR_W1 = 16'hA5C3, TR_W2 = 16'h5A3C;
  localparam  [1:0] TR_BANK = 2'd3;
  localparam [12:0] TR_ROW  = 13'd8191;
  localparam  [9:0] TR_COL  = 10'd510;
  localparam [17:0] TR_READS = 18'd1 << TR_READS_LOG2;

  reg  [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_dqm = sd_addr[12:11];
  assign sd_cke = 1'b1;

`ifdef SIMULATION
  assign sd_clk = ~clk_sdc;
`else
  altddio_out #(
    .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
    .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"), .width(1)
  ) sdclk_ddr (
    .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_sdc), .dataout(sd_clk),
    .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
  );
`endif

  reg [15:0] dq_out, dq_pre;
  reg        dq_oe, oe_pre;
  assign sd_dq = dq_oe ? dq_out : 16'hzzzz;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin dq_out <= 0; dq_oe <= 0; end
    else begin dq_out <= dq_pre; dq_oe <= oe_pre; end

  wire clk_cap;
`ifdef SIMULATION
  assign clk_cap = cap_sel ? clk_capb : clk_capa;
`else
  altclkctrl #(
    .clock_type("Global Clock"), .intended_device_family("Cyclone V"),
    .ena_register_mode("falling edge"), .implement_in_les("OFF"),
    .number_of_clocks(4), .use_glitch_free_switch_over_implementation("OFF"),
    .width_clkselect(2), .lpm_type("altclkctrl")
  ) cap_clkctrl (
    .inclk({clk_capb, clk_capa, 2'b00}), .clkselect({1'b1, cap_sel}), .ena(1'b1), .outclk(clk_cap)
  );
`endif
  // one register longer than se30_sdram's (dq_x): at 150 MHz a pin at the
  // chip's far edge cannot reach the core's registers in one period (compile
  // 4: three bits at -0.6 to -1.5 ns); two full periods on the capture clock
  // let the fitter split the route
  reg [15:0] dq_q, dq_w, dq_x, dq_m;
  always @(posedge clk_cap) begin dq_q <= sd_dq; dq_w <= dq_q; dq_x <= dq_w; end
  always @(negedge clk) dq_m <= dq_x;

  // ------------------------------------------------ the inputs
  // The MDU's request: sampled on every clock, taken on its rise (it is up
  // for one clk_sys clock, three of ours).  The download and disk ports:
  // se30_sdram's second-edge sampling.
  reg        phi_q, phi_qq;
  always @(posedge clk) begin phi_q <= phi; phi_qq <= phi_q; end
  wire       sample_en = (phi_q != phi_qq);
  reg        mq, m_new, vq, vq_q, rq, rq_q;
  reg        xm_we, xm_burst;
  reg [24:0] xm_addr, xv_addr;
  reg  [3:0] xm_be;
  reg [31:0] xm_wdata;
  reg        xs_dl_req, xs_dk_req, xs_dk_we;
  reg [23:0] xs_dl_addr, xs_dk_addr;
  reg [15:0] xs_dl_data, xs_dk_wdata;
  reg        m_pend, v_pend, r_pend;
  always @(posedge clk) begin
    // the MDU's request on the SECOND edge after the clk_sys edge (as the
    // download's): 13.3 ns from the wrapper's kb_* registers through the
    // MDU's decode (MacIIci.sdc's multicycle on mq, m_new and xm_*); the
    // read's data has the time to spare since the MDU terminates on m_soon
    m_new <= 0;
    if (sample_en) begin
      mq <= m_req;
      if (m_req && !mq) begin
        xm_we <= m_we; xm_burst <= m_burst; xm_addr <= m_addr; xm_be <= m_be; xm_wdata <= m_wdata; m_new <= 1;
      end
    end
    vq <= v_req; vq_q <= vq;
    rq <= m_refresh; rq_q <= rq;
    if (v_req && !vq) xv_addr <= v_addr;
    if (sample_en) begin
      xs_dl_req <= dl_req; xs_dl_addr <= dl_addr; xs_dl_data <= dl_data;
      xs_dk_req <= dk_req; xs_dk_we <= dk_we; xs_dk_addr <= dk_addr; xs_dk_wdata <= dk_wdata;
    end
  end
  wire v_new = vq && !vq_q;
  wire r_new = rq && !rq_q;

  wire [25:0] a_word = {xm_addr, 1'b0};
  wire [25:0] w_word = {xv_addr, 1'b0};

  // --------------------------------------------- the output pacing
  // Longs leave three clocks apart (one clk_sys edge each), from small
  // buffers: the CPU's four and the video's eight.
  reg [31:0] mb [0:3];
  reg  [2:0] mb_in, mb_out;
  reg [31:0] vb [0:7];
  reg  [3:0] vb_in, vb_out;
  reg  [1:0] m_hold, v_hold;           // the acknowledge's remaining clocks
  reg  [1:0] soon_hold;                // m_soon's remaining clocks
  reg        m_wack;                   // a write's acknowledge, to go out

  // --------------------------------------------------- the sequencer
  localparam [3:0] S_INIT = 4'd0, S_IDLE = 4'd1, S_RD = 4'd2, S_WR = 4'd3, S_VID = 4'd4, S_DL = 4'd5, S_TRAIN = 4'd6, S_DK = 4'd7;
  reg  [3:0] state;
  reg  [4:0] seq;
  reg  [4:0] busy;
  reg  [4:0] busy_n;                   // busy's next value (blocking, within the clock)
  // seq's and init_cnt's comparisons for the pins' registers, registered from
  // their next values (compile 4: seq -> cmd -1.58, init_cnt -> sd_addr -1.45)
  reg  [4:0] seq_n;
  reg        f_s0, f_sR, f_sR1, f_geR, f_even;
  reg [14:0] init_n;
  reg        ih_pause, ih_12, ih_3;
  reg        busy_z;                   // busy is 0 this clock (registered from busy_n)
  reg        ref_force;                // a refresh is overdue (registered)
  localparam [2:0] O_NONE = 3'd0, O_REF = 3'd1, O_VID = 3'd2, O_DL = 3'd3, O_DK = 3'd4;
  reg  [2:0] o_kind;                   // the other request, chosen a clock ahead
  reg        o_chip;
  reg  [1:0] o_ba;
  reg [12:0] o_row;
  reg [10:0] ref_cnt;
  reg  [1:0] ref_owed;                 // refreshes the MDU's window asked for
  reg [14:0] init_cnt;
  reg  [3:0] init_step;
  reg  [1:0] tr_step;
  reg        tr_pass, tr_c1;
  reg        c1_dup;
  reg  [2:0] c1_cmd;
  reg [12:0] c1_addr;
  reg [17:0] tr_n, tr_good;
  wire [17:0] tr_bad = TR_READS - tr_good;
  wire [13:0] tr_fail = (tr_bad > 18'd16383) ? 14'h3FFF : tr_bad[13:0];
  reg [15:0] tr_w1;
  reg        a_chip;
  reg  [1:0] a_bank;
  reg  [9:0] a_col;
  reg  [1:0] a_ent;                    // a burst's first long in its line
  reg  [2:0] a_n;                      // longs read so far (the READs issued)
  reg  [2:0] a_len;                    // longs to read: 1 or 4 (CPU), 8 (video)
  reg  [3:0] a_be;
  reg [31:0] a_wdata;
  reg  [3:0] rd_cnt;                   // words taken from dq_m
  reg        k_we_r;
  reg  [1:0] k_bank_r;
  reg  [8:0] k_col_r;
  reg [15:0] k_wdata_r;
  reg [15:0] hi_w;                     // a long's high word, waiting for its low one
  // which column each READ names: the CPU's burst wraps in its line
  wire [1:0] ent_n = a_ent + a_n[1:0];
  wire [9:0] col_n = (state == S_VID) ? {a_col[9:4], a_n[2:0], 1'b0} : {a_col[9:3], ent_n, 1'b0};

  assign ready = (state != S_INIT) && (state != S_TRAIN);

  integer i;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      state <= S_INIT; init_cnt <= 0; init_step <= 0; seq <= 0; busy <= 0; busy_z <= 1; ref_force <= 0;
      o_kind <= O_NONE; o_chip <= 0; o_ba <= 0; o_row <= 0;
      f_s0 <= 1; f_sR <= 0; f_sR1 <= 0; f_geR <= 0; f_even <= 1; ih_pause <= 0; ih_12 <= 0; ih_3 <= 0;
      cmd <= CMD_INHIBIT; sd_addr <= 0; sd_ba <= 0; dq_pre <= 0; oe_pre <= 0;
      m_ack <= 0; m_soon <= 0; soon_hold <= 0; m_rdata <= 0; v_ack <= 0; v_rdata <= 0; dl_ack <= 0; dk_ack <= 0; dk_rdata <= 0;
      ref_cnt <= 0; ref_owed <= 0; m_pend <= 0; v_pend <= 0;
      mb_in <= 0; mb_out <= 0; vb_in <= 0; vb_out <= 0; m_hold <= 0; v_hold <= 0; m_wack <= 0;
      a_chip <= 0; a_bank <= 0; a_col <= 0; a_ent <= 0; a_n <= 0; a_len <= 0; a_be <= 0; a_wdata <= 0; rd_cnt <= 0; hi_w <= 0;
      k_we_r <= 0; k_bank_r <= 0; k_col_r <= 0; k_wdata_r <= 0;
      cap_sel <= 0; cap_ok <= 0; tr_step <= 0; tr_pass <= 0; tr_c1 <= 0; tr_n <= 0; tr_good <= 0; tr_w1 <= 0;
      cap_fail_a <= 0; cap_fail_b <= 0; c1_ok <= 0; c1_fail <= 0;
      c1_dup <= 0; c1_cmd <= 3'b111; c1_addr <= 0;
    end else begin
      cmd <= CMD_NOP;
      c1_dup <= 0;
      busy_n = (busy != 0) ? busy - 1'b1 : 5'd0;
      seq_n = seq; init_n = init_cnt;
      if (ref_cnt != 11'h7FF) ref_cnt <= ref_cnt + 1'b1;
      if (state != S_INIT) sd_addr[12:11] <= 2'b00;
      if (m_new) m_pend <= 1;
      if (v_new) v_pend <= 1;
      if (r_new) ref_owed <= 2'd2;
      if (!xs_dl_req) dl_ack <= 0;
      if (!xs_dk_req) dk_ack <= 0;

      // the acknowledges: one clk_sys edge each
      if (m_hold != 0) begin m_hold <= m_hold - 1'b1; if (m_hold == 2'd1) m_ack <= 0; end
      else if (m_wack) begin m_wack <= 0; m_ack <= 1; m_hold <= 2'd3; end
      else if (mb_out != mb_in) begin m_rdata <= mb[mb_out[1:0]]; mb_out <= mb_out + 1'b1; m_ack <= 1; m_hold <= 2'd3; end
      if (v_hold != 0) begin v_hold <= v_hold - 1'b1; if (v_hold == 2'd1) v_ack <= 0; end
      else if (vb_out != vb_in) begin v_rdata <= vb[vb_out[2:0]]; vb_out <= vb_out + 1'b1; v_ack <= 1; v_hold <= 2'd3; end
      if (soon_hold != 0) begin soon_hold <= soon_hold - 1'b1; if (soon_hold == 2'd1) m_soon <= 0; end

      case (state)
        S_INIT: begin
          sd_addr[12:11] <= 2'b11;
          init_n = init_cnt + 1'b1;
          case (init_step)
            4'd0:  if (ih_pause) begin init_step <= 1; init_n = 0; end
            4'd1:  begin
              cmd <= CMD_PRECHARGE; sd_addr[10] <= 1'b1; init_step <= 2; init_n = 0;
              c1_dup <= 1; c1_cmd <= CMD_PRECHARGE[2:0]; c1_addr <= 13'h1C00;
            end
            4'd10: if (ih_12) begin
              cmd <= CMD_LOAD_MODE; sd_addr <= MODE; sd_ba <= 0; init_step <= 11; init_n = 0;
              c1_dup <= 1; c1_cmd <= CMD_LOAD_MODE[2:0]; c1_addr <= MODE;
            end
            4'd11: if (ih_3) begin
              state <= S_TRAIN; tr_step <= 0; tr_pass <= 0; tr_c1 <= 0; tr_n <= 0; tr_good <= 0; seq_n = 0; cap_sel <= 0;
            end
            default: if (ih_12) begin
              cmd <= CMD_REFRESH; init_step <= init_step + 1'b1; init_n = 0;
              c1_dup <= 1; c1_cmd <= CMD_REFRESH[2:0]; c1_addr <= 13'h1800;
            end
          endcase
        end

        // the training: se30_sdram's, at this clock's numbers - ACTIVE at
        // 0, the column command at T_RCD, a read's words from dq_m at
        // T_RCD + 6 and + 7, the next ACTIVE after tRC
        S_TRAIN: begin
          seq_n = seq + 1'b1;
          case (tr_step)
            2'd0: begin
              if (f_s0) begin cmd <= {tr_c1, CMD_ACTIVE[2:0]}; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (f_sR) begin cmd <= {tr_c1, CMD_WRITE[2:0]}; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b0, TR_COL}; end
              if (f_sR1) begin cmd <= {tr_c1, CMD_WRITE[2:0]}; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, TR_COL | 10'd1}; end
              if (seq == 5'd14) begin tr_step <= 1; seq_n = 0; end
            end
            2'd1: begin
              if (f_s0) begin cmd <= {tr_c1, CMD_ACTIVE[2:0]}; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (f_sR) begin cmd <= {tr_c1, CMD_READ[2:0]}; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, TR_COL}; end
              if (seq == T_RCD + RD_LAT) tr_w1 <= dq_m;
              if (seq == T_RCD + RD_LAT + 1) begin
                if (tr_w1 == TR_W1 && dq_m == TR_W2) tr_good <= tr_good + 1'b1;
                tr_n <= tr_n + 1'b1;
              end
              if (seq == 5'd14) begin seq_n = 0; if (tr_n == TR_READS) tr_step <= 2; end   // after the takes
            end
            default: begin
              if (seq == 0) begin
                if (tr_c1) begin c1_ok <= (tr_fail == 0); c1_fail <= tr_fail; end
                else if (!tr_pass) begin cap_ok[1] <= (tr_fail == 0); cap_fail_a <= tr_fail; cap_sel <= 1; end
                else begin
                  cap_ok[0] <= (tr_fail == 0); cap_fail_b <= tr_fail;
                  cap_sel <= (cap_fail_a == 0) ? 1'b0 : (tr_fail == 0) ? 1'b1 : (tr_fail < cap_fail_a);
                end
                tr_n <= 0; tr_good <= 0;
              end
              if (seq == 5'd20) begin
                seq_n = 0;
                if (tr_c1) begin state <= S_IDLE; ref_cnt <= 0; busy_n = 0; end
                else if (!tr_pass) begin tr_pass <= 1; tr_step <= 1; end
                else begin tr_c1 <= 1; tr_step <= 0; end
              end
            end
          endcase
        end

        // the CPU first, then refresh, then video, then the download and
        // the disk
        // The CPU's request decides on its own clock (the 5-clock read
        // needs ACTIVE at 2); every other request was chosen a clock ahead
        // (o_*, below) and the chip's readiness too (busy_z): the first
        // compile's -2.0 ns was this arbitration into sd_addr's I/O cells.
        S_IDLE: begin
          if (busy_z) begin
            if (m_pend || m_new) begin
              cmd <= {a_word[25], CMD_ACTIVE[2:0]}; sd_ba <= a_word[23:22]; sd_addr <= a_word[21:9];
              a_chip <= a_word[25]; a_bank <= a_word[23:22]; a_col <= {a_word[24], a_word[8:0]};
              a_ent <= xm_addr[1:0]; a_n <= 0; rd_cnt <= 0; a_len <= xm_burst ? 3'd4 : 3'd1;
              a_be <= xm_be; a_wdata <= xm_wdata;
              m_pend <= 0; seq_n = 1;
              // the next ACTIVE: tRC, or a burst's last READ + 2 + tRP
              busy_n = (xm_burst && !xm_we) ? 5'd16 : ACT_BUSY;
              state <= xm_we ? S_WR : S_RD;
            end else if (o_kind == O_REF) begin
              cmd <= CMD_REFRESH; busy_n = REF_BUSY; ref_cnt <= 0;
              if (ref_owed != 0) ref_owed <= ref_owed - 1'b1;
              c1_dup <= 1; c1_cmd <= CMD_REFRESH[2:0];
            end else if (o_kind != O_NONE) begin
              cmd <= {o_chip, CMD_ACTIVE[2:0]}; sd_ba <= o_ba; sd_addr <= o_row;
              seq_n = 1;
              case (o_kind)
                O_VID: begin
                  a_chip <= w_word[25]; a_bank <= w_word[23:22]; a_col <= {w_word[24], w_word[8:0]};
                  a_n <= 0; rd_cnt <= 0; a_len <= 3'd0;      // eight (a_n wraps at 8)
                  v_pend <= 0; busy_n = 5'd24; state <= S_VID;
                end
                O_DL: begin busy_n = ACT_BUSY; state <= S_DL; end
                default: begin                               // O_DK
                  k_we_r <= xs_dk_we; k_bank_r <= xs_dk_addr[23:22]; k_col_r <= xs_dk_addr[8:0]; k_wdata_r <= xs_dk_wdata;
                  busy_n = ACT_BUSY; state <= S_DK;
                end
              endcase
            end
          end
        end

        // a CPU read, a long or a burst of four: READs two clocks apart
        // from T_RCD, the last auto-precharged; the words from dq_m at
        // T_RCD + 6 on, one a clock
        S_RD, S_VID: begin
          seq_n = seq + 1'b1;
          if (f_geR && f_even && (state == S_VID ? (a_n != 3'd0 || f_sR) : (a_n < a_len))) begin
            cmd <= {a_chip, CMD_READ[2:0]}; sd_ba <= a_bank;
            sd_addr <= {2'b00, (state == S_VID) ? (a_n == 3'd7) : (a_n == a_len - 1'b1), col_n};
            a_n <= a_n + 1'b1;
          end
          // m_soon three clocks before the first long's m_ack (the clock its
          // low word arrives, T_RCD + RD_LAT + 1): whichever clk_sys edge
          // sees it, the long is on m_rdata by the next
          if (state == S_RD && seq == T_RCD + RD_LAT - 5'd2) begin m_soon <= 1; soon_hold <= 2'd3; end
          if (seq >= T_RCD + RD_LAT) begin
            rd_cnt <= rd_cnt + 1'b1;
            if (!rd_cnt[0]) hi_w <= dq_m;
            else if (state == S_RD) begin
              // the first long straight out, on its own clock (the MDU's
              // edge follows); a burst's others through the buffer
              if (m_hold == 0 && !m_wack && mb_out == mb_in) begin m_rdata <= {hi_w, dq_m}; m_ack <= 1; m_hold <= 2'd3; end
              else begin mb[mb_in[1:0]] <= {hi_w, dq_m}; mb_in <= mb_in + 1'b1; end
            end
            else begin vb[vb_in[2:0]] <= {hi_w, dq_m}; vb_in <= vb_in + 1'b1; end
            if (rd_cnt == ((state == S_VID) ? 4'd15 : {a_len, 1'b0} - 4'd1)) state <= S_IDLE;
          end
        end

        // a CPU write: two single-location WRITEs, the second auto-
        // precharged, acknowledged at the first (posted)
        S_WR: begin
          seq_n = seq + 1'b1;
          if (f_sR) begin
            cmd <= {a_chip, CMD_WRITE[2:0]}; sd_ba <= a_bank; sd_addr <= {~a_be[3:2], 1'b0, a_col};
            m_wack <= 1;
          end
          if (f_sR1) begin
            cmd <= {a_chip, CMD_WRITE[2:0]}; sd_ba <= a_bank; sd_addr <= {~a_be[1:0], 1'b1, a_col | 10'd1};
          end
          if (seq == T_RCD + 2) state <= S_IDLE;           // busy holds the next ACTIVE for tWR + tRP
        end

        S_DL: begin
          seq_n = seq + 1'b1;
          if (f_sR) begin cmd <= CMD_WRITE; sd_ba <= xs_dl_addr[23:22]; sd_addr <= {2'b00, 1'b1, 1'b0, xs_dl_addr[8:0]}; dl_ack <= 1; end
          if (seq == T_RCD + 1) state <= S_IDLE;
        end

        S_DK: begin
          seq_n = seq + 1'b1;
          if (f_sR) begin
            cmd <= k_we_r ? CMD_WRITE : CMD_READ; sd_ba <= k_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, k_col_r};
            if (k_we_r) dk_ack <= 1;
          end
          if (k_we_r && seq == T_RCD + 1) state <= S_IDLE;
          if (!k_we_r && seq == T_RCD + RD_LAT) begin dk_rdata <= dq_m; dk_ack <= 1; state <= S_IDLE; end
        end

        default: state <= S_IDLE;
      endcase

      // the data pins' next clock
      oe_pre <= 1'b0;
      case (state)
        S_TRAIN: if (tr_step == 2'd0) begin oe_pre <= 1'b1; dq_pre <= f_sR ? TR_W2 : TR_W1; end
        S_WR:    begin oe_pre <= 1'b1; dq_pre <= f_geR ? a_wdata[15:0] : a_wdata[31:16]; end
        S_DL:    begin oe_pre <= 1'b1; dq_pre <= xs_dl_data; end
        S_DK:    if (k_we_r) begin oe_pre <= 1'b1; dq_pre <= k_wdata_r; end
        default: ;
      endcase
      if (c1_dup) begin
        cmd <= {1'b1, c1_cmd};
        if (state == S_INIT) sd_addr <= c1_addr;
      end
      busy <= busy_n; busy_z <= (busy_n == 0);
      seq <= seq_n;
      f_s0 <= (seq_n == 5'd0); f_sR <= (seq_n == T_RCD); f_sR1 <= (seq_n == T_RCD + 5'd1);
      f_geR <= (seq_n >= T_RCD); f_even <= !seq_n[0];
      init_cnt <= init_n;
      ih_pause <= (init_n == INIT_PAUSE); ih_12 <= (init_n == 15'd12); ih_3 <= (init_n == 15'd3);
      // the next clock's other request, chosen now: refresh, the video,
      // the download, the disk (a clock stale: the issued one's flag clears
      // while the chip is busy, so it is never issued twice)
      ref_force <= (ref_cnt >= REF_FORCE);
      if (ref_owed != 0 || ref_force) begin o_kind <= O_REF; end
      else if (v_pend) begin o_kind <= O_VID; o_chip <= w_word[25]; o_ba <= w_word[23:22]; o_row <= w_word[21:9]; end
      else if (xs_dl_req && !dl_ack) begin o_kind <= O_DL; o_chip <= 1'b0; o_ba <= xs_dl_addr[23:22]; o_row <= xs_dl_addr[21:9]; end
      else if (xs_dk_req && !dk_ack) begin o_kind <= O_DK; o_chip <= 1'b0; o_ba <= xs_dk_addr[23:22]; o_row <= xs_dk_addr[21:9]; end
      else o_kind <= O_NONE;
    end

endmodule
