// se30_swim.v - Apple's SWIM (343S0061-A) at UJ11, to the contract of
// SE30_PLAN.md 5.2, 5.12, 5.13, 5.15 and 5.16 - both register sets, the
// IWM's read path (rung 2, GCR) and its write path (rung 3), the ISM's MFM
// read path (5.13) and its write path (5.16).
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
// THE ISM READ PATH (plan 5.13.3, 5.13.9 item 4; the ISM ASIC spec
// 4.1-4.5, the User's Reference pp. 12-18 and 20-24)
//   Built to what the ROM drives (5.15's decision): Setup $20, the
//   correction machine off, FCLK whole.  RDDATA is SENSE on this board;
//   with Setup bit 5 (the IBM drive option, the ROM's) a transition is a
//   pulse's trailing edge, else every edge.
//   The cell: the SCT counter's boundaries from the parameter RAM, in
//   half-clocks from the last transition, each value plus the chip's
//   internal delay the User's Reference subtracts (p. 14: MIN 3 clocks,
//   the rest 2): B1 = MIN + 6, B2 = B1 + xSx + 4, B3 = B2 + xLx + 4,
//   B4 = B3 + RPT + 4.  A transition before B1 is too narrow (error bit
//   4), before B2 a 2-unit cell, before B3 a 3, before B4 a 4; none by
//   B4 is too wide (bit 5).  The previous cell picks the row: after a
//   2-unit cell SSx/SLx, after a longer one LSx/LLx.  The names' third
//   letter (the next cell) and CSLS are stored, not used: the ROM's
//   table gives each pair one value ($2E $2E, $18 $18, $2F $2F, $19
//   $19), and with it every boundary is 12 half-clocks or more from any
//   interval the drive's 1-us cells make.  RDDATA here is synchronous to
//   FCLK, so the Half Read's bias (4.1) has nothing to correct: the
//   counter counts FCLK, two half-clocks each.
//   The Correction State Machine (4.2): after a transition it counts
//   minimum cells; 32 pairs (64) of them, and the first non-minimum cell
//   starts a byte - after a run of zeros it is the 1 that begins a mark;
//   a mark - a 4-unit cell after a data 0, the dropped clock (4.5, "a 4
//   unit cell which begins with a zero") - within that byte locks it;
//   anything else sends it back to counting.  So the bytes are framed
//   from the mark's first bit: A1, the mark the ROM writes and reads (a
//   C2 index mark would frame the same way, from its first 1).
//   The inverse trans-space machine (4.5): from a data bit's transition,
//   2, 3, 4 units are 1, 00, 01; from a clock's (a 0), 0, 1, and the
//   mark's 00.  Bits enter the shift register MSB first; a whole byte goes
//   to the FIFO with its mark flag (the byte held a mark cell) and
//   whether the CRC is zero after it.  The CRC (CCITT-16, User's Ref p.
//   9) starts at all ones with the byte's first bit, so it covers the
//   three A1s and the field.  Locked, the machine stays locked until
//   ACTION is cleared (4.2); a cell error there is flagged and adds no
//   bits.
//   The FIFO: two bytes.  A byte arriving with both full is an overrun
//   (error bit 0) and is lost.  The Data register (with ACTION) and the
//   Mark register read the head: a mark through the Data register is
//   error bit 1, a read of an empty FIFO bit 2.  Handshake (read mode):
//   bit 7 a byte, bit 6 two, bit 5 an error, bit 1 the CRC not zero
//   after the head byte (the running CRC when empty), bit 0 the head a
//   mark.  The first error bit set holds the register until it is read.
//   Mode bit 0 (Clear FIFO) empties the FIFO while it is set; ACTION's
//   fall stops the machine.  The correction counters (4.3) and
//   post-compensation (4.4) are not built: the Correction register reads
//   0 (Setup bit 4, the ROM's 0, leaves them without effect).
//
// THE ISM WRITE PATH (plan 5.16.3; the SWIM drawing 6.2, the ISM ASIC
// spec 3.1-3.6 and 5.1, the User's Reference pp. 12-13 and 19-24)
//   The FIFO is the read path's: in write mode the Data register pushes a
//   byte, the Mark register a byte with its mark bit, the CRC register
//   (with ACTION) an entry that sends the CRC; a push into a full FIFO is
//   an overrun (error bit 2) and is lost.  Handshake bits 7 and 6 are a
//   place free and two.  "An IN occurs at the instant that Action is set
//   when writing": the head entry goes to the shift register at once.  The
//   shift register sends MSB first; with its last bit gone the next IN
//   takes the FIFO's head, and an IN with the FIFO empty is an underrun
//   (error bit 0).  "The Action bit will be cleared any time there is any
//   Error while writing"; the handshake then shows the FIFO empty, so the
//   ROM's byte loop, which has no timeout, runs on to its error check
//   (engineering, from the ROM and SWIM III's register document).  /WRREQ
//   is low while write mode and ACTION are set.
//   The CRC takes every data and mark bit as it leaves the shift register,
//   preset to ones at the IN of a mark byte that follows a non-mark byte
//   (our reading of "cleared to ones just prior to writing the Mark byte":
//   it then covers the three A1s, as the read path's and the encoder's do);
//   a CRC entry shifts its 16 bits instead, which it does not take.
//   The trans-space machine (Table 13): the current bit c and the next n
//   give 1 for (0,0), 01 for (0,1), 0 for (1,0), 1 for (1,1); in a mark
//   byte at the pattern 1 0 0 0 (two back, one back, c, n), 00 - the
//   dropped clock.  A trans-space 1 presets the counter to TIME1, a 0 to
//   TIME0, each in half-clocks plus the chip's two-clock delay the User's
//   Reference takes off (the ROM's: 31.5 and 15.5 FCLK), and WRDATA
//   toggles at a 1's terminal count - intervals of 31.5, 47 and 62.5 FCLK.
//   The half clock (3.6) is a remainder carried into the next count: the
//   toggle lands on the FCLK, nothing accumulates.  With the IBM drive
//   option (Setup bit 5, the ROM's) WRDATA idles high and each toggle is a
//   4-FCLK low pulse instead (5.1).  Not built: pre-compensation (EARLY/
//   NORMAL/LATE move a transition 2 clocks, which never changes the cell
//   count the drive records - plan 5.16.3 item 8), trans-space bypass and
//   GCR through the ISM (Setup bits 6 and 2, which the ROM never sets).
//   An ACTION whose first entry is a CRC entry sends it as a data byte.
//   MFM_WRITE = 0 leaves the whole path out (plan 10.4.2): write mode then
//   accepts nothing and never lowers /WRREQ.
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

module se30_swim #(
  parameter     MFM_WRITE = 1          // the ISM's write path (plan 5.16)
) (
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
  // the read path's FIFO, two entries, head in 0, and its CRC (below)
  reg   [7:0] f_b0, f_b1;
  reg         f_m0, f_m1, f_c0, f_c1;
  reg   [1:0] f_n;
  reg  [15:0] rcrc;                                           // the read CRC
  wire [3:0] ph_rd  = (ph_dir & ph_lvl) | (~ph_dir & ph_in);
  wire       fifo_w = ism_mode[4];                                   // write mode: the empty FIFO has two places
  reg  [7:0] ism_q;
  always @* begin
    case (rs)
      4'd8:  ism_q = ism_mode[3] ? f_b0 : 8'h00;                    // FIFO data with ACTION, else the correction pair (none)
      4'd9:  ism_q = f_b0;                                           // mark: the head, no mark error
      4'd10: ism_q = ism_error;
      4'd11: ism_q = param[pidx];
      4'd12: ism_q = {ph_dir, ph_rd};
      4'd13: ism_q = ism_setup;
      4'd14: ism_q = ism_mode | 8'h40;                               // status: the mode, bit 6 reading 1
      4'd15: ism_q = fifo_w ? {f_n != 2'd2 || |ism_error, f_n == 2'd0 || |ism_error, |ism_error,
                               ism_mode[7], sense, sense, 2'b00}         // places free; an error shows it empty
                            : {f_n != 0, f_n == 2'd2, |ism_error, ism_mode[7], sense, sense,
                               (f_n != 0) ? !f_c0 : (rcrc != 16'h0000), (f_n != 0) && f_m0};
      default: ism_q = 8'hFF;                                        // a write address: the chip does not drive the lanes
    endcase
  end

  assign rdata = ism ? ism_q : iwm_q;

  // ------------------------------------------------- the ISM read path
  wire        ism_rd   = ism && !ism_mode[4];                 // read mode
  wire        ism_act  = ism_rd && ism_mode[3];               // ... and ACTION
  reg         rdd_s;                                          // RDDATA at the last FCLK
  wire        ism_tr     = c16_en && (ism_setup[5] ? (sense && !rdd_s) : (sense != rdd_s));
  reg  [11:0] tc;                                             // half-clocks since the last transition
  reg         have_t;                                         // a transition since ACTION
  reg         prev_l;                                         // the last cell was 3 or 4 units
  reg         wide_done;                                      // too wide already flagged
  wire [11:0] ivl = tc + 12'd2;                                // this FCLK's transition's interval
  wire [11:0] bnd1 = {4'd0, param[0]} + 12'd6;
  wire [11:0] bnd2 = bnd1 + {4'd0, prev_l ? param[8]  : param[2]} + 12'd4;
  wire [11:0] bnd3 = bnd2 + {4'd0, prev_l ? param[10] : param[4]} + 12'd4;
  wire [11:0] bnd4 = bnd3 + {4'd0, param[6]} + 12'd4;
  // the cell: 0 too narrow, 2, 3, 4 units (or too wide, before it ends)
  wire  [2:0] ccls = (ivl < bnd1) ? 3'd0 : (ivl < bnd2) ? 3'd2 : (ivl < bnd3) ? 3'd3 : 3'd4;
  wire        cell_ok  = ism_act && have_t && ism_tr && !wide_done && ivl < bnd4;
  wire        wide_now = ism_act && have_t && !wide_done && c16_en && ivl >= bnd4;

  // the CSM
  localparam [2:0] C_IDLE = 3'd0, C_SYNC = 3'd1, C_WAIT = 3'd2, C_MARK = 3'd3, C_LOCK = 3'd4;
  reg   [2:0] csm;
  reg   [5:0] nmin;                                           // minimum cells counted, less one
  reg         ref_d;                                          // the last transition a data bit's (a 1)
  reg   [7:0] asr;                                            // the shift register
  reg   [3:0] acnt;                                           // its bits
  reg         amark;                                          // the byte holds a mark

  // the cell's bits (inverse trans-space): 1 or 2, MSB first in dbits[1]
  wire        is_mark = (ccls == 3'd4) && !ref_d;
  wire  [1:0] dbits   = (ccls == 3'd2) ? {ref_d, 1'b0} :
                        (ccls == 3'd3) ? (ref_d ? 2'b00 : {1'b1, 1'b0}) :
                                         (ref_d ? 2'b01 : 2'b00);
  wire        dtwo    = (ccls == 3'd2) ? 1'b0 : (ccls == 3'd3) ? ref_d : 1'b1;
  wire        ref_n   = (ccls == 3'd2) ? ref_d : (ccls == 3'd3) ? !ref_d : ref_d;

  // the FIFO (declared with the ISM's registers, above)
  wire        rd_data  = hit && ism && rs == 4'd8 && ism_mode[3] && !ism_mode[4];
  wire        rd_mark  = hit && ism && rs == 4'd9 && !ism_mode[4];
  wire        f_pop    = (rd_data || rd_mark) && f_n != 0;

  function [15:0] crc1(input [15:0] c, input d);
    crc1 = {c[14:0], 1'b0} ^ ((c[15] ^ d) ? 16'h1021 : 16'h0000);
  endfunction

  // one cell's bits into the shift register: the byte completed (if any)
  reg   [7:0] n_asr, done_b;
  reg   [3:0] n_acnt;
  reg  [15:0] n_crc;
  reg         n_amark, done, done_m, done_c;
  integer     bi;
  always @* begin
    n_asr = asr; n_acnt = acnt; n_crc = rcrc; n_amark = amark || is_mark;
    done = 1'b0; done_b = 8'h00; done_m = 1'b0; done_c = 1'b0;
    for (bi = 1; bi >= 0; bi = bi - 1)
      if (bi == 1 || dtwo) begin
        n_asr = {n_asr[6:0], dbits[bi]};
        n_crc = crc1(n_crc, dbits[bi]);
        n_acnt = n_acnt + 1'b1;
        if (n_acnt == 4'd8) begin
          done = 1'b1; done_b = n_asr; done_m = n_amark; done_c = (n_crc == 16'h0000);
          n_acnt = 4'd0; n_amark = 1'b0;
        end
      end
  end

  // a byte to the FIFO: locked, or the mark cell that locks completing it
  wire        f_push  = cell_ok && ccls != 3'd0 && done && !ism_mode[0] &&
                        (csm == C_LOCK || (csm == C_MARK && is_mark));

  // ------------------------------------------------ the ISM write path
  // (plan 5.16.3).  An OUT: a processor write to Data, Mark, or CRC with
  // ACTION, in write mode.  An IN: ACTION set in write mode, or a bit
  // wanted with the shift register empty.
  wire        iw_on   = MFM_WRITE && ism && ism_mode[4] && ism_mode[3];
  wire        w_push  = MFM_WRITE && hit && ism && ism_mode[4] && !rs[3] && !ism_mode[0] &&
                        (rs[2:0] == 3'd0 || rs[2:0] == 3'd1 || (rs[2:0] == 3'd2 && ism_mode[3]));
  wire        w_mk    = (rs[2:0] == 3'd1);
  wire        w_crc   = (rs[2:0] == 3'd2);
  wire        iw_go   = MFM_WRITE && hit && ism && !rs[3] && rs[2:0] == 3'd7 && wdata[3] &&
                        !ism_mode[3] && (ism_mode[4] || wdata[4]);   // ACTION set in write mode
  reg  [15:0] wsr16;                                          // the shift register (a CRC entry's 16 bits)
  reg   [4:0] wn;                                             // its bits left
  reg         wisc, wmk, wpmk;                                // it holds the CRC; a mark byte; the last IN a mark
  reg  [15:0] wcrc;
  reg         wh2, wh1, wcur, wnxt, wmk_c, wmk_n;             // the trans-space machine's four bits, two marks
  reg         wtok, wtok2, wtok2v;                            // the token counting; a second owed, its value
  reg   [9:0] tcnt;                                           // half-clocks left of the token (signed)
  reg         wrd_m;                                          // WRDATA as a level
  reg   [2:0] wpul;                                           // FCLK left of the IBM pulse
  wire  [9:0] tcnt_n  = tcnt - 10'd2;
  wire        tk_end  = iw_on && c16_en && $signed(tcnt_n) <= 0;
  wire        need_b  = tk_end && !wtok2;                     // the next bit into the machine
  wire        w_need  = (need_b && wn == 0) || iw_go;
  wire        w_in    = w_need && f_n != 0;
  wire        w_unr   = w_need && f_n == 0;
  // the bit wanted: from the shift register, or the FIFO's head at an IN
  wire        in_crc  = f_c0 && !iw_go;
  wire        wb      = (wn != 0) ? wsr16[15] : (in_crc ? wcrc[15] : f_b0[7]);
  wire        wb_mk   = (wn != 0) ? wmk : (!in_crc && f_m0);
  wire        wb_isc  = (wn != 0) ? wisc : in_crc;
  wire [15:0] crc_b0  = (wn == 0 && !in_crc && f_m0 && !wpmk) ? 16'hFFFF : wcrc;   // preset at a mark after a non-mark
  // the tokens for a bit c with the next n (Table 13): {first, two, second}
  function [2:0] tks(input h2, input h1, input c, input n, input mk);
    if (mk && h2 && !h1 && !c && !n) tks = 3'b010;            // 00: the dropped clock
    else case ({c, n})
      2'b00:   tks = 3'b100;                                  // 1
      2'b01:   tks = 3'b011;                                  // 01
      2'b10:   tks = 3'b000;                                  // 0
      default: tks = 3'b100;                                  // 1
    endcase
  endfunction
  wire  [9:0] dur1 = {2'b00, param[15]} + 10'd4;             // TIME1 + the two-clock delay, in half-clocks
  wire  [9:0] dur0 = {2'b00, param[13]} + 10'd4;             // TIME0
  // a new bit: (c, n) become (wnxt, wb), or at ACTION the head's first two
  wire        a_c  = iw_go ? f_b0[7] : wnxt;
  wire        a_n  = iw_go ? f_b0[6] : wb;
  wire  [2:0] a_t  = iw_go ? tks(1'b0, 1'b0, f_b0[7], f_b0[6], f_m0) : tks(wh1, wcur, wnxt, wb, wmk_n);
  wire        w_tog = tk_end && wtok;                         // a 1 token's terminal count
  // the error bits raised this clock (User's Ref p. 23)
  wire  [7:0] rc_err  = {2'b00,
                         wide_now,                                            // 5 too wide
                         cell_ok && ccls == 3'd0,                             // 4 too narrow
                         1'b0,
                         (rd_data || rd_mark) && f_n == 0,                    // 2 nothing to read
                         rd_data && f_n != 0 && f_m0,                         // 1 a mark through Data
                         f_push && f_n == 2'd2 && !f_pop};                    // 0 overrun
  // ... and the write path's (write mode only)
  wire  [7:0] wc_err  = {5'b00000,
                         w_push && f_n == 2'd2 && !w_in,                      // 2 overrun
                         1'b0,
                         w_unr};                                              // 0 underrun
  wire  [7:0] all_err = rc_err | wc_err;
  // the FIFO's one push and one pop, reading or writing
  wire        fp   = f_push || w_push;
  wire        fo   = f_pop  || w_in;
  wire  [7:0] fd_b = w_push ? wdata : done_b;
  wire        fd_m = w_push ? w_mk  : done_m;
  wire        fd_c = w_push ? w_crc : done_c;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      wsr16 <= 0; wn <= 0; wisc <= 0; wmk <= 0; wpmk <= 0; wcrc <= 16'hFFFF;
      wh2 <= 0; wh1 <= 0; wcur <= 0; wnxt <= 0; wmk_c <= 0; wmk_n <= 0;
      wtok <= 0; wtok2 <= 0; wtok2v <= 0; tcnt <= 0; wrd_m <= 0; wpul <= 0;
    end else begin
      if (c16_en && wpul != 0) wpul <= wpul - 1'b1;
      if (w_tog) begin wrd_m <= !wrd_m; wpul <= 3'd4; end

      if (iw_go) begin
        // the IN at ACTION: the head's first two bits into the machine
        wh2 <= 0; wh1 <= 0; wcur <= f_b0[7]; wnxt <= f_b0[6]; wmk_c <= f_m0; wmk_n <= f_m0;
        wsr16 <= {f_b0[5:0], 10'd0}; wn <= 5'd6; wisc <= 0; wmk <= f_m0; wpmk <= f_m0;
        wcrc <= crc1(crc1((f_m0 && !wpmk) ? 16'hFFFF : wcrc, f_b0[7]), f_b0[6]);
        wtok <= a_t[2]; wtok2 <= a_t[1]; wtok2v <= a_t[0];
        tcnt <= a_t[2] ? dur1 : dur0;
      end else if (!iw_on) begin
        wtok <= 0; wtok2 <= 0; wn <= 0;
      end else if (c16_en) begin
        if (!tk_end) tcnt <= tcnt_n;
        else if (wtok2) begin                                 // the second token of 01 or 00
          wtok <= wtok2v; wtok2 <= 0;
          tcnt <= tcnt_n + (wtok2v ? dur1 : dur0);
        end else begin                                        // the next bit
          wh2 <= wh1; wh1 <= wcur; wcur <= wnxt; wnxt <= wb; wmk_c <= wmk_n; wmk_n <= wb_mk;
          if (!wb_isc) wcrc <= crc1(crc_b0, wb);
          if (wn != 0) begin wsr16 <= {wsr16[14:0], 1'b0}; wn <= wn - 1'b1; end
          else if (f_n != 0) begin                            // an IN
            wisc <= in_crc; wmk <= !in_crc && f_m0; wpmk <= !in_crc && f_m0;
            wsr16 <= in_crc ? {wcrc[14:0], 1'b0} : {f_b0[6:0], 9'd0};
            wn <= in_crc ? 5'd15 : 5'd7;
          end
          wtok <= a_t[2]; wtok2 <= a_t[1]; wtok2v <= a_t[0];
          tcnt <= tcnt_n + (a_t[2] ? dur1 : dur0);
        end
      end
    end
  end

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      rdd_s <= 1; tc <= 0; have_t <= 0; prev_l <= 0; wide_done <= 0;
      csm <= C_IDLE; nmin <= 0; ref_d <= 0; asr <= 0; acnt <= 0; amark <= 0; rcrc <= 16'hFFFF;
      f_b0 <= 0; f_b1 <= 0; f_m0 <= 0; f_m1 <= 0; f_c0 <= 0; f_c1 <= 0; f_n <= 0;
    end else begin
      if (c16_en) rdd_s <= sense;
      if (c16_en) tc <= ism_tr ? 12'd0 : (tc[11] ? tc : tc + 12'd2);

      if (!ism_act) begin
        csm <= C_IDLE; have_t <= 0; wide_done <= 0; acnt <= 0; amark <= 0;
      end else begin
        if (wide_now) begin                                       // too wide: back to counting
          wide_done <= 1;
          if (csm != C_LOCK) begin csm <= C_SYNC; nmin <= 0; end
        end
        if (ism_tr) begin
          have_t <= 1; wide_done <= 0;
          if (csm == C_IDLE) begin csm <= C_SYNC; nmin <= 0; ref_d <= 0; prev_l <= 0; end
        end
        if (cell_ok) begin
          prev_l <= (ccls != 3'd2);
          if (ccls == 3'd0) begin                                 // too narrow
            if (csm != C_LOCK) begin csm <= C_SYNC; nmin <= 0; end
          end else case (csm)
            C_SYNC:                                               // the run of minimum cells
              if (ccls == 3'd2) begin
                if (nmin == 6'd63) csm <= C_WAIT; else nmin <= nmin + 1'b1;
              end else nmin <= 0;
            C_WAIT:                                               // the first non-minimum cell
              if (ccls == 3'd3) begin                             // a 1 after the zeros: a byte begins
                asr <= 8'h01; acnt <= 4'd1; amark <= 0; rcrc <= crc1(16'hFFFF, 1'b1);
                ref_d <= 1; csm <= C_MARK;
              end else if (ccls != 3'd2) begin csm <= C_SYNC; nmin <= 0; end
            C_MARK: begin                                         // the mark within this byte, or back
              asr <= n_asr; acnt <= n_acnt; amark <= n_amark; rcrc <= n_crc; ref_d <= ref_n;
              if (is_mark) csm <= C_LOCK;
              else if (done) begin csm <= C_SYNC; nmin <= 0; end
            end
            C_LOCK: begin                                         // bytes to the FIFO
              asr <= n_asr; acnt <= n_acnt; amark <= n_amark; rcrc <= n_crc; ref_d <= ref_n;
            end
            default: ;
          endcase
        end
      end

      // the FIFO: a pop, a push, Clear FIFO.  Reading, a completed byte in
      // and the processor's read out; writing, the processor's byte in
      // (OUT) and the shift register's IN out.  f_c is the CRC-zero flag
      // reading and the CRC entry writing.
      if (ism_mode[0]) begin
        f_n <= 0; rcrc <= 16'hFFFF;
      end else begin
        if (fo) begin f_b0 <= f_b1; f_m0 <= f_m1; f_c0 <= f_c1; end
        if (fp) begin
          if (f_n == 2'd2 && !fo) ;                               // overrun: the byte is lost
          else if ((f_n == 2'd0) || (f_n == 2'd1 && fo)) begin
            f_b0 <= fd_b; f_m0 <= fd_m; f_c0 <= fd_c;
            f_n <= fo ? f_n : f_n + 1'b1;
          end else begin
            f_b1 <= fd_b; f_m1 <= fd_m; f_c1 <= fd_c;
            f_n <= fo ? f_n : f_n + 1'b1;
          end
        end else if (fo) f_n <= f_n - 1'b1;
      end
    end
  end

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
      // the errors: the first one holds the register until it is read
      if (all_err != 0 && ism_error == 0) ism_error <= all_err;

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
          3'd2: ism_error <= all_err;                                // read: cleared (an error this clock stays)
          3'd3: pidx <= pidx + 1'b1;
          default: ;
        endcase
      end
      // "the Action bit will be cleared any time there is any Error while
      // writing" (ISM spec p. 45) - after the register writes, so it wins
      if (wc_err != 0) ism_mode[3] <= 1'b0;
    end
  end

  // ---------------------------------------------------------- the pins
  assign ph_out  = ph_lvl;
  assign ph_oe   = ph_dir;
  assign enbl1_n = ism ? !(ism_mode[7] && ism_mode[1]) : !(motor_d && !drvsel);
  assign enbl2_n = ism ? !(ism_mode[7] && ism_mode[2]) : !(motor_d &&  drvsel);
  // the ISM's WRDATA: a 4-FCLK low pulse a toggle with the IBM option, else the level
  assign wrdata  = ism ? (ism_setup[5] ? (wpul == 0) : wrd_m) : wrd;
  assign wrreq_n = ism ? !iw_on : !(wact && unr_n);
  assign hdsel   = ism_setup[0] && ism_mode[5];

  assign dbg_vread = vread;
  assign dbg = {ism, l7, l6, drvsel, motor, ph_lvl, iwm_mode, motor_d, enbl1_n, enbl2_n, sense,
                iwm_test, sw_cnt, ism_mode | (ism ? 8'h40 : 8'h00), ism_setup, ph_dir, iwm_cfg, 4'b0};

endmodule
