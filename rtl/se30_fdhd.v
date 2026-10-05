// se30_fdhd.v - one Sony FDHD (SuperDrive) floppy drive, as the SE/30's
// ROM reads it: the registers of SE30_PLAN.md 5.5 (rung 1) and the
// turning disk of 5.12.3 (rung 2).
//
// WHAT IT IS
//   The drive's sixteen status registers and its commands, addressed by
//   the phase lines and SEL, and a disk that turns under them.  The
//   SuperDrive's own description is not in hand: the timing and every
//   register the 800K drive shares with it are Apple's 800K ERS
//   (669-0452-A, Sep 86, read from the page images); the SuperDrive's
//   additions are the ROM's .Sony driver and a modern table of Apple's
//   register names (secondary), confirmed by the ROM wherever the ROM
//   reaches (plan 5.5 marks each level's evidence).  Held to
//   sim/fdhd/tb_se30_fdhd.v and sim/swim/tb_se30_swim.v.
//
// THE ADDRESS
//   {SEL, CA2, CA1, CA0} = {sel, ph[2], ph[1], ph[0]} selects a status
//   register (the ERS's Table 1), which the drive puts on SENSE while it
//   is enabled.  A command is {SEL, CA1, CA0} with CA2 as its value,
//   taken on the rising edge of LSTRB (PH3) while enabled (3.2.3).  The
//   ROM numbers the same registers {CA1, CA0, SEL, CA2} ($4082E0EC); the
//   comments below give both.
//
// THE TIMES (ERS maxima, in FCLK = C16M = 15.6672 MHz; plan 5.12.3)
//   /STEP low after a step              72 us     3.4.3.1 T2
//   /READY after a step, same group     36 ms     3.4.3.3 T2
//   /READY after a step across groups   152 ms    3.4.3.3 T2
//   /READY after motor-on               600 ms    3.4.4 T1
//   /READY after a disk-in, motor on    1.0 s     3.4.4 T3
//   /READY goes high at once on a step, the motor off, or the disk out
//   (the ERS's 150 us, 50 ms and 0.5 us maxima, met at zero).
//
// THE DISK
//   Five speed groups of 16 tracks at 394/429/472/525/590 rpm (2.16);
//   the data rate is fixed at 489.6 kbit/s, exactly 32 FCLK a cell, so a
//   revolution is 74,558 / 68,476 / 62,237 / 55,954 / 49,790 cells (MFM
//   mode: below).  The cell counter runs whenever the motor is on and
//   wraps at the revolution's length (a speed change leaves the position
//   where it falls - /READY is high for its 152 ms).  /TACH toggles 120 times a revolution: 60
//   pulses (3.2.4.11).  RD in data mode is an 8-FCLK low pulse (0.51 us,
//   T4 0.3-0.8 us) at each 1 of the track bitstream, from the side SEL
//   picks (3.2.4.5), and 1 without a disk, with the motor off, or while
//   the track buffers do not hold the head's cylinder.
//
// THE TRACK BUFFERS (the encoder's side, plan 5.12.5b)
//   The drive shows the cylinder its head is on (`cyl`); the encoder
//   answers with the cylinder its two buffers hold (`trk_cyl`) and
//   whether they are whole (`trk_valid`).  /READY waits for the match.
//   The cell under the head is `trk_addr` on side `trk_side`; its bit
//   (1 = a transition) is expected on `trk_bit` a clock later.
//
// DESELECTION (3.2.2)
//   /ENBL high presets /DIRTN to 0 and /MOTORON high: the motor stops.
//   The ROM keeps MotorOn up while it wants the spindle (its VBL task,
//   $4082E444, drops it only after the motor-off command).
//
// EJECT
//   Command $D sets the latch at $C and pulses `eject` (the loader takes
//   the disk out, so /CSTIN rises); command $3 resets the latch - the
//   SuperDrive's latch the ROM resets ($4082E4E2), not the 800K drive's
//   self-clearing EJECT (plan 5.12.3).
//
// RECORDING (rung 3, plan 5.15.3; interval recording, plan 5.13.5)
//   "When /WRTGATE is a zero, when /ENBL is a zero and if the inserted
//   disk is not write protected, data on WRTDATA are recorded on the
//   disk" (3.2.5) - and here the motor must be on and the track buffers
//   the head's, as for reading.  The buffer holds a bit a cell, so the
//   drive records INTERVALS (Daniel's decision B, 2026-10-05): a write
//   cursor starts at the cell under the head when the gate opens; each
//   WRTDATA transition is written as a 1 in the cell after the cursor,
//   and whenever 1.5 cells pass with none, the cell after the cursor
//   cannot hold the next one and is written 0.  So each interval is kept
//   as the nearest whole number of cells.  For GCR that is exact as it
//   always was (the IWM's cell and the drive's are both 32 FCLK); for
//   MFM it is what makes a medium of the ISM's writes at all - its
//   intervals (31.5, 47 and 62.5 FCLK from the parameter RAM) are no
//   multiple of the 1-us cell, and a fixed grid would drift a whole cell
//   in one sync field.  A transition within half a cell of the last is
//   the same one (an IBM-style pulse's second edge, MFM mode).  The
//   cursor drifts from the head by the writer's own rate error.  When the
//   gate ends (or SEL changes side) the recording is reported as an arc -
//   its side, first and last cells, and whether it covered a whole
//   revolution - for the decoder.  /WRTPRT reads 0 with no disk or a disk
//   mounted read-only (wprot), 1 otherwise (3.2.4.9).  The erase head
//   (3.4.5 T7) trims the track's edges and is not modelled.
//
// MFM MODE (plan 5.13.4, 5.13.9 item 1)
//   Command $6 (and $7 back): $7 reads 1.  The spindle runs at one speed
//   whatever the track - 300 rpm with a high-density medium, 600 rpm with
//   double density (decision A: the ROM's only ISM timing is the 1.44 MB
//   one, so a 720K disk must reach the ISM at 500 kbit/s) - with a 1-us
//   cell (15.6672 FCLK, a fractional count: cells of 15 or 16 FCLK, exact
//   on average): 200,000 or 100,000 cells a revolution.  $E gives the
//   index, high for the first IDX cells of the revolution, instead of the
//   tach (the width is ours: no drive document; the ROM waits only for
//   the rising edge).  $F reads 0 for a high-density medium (hd).  A
//   speed change takes the speed group's 152 ms settle (3.4.3.3, the
//   documented analogue).
//
// The drive is not on RESET* (sheet 6): reset_n is the power-up only.

`timescale 1ns/1ps

module se30_fdhd (
  input         clk,
  input         c16_en,                // FCLK
  input         reset_n,               // power-up, not the RESET instruction

  input         enbl_n,
  input   [3:0] ph,                    // CA0, CA1, CA2, LSTRB
  input         sel,                   // VIA1 PA5
  output        sense,                 // 1 when not enabled: the line's pull-up

  input         disk_in,               // a whole image is mounted
  output reg    eject,                 // one clock: the eject command

  output  [6:0] cyl,                   // the head's cylinder
  input   [6:0] trk_cyl,               // the cylinder the track buffers hold
  input         trk_valid,             // and they are whole
  output [17:0] trk_addr,              // the cell under the head, or being written
  output        trk_side,
  input         trk_bit,               // its bit, a clock after trk_addr

  input         hd,                    // the medium is high-density (plan 5.13)
  input         wprot,                 // the disk is write-protected (mounted read-only)
  input         wrreq_n,               // /WRTGATE: the SWIM's /WRREQ
  input         wrdata,                // WRTDATA
  output        trk_we,                // write trk_wbit at trk_addr on trk_side
  output        trk_wbit,
  output [17:0] trk_cells,             // the head's revolution, in cells
  output reg    arc_done,              // one clock: a recording ended
  output reg    arc_side,
  output reg [17:0] arc_start,         // its first cell
  output reg [17:0] arc_end,           // its last cell
  output reg    arc_whole,             // it covered a whole revolution

  output [15:0] dbg
);

  localparam [24:0] T_STEP = 25'd1128;       // 72 us
  localparam [24:0] T_SET  = 25'd564019;     // 36 ms
  localparam [24:0] T_GRP  = 25'd2381414;    // 152 ms
  localparam [24:0] T_SPIN = 25'd9400320;    // 600 ms
  localparam [24:0] T_DIN  = 25'd15667200;   // 1.0 s

  reg        dir;                      // /DIRTN: 0 = toward the centre (higher tracks)
  reg        motor_on;                 // /MOTORON low
  reg        eject_latch;
  reg        mfm;                      // 1 = MFM mode; GCR from power-up
  reg  [6:0] track;                    // the destination counter; the head is on it
  reg        step_n;                   // the /STEP latch
  reg [24:0] step_t, settle, spin;     // FCLK left: /STEP low, head settling, spin-up
  reg        lstrb_d, disk_d;

  // ------------------------------------------------------ the rotation
  // a cell in units of 1/10000 FCLK: 32 FCLK in GCR, 15.6672 (1 us) in MFM
  localparam [18:0] U_FCLK  = 19'd10000;
  localparam [18:0] L_GCR   = 19'd320000;
  localparam [18:0] L_MFM   = 19'd156672;
  localparam [17:0] IDX     = 18'd2000;      // the index's width in cells (2 ms in HD)
  reg [17:0] cells;                    // a revolution
  always @* begin
    if (mfm) cells = hd ? 18'd200000 : 18'd100000;   // 300 / 600 rpm
    else case (track[6:4])
      3'd0:    cells = 18'd74558;      // 394 rpm
      3'd1:    cells = 18'd68476;      // 429 rpm
      3'd2:    cells = 18'd62237;      // 472 rpm
      3'd3:    cells = 18'd55954;      // 525 rpm
      default: cells = 18'd49790;      // 590 rpm
    endcase
  end
  wire [18:0] lcell = mfm ? L_MFM : L_GCR;
  reg  [18:0] acc;                     // units into the cell under the head
  wire [18:0] acc_n = acc + U_FCLK;
  wire        cell_end = c16_en && motor_on && acc_n >= lcell;   // the cell under the head ends
  reg         cs_q;                    // a cell began at the last FCLK: its bit is ready
  reg  [17:0] pos;                     // the cell under the head
  reg  [17:0] tacc;                    // /TACH: 120 toggles a revolution
  reg         tach;
  reg   [3:0] pulse;                   // FCLK left of RD's low pulse
  wire        index = pos < IDX;

  wire trk_ok  = trk_valid && trk_cyl == track;
  // disk_d as well: an arriving disk loads the spin-up a clock later, and
  // /READY must not dip for that clock
  wire data_ok = disk_in && disk_d && motor_on && trk_ok;
  wire ready   = data_ok && spin == 0 && settle == 0;
  wire rd_data = !(data_ok && pulse != 0);

  // ------------------------------------------------------ recording
  wire        gate    = !enbl_n && !wrreq_n && data_ok && !wprot;
  reg         wr_q;                    // WRTDATA a clock ago
  reg         rec;                     // a recording is open
  reg         wrote;                   // ... and has written a cell
  reg  [17:0] wcur;                    // the write cursor: the last cell written
  reg  [18:0] wt;                      // units since the last transition, less the cells written 0 since
  reg  [17:0] wcount;                  // cells written, saturating at a revolution
  reg         pend1;                   // a 1 owed to the cell after the cursor
  reg         had_t;                   // a transition since the gate opened
  reg         we_r, wbit_r;            // the buffer's write: this clock
  reg  [17:0] wa_r;
  wire        side_moved = rec && arc_side != sel;
  wire        edge_ev = wrdata != wr_q;
  wire [17:0] wnext   = (wcur + 1'b1 >= cells) ? 18'd0 : wcur + 1'b1;
  wire [18:0] wt_n    = c16_en ? wt + U_FCLK : wt;
  wire        zero_due = rec && (wt_n >= lcell + {1'b0, lcell[18:1]});  // 1.5 cells and no transition
  wire        trans   = rec && edge_ev && (!had_t || wt_n >= {1'b0, lcell[18:1]}); // not within half a cell of the last
  assign trk_we   = we_r;
  assign trk_wbit = wbit_r;

  reg        bit_q;
  always @* begin
    case ({sel, ph[2], ph[1], ph[0]})             // ROM number {CA1,CA0,SEL,CA2}
      4'h0: bit_q = dir;                          // $0 /DIRTN
      4'h1: bit_q = step_n;                       // $4 /STEP
      4'h2: bit_q = !motor_on;                    // $8 /MOTORON
      4'h3: bit_q = eject_latch;                  // $C the eject latch
      4'h4: bit_q = rd_data;                      // $1 RDDATA, side 0
      4'h5: bit_q = 1'b1;                         // $5 a SuperDrive
      4'h6: bit_q = 1'b1;                         // $9 /SINGLE SIDE: 1, double-sided
      4'h7: bit_q = 1'b0;                         // $D /DRVIN: present
      4'h8: bit_q = !disk_in;                     // $2 /CSTIN
      4'h9: bit_q = disk_in && !wprot;            // $6 /WRTPRT: 0 protected, or no disk
      4'hA: bit_q = (track != 0);                 // $A /TK0
      4'hB: bit_q = mfm ? (motor_on && index)      // $E the index (MFM mode)
                        : (motor_on ? tach : 1'b1); // $E /TACH (GCR)
      4'hC: bit_q = rd_data;                      // $3 RDDATA, side 1
      4'hD: bit_q = mfm;                          // $7 MFM mode
      4'hE: bit_q = !ready;                       // $B /READY
      4'hF: bit_q = !(disk_in && hd);             // $F 0: a high-density medium
    endcase
  end
  assign sense = enbl_n ? 1'b1 : bit_q;

  // a step's destination and its settling time
  wire [6:0]  step_to  = dir ? (track == 7'd0  ? track : track - 1'b1)
                             : (track == 7'd79 ? track : track + 1'b1);
  wire [24:0] step_set = (step_to[6:4] != track[6:4]) ? T_GRP : T_SET;
  wire        strobe   = !enbl_n && ph[3] && !lstrb_d;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      dir <= 0; motor_on <= 0; eject_latch <= 0; mfm <= 0; track <= 0;
      step_n <= 1; step_t <= 0; settle <= 0; spin <= 0;
      lstrb_d <= 0; disk_d <= 0; eject <= 0;
      acc <= 0; cs_q <= 0; pos <= 0; tacc <= 0; tach <= 1; pulse <= 0;
      wr_q <= 0; rec <= 0; wrote <= 0; wcur <= 0; wt <= 0; wcount <= 0; pend1 <= 0; had_t <= 0;
      we_r <= 0; wbit_r <= 0; wa_r <= 0;
      arc_done <= 0; arc_side <= 0; arc_start <= 0; arc_end <= 0; arc_whole <= 0;
    end else begin
      lstrb_d <= ph[3];
      disk_d  <= disk_in;
      eject   <= 0;

      // recording (the header): one cell written a clock at most - a 0
      // when 1.5 cells pass with no transition, a 1 at a transition (owed
      // a clock if a 0 goes first); the arc closes when the gate drops or
      // SEL moves to the other side
      wr_q     <= wrdata;
      arc_done <= 0;
      we_r     <= 0;
      if (!rec) begin
        pend1 <= 0;
        if (gate) begin rec <= 1; wrote <= 0; had_t <= 0; arc_side <= sel; wcur <= pos; wt <= 0; wcount <= 0; end
      end else if (!gate || side_moved) begin
        rec <= 0;
        if (wrote || pend1) begin
          arc_done  <= 1;
          arc_whole <= (wcount + 1'b1 >= cells);
        end
        if (pend1) begin we_r <= 1; wa_r <= wnext; wbit_r <= 1; arc_end <= wnext; end
      end else begin
        wt <= wt_n;
        if (trans) had_t <= 1;
        if (pend1 || zero_due || trans) begin
          we_r <= 1; wa_r <= wnext; wcur <= wnext; arc_end <= wnext;
          if (!wrote) arc_start <= wnext;
          wrote <= 1;
          if (wrote && wcount != cells) wcount <= wcount + 1'b1;
          if (pend1) begin                        // the owed 1
            wbit_r <= 1; pend1 <= 0;
            if (trans) wt <= 19'd0;               // (a third event this soon is the same transition)
          end else if (zero_due) begin            // a cell with no transition
            wbit_r <= 0; wt <= wt_n - lcell;
            if (trans) begin                      // the transition's 1 goes next clock,
              pend1 <= 1; wt <= 19'd0;            // and its interval starts now
            end
          end else begin                          // a transition
            wbit_r <= 1; wt <= 19'd0;
          end
        end
      end

      if (c16_en) begin
        if (step_t != 0) begin step_t <= step_t - 1'b1; if (step_t == 1) step_n <= 1; end
        if (settle != 0) settle <= settle - 1'b1;
        if (spin   != 0) spin   <= spin - 1'b1;

        // the disk turns: a cell every 32 FCLK (GCR) or 15.6672 (MFM), RD's
        // bit taken a FCLK into the cell
        cs_q <= cell_end;
        if (motor_on) begin
          if (cell_end) begin
            acc <= acc_n - lcell;
            pos <= (pos + 1'b1 >= cells) ? 18'd0 : pos + 1'b1;
            if (tacc + 18'd120 >= cells) begin tacc <= tacc + 18'd120 - cells; tach <= !tach; end
            else tacc <= tacc + 18'd120;
          end else acc <= acc_n;
        end
        if (motor_on && cs_q && trk_bit && !rec) pulse <= 4'd8;
        else if (pulse != 0) pulse <= pulse - 1'b1;
      end

      // a disk arriving with the motor on: 1.0 s (3.4.4 T3)
      if (disk_in && !disk_d && motor_on) spin <= (spin > T_DIN) ? spin : T_DIN;

      if (enbl_n) begin                             // deselected: the latches preset (3.2.2)
        dir <= 0;
        motor_on <= 0;
      end else if (strobe)
        case ({sel, ph[1], ph[0]})                // ROM number: CA2 = 0 / 1
          3'b000: dir <= ph[2];                   // $0 / $1 direction
          3'b001: if (ph[2]) step_n <= 1;         // $5: the latch set high, no count
                  else if (step_n) begin          // $4: /STEP's falling edge counts (3.2.4.2)
                    step_n <= 0; step_t <= T_STEP;
                    track  <= step_to;
                    settle <= (settle > step_set) ? settle : step_set;
                  end
          3'b010: begin                           // $8 on / $9 off
                    if (!ph[2] && !motor_on) spin <= T_SPIN;
                    motor_on <= !ph[2];
                  end
          3'b011: if (ph[2]) begin eject_latch <= 1; eject <= 1; end   // $D eject
          3'b100: if (ph[2]) eject_latch <= 0;    // $3 reset the eject latch
          3'b101: begin                           // $6 MFM / $7 GCR
                    if (mfm != !ph[2]) settle <= (settle > T_GRP) ? settle : T_GRP;   // a speed change
                    mfm <= !ph[2];
                  end
          default: ;                              // undefined
        endcase
    end
  end

  assign cyl       = track;
  assign trk_cells = cells;
  assign trk_addr  = we_r ? wa_r : pos;
  assign trk_side = sel;

  assign dbg = {motor_on, dir, eject_latch, mfm, disk_in, !ready, !step_n, settle != 0, spin != 0, track};

endmodule
