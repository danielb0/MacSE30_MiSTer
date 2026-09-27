// se30_fdhd.v - one Sony FDHD (SuperDrive) floppy drive, as the SE/30's
// ROM reads it, to the contract of SE30_PLAN.md 5.5 - rung 1: no disk.
//
// WHAT IT IS
//   The drive's sixteen status registers and its commands, addressed by
//   the phase lines and SEL.  Apple's own description of the Sony
//   drives' registers is not in hand; the ROM's .Sony driver fixes the
//   address encoding and every register it reads at start-up, and a
//   modern table of Apple's register names (built from a SWIM3 driver,
//   secondary) gives the rest, confirmed by the ROM wherever the ROM
//   reaches (plan 5.5 marks each level's evidence).  Held to
//   sim/swim/tb_se30_swim.v.
//
// THE ADDRESS
//   {SEL, CA2, CA1, CA0} = {sel, ph[2], ph[1], ph[0]} selects a status
//   register, which the drive puts on SENSE while it is enabled.  A
//   command is {SEL, CA1, CA0} with CA2 as its value, taken on the rising
//   edge of LSTRB (PH3) while enabled - the ROM's pulse (PH3 high, two
//   NOPs, low) works on either edge; the rising one is our choice (plan
//   5.10).  The ROM numbers the same registers {CA1, CA0, SEL, CA2}
//   ($4082E0EC); the comments below give both.
//
// RUNG 1
//   There is never a disk (disk_in is 0): no flux, no tach, not ready.
//   A step moves the track counter at once; the step and settle times,
//   the spindle, the heads and the flux are rung 2's.  The drive is not
//   on RESET* (sheet 6): reset_n is the power-up only.

`timescale 1ns/1ps

module se30_fdhd (
  input         clk,
  input         c16_en,
  input         reset_n,               // power-up, not the RESET instruction

  input         enbl_n,
  input   [3:0] ph,                    // CA0, CA1, CA2, LSTRB
  input         sel,                   // VIA1 PA5
  output        sense,                 // 1 when not enabled: the line's pull-up
  input         disk_in,

  output [15:0] dbg
);

  reg        dir;                      // 0 = inward (toward higher tracks)
  reg        motor_on;
  reg        eject_latch;
  reg        mfm;                      // 1 = MFM mode; GCR from power-up
  reg  [6:0] track;
  reg        lstrb_d;

  reg        bit_q;
  always @* begin
    case ({sel, ph[2], ph[1], ph[0]})             // ROM number {CA1,CA0,SEL,CA2}
      4'h0: bit_q = dir;                          // $0 rDirPrevAdr
      4'h1: bit_q = 1'b1;                         // $4 rStepOffAdr: no step in progress
      4'h2: bit_q = !motor_on;                    // $8 rMotorOffAdr
      4'h3: bit_q = eject_latch;                  // $C rEjectOnAdr
      4'h4: bit_q = 1'b1;                         // $1 rRdData0Adr: no flux
      4'h5: bit_q = 1'b1;                         // $5 rMFMDriveAdr: a SuperDrive
      4'h6: bit_q = 1'b1;                         // $9 rDoubleSidedAdr
      4'h7: bit_q = 1'b0;                         // $D rNoDriveAdr: present
      4'h8: bit_q = !disk_in;                     // $2 rNoDiskInPlAdr
      4'h9: bit_q = 1'b1;                         // $6 rNoWrProtectAdr
      4'hA: bit_q = (track != 0);                 // $A rNotTrack0Adr
      4'hB: bit_q = 1'b1;                         // $E tach / index: nothing turning
      4'hC: bit_q = 1'b1;                         // $3 rRdData1Adr: no flux
      4'hD: bit_q = mfm;                          // $7 rMFMModeOnAdr
      4'hE: bit_q = 1'b1;                         // $B rNotReadyAdr
      4'hF: bit_q = 1'b1;                         // $F r1MegMediaAdr: no HD medium
    endcase
  end
  assign sense = enbl_n ? 1'b1 : bit_q;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      dir <= 0; motor_on <= 0; eject_latch <= 0; mfm <= 0; track <= 0; lstrb_d <= 0;
    end else begin
      lstrb_d <= ph[3];
      if (!enbl_n && ph[3] && !lstrb_d)
        case ({sel, ph[1], ph[0]})                // ROM number: CA2 = 0 / 1
          3'b000: dir <= ph[2];                   // $0 / $1 direction
          3'b001: if (!ph[2]) begin               // $4 step
                    if (!dir && track != 7'd79) track <= track + 1'b1;
                    if ( dir && track != 7'd0)  track <= track - 1'b1;
                  end
          3'b010: motor_on <= !ph[2];             // $8 on / $9 off
          3'b011: ;                               // $D eject: no disk to eject
          3'b100: if (ph[2]) eject_latch <= 0;    // $3 reset the eject latch
          3'b101: mfm <= !ph[2];                  // $6 MFM / $7 GCR
          default: ;                              // undefined
        endcase
    end
  end

  assign dbg = {motor_on, dir, eject_latch, mfm, disk_in, 4'b0, track};

endmodule
