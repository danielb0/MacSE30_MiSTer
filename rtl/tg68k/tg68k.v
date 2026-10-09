// tg68k.v - the SE/30's 68030: the TG68K kernel (32-bit shape, with the PMMU) running its beats
// as 68030 bus cycles on the C16M half-clock grid (S0-S5; DSACK and BERR sampled from S3), with
// the caches, the write pending buffer and the pace that holds each instruction to the UM's time.

`timescale 1ns/1ps

module tg68k (
  input         clk,                   // 2 x C16M
  input         phi1,                  // C16M rising edge
  input         phi2,                  // C16M falling edge
  input         reset_n,

  // the 68030 bus
  output        ecs,                   // ECS*, active high here: S0 of a cycle that may follow
  output [31:0] cpu_addr,
  output        cpu_as_n,
  output        cpu_ds_n,
  output        cpu_rw_n,              // 1 = read
  output  [2:0] cpu_fc,
  output  [1:0] cpu_siz,
  output [31:0] cpu_dout,
  input  [31:0] cpu_din,
  input   [1:0] dsack_n,               // {DSACK1*, DSACK0*}
  input         berr,
  input   [2:0] ipl_n,
  input         cdis,                  // CDIS* asserted (VIA2 PB0 low): the caches disabled
  input         pace_en,               // hold each instruction to the 68030's time; low: unpaced
  input         post_en,               // the write pending buffer; low: every write waited for

  output        reset_out_n,           // the RESET instruction
  output        halted,                // double bus fault
  output [31:0] dbg_d6,                // debug: D6 and D7 (the ROM's test manager keeps a failed
  output [31:0] dbg_d7,                //   test's code there)
  output [56:0] dbg_exc,               // debug: {an exception taken (one clk), its vector number, the opcode, its PC}
  output [35:0] dbg_pace,              // debug: one instruction released by the pace: {release, its decoder row[7:0],
                                       //   clocks it took[8:0], its budget[9:0], its fetches' wait states[7:0]}
  output [63:0] dbg_cache,             // debug: {CDIS*, 1'b0, CACR[13:0], instruction hits[23:0], data hits[23:0]}
  output [55:0] dbg_mmuf               // debug: the PMMU's last fault: {1'b0, the bus BERR pending, an MMU bus error
                                       //   pending, then as latched at the fault: an instruction fetch, read, FC[2:0],
                                       //   its MMUSR-coded status[15:0], the logical address[31:0]}
);

  // ------------------------------------------------------------- kernel
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
  wire        k_decode;                // the kernel's decode beat is next (decodeOPC)
  wire        pace_stall;              // ... and the pace withholds it (below)
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
  // the fault as the PMMU raises it, latched while the fault line is up
  reg  [52:0] mmuf_q = 53'd0;
  always @(posedge clk) if (k_pmmu_fault) mmuf_q <= {k_f_insn, k_f_rw, k_f_fc, k_f_mmusr, k_f_addr};
  assign dbg_mmuf = {1'b0, k_trap_berr, k_trap_mmu_berr, mmuf_q};
  assign dbg_exc = {k_exc_take, k_trap_vector[9:2], k_opcode, k_opcode_pc};
  assign reset_out_n = k_nreset_out;
  assign halted = k_halted;

  // ----------------------------------------------------- the bus cycle
  // whose cycle: the walker's when it asks, else the kernel's once the PMMU has its address
  reg         walk;                    // a walker cycle is in progress (a long, in beats)
  reg   [2:0] walk_done;               // bytes of the walker's long moved so far
  reg  [31:0] walk_buf;
  // the walker is not selected in the clk w_ack is high (its request still the one served), and
  // a translation that has faulted parks the kernel's cycle: no bus cycle to an invalid page
  wire        k_req  = (k_busstate != 2'b01);
  wire        park   = k_pmmu_busy || k_pmmu_fault || w_req;
  // the write pending buffer: while it holds an
  // operand the bus is its, and nothing else starts
  reg         post;                    // a posted operand: from its first beat's S1 to its last beat's S5
  reg  [31:0] pb_addr;                 // the beat's address
  reg  [31:0] pb_dout;                 // ... its data
  reg   [2:0] pb_rem;                  // the operand's bytes from this beat on: the beat's SIZ
  reg   [2:0] pb_fc;
  wire        wsel   = !post && (walk || (w_req && !w_ack));   // the bus is the walker's
  wire        eff_req  = post || wsel || (k_req && !park);
  wire [31:0] eff_addr = post ? pb_addr : wsel ? {w_addr[31:2], walk_done[1:0]} : k_addr;
  wire        eff_rw   = post ? 1'b0 : wsel ? !w_we : k_nwr;
  wire  [2:0] eff_fc   = post ? pb_fc : wsel ? 3'd5 : k_fc;
  wire  [1:0] eff_siz  = post ? pb_rem[1:0] :
                         wsel ? (walk_done == 3'd3 ? 2'b01 : walk_done == 3'd2 ? 2'b10 : walk_done == 3'd1 ? 2'b11 : 2'b00) : k_siz;
  // the walker's write data as Table 7-5 places a long's remaining bytes
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
  wire        cp_local  = cpu_space && !cp_fpu;                  // answered here
  reg   [2:0] s;                       // 0 idle (S0), 2 after S1, 3 S3/wait, 4 after S4, 5 after S5
  reg         as_n_r, ds_n_r;
  reg  [31:0] din_r;
  reg   [1:0] dsack_r;
  reg         ack_pending, ack_berr;
  reg         berr_hold;

  // ------------------------------------------------------------ the caches
  // a fetch or data read that hits is answered from the cache, no cycle; a cachable miss fills
  // its entry at S5; a cachable write updates the data cache as its cycle starts
  wire        k_fetch  = !wsel && (k_busstate == 2'b00) && !park;
  wire        k_dread  = !wsel && (k_busstate == 2'b10) && !park;
  wire        k_dwrite = !wsel && (k_busstate == 2'b11) && !park;
  wire        i_hit, d_hit;
  wire [31:0] i_q, d_q;
  wire        f_hit    = k_fetch && i_hit;
  wire        r_hit    = k_dread && !k_rmc && d_hit && (k_fc != 3'd7);
  // the kernel's destination read for CLR, Scc and MOVE from SR/CCR, which a 68030 does not run:
  // answered here like a hit, no cycle
  wire        z_hit    = k_dread && k_wronly;
  // the data beat a bus-error handler completed in software: no cycle for it
  wire        s_hit    = (k_dread || k_dwrite) && k_dibsub;
  wire        any_hit  = f_hit || r_hit || z_hit || s_hit;
  reg         hit_ack;                 // a hit taken: the kernel is acknowledged at the next phi1
  reg         hit_d;                   // ... from the data cache
  reg         hit_z;                   // ... for a write-only instruction's read (z_hit)
  reg         cyc_fill;                // this cycle's long fills the instruction cache
  reg         cyc_dfill;               // ... the data cache
  reg  [31:2] cyc_la;
  reg   [2:0] cyc_fc;
  wire        fill_ok  = phi2 && (s == 3'd5) && !berr && (dsack_n == 2'b00);
  wire        i_fill   = fill_ok && cyc_fill;
  wire        d_fill   = fill_ok && cyc_dfill;
  // the write's bytes: from A1-A0, as many as SIZ says remain, to the long's end
  wire  [2:0] w_size   = (k_siz == 2'b00) ? 3'd4 : {1'b0, k_siz};
  wire  [2:0] w_nb     = (w_size > 3'd4 - k_addr[1:0]) ? 3'd4 - k_addr[1:0] : w_size;
  wire  [3:0] w_mask   = (w_nb == 3'd1) ? 4'b1000 : (w_nb == 3'd2) ? 4'b1100 : (w_nb == 3'd3) ? 4'b1110 : 4'b1111;
  wire  [3:0] d_wbe    = w_mask >> k_addr[1:0];
  // a cycle the kernel (or the walker) starts; the buffer's later beats are pb_take's
  wire        s1_take  = phi2 && (s == 3'd0) && !post && !any_hit && !ack_pending && !hit_ack && eff_req && !pace_stall;
  wire        pb_take  = phi2 && (s == 3'd0) && post && !ack_pending;
  wire        d_wr     = s1_take && k_dwrite && !k_ci && (k_fc != 3'd7);
  wire        d_inv    = phi1 && k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post && !k_nwr && (k_fc != 3'd7);   // k_force's terms (declared below)

  // ------------------------------------------- the write pending buffer
  // a kernel data write to RAM, ROM or the video card - ports that never bus-error - is acknowledged
  // at once and run by the buffer, in the beats the port needs
  wire        pb_vid   = (k_addr[31:24] == 8'hFE);
  // post_en low waits for every write (for a write that may bus-error)
  wire        k_post   = post_en && k_dwrite && !k_rmc && (k_fc != 3'd7) && ((k_addr[31:30] == 2'b00) || pb_vid);
  reg         post_ack;                // the kernel's acknowledge for its posted write, at the next phi1
  reg  [31:0] pb_lanes;                // the long as the kernel drove it: each byte on its own address's lane
  reg   [1:0] pb_lane;                 // the beat's lane in it
  reg   [2:0] pb_n;                    // beats left, this one's included
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

  // ECS (UM 5.6.2, 7.1.1): the S0 half-clock when a request is waiting and the bus is idle; the
  // memory controller starts its row access on it. Not while the last acknowledge is pending.
  assign ecs      = reset_n && (s == 3'd0) && !ack_pending &&
                    (post || (eff_req && !hit_ack && !any_hit && !pace_stall));
  assign cpu_addr = eff_addr;
  assign cpu_as_n = as_n_r;
  assign cpu_ds_n = ds_n_r;
  assign cpu_rw_n = eff_rw;
  assign cpu_fc   = eff_fc;
  assign cpu_siz  = eff_siz;
  assign cpu_dout = eff_dout;

  // the bytes a walker beat brings, from the lanes the port answered on
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
        // a completed walker beat: more beats, or the descriptor is in
        if (ack_pending && walk) begin
          if (ack_berr) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else if (walk_done + w_n >= 3'd4) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else begin walk_done <= walk_done + w_n; walk_buf <= w_long; end
        end
        if (s == 3'd2) s <= 3'd3;
        if (s == 3'd4) s <= 3'd5;
        if (k_make_berr || k_trap_berr || k_cp_berr_ack) berr_hold <= 0;   // (taken as no coprocessor)
      end
      if (phi2) begin
        // a hit while the buffer drains: the bus is the buffer's, the
        // caches are not (the posted write's own acknowledge goes first)
        if (post && any_hit && !hit_ack && !post_ack && !pace_stall) begin
          hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit || s_hit; dsack_r <= 2'b00;
        end
        case (s)
          3'd0: if (post) begin                                            // the buffer's next beat: S1
                  as_n_r <= 0; ds_n_r <= 1'b1; s <= 3'd2;
                end else if (any_hit && !ack_pending && !hit_ack && !pace_stall) begin   // a hit: no cycle
                  hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit || s_hit; dsack_r <= 2'b00;
                end else if (eff_req && !hit_ack && !pace_stall) begin       // S1
                  if (w_req && !walk) begin walk <= 1; walk_done <= 0; walk_buf <= 0; end
                  as_n_r <= 0; ds_n_r <= !eff_rw ? 1'b1 : 1'b0; s <= 3'd2;
                  cyc_fill  <= k_fetch && !k_ci && (k_fc != 3'd7);
                  cyc_dfill <= k_dread && !k_ci && (k_fc != 3'd7);
                  cyc_la <= k_addr_log[31:2]; cyc_fc <= k_fc;
                  if (k_post) begin                                          // posted: the buffer takes it from here
                    post <= 1; post_ack <= 1; dsack_r <= 2'b00;
                    pb_addr <= k_addr; pb_dout <= k_dout; pb_lanes <= k_dout; pb_lane <= k_addr[1:0];
                    pb_n <= pb_vid ? w_nb : 3'd1; pb_rem <= w_size; pb_fc <= k_fc;
                  end
                end
          3'd3: begin                                                      // S3 and the wait states
                  ds_n_r <= 0;
                  if (cp_local) begin                                        // AVEC, or no coprocessor
                    if (iack) begin dsack_r <= 2'b00; s <= 3'd4; end
                    else begin
                      as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                      if (!walk) berr_hold <= 1;
                    end
                  end else if (berr && post) begin
                    // not reachable: the operand ends, the
                    // fault is held to the kernel as a late BERR
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; post <= 0; berr_hold <= 1;
                  end else if (berr) begin
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                    dsack_r <= dsack_n; if (!walk) berr_hold <= 1;
                  end else if (dsack_n != 2'b11) s <= 3'd4;
                end
          3'd5: if (post) begin                                            // S5 of a posted beat: no acknowledge
                  as_n_r <= 1; ds_n_r <= 1; s <= 3'd0;
                  if (berr || pb_n == 3'd1) begin post <= 0; if (berr) berr_hold <= 1; end
                  else begin                                                 // the next byte, at the next address
                    pb_n <= pb_n - 3'd1; pb_rem <= pb_rem - 3'd1; pb_addr <= pb_addr + 32'd1;
                    pb_lane <= pb_ln; pb_dout <= {4{pb_nbyte}};
                  end
                end else begin                                             // S5: latch at the end of S4
                  din_r <= cpu_din; if (!cp_local) dsack_r <= dsack_n;
                  as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1;
                  if (berr) begin ack_berr <= 1; if (!walk) berr_hold <= 1; end
                end
          default: ;
        endcase
      end
    end

  // the kernel's acknowledge: its own completed cycle, a posted write's early one, an internal beat
  // once per C16M clock, or a force-released beat on a PMMU fault
  wire k_cycle_ack = (ack_pending || hit_ack || post_ack) && !walk;
  wire k_internal  = (k_busstate == 2'b01) && !k_pmmu_busy && !w_req && !walk && !pace_stall;
  wire k_force     = k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post;
  assign k_clkena     = phi1 && (k_cycle_ack || k_internal || k_force);
  assign k_beat_valid = k_cycle_ack || k_internal;
  assign k_din   = !hit_ack ? din_r : hit_z ? 32'h0 : hit_d ? d_q : i_q;

  // ------------------------------------------------------------ the pace
  // at the kernel's decode beat the step is withheld until the instruction just run has had its
  // budget: UM Equation 11-2 from se30_pace030.v's tables, plus its bus cycles' wait states.
  // Bus cycles and acknowledges are never delayed; pace_en low runs the kernel unpaced.
  reg  [15:0] p_op;      // the instruction running: its opcode ...
  reg  [31:0] p_pc;      // ... and address, latched at its release
  reg   [5:0] p_tail;    // the tail of the instruction before it, with its write cycles' wait states (saturating)
  reg   [8:0] p_cnt;     // C16M clocks since the release (saturating)
  reg   [7:0] p_rcred;   // the wait-state clocks of its data read cycles so far (saturating) ...
  reg   [7:0] p_wcred;   // ... of its write cycles, MOVEM's register clocks with them ...
  reg   [7:0] p_fcred;   // ... and of its instruction fetches (the no-cache case's W: budget only, no tail)
  reg   [7:0] p_xcred;   // ... and of the instruction before's posted write, completed after the release
  reg         pb_old;    // the posted operand's instruction has been released
  reg         p_rel;     // released: the decode beat may step
  reg   [4:0] p_cyc;     // clk edges of the cycle in progress (saturating)
  reg         p_cont;    // the cycle in progress continues an operand through a narrow port
  reg  [29:0] p_last_la; // the last data cycle's long address ...
  reg   [1:0] p_last_ds; // ... and port size
  reg         p_last_d;  // ... and that it was a data cycle
  wire        d_ea_on, d_ea_ophead;
  wire  [4:0] d_ea_h, d_op_h;
  wire  [1:0] d_ea_t, d_op_t, d_br, d_mvm;
  wire  [7:0] d_row;
  wire  [5:0] d_ea_cc;
  wire  [6:0] d_op_cc, d_op_cc_t;
  se30_pace030 pace (
    .op(p_op), .ea_on(d_ea_on), .ea_ophead(d_ea_ophead), .ea_h(d_ea_h), .ea_t(d_ea_t), .ea_cc(d_ea_cc),
    .op_h(d_op_h), .op_t(d_op_t), .op_cc(d_op_cc), .op_cc_t(d_op_cc_t), .br(d_br), .mvm(d_mvm), .row(d_row));
  // the decoder's answer, registered: settled two clocks before the earliest next decision
  reg         r_ea_on;
  reg   [5:0] r_ea_h;    // the EA's head, the op's included where the manual says "n + op head"
  reg   [1:0] r_ea_t, r_op_t, r_br, r_mvm;
  reg   [4:0] r_op_h;
  reg   [5:0] r_ea_cc;
  reg   [6:0] r_op_cc, r_op_cc_t;
  reg         r_taken;   // a branch: the next instruction is not the one that follows
  reg   [7:0] r_row;     // the decoder's row, for the profile (dbg_pace)
  wire  [2:0] p_ilen  = (d_br == 2'd2) ? 3'd4 : (p_op[7:0] == 8'h00) ? 3'd4 : (p_op[7:0] == 8'hFF) ? 3'd6 : 3'd2;
  always @(posedge clk) begin
    r_ea_on  <= d_ea_on && (d_ea_cc != 6'd0);
    r_ea_h   <= {1'b0, d_ea_h} + (d_ea_ophead ? {1'b0, d_op_h} : 6'd0);
    r_ea_t   <= d_ea_t; r_ea_cc <= d_ea_cc;
    r_op_h   <= d_op_h; r_op_t <= d_op_t; r_op_cc <= d_op_cc; r_op_cc_t <= d_op_cc_t;
    r_br     <= d_br; r_mvm <= d_mvm; r_row <= d_row;
    r_taken  <= (d_br != 2'd0) && (k_opcode_pc != p_pc + {29'd0, p_ilen});
  end
  wire  [5:0] p_ov_ea  = (r_ea_h < p_tail) ? r_ea_h : p_tail;                          // min(head, tail before)
  wire  [8:0] p_ea_tl  = {7'd0, r_ea_t} + {1'b0, p_rcred};                             // the EA part's tail, its reads' wait states in
  wire  [8:0] p_t_mid  = r_ea_on ? p_ea_tl : {3'd0, p_tail};
  wire  [8:0] p_ov_op  = ({4'd0, r_op_h} < p_t_mid) ? {4'd0, r_op_h} : p_t_mid;
  wire  [6:0] p_op_clk = r_taken ? r_op_cc_t : r_op_cc;
  wire  [9:0] p_credit = {2'd0, p_rcred} + {2'd0, p_wcred} + {2'd0, p_fcred} + {2'd0, p_xcred};
  // an overlap never exceeds its part's clocks (the tables' heads do not; a
  // branch's taken row may have fewer clocks than the fall-through row's head)
  wire  [5:0] p_ov_ea_c = (p_ov_ea > r_ea_cc) ? r_ea_cc : p_ov_ea;
  wire  [8:0] p_ov_op_c = (p_ov_op > {2'd0, p_op_clk}) ? {2'd0, p_op_clk} : p_ov_op;
  wire  [9:0] p_budget = (r_ea_on ? {4'd0, r_ea_cc} - {4'd0, p_ov_ea_c} : 10'd0) + ({3'd0, p_op_clk} - {1'b0, p_ov_op_c}) + p_credit;
  // the tail this instruction leaves: the op's, its writes' wait states in, and its reads' if it had no EA part
  wire  [9:0] p_tail_n = {8'd0, r_op_t} + {2'd0, p_wcred} + (r_ea_on ? 10'd0 : {2'd0, p_rcred});
  wire        p_due    = ({1'b0, p_cnt} >= p_budget);
  wire        p_go     = p_rel || p_due || !pace_en;
  assign      pace_stall = k_decode && !p_go;
  // the profile (dbg_pace): the instruction running ends at its release
  wire        p_release = phi1 && k_decode && !p_rel && p_go;
  assign      dbg_pace  = {p_release, r_row, p_cnt, p_budget, p_fcred};
  // a cycle's clocks: p_cyc + 1 clk edges with s != 0 at its S5, two a C16M, S0 and S1 before them
  wire  [4:0] p_edges  = p_cyc + 5'd1;
  wire  [4:0] p_len    = {1'b0, p_edges[4:1]} + 5'd1;                                   // C16M clocks
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
        if (k_decode && !p_rel && p_go) begin                             // the release
          p_op <= k_opcode; p_pc <= k_opcode_pc; p_tail <= (p_tail_n > 10'd63) ? 6'd63 : p_tail_n[5:0];
          p_cnt <= 9'd1; p_rcred <= 8'd0; p_wcred <= 8'd0; p_fcred <= 8'd0;     // this clock is the instruction's first
          p_xcred <= 8'd0; if (post) pb_old <= 1'b1;                       // a write still posted is the instruction before's
          p_rel <= !k_clkena;                                              // an internal beat steps now
        end else if (k_clkena && k_decode) p_rel <= 1'b0;                  // the decode beat taken
      end
      if (phi2) begin
        if (s1_take) begin
          p_cyc <= 5'd0;
          p_cont <= !wsel && (k_fc != 3'd6) && p_last_d && (p_last_ds != 2'b00) && (k_addr[31:2] == p_last_la);
          if (k_post) pb_old <= 1'b0;
        end
        if (pb_take) begin p_cyc <= 5'd0; p_cont <= 1'b1; end              // the buffer's later beats continue its operand
        if (s == 3'd5) begin
          if (post && pb_old) begin                                         // a posted beat after its instruction's release
            if (p_xcred + {2'd0, p_addw} < 9'd255) p_xcred <= p_xcred + {2'd0, p_addw}; else p_xcred <= 8'hFF;
            p_tail <= (p_tail_x > 7'd63) ? 6'd63 : p_tail_x[5:0];
          end else if (cyc_fc == 3'd6) begin                                // a fetch
            if (p_fcred + {2'd0, p_add} < 9'd255) p_fcred <= p_fcred + {2'd0, p_add}; else p_fcred <= 8'hFF;
          end else if (!eff_rw) begin                                        // a write: the operation's
            if (p_wcred + {2'd0, p_add} < 9'd255) p_wcred <= p_wcred + {2'd0, p_add}; else p_wcred <= 8'hFF;
          end else begin                                                     // a data read: the EA's
            if (p_rcred + {2'd0, p_add} < 9'd255) p_rcred <= p_rcred + {2'd0, p_add}; else p_rcred <= 8'hFF;
          end
          p_last_d <= (cyc_fc != 3'd6); p_last_ds <= dsack_n; p_last_la <= cyc_la;
        end
      end
    end

  // debug: one count per cache hit, at the phi1 that acknowledges it
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
