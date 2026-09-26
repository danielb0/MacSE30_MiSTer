// tg68k.v - the SE/30's 68030: the TG68K kernel (32-bit shape, plan 1.15)
// presented on the 68030 bus of plan 2.11.1, to GLUE.
//
// WHAT IT DOES
//   Runs the kernel's beats as 68030 bus cycles, in the processor's own
//   states on the C16M half-clock grid (UM 7.3.1):
//     S0  address, FC, SIZ, R/W valid (the kernel's outputs)
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
//   cycle does not start while a translation is pending or a table walk is
//   in progress (the address is not physical yet), and the kernel does not
//   advance then either, except to dispatch a fault - a force-released
//   beat with beat_valid low.  The walker's descriptor reads and writes
//   are the wrapper's own long cycles at the physical address, FC = 5,
//   in the beats the port needs.
//
//   Interrupts: GLUE's IPL to the kernel; AVEC is grounded on the board,
//   so every acknowledge autovectors - the kernel does it internally and
//   no acknowledge cycle reaches the bus, which is what GLUE sees on the
//   real board (UI6 keeps AS* from the system for FC = 7).
//
//   Not here yet: the 68030's caches (plan 1.15 item 9); internal beats
//   (no bus access) advance once per C16M clock.
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

  output        reset_out_n,           // the RESET instruction
  output        halted                 // double bus fault
);

  // ------------------------------------------------------------- kernel
  wire        k_clkena, k_beat_valid;
  wire [31:0] k_din, k_dout, k_addr;
  wire  [1:0] k_dsack, k_busstate, k_siz;
  wire        k_nwr, k_nreset_out, k_clr_berr;
  wire  [2:0] k_fc;
  wire        k_pmmu_busy, k_pmmu_fault, k_make_berr, k_trap_berr, k_halted;
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
    .addr_out(k_addr), .data_write(k_dout), .siz(k_siz), .nWr(k_nwr),
    .busstate(k_busstate), .FC(k_fc), .nResetOut(k_nreset_out), .clr_berr(k_clr_berr),
    .pmmu_walker_req(w_req), .pmmu_walker_we(w_we), .pmmu_walker_addr(w_addr), .pmmu_walker_wdat(w_wdat),
    .pmmu_walker_ack(w_ack), .pmmu_walker_data(w_data), .pmmu_walker_berr(w_berr),
    .debug_pmmu_busy(k_pmmu_busy), .debug_pmmu_fault(k_pmmu_fault),
    .debug_make_berr(k_make_berr), .debug_trap_berr(k_trap_berr), .debug_cpu_halted(k_halted)
  );
  assign reset_out_n = k_nreset_out;
  assign halted = k_halted;

  // ----------------------------------------------------- the bus cycle
  // whose cycle: the walker's when it asks, else the kernel's - and the
  // kernel's only once the PMMU has its physical address
  reg         walk;                    // a walker cycle is in progress (a long, in beats)
  reg   [2:0] walk_done;               // bytes of the walker's long moved so far
  reg  [31:0] walk_buf;
  wire        k_req  = (k_busstate != 2'b01);
  wire        park   = k_pmmu_busy || w_req;
  wire        wsel   = walk || w_req;                  // the bus is the walker's
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

  reg   [2:0] s;                       // 0 idle (S0), 2 after S1, 3 S3/wait, 4 after S4, 5 after S5
  reg         as_n_r, ds_n_r;
  reg  [31:0] din_r;
  reg   [1:0] dsack_r;
  reg         ack_pending, ack_berr;
  reg         berr_hold;

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
    end else begin
      w_ack <= 0;
      if (phi1) begin
        ack_pending <= 0; ack_berr <= 0;
        // a completed walker beat: more beats, or the descriptor is in
        if (ack_pending && walk) begin
          if (ack_berr) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else if (walk_done + w_n >= 3'd4) begin walk <= 0; walk_done <= 0; w_ack <= 1; w_data <= w_long; end
          else begin walk_done <= walk_done + w_n; walk_buf <= w_long; end
        end
        if (s == 3'd2) s <= 3'd3;
        if (s == 3'd4) s <= 3'd5;
        if (k_make_berr || k_trap_berr) berr_hold <= 0;
      end
      if (phi2) begin
        case (s)
          3'd0: if (eff_req) begin                                         // S1
                  if (w_req && !walk) begin walk <= 1; walk_done <= 0; walk_buf <= 0; end
                  as_n_r <= 0; ds_n_r <= !eff_rw ? 1'b1 : 1'b0; s <= 3'd2;
                end
          3'd3: begin                                                      // S3 and the wait states
                  ds_n_r <= 0;
                  if (berr) begin
                    as_n_r <= 1; ds_n_r <= 1; s <= 3'd0; ack_pending <= 1; ack_berr <= 1;
                    dsack_r <= dsack_n; if (!walk) berr_hold <= 1;
                  end else if (dsack_n != 2'b11) s <= 3'd4;
                end
          3'd5: begin                                                      // S5: latch at the end of S4
                  din_r <= cpu_din; dsack_r <= dsack_n;
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
  wire k_cycle_ack = ack_pending && !walk;
  wire k_internal  = (k_busstate == 2'b01) && !k_pmmu_busy && !w_req && !walk;
  wire k_force     = k_pmmu_fault && !walk && (s == 3'd0) && !ack_pending;
  assign k_clkena     = phi1 && (k_cycle_ack || k_internal || k_force);
  assign k_beat_valid = k_cycle_ack || k_internal;
  assign k_din   = din_r;
  assign k_dsack = dsack_r;
  assign w_berr  = ack_berr && walk;
  always @* k_berr = berr_hold && !(k_make_berr || k_trap_berr);

endmodule
