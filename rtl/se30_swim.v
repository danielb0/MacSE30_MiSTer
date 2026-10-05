// se30_swim.v - Apple's SWIM (343S0061-A) at UJ11, to the contract of
// SE30_PLAN.md 5.2, 5.12 and 5.15 - both register sets, the IWM's read
// path (rung 2, GCR) and its write path (rung 3).  The ISM's data path
// (5.13) is to come.
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
//   The ISM's FIFO stays empty with ACTION never set.
//
// THE IWM WRITE PATH (plan 5.15.2; the SWIM drawing sheet 52, the IWM
// Spec Rev 19 pp. 2-3 and 7, the 1984 undocumented-features note)
//   "The combination of L7 and Motor-On and /underrun enables /WRREQ
//   low."  The write state begins when L7 is set with MotorOn (the ROM
//   sets it from the sense state with the first byte); "the write shift
//   register is loaded every 8 bit cell times starting seven CLK periods
//   after the write state begins", the cell being 32 FCLK in 8M slow, 28
//   in 7M slow, 16 in 8M fast.  At a load the buffer's byte moves to the
//   shift register and the handshake's bit 7 (buffer empty) rises; a
//   processor write fills the buffer and clears it, the last write before
//   a load being the one used - except within 9 FCLK of a load, when
//   writes are ignored.  A load with nothing written is an underrun:
//   /underrun (bit 6) falls and /WRREQ goes high until L7 is cleared.
//   "A one is written as a transition on the WRDATA output at a bit cell
//   boundary", MSB first.  Synchronous-mode writing is timed from Q3,
//   which is AS* on this board (plan 5.3), and is not built: a write
//   behaves as in asynchronous mode whatever mode bit 1 holds.
//
// THE IWM READ PATH (plan 5.12.2)
//   In the read state (L6 = L7 = 0) RDDATA - SENSE on this board - is
//   sampled on CLK, which is FCLK in fast mode and FCLK/2 in slow.  "A
//   falling transition within a bit cell window is considered to be a
//   one, and no falling transition within a bit cell window is considered
//   to be a zero"; "each falling transition resets the read data windows".
//   The windows are the IWM Spec's (Rev 19, p. 10), in CLK periods since
//   the last transition: 8M 8-23 a 1, 24-39 a 01, 40-55 a 001 (a 16-CLK
//   window); 7M 7-20, 21-34, 35-48 (14).  Here that is a zero shifted at
//   each window boundary (24, 40, 56, ... in 8M) and a one at each
//   transition; past the table's last band the boundaries go on every
//   window, the one-shot's continuation (the table stops where GCR does).
//   The SWIM drawing's B revision ignores a falling transition within
//   6 CLK of the last in 8M (5 in 7M) - "6 FCLK periods" in fast mode, "twice
//   as long" in slow; an accepted one below the table's first band (6-7)
//   is a one.  Bits enter the shift register at the LSB; "a full data
//   nibble is considered to be shifted in when a one shifted into the MSB",
//   and it is then latched into the read data register and the shift
//   register cleared.
//
//   Asynchronous mode (mode bit 1, the ROM's): the data register holds the
//   byte and "will be cleared 14 FCLK periods (about 2 us) after a valid
//   data read takes place (a valid data read being defined as both /DEV
//   being low and D7 (the msb) outputting a one from the data register for
//   at least one FCLK period)"; a new byte arriving first supersedes the
//   pending clear.  Synchronous mode: "the shift register is readable in
//   any intermediate state", except that after a one reaches the MSB it
//   "will appear ... to be stalled for a period of two bit times plus four
//   CLK periods".
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

  output [47:0] dbg,                   // PSWM (plan 5.8)
  output        dbg_vread              // a valid data read: a byte the processor took (PFLP counts them)
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
  reg  [7:0] rd_latch;                 // the read data register
  reg  [7:0] sr;                       // the read shift register
  reg  [7:0] ism_mode;                 // bit 6 is not stored: it reads 1 while the ISM is selected
  reg  [7:0] ism_setup, ism_error;
  reg  [7:0] param [0:15];
  reg  [3:0] pidx;
  reg        corr_sel;                 // which correction byte a data read gives with ACTION low

  // the IWM write path (rung 3, below)
  reg  [7:0] wbuf;                     // the buffer register
  reg        wempty;                   // handshake bit 7: the buffer is empty
  reg        unr_n;                    // handshake bit 6: /underrun
  reg  [7:0] wsr;                      // the shift register, MSB out first
  reg  [7:0] wsr_last;                 // the byte the last load took (the bench's view)
  reg  [2:0] wbits;                    // bits still to go before the next load
  reg  [4:0] wcnt;                     // CLK periods to the next cell boundary
  reg  [3:0] wlock;                    // FCLK the buffer is locked after a load
  reg        wload;                    // one clock: a load
  reg        wrd;                      // WRDATA

  // GLUE's strobe is one C16M - two clk in the machine, where clk is
  // clk_sys - so the access is taken on the C16M edge alone, as the VIA
  // takes it.  Without c16_en every access acted twice: the ISM switch's
  // count never reached four and the ROM's probe found no SWIM
  // (sim/gcrread part 1).
  wire       hit = c16_en && sel && strobe;

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

  wire [7:0] rd_val;                   // the data register as read (the read path, below)
  reg  [7:0] iwm_q;
  always @* begin
    case ({l7_n, l6_n})
      2'b00: iwm_q = motor_dn ? rd_val : 8'hFF;                     // read data / read all ones
      2'b01: iwm_q = {sense, 1'b0, motor_dn, iwm_mode};             // status: bit 6 is MZ, reads 0
      2'b10: iwm_q = {wempty, unr_n, 6'h3F};                        // write-handshake: bits 5-0 read 1
      2'b11: iwm_q = 8'hFF;                                         // a write state: no register is read
    endcase
  end

  // ------------------------------------------------ the IWM read path
  wire       fast    = iwm_mode[3];
  wire       m8      = iwm_mode[4];
  wire       async_m = iwm_mode[1];
  reg        cdiv;                                          // FCLK/2's phase
  wire       clk_en  = c16_en && (fast || cdiv);            // one CLK period
  wire [6:0] blank   = m8 ? 7'd6  : 7'd5;
  wire [6:0] first0  = m8 ? 7'd24 : 7'd21;
  wire [6:0] win     = m8 ? 7'd16 : 7'd14;
  wire       rstate  = !ism && !l6 && !l7;                  // the read state
  reg        rd_s;                                          // RDDATA at the last CLK
  reg  [6:0] ncl;                                           // CLK periods since the last transition, saturating
  reg  [6:0] nb;                                            // CLK periods to the next window boundary
  wire       fall    = rd_s && !sense;
  wire       take    = rstate && clk_en && fall && ncl >= blank;
  wire       bound   = rstate && clk_en && nb == 7'd1;
  // the bits this CLK shifts in: a zero at a boundary, then a one at a
  // transition - both when a transition lands on a boundary (Nclks 24: 01)
  wire [8:0] sh0     = {sr, 1'b0};                          // after a zero
  wire       lat0    = bound && sh0[7];                     // the zero completes a byte
  wire [7:0] sr0     = !bound ? sr : (lat0 ? 8'h00 : sh0[7:0]);
  wire [7:0] sh1     = {sr0[6:0], 1'b1};
  wire       lat1    = take && sh1[7];
  wire [7:0] sr_n    = !take ? sr0 : (lat1 ? 8'h00 : sh1);
  reg  [3:0] clr_cnt;                                       // FCLK to the clear after a valid read, 0 = none
  reg  [6:0] stall;                                         // synchronous mode's stall, in CLK
  reg  [7:0] stall_v;
  assign     rd_val  = async_m ? rd_latch : (stall != 0 ? stall_v : sr);
  wire       rd_sel  = !ism && !l7_n && !l6_n && motor_dn;  // the data register as this access leaves the latches
  wire       vread   = hit && rd_sel && async_m && rd_latch[7];

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      cdiv <= 0; rd_s <= 1; ncl <= 7'h7F; nb <= 0; sr <= 0; rd_latch <= 0;
      clr_cnt <= 0; stall <= 0; stall_v <= 0;
    end else begin
      if (c16_en) cdiv <= !cdiv;
      if (clk_en) begin
        rd_s <= sense;
        if (take) begin ncl <= 0; nb <= first0; end
        else begin
          if (ncl != 7'h7F) ncl <= ncl + 1'b1;
          if (rstate) nb <= (nb <= 7'd1) ? win : nb - 1'b1;
        end
        if (stall != 0) stall <= stall - 1'b1;
      end
      sr <= sr_n;
      if (lat0 || lat1) begin
        rd_latch <= lat1 ? sh1 : sh0[7:0];
        stall_v  <= lat1 ? sh1 : sh0[7:0];
        stall    <= {win[5:0], 1'b0} + 7'd4;                // two bit times plus four CLK
        clr_cnt  <= 0;                                      // a new byte: no clear pending for it
      end else begin
        if (vread) clr_cnt <= 4'd14;
        else if (c16_en && clr_cnt != 0) begin
          clr_cnt <= clr_cnt - 1'b1;
          if (clr_cnt == 4'd1) rd_latch <= 8'h00;
        end
      end
    end
  end

  // ------------------------------------------------ the IWM write path
  // The write state is L7 set with the delayed MotorOn (the ROM enters it
  // from the sense state, L6 set, by setting L7 with the first byte - an
  // access that is also a data-register write).  The first load comes 7
  // CLK after it begins, then one every 8 cells; a cell is 16 CLK at 8M
  // (32 FCLK slow, 16 fast) and 14 at 7M (28, 14).  A load moves the
  // buffer to the shift register and empties the buffer; with nothing
  // written since the last load it is an underrun, and the shift register
  // takes zeros.  Each cell boundary sends the shift register's MSB: a
  // one toggles WRDATA.  For 9 FCLK after a load the buffer ignores
  // writes.  Clearing L7 ends the state, resets /underrun and empties
  // the buffer.
  wire [4:0] wcell = m8 ? 5'd16 : 5'd14;
  wire       wdreg = hit && !ism && iwm_wr && motor_dn;     // a data-register write
  wire       wact  = !ism && l7 && motor_d;                // the write state
  wire       wload_now = wact && clk_en && wcnt == 5'd1 && wbits == 0;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wbuf <= 0; wempty <= 1; unr_n <= 1; wsr <= 0; wsr_last <= 0;
      wbits <= 0; wcnt <= 0; wlock <= 0; wload <= 0; wrd <= 0;
    end else begin
      wload <= 0;
      if (c16_en && wlock != 0) wlock <= wlock - 1'b1;
      // OUR READING: clearing L7 "will reset the /underrun flag" (sheet
      // 52); it empties the buffer too, so the handshake idles at $FF and
      // a write state left before its first load leaves nothing behind
      if (!l7) begin unr_n <= 1; if (!wdreg) wempty <= 1; end

      // a write in the load's own clock is inside the lock
      if (wdreg && wlock == 0 && !wload_now) begin wbuf <= wdata; wempty <= 0; end

      if (!wact) begin
        wcnt <= 5'd7; wbits <= 0;                           // the first load, 7 CLK in
      end else if (clk_en) begin
        if (wcnt != 5'd1) wcnt <= wcnt - 1'b1;
        else begin                                          // a cell boundary
          wcnt <= wcell;
          if (wbits == 0) begin                             // a load, and its byte's MSB
            wload <= 1; wlock <= 4'd9; wempty <= 1; wbits <= 3'd7;
            if (wempty) begin unr_n <= 0; wsr <= 8'h00; wsr_last <= 8'h00; end
            else begin
              wsr <= {wbuf[6:0], 1'b0}; wsr_last <= wbuf;
              if (wbuf[7]) wrd <= !wrd;
            end
          end else begin
            wbits <= wbits - 1'b1;
            wsr <= {wsr[6:0], 1'b0};
            if (wsr[7]) wrd <= !wrd;
          end
        end
      end
    end
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
  assign wrdata  = wrd;
  assign wrreq_n = !(wact && unr_n);
  assign hdsel   = ism_setup[0] && ism_mode[5];

  assign dbg_vread = vread;
  assign dbg = {ism, l7, l6, drvsel, motor, ph_lvl, iwm_mode, motor_d, enbl1_n, enbl2_n, sense,
                iwm_test, sw_cnt, ism_mode | (ism ? 8'h40 : 8'h00), ism_setup, ph_dir, iwm_cfg, 4'b0};

endmodule
