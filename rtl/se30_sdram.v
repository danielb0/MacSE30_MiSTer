// se30_sdram.v - the SDRAM controller behind GLUE's RAM and ROM ports
// (SE30_PLAN.md 3.2, 3.3, 3.8 item 18).
//
// WHAT IT DOES
//   Puts the SE/30's RAM and ROM in the DE10-Nano's SDRAM as one 32-bit
//   port that meets GLUE's contract: the 68030 cycle to RAM or ROM is four
//   C16M clocks, the Guide's one wait state, so the acknowledge and the data
//   are at GLUE two C16M after the address appeared at S0 - 127.7 ns, 12 of
//   this module's clocks.  That is possible only by starting from the
//   address at S0, which the wrapper signals with the 68030's ECS (UM
//   7.1.1: "ECS can be used to initiate various timing sequences that are
//   eventually qualified with AS"): cpu_start opens the row and, for a
//   read, issues the READ speculatively (a RAM read has no side effect and
//   auto-precharge closes the row); cpu_req, GLUE's AS*-qualified request,
//   confirms the cycle, gates the acknowledge, and for a write gates the
//   WRITE itself.  A start that no request follows is the 68030's aborted
//   cycle: a read's data is discarded, a write's row is precharged.
//
//   The chip is driven to the worse of the W9825G6KH-6 and AS4C32M16SB-7
//   datasheets at every row (plan 3.2's table), at 94.0032 MHz = 3 x
//   clk_sys, phase-locked: CL2, burst length 2, sequential, burst writes;
//   tRCD and tRP 2 clocks, tRAS 4, tRC 6, tRFC 6, tMRD 2; one AUTO REFRESH
//   per 7.8125 us, scheduled into the idle clocks between cycles so it
//   never costs the CPU a wait state; power-up 200 us of NOP, PRECHARGE
//   ALL, eight AUTO REFRESH, LOAD MODE, then the read-capture training
//   below.  The geometry is the subset every MiSTer module presents: 4
//   banks x 8192 rows x 512 columns x 16 = 32 MB.
//
// THE CLOCKS (plan 3.8 item 18, decided 2026-09-27)
//   clk       94.0032 MHz: the sequencer, the outputs to the chip, and
//             everything downstream of the read capture
//   clk_sdc   clk + 1.064 ns: the chip's clock, inverted at the pin, so
//             the chip's rising edges are 6.38 ns after ours plus the
//             clock's delay to the pin; the phase balances the setup and
//             hold of our outputs at the chip (about 2.4 ns each)
//   clk_capa  clk - 0.266 ns: read-data capture A, for slow silicon
//   clk_capb  clk - 2.261 ns: read-data capture B, for fast silicon
//   clk_cap   the capture register's clock: A or B, chosen by cap_sel
//             through a clock control block
//   Why two captures: a read word is at our pin for about 6.6 ns, and
//   where a fixed capture edge lands in that eye moves 3.9 ns between the
//   slow and fast timing corners (the chip clock's path out and the data's
//   path in do not track), so no one edge is inside it at every corner -
//   compile 6's -0.128 ns of hold at the fast corner, hidden by single-
//   corner STA, was the $002A002A reset vector on the board (plan 4.11
//   item 8).  A is inside the eye at both slow corners by at least 1.40
//   ns, B at both fast corners by at least 1.89 (the experiment of 3.8
//   item 18, which reproduces the core's clock paths within 0.1 ns); the
//   training below picks the one that works.  One register, not two: a
//   Cyclone V I/O cell has one input clock (two registers on two clocks
//   put the second in the fabric; the DDIO atom's clkn refuses any other
//   source - both tried), and a fabric register would trade the cell's
//   characterised delay for a placed one.  The phases assume no input
//   delay chain on SDRAM_DQ: MacSE30.qsf pins the chains to zero and
//   MacSE30.sdc keeps the capture out of the fitter's hands, because a
//   fitter asked to meet both captures at every corner can meet neither
//   and would move the chains to try (compile 6's fitter had 1.5-2.5 ns
//   of chain on the DQ pins, tuning one capture as far as it could go).
//
// THE READ TIMELINE (clocks after the C16M edge that begins S0; the chip
// clocks on the falling edges of clk_sdc, 0.6 clock after our rising ones)
//    2  cpu_start, the address and R/W sampled (the second clock after the
//       clk_sys edge: 21 ns for the kernel's address cone, see the xs_*
//       registers below)
//    3  ACTIVE                              chip 3.6
//    5  READ with auto-precharge            chip 5.6   (tRCD 21.28 >= 21)
//    6.6, 7.6  the chip launches the two words: CAS latency 2 means the
//              first word is VALID at the second chip edge after the READ
//              (7.6), launched from the edge before it (AS4C32M16SB 1.4:
//              CL is "the number of clock cycles from the assertion of the
//              Read command to the first read data"; the model's comment
//              at its READ has the quotes).  Each word is at our pin from
//              (the clock's delay to the pin, about 4 ns, + tAC 6.0 +
//              trace) 10.5 ns after the launch edge to (that delay + a
//              period + tOH 2.5) 17.1 ns after it
//    8, 9      captured in the I/O cell (dq_q) on clk_cap: A 14.6 ns after
//              the launch edge, B 12.6.  MacSE30.sdc states the capture as
//              a two-cycle setup multicycle on dq_q from the chip's clock,
//              for either capture clock; the default hold check that comes
//              with it is the real one (the next word's arrival)
//    9, 10     dq_w, a fabric register on the same clock: the cell-to-
//              fabric path takes most of a period at the slow corner
//    9.5, 10.5 dq_m, on the FALLING edge of clk: the crossing into the clk
//              domain, 5.6 ns from A's edge and 7.6 from B's, an ordinary
//              single-cycle path for either, with no credit anywhere
//   10, 11     taken into cpu_rdata on our rising edge, half a period from
//              dq_m; cpu_ack with the second word at 11
//   12  GLUE samples: one clock in hand (two, before item 18).
//   Until 2026-09-27 this timeline had the launches at 7.5 and 8.5 - MacLC's
//   reading of CL2, one clock late - and the first board reading showed the
//   chip keeping to the datasheet: the capture at 9 took the SECOND word,
//   the one at 10 the floating bus after the burst (SE30_PLAN.md 3.8 item
//   15: a reset vector of $002A002A from $4080002A).
//   A write: WRITE at 6 (cpu_req, AS* having asserted at S1, was sampled
//   at 5) with the high word and its DQM from be[3:2], the low word at 7;
//   acknowledged as posted.  Any ACTIVE is followed by eight clocks before
//   the next ACTIVE or refresh (tRC 63; a write's tWR + tRP well inside).
//
// THE TRAINING (S_TRAIN, after the ladder and before ready)
//   Writes the complementary pair $A5C3, $5A3C to the top two words of the
//   32 MB (word $FFFFFE: bank 3, row 8191, columns 510-511 - above the RAM
//   image and the ROM, reserved for this), then reads them back as one
//   burst 32 times through A and 32 times through B, consuming dq_m at
//   the same clocks a CPU read does, so the test is the operational path.
//   A capture that returns the pair every time passes.  Both pass: A,
//   because a cold board warms and slows, which widens A's margin (its
//   failing side is hold, on fast silicon) and narrows B's (setup, on slow
//   silicon).  Only one passes: that one.  Neither: A, and cap_ok reads
//   00 - the probe deck's PSTA carries {cap_sel, cap_fail, cap_ok} so the
//   board says what it chose.  A wrong capture cannot return the pair:
//   early it reads the bus before the word (the previous word, or the
//   floating bus holding the last word driven, always $5A3C), late it
//   reads the second word for the first; the pair differs in every bit.
//   The choice stands until the PLL loses lock - the machine's resets do
//   not repeat it.
//
// PORTS
//   cpu_*   the clk_sys-domain signals of the machine, registered here first
//           (the related-clock path is then a register-to-register hop).
//           cpu_addr is a longword address in the 32 MB; cpu_be bit 3 is
//           D31-D24.  cpu_ack is a level held while cpu_req is up: a read's
//           data is on cpu_rdata, a write is posted.
//   dl_*    the HPS download (boot0.rom): 16-bit words, a level request
//           acknowledged by a level held until the request drops; served
//           when the CPU port is idle, never touching cpu_ack.
//   ready   the power-up ladder and the training have run.
//   cap_sel the capture in use: 0 = A, 1 = B.  cap_ok {A passed, B passed}.

`timescale 1ns/1ps

module se30_sdram (
  input             clk,               // 94.0032 MHz, 3 x clk_sys
  input             clk_sdc,           // clk + 1.064 ns: the chip's clock, inverted at the pin
  input             clk_capa,          // clk - 0.266 ns: read-data capture A
  input             clk_capb,          // clk - 2.261 ns: read-data capture B
  input             phi,               // the top's clk_sys toggle: where the clk_sys edges are
  input             reset_n,
  output            ready,
  output reg        cap_sel,           // the read capture in use: 0 = A, 1 = B
  output reg  [1:0] cap_ok,            // the training's verdict: {A passed, B passed}
  output reg  [5:0] cap_good_a,        // reads of TR_READS that returned the pair through A
  output reg  [5:0] cap_good_b,        //   and through B (the probe deck's PCAP)

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

  // the chip
  output            sd_clk,
  output            sd_cke,
  output reg [12:0] sd_addr,
  output reg  [1:0] sd_ba,
  inout      [15:0] sd_dq,
  output reg  [1:0] sd_dqm,
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
  // mode register: A9 = 0 burst writes, A8-A7 = 00, A6-A4 = 010 CL2,
  // A3 = 0 sequential, A2-A0 = 001 burst length 2
  localparam [12:0] MODE = 13'h0021;
  localparam INIT_PAUSE  = 15'd20000;          // 212.8 us >= the 200 us both datasheets ask
  localparam REF_EARLY   = 10'd600;            // 6.38 us: from here a refresh takes the first idle window after a cycle
  localparam REF_PERIOD  = 10'd700;            // 7.45 us: from here it goes at the first idle clock, inside tREFI's 7.81 us
  localparam REF_FORCE   = 10'd1023;           // overdue: refresh even with a CPU start pending
  localparam WIN_LO      = 6'd10;              // the idle window after a cycle, in clocks since its start:
  localparam WIN_HI      = 6'd17;              //   a refresh issued here completes before a back-to-back start needs the chip
  localparam ACT_BUSY    = 4'd8;               // clocks from ACTIVE to the next ACTIVE or refresh
  localparam REF_BUSY    = 4'd6;               // tRFC 63 ns
  // the training (the header): the pair, where it lives, how many reads
  localparam [15:0] TR_W1 = 16'hA5C3, TR_W2 = 16'h5A3C;
  localparam  [1:0] TR_BANK = 2'd3;
  localparam [12:0] TR_ROW  = 13'd8191;
  localparam  [8:0] TR_COL  = 9'd510;
  localparam  [5:0] TR_READS = 6'd32;

  reg  [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_cke = 1'b1;

  // ------------------------------------------- the clock to the chip
  // The inverted clk_sdc: the chip's rising edge is 6.38 ns after ours
  // (plus the clock's delay to the pin), 4.3 ns before our registered
  // outputs next change - MacLC's arrangement moved 1.064 ns later, the
  // header says why.
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

  // The read capture: one register in the I/O cell, on capture A or B as
  // cap_sel says (the header).  The clock control block is the Cyclone V
  // global clock network's own select; PLL outputs must feed its inputs
  // 2 and 3 (Quartus 15836; 0 and 1 are for clock pins), so the select is
  // {1, cap_sel}.  Switching it is not glitch-free, which is harmless: it
  // switches only during the training, with sixteen clocks of settling
  // before the next read, and nothing reads the capture in between.
  // Then the chain into the clk domain (the timeline): dq_w a full period
  // on the capture clock, dq_m on clk's falling edge.
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
  // The clk_sys-domain inputs are sampled on the SECOND of our clocks after
  // each clk_sys edge (sample_en), not the first: the address and write
  // data are the kernel's address adder and the beat engine's byte
  // routing, 15 ns of logic (the first compile: 12 levels, -5.7 ns against
  // the 10.6 ns single-cycle window between the related clocks), and the
  // second edge gives them 21 ns.  MacSE30.sdc says so with a two-cycle
  // multicycle on exactly these xs_* registers.  phi is the top's clk_sys
  // toggle; its own crossing is a register-to-register hop.
  reg        phi_q, phi_qq;
  always @(posedge clk) begin phi_q <= phi; phi_qq <= phi_q; end
  wire       sample_en = (phi_q != phi_qq);           // one clock after the clk_sys edge: the edge after is the sample
  reg        xs_start, xs_start_evt, xs_req, xs_we, xs_dl_req;
  reg [22:0] xs_addr;
  reg  [3:0] xs_be;
  reg [31:0] xs_wdata;
  reg [23:0] xs_dl_addr;
  reg [15:0] xs_dl_data;
  always @(posedge clk) begin
    xs_start_evt <= 0;
    if (sample_en) begin
      xs_start <= cpu_start; xs_start_evt <= cpu_start && !xs_start;    // the start, once, for one clock
      xs_req <= cpu_req; xs_we <= cpu_we;
      xs_addr <= cpu_addr; xs_be <= cpu_be; xs_wdata <= cpu_wdata;
      xs_dl_req <= dl_req; xs_dl_addr <= dl_addr; xs_dl_data <= dl_data;
    end
  end
  wire       start_rise = xs_start_evt;
  wire       req_q = xs_req, we_q = xs_we, dl_req_q = xs_dl_req;

  // the word address of the access: bank, row, column
  wire [23:0] a_word  = {xs_addr, 1'b0};
  wire  [1:0] a_bank  = a_word[23:22];
  wire [12:0] a_row   = a_word[21:9];
  wire  [8:0] a_col   = a_word[8:0];
  wire  [1:0] d_bank  = xs_dl_addr[23:22];
  wire [12:0] d_row   = xs_dl_addr[21:9];
  wire  [8:0] d_col   = xs_dl_addr[8:0];

  // --------------------------------------------------- the sequencer
  localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_ACC = 3'd2, S_DONE = 3'd3, S_DL = 3'd4, S_TRAIN = 3'd5;
  reg  [2:0] state;
  reg  [3:0] seq;                      // clocks since the ACTIVE
  reg  [3:0] busy;                     // clocks until the next ACTIVE or refresh may issue
  reg  [9:0] ref_cnt;
  reg        ref_due, ref_early, ref_force;
  reg  [5:0] since_start;              // clocks since the last start, saturating: where in a cycle we are
  reg        start_pend;               // a start seen and not yet served
  reg        a_we;                     // the access in flight is a write
  reg        a_written;                // its WRITE has issued
  reg  [1:0] a_bank_r;
  reg  [8:0] a_col_r;
  reg  [3:0] a_be;
  reg [31:0] a_wdata;
  reg [14:0] init_cnt;
  reg  [3:0] init_step;                // 0 pause, 1 precharge, 2-9 refreshes, 10 mode, 11 settle
  reg  [1:0] tr_step;                  // the training: 0 write the pair, 1 read it, 2 judge and switch
  reg        tr_pass;                  // 0 testing A, 1 testing B
  reg  [5:0] tr_n, tr_good;            // reads done in this pass, reads that returned the pair
  reg [15:0] tr_w1;                    // the burst's first word, held for the compare
  assign ready = (state != S_INIT) && (state != S_TRAIN);
  // a CPU access may begin: a start (this clock or pending) or a request
  // whose start was missed, the chip ready for an ACTIVE, no overdue refresh
  wire       go = (start_rise || start_pend || req_q) && (busy == 0) && !ref_force;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      state <= S_INIT; init_cnt <= 0; init_step <= 0; seq <= 0; busy <= 0;
      cmd <= CMD_INHIBIT; sd_addr <= 0; sd_ba <= 0; sd_dqm <= 2'b11; dq_out <= 0; dq_oe <= 0;
      cpu_ack <= 0; cpu_rdata <= 0; dl_ack <= 0; ref_cnt <= 0; ref_due <= 0; ref_early <= 0; ref_force <= 0;
      since_start <= 6'd63;
      start_pend <= 0; a_we <= 0; a_written <= 0; a_bank_r <= 0; a_col_r <= 0; a_be <= 0; a_wdata <= 0;
      cap_sel <= 0; cap_ok <= 2'b00; tr_step <= 0; tr_pass <= 0; tr_n <= 0; tr_good <= 0; tr_w1 <= 0;
      cap_good_a <= 0; cap_good_b <= 0;
    end else begin
      cmd    <= CMD_NOP;
      dq_oe  <= 0;
      if (busy != 0) busy <= busy - 1'b1;
      if (ref_cnt != 10'h3FF) ref_cnt <= ref_cnt + 1'b1;
      ref_due   <= (ref_cnt >= REF_PERIOD);
      ref_early <= (ref_cnt >= REF_EARLY);
      ref_force <= (ref_cnt >= REF_FORCE);
      if (start_rise) begin start_pend <= 1; since_start <= 0; end
      else if (since_start != 6'd63) since_start <= since_start + 1'b1;
      if (!dl_req_q) dl_ack <= 0;
      if (state != S_INIT) sd_dqm <= 2'b00;

      case (state)
        // ------------------------------------------------- power-up
        // 200 us of NOP with DQM high, PRECHARGE ALL, eight AUTO REFRESH
        // eight clocks apart (tRFC 63 ns), LOAD MODE, tMRD, then the
        // training.
        S_INIT: begin
          sd_dqm <= 2'b11;
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
        // The header.  Each access here is a CPU access's shape - ACTIVE
        // at 0, the column command at 2, a read's words consumed from dq_m
        // at 7 and 8 - and the next ACTIVE comes ten clocks after the last
        // (tRC 63, a write's tWR + tRP inside).
        S_TRAIN: begin
          seq <= seq + 1'b1;
          case (tr_step)
            2'd0: begin                                             // the pair, one burst write, auto-precharged
              if (seq == 4'd0) begin cmd <= CMD_ACTIVE; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (seq == 4'd2) begin
                cmd <= CMD_WRITE; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, 1'b0, TR_COL};
                dq_out <= TR_W1; sd_dqm <= 2'b00; dq_oe <= 1;
              end
              if (seq == 4'd3) begin dq_out <= TR_W2; dq_oe <= 1; end
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
                  cap_ok[1] <= (tr_good == TR_READS); cap_good_a <= tr_good;
                  cap_sel <= 1;                                     // B next
                end else begin
                  cap_ok[0] <= (tr_good == TR_READS); cap_good_b <= tr_good;
                  cap_sel <= cap_ok[1] ? 1'b0 : (tr_good == TR_READS);   // A if it passed, else B if it did, else A
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
        // The CPU first: its start (or a request the start of which was
        // missed, e.g. while a refresh ran) opens the row.  Then refresh:
        // once it is nearly due it takes the idle window right after a
        // cycle, where it completes before a back-to-back cycle's start
        // needs the chip, so a stream of RAM cycles never waits for it;
        // once due it goes at the first idle clock (the bus has been idle,
        // so no stream is running); overdue, it outranks a start.  Then a
        // download word.
        S_IDLE: begin
          if (busy == 0) begin
            if (go) begin
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= xs_be; a_wdata <= xs_wdata;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0;
              state <= S_ACC;
            end else if (ref_due || (ref_early && since_start >= WIN_LO && since_start <= WIN_HI)) begin
              cmd <= CMD_REFRESH; busy <= REF_BUSY; ref_cnt <= 0;
            end else if (dl_req_q && !dl_ack) begin
              cmd <= CMD_ACTIVE; sd_ba <= d_bank; sd_addr <= d_row;
              seq <= 1; busy <= ACT_BUSY;
              state <= S_DL;
            end
          end
        end

        // ------------------------------------------- a CPU access
        S_ACC: begin
          seq <= seq + 1'b1;
          if (!a_we) begin
            // a read: speculative, auto-precharged; the two words reach
            // dq_m for our rising edges at 7 and 8 clocks after ACTIVE:
            // the READ at 2, the words valid at the chip's edges 4.6 and
            // 5.6, captured into dq_q at 5 and 6, dq_w at 6 and 7, dq_m
            // at 6.5 and 7.5 (the timeline above)
            if (seq == 4'd2) begin cmd <= CMD_READ; sd_ba <= a_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, a_col_r}; end
            if (seq == 4'd7) cpu_rdata[31:16] <= dq_m;
            if (seq == 4'd8) begin
              cpu_rdata[15:0] <= dq_m; cpu_ack <= req_q;
              state <= S_DONE;
            end
          end else begin
            // a write: WRITE once the request has confirmed the cycle;
            // the row waits open for a late request (GLUE's refresh
            // window) and is precharged if another start supersedes it
            if (!a_written) begin
              if (seq == 4'd15) seq <= 4'd15;                       // count the wait, saturating
              if (req_q && seq >= 4'd2) begin                       // tRCD met at 2
                cmd <= CMD_WRITE; sd_ba <= a_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, a_col_r};
                dq_out <= a_wdata[31:16]; sd_dqm <= ~a_be[3:2]; dq_oe <= 1;
                a_written <= 1; seq <= 4'd3; cpu_ack <= 1;
                busy <= 4'd6;                                       // the low word, tWR, tRP: 4.8 from here
              end else if (seq >= 4'd5) begin
                // no request by now: the cycle was aborted (a request that
                // GLUE's refresh window delays comes later and re-opens the
                // row from S_IDLE).  tRAS is met at 5.
                cmd <= CMD_PRECHARGE; sd_ba <= a_bank_r; sd_addr[10] <= 1'b0;
                busy <= 4'd2; state <= S_IDLE;
              end
            end else begin
              if (seq == 4'd3) begin dq_out <= a_wdata[15:0]; sd_dqm <= ~a_be[1:0]; dq_oe <= 1; end
              if (seq == 4'd4) state <= S_DONE;
            end
          end
        end

        // ----------------------------- acknowledged, or waiting to be
        // A read's data waits here for the request (GLUE's refresh window
        // can delay it) or for the next start, which means the cycle
        // never ran.  The acknowledge is a level while the request is up.
        S_DONE: begin
          if (req_q) cpu_ack <= 1;
          else begin
            cpu_ack <= 0;
            if (cpu_ack) state <= S_IDLE;
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
        // One word: WRITE with the word, the second beat of the burst
        // masked.  Acknowledged as posted; the level clears with the
        // request.
        S_DL: begin
          seq <= seq + 1'b1;
          if (seq == 4'd2) begin
            cmd <= CMD_WRITE; sd_ba <= d_bank; sd_addr <= {2'b00, 1'b1, 1'b0, d_col};
            dq_out <= xs_dl_data; sd_dqm <= 2'b00; dq_oe <= 1; dl_ack <= 1;
          end
          if (seq == 4'd3) begin sd_dqm <= 2'b11; dq_oe <= 1; end
          if (seq == 4'd4) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end

endmodule
