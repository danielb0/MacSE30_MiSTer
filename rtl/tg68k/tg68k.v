// tg68k.v - the TG68K kernel on the 68030 bus

`timescale 1ns/1ps

module tg68k (
  input         clk,
  input         phi1,
  input         phi2,
  input         reset_n,

  output        ecs,
  output [31:0] cpu_addr,
  output        cpu_as_n,
  output        cpu_ds_n,
  output        cpu_rw_n,
  output  [2:0] cpu_fc,
  output  [1:0] cpu_siz,
  output [31:0] cpu_dout,
  input  [31:0] cpu_din,
  input   [1:0] dsack_n,
  input         berr,
  input   [2:0] ipl_n,
  input         cdis,
  input         pace_en,
  input         post_en,

  output        reset_out_n,
  output        halted,
  output [31:0] dbg_d6,
  output [31:0] dbg_d7,
  output [56:0] dbg_exc,
  output [35:0] dbg_pace,
  output [63:0] dbg_cache,
  output [55:0] dbg_mmuf
);

  wire        k_clkena, k_beat_valid;
  wire [31:0] k_din, k_dout, k_addr, k_addr_log, k_cacr, k_cache_op_addr;
  wire        k_ci, k_rmc, k_wronly, k_dibsub;
  wire  [1:0] k_dsack, k_busstate, k_siz;
  wire        k_nwr, k_nreset_out, k_clr_berr, k_cp_berr_ack;
  wire  [2:0] k_fc;
  wire        k_pmmu_busy, k_pmmu_fault, k_make_berr, k_trap_berr, k_halted;
  wire        k_exc_take;
  wire [31:0] k_f_addr;
  wire [15:0] k_f_mmusr;
  wire  [2:0] k_f_fc;
  wire        k_f_rw, k_f_insn, k_trap_mmu_berr;
  wire        k_decode;
  wire        pace_stall;
  wire [31:0] k_trap_vector;
  wire [15:0] k_opcode;
  wire [31:0] k_opcode_pc;
  wire        w_req, w_we, w_berr;
  wire [31:0] w_addr, w_wdat;
  reg         w_ack;
  reg  [31:0] w_data;
  reg         k_berr;

  TG68KdotC_Kernel #(
    .SR_Read(2), .VBR_Stackframe(2), .extAddr_Mode(2), .MUL_Mode(2), .DIV_Mode(2),
    .BitField(2), .BarrelShifter(2), .MUL_Hardware(1), .DATA_WIDTH(32)
  ) kernel (
    .clk(clk), .nReset(reset_n), .clkena_in(k_clkena), .beat_valid(k_beat_valid),
    .data_in(k_din), .dsack(k_dsack), .IPL(ipl_n), .IPL_autovector(1'b1), .berr(k_berr), .CPU(2'b10),
    .addr_out(k_addr), .addr_log_out(k_addr_log), .data_write(k_dout), .siz(k_siz), .nWr(k_nwr),
    .CACR_out(k_cacr), .cache_op_addr(k_cache_op_addr), .pmmu_cache_inhibit(k_ci), .rmc_out(k_rmc), .wronly_rd_out(k_wronly), .dib_sub_out(k_dibsub),
    .busstate(k_busstate), .FC(k_fc), .nResetOut(k_nreset_out), .clr_berr(k_clr_berr), .cp_berr_ack(k_cp_berr_ack),
    .pmmu_walker_req(w_req), .pmmu_walker_we(w_we), .pmmu_walker_addr(w_addr), .pmmu_walker_wdat(w_wdat),
    .pmmu_walker_ack(w_ack), .pmmu_walker_data(w_data), .pmmu_walker_berr(w_berr),
    .debug_pmmu_busy(k_pmmu_busy), .debug_pmmu_fault(k_pmmu_fault),
    .debug_make_berr(k_make_berr), .debug_trap_berr(k_trap_berr), .debug_cpu_halted(k_halted),
    .debug_regfile_d6(dbg_d6), .debug_regfile_d7(dbg_d7),
    .debug_exc_take(k_exc_take), .debug_trap_vector(k_trap_vector), .debug_opcode(k_opcode), .debug_opcode_pc(k_opcode_pc),
    .debug_decodeOPC(k_decode),
    .debug_pmmu_fault_addr(k_f_addr), .debug_pmmu_fault_mmusr(k_f_mmusr), .debug_pmmu_fault_fc(k_f_fc),
    .debug_pmmu_fault_rw(k_f_rw), .debug_pmmu_fault_is_insn(k_f_insn), .debug_trap_mmu_berr(k_trap_mmu_berr)
  );
  reg  [52:0] mmuf_q = 53'd0;
  always @(posedge clk) if (k_pmmu_fault) mmuf_q <= {k_f_insn, k_f_rw, k_f_fc, k_f_mmusr, k_f_addr};
  assign dbg_mmuf = {1'b0, k_trap_berr, k_trap_mmu_berr, mmuf_q};
  assign dbg_exc = {k_exc_take, k_trap_vector[9:2], k_opcode, k_opcode_pc};
  assign reset_out_n = k_nreset_out;
  assign halted = k_halted;

  reg         walk;
  reg   [2:0] walk_done;
  reg  [31:0] walk_buf;
  wire        k_req  = (k_busstate != 2'b01);
  wire        park   = k_pmmu_busy || k_pmmu_fault || w_req;
  reg         post;
  reg  [31:0] pb_addr;
  reg  [31:0] pb_dout;
  reg   [2:0] pb_rem;
  reg   [2:0] pb_fc;
  wire        wsel   = !post && (walk || (w_req && !w_ack));
  wire        eff_req  = post || wsel || (k_req && !park);
  wire [31:0] eff_addr = post ? pb_addr : wsel ? {w_addr[31:2], walk_done[1:0]} : k_addr;
  wire        eff_rw   = post ? 1'b0 : wsel ? !w_we : k_nwr;
  wire  [2:0] eff_fc   = post ? pb_fc : wsel ? 3'd5 : k_fc;
  wire  [1:0] eff_siz  = post ? pb_rem[1:0] :
                         wsel ? (walk_done == 3'd3 ? 2'b01 : walk_done == 3'd2 ? 2'b10 : walk_done == 3'd1 ? 2'b11 : 2'b00) : k_siz;
  wire  [7:0] w_r0 = walk_done == 0 ? w_wdat[31:24] : walk_done == 1 ? w_wdat[23:16] : walk_done == 2 ? w_wdat[15:8] : w_wdat[7:0];
  wire  [7:0] w_r1 = walk_done == 0 ? w_wdat[23:16] : walk_done == 1 ? w_wdat[15:8]  : w_wdat[7:0];
  wire  [7:0] w_r2 = walk_done == 0 ? w_wdat[15:8]  : w_wdat[7:0];
  wire  [7:0] w_r3 = w_wdat[7:0];
  wire [31:0] w_dout = (walk_done == 0) ? {w_r0, w_r1, w_r2, w_r3} :
                       (walk_done == 1) ? {w_r0, w_r0, w_r1, w_r2} :
                       (walk_done == 2) ? {w_r0, w_r1, w_r0, w_r1} : {w_r0, w_r0, w_r1, w_r0};
  wire [31:0] eff_dout = post ? pb_dout : wsel ? w_dout : k_dout;

  wire        cpu_space = (eff_fc == 3'd7);
  wire        iack      = cpu_space && (eff_addr[19:16] == 4'hF);
  wire        cp_fpu    = cpu_space && (eff_addr[19:13] == 7'b0010_001);
  wire        cp_local  = cpu_space && !cp_fpu;
  reg   [2:0] s;
  reg         as_n_r, ds_n_r;
  reg  [31:0] din_r;
  reg   [1:0] dsack_r;
  reg         ack_pending, ack_berr;
  reg         berr_hold;

  wire        k_fetch  = !wsel && (k_busstate == 2'b00) && !park;
  wire        k_dread  = !wsel && (k_busstate == 2'b10) && !park;
  wire        k_dwrite = !wsel && (k_busstate == 2'b11) && !park;
  wire        i_hit, d_hit;
  wire [31:0] i_q, d_q;
  wire        f_hit    = k_fetch && i_hit;
  wire        r_hit    = k_dread && !k_rmc && d_hit && (k_fc != 3'd7);
  wire        z_hit    = k_dread && k_wronly;
  wire        s_hit    = (k_dread || k_dwrite) && k_dibsub;
  wire        any_hit  = f_hit || r_hit || z_hit || s_hit;
  reg         hit_ack;
  reg         hit_d;
  reg         hit_z;
  reg         cyc_fill;
  reg         cyc_dfill;
  reg  [31:2] cyc_la;
  reg   [2:0] cyc_fc;
  wire        fill_ok  = phi2 && (s == 3'd5) && !berr && (dsack_n == 2'b00);
  wire        i_fill   = fill_ok && cyc_fill;
  wire        d_fill   = fill_ok && cyc_dfill;
  wire  [2:0] w_size   = (k_siz == 2'b00) ? 3'd4 : {1'b0, k_siz};
  wire  [2:0] w_nb     = (w_size > 3'd4 - k_addr[1:0]) ? 3'd4 - k_addr[1:0] : w_size;
  wire  [3:0] w_mask   = (w_nb == 3'd1) ? 4'b1000 : (w_nb == 3'd2) ? 4'b1100 : (w_nb == 3'd3) ? 4'b1110 : 4'b1111;
  wire  [3:0] d_wbe    = w_mask >> k_addr[1:0];
  wire        s1_take  = phi2 && (s == 3'd0) && !post && !any_hit && !ack_pending && !hit_ack && eff_req && !pace_stall;
  wire        pb_take  = phi2 && (s == 3'd0) && post && !ack_pending;
  wire        d_wr     = s1_take && k_dwrite && !k_ci && (k_fc != 3'd7);
  wire        d_inv    = phi1 && k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post && !k_nwr && (k_fc != 3'd7);

  wire        pb_vid   = (k_addr[31:24] == 8'hFE);
  wire        k_post   = post_en && k_dwrite && !k_rmc && (k_fc != 3'd7) && ((k_addr[31:30] == 2'b00) || pb_vid);
  reg         post_ack;
  reg  [31:0] pb_lanes;
  reg   [1:0] pb_lane;
  reg   [2:0] pb_n;
  wire  [1:0] pb_ln    = pb_lane + 2'd1;
  wire  [7:0] pb_nbyte = pb_lanes[31 - 8 * pb_ln -: 8];
  se30_cache030 cache (
    .clk(clk), .reset_n(reset_n),
    .cacr(k_cacr[13:0]), .caar(k_cache_op_addr[7:2]), .cdis(cdis),
    .la(k_addr_log[31:2]), .fc(k_fc), .i_hit(i_hit), .i_q(i_q),
    .i_fill(i_fill), .fill_la(cyc_la), .fill_fc(cyc_fc), .fill_data(cpu_din),
    .d_hit(d_hit), .d_q(d_q), .d_fill(d_fill),
    .d_wr(d_wr), .d_wbe(d_wbe), .d_wdata(k_dout), .d_wlong(k_siz == 2'b00 && k_addr[1:0] == 2'b00),
    .d_inv(d_inv));

  assign ecs      = reset_n && (s == 3'd0) && !ack_pending &&
                    (post || (eff_req && !hit_ack && !any_hit && !pace_stall));
  assign cpu_addr = eff_addr;
  assign cpu_as_n = as_n_r;
  assign cpu_ds_n = ds_n_r;
  assign cpu_rw_n = eff_rw;
  assign cpu_fc   = eff_fc;
  assign cpu_siz  = eff_siz;
  assign cpu_dout = eff_dout;

  wire  [2:0] w_room = (dsack_r == 2'b10) ? 3'd1 : (dsack_r == 2'b01) ? 3'd2 - {2'b0, walk_done[0]} : 3'd4 - walk_done;
  wire  [2:0] w_n    = (w_room > 3'd4 - walk_done) ? 3'd4 - walk_done : w_room;
  wire  [1:0] w_first = (dsack_r == 2'b10) ? 2'd0 : (dsack_r == 2'b01) ? {1'b0, walk_done[0]} : walk_done[1:0];
  wire [31:0] w_lane = (w_first == 0) ? din_r : (w_first == 1) ? {din_r[23:0], 8'h0} : (w_first == 2) ? {din_r[15:0], 16'h0} : {din_r[7:0], 24'h0};
  integer k;
  reg  [31:0] w_long;
  always @* begin
    w_long = walk_buf;
    for (k = 0; k < 4; k = k + 1)
      if (k >= walk_done && k < walk_done + w_n)
        w_long[31-8*k -: 8] = w_lane[31-8*(k-walk_done) -: 8];
  end

  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      s <= 0; as_n_r <= 1; ds_n_r <= 1; din_r <= 0; dsack_r <= 2'b11;
      ack_pending <= 0; ack_berr <= 0; walk <= 0; walk_done <= 0; walk_buf <= 0;
      w_ack <= 0; w_data <= 0; berr_hold <= 0;
      hit_ack <= 0; hit_d <= 0; hit_z <= 0; cyc_fill <= 0; cyc_dfill <= 0; cyc_la <= 0; cyc_fc <= 0;
      post <= 0; post_ack <= 0; pb_addr <= 0; pb_dout <= 0; pb_lanes <= 0; pb_lane <= 0; pb_n <= 0; pb_rem <= 0; pb_fc <= 0;
    end else begin
      w_ack <= 0;
      if (phi1) begin
        ack_pending <= 0; ack_berr <= 0; hit_ack <= 0; post_ack <= 0;
        if (ack_pending && walk) begin
          if (ack_berr) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else if (walk_done + w_n >= 3'd4) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else begin walk_done <= walk_done + w_n; walk_buf <= w_long; end
        end
        if (s == 3'd2) s <= 3'd3;
        if (s == 3'd4) s <= 3'd5;
        if (k_make_berr || k_trap_berr || k_cp_berr_ack) berr_hold <= 0;
      end
      if (phi2) begin
        if (post && any_hit && !hit_ack && !post_ack && !pace_stall) begin
          hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit || s_hit; dsack_r <= 2'b00;
        end
        case (s)
          3'd0: if (post) begin
                  as_n_r <= 0; ds_n_r <= 1'b1; s <= 3'd2;
                end else if (any_hit && !ack_pending && !hit_ack && !pace_stall) begin
                  hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit || s_hit; dsack_r <= 2'b00;
                end else if (eff_req && !hit_ack && !pace_stall) begin
                  if (w_req && !walk) begin walk <= 1; walk_done <= 0; walk_buf <= 0; end
                  as_n_r <= 0; ds_n_r <= !eff_rw ? 1'b1 : 1'b0; s <= 3'd2;
                  cyc_fill  <= k_fetch && !k_ci && (k_fc != 3'd7);
                  cyc_dfill <= k_dread && !k_ci && (k_fc != 3'd7);
                  cyc_la <= k_addr_log[31:2]; cyc_fc <= k_fc;
                  if (k_post) begin
                    post <= 1; post_ack <= 1; dsack_r <= 2'b00;
                    pb_addr <= k_addr; pb_dout <= k_dout; pb_lanes <= k_dout; pb_lane <= k_addr[1:0];
                    pb_n <= pb_vid ? w_nb : 3'd1; pb_rem <= w_size; pb_fc <= k_fc;
                  end
                end
          3'd3: begin
                  ds_n_r <= 0;
                  if (cp_local) begin
                    if (iack) begin dsack_r <= 2'b00; s <= 3'd4; end
                    else begin
                      as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                      if (!walk) berr_hold <= 1;
                    end
                  end else if (berr && post) begin
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; post <= 0; berr_hold <= 1;
                  end else if (berr) begin
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                    dsack_r <= dsack_n; if (!walk) berr_hold <= 1;
                  end else if (dsack_n != 2'b11) s <= 3'd4;
                end
          3'd5: if (post) begin
                  as_n_r <= 1; ds_n_r <= 1; s <= 3'd0;
                  if (berr || pb_n == 3'd1) begin post <= 0; if (berr) berr_hold <= 1; end
                  else begin
                    pb_n <= pb_n - 3'd1; pb_rem <= pb_rem - 3'd1; pb_addr <= pb_addr + 32'd1;
                    pb_lane <= pb_ln; pb_dout <= {4{pb_nbyte}};
                  end
                end else begin
                  din_r <= cpu_din; if (!cp_local) dsack_r <= dsack_n;
                  as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1;
                  if (berr) begin ack_berr <= 1; if (!walk) berr_hold <= 1; end
                end
          default: ;
        endcase
      end
    end

  wire k_cycle_ack = (ack_pending || hit_ack || post_ack) && !walk;
  wire k_internal  = (k_busstate == 2'b01) && !k_pmmu_busy && !w_req && !walk && !pace_stall;
  wire k_force     = k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post;
  assign k_clkena     = phi1 && (k_cycle_ack || k_internal || k_force);
  assign k_beat_valid = k_cycle_ack || k_internal;
  assign k_din   = !hit_ack ? din_r : hit_z ? 32'h0 : hit_d ? d_q : i_q;

  reg  [15:0] p_op;
  reg  [31:0] p_pc;
  reg   [5:0] p_tail;
  reg   [8:0] p_cnt;
  reg   [7:0] p_rcred;
  reg   [7:0] p_wcred;
  reg   [7:0] p_fcred;
  reg   [7:0] p_xcred;
  reg         pb_old;
  reg         p_rel;
  reg   [4:0] p_cyc;
  reg         p_cont;
  reg  [29:0] p_last_la;
  reg   [1:0] p_last_ds;
  reg         p_last_d;
  wire        d_ea_on, d_ea_ophead;
  wire  [4:0] d_ea_h, d_op_h;
  wire  [1:0] d_ea_t, d_op_t, d_br, d_mvm;
  wire  [7:0] d_row;
  wire  [5:0] d_ea_cc;
  wire  [6:0] d_op_cc, d_op_cc_t;
  se30_pace030 pace (
    .op(p_op), .ea_on(d_ea_on), .ea_ophead(d_ea_ophead), .ea_h(d_ea_h), .ea_t(d_ea_t), .ea_cc(d_ea_cc),
    .op_h(d_op_h), .op_t(d_op_t), .op_cc(d_op_cc), .op_cc_t(d_op_cc_t), .br(d_br), .mvm(d_mvm), .row(d_row));
  reg         r_ea_on;
  reg   [5:0] r_ea_h;
  reg   [1:0] r_ea_t, r_op_t, r_br, r_mvm;
  reg   [4:0] r_op_h;
  reg   [5:0] r_ea_cc;
  reg   [6:0] r_op_cc, r_op_cc_t;
  reg         r_taken;
  reg   [7:0] r_row;
  wire  [2:0] p_ilen  = (d_br == 2'd2) ? 3'd4 : (p_op[7:0] == 8'h00) ? 3'd4 : (p_op[7:0] == 8'hFF) ? 3'd6 : 3'd2;
  always @(posedge clk) begin
    r_ea_on  <= d_ea_on && (d_ea_cc != 6'd0);
    r_ea_h   <= {1'b0, d_ea_h} + (d_ea_ophead ? {1'b0, d_op_h} : 6'd0);
    r_ea_t   <= d_ea_t; r_ea_cc <= d_ea_cc;
    r_op_h   <= d_op_h; r_op_t <= d_op_t; r_op_cc <= d_op_cc; r_op_cc_t <= d_op_cc_t;
    r_br     <= d_br; r_mvm <= d_mvm; r_row <= d_row;
    r_taken  <= (d_br != 2'd0) && (k_opcode_pc != p_pc + {29'd0, p_ilen});
  end
  wire  [5:0] p_ov_ea  = (r_ea_h < p_tail) ? r_ea_h : p_tail;
  wire  [8:0] p_ea_tl  = {7'd0, r_ea_t} + {1'b0, p_rcred};
  wire  [8:0] p_t_mid  = r_ea_on ? p_ea_tl : {3'd0, p_tail};
  wire  [8:0] p_ov_op  = ({4'd0, r_op_h} < p_t_mid) ? {4'd0, r_op_h} : p_t_mid;
  wire  [6:0] p_op_clk = r_taken ? r_op_cc_t : r_op_cc;
  wire  [9:0] p_credit = {2'd0, p_rcred} + {2'd0, p_wcred} + {2'd0, p_fcred} + {2'd0, p_xcred};
  wire  [5:0] p_ov_ea_c = (p_ov_ea > r_ea_cc) ? r_ea_cc : p_ov_ea;
  wire  [8:0] p_ov_op_c = (p_ov_op > {2'd0, p_op_clk}) ? {2'd0, p_op_clk} : p_ov_op;
  wire  [9:0] p_budget = (r_ea_on ? {4'd0, r_ea_cc} - {4'd0, p_ov_ea_c} : 10'd0) + ({3'd0, p_op_clk} - {1'b0, p_ov_op_c}) + p_credit;
  wire  [9:0] p_tail_n = {8'd0, r_op_t} + {2'd0, p_wcred} + (r_ea_on ? 10'd0 : {2'd0, p_rcred});
  wire        p_due    = ({1'b0, p_cnt} >= p_budget);
  wire        p_go     = p_rel || p_due || !pace_en;
  assign      pace_stall = k_decode && !p_go;
  wire        p_release = phi1 && k_decode && !p_rel && p_go;
  assign      dbg_pace  = {p_release, r_row, p_cnt, p_budget, p_fcred};
  wire  [4:0] p_edges  = p_cyc + 5'd1;
  wire  [4:0] p_len    = {1'b0, p_edges[4:1]} + 5'd1;
  wire  [5:0] p_addw   = p_cont ? {1'b0, p_len} : {1'b0, p_len} - 6'd2;
  wire  [5:0] p_add    = p_addw + {4'd0, (cyc_fc != 3'd6) ? r_mvm : 2'd0};
  wire  [6:0] p_tail_x = {1'b0, p_tail} + {1'b0, p_addw};
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
      p_op <= 16'h0; p_pc <= 32'h0; p_tail <= 6'd0; p_cnt <= 9'h1FF; p_rcred <= 8'd0; p_wcred <= 8'd0; p_fcred <= 8'd0; p_rel <= 1'b0;
      p_xcred <= 8'd0; pb_old <= 1'b0;
      p_cyc <= 5'd0; p_cont <= 1'b0; p_last_la <= 30'd0; p_last_ds <= 2'b00; p_last_d <= 1'b0;
    end else begin
      if (s != 3'd0 && p_cyc != 5'h1F) p_cyc <= p_cyc + 5'd1;
      if (phi1) begin
        if (p_cnt != 9'h1FF) p_cnt <= p_cnt + 9'd1;
        if (k_decode && !p_rel && p_go) begin
          p_op <= k_opcode; p_pc <= k_opcode_pc; p_tail <= (p_tail_n > 10'd63) ? 6'd63 : p_tail_n[5:0];
          p_cnt <= 9'd1; p_rcred <= 8'd0; p_wcred <= 8'd0; p_fcred <= 8'd0;
          p_xcred <= 8'd0; if (post) pb_old <= 1'b1;
          p_rel <= !k_clkena;
        end else if (k_clkena && k_decode) p_rel <= 1'b0;
      end
      if (phi2) begin
        if (s1_take) begin
          p_cyc <= 5'd0;
          p_cont <= !wsel && (k_fc != 3'd6) && p_last_d && (p_last_ds != 2'b00) && (k_addr[31:2] == p_last_la);
          if (k_post) pb_old <= 1'b0;
        end
        if (pb_take) begin p_cyc <= 5'd0; p_cont <= 1'b1; end
        if (s == 3'd5) begin
          if (post && pb_old) begin
            if (p_xcred + {2'd0, p_addw} < 9'd255) p_xcred <= p_xcred + {2'd0, p_addw}; else p_xcred <= 8'hFF;
            p_tail <= (p_tail_x > 7'd63) ? 6'd63 : p_tail_x[5:0];
          end else if (cyc_fc == 3'd6) begin
            if (p_fcred + {2'd0, p_add} < 9'd255) p_fcred <= p_fcred + {2'd0, p_add}; else p_fcred <= 8'hFF;
          end else if (!eff_rw) begin
            if (p_wcred + {2'd0, p_add} < 9'd255) p_wcred <= p_wcred + {2'd0, p_add}; else p_wcred <= 8'hFF;
          end else begin
            if (p_rcred + {2'd0, p_add} < 9'd255) p_rcred <= p_rcred + {2'd0, p_add}; else p_rcred <= 8'hFF;
          end
          p_last_d <= (cyc_fc != 3'd6); p_last_ds <= dsack_n; p_last_la <= cyc_la;
        end
      end
    end

  reg [23:0] n_ihit, n_dhit;
  always @(posedge clk or negedge reset_n)
    if (!reset_n) begin n_ihit <= 0; n_dhit <= 0; end
    else if (phi1 && hit_ack && !hit_z) begin
      if (hit_d) n_dhit <= n_dhit + 1'd1; else n_ihit <= n_ihit + 1'd1;
    end
  assign dbg_cache = {cdis, 1'b0, k_cacr[13:0], n_ihit, n_dhit};
  assign k_dsack = dsack_r;
  assign w_berr  = ack_berr && walk;
  always @* k_berr = berr_hold && !(k_make_berr || k_trap_berr);

endmodule
