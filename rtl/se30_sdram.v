// se30_sdram.v - the SDRAM controller behind GLUE's RAM and ROM ports
// (SE30_PLAN.md 3.2, 3.3).
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
//   ALL, eight AUTO REFRESH, LOAD MODE.  The geometry is the subset every
//   MiSTer module presents: 4 banks x 8192 rows x 512 columns x 16 = 32 MB.
//
// THE READ TIMELINE (clocks after the C16M edge that begins S0; the chip
// clocks on the falling edges, SDRAM_CLK being the inverted clk)
//    1  cpu_start, the address and R/W registered
//    2  ACTIVE                              chip 2.5
//    4  READ with auto-precharge            chip 4.5   (tRCD 21.28 >= 21)
//    6.5, 7.5  the chip launches the two words (CL2)
//    7.5, 8.5  captured in the I/O cell on the falling edge (dq_q): 6.0 ns
//              of tAC to 2.5 ns of tOH after the next edge is a 7.1 ns eye
//    8.5, 9.5  re-timed once in the fabric (dq_r), a full period from the
//              I/O cell, as MacLC's 2026-09-12 capture work found necessary
//    9, 10     taken into cpu_rdata on the rising edge, half a period from
//              dq_r; cpu_ack with the second word at 10
//   12  GLUE samples: two clocks in hand.
//   A write: WRITE at 5 (cpu_req was registered at 4, AS* having asserted
//   at S1) with the high word and its DQM from be[3:2], the low word at 6;
//   acknowledged as posted.  Any ACTIVE is followed by eight clocks before
//   the next ACTIVE or refresh (tRC 63; a write's tWR + tRP land at 9.8).
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
//   ready   the power-up ladder has run.

`timescale 1ns/1ps

module se30_sdram (
  input             clk,               // 94.0032 MHz, 3 x clk_sys
  input             reset_n,
  output            ready,

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

  reg  [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_cke = 1'b1;

  // ------------------------------------------- the clock to the chip
  // The inverted clk: the chip's rising edge is our falling edge, half a
  // period after our registered outputs change (tIS 1.5 ns) and the edge
  // on which we capture its data (MacLC's arrangement, its sdc numbers).
`ifdef SIMULATION
  assign sd_clk = ~clk;
`else
  altddio_out #(
    .extend_oe_disable("OFF"), .intended_device_family("Cyclone V"), .invert_output("OFF"),
    .lpm_hint("UNUSED"), .lpm_type("altddio_out"), .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"), .width(1)
  ) sdclk_ddr (
    .datain_h(1'b0), .datain_l(1'b1), .outclock(clk), .dataout(sd_clk),
    .aclr(1'b0), .aset(1'b0), .oe(1'b1), .outclocken(1'b1), .sclr(1'b0), .sset(1'b0)
  );
`endif

  // ------------------------------------------------------ data pins
  reg [15:0] dq_out;
  reg        dq_oe;
  assign sd_dq = dq_oe ? dq_out : 16'hzzzz;
  reg [15:0] dq_q, dq_r;               // the I/O-cell capture and its re-timing, both falling edge
  always @(negedge clk) dq_q <= sd_dq;
  always @(negedge clk) dq_r <= dq_q;

  // -------------------------------------------- the inputs, registered
  reg        start_q, start_qq, req_q, we_q, dl_req_q;
  reg [22:0] addr_q;
  reg  [3:0] be_q;
  reg [31:0] wdata_q;
  reg [23:0] dl_addr_q;
  reg [15:0] dl_data_q;
  wire       start_rise = start_q && !start_qq;       // cpu_start is a clk_sys clock wide, three of ours
  always @(posedge clk) begin
    start_q <= cpu_start; start_qq <= start_q; req_q <= cpu_req; we_q <= cpu_we;
    addr_q <= cpu_addr; be_q <= cpu_be; wdata_q <= cpu_wdata;
    dl_req_q <= dl_req; dl_addr_q <= dl_addr; dl_data_q <= dl_data;
  end

  // the word address of the access: bank, row, column
  wire [23:0] a_word  = {addr_q, 1'b0};
  wire  [1:0] a_bank  = a_word[23:22];
  wire [12:0] a_row   = a_word[21:9];
  wire  [8:0] a_col   = a_word[8:0];
  wire  [1:0] d_bank  = dl_addr_q[23:22];
  wire [12:0] d_row   = dl_addr_q[21:9];
  wire  [8:0] d_col   = dl_addr_q[8:0];

  // --------------------------------------------------- the sequencer
  localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_ACC = 3'd2, S_DONE = 3'd3, S_DL = 3'd4;
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
  reg        have_data;                // S_DONE: a read's data is complete
  reg [14:0] init_cnt;
  reg  [3:0] init_step;                // 0 pause, 1 precharge, 2-9 refreshes, 10 mode, 11 settle
  assign ready = (state != S_INIT);
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
      have_data <= 0;
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
        // eight clocks apart (tRFC 63 ns), LOAD MODE, tMRD.
        S_INIT: begin
          sd_dqm <= 2'b11;
          init_cnt <= init_cnt + 1'b1;
          case (init_step)
            4'd0:  if (init_cnt == INIT_PAUSE) begin init_step <= 1; init_cnt <= 0; end
            4'd1:  begin cmd <= CMD_PRECHARGE; sd_addr[10] <= 1'b1; init_step <= 2; init_cnt <= 0; end
            4'd10: if (init_cnt == 15'd8) begin cmd <= CMD_LOAD_MODE; sd_addr <= MODE; sd_ba <= 0; init_step <= 11; init_cnt <= 0; end
            4'd11: if (init_cnt == 15'd2) begin state <= S_IDLE; ref_cnt <= 0; busy <= 0; end
            default: if (init_cnt == 15'd8) begin cmd <= CMD_REFRESH; init_step <= init_step + 1'b1; init_cnt <= 0; end
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
              a_be <= be_q; a_wdata <= wdata_q;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0; have_data <= 0;
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
            // a read: speculative, auto-precharged; the two words arrive
            // in dq_r for the rising edges at 7 and 8 clocks after ACTIVE
            if (seq == 4'd2) begin cmd <= CMD_READ; sd_ba <= a_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, a_col_r}; end
            if (seq == 4'd7) cpu_rdata[31:16] <= dq_r;
            if (seq == 4'd8) begin
              cpu_rdata[15:0] <= dq_r; have_data <= 1; cpu_ack <= req_q;
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
            if (cpu_ack) begin have_data <= 0; state <= S_IDLE; end
            else if (go) begin
              // the next cycle's start, with this one never requested: the
              // data is discarded and the row for the new one opens now
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= be_q; a_wdata <= wdata_q;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0; have_data <= 0;
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
            dq_out <= dl_data_q; sd_dqm <= 2'b00; dq_oe <= 1; dl_ack <= 1;
          end
          if (seq == 4'd3) begin sd_dqm <= 2'b11; dq_oe <= 1; end
          if (seq == 4'd4) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end

endmodule
