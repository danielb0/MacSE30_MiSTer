// se30_fdhd.v - a Sony FDHD (SuperDrive) floppy drive

`timescale 1ns/1ps

module se30_fdhd #(
  parameter     MFM_WRITE = 1
) (
  input         clk,
  input         c16_en,
  input         reset_n,

  input         enbl_n,
  input   [3:0] ph,
  input         sel,
  output        sense,

  input         disk_in,
  output reg    eject,

  output  [6:0] cyl,
  input   [6:0] trk_cyl,
  input         trk_valid,
  output [17:0] trk_addr,
  output        trk_side,
  input         trk_bit,

  input         hd,
  input         wprot,
  input         wrreq_n,
  input         wrdata,
  output        trk_we,
  output        trk_wbit,
  output [17:0] trk_cells,
  output reg    arc_done,
  output reg    arc_side,
  output reg [17:0] arc_start,
  output reg [17:0] arc_end,
  output reg    arc_whole,

  output [15:0] dbg
);

  localparam [24:0] T_STEP = 25'd1128;
  localparam [24:0] T_SET  = 25'd564019;
  localparam [24:0] T_GRP  = 25'd2381414;
  localparam [24:0] T_SPIN = 25'd9400320;
  localparam [24:0] T_DIN  = 25'd15667200;

  reg        dir;
  reg        motor_on;
  reg        eject_latch;
  reg        mfm;
  reg  [6:0] track;
  reg        step_n;
  reg [24:0] step_t, settle, spin;
  reg        lstrb_d, disk_d;

  localparam [18:0] U_FCLK  = 19'd10000;
  localparam [18:0] L_GCR   = 19'd320000;
  localparam [18:0] L_MFM   = 19'd156672;
  localparam [17:0] IDX     = 18'd2000;
  reg [17:0] cells;
  always @* begin
    if (mfm) cells = hd ? 18'd200000 : 18'd100000;
    else case (track[6:4])
      3'd0:    cells = 18'd74558;
      3'd1:    cells = 18'd68476;
      3'd2:    cells = 18'd62237;
      3'd3:    cells = 18'd55954;
      default: cells = 18'd49790;
    endcase
  end
  wire [18:0] lcell = mfm ? L_MFM : L_GCR;
  reg  [18:0] acc;
  wire [18:0] acc_n = acc + U_FCLK;
  wire        cell_end = c16_en && motor_on && acc_n >= lcell;
  reg         cs_q;
  reg  [17:0] pos;
  reg  [17:0] tacc;
  reg         tach;
  reg   [3:0] pulse;
  wire        index = pos < IDX;

  wire trk_ok  = trk_valid && trk_cyl == track;
  wire data_ok = disk_in && disk_d && motor_on && trk_ok;
  wire ready   = data_ok && spin == 0 && settle == 0;
  wire rd_data = !(data_ok && pulse != 0);
  wire rd_reg  = (MFM_WRITE && mfm && !wrreq_n) ? (motor_on && index) : rd_data;

  wire        gate    = !enbl_n && !wrreq_n && data_ok && !wprot;
  reg         wr_q;
  reg         rec;
  reg         wrote;
  reg  [17:0] wcur;
  reg  [18:0] wt;
  reg  [17:0] wcount;
  reg         pend1;
  reg         had_t;
  reg         we_r, wbit_r;
  reg  [17:0] wa_r;
  wire        side_moved = rec && arc_side != sel;
  wire        edge_ev = wrdata != wr_q;
  wire [17:0] wnext   = (wcur + 1'b1 >= cells) ? 18'd0 : wcur + 1'b1;
  wire [18:0] wt_n    = c16_en ? wt + U_FCLK : wt;
  wire        zero_due = rec && (wt_n >= lcell + {1'b0, lcell[18:1]});
  wire        trans   = rec && edge_ev && (!had_t || wt_n >= {1'b0, lcell[18:1]});
  assign trk_we   = we_r;
  assign trk_wbit = wbit_r;

  reg        bit_q;
  always @* begin
    case ({sel, ph[2], ph[1], ph[0]})
      4'h0: bit_q = dir;
      4'h1: bit_q = step_n;
      4'h2: bit_q = !motor_on;
      4'h3: bit_q = eject_latch;
      4'h4: bit_q = rd_reg;
      4'h5: bit_q = 1'b1;
      4'h6: bit_q = 1'b1;
      4'h7: bit_q = 1'b0;
      4'h8: bit_q = !disk_in;
      4'h9: bit_q = disk_in && !wprot;
      4'hA: bit_q = (track != 0);
      4'hB: bit_q = mfm ? (motor_on && index)
                        : (motor_on ? tach : 1'b1);
      4'hC: bit_q = rd_reg;
      4'hD: bit_q = mfm;
      4'hE: bit_q = !ready;
      4'hF: bit_q = !(disk_in && hd);
    endcase
  end
  assign sense = enbl_n ? 1'b1 : bit_q;

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
          if (pend1) begin
            wbit_r <= 1; pend1 <= 0;
            if (trans) wt <= 19'd0;
          end else if (zero_due) begin
            wbit_r <= 0; wt <= wt_n - lcell;
            if (trans) begin
              pend1 <= 1; wt <= 19'd0;
            end
          end else begin
            wbit_r <= 1; wt <= 19'd0;
          end
        end
      end

      if (c16_en) begin
        if (step_t != 0) begin step_t <= step_t - 1'b1; if (step_t == 1) step_n <= 1; end
        if (settle != 0) settle <= settle - 1'b1;
        if (spin   != 0) spin   <= spin - 1'b1;

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

      if (disk_in && !disk_d && motor_on) spin <= (spin > T_DIN) ? spin : T_DIN;

      if (enbl_n) begin
        dir <= 0;
        motor_on <= 0;
      end else if (strobe)
        case ({sel, ph[1], ph[0]})
          3'b000: dir <= ph[2];
          3'b001: if (ph[2]) step_n <= 1;
                  else if (step_n) begin
                    step_n <= 0; step_t <= T_STEP;
                    track  <= step_to;
                    settle <= (settle > step_set) ? settle : step_set;
                  end
          3'b010: begin
                    if (!ph[2] && !motor_on) spin <= T_SPIN;
                    motor_on <= !ph[2];
                  end
          3'b011: if (ph[2]) begin eject_latch <= 1; eject <= 1; end
          3'b100: if (ph[2]) eject_latch <= 0;
          3'b101: begin
                    if (mfm != !ph[2]) settle <= (settle > T_GRP) ? settle : T_GRP;
                    mfm <= !ph[2];
                  end
          default: ;
        endcase
    end
  end

  assign cyl       = track;
  assign trk_cells = cells;
  assign trk_addr  = we_r ? wa_r : pos;
  assign trk_side = sel;

  assign dbg = {motor_on, dir, eject_latch, mfm, disk_in, !ready, !step_n, settle != 0, spin != 0, track};

endmodule
