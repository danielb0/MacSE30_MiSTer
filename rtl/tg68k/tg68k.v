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
//   The pace (plan 1.17.5): the kernel runs its internal work about twice
//   as fast as a 68030, so each instruction is held, at the kernel's decode
//   beat, to the manual's instruction time - UM Section 11's tables
//   (se30_pace030.v) by Equation 11-2, the bus cycles' wait states added
//   as 11.5 adds them.  Only the step into the next instruction waits;
//   cycles and acknowledges never do.  pace_en low runs unpaced.
//
//   The write pending buffer (plan 1.17.7; UM 11.2.5.2): a kernel data
//   write to a port that always terminates and never bus-errors - low
//   space, RAM or the ROM under the overlay (32-bit, one beat), and the
//   video card at $FExxxxxx (8-bit, a beat a byte) - is posted: latched at
//   its S1, acknowledged to the kernel at the next phi1 as a 32-bit port
//   would take it, and run from the buffer while the kernel goes on with
//   internal beats and cache hits.  The wrapper runs the byte beats itself,
//   as the 68030's micro bus controller does its dynamic sizing (UM
//   11.2.5.3).  Any other cycle waits for the buffer (the interlock), so
//   the bus sees the same cycles in the same order.  Every other write -
//   devices, slots, CPU space, a read-modify-write's - is waited for, as
//   before.
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
  input         pace_en,               // hold each instruction to the 68030's time (plan 1.17.5); low: unpaced
  input         post_en,               // the write pending buffer (plan 1.17.7); low: every write waited for

  output        reset_out_n,           // the RESET instruction
  output        halted,                // double bus fault
  output [31:0] dbg_d6,                // D6 and D7, for the probe deck: the ROM's test manager
  output [31:0] dbg_d7,                //   keeps a failed test's code there (plan 3.8 item 23)
  output [56:0] dbg_exc,               // {an exception taken (one clk), its vector number, the opcode, its PC}:
                                       //   the probe deck's PEXC and PTRP (plan 5.12.12 item 8)
  output [35:0] dbg_pace,              // one instruction released by the pace: {release (one clk), its decoder row[7:0],
                                       //   clocks it took[8:0], its budget[9:0], its fetches' wait states[7:0]} (PPRF, plan 10.4 item 4)
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
    .CACR_out(k_cacr), .cache_op_addr(k_cache_op_addr), .pmmu_cache_inhibit(k_ci), .rmc_out(k_rmc), .wronly_rd_out(k_wronly),
    .busstate(k_busstate), .FC(k_fc), .nResetOut(k_nreset_out), .clr_berr(k_clr_berr), .cp_berr_ack(k_cp_berr_ack),
    .pmmu_walker_req(w_req), .pmmu_walker_we(w_we), .pmmu_walker_addr(w_addr), .pmmu_walker_wdat(w_wdat),
    .pmmu_walker_ack(w_ack), .pmmu_walker_data(w_data), .pmmu_walker_berr(w_berr),
    .debug_pmmu_busy(k_pmmu_busy), .debug_pmmu_fault(k_pmmu_fault),
    .debug_make_berr(k_make_berr), .debug_trap_berr(k_trap_berr), .debug_cpu_halted(k_halted),
    .debug_regfile_d6(dbg_d6), .debug_regfile_d7(dbg_d7),
    .debug_exc_take(k_exc_take), .debug_trap_vector(k_trap_vector), .debug_opcode(k_opcode), .debug_opcode_pc(k_opcode_pc),
    .debug_decodeOPC(k_decode)
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
  // the write pending buffer (the header; below): while it holds an
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
  // a cycle the kernel (or the walker) starts; the buffer's later beats are pb_take's
  wire        s1_take  = phi2 && (s == 3'd0) && !post && !any_hit && !ack_pending && !hit_ack && eff_req && !pace_stall;
  wire        pb_take  = phi2 && (s == 3'd0) && post && !ack_pending;
  wire        d_wr     = s1_take && k_dwrite && !k_ci && (k_fc != 3'd7);
  wire        d_inv    = phi1 && k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post && !k_nwr && (k_fc != 3'd7);   // k_force's terms (declared below)

  // ------------------------------------------- the write pending buffer
  // (plan 1.17.7) What is posted: a kernel data write - not the walker's,
  // not CPU space, not a read-modify-write's - to a port that always
  // terminates and never bus-errors, so the early acknowledge cannot be
  // wrong: low space (GLUE: RAM, or the ROM under the overlay, "a ROM
  // write: acknowledged, no effect" - a 32-bit port, one beat) and the
  // video card, which answers every address of $FExxxxxx (VRAM and the
  // declaration ROM, mirrored) on its 8-bit port, a beat a byte.  The
  // kernel is told DSACK 00 - the bytes a 32-bit port takes, to the long's
  // end (w_nb) - so its own split at a long boundary is unchanged; the
  // buffer then runs those bytes as the port needs.  The beats after the
  // first carry their byte on every lane: D31-D24 is the only lane an
  // 8-bit port reads (the first beat is the kernel's own Table 7-5 image).
  wire        pb_vid   = (k_addr[31:24] == 8'hFE);
  // post_en low waits for every write: for a bench that bus-errors a RAM
  // write (sim/cpfpu b5c) - a fault the SE/30 cannot raise there, and one
  // the buffer, having acknowledged early, could only report late (the
  // header).
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
  // The buffer's later beats take theirs whatever the kernel is doing.
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
        if (k_make_berr || k_trap_berr || k_cp_berr_ack) berr_hold <= 0;   // (7d B5: taken as no coprocessor)
      end
      if (phi2) begin
        // a hit while the buffer drains: the bus is the buffer's, the
        // caches are not (the posted write's own acknowledge goes first)
        if (post && any_hit && !hit_ack && !post_ack && !pace_stall) begin
          hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit; dsack_r <= 2'b00;
        end
        case (s)
          3'd0: if (post) begin                                            // the buffer's next beat: S1
                  as_n_r <= 0; ds_n_r <= 1'b1; s <= 3'd2;
                end else if (any_hit && !ack_pending && !hit_ack && !pace_stall) begin   // a hit: no cycle
                  hit_ack <= 1; hit_d <= !f_hit; hit_z <= z_hit; dsack_r <= 2'b00;
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
                    // not reachable (the header): the operand ends, the
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

  // the kernel's acknowledge: its own completed cycle, a posted write's
  // early one, an internal beat (no bus access) once per C16M clock, or a
  // force-released beat on a PMMU fault so the exception can dispatch
  // (after the buffer has drained)
  wire k_cycle_ack = (ack_pending || hit_ack || post_ack) && !walk;
  wire k_internal  = (k_busstate == 2'b01) && !k_pmmu_busy && !w_req && !walk && !pace_stall;
  wire k_force     = k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending && !post;
  assign k_clkena     = phi1 && (k_cycle_ack || k_internal || k_force);
  assign k_beat_valid = k_cycle_ack || k_internal;
  assign k_din   = !hit_ack ? din_r : hit_z ? 32'h0 : hit_d ? d_q : i_q;

  // ------------------------------------------------------------ the pace
  // (plan 1.17.5 item 5) The kernel runs its internal work about twice as
  // fast as a 68030 (1.17.1), and the ROM's floppy driver cannot stand it
  // (1.17.5).  Each instruction is held to the manual's time: at the
  // kernel's decode beat - decodeOPC, the first beat of the next instruction
  // - the step is withheld until the instruction just run has been on the
  // clock for its budget, UM Section 11.3's Equation 11-2: the effective-
  // address part's and the operation part's I-cache-case clocks
  // (se30_pace030.v, the manual's tables), each less its overlap with the
  // part before, min(head, tail of the previous part); plus, as 11.5 adds
  // wait states, every bus cycle's clocks beyond the tables' two (a
  // continuation beat of a long through a narrow port counts whole, as the
  // manual's dynamic-sizing rule has it), and those clocks lengthen the
  // tail of the part that ran the cycle - a read's the EA part's (rule 1a),
  // a write's the operation's (rule 3a) - so the part after may overlap
  // them; plus MOVEM's clocks a register.  A posted write (plan 1.17.7)
  // may still be on the bus when its instruction is released: a beat that
  // completes after the release adds its clocks to the running
  // instruction's budget (p_xcred) and to the tail that instruction
  // overlaps (p_tail) - Equation 11-2's total, the write's wait states in
  // the writer's tail, now reachable because the next head really runs
  // under the write.  (Should a second release come first, the rest goes
  // to the instruction then running - a small misattribution, the total
  // kept.)
  // Bus cycles and acknowledges are never delayed, only the step into the
  // next instruction.  Elapsed time runs from one release to the next; the
  // cycle a decode beat starts belongs to the new instruction.  pace_en low
  // runs the kernel unpaced (the bench's comparison).
  reg  [15:0] p_op;      // the instruction running: its opcode ...
  reg  [31:0] p_pc;      //   ... and address, latched at its release
  reg   [5:0] p_tail;    // the tail of the instruction before it, its write cycles' wait states included (saturating)
  reg   [8:0] p_cnt;     // C16M clocks since the release (saturating)
  reg   [7:0] p_rcred;   // the wait-state clocks of its data read cycles so far (saturating) ...
  reg   [7:0] p_wcred;   //   ... of its write cycles, MOVEM's register clocks with them ...
  reg   [7:0] p_fcred;   //   ... and of its instruction fetches (the no-cache case's W: budget only, no tail)
  reg   [7:0] p_xcred;   //   ... and of the instruction before's posted write, completed after the release
  reg         pb_old;    // the posted operand's instruction has been released
  reg         p_rel;     // released: the decode beat may step
  reg   [4:0] p_cyc;     // clk edges of the cycle in progress (saturating)
  reg         p_cont;    // the cycle in progress continues an operand through a narrow port
  reg  [29:0] p_last_la; // the last data cycle's long address ...
  reg   [1:0] p_last_ds; //   ... and port size
  reg         p_last_d;  //   ... and that it was a data cycle
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
