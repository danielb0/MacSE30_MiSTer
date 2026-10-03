// tg68k.v - the SE/30's 68030: the TG68K kernel (32-bit shape, plan 1.15)
// presented on the 68030 bus of plan 2.11.1, to GLUE.
//
// WHAT IT DOES
//   Runs the kernel's beats as 68030 bus cycles, in the processor's own
//   states on the C16M half-clock grid (UM 7.3.1):
//     S0  address, FC, SIZ, R/W valid (the kernel's outputs); ECS asserted
//     S1  AS* asserted, DS* with it on a read
//     S2  write data valid (the kernel drives it from S0)
//     S3  DS* on a write; DSACK1*/DSACK0* and BERR sampled at the falling
//         edge - and at every falling edge after, the wait states
//     S4  -
//     S5  read data latched at the end of S4, AS* and DS* negated
//   The kernel is acknowledged at the next S0 - one clkena with the data
//   and the DSACK code - so a following cycle's AS* asserts at its S1 and
//   cycles run back-to-back, as the 68030's do.  A bus error terminates
//   the cycle at the edge it is seen and is held to the kernel until it
//   takes the exception (plan 1.4 item 4, the IIvi's contract).
//
//   The PMMU (inside the kernel) is served as plan 1.4 says: the kernel's
//   cycle does not start while a translation is pending, a table walk is
//   in progress (the address is not physical yet) or the translation has
//   faulted, and the kernel does not advance then either, except to
//   dispatch a fault - a force-released beat with beat_valid low.  The walker's descriptor reads and writes
//   are the wrapper's own long cycles at the physical address, FC = 5,
//   in the beats the port needs.
//
//   CPU space (FC = 7): an interrupt acknowledge (A19-A16 = $F) is
//   terminated here as the grounded AVEC pin terminates it on the board -
//   the kernel autovectors (IPL_autovector) and the cycle's data is
//   unused; GLUE sees the cycle and ignores it, as UI6 keeps AS* from
//   the system.  A coprocessor cycle to ID 1 (A19-A13 = 0010 001) is the
//   68882's and runs on the bus like any other, terminated by the FPU's
//   DSACKs through GLUE (plan 8.9 item 7d).  Any other CPU-space cycle -
//   a coprocessor ID with no chip - is bus-errored here, which is what
//   makes an F-line instruction to it trap to its emulator vector
//   instead of hanging the processor (030 UM 10.5.2.8).
//
//   The instruction cache (plan 1.16, se30_cache030.v): a fetch that hits
//   is answered from it one C16M clock after the request, with no bus
//   cycle - no ECS, no AS* (the 68030 starts the cycle and aborts it on a
//   hit; our memory controller takes ECS as a committed start, plan 3.2,
//   so it is not presented for a hit).  A cachable fetch cycle - the
//   cache enabled, CDIS* negated, the MMU's CI clear, answered by a 32-bit
//   port without a bus error - fills its entry from the long at S5.  Not
//   here yet: the data cache (1.16 step 2).  Internal beats (no bus
//   access) advance once per C16M clock.
//
// CLOCKING
//   clk is 2 x C16M; phi1 marks C16M's rising edge and phi2 its falling
//   edge, one clk each, alternating.  The kernel is clocked by clk and
//   advanced by clkena.  GLUE runs on clk with c16_en = phi1.

`timescale 1ns/1ps

module tg68k (
  input         clk,                   // 2 x C16M
  input         phi1,                  // C16M rising edge
  input         phi2,                  // C16M falling edge
  input         reset_n,

  // the 68030 bus
  output        ecs,                   // ECS*, active high here: S0 of a cycle that may follow, the new address on the bus
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

  output        reset_out_n,           // the RESET instruction
  output        halted,                // double bus fault
  output [31:0] dbg_d6,                // D6 and D7, for the probe deck: the ROM's test manager
  output [31:0] dbg_d7,                //   keeps a failed test's code there (plan 3.8 item 23)
  output [56:0] dbg_exc,               // {an exception taken (one clk), its vector number, the opcode, its PC}:
                                       //   the probe deck's PEXC and PTRP (plan 5.12.12 item 8)
  output [63:0] dbg_cache              // {CDIS*, 1'b0, CACR[13:0], instruction hits[23:0], data hits[23:0]}:
                                       //   the probe deck's PCCH (plan 1.16.3); the counts wrap
);

  // ------------------------------------------------------------- kernel
  wire        k_clkena, k_beat_valid;
  wire [31:0] k_din, k_dout, k_addr, k_addr_log, k_cacr, k_cache_op_addr;
  wire        k_ci, k_rmc, k_wronly;
  wire  [1:0] k_dsack, k_busstate, k_siz;
  wire        k_nwr, k_nreset_out, k_clr_berr, k_cp_berr_ack;
  wire  [2:0] k_fc;
  wire        k_pmmu_busy, k_pmmu_fault, k_make_berr, k_trap_berr, k_halted;
  wire        k_exc_take;
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
    .CACR_out(k_cacr), .cache_op_addr(k_cache_op_addr), .pmmu_cache_inhibit(k_ci), .rmc_out(k_rmc), .wronly_rd_out(k_wronly),
    .busstate(k_busstate), .FC(k_fc), .nResetOut(k_nreset_out), .clr_berr(k_clr_berr), .cp_berr_ack(k_cp_berr_ack),
    .pmmu_walker_req(w_req), .pmmu_walker_we(w_we), .pmmu_walker_addr(w_addr), .pmmu_walker_wdat(w_wdat),
    .pmmu_walker_ack(w_ack), .pmmu_walker_data(w_data), .pmmu_walker_berr(w_berr),
    .debug_pmmu_busy(k_pmmu_busy), .debug_pmmu_fault(k_pmmu_fault),
    .debug_make_berr(k_make_berr), .debug_trap_berr(k_trap_berr), .debug_cpu_halted(k_halted),
    .debug_regfile_d6(dbg_d6), .debug_regfile_d7(dbg_d7),
    .debug_exc_take(k_exc_take), .debug_trap_vector(k_trap_vector), .debug_opcode(k_opcode), .debug_opcode_pc(k_opcode_pc)
  );
  assign dbg_exc = {k_exc_take, k_trap_vector[9:2], k_opcode, k_opcode_pc};
  assign reset_out_n = k_nreset_out;
  assign halted = k_halted;

  // ----------------------------------------------------- the bus cycle
  // whose cycle: the walker's when it asks, else the kernel's - and the
  // kernel's only once the PMMU has its physical address
  reg         walk;                    // a walker cycle is in progress (a long, in beats)
  reg   [2:0] walk_done;               // bytes of the walker's long moved so far
  reg  [31:0] walk_buf;
  // The walker's request is registered and drops only at the edge that
  // takes w_ack, so for the clk w_ack is high it is the one just served:
  // a cycle started then carried the old address and R/W (a walk's second
  // access went out at the first's address, corrupting the table - sim/
  // cpfpu mmu, b5d).  Not the walker's that clk, and parked, as ecs waits
  // out ack_pending below.  A translation that has faulted (an invalid
  // descriptor) parks the kernel's cycle too: the 68030 runs no bus cycle
  // to an invalid page, it takes the bus error (k_force) - the kernel
  // gates its own strobes so (nUDS/nLDS), which this bus does not use,
  // and a write to an invalid page reached memory before its fault.
  wire        k_req  = (k_busstate != 2'b01);
  wire        park   = k_pmmu_busy || k_pmmu_fault || w_req;
  wire        wsel   = walk || (w_req && !w_ack);      // the bus is the walker's
  wire        eff_req  = wsel || (k_req && !park);
  wire [31:0] eff_addr = wsel ? {w_addr[31:2], walk_done[1:0]} : k_addr;
  wire        eff_rw   = wsel ? !w_we : k_nwr;
  wire  [2:0] eff_fc   = wsel ? 3'd5 : k_fc;
  wire  [1:0] eff_siz  = wsel ? (walk_done == 3'd3 ? 2'b01 : walk_done == 3'd2 ? 2'b10 : walk_done == 3'd1 ? 2'b11 : 2'b00) : k_siz;
  // the walker's write data as Table 7-5 places a long's remaining bytes
  wire  [7:0] w_r0 = walk_done == 0 ? w_wdat[31:24] : walk_done == 1 ? w_wdat[23:16] : walk_done == 2 ? w_wdat[15:8] : w_wdat[7:0];
  wire  [7:0] w_r1 = walk_done == 0 ? w_wdat[23:16] : walk_done == 1 ? w_wdat[15:8]  : w_wdat[7:0];
  wire  [7:0] w_r2 = walk_done == 0 ? w_wdat[15:8]  : w_wdat[7:0];
  wire  [7:0] w_r3 = w_wdat[7:0];
  wire [31:0] w_dout = (walk_done == 0) ? {w_r0, w_r1, w_r2, w_r3} :
                       (walk_done == 1) ? {w_r0, w_r0, w_r1, w_r2} :
                       (walk_done == 2) ? {w_r0, w_r1, w_r0, w_r1} : {w_r0, w_r0, w_r1, w_r0};
  wire [31:0] eff_dout = wsel ? w_dout : k_dout;

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
  // (plan 1.16) a kernel fetch (busstate 00) that hits the instruction
  // cache, or a data read (10) that hits the data cache and is not the read
  // of a read-modify-write (forced to miss, UM 6.1.2.2): answered from the
  // cache, no cycle.  A cachable cycle that misses - not CI by the PMMU, not
  // CPU space, not the walker's - fills its entry at S5 from a 32-bit
  // termination.  A cachable data write updates the data cache as its
  // cycle starts (S1), with the bytes its beat puts on a 32-bit port's
  // lanes; a write the PMMU faults (k_force) clears a matching entry.
  wire        k_fetch  = !wsel && (k_busstate == 2'b00) && !park;
  wire        k_dread  = !wsel && (k_busstate == 2'b10) && !park;
  wire        k_dwrite = !wsel && (k_busstate == 2'b11) && !park;
  wire        i_hit, d_hit;
  wire [31:0] i_q, d_q;
  wire        f_hit    = k_fetch && i_hit;
  wire        r_hit    = k_dread && !k_rmc && d_hit && (k_fc != 3'd7);
  // (plan 1.17.2) the kernel's destination read for CLR, Scc and MOVE from
  // SR/CCR, which a 68030 does not run: answered here like a hit, no cycle,
  // the data unused (zero)
  wire        z_hit    = k_dread && k_wronly;
  wire        any_hit  = f_hit || r_hit || z_hit;
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
  wire        s1_take  = phi2 && (s == 3'd0) && !any_hit && !ack_pending && !hit_ack && eff_req;
  wire        d_wr     = s1_take && k_dwrite && !k_ci && (k_fc != 3'd7);
  wire        d_inv    = phi1 && k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !k_nwr && (k_fc != 3'd7);   // k_force's terms (declared below)
  se30_cache030 cache (
    .clk(clk), .reset_n(reset_n),
    .cacr(k_cacr[13:0]), .caar(k_cache_op_addr[7:2]), .cdis(cdis),
    .la(k_addr_log[31:2]), .fc(k_fc), .i_hit(i_hit), .i_q(i_q),
    .i_fill(i_fill), .fill_la(cyc_la), .fill_fc(cyc_fc), .fill_data(cpu_din),
    .d_hit(d_hit), .d_q(d_q), .d_fill(d_fill),
    .d_wr(d_wr), .d_wbe(d_wbe), .d_wdata(k_dout), .d_wlong(k_siz == 2'b00 && k_addr[1:0] == 2'b00),
    .d_inv(d_inv));

  // ECS (UM 5.6.2, 7.1.1): "the earliest indication that the processor is
  // initiating a bus cycle" - the address, FC, SIZ and R/W are on the bus
  // and AS* follows at S1 unless the cycle is aborted.  Here: the S0
  // half-clock, when a request is waiting and the state machine is idle;
  // the memory controller starts its row access on it and qualifies with
  // AS* (plan 3.2).  Not while the previous cycle's acknowledge is still
  // pending: from S5 to the phi1 that acknowledges the kernel, the kernel
  // still presents the request just completed, and an ECS there would carry
  // the old address (the machine bench found this: the second of two
  // back-to-back fetches came back with the first one's data).  The
  // kernel's new request appears at that phi1 and is taken at the following
  // phi2, so this is exactly one clk wide, and nothing during reset.
  assign ecs      = reset_n && (s == 3'd0) && eff_req && !ack_pending && !hit_ack && !any_hit;
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
    end else begin
      w_ack <= 0;
      if (phi1) begin
        ack_pending <= 0; ack_berr <= 0; hit_ack <= 0;
        // a completed walker beat: more beats, or the descriptor is in
        if (ack_pending && walk) begin
          if (ack_berr) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else if (walk_done + w_n >= 3'd4) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else begin walk_done <= walk_done + w_n; walk_buf <= w_long; end
        end
        if (s == 3'd2) s <= 3'd3;
        if (s == 3'd4) s <= 3'd5;
        if (k_make_berr || k_trap_berr || k_cp_berr_ack) berr_hold <= 0;   // (7d B5: taken as no coprocessor)
      end
      if (phi2) begin
        case (s)
          3'd0: if (any_hit && !ack_pending && !hit_ack) begin             // a hit: no cycle
                  hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit; dsack_r <= 2'b00;
                end else if (eff_req && !hit_ack) begin                      // S1
                  if (w_req && !walk) begin walk <= 1; walk_done <= 0; walk_buf <= 0; end
                  as_n_r <= 0; ds_n_r <= !eff_rw ? 1'b1 : 1'b0; s <= 3'd2;
                  cyc_fill  <= k_fetch && !k_ci && (k_fc != 3'd7);
                  cyc_dfill <= k_dread && !k_ci && (k_fc != 3'd7);
                  cyc_la <= k_addr_log[31:2]; cyc_fc <= k_fc;
                end
          3'd3: begin                                                      // S3 and the wait states
                  ds_n_r <= 0;
                  if (cp_local) begin                                        // AVEC, or no coprocessor
                    if (iack) begin dsack_r <= 2'b00; s <= 3'd4; end
                    else begin
                      as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                      if (!walk) berr_hold <= 1;
                    end
                  end else if (berr) begin
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                    dsack_r <= dsack_n; if (!walk) berr_hold <= 1;
                  end else if (dsack_n != 2'b11) s <= 3'd4;
                end
          3'd5: begin                                                      // S5: latch at the end of S4
                  din_r <= cpu_din; if (!cp_local) dsack_r <= dsack_n;
                  as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1;
                  if (berr) begin ack_berr <= 1; if (!walk) berr_hold <= 1; end
                end
          default: ;
        endcase
      end
    end

  // the kernel's acknowledge: its own completed cycle, an internal beat
  // (no bus access) once per C16M clock, or a force-released beat on a
  // PMMU fault so the exception can dispatch
  wire k_cycle_ack = (ack_pending || hit_ack) && !walk;
  wire k_internal  = (k_busstate == 2'b01) && !k_pmmu_busy && !w_req && !walk;
  wire k_force     = k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending;
  assign k_clkena     = phi1 && (k_cycle_ack || k_internal || k_force);
  assign k_beat_valid = k_cycle_ack || k_internal;
  assign k_din   = !hit_ack ? din_r : hit_z ? 32'h0 : hit_d ? d_q : i_q;

  // the probe deck's PCCH: one count per hit, at the phi1 that acknowledges it
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
