// se30_sdram.v - SDRAM controller

`timescale 1ns/1ps

module se30_sdram #(
  parameter TR_READS_LOG2 = 16
) (
  input             clk,
  input             clk_sdc,
  input             clk_capa,
  input             clk_capb,
  input             phi,
  input             reset_n,
  output            ready,
  output reg        cap_sel,
  output reg  [1:0] cap_ok,
  output reg [13:0] cap_fail_a,
  output reg [13:0] cap_fail_b,

  input             cpu_start,
  input             cpu_req,
  input             cpu_we,
  input      [22:0] cpu_addr,
  input       [3:0] cpu_be,
  input      [31:0] cpu_wdata,
  output reg [31:0] cpu_rdata,
  output reg        cpu_ack,

  input             dl_req,
  input      [23:0] dl_addr,
  input      [15:0] dl_data,
  output reg        dl_ack,
  input             dk_req,
  input             dk_we,
  input      [23:0] dk_addr,
  input      [15:0] dk_wdata,
  output reg [15:0] dk_rdata,
  output reg        dk_ack,

  input             raw_req,
  input      [63:0] raw_ctl,
  input      [23:0] raw_addr,
  output reg        raw_ack,
  input             dbg_dqm_force,

  output            sd_clk,
  output            sd_cke,
  output reg [12:0] sd_addr,
  output reg  [1:0] sd_ba,
  inout      [15:0] sd_dq,
  output      [1:0] sd_dqm,
  output            sd_cs_n,
  output            sd_ras_n,
  output            sd_cas_n,
  output            sd_we_n
);

  localparam [3:0] CMD_INHIBIT   = 4'b1111,
                   CMD_NOP       = 4'b0111,
                   CMD_ACTIVE    = 4'b0011,
                   CMD_READ      = 4'b0101,
                   CMD_WRITE     = 4'b0100,
                   CMD_PRECHARGE = 4'b0010,
                   CMD_REFRESH   = 4'b0001,
                   CMD_LOAD_MODE = 4'b0000;
  localparam [12:0] MODE = 13'h0221;
  localparam INIT_PAUSE  = 15'd20000;
  localparam REF_EARLY   = 10'd600;
  localparam REF_PERIOD  = 10'd700;
  localparam REF_FORCE   = 10'd1023;
  localparam WIN_LO      = 6'd10;
  localparam WIN_HI      = 6'd17;
  localparam DK_HI       = 6'd15;
  localparam ACT_BUSY    = 4'd8;
  localparam REF_BUSY    = 4'd6;
  localparam [15:0] TR_W1 = 16'hA5C3, TR_W2 = 16'h5A3C;
  localparam  [1:0] TR_BANK = 2'd3;
  localparam [12:0] TR_ROW  = 13'd8191;
  localparam  [8:0] TR_COL  = 9'd510;
  localparam [17:0] TR_READS = 18'd1 << TR_READS_LOG2;

  reg  [3:0] cmd;
  assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;
  assign sd_dqm = sd_addr[12:11];
  assign sd_cke = 1'b1;

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

  reg [15:0] dq_out;
  reg        dq_oe;
  assign sd_dq = dq_oe ? dq_out : 16'hzzzz;
  reg [15:0] dq_pre;
  reg        oe_pre;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin dq_out <= 0; dq_oe <= 0; end
    else begin dq_out <= dq_pre; dq_oe <= oe_pre; end

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

  reg        phi_q, phi_qq;
  always @(posedge clk) begin phi_q <= phi; phi_qq <= phi_q; end
  wire       sample_en = (phi_q != phi_qq);
  reg        xs_start, xs_start_evt, xs_req, xs_we, xs_dl_req;
  reg [22:0] xs_addr;
  reg  [3:0] xs_be;
  reg [31:0] xs_wdata;
  reg [23:0] xs_dl_addr;
  reg [15:0] xs_dl_data;
  reg        xs_raw_req;
  reg [63:0] xs_raw_ctl;
  reg [23:0] xs_raw_addr;
  reg        xs_dk_req, xs_dk_we;
  reg [23:0] xs_dk_addr;
  reg [15:0] xs_dk_wdata;
  always @(posedge clk) begin
    xs_start_evt <= 0;
    if (sample_en) begin
      xs_start <= cpu_start; xs_start_evt <= cpu_start && !xs_start;
      xs_req <= cpu_req; xs_we <= cpu_we;
      xs_addr <= cpu_addr; xs_be <= cpu_be; xs_wdata <= cpu_wdata;
      xs_dl_req <= dl_req; xs_dl_addr <= dl_addr; xs_dl_data <= dl_data;
      xs_raw_req <= raw_req; xs_raw_ctl <= raw_ctl; xs_raw_addr <= raw_addr;
      xs_dk_req <= dk_req; xs_dk_we <= dk_we; xs_dk_addr <= dk_addr; xs_dk_wdata <= dk_wdata;
    end
  end
  wire       start_rise = xs_start_evt;
  wire       req_q = xs_req, we_q = xs_we, dl_req_q = xs_dl_req, raw_req_q = xs_raw_req, dk_req_q = xs_dk_req;
  wire [15:0] r_w0 = xs_raw_ctl[15:0], r_w1 = xs_raw_ctl[31:16];
  wire  [7:0] r_dqm = xs_raw_ctl[39:32];
  wire  [3:0] r_oe = xs_raw_ctl[43:40];
  wire  [3:0] r_sel = {1'b0, xs_raw_ctl[46:44]};
  wire        r_read = xs_raw_ctl[47];
  wire        r_ap = xs_raw_ctl[48], r_second = xs_raw_ctl[49], r_kind = xs_raw_ctl[50];
  wire [12:0] r_mode = xs_raw_ctl[63:51];
  wire  [1:0] r_bank = xs_raw_addr[23:22];
  wire [12:0] r_row  = xs_raw_addr[21:9];
  wire  [8:0] r_col  = xs_raw_addr[8:0];

  wire [23:0] a_word  = {xs_addr, 1'b0};
  wire  [1:0] a_bank  = a_word[23:22];
  wire [12:0] a_row   = a_word[21:9];
  wire  [8:0] a_col   = a_word[8:0];
  wire  [1:0] d_bank  = xs_dl_addr[23:22];
  wire [12:0] d_row   = xs_dl_addr[21:9];
  wire  [8:0] d_col   = xs_dl_addr[8:0];
  wire  [1:0] k_bank  = xs_dk_addr[23:22];
  wire [12:0] k_row   = xs_dk_addr[21:9];
  wire  [8:0] k_col   = xs_dk_addr[8:0];

  localparam [2:0] S_INIT = 3'd0, S_IDLE = 3'd1, S_ACC = 3'd2, S_DONE = 3'd3, S_DL = 3'd4, S_TRAIN = 3'd5, S_RAW = 3'd6, S_DK = 3'd7;
  reg  [2:0] state;
  reg  [3:0] seq;
  wire [1:0] r_k = seq[1:0] - 2'd2;
  wire [1:0] r_kn = seq[1:0] - 2'd1;
  reg  [3:0] busy;
  reg  [9:0] ref_cnt;
  reg        ref_due, ref_early, ref_force;
  reg  [5:0] since_start;
  wire [5:0] next_start = start_rise ? 6'd0 : (since_start != 6'd63) ? since_start + 1'b1 : 6'd63;
  reg        win_ref;
  reg        win_dk;
  reg        start_pend;
  reg        a_we;
  reg        a_written;
  reg  [1:0] a_bank_r;
  reg  [8:0] a_col_r;
  reg  [3:0] a_be;
  reg [31:0] a_wdata;
  reg        k_we_r;
  reg  [1:0] k_bank_r;
  reg  [8:0] k_col_r;
  reg [15:0] k_wdata_r;
  reg [14:0] init_cnt;
  reg  [3:0] init_step;
  reg  [1:0] tr_step;
  reg        tr_pass;
  reg [17:0] tr_n;
  reg [17:0] tr_good;
  wire [17:0] tr_bad = TR_READS - tr_good;
  wire [13:0] tr_fail = (tr_bad > 18'd16383) ? 14'h3FFF : tr_bad[13:0];
  reg [15:0] tr_w1;
  assign ready = (state != S_INIT) && (state != S_TRAIN);
  wire       go = (start_rise || start_pend || req_q) && (busy == 0) && !ref_force;

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      state <= S_INIT; init_cnt <= 0; init_step <= 0; seq <= 0; busy <= 0;
      cmd <= CMD_INHIBIT; sd_addr <= 0; sd_ba <= 0; dq_pre <= 0; oe_pre <= 0;
      cpu_ack <= 0; cpu_rdata <= 0; dl_ack <= 0; raw_ack <= 0; ref_cnt <= 0; ref_due <= 0; ref_early <= 0; ref_force <= 0;
      dk_ack <= 0; dk_rdata <= 0;
      since_start <= 6'd63; win_ref <= 0; win_dk <= 1;
      start_pend <= 0; a_we <= 0; a_written <= 0; a_bank_r <= 0; a_col_r <= 0; a_be <= 0; a_wdata <= 0;
      k_we_r <= 0; k_bank_r <= 0; k_col_r <= 0; k_wdata_r <= 0;
      cap_sel <= 0; cap_ok <= 2'b00; tr_step <= 0; tr_pass <= 0; tr_n <= 0; tr_good <= 0; tr_w1 <= 0;
      cap_fail_a <= 0; cap_fail_b <= 0;
    end else begin
      cmd    <= CMD_NOP;
      if (busy != 0) busy <= busy - 1'b1;
      if (ref_cnt != 10'h3FF) ref_cnt <= ref_cnt + 1'b1;
      ref_due   <= (ref_cnt >= REF_PERIOD);
      ref_early <= (ref_cnt >= REF_EARLY);
      ref_force <= (ref_cnt >= REF_FORCE);
      if (start_rise) start_pend <= 1;
      since_start <= next_start;
      win_ref <= (next_start >= WIN_LO) && (next_start <= WIN_HI);
      win_dk  <= ((next_start >= WIN_LO) && (next_start <= DK_HI)) || (next_start == 6'd63);
      if (!dl_req_q) dl_ack <= 0;
      if (!raw_req_q) raw_ack <= 0;
      if (!dk_req_q) dk_ack <= 0;
      if (state != S_INIT) sd_addr[12:11] <= 2'b00;

      case (state)
        S_INIT: begin
          sd_addr[12:11] <= 2'b11;
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

        S_TRAIN: begin
          seq <= seq + 1'b1;
          case (tr_step)
            2'd0: begin
              if (seq == 4'd0) begin cmd <= CMD_ACTIVE; sd_ba <= TR_BANK; sd_addr <= TR_ROW; end
              if (seq == 4'd2) begin
                cmd <= CMD_WRITE; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b0, 1'b0, TR_COL};
              end
              if (seq == 4'd3) begin
                cmd <= CMD_WRITE; sd_ba <= TR_BANK; sd_addr <= {2'b00, 1'b1, 1'b0, TR_COL | 9'd1};
              end
              if (seq == 4'd9) begin tr_step <= 1; seq <= 0; end
            end
            2'd1: begin
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
            default: begin
              if (seq == 4'd0) begin
                if (!tr_pass) begin
                  cap_ok[1] <= (tr_fail == 0); cap_fail_a <= tr_fail;
                  cap_sel <= 1;
                end else begin
                  cap_ok[0] <= (tr_fail == 0); cap_fail_b <= tr_fail;
                  cap_sel <= (cap_fail_a == 0) ? 1'b0 : (tr_fail == 0) ? 1'b1 : (tr_fail < cap_fail_a);
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

        S_IDLE: begin
          if (busy == 0) begin
            if (go) begin
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= xs_be; a_wdata <= xs_wdata;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0;
              state <= S_ACC;
            end else if (ref_due || (ref_early && win_ref)) begin
              cmd <= CMD_REFRESH; busy <= REF_BUSY; ref_cnt <= 0;
            end else if (dl_req_q && !dl_ack) begin
              cmd <= CMD_ACTIVE; sd_ba <= d_bank; sd_addr <= d_row;
              seq <= 1; busy <= ACT_BUSY;
              state <= S_DL;
            end else if (dk_req_q && !dk_ack && win_dk) begin
              cmd <= CMD_ACTIVE; sd_ba <= k_bank; sd_addr <= k_row;
              k_we_r <= xs_dk_we; k_bank_r <= k_bank; k_col_r <= k_col; k_wdata_r <= xs_dk_wdata;
              seq <= 1; busy <= ACT_BUSY;
              state <= S_DK;
            end else if (raw_req_q && !raw_ack) begin
              if (r_kind) begin cmd <= CMD_PRECHARGE; sd_addr <= 13'h0400; busy <= 4'd6; end
              else begin cmd <= CMD_ACTIVE; sd_ba <= r_bank; sd_addr <= r_row; busy <= ACT_BUSY; end
              seq <= 1; state <= S_RAW;
            end
          end
        end

        S_ACC: begin
          seq <= seq + 1'b1;
          if (!a_we) begin
            if (seq == 4'd2) begin cmd <= CMD_READ; sd_ba <= a_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, a_col_r}; end
            if (seq == 4'd7) cpu_rdata[31:16] <= dq_m;
            if (seq == 4'd8) begin
              cpu_rdata[15:0] <= dq_m; cpu_ack <= req_q;
              state <= S_DONE;
            end
          end else begin
            if (!a_written) begin
              if (seq == 4'd15) seq <= 4'd15;
              if (req_q && seq >= 4'd2) begin
                cmd <= CMD_WRITE; sd_ba <= a_bank_r; sd_addr <= {~a_be[3:2], 1'b0, 1'b0, a_col_r};
                a_written <= 1; seq <= 4'd3; cpu_ack <= 1;
                busy <= 4'd6;
              end else if (seq >= 4'd5) begin
                cmd <= CMD_PRECHARGE; sd_ba <= a_bank_r; sd_addr[10] <= 1'b0;
                busy <= 4'd2; state <= S_IDLE;
              end
            end else begin
              if (seq == 4'd3) begin
                cmd <= CMD_WRITE; sd_ba <= a_bank_r; sd_addr <= {~a_be[1:0], 1'b1, 1'b0, a_col_r | 9'd1};
              end
              if (seq == 4'd4) state <= S_DONE;
            end
          end
        end

        S_DONE: begin
          if (req_q && !start_pend) cpu_ack <= 1;
          else begin
            cpu_ack <= 0;
            if (cpu_ack) state <= S_IDLE;
            else if (since_start == 6'd63) state <= S_IDLE;
            else if (go) begin
              cmd <= CMD_ACTIVE; sd_ba <= a_bank; sd_addr <= a_row;
              a_we <= we_q; a_written <= 0; a_bank_r <= a_bank; a_col_r <= a_col;
              a_be <= xs_be; a_wdata <= xs_wdata;
              seq <= 1; busy <= ACT_BUSY; start_pend <= 0;
              state <= S_ACC;
            end
          end
        end

        S_DL: begin
          seq <= seq + 1'b1;
          if (seq == 4'd2) begin
            cmd <= CMD_WRITE; sd_ba <= d_bank; sd_addr <= {2'b00, 1'b1, 1'b0, d_col};
            dl_ack <= 1;
          end
          if (seq == 4'd4) state <= S_IDLE;
        end

        S_DK: begin
          seq <= seq + 1'b1;
          if (seq == 4'd2) begin
            cmd <= k_we_r ? CMD_WRITE : CMD_READ; sd_ba <= k_bank_r; sd_addr <= {2'b00, 1'b1, 1'b0, k_col_r};
            if (k_we_r) dk_ack <= 1;
          end
          if (k_we_r && seq == 4'd4) state <= S_IDLE;
          if (!k_we_r && seq == 4'd7) begin dk_rdata <= dq_m; dk_ack <= 1; state <= S_IDLE; end
        end

        S_RAW: begin
          seq <= seq + 1'b1;
          if (r_kind) begin
            if (seq == 4'd2) begin cmd <= CMD_LOAD_MODE; sd_addr <= r_mode; sd_ba <= 0; end
            if (seq == 4'd4) begin raw_ack <= 1; state <= S_IDLE; end
          end else begin
            if (seq == 4'd2) begin
              cmd <= r_read ? CMD_READ : CMD_WRITE; sd_ba <= r_bank;
              sd_addr <= {2'b00, r_ap && !(r_second && !r_read), 1'b0, r_col};
            end
            if (seq == 4'd3 && r_second && !r_read) begin
              cmd <= CMD_WRITE; sd_ba <= r_bank; sd_addr <= {2'b00, r_ap, 1'b0, r_col | 9'd1};
            end
            if (seq >= 4'd2 && seq <= 4'd5)
              sd_addr[12:11] <= r_dqm[2 * r_k +: 2];
            if (r_read && seq == 4'd7) cpu_rdata[31:16] <= dq_m;
            if (r_read && seq == 4'd8) cpu_rdata[15:0]  <= dq_m;
            if (seq == 4'd7 && !r_ap) begin
              cmd <= CMD_PRECHARGE; sd_ba <= r_bank; sd_addr[10] <= 1'b0; busy <= 4'd3;
            end
            if (seq == 4'd9) begin raw_ack <= 1; state <= S_IDLE; end
          end
        end

        default: state <= S_IDLE;
      endcase

      oe_pre <= 1'b0;
      case (state)
        S_TRAIN: if (tr_step == 2'd0) begin
          oe_pre <= 1'b1; dq_pre <= (seq == 4'd2) ? TR_W2 : TR_W1;
        end
        S_ACC: if (a_we) begin
          oe_pre <= 1'b1;
          dq_pre <= (a_written || (req_q && seq >= 4'd2)) ? a_wdata[15:0] : a_wdata[31:16];
        end
        S_DL: begin oe_pre <= 1'b1; dq_pre <= xs_dl_data; end
        S_DK: if (k_we_r) begin oe_pre <= 1'b1; dq_pre <= k_wdata_r; end
        S_RAW: if (!r_kind) begin
          oe_pre <= (seq >= 4'd1 && seq <= 4'd4) && r_oe[r_kn] && !r_read;
          dq_pre <= r_sel[r_kn] ? r_w1 : r_w0;
        end
        default: ;
      endcase
      if (dbg_dqm_force && state != S_INIT && !(state == S_RAW && r_kind)) sd_addr[12:11] <= 2'b11;
    end

endmodule
