// se30_swim.v - Apple's SWIM (343S0061-A) at UJ11, to the contract of
// SE30_PLAN.md 5.2 - rung 1: both register sets, no data path.
//
// WHAT IT IS
//   An IWM and an ISM in one package, one register set selected at a time
//   (the SWIM Chip Specification, 29 Sep 1987, "the combination logic").
//   The IWM set: eight state latches addressed by A3-A1 with A0 the new
//   value; L7, L6 and the delayed MotorOn choosing among read-all-ones,
//   read data, status, write-handshake, mode and write data; the MotorOn
//   timer (production drawing 6.7, User's Reference pp. 10-12).  The ISM
//   set: sixteen registers, A3 the direction - data, mark, CRC/IWM
//   configuration, parameter RAM, phases, setup, mode by write-zeros and
//   write-ones, error, status, handshake (production 6.5, User's Ref
//   pp. 20-26).  The switch between them and the three extra IWM bits
//   (chip spec).  Held to sim/swim/tb_se30_swim.v.
//
//   Rung 1 has no data path: no flux reaches the read shift registers, so
//   the IWM's read data latch stays 0 and the ISM's FIFO stays empty with
//   ACTION never set; the write side idles (/WRREQ high, the handshake
//   "empty, no underrun").  Rungs 2 and 3 (plan 5.2.4) add them.
//
// THE BUS (plan 5.4)
//   GLUE's device port.  THE CHIP HAS NO R/W PIN: the address decides.
//   In the IWM set an access with A0 = 1 writes when L6 and L7 are both
//   set (or being set), and otherwise does not drive the lanes; in the
//   ISM set A3 = 0 writes and A3 = 1 reads.  So a CPU write to a read
//   address is the chip's read, side effects included, and a CPU read of
//   a write address is the chip's write of whatever the lanes hold
//   (wdata here; undefined on the board).  Latches, writes and read side
//   effects land at the strobe; rdata is combinational throughout and,
//   in the IWM set, is the register the latches select AS THIS ACCESS
//   LEAVES THEM ("the new state will select the register", User's Ref
//   p. 10).
//
// THE PINS (plan 5.3)
//   ph_out/ph_oe: the four phase lines, the ISM's direction bits in force
//   in both register sets (the chip spec; the User's Ref disagrees, plan
//   5.2.3).  enbl1_n is the internal drive, enbl2_n the external.  sense
//   is RDDATA on this board.  hdsel goes to a test point only.
//
// RESET
//   /RESET: the IWM latches and mode 0 (so the MotorOn timer is enabled),
//   the ISM mode, setup and error 0, the phases $F0, the IWM set
//   selected, the three extra bits 0.  The parameter RAM has no
//   documented reset contents and is not cleared.

`timescale 1ns/1ps

module se30_swim (
  input         clk,
  input         c16_en,                // FCLK: C16M
  input         reset_n,

  input         sel,                   // /DEV
  input         strobe,
  input   [3:0] rs,                    // A12-A9
  input   [7:0] wdata,                 // D31-24
  output  [7:0] rdata,

  output  [3:0] ph_out,
  output  [3:0] ph_oe,
  input   [3:0] ph_in,                 // the pins, for lines the ISM makes inputs
  output        enbl1_n,
  output        enbl2_n,
  input         sense,
  output        wrdata,
  output        wrreq_n,
  output        hdsel,

  output [47:0] dbg                    // PSWM (plan 5.8)
);

  // 2^23 + 100 FCLK: how long /ENBLx outlives MotorOn with the timer on
  // (production 6.7.2); M16/M8 doubles it (chip spec)
  localparam [24:0] IWM_TIMER = 25'd8388708;

  reg        ism;                      // the ISM register set is selected
  reg  [3:0] ph_lvl;                   // PH3-0: the IWM's latches and the ISM's state bits are one set
  reg  [3:0] ph_dir;                   // the ISM's direction bits, 1 = output
  reg        motor, drvsel, l6, l7;    // the IWM's other four latches
  reg  [4:0] iwm_mode;                 // mode bits 4-0 (status echoes them)
  reg        iwm_test;                 // mode bit 5
  reg [24:0] timer;                    // the MotorOn timer, counting FCLK
  reg  [2:0] iwm_cfg;                  // {OVERRIDE, M16/M8, MODIFY}
  reg  [1:0] sw_cnt;                   // mode writes matched so far of 1, 0, 1, 1 (bit 6)
  wire [7:0] rd_latch = 8'h00;         // the read data register: no flux on rung 1 (rung 2's shift register)
  reg  [7:0] ism_mode;                 // bit 6 is not stored: it reads 1 while the ISM is selected
  reg  [7:0] ism_setup, ism_error;
  reg  [7:0] param [0:15];
  reg  [3:0] pidx;
  reg        corr_sel;                 // which correction byte a data read gives with ACTION low

  wire       hit = sel && strobe;

  // ------------------------------------------------ the IWM, next state
  wire [2:0] k = rs[3:1];
  wire       v = rs[0];
  wire [3:0] ph_n     = (k[2] == 1'b0) ? ((ph_lvl & ~(4'b1 << k[1:0])) | ({3'b0, v} << k[1:0])) : ph_lvl;
  wire       motor_n  = (k == 3'd4) ? v : motor;
  wire       drvsel_n = (k == 3'd5) ? v : drvsel;
  wire       l6_n     = (k == 3'd6) ? v : l6;
  wire       l7_n     = (k == 3'd7) ? v : l7;
  // the delayed MotorOn: MotorOn, or the timer still running.  MotorOn
  // falling with mode bit 2 clear starts the timer; with OVERRIDE, MotorOn
  // low and a drive-select toggle kill it (chip spec); MotorOn on clears it.
  wire       t_start  = motor && !motor_n && !iwm_mode[2];
  wire       t_kill   = iwm_cfg[2] && !motor_n && (drvsel_n != drvsel);
  wire       motor_d  = motor || (timer != 0);
  wire       motor_dn = motor_n || (!t_kill && (t_start || timer != 0));
  // a write: L6 and L7 set or being set, and A0 = 1 (production 6.7.1);
  // the delayed MotorOn picks the data register over the mode register -
  // which is also why the mode register, and so the switch to the ISM,
  // cannot be reached while MOTOREN is high
  wire       iwm_wr   = l6_n && l7_n && v;
  wire       mode_wr  = iwm_wr && !motor_dn;

  reg  [7:0] iwm_q;
  always @* begin
    case ({l7_n, l6_n})
      2'b00: iwm_q = motor_dn ? rd_latch : 8'hFF;                   // read data / read all ones
      2'b01: iwm_q = {sense, 1'b0, motor_dn, iwm_mode};             // status: bit 6 is MZ, reads 0
      2'b10: iwm_q = 8'hFF;                                         // write-handshake: empty, no underrun, bits 5-0 read 1
      2'b11: iwm_q = 8'hFF;                                         // a write state: no register is read
    endcase
  end

  // ------------------------------------------------------ the ISM reads
  wire [3:0] ph_rd  = (ph_dir & ph_lvl) | (~ph_dir & ph_in);
  wire       fifo_w = ism_mode[4];                                   // write mode: the empty FIFO has two places
  reg  [7:0] ism_q;
  always @* begin
    case (rs)
      4'd8:  ism_q = 8'h00;                                          // FIFO data, or the correction pair: no flux, no measurement
      4'd9:  ism_q = 8'h00;                                          // mark
      4'd10: ism_q = ism_error;
      4'd11: ism_q = param[pidx];
      4'd12: ism_q = {ph_dir, ph_rd};
      4'd13: ism_q = ism_setup;
      4'd14: ism_q = ism_mode | 8'h40;                               // status: the mode, bit 6 reading 1
      4'd15: ism_q = {fifo_w, fifo_w, |ism_error, ism_mode[7], sense, sense, 1'b0, 1'b0};
      default: ism_q = 8'hFF;                                        // a write address: the chip does not drive the lanes
    endcase
  end

  assign rdata = ism ? ism_q : iwm_q;

  // --------------------------------------------------------- the state
  integer i;
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      ism <= 0; ph_lvl <= 4'h0; ph_dir <= 4'hF;
      motor <= 0; drvsel <= 0; l6 <= 0; l7 <= 0;
      iwm_mode <= 0; iwm_test <= 0; timer <= 0; iwm_cfg <= 0; sw_cnt <= 0;
      ism_mode <= 0; ism_setup <= 0; ism_error <= 0; pidx <= 0; corr_sel <= 0;
    end else begin
      if (c16_en && timer != 0) timer <= timer - 1'b1;

      if (hit && !ism) begin
        ph_lvl <= ph_n; motor <= motor_n; drvsel <= drvsel_n; l6 <= l6_n; l7 <= l7_n;
        if (motor_n || t_kill) timer <= 0;
        else if (t_start)      timer <= iwm_cfg[1] ? {IWM_TIMER[23:0], 1'b0} : IWM_TIMER;
        if (mode_wr) begin
          iwm_mode <= wdata[4:0]; iwm_test <= wdata[5];
          // the switch: four successive mode writes with bit 6 = 1, 0, 1, 1
          if (wdata[6] == (sw_cnt != 2'd1)) begin
            if (sw_cnt == 2'd3) begin ism <= 1; sw_cnt <= 0; end
            else sw_cnt <= sw_cnt + 1'b1;
          end else
            sw_cnt <= {1'b0, wdata[6]};
        end
      end

      if (hit && ism) begin
        if (!rs[3]) case (rs[2:0])
          3'd2: if (!ism_mode[3]) iwm_cfg <= wdata[7:5];             // with ACTION: the CRC (rung 3)
          3'd3: begin param[pidx] <= wdata; pidx <= pidx + 1'b1; end
          3'd4: begin ph_dir <= wdata[7:4]; ph_lvl <= wdata[3:0]; end
          3'd5: ism_setup <= wdata;
          3'd6: begin
            ism_mode <= ism_mode & ~wdata & 8'hBF;
            pidx <= 0;
            // back to the IWM: bit 6, with MotorOn (MOTOREN) low as the
            // write leaves it - the ROM's $F8 clears both at once
            if (wdata[6] && !(ism_mode[7] && !wdata[7])) ism <= 0;
          end
          3'd7: ism_mode <= (ism_mode | wdata) & 8'hBF;
          default: ;                                                 // data, mark: the FIFO (rungs 2-3)
        endcase
        else case (rs[2:0])
          3'd0: if (!ism_mode[3]) corr_sel <= !corr_sel;
          3'd2: ism_error <= 0;
          3'd3: pidx <= pidx + 1'b1;
          default: ;
        endcase
      end
    end
  end

  // ---------------------------------------------------------- the pins
  assign ph_out  = ph_lvl;
  assign ph_oe   = ph_dir;
  assign enbl1_n = ism ? !(ism_mode[7] && ism_mode[1]) : !(motor_d && !drvsel);
  assign enbl2_n = ism ? !(ism_mode[7] && ism_mode[2]) : !(motor_d &&  drvsel);
  assign wrdata  = 1'b0;
  assign wrreq_n = 1'b1;
  assign hdsel   = ism_setup[0] && ism_mode[5];

  assign dbg = {ism, l7, l6, drvsel, motor, ph_lvl, iwm_mode, motor_d, enbl1_n, enbl2_n, sense,
                iwm_test, sw_cnt, ism_mode | (ism ? 8'h40 : 8'h00), ism_setup, ph_dir, iwm_cfg, 4'b0};

endmodule
