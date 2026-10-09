// se30_fdhd.v - a Sony FDHD (SuperDrive): the sixteen status registers and the commands, addressed
// by {SEL, CA2, CA1, CA0}, a disk turning in five GCR speed groups (or one MFM speed) under them,
// and interval recording into the track buffers. Timings are the 800K drive ERS's maxima.

`timescale 1ns/1ps

module se30_fdhd #(
  parameter     MFM_WRITE = 1          // the index on RDDATA while writing
) (
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

  input         hd,                    // the medium is high-density
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
  // MFM mode with /WRTGATE low: RDDATA0/1 give the index, as $E does (the ROM's formatter waits on it)
  wire rd_reg  = (MFM_WRITE && mfm && !wrreq_n) ? (motor_on && index) : rd_data;

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
      4'h4: bit_q = rd_reg;                       // $1 RDDATA, side 0
      4'h5: bit_q = 1'b1;                         // $5 a SuperDrive
      4'h6: bit_q = 1'b1;                         // $9 /SINGLE SIDE: 1, double-sided
      4'h7: bit_q = 1'b0;                         // $D /DRVIN: present
      4'h8: bit_q = !disk_in;                     // $2 /CSTIN
      4'h9: bit_q = disk_in && !wprot;            // $6 /WRTPRT: 0 protected, or no disk
      4'hA: bit_q = (track != 0);                 // $A /TK0
      4'hB: bit_q = mfm ? (motor_on && index)      // $E the index (MFM mode)
                        : (motor_on ? tach : 1'b1); // $E /TACH (GCR)
      4'hC: bit_q = rd_reg;                       // $3 RDDATA, side 1
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

      // recording: one cell written a clock at most - a 0 when 1.5 cells pass with no transition,
      // a 1 at a transition; the arc closes when the gate drops or SEL moves to the other side
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
            if (trans) begin                      // the transition's 1 goes next clock
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

      // a disk arriving with the motor on: 1.0 s
      if (disk_in && !disk_d && motor_on) spin <= (spin > T_DIN) ? spin : T_DIN;

      if (enbl_n) begin                             // deselected: the latches preset
        dir <= 0;
        motor_on <= 0;
      end else if (strobe)
        case ({sel, ph[1], ph[0]})                // ROM number: CA2 = 0 / 1
          3'b000: dir <= ph[2];                   // $0 / $1 direction
          3'b001: if (ph[2]) step_n <= 1;         // $5: the latch set high, no count
                  else if (step_n) begin          // $4: /STEP's falling edge counts
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
