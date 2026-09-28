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
//   revolution is 74,558 / 68,476 / 62,237 / 55,954 / 49,790 cells.  The
//   cell counter runs whenever the motor is on and wraps at the group's
//   length (a speed change leaves the phase where it falls - /READY is
//   high for its 152 ms).  /TACH toggles 120 times a revolution: 60
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
// Every rung-2 disk is write-protected (/WRTPRT 0, as with no disk); the
// drive is not on RESET* (sheet 6): reset_n is the power-up only.

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
  output [16:0] trk_addr,              // the cell under the head
  output        trk_side,
  input         trk_bit,               // its bit, a clock after trk_addr

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
  reg [16:0] cells;                    // a revolution of this speed group
  always @* begin
    case (track[6:4])
      3'd0:    cells = 17'd74558;      // 394 rpm
      3'd1:    cells = 17'd68476;      // 429 rpm
      3'd2:    cells = 17'd62237;      // 472 rpm
      3'd3:    cells = 17'd55954;      // 525 rpm
      default: cells = 17'd49790;      // 590 rpm
    endcase
  end
  reg  [4:0] phase;                    // FCLK within the cell
  reg [16:0] pos;                      // the cell under the head
  reg [16:0] tacc;                     // /TACH: 120 toggles a revolution
  reg        tach;
  reg  [3:0] pulse;                    // FCLK left of RD's low pulse

  wire trk_ok  = trk_valid && trk_cyl == track;
  // disk_d as well: an arriving disk loads the spin-up a clock later, and
  // /READY must not dip for that clock
  wire data_ok = disk_in && disk_d && motor_on && trk_ok;
  wire ready   = data_ok && spin == 0 && settle == 0;
  wire rd_data = !(data_ok && pulse != 0);

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
      4'h9: bit_q = 1'b0;                         // $6 /WRTPRT: protected, or no disk
      4'hA: bit_q = (track != 0);                 // $A /TK0
      4'hB: bit_q = motor_on ? tach : 1'b1;       // $E /TACH
      4'hC: bit_q = rd_data;                      // $3 RDDATA, side 1
      4'hD: bit_q = mfm;                          // $7 MFM mode
      4'hE: bit_q = !ready;                       // $B /READY
      4'hF: bit_q = 1'b1;                         // $F a double-density medium
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
      phase <= 0; pos <= 0; tacc <= 0; tach <= 1; pulse <= 0;
    end else begin
      lstrb_d <= ph[3];
      disk_d  <= disk_in;
      eject   <= 0;

      if (c16_en) begin
        if (step_t != 0) begin step_t <= step_t - 1'b1; if (step_t == 1) step_n <= 1; end
        if (settle != 0) settle <= settle - 1'b1;
        if (spin   != 0) spin   <= spin - 1'b1;

        // the disk turns: a cell every 32 FCLK, RD's bit taken a FCLK in
        if (motor_on) begin
          phase <= phase + 1'b1;
          if (phase == 5'd31) begin
            pos <= (pos + 1'b1 >= cells) ? 17'd0 : pos + 1'b1;
            if (tacc + 17'd120 >= cells) begin tacc <= tacc + 17'd120 - cells; tach <= !tach; end
            else tacc <= tacc + 17'd120;
          end
        end
        if (motor_on && phase == 5'd1 && trk_bit) pulse <= 4'd8;
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
          3'b101: mfm <= !ph[2];                  // $6 MFM / $7 GCR
          default: ;                              // undefined
        endcase
    end
  end

  assign cyl      = track;
  assign trk_addr = pos;
  assign trk_side = sel;

  assign dbg = {motor_on, dir, eject_latch, mfm, disk_in, !ready, !step_n, settle != 0, spin != 0, track};

endmodule
