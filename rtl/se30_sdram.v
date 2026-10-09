// se30_sdram.v - the SDRAM controller behind GLUE's RAM and ROM ports: one 32-bit port meeting
// the 68030's four-clock RAM cycle by starting at ECS (a read speculative, auto-precharged); CL2,
// single-location writes, the mask on A12:11 (the MiSTer module's DQM wiring), refresh in idle
// clocks, and the read capture on clock A or B, chosen at power-up by a training read.

`timescale 1ns/1ps

module se30_sdram #(
  parameter TR_READS_LOG2 = 16       // the training's reads per capture, as a power of two
) (
  input             clk,               // 94.0032 MHz, 3 x clk_sys
  input             clk_sdc,           // clk + 1.064 ns: the chip's clock, inverted at the pin
  input             clk_capa,          // clk - 0.266 ns: read-data capture A
  input             clk_capb,          // clk - 2.261 ns: read-data capture B
  input             phi,               // the top's clk_sys toggle: where the clk_sys edges are
  input             reset_n,
  output            ready,
  output reg        cap_sel,           // the read capture in use: 0 = A, 1 = B
  output reg  [1:0] cap_ok,            // the training's verdict: {A clean, B clean}
  output reg [13:0] cap_fail_a,        // reads that did not return the pair through A, saturating
  output reg [13:0] cap_fail_b,        // and through B

  // the CPU port (clk_sys domain)
  input             cpu_start,         // ECS with a RAM/ROM address: the S0 half-clock
  input             cpu_req,           // GLUE's ram_req | rom_req: AS*-qualified, until acknowledged
  input             cpu_we,
  input      [22:0] cpu_addr,          // longword address
  input       [3:0] cpu_be,
  input      [31:0] cpu_wdata,
  output reg [31:0] cpu_rdata,
  output reg        cpu_ack,

  // the download port (clk_sys domain)
  input             dl_req,
  input      [23:0] dl_addr,           // word address
  input      [15:0] dl_data,
  output reg        dl_ack,
  input             dk_req,
  input             dk_we,
  input      [23:0] dk_addr,           // word address
  input      [15:0] dk_wdata,
  output reg [15:0] dk_rdata,
  output reg        dk_ack,

  // the raw experiment port (clk_sys domain): a JTAG instrument, only while the machine is in reset
  input             raw_req,
  input      [63:0] raw_ctl,
  input      [23:0] raw_addr,          // word address
  output reg        raw_ack,
  input             dbg_dqm_force,     // hold both DQM pins high (only while the machine is held in reset)

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

  // ---------------------------------------------------------- constants
  localparam [3:0] CMD_INHIBIT   = 4'b1111,   // {CS*, RAS*, CAS*, WE*}
                   CMD_NOP       = 4'b0111,
                   CMD_ACTIVE    = 4'b0011,
                   CMD_READ      = 4'b0101,
                   CMD_WRITE     = 4'b0100,
                   CMD_PRECHARGE = 4'b0010,
                   CMD_REFRESH   = 4'b0001,
                   CMD_LOAD_MODE = 4'b0000;
  // mode register: A9 = 1 single-location writes, CL2, sequential, burst length 2 (reads)
  localparam [12:0] MODE = 13'h0221;
  localparam INIT_PAUSE  = 15'd20000;          // 212.8 us >= the 200 us both datasheets ask
  localparam REF_EARLY   = 10'd600;            // 6.38 us: from here a refresh takes the first idle window after a cycle
  localparam REF_PERIOD  = 10'd700;            // 7.45 us: from here it goes at the first idle clock, inside tREFI's 7.81 us
  localparam REF_FORCE   = 10'd1023;           // overdue: refresh even with a CPU start pending
  localparam WIN_LO      = 6'd10;              // the idle window after a cycle, in clocks since its start:
  localparam WIN_HI      = 6'd17;              // a refresh issued here completes before a back-to-back start needs the chip
  localparam DK_HI       = 6'd15;              // and a disk word's (ACT_BUSY, two clocks longer) issued here
  localparam ACT_BUSY    = 4'd8;               // clocks from ACTIVE to the next ACTIVE or refresh
  localparam REF_BUSY    = 4'd6;               // tRFC 63 ns
  // the training: the pair, where it lives, how many reads
  localparam [15:0] TR_W1 = 16'hA5C3, TR_W2 = 16'h5A3C;
  localparam  [1:0] TR_BANK = 2'd3;
  localparam [12:0] TR_ROW  = 13'd8191;
  localparam  [8:0] TR_COL  = 9'd510;
  localparam [17:0] TR_READS = 18'd1 << TR_READS_LOG2;

  reg  [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  // the mask is on A12:11; the DQM pins copy it
  assign sd_dqm = sd_addr[12:11];
  assign sd_cke = 1'b1;

  // ------------------------------------------- the clock to the chip
  // the inverted clk_sdc: the chip's rising edge is 6.38 ns after ours, plus the clock's delay to the pin
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

  // ------------------------------------------------------ data pins
  reg [15:0] dq_out;
  reg        dq_oe;
  assign sd_dq = dq_oe ? dq_out : 16'hzzzz;
  // the pins' next value, decided a clock ahead, so the pins' registers take it with no logic between
  reg [15:0] dq_pre;
  reg        oe_pre;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin dq_out <= 0; dq_oe <= 0; end
    else begin dq_out <= dq_pre; dq_oe <= oe_pre; end

  // the read capture: one register in the I/O cell, on capture A or B through the global clock
  // network's select (switched only during the training); then dq_w on it, dq_m on clk's falling edge
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
  reg [15:0] dq_q, dq_w, dq_m;
  always @(posedge clk_cap) begin dq_q <= sd_dq; dq_w <= dq_q; end
  always @(negedge clk) dq_m <= dq_w;

  // -------------------------------------------- the inputs, registered
  // the clk_sys-domain inputs are sampled on the second clk after each clk_sys edge (a multicycle in the sdc)
  reg        phi_q, phi_qq;
  always @(posedge clk) begin phi_q <= phi; phi_qq <= phi_q; end
  wire       sample_en = (phi_q != phi_qq);           // one clock after the clk_sys edge: the edge after is the sample
  reg        xs_start, xs_start_evt, xs_req, xs_we, xs_dl_req;
  reg [22:0] xs_addr;
  reg  [3:0] xs_be;
  reg [31:0] xs_wdata;
  reg [23:0] xs_dl_addr;
  reg [15:0] xs_dl_data;
  reg        xs_raw_req;
  reg [63:0] xs_raw_ctl;
  reg [23:0] xs_raw_addr;
  reg        xs_dk_req, xs_dk_we;
  reg [23:0] xs_dk_addr;
  reg [15:0] xs_dk_wdata;
  always @(posedge clk) begin
    xs_start_evt <= 0;
    if (sample_en) begin
      xs_start <= cpu_start; xs_start_evt <= cpu_start && !xs_start;    // the start, once, for one clock
      xs_req <= cpu_req; xs_we <= cpu_we;
      xs_addr <= cpu_addr; xs_be <= cpu_be; xs_wdata <= cpu_wdata;
      xs_dl_req <= dl_req; xs_dl_addr <= dl_addr; xs_dl_data <= dl_data;
      xs_raw_req <= raw_req; xs_raw_ctl <= raw_ctl; xs_raw_addr <= raw_addr;
      xs_dk_req <= dk_req; xs_dk_we <= dk_we; xs_dk_addr <= dk_addr; xs_dk_wdata <= dk_wdata;
    end
  end
  wire       start_rise = xs_start_evt;
  wire       req_q = xs_req, we_q = xs_we, dl_req_q = xs_dl_req, raw_req_q = xs_raw_req, dk_req_q = xs_dk_req;
  // the experiment's fields
  wire [15:0] r_w0 = xs_raw_ctl[15:0], r_w1 = xs_raw_ctl[31:16];
  wire  [7:0] r_dqm = xs_raw_ctl[39:32];
  wire  [3:0] r_oe = xs_raw_ctl[43:40];
  wire  [3:0] r_sel = {1'b0, xs_raw_ctl[46:44]};
  wire        r_read = xs_raw_ctl[47];
  wire        r_ap = xs_raw_ctl[48], r_second = xs_raw_ctl[49], r_kind = xs_raw_ctl[50];
  wire [12:0] r_mode = xs_raw_ctl[63:51];
  wire  [1:0] r_bank = xs_raw_addr[23:22];
  wire [12:0] r_row  = xs_raw_addr[21:9];
  wire  [8:0] r_col  = xs_raw_addr[8:0];

  // the word address of the access: bank, row, column
  wire [23:0] a_word  = {xs_addr, 1'b0};
  wire  [1:0] a_bank  = a_word[23:22];
  wire [12:0] a_row   = a_word[21:9];
  wire  [8:0] a_col   = a_word[8:0];
  wire  [1:0] d_bank  = xs_dl_addr[23:22];
  wire [12:0] d_row   = xs_dl_addr[21:9];
  wire  [8:0] d_col   = xs_dl_addr[8:0];
  wire  [1:0] k_bank  = xs_dk_addr[23:22];
  wire [12:0] k_row   = xs_dk_addr[21:9];
  wire  [8:0] k_col   = xs_dk_addr[8:0];

  // --------------------------------------------------- the sequencer
  localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_ACC = 3'd2, S_DONE = 3'd3, S_DL = 3'd4, S_TRAIN = 3'd5, S_RAW = 3'd6, S_DK = 3'd7;
  reg  [2:0] state;
  reg  [3:0] seq;                      // clocks since the ACTIVE
  wire [1:0] r_k = seq[1:0] - 2'd2;    // the schedule's index on clocks 2..5 of a raw experiment
  wire [1:0] r_kn = seq[1:0] - 2'd1;   // and the next clock's, loaded a clock ahead
  reg  [3:0] busy;                     // clocks until the next ACTIVE or refresh may issue
  reg  [9:0] ref_cnt;
  reg        ref_due, ref_early, ref_force;
  reg  [5:0] since_start;              // clocks since the last start, saturating
  // the idle windows a clock ahead, as registers: the compares run on next_start
  wire [5:0] next_start = start_rise ? 6'd0 : (since_start != 6'd63) ? since_start + 1'b1 : 6'd63;
  reg        win_ref;                  // since_start in [WIN_LO, WIN_HI]: an early refresh fits
  reg        win_dk;                   // since_start in [WIN_LO, DK_HI], or 63 (an idle bus): a disk word fits
  reg        start_pend;               // a start seen and not yet served
  reg        a_we;                     // the access in flight is a write
  reg        a_written;                // its WRITE has issued
  reg  [1:0] a_bank_r;
  reg  [8:0] a_col_r;
  reg  [3:0] a_be;
  reg [31:0] a_wdata;
  reg        k_we_r;                   // the disk word in flight, latched at its ACTIVE
  reg  [1:0] k_bank_r;
  reg  [8:0] k_col_r;
  reg [15:0] k_wdata_r;
  reg [14:0] init_cnt;
  reg  [3:0] init_step;                // 0 pause, 1 precharge, 2-9 refreshes, 10 mode, 11 settle
  reg  [1:0] tr_step;                  // the training: 0 write the pair, 1 read it, 2 judge and switch
  reg        tr_pass;                  // 0 testing A, 1 testing B
  reg [17:0] tr_n;                     // reads done in this pass
  reg [17:0] tr_good;                  // reads that returned the pair
  wire [17:0] tr_bad = TR_READS - tr_good;
  wire [13:0] tr_fail = (tr_bad > 18'd16383) ? 14'h3FFF : tr_bad[13:0];
  reg [15:0] tr_w1;                    // the burst's first word, held for the compare
  assign ready = (state != S_INIT) && (state != S_TRAIN);
  // a CPU access may begin: a start (this clock or pending) or a request
  // whose start was missed, the chip ready for an ACTIVE, no overdue refresh
  wire       go = (start_rise || start_pend || req_q) && (busy == 0) && !ref_force;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      state <= S_INIT; init_cnt <= 0; init_step <= 0; seq <= 0; busy <= 0;
      cmd <= CMD_INHIBIT; sd_addr <= 0; sd_ba <= 0; dq_pre <= 0; oe_pre <= 0;
      cpu_ack <= 0; cpu_rdata <= 0; dl_ack <= 0; raw_ack <= 0; ref_cnt <= 0; ref_due <= 0; ref_early <= 0; ref_force <= 0;
      dk_ack <= 0; dk_rdata <= 0;
      since_start <= 6'd63; win_ref <= 0; win_dk <= 1;
      start_pend <= 0; a_we <= 0; a_written <= 0; a_bank_r <= 0; a_col_r <= 0; a_be <= 0; a_wdata <= 0;
      k_we_r <= 0; k_bank_r <= 0; k_col_r <= 0; k_wdata_r <= 0;
      cap_sel <= 0; cap_ok <= 2'b00; tr_step <= 0; tr_pass <= 0; tr_n <= 0; tr_good <= 0; tr_w1 <= 0;
      cap_fail_a <= 0; cap_fail_b <= 0;
    end else begin
      cmd    <= CMD_NOP;
      if (busy != 0) busy <= busy - 1'b1;
      if (ref_cnt != 10'h3FF) ref_cnt <= ref_cnt + 1'b1;
      ref_due   <= (ref_cnt >= REF_PERIOD);
      ref_early <= (ref_cnt >= REF_EARLY);
      ref_force <= (ref_cnt >= REF_FORCE);
      if (start_rise) start_pend <= 1;
      since_start <= next_start;
      win_ref <= (next_start >= WIN_LO) && (next_start <= WIN_HI);
      win_dk  <= ((next_start >= WIN_LO) && (next_start <= DK_HI)) || (next_start == 6'd63);
      if (!dl_req_q) dl_ack <= 0;
      if (!raw_req_q) raw_ack <= 0;
      if (!dk_req_q) dk_ack <= 0;
      if (state != S_INIT) sd_addr[12:11] <= 2'b00;                 // the mask: 00 unless a command says otherwise

      case (state)
        // ------------------------------------------------- power-up
        // 200 us of NOP with DQM high, PRECHARGE ALL, eight AUTO REFRESH, LOAD MODE, tMRD, the training
        S_INIT: begin
          sd_addr[12:11] <= 2'b11;                                  // DQM high; LOAD MODE's value overrides it
          init_cnt <= init_cnt + 1'b1;
          case (init_step)
            4'd0:  if (init_cnt == INIT_PAUSE) begin init_step <= 1; init_cnt <= 0; end
            4'd1:  begin cmd <= CMD_PRECHARGE; sd_addr[10] <= 1'b1; init_step <= 2; init_cnt <= 0; end
            4'd10: if (init_cnt == 15'd8) begin cmd <= CMD_LOAD_MODE; sd_addr <= MODE; sd_ba <= 0; init_step <= 11; init_cnt <= 0; end
            4'd11: if (init_cnt == 15'd2) begin
              state <= S_TRAIN; tr_step <= 0; tr_pass <= 0; tr_n <= 0; tr_good <= 0; seq <= 0; cap_sel <= 0;
            end
            default: if (init_cnt == 15'd8) begin cmd <= CMD_REFRESH; init_step <= init_step + 1'b1; init_cnt <= 0; end
          endcase
        end

        // ------------------------------------------- the training
        // the pair $A5C3/$5A3C at word $FFFFFE, read back 2^TR_READS_LOG2 times through A and B as a CPU
        // read is; A if no read failed, else B if none failed, else the fewer failures
        S_TRAIN: begin
          seq <= seq + 1'b1;
          case (tr_step)
            2'd0: begin                                             // the pair: two WRITEs, the second auto-precharged
              if (seq == 4'd0) begin cmd <= CMD_ACTIVE; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (seq == 4'd2) begin
                cmd <= CMD_WRITE; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b0, 1'b0, TR_COL};
              end
              if (seq == 4'd3) begin
                cmd <= CMD_WRITE; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, 1'b0, TR_COL | 9'd1};
              end
              if (seq == 4'd9) begin tr_step <= 1; seq <= 0; end
            end
            2'd1: begin                                             // a read, the same clocks as S_ACC's
              if (seq == 4'd0) begin cmd <= CMD_ACTIVE; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (seq == 4'd2) begin cmd <= CMD_READ; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, 1'b0, TR_COL}; end
              if (seq == 4'd7) tr_w1 <= dq_m;
              if (seq == 4'd8) begin
                if (tr_w1 == TR_W1 && dq_m == TR_W2) tr_good <= tr_good + 1'b1;
                tr_n <= tr_n + 1'b1;
              end
              if (seq == 4'd9) begin
                seq <= 0;
                if (tr_n == TR_READS) tr_step <= 2;
              end
            end
            default: begin                                          // judge this pass; switch; settle 16 clocks
              if (seq == 4'd0) begin
                if (!tr_pass) begin
                  cap_ok[1] <= (tr_fail == 0); cap_fail_a <= tr_fail;
                  cap_sel <= 1;                                     // B next
                end else begin
                  cap_ok[0] <= (tr_fail == 0); cap_fail_b <= tr_fail;
                  // A if clean; else B if clean; else the fewer failures (A on a tie)
                  cap_sel <= (cap_fail_a == 0) ? 1'b0 : (tr_fail == 0) ? 1'b1 : (tr_fail < cap_fail_a);
                end
                tr_n <= 0; tr_good <= 0;
              end
              if (seq == 4'd15) begin
                seq <= 0;
                if (!tr_pass) begin tr_pass <= 1; tr_step <= 1; end
                else begin state <= S_IDLE; ref_cnt <= 0; busy <= 0; end
              end
            end
          endcase
        end

        // ---------------------------------------------------- idle
        // the CPU first; refresh in the idle window after a cycle, at once when due, ahead of a start
        // when overdue; then a download or disk word
        S_IDLE: begin
          if (busy == 0) begin
            if (go) begin
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= xs_be; a_wdata <= xs_wdata;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0;
              state <= S_ACC;
            end else if (ref_due || (ref_early && win_ref)) begin
              cmd <= CMD_REFRESH; busy <= REF_BUSY; ref_cnt <= 0;
            end else if (dl_req_q && !dl_ack) begin
              cmd <= CMD_ACTIVE; sd_ba <= d_bank; sd_addr <= d_row;
              seq <= 1; busy <= ACT_BUSY;
              state <= S_DL;
            end else if (dk_req_q && !dk_ack && win_dk) begin
              // a disk word: in the window after a start, or on an idle bus
              cmd <= CMD_ACTIVE; sd_ba <= k_bank; sd_addr <= k_row;
              k_we_r <= xs_dk_we; k_bank_r <= k_bank; k_col_r <= k_col; k_wdata_r <= xs_dk_wdata;
              seq <= 1; busy <= ACT_BUSY;
              state <= S_DK;
            end else if (raw_req_q && !raw_ack) begin
              // an experiment: every row is closed here, so
              // a LOAD MODE may follow a PRECHARGE ALL at once
              if (r_kind) begin cmd <= CMD_PRECHARGE; sd_addr <= 13'h0400; busy <= 4'd6; end
              else begin cmd <= CMD_ACTIVE; sd_ba <= r_bank; sd_addr <= r_row; busy <= ACT_BUSY; end
              seq <= 1; state <= S_RAW;
            end
          end
        end

        // ------------------------------------------- a CPU access
        S_ACC: begin
          seq <= seq + 1'b1;
          if (!a_we) begin
            // a read: speculative, auto-precharged; the two words reach dq_m 7 and 8 clocks after ACTIVE
            if (seq == 4'd2) begin cmd <= CMD_READ; sd_ba <= a_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, a_col_r}; end
            if (seq == 4'd7) cpu_rdata[31:16] <= dq_m;
            if (seq == 4'd8) begin
              cpu_rdata[15:0] <= dq_m; cpu_ack <= req_q;
              state <= S_DONE;
            end
          end else begin
            // a write: the high word's WRITE once the request has confirmed the cycle, the low word's the
            // clock after; the row is precharged if another start supersedes it
            if (!a_written) begin
              if (seq == 4'd15) seq <= 4'd15;                       // count the wait, saturating
              if (req_q && seq >= 4'd2) begin                       // tRCD met at 2
                cmd <= CMD_WRITE; sd_ba <= a_bank_r; sd_addr <= {~a_be[3:2], 1'b0, 1'b0, a_col_r};
                a_written <= 1; seq <= 4'd3; cpu_ack <= 1;
                busy <= 4'd6;                                       // the low word, tWR, tRP: 4.8 from here
              end else if (seq >= 4'd5) begin
                // no request by now: the cycle was aborted; precharge
                cmd <= CMD_PRECHARGE; sd_ba <= a_bank_r; sd_addr[10] <= 1'b0;
                busy <= 4'd2; state <= S_IDLE;
              end
            end else begin
              if (seq == 4'd3) begin                                // the low word, auto-precharged
                cmd <= CMD_WRITE; sd_ba <= a_bank_r; sd_addr <= {~a_be[1:0], 1'b1, 1'b0, a_col_r | 9'd1};
              end
              if (seq == 4'd4) state <= S_DONE;
            end
          end
        end

        // ----------------------------- acknowledged, or waiting to be
        // a read's data waits for its request; a request after a new start belongs to that start, and
        // data unasked for 63 clocks after its start is dropped, so refresh is never starved
        S_DONE: begin
          if (req_q && !start_pend) cpu_ack <= 1;
          else begin
            cpu_ack <= 0;
            if (cpu_ack) state <= S_IDLE;
            else if (since_start == 6'd63) state <= S_IDLE;         // never requested: dropped
            else if (go) begin
              // the next cycle's start, with this one never requested: the
              // data is discarded and the row for the new one opens now
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= xs_be; a_wdata <= xs_wdata;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0;
              state <= S_ACC;
            end
          end
        end

        // ------------------------------------------ a download word
        // one single-location WRITE, auto-precharged; acknowledged as posted
        S_DL: begin
          seq <= seq + 1'b1;
          if (seq == 4'd2) begin
            cmd <= CMD_WRITE; sd_ba <= d_bank; sd_addr <= {2'b00, 1'b1, 1'b0, d_col};
            dl_ack <= 1;
          end
          if (seq == 4'd4) state <= S_IDLE;
        end

        // ------------------------------------------ a disk word
        // a write as the download's; a read auto-precharged, its first beat the addressed word
        S_DK: begin
          seq <= seq + 1'b1;
          if (seq == 4'd2) begin
            cmd <= k_we_r ? CMD_WRITE : CMD_READ; sd_ba <= k_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, k_col_r};
            if (k_we_r) dk_ack <= 1;
          end
          if (k_we_r && seq == 4'd4) state <= S_IDLE;
          if (!k_we_r && seq == 4'd7) begin dk_rdata <= dq_m; dk_ack <= 1; state <= S_IDLE; end
        end

        // ------------------------------------- a raw experiment
        S_RAW: begin
          seq <= seq + 1'b1;
          if (r_kind) begin                                         // PRECHARGE ALL was issued at entry
            if (seq == 4'd2) begin cmd <= CMD_LOAD_MODE; sd_addr <= r_mode; sd_ba <= 0; end
            if (seq == 4'd4) begin raw_ack <= 1; state <= S_IDLE; end  // tMRD met by busy
          end else begin
            if (seq == 4'd2) begin
              cmd <= r_read ? CMD_READ : CMD_WRITE; sd_ba <= r_bank;
              sd_addr <= {2'b00, r_ap && !(r_second && !r_read), 1'b0, r_col};
            end
            if (seq == 4'd3 && r_second && !r_read) begin
              cmd <= CMD_WRITE; sd_ba <= r_bank; sd_addr <= {2'b00, r_ap, 1'b0, r_col | 9'd1};
            end
            if (seq >= 4'd2 && seq <= 4'd5)                         // the schedule's mask (its data and enable: below)
              sd_addr[12:11] <= r_dqm[2 * r_k +: 2];               // after the column address: the schedule wins
            if (r_read && seq == 4'd7) cpu_rdata[31:16] <= dq_m;   // a read's words, as S_ACC takes them
            if (r_read && seq == 4'd8) cpu_rdata[15:0]  <= dq_m;
            if (seq == 4'd7 && !r_ap) begin                         // tRAS met at 4, tWR after the last data
              cmd <= CMD_PRECHARGE; sd_ba <= r_bank; sd_addr[10] <= 1'b0; busy <= 4'd3;
            end
            if (seq == 4'd9) begin raw_ack <= 1; state <= S_IDLE; end
          end
        end

        default: state <= S_IDLE;
      endcase

      // the data pins' next clock, from the state as it is now
      oe_pre <= 1'b0;
      case (state)
        S_TRAIN: if (tr_step == 2'd0) begin                         // the pair: $A5C3 at 2, $5A3C at 3
          oe_pre <= 1'b1; dq_pre <= (seq == 4'd2) ? TR_W2 : TR_W1;
        end
        S_ACC: if (a_we) begin                                      // the high word; the low one from the high WRITE's clock
          oe_pre <= 1'b1;
          dq_pre <= (a_written || (req_q && seq >= 4'd2)) ? a_wdata[15:0] : a_wdata[31:16];
        end
        S_DL: begin oe_pre <= 1'b1; dq_pre <= xs_dl_data; end
        S_DK: if (k_we_r) begin oe_pre <= 1'b1; dq_pre <= k_wdata_r; end
        S_RAW: if (!r_kind) begin                                   // the schedule's entry for the next clock
          oe_pre <= (seq >= 4'd1 && seq <= 4'd4) && r_oe[r_kn] && !r_read;
          dq_pre <= r_sel[r_kn] ? r_w1 : r_w0;
        end
        default: ;
      endcase
      // the mask held high while dbg_dqm_force is set, but never into a mode register's reserved bits
      if (dbg_dqm_force && state != S_INIT && !(state == S_RAW && r_kind)) sd_addr[12:11] <= 2'b11;
    end

endmodule
