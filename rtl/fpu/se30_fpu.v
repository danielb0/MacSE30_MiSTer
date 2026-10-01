// se30_fpu.v - the MC68882 floating-point coprocessor (UJ9 on the IIcx proxy;
// SE30_PLAN.md 8), its bus interface unit and conversion unit around the
// APU (se30_fpu_apu.v): items 7b and 7c of plan 8.9, and 7e's overlap (8.9.6)
// - the CU takes the next instruction while the APU runs.  Held to sim/fpu/
// tb_se30_fpu.v, which runs the model's vectors through these pins, and
// pairs and triples of them without waiting against the same one at a time.
//
// THE PINS (MC68882 data sheet BR509; UM 7.1-7.2)
//   cs is the chip select as GLUE drives it - FC = 7, A19-A16 = 0010,
//   A15-A13 = the coprocessor ID - qualified by the strobe: the access
//   starts when it rises and ends when it falls ("START", BR509 note 8).
//   a is A4-A0, the CIR select; rw 1 = read.  The FPU is a 32-bit port:
//   the word registers ($00-$0E) answer DSACK1 alone with their data on
//   D31-D16 whatever A1, the operand, register select, instruction and
//   operand address CIRs ($10-$1F) both DSACKs (Table 5 of BR509).
//   Asynchronous accesses are acknowledged at the first clk edge that
//   sees them (within the data sheet's 50 ns at 16.67 MHz); the response
//   and save reads are synchronous (BR509 note 3): START is sampled at a
//   rising FPU clock edge (the ce edge) and DSACK asserted at the falling
//   edge a clock and a half later - 1.5 to 2.5 clocks from START, the
//   data sheet's specification 27.  DSACK stays asserted until cs falls.
//   The FPU may hold DSACK off to synchronize ("delaying the assertion of
//   DSACKx, if necessary", UM 6.1.12); it does while a null restore
//   clears the registers and while an FMOVEM register is fetched.
//
// THE CIRs (UM Table 7-2, plan 8.6.12)
//   Response ($00) read: the primitive of the current dialog; reading a
//   service primitive consumes it.  Control ($02) write: XA bit 1, AB bit
//   0.  Save ($04) read: FSAVE, below.  Restore ($06) write: FRESTORE,
//   below; the read returns the word written if valid, else $0238.
//   Operation word ($08), operand address
//   ($1C) and the reserved locations: writes ignored, reads all ones.
//   Command ($0A) and condition ($0E): the instruction.  Operand ($10):
//   the data port, MSB-aligned.  Register select ($14): the FMOVEM mask in
//   bits 15-8.  Instruction address ($18): the PC the FPU asked for; it
//   becomes FPIAR (one instruction at a time, the requesting instruction
//   is the one in the APU).
//
// THE DIALOGS (UM 7.5, Figures 7-17 to 7-24; plan 8.6.12)
//   Execution starts at the first response read after the command write
//   (UM 7.2.1).  The PC is requested (bit 14) in the first primitive of an
//   arithmetic instruction when any exception is enabled (Table 7-5 note).
//   Register to register and FMOVECR: $0900/$4900, the APU runs.  <ea> to
//   register: evaluate-and-transfer - $1504/$1608/$160C (CA = 0) for S, D
//   and X, $9501/$9502/$9504/$960C for B, W, L and P, then $0900 once the
//   operand is in - and the APU runs from the last operand write.  FPn to
//   <ea>: $8900/$C900 while converting (a dynamic k-factor first asks for
//   Dn with $8C0r/$CC0r), then $B101-$B20C, or the CA = 0 forms
//   $3104/$3208/$320C for S, D and X unless the source is a NaN, unnormal
//   or denormal, or (S and D) the store over- or underflowed or INEX2 is
//   enabled; a CA = 1 store ends with $0802 or take mid-instruction.
//   FMOVE of the control registers: $9504/$9608/$960C/$9704 in,
//   $B104/$B208/$B20C/$B304 out, then $0802.  FMOVEM: ($8C0r for a
//   dynamic list) $810C/$A10C, the register select read, 12 bytes a
//   register, then $0802.  Conditionals: $8900 while busy, then $0800/
//   $0801 (TF), or BSUN's $5C30.
//
// THE OVERLAP (UM 5.1.1.2, 7.2.6, 7.5; plan 8.9.6 - item 7e)
//   A general instruction arriving while the APU runs goes to the CU's slot
//   when it is free: arithmetic from an FP register is released at once
//   ($0900, or $4900 and the PC); from memory in S, D or X its operand is
//   transferred with CA = 0 and the MPU released; in B, W or L the operand
//   is transferred and the MPU held with $8900 until the hand-off, then
//   released with $0900 (B_HOLD).  Packed sources, FMOVECR, stores, FMOVEM,
//   the control registers and conditionals wait for both units ($8900), as
//   does any instruction while the slot is full.  The hand-off starts the
//   APU on the slot's command when it is idle, no exception is pending, no
//   save is awaited and the PC has come.  A passed PC waits with its
//   instruction (cu_iar) and becomes FPIAR when it starts, so FPIAR is the
//   APU instruction's while its exception is handled.  An exception
//   pending holds the slot until a FRESTORE with bit 27 set (5.2.3.6); the
//   MPU still in the slot's dialog (B_HOLD) gets it as take mid-instruction
//   $1Dvv, and after XA the dialog waits again; else the next instruction
//   gets take pre-instruction.  FMOVEM and the control registers do not
//   report it and so wait while it holds the slot.
//
// THE CU'S MOVES (UM Table 5-5, 5.1.2.2; plan 8.9.6 - item 7e-2)
//   The fully concurrent FMOVEs - FPm,FPn; <ea>,FPn and FPm,<ea> in S, D
//   and X - the CU does itself, the APU busy or idle: FPm read through
//   port B while the first response read waits ($8900), then FPm,FPn
//   written and released ($0900), or the store's image made (rounded by
//   RND, PREC ignored) and transferred with CA = 0; <ea>,FPn widened and
//   written after its last operand write.  Handed over as the table says:
//   FPm the APU instruction's destination waits for it (a); FPn its
//   destination (f), a NaN, unnormal or denormal (b), PREC single or
//   double (c) send a move in to the APU (the slot while it runs); INEX2
//   enabled (d), the store over- or underflowing (e) or (b) send a store
//   the APU's way.  The move's register or memory operand is written at
//   once; its FPSR effect (FPCC for a move in, EXC, the AEXC bits) and its
//   passed PC are held while an older instruction runs or its exception is
//   pending, and applied after it, so FPSR and FPIAR retire in program
//   order.  A move in progress keeps the CU busy: a third instruction and
//   the conditionals wait, FSAVE answers come again.
//
// EXCEPTIONS (UM 6.1.9-6.1.12, 7.4.2.5-7.4.2.6, 7.5.4; plan 8.6.10)
//   The APU's end leaves EXC AND ENABLE's exception pending (fpu_trapvec).
//   An arithmetic or conditional instruction initiated with one pending
//   gets take pre-instruction $1Cvv (8.6.14 item 19: FMOVEM and FMOVE of
//   the control registers do not report it); a store reports its own as
//   take mid-instruction $1Dvv at its end.  The acknowledge (XA) does not
//   clear it (the 68882's rule): the primitive stays in the response
//   register and every such instruction reports it again, until an FSAVE
//   or a null restore.  An illegal command word - opclass 001,
//   opmodes $40-$7F, FMOVECR offsets $40-$7F, an empty control-register
//   list (8.6.14 item 20) - gets $1C0B (item 18), after any pending
//   exception, and XA clears it.  A protocol violation (6.1.12's four
//   rules, and any write to the register select CIR) terminates the access
//   at once and answers $1D0D until XA, which aborts everything.  An
//   operand read before an FMOVE or FMOVEM out has issued its DR = 1
//   primitive is never acknowledged (6.1.12, 8.6.14 item 21).  AB aborts
//   the dialog in progress.
//
// FSAVE AND FRESTORE (UM 6.4, 7.5.3, 7.5.4.6-7.5.4.7; plan 8.9.3 - item 7c)
//   The save CIR read answers by phase: $0038 (null) until a command or
//   condition word has been accepted since the reset or a null restore
//   (8.6.14 item 28); $0138 (come again) while the APU runs, latching a save
//   request that stops it at its next checkpoint or cuts its END padding
//   short; then $1FD4 (busy, 53 longwords) if it stopped at a checkpoint
//   or the dialog is receiving an instruction's operands, else $1F38
//   (idle, 14).  The frame streams from the chip's registers, frozen
//   meanwhile, highest longword first; after the last the chip is idle
//   with nothing pending.  A save read during a transfer answers $0238
//   and changes nothing; AB then ends the transfer, and the rest of its
//   operand accesses are acknowledged and ignored.  A command or condition
//   written while a save is awaited abandons it (a stopped APU carries
//   on).  A restore write aborts everything: $00xx is the null restore -
//   the registers to the NaN, FPCR, FPSR and FPIAR to zero, nothing
//   pending (6.4.4); $1F38 and $1FD4 take their frame lowest longword
//   first into the same registers, and at its end the dialog and the
//   pending exception (BIU flag bit 27, of type EXC AND ENABLE) are
//   reinstated and a stopped APU resumes.  Longword k is at offset 4k:
//     1        the command/condition image (the last word written)
//     2-4      the dialog's data: the operand or FMOVEM register being
//              received, or the CU's instruction's operand, else the
//              store's output buffer
//     5        the dialog's state (bst, pc_next, longwords, CA, masks) and
//              the CU's (the slot full, its PC waiting, the dialog's
//              instruction in the APU, a take from B_HOLD)
//     6        the take primitive posted, the slot's command word
//     7        the slot's PC
//     8        the CU's moves: the held effect {valid, FPCC in it, FPIAR
//              in it, a move's PC awaited, the dialog the CU's store (its
//              image in 2-4), 0, FPCC, EXC, AEXC}
//     9        the held PC
//     10-15    busy: {APU stopped, the APU's context (se30_fpu_apu.v), 0}
//     16-48    busy: T0-T10, three longwords each
//     N-4..N-2 the exceptional operand;  N-1 the operand register image;
//     N        the BIU flags (Figure 6-6, Table 6-4)

`timescale 1ns/1ps
`include "fpu_ucode.vh"

module se30_fpu #(
  parameter UROM_HEX  = "ucode.urom.hex",
  parameter NROM_HEX  = "ucode.nrom.hex",
  parameter ENTRY_HEX = "ucode.entry.hex",
  parameter KROM_HEX  = "ucode.krom.hex",
  parameter NSEL_HEX  = "ucode.nsel.hex",
  parameter CVT_HEX   = "ucode.cvt.hex",    // the CU's conversion times (7e-3, plan 8.9.7)
  parameter CVSEL_HEX = "ucode.cvsel.hex",  // ... which of them an entry uses
  parameter TADJ_HEX  = "ucode.tadj.hex"    // the APU's clocks' adjustment (8.9.7)
) (
  input             clk,
  input             ce,            // C16M: the FPU clock's rising edge is the clk edge with ce
  input             reset,

  input             cs,
  input             rw,
  input      [4:0]  a,
  input      [31:0] din,
  output reg [31:0] dout,
  output reg [1:0]  dsack_n,       // {DSACK1*, DSACK0*}: 01 a word register, 00 a long one

  // the bench's view (sim/fpu): the exceptional operand (FSAVE shows it
  // too), the APU's clocks, sim.py's SimError
  output     [79:0] dbg_exop,
  output     [15:0] dbg_clocks,
  output            dbg_err,
  output     [4:0]  dbg_state
);
  `include "se30_fpu_fn.vh"

  localparam [79:0] FP_NAN = 80'h7FFF_FFFFFFFFFFFFFFFF;
  localparam [2:0]  TZERO  = `TAG_ZERO;

  // -- the APU and the register file's port B (the CU's) ----------------------
  reg         apu_start, apu_abort;
  reg  [9:0]  apu_idx;
  reg  [15:0] cmd;                 // the BIU's: the dialog's command word
  reg  [15:0] acmd;                // the command of the instruction the APU starts (7e)
  reg  [95:0] opnd;                // the CU's operand, right-aligned
  reg  [31:0] dreg;                // Dn from a transfer-single-register
  reg         src_is_fp, zero_src;
  reg  [79:0] src_fp;
  reg  [2:0]  fpb_addr;
  reg         fpb_we;
  reg  [79:0] fpb_d;
  wire [79:0] fpb_q;
  reg         fpcr_we, fpsr_we;
  reg  [31:0] fpcr_d, fpsr_d;
  wire [31:0] fpcr, fpsr;
  wire [95:0] obuf;
  wire        apu_busy, apu_susp;
  wire [162:0] ctx_q;
  wire [85:0] x_tq;

  // -- FSAVE and FRESTORE (7c, plan 8.9.3) ---------------------------------------
  reg         used;                // a command or condition accepted: not the reset phase
  reg         sv_req;              // a save waits for the APU
  reg         sv_on, rs_on;        // a frame is being saved, restored
  reg         fbz;                 // ... and it is a busy one
  reg         dead;                // a transfer aborted by AB: its operand accesses are ignored
  reg  [5:0]  fk;                  // the frame's longword (1 to N)
  reg  [1:0]  fwait;               // the next longword is being read (T0-T10)
  reg         apu_go, go_pend;     // resume the APU (after its context is loaded)
  reg         ctx_we, x_twe, x_exop_we, x_obuf_we;
  reg  [3:0]  x_ta;
  reg  [85:0] x_td;
  reg  [15:0] img, rs_img, rs_take, rs_cucmd;
  reg  [31:0] rs_iar;
  reg  [95:0] rs_slot;
  reg  [31:0] rs_ctl, rs_mv;
  reg  [191:0] rs_ctx;
  reg  [63:0] rs_t;
  reg  [79:0] rs_exop;
  wire [5:0]  f_n = fbz ? 6'd53 : 6'd14;

  // {T index, longword 0-2} of busy-frame longword k (16-48)
  function [5:0] tsplit;
    input [5:0] k;
    reg   [5:0] r;
    integer i;
    begin
      tsplit = 6'd0;
      for (i = 0; i < 11; i = i + 1) begin
        r = k - 6'd16 - 3 * i;
        if (r < 6'd3) tsplit = {i[3:0], r[1:0]};
      end
    end
  endfunction
  wire [5:0]  f_ts = tsplit(fk);
  wire [85:0] u_word;
  wire [2:0]  u_tag;
  wire        u_snan, u_den, u_neg;

  se30_fpu_unpack unpack (
    .is_fp(src_is_fp), .fp(src_fp), .fmt(acmd[12:10]), .operand(opnd),
    .word(u_word), .tag(u_tag), .snan(u_snan), .den(u_den), .neg(u_neg));

  se30_fpu_apu #(.UROM_HEX(UROM_HEX), .NROM_HEX(NROM_HEX), .ENTRY_HEX(ENTRY_HEX),
                 .KROM_HEX(KROM_HEX), .NSEL_HEX(NSEL_HEX), .TADJ_HEX(TADJ_HEX)) apu (
    .clk(clk), .reset(reset), .ce(ce),
    .start(apu_start), .abort(apu_abort), .entry_idx(apu_idx), .cmd(acmd),
    .cu_word(zero_src ? 86'd0 : u_word), .cu_tag(zero_src ? TZERO : u_tag),
    .cu_snan(zero_src ? 1'b0 : u_snan), .cu_den(zero_src ? 1'b0 : u_den),
    .cu_neg(zero_src ? 1'b0 : u_neg),
    .operand(acmd[15:13] == 3'd3 ? {64'd0, dreg} : opnd),
    .busy(apu_busy), .clocks(dbg_clocks), .err(dbg_err),
    .fpcr_we(fpcr_we), .fpcr_d(fpcr_d), .fpsr_we(fpsr_we), .fpsr_d(fpsr_d),
    .fpcr(fpcr), .fpsr(fpsr),
    .fpb_addr(fpb_addr), .fpb_we(fpb_we), .fpb_d(fpb_d), .fpb_q(fpb_q),
    .obuf(obuf), .exop(dbg_exop),
    .save_req(sv_req), .susp(apu_susp), .in_pad(), .resume(apu_go),
    .ctx_we(ctx_we), .ctx_d(rs_ctx[190:28]), .ctx_q(ctx_q),
    .x_taddr(x_twe ? x_ta : f_ts[5:2]), .x_twe(x_twe), .x_td(x_td), .x_tq(x_tq),
    .x_exop_we(x_exop_we), .x_exop(rs_exop), .x_obuf_we(x_obuf_we), .x_obuf(rs_slot),
    .t_exec(), .t_upc());

  // the conditional predicate (the BIU's)
  reg  [5:0] pred;
  wire       c_taken, c_bsun;
  se30_fpu_cond cond (.pred(pred), .fpcc(fpsr[27:24]), .taken(c_taken), .bsun(c_bsun));

  // -- the BIU's state (the codes in bits 30-28 of 7c's BIU flags are
  //    derived from it: 111 idle, 011 general pending, 001 conditional
  //    pending, 100 operand write, 110 operand read) ----------------------
  localparam B_IDLE  = 5'd0,   // expecting a command or condition
             B_CMD   = 5'd1,   // a general instruction received, not started
             B_COND  = 5'd2,   // a conditional received, not evaluated
             B_PCW   = 5'd3,   // expecting the instruction address
             B_OPW   = 5'd4,   // expecting the operand (in)
             B_REL   = 5'd5,   // the operand is in: the next read releases ($0900)
             B_DREG  = 5'd6,   // expecting Dn (a dynamic k-factor)
             B_CONV  = 5'd7,   // a store converting
             B_OPR   = 5'd8,   // expecting the operand reads (out)
             B_FIN   = 5'd9,   // a CA = 1 store's final read
             B_CRW   = 5'd10,  // control registers in
             B_CRR   = 5'd11,  // control registers out
             B_MDREG = 5'd12,  // expecting Dn (a dynamic FMOVEM list)
             B_MPRIM = 5'd13,  // the next read gives the transfer-multiple
             B_RSEL  = 5'd14,  // expecting the register select read
             B_MMW   = 5'd15,  // FMOVEM in
             B_MMR   = 5'd16,  // FMOVEM out
             B_DONE  = 5'd17,  // the next read gives $0802
             B_TAKE  = 5'd18,  // a take-exception primitive is posted
             B_PV    = 5'd19,  // a protocol violation: $1D0D until XA
             B_HOLD  = 5'd20;  // a B, W or L source in, its instruction in the CU (7e):
                               // $8900 until the hand-off, then $0900
  reg [4:0]  bst, pc_next;
  assign dbg_state = bst;

  reg [31:0] fpiar;
  reg        pend, pend_rep;       // an exception pending; its primitive reported
  reg [7:0]  pend_vec;
  reg [15:0] take_prim;
  reg        take_fline;
  reg [15:0] restore_rd;
  reg [1:0]  n_long, i_long;       // operand longwords, and done so far
  reg        st_ca0;               // this store's evaluate-and-transfer is CA = 0
  reg        st_special;           // its source is a NaN, unnormal or denormal
  reg [2:0]  cr_mask;              // FMOVE control registers: still to move
  reg [7:0]  mm_mask;              // FMOVEM: registers still to move, bit 7 first
  reg        mm_have;              // FMOVEM out: the register is fetched
  reg [79:0] mm_buf;
  reg [3:0]  rst_cnt;              // a null restore clearing the registers
  reg        cu_busy;              // the CU is starting the APU
  reg [1:0]  mm_step;              // FMOVEM out: the fetch through port B
  reg        kill;                 // the APU was aborted: its end leaves nothing pending
  reg        conv_ok;              // a store's conversion ended a clock ago
  reg        apu_was_busy;

  // -- the CU's slot (7e, plan 8.9.6): the next general instruction, taken
  //    while the APU runs and handed to it when it is idle, no exception is
  //    pending and no save is awaited; its operand stays in opnd (the
  //    dialog's register - no other dialog starts while the slot is full)
  reg        cu_v;                 // the slot holds an instruction
  reg [15:0] cu_cmd;               // ... its command word
  reg [31:0] cu_iar;               // a passed PC whose instruction has not started:
  reg        cu_pcv;               //   FPIAR takes it when it does
  reg        pc_apu;               // the dialog's instruction is already in the APU
  reg        take_hold;            // a take mid-instruction from B_HOLD: back there after XA

  // -- the CU's own moves (7e-2, plan 8.9.6): the fully concurrent FMOVEs
  //    (UM Table 5-5) done without the APU, their FPSR effect and PC held
  //    while the APU runs an older instruction
  reg [1:0]  pk;                   // B_CMD: FPm being read for a move (3: in cu_fp)
  reg [1:0]  mi;                   // a move in: its operand widened (1), written (2), its time (3)
  reg [7:0]  mv_el, mv_T;          // a CU move's clocks so far, and its time (7e-3)
  reg [79:0] cu_fp;                // the move's value, a register image
  reg        cu_st;                // the dialog is the CU's store: its image in opnd
  reg        mv_pcw;               // a move's PC is still to come: it is held with it
  reg        take_cst;             // a take mid-instruction from the CU's store: back to B_CONV after XA
  reg        cu_fin;               // a move done (for the bench)
  reg        hv, h_ccv, h_iarv;    // the held effect: valid, FPCC in it, FPIAR in it
  reg [3:0]  h_cc;
  reg [7:0]  h_exc, h_aexc;
  reg [31:0] h_iar;

  // -- the CU's conversion (7e-3, plan 8.9.7): Table 8-13's input conversion
  //    for a register, X, S or D source is the CU's (UM 5.1.1.2), spent
  //    after the operand is in and before the hand-off; an integer source's
  //    conversion stays the APU's and holds the MPU meanwhile (Table 8-3,
  //    8.6.14 item 22), as FMOVECR does to its end.  The assembler moved
  //    the times out of the microcode (asm.py: `cu` and `hold` tables) into
  //    cvt, {table, source tag x 5 + destination tag}; cvsel gives an entry
  //    index's table, {hold, number}.
  reg [7:0]  cvt   [0:511];
  reg [7:0]  cvt_h [0:511];        // (a copy: the hold's read)
  reg [4:0]  cvsel [0:1023];
  reg [4:0]  cvsel_h [0:1023];
  initial begin
    $readmemh(CVT_HEX, cvt);
    $readmemh(CVT_HEX, cvt_h);
    $readmemh(CVSEL_HEX, cvsel);
    $readmemh(CVSEL_HEX, cvsel_h);
  end
  reg [3:0]  cv_st;                // the slot instruction's conversion: 0 none, 1-8 its steps, 9 counting
  reg [8:0]  cv_el;                // FPU clocks since its operand came
  reg [7:0]  cv_T;
  reg [79:0] cv_src, cv_dst;
  reg [4:0]  cvsel_q;
  reg [7:0]  cvt_q;
  reg        cu_v_q, cv_rest;
  reg        hold_on, hold_end;    // the MPU held: through an integer's conversion, to FMOVECR's end
  reg [8:0]  hold_t;
  reg [4:0]  hsel_q;
  reg [7:0]  hold_T;
  reg [1:0]  hold_tv;              // the APU's tags (and so hold_T) valid
  reg [7:0]  ho_el;                // clocks the slot has been ready to hand off

  // -- the command word (plan 8.6.7; the model's decode, vec.py) --------------
  wire [2:0] c_opclass = cmd[15:13];
  wire [2:0] c_rx      = cmd[12:10];
  wire       c_arith   = (c_opclass == 3'd0) || (c_opclass == 3'd2) || (c_opclass == 3'd3);
  wire       c_fmovecr = (c_opclass == 3'd2) && (c_rx == 3'd7);
  wire       c_illegal = (c_opclass == 3'd1)
                      || ((c_opclass == 3'd0 || c_opclass == 3'd2) && cmd[6])
                      || ((c_opclass == 3'd4 || c_opclass == 3'd5) && cmd[12:10] == 3'd0);
  wire       c_pcb     = c_arith && (fpcr[15:8] != 8'd0);          // pass the PC
  wire [15:0] pcbit    = c_pcb ? 16'h4000 : 16'h0000;

  // an input's length and longwords (L S X P W D B)
  function [3:0] in_len;
    input [2:0] f;
    case (f)
      3'd0, 3'd1: in_len = 4'd4;
      3'd2, 3'd3: in_len = 4'd12;
      3'd4:       in_len = 4'd2;
      3'd5:       in_len = 4'd8;
      default:    in_len = 4'd1;
    endcase
  endfunction
  // a store's length (L S X P W D B PK)
  function [3:0] out_len;
    input [2:0] f;
    case (f)
      3'd0, 3'd1: out_len = 4'd4;
      3'd4:       out_len = 4'd2;
      3'd5:       out_len = 4'd8;
      3'd6:       out_len = 4'd1;
      default:    out_len = 4'd12;
    endcase
  endfunction
  function [1:0] longs;
    input [3:0] len;
    longs = (len > 4'd8) ? 2'd3 : (len > 4'd4) ? 2'd2 : 2'd1;
  endfunction

  // the evaluate-and-transfer primitive of an input: the EA class (Table
  // 7-4: 101 data for B W L S, 110 memory for D X P) and CA
  wire [3:0]  i_len  = in_len(c_rx);
  wire        i_ca0  = (c_rx == 3'd1) || (c_rx == 3'd5) || (c_rx == 3'd2);
  wire [15:0] i_prim = {~i_ca0, 1'b0, 1'b0, 2'b10, (i_len > 4'd4) ? 3'b110 : 3'b101, 4'd0, i_len} | pcbit;
  // a store's: 001 data alterable for B W L S, 010 memory alterable else
  wire [3:0]  o_len  = out_len(c_rx);
  wire [15:0] o_prim = {~st_ca0, 1'b0, 1'b1, 2'b10, (o_len > 4'd4) ? 3'b010 : 3'b001, 4'd0, o_len};

  // FMOVE of the control registers: FPCR, FPSR, FPIAR in that order
  wire [1:0]  cr_n     = cmd[12] + cmd[11] + cmd[10];
  wire        cr_iar1  = (cmd[12:10] == 3'b001);
  wire [2:0]  cr_class = cr_iar1 ? (c_opclass[0] ? 3'b011 : 3'b111)
                       : (cr_n == 2'd1) ? (c_opclass[0] ? 3'b001 : 3'b101)
                       : (c_opclass[0] ? 3'b010 : 3'b110);
  wire [15:0] cr_prim  = {1'b1, 1'b0, c_opclass[0], 2'b10, cr_class, 4'd0, cr_n, 2'b00};

  // FMOVEM: the next register (the highest set bit of mm_mask) - in the
  // predecrement mode bit n is FPn, in the others bit 7 is FP0 (UM 4-79)
  wire       mm_predec = !cmd[12];
  reg  [2:0] mm_bit;
  always @* begin
    mm_bit = 3'd0;
    if      (mm_mask[7]) mm_bit = 3'd7;
    else if (mm_mask[6]) mm_bit = 3'd6;
    else if (mm_mask[5]) mm_bit = 3'd5;
    else if (mm_mask[4]) mm_bit = 3'd4;
    else if (mm_mask[3]) mm_bit = 3'd3;
    else if (mm_mask[2]) mm_bit = 3'd2;
    else if (mm_mask[1]) mm_bit = 3'd1;
    else                 mm_bit = 3'd0;
  end
  wire [2:0] mm_reg = mm_predec ? mm_bit : 3'd7 - mm_bit;
  wire [7:0] mm_clr = mm_mask & ~(8'd1 << mm_bit);

  // the entry-table index of a command word (fields.entry_general,
  // ENTRY_FMOVECR, entry_store)
  function is_fmovecr;
    input [15:0] w;
    is_fmovecr = (w[15:13] == 3'd2) && (w[12:10] == 3'd7);
  endfunction
  function [9:0] idx_fn;
    input [15:0] w;
    idx_fn = (w[15:13] == 3'd0) ? {4'd0, w[5:0]}
           : is_fmovecr(w)      ? 10'h200
           : (w[15:13] == 3'd2) ? {1'b0, w[12:10] + 3'd1, w[5:0]}
           :                      10'h208 + {7'd0, w[12:10]};
  endfunction
  // the classes the CU takes while the APU runs (7e-1): arithmetic from an
  // FP register, or from memory in any format but packed (UM Tables 5-1,
  // 5-4; FMOVECR, packed, stores, FMOVEM and the control registers wait)
  wire c_ov = (c_opclass == 3'd0) || ((c_opclass == 3'd2) && !c_fmovecr && c_rx != 3'd3);

  // -- the bus access -----------------------------------------------------------
  wire acc_sync = rw && (a[4:1] == 4'b0000 || a[4:1] == 4'b0010);   // response, save
  wire acc_long = a[4];
  reg  served, sync_arm;
  reg  [1:0] sync_cnt;
  // idle once the APU's end has been seen (a clock after busy falls), so
  // the pending exception it left is registered before anything reads it
  // (nor about to resume a restored busy frame's instruction: its context
  // is loaded while the APU is idle, and nothing may start in between - 7e)
  wire apu_idle = !apu_busy && !apu_was_busy && !cu_busy && !apu_start && !go_pend && !apu_go;

  // -- the CU's moves (7e-2): UM Table 5-5 and its notes -------------------------
  //   FMOVE FPm,FPn; FMOVE <ea>,FPn in S, D, X; FMOVE FPm,<ea> in S, D, X.
  //   (a) FPm, (f) FPn the APU instruction's destination; (b) a NaN,
  //   unnormal or denormal - here anything but a normalized number, a zero
  //   with exponent 0 or an infinity with mantissa 0; (c) PREC not extended
  //   (moves to a register); (d) INEX2 enabled, (e) the store over- or
  //   underflowing (S and D).  The results are the model's (fpu.py
  //   _op_fmove, fmove_out): exact to a register with FPCC set and EXC
  //   cleared; a store rounded by RND alone, EXC INEX2 if inexact, AEXC's
  //   INEX from it, FPCC unchanged; UNFL judged before rounding.
  wire        c_sdx    = (c_rx == 3'd1) || (c_rx == 3'd5) || (c_rx == 3'd2);
  wire        c_mv_rr  = (c_opclass == 3'd0) && (cmd[6:0] == 7'd0);
  wire        c_mv_in  = (c_opclass == 3'd2) && c_sdx && (cmd[6:0] == 7'd0);
  wire        c_mv_out = (c_opclass == 3'd3) && c_sdx;
  wire        prec_x   = (fpcr[7:6] == 2'd0);
  wire        c_inx_en = (c_rx != 3'd2) && fpcr[9];
  wire [2:0]  c_fpm    = c_opclass[0] ? cmd[9:7] : cmd[12:10];       // a store's source is ry
  // the instruction the APU runs (being started, or its own copy - which
  // a restored busy frame reloads, the clock after the frame's end: until
  // then the frame's) and the FP registers it writes: FPn, and FSINCOS's
  // FPc; not FCMP, FTST, nor a store
  wire [15:0] a_run    = (cu_busy || apu_start) ? acmd : ctx_we ? rs_ctx[55:40] : ctx_q[27:12];
  function a_writes;
    input [15:0] w;
    input [2:0]  r;
    a_writes = ((w[15:13] == 3'd0) || (w[15:13] == 3'd2)) &&
               (is_fmovecr(w) ? (r == w[9:7])
                              : (w[6:0] != 7'h38) && (w[6:0] != 7'h3A) &&
                                ((r == w[9:7]) || ((w[6:3] == 4'b0110) && (r == w[2:0]))));
  endfunction
  wire        conf_a   = !apu_idle && a_writes(a_run, c_fpm);
  wire        conf_f   = !apu_idle && a_writes(a_run, cmd[9:7]);
  // a register image's class: 0 anything the CU hands over, 1 zero, 2 infinity, 3 normalized
  function [1:0] fcls;
    input [79:0] x;
    fcls = (x[78:0] == 79'd0)       ? 2'd1
         : (x[78:64] == 15'h7FFF)   ? ((x[63:0] == 64'd0) ? 2'd2 : 2'd0)
         : x[63]                    ? 2'd3 : 2'd0;
  endfunction
  function [3:0] fcc;              // FPCC: N Z I NAN
    input [79:0] x;
    fcc = {x[79], fcls(x) == 2'd1, fcls(x) == 2'd2, 1'b0};
  endfunction
  // S, D or X widened to a register image (a denormal keeps no integer
  // bit, so fcls hands it over)
  function [79:0] widen;
    input [2:0]  f;
    input [95:0] o;
    case (f)
      3'd1: widen = (o[30:23] == 8'hFF) ? {o[31], 15'h7FFF, (o[22:0] == 23'd0) ? 64'd0 : {1'b1, o[22:0], 40'd0}}
                  : (o[30:23] == 8'd0)  ? {o[31], 15'd0, 1'b0, o[22:0], 40'd0}
                  :                       {o[31], {7'd0, o[30:23]} + 15'd16256, 1'b1, o[22:0], 40'd0};
      3'd5: widen = (o[62:52] == 11'h7FF) ? {o[63], 15'h7FFF, (o[51:0] == 52'd0) ? 64'd0 : {1'b1, o[51:0], 11'd0}}
                  : (o[62:52] == 11'd0)   ? {o[63], 15'd0, 1'b0, o[51:0], 11'd0}
                  :                         {o[63], {4'd0, o[62:52]} + 15'd15360, 1'b1, o[51:0], 11'd0};
      default: widen = {o[95], o[94:80], o[63:0]};
    endcase
  endfunction

  // the store's image, right-aligned as the store's operand reads want it;
  // st_ok: the CU can make it (not (b), (e)); st_inx: inexact
  wire [1:0]  pk_cls = fcls(cu_fp);
  wire        pk_s   = cu_fp[79];
  wire [14:0] pk_e   = cu_fp[78:64];
  wire [63:0] pk_m   = cu_fp[63:0];
  wire [1:0]  rnd    = fpcr[5:4];                                   // RN RZ RM RP
  wire        dbl    = (c_rx == 3'd5);
  wire [52:0] k_keep = dbl ? pk_m[63:11] : {29'd0, pk_m[63:40]};
  wire        k_g    = dbl ? pk_m[10] : pk_m[39];
  wire        k_s    = dbl ? (pk_m[9:0] != 10'd0) : (pk_m[38:0] != 39'd0);
  wire        k_inx  = k_g || k_s;
  wire        k_up   = (rnd == 2'd0) ? (k_g && (k_s || k_keep[0]))
                     : (rnd == 2'd2) ? (pk_s && k_inx)
                     : (rnd == 2'd3) ? (!pk_s && k_inx) : 1'b0;
  wire [53:0] k_sum  = {1'b0, k_keep} + {53'd0, k_up};
  wire        k_cy   = dbl ? k_sum[53] : k_sum[24];
  wire [15:0] k_be   = {1'b0, pk_e} - (dbl ? 16'd15360 : 16'd16256) + {15'd0, k_cy};   // biased, after rounding
  wire        k_tiny = dbl ? (pk_e < 15'd15361) : (pk_e < 15'd16257);
  wire        k_ovf  = dbl ? (k_be >= 16'd2047) : (k_be >= 16'd255);
  reg  [95:0] st_img;
  always @* begin
    if (c_rx == 3'd2)
      st_img = (pk_cls == 2'd1) ? {pk_s, 95'd0} : {pk_s, pk_e, 16'd0, pk_m};
    else if (dbl)
      st_img = (pk_cls == 2'd1) ? {32'd0, pk_s, 63'd0}
             : (pk_cls == 2'd2) ? {32'd0, pk_s, 11'h7FF, 52'd0}
             :                    {32'd0, pk_s, k_be[10:0], k_cy ? 52'd0 : k_sum[51:0]};
    else
      st_img = (pk_cls == 2'd1) ? {64'd0, pk_s, 31'd0}
             : (pk_cls == 2'd2) ? {64'd0, pk_s, 8'hFF, 23'd0}
             :                    {64'd0, pk_s, k_be[7:0], k_cy ? 23'd0 : k_sum[22:0]};
  end
  wire        st_norm = (pk_cls == 2'd3) && (c_rx != 3'd2);
  wire        st_ok   = (pk_cls != 2'd0) && !(st_norm && (k_tiny || k_ovf));
  wire        st_inx  = st_norm && k_inx;

  // at the first response read: the CU tries the move (FPm read first, pk);
  // (a) waits for the APU, the rest go the APU's way (the slot, or at once)
  wire cu_try  = ((c_mv_rr && prec_x) || (c_mv_out && !c_inx_en)) && !c_illegal &&
                 !cu_v && !cu_busy && !pend;
  wire cu_hold = cu_try && (conf_a || pk != 2'd3);
  wire cu_do_rr = cu_try && c_mv_rr && !conf_a && pk == 2'd3 && pk_cls != 2'd0 && !conf_f;
  wire cu_do_st = cu_try && c_mv_out && !conf_a && pk == 2'd3 && st_ok;

  // -- 7e-3: the conversion's and the hold's readiness --------------------------------
  // Table 8-13's class of a register image, as the APU's tag logic makes it
  function [2:0] itag;
    input [79:0] x;
    itag = (x[78:64] == 15'h7FFF) ? ((x[62:0] != 63'd0) ? `TAG_NAN : `TAG_INF)
         : (x[63:0] == 64'd0)     ? `TAG_ZERO
         : x[63]                  ? `TAG_NORM : `TAG_UNN;
  endfunction
  // what each format's dialog leaves over, against Table 8-3's heads for
  // the typical operand (calibrated, 8.9.7): added to Table 8-13's time
  localparam signed [9:0] K_REG = -10'sd8, K_S = -10'sd2, K_D = 10'sd2, K_X = 10'sd10, K_INT = -10'sd12;
  // a monadic operation's memory source: the 68881's in-memory monadic
  // figures are 2 below the dyadic ones, the 68882's heads are not; an
  // integer's hold for a monadic operation (cv_intm) 6 more
  localparam signed [9:0] K_MONO = 10'sd2, K_INTM = 10'sd6;
  localparam [8:0] HOLD_K = 9'd0;
  localparam [3:0] D_REG = 4'd4;   // a register source's hand-off (Table 8-3: total = H + T + 4)
  // the CU's own moves' times (Table 8-3: FMOVE to FPn 21/34/40/46, to
  // memory 38/44/50), counted from the operand's arrival - the CU busy
  localparam [7:0] M_RR = 8'd11, M_S = 8'd19, M_D = 8'd21, M_X = 8'd23,
                   MO_S = 8'd20, MO_D = 8'd24, MO_X = 8'd22;
  function [7:0] m_in;  input [2:0] f; m_in  = (f == 3'd1) ? M_S  : (f == 3'd5) ? M_D  : M_X;  endfunction
  function [7:0] m_out; input [2:0] f; m_out = (f == 3'd1) ? MO_S : (f == 3'd5) ? MO_D : MO_X; endfunction
  function signed [9:0] cvk;
    input [15:0] w;
    input [3:0]  id;                 // cvsel's table: 3, 5, 7 the monadic S/D/X ones, 9 an integer's monadic
    cvk = ((id == 4'd3 || id == 4'd5 || id == 4'd7) ? K_MONO : (id == 4'd9) ? K_INTM : 10'sd0) +
          ((w[15:13] == 3'd0) ? K_REG
        : (w[15:13] != 3'd2) ? 10'sd0
        : (w[12:10] == 3'd1) ? K_S : (w[12:10] == 3'd5) ? K_D : (w[12:10] == 3'd2) ? K_X
        : (w[12:10] == 3'd0 || w[12:10] == 3'd4 || w[12:10] == 3'd6) ? K_INT : 10'sd0);
  endfunction
  // the slot's instruction converted: its time spent (none to spend: a
  // restored frame's, an integer's, a packed one's)
  // an integer's time is not a conversion before the hand-off but a wait
  // after it, the MPU held (the APU converts: Table 8-3's H + 19 + T)
  wire cv_rdy  = (cv_st == 4'd0) || (cv_st == 4'd9 && (cvsel_q[4] || cv_el >= {1'b0, cv_T}));
  wire [7:0] ho_need = (cv_st == 4'd9 && cvsel_q[4]) ? cv_T
                     : (cu_cmd[15:13] == 3'd0) ? {4'd0, D_REG} : 8'd0;
  // the MPU may go: no hold, or the integer's conversion spent since the
  // APU started (its own tags: they are the dispatch's), or FMOVECR ended
  wire hold_ok = !hold_on || (hold_end ? (apu_idle && !hv)
                                       : (apu_idle || (hold_tv == 2'd3 && hold_t >= {1'b0, hold_T} + HOLD_K)));
  wire [4:0] cv_tp = {2'd0, itag(cv_src)} * 5'd5 + {2'd0, itag(cv_dst)};
  wire [31:0] cu_iv = (cu_cmd[12:10] == 3'd0) ? opnd[31:0] :
                      (cu_cmd[12:10] == 3'd4) ? {16'd0, opnd[15:0]} : {24'd0, opnd[7:0]};
  wire [4:0] ap_tp = {2'd0, ctx_q[11:9]} * 5'd5 + {2'd0, ctx_q[5:3]};   // the APU's stag, dtag

  // an access the FPU may not acknowledge yet
  wire opr_early = rw && (a[4:2] == 3'b100) &&
                   ((bst == B_CONV) ||
                    ((bst == B_CMD || bst == B_MPRIM) && (c_opclass == 3'd3 || c_opclass == 3'd7)));
  wire acc_wait  = (rst_cnt != 4'd0) ||
                   ((sv_on || rs_on) ? (sv_on && rw && (a[4:2] == 3'b100) && fwait != 2'd0)
                                     : (!dead && (opr_early ||
                                                  (rw && (a[4:2] == 3'b100) && (bst == B_MMR) && !mm_have))));
  wire acc_fire  = cs && !served && (acc_sync ? (sync_arm && sync_cnt == 2'd0) : !acc_wait);

  always @(posedge clk) begin
    if (reset || !cs) begin
      served <= 1'b0;
      sync_arm <= 1'b0;
      dsack_n <= 2'b11;
    end else if (!served) begin
      if (acc_sync && !sync_arm) begin
        if (ce) begin sync_arm <= 1'b1; sync_cnt <= 2'd2; end
      end else if (acc_sync && sync_cnt != 2'd0)
        sync_cnt <= sync_cnt - 2'd1;
      if (acc_fire) begin
        served <= 1'b1;
        dsack_n <= acc_long ? 2'b00 : 2'b01;
      end
    end
  end

  // -- the BIU and the CU ----------------------------------------------------------
  reg [31:0] rdata;                // what this access reads

  // the store's operand, MSB-aligned, longword i_long of n_long
  wire [95:0] ob = cu_st ? opnd : obuf;                  // the CU's store's image (7e-2), or the APU's
  reg  [31:0] st_long;
  always @* begin
    case (c_rx)
      3'd6:    st_long = {ob[7:0], 24'd0};
      3'd4:    st_long = {ob[15:0], 16'd0};
      3'd0,
      3'd1:    st_long = ob[31:0];
      3'd5:    st_long = (i_long == 2'd0) ? ob[63:32] : ob[31:0];
      default: st_long = (i_long == 2'd0) ? ob[95:64] : (i_long == 2'd1) ? ob[63:32] : ob[31:0];
    endcase
  end

  // -- the frame (8.9.3) ---------------------------------------------------------
  // the phase: the dialog receiving an instruction's operands (6.4.3.3)
  wire f_initial = (bst == B_PCW) || (bst == B_OPW) || (bst == B_DREG) || (bst == B_CRW) ||
                   (bst == B_MDREG) || (bst == B_MPRIM) || (bst == B_RSEL) || (bst == B_MMW);
  wire f_rdpend  = (bst == B_OPR) || (bst == B_CRR) || (bst == B_MMR);
  wire f_wrpend  = (bst == B_OPW) || (bst == B_DREG) || (bst == B_MDREG) || (bst == B_CRW) ||
                   (bst == B_MMW);
  wire [2:0] f_code = (bst == B_CMD)  ? 3'b011 : (bst == B_COND) ? 3'b001 :
                      f_wrpend        ? 3'b100 : f_rdpend        ? 3'b110 : 3'b111;
  // the BIU flags (Figure 6-6): the CU's bits and 15-0 as WinUAE writes them
  wire [31:0] f_flags = {bst == B_PV, f_code, !pend, !f_rdpend, 2'b00,
                         (bst == B_OPR) ? 4'hF : 4'h0, 4'hE, 16'hFFFF};
  wire [95:0] f_slot  = (bst == B_OPW || cu_v || cu_st) ? opnd : (bst == B_MMW) ? {mm_buf, 16'd0} : obuf;
  // longword 8: the CU's moves (7e-2) - the held effect, a move's PC
  // awaited, the dialog the CU's store
  wire [31:0] f_mv    = {hv, h_ccv, h_iarv, mv_pcw, cu_st, take_cst, 6'd0, h_cc, h_exc, h_aexc};
  wire [31:0] f_ctl   = {bst, pc_next, n_long, i_long, st_ca0, st_special, cr_mask, take_fline,
                         mm_mask, cu_v, cu_pcv, pc_apu, take_hold};
  wire [191:0] f_apu  = {apu_susp, ctx_q, 28'd0};
  reg  [31:0] f_lw;                // longword fk of the frame being saved
  always @* begin
    f_lw = 32'd0;
    if (fk == 6'd1)                          f_lw = {img, 16'd0};
    else if (fk >= 6'd2 && fk <= 6'd4)       f_lw = f_slot[95 - 32 * (fk - 6'd2) -: 32];
    else if (fk == 6'd5)                     f_lw = f_ctl;
    else if (fk == 6'd6)                     f_lw = {take_prim, cu_cmd};
    else if (fk == 6'd7)                     f_lw = cu_iar;
    else if (fk == 6'd8)                     f_lw = f_mv;
    else if (fk == 6'd9)                     f_lw = h_iar;
    else if (fk == f_n)                      f_lw = f_flags;
    else if (fk == f_n - 6'd1)               f_lw = (bst == B_OPR) ? st_long : 32'd0;
    else if (fk == f_n - 6'd4)               f_lw = {dbg_exop[79:64], 16'd0};
    else if (fk == f_n - 6'd3)               f_lw = dbg_exop[63:32];
    else if (fk == f_n - 6'd2)               f_lw = dbg_exop[31:0];
    else if (fbz && fk >= 6'd10 && fk <= 6'd15) f_lw = f_apu[191 - 32 * (fk - 6'd10) -: 32];
    else if (fbz && fk >= 6'd16 && fk <= 6'd48)
      f_lw = (f_ts[1:0] == 2'd0) ? x_tq[85:54] : (f_ts[1:0] == 2'd1) ? x_tq[53:22] : {x_tq[21:0], 10'd0};
  end

  // a protocol violation (UM 6.1.12's four rules, and the register select
  // write): the access class against what the state expects
  wire w_cmd  = !rw && (a[4:1] == 4'b0101 || a[4:1] == 4'b0111);
  wire x_opr  = (a[4:2] == 3'b100);
  wire x_rsel = (a[4:1] == 4'b1010);
  wire x_ia   = (a[4:2] == 3'b110);
  wire exp_opw = (bst == B_OPW) || (bst == B_DREG) || (bst == B_MDREG) || (bst == B_CRW) || (bst == B_MMW);
  wire exp_rd  = (bst == B_OPR) || (bst == B_CRR) || (bst == B_MMR) || (bst == B_RSEL);
  reg  viol;
  always @* begin
    viol = 1'b0;
    if (x_rsel && !rw) viol = 1'b1;
    if (bst == B_IDLE)
      viol = viol | x_rsel | x_opr | (x_ia && !rw);
    else if (exp_rd)
      viol = viol | (!rw && (w_cmd || x_opr || x_ia))
                  | (rw && x_opr && bst == B_RSEL) | (rw && x_rsel && bst != B_RSEL);
    else if (exp_opw)
      viol = viol | w_cmd | (rw && (x_rsel || x_opr || x_ia));
    else if (bst == B_PCW)
      viol = viol | (!rw && (w_cmd || x_opr)) | (rw && (x_opr || x_rsel));
    else if (bst == B_PV || bst == B_TAKE)
      viol = 1'b0;
    else
      // the initial phase of a general instruction, a conditional not yet
      // read, a store converting or ending: no command, no condition, no
      // operand but the ones above
      viol = viol | w_cmd | (x_opr && !opr_early) | x_rsel;
  end

  task start_apu;                  // the CU starts the APU on a command
    input fp_src;                  // the source is an FP register
    input [2:0] r;
    input [15:0] w;                // the command word
    begin
      acmd     <= w;
      apu_idx  <= idx_fn(w);
      zero_src <= is_fmovecr(w);
      src_is_fp <= fp_src;
      fpb_addr <= r;
      cu_busy  <= 1'b1;
      if (cu_pcv) begin fpiar <= cu_iar; cu_pcv <= 1'b0; end   // its passed PC is FPIAR now
    end
  endtask

  reg [1:0] cu_step;

  // the CU's frame fields (longwords 5 and 6 of the idle frame, 8.8.15):
  // the reset state, and the null restore's, so every frame saved is defined
  task cu_clear;
    begin
      pc_next <= B_IDLE; n_long <= 2'd0; i_long <= 2'd0; st_ca0 <= 1'b0; st_special <= 1'b0;
      cr_mask <= 3'd0; mm_mask <= 8'd0; take_prim <= 16'd0; pend_vec <= 8'd0;
      cu_v <= 1'b0; cu_cmd <= 16'd0; cu_iar <= 32'd0; cu_pcv <= 1'b0; pc_apu <= 1'b0;
      take_hold <= 1'b0; acmd <= 16'd0;
      pk <= 2'd0; mi <= 2'd0; cu_fp <= 80'd0; cu_st <= 1'b0; mv_pcw <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0; mv_el <= 8'd0; mv_T <= 8'd0;
      cv_st <= 4'd0; cv_el <= 9'd0; cv_T <= 8'd0; cv_src <= 80'd0; cv_dst <= 80'd0;
      hold_on <= 1'b0; hold_end <= 1'b0; hold_t <= 9'd0; cv_rest <= 1'b0;
      hv <= 1'b0; h_ccv <= 1'b0; h_iarv <= 1'b0; h_cc <= 4'd0; h_exc <= 8'd0; h_aexc <= 8'd0;
      h_iar <= 32'd0;
    end
  endtask

  // a CU move done: its FPSR effect joins the held one (the last FPCC and
  // EXC, the AEXC bits ORed); FPIAR joins it when the move passes its PC
  task h_rec;
    input       fv;                // a move to a register: FPCC
    input [3:0] cc;
    input [7:0] ex;
    input [7:0] ax;
    begin
      hv <= 1'b1;
      h_ccv <= fv | (hv & h_ccv);
      if (fv) h_cc <= cc;
      h_exc <= ex;
      h_aexc <= (hv ? h_aexc : 8'd0) | ax;
      if (!hv) h_iarv <= 1'b0;
      cu_fin <= 1'b1;
    end
  endtask

  task restore_start;              // a restore CIR write: abort everything, check the word
    begin
      sv_on <= 1'b0; rs_on <= 1'b0; sv_req <= 1'b0; dead <= 1'b0;
      apu_go <= 1'b0; go_pend <= 1'b0;
      bst <= B_IDLE; take_fline <= 1'b0;
      apu_abort <= 1'b1; apu_start <= 1'b0; cu_busy <= 1'b0; cu_step <= 2'd0;
      cu_v <= 1'b0; cu_pcv <= 1'b0; take_hold <= 1'b0;     // the CU's instruction too
      mi <= 2'd0; cu_st <= 1'b0; mv_pcw <= 1'b0; hv <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;   // and its moves (a frame reinstates them)
      if (din[31:24] == 8'h00) begin                        // null: the reset state
        restore_rd <= din[31:16];
        pend <= 1'b0; pend_rep <= 1'b0; used <= 1'b0;
        rst_cnt <= 4'd8;
        cu_clear;
      end else if (din[31:16] == 16'h1F38 || din[31:16] == 16'h1FD4) begin
        restore_rd <= din[31:16];
        rs_on <= 1'b1; fbz <= din[23]; fk <= 6'd1;
      end else
        restore_rd <= 16'h0238;
    end
  endtask

  always @(posedge clk) begin
    fpcr_we <= 1'b0;
    fpsr_we <= 1'b0;
    if (!ce) fpb_we <= 1'b0;       // port B's p0 edge takes a write (7e); until then it stands
    apu_abort <= 1'b0;
    ctx_we <= 1'b0; x_twe <= 1'b0; x_exop_we <= 1'b0; x_obuf_we <= 1'b0;
    cu_fin <= 1'b0;
    if (reset) begin
      used <= 1'b0; sv_req <= 1'b0; sv_on <= 1'b0; rs_on <= 1'b0; dead <= 1'b0; fbz <= 1'b0;
      apu_go <= 1'b0; go_pend <= 1'b0; fk <= 6'd1; fwait <= 2'd0; img <= 16'd0;
      bst <= B_IDLE;
      pend <= 1'b0; pend_rep <= 1'b0; take_fline <= 1'b0;
      cu_clear;
      fpb_we <= 1'b0;
      apu_start <= 1'b0; cu_busy <= 1'b0; cu_step <= 2'd0; mm_step <= 2'd0;
      kill <= 1'b1; conv_ok <= 1'b0;
      restore_rd <= 16'h0000;
      rst_cnt <= 4'd8;             // the reset state is the null restore's
      fpiar <= 32'd0;
      apu_was_busy <= 1'b0;
      apu_abort <= 1'b1;
    end else begin
      // the CU starting the APU: fetch the source through port B, then start
      // (steps 0 and 1 at p1 edges: the p0 edge between them reads fpb_addr)
      if (cu_busy) begin
        case (cu_step)
          2'd0: if (ce) cu_step <= 2'd1;
          2'd1: if (ce) begin src_fp <= fpb_q; cu_step <= 2'd2; end
          2'd2: begin apu_start <= 1'b1; kill <= 1'b0; cu_step <= 2'd3; end
          default:
            if (apu_busy) begin
              apu_start <= 1'b0; cu_busy <= 1'b0; cu_step <= 2'd0;
              st_special <= (u_tag == `TAG_NAN) || (u_tag == `TAG_UNN) || u_den;
            end
        endcase
      end
      // the APU's end: the pending exception (EXC AND ENABLE)
      apu_was_busy <= apu_busy;
      if (apu_was_busy && !apu_busy) begin
        if (!kill && fpu_trapvec(fpsr, fpcr) != 8'd0) begin
          pend <= 1'b1;
          pend_vec <= fpu_trapvec(fpsr, fpcr);
          pend_rep <= 1'b0;
        end
        kill <= 1'b0;
      end
      if (apu_abort) kill <= 1'b1;
      conv_ok <= (bst == B_CONV) && apu_idle;
      // the frames' housekeeping: the resume after a context load, the
      // wait for a temporary's read
      if (go_pend) begin apu_go <= 1'b1; go_pend <= 1'b0; end
      if (apu_go && apu_busy && !apu_susp) apu_go <= 1'b0;
      if (fwait != 2'd0) fwait <= fwait - 2'd1;
      // the null restore's clearing of the registers, one at each p1 edge
      // (port B writes it at the p0 edge after)
      if (rst_cnt != 4'd0 && ce) begin
        rst_cnt <= rst_cnt - 4'd1;
        fpb_addr <= rst_cnt[2:0] - 3'd1;
        fpb_d <= FP_NAN;
        fpb_we <= 1'b1;
        fpcr_we <= 1'b1; fpcr_d <= 32'd0;
        fpsr_we <= 1'b1; fpsr_d <= 32'd0;
        fpiar <= 32'd0;
      end
      // FMOVEM out: fetch the next register
      // (the address from step 0's p1 edge, read at the p0 edge after it,
      // latched at the next p1 edge)
      if (bst == B_MMR && !mm_have) begin
        fpb_addr <= mm_reg;
        if (ce) begin
          if (mm_step == 2'd1) begin mm_buf <= fpb_q; mm_have <= 1'b1; mm_step <= 2'd0; end
          else mm_step <= 2'd1;
        end
      end

      // the CU's moves (7e-2).  In B_CMD, FPm is read for a move the CU may
      // do itself (the address set, then two p1 edges: the p0 edge between
      // them reads it); it is decided at the next response read.
      if (bst != B_CMD || conf_a) pk <= 2'd0;             // (a conflict seen: read it again after)
      else
        case (pk)
          2'd0: if (cu_try && !conf_a && !fpb_we && rst_cnt == 4'd0) begin
                  fpb_addr <= c_fpm; pk <= 2'd1;
                end
          2'd1: if (ce) pk <= 2'd2;
          2'd2: if (ce) begin cu_fp <= fpb_q; pk <= 2'd3; end
          default: ;
        endcase
      // a move in (FMOVE <ea>,FPn): its operand widened, then FPn written
      // through port B - or handed to the APU through the slot: (b), (f),
      // or an exception pending (it waits there for the handler, UM 5.2.3.6)
      if ((mi != 2'd0 || cu_st) && ce && mv_el != 8'hFF) mv_el <= mv_el + 8'd1;
      case (mi)
        2'd1: begin cu_fp <= widen(cu_cmd[12:10], opnd); mi <= 2'd2; end
        2'd2:
          if (!fpb_we && !(hv && apu_idle && !pend)) begin
            if (fcls(cu_fp) != 2'd0 && !pend && !(!apu_idle && a_writes(a_run, cu_cmd[9:7]))) begin
              fpb_addr <= cu_cmd[9:7]; fpb_d <= cu_fp; fpb_we <= 1'b1;
              h_rec(1'b1, fcc(cu_fp), 8'd0, 8'd0);
              if (cu_pcv) begin h_iar <= cu_iar; h_iarv <= 1'b1; cu_pcv <= 1'b0; end
              mv_T <= m_in(cu_cmd[12:10]); mi <= 2'd3;             // the CU busy for the move's time
            end else begin
              cu_v <= 1'b1; mi <= 2'd0;
            end
          end
        2'd3: if (mv_el >= mv_T) mi <= 2'd0;
        default: ;
      endcase
      // the held effect applied once the older instruction has ended with
      // nothing pending (after its own FPSR write), the move's PC in
      if (hv && apu_idle && !pend && !mv_pcw && !sv_req && !sv_on && !rs_on && rst_cnt == 4'd0) begin
        fpsr_we <= 1'b1;
        fpsr_d  <= {4'd0, h_ccv ? h_cc : fpsr[27:24], fpsr[23:16], h_exc, fpsr[7:0] | h_aexc};
        if (h_iarv) fpiar <= h_iar;
        hv <= 1'b0; h_ccv <= 1'b0; h_iarv <= 1'b0;
      end

      // 7e-3 (plan 8.9.7): the slot instruction's conversion, the CU's -
      // its table and its tags (the source's and FPn's, read through port
      // B as the APU's tag logic would class them), then its time from the
      // operand's arrival; a restored slot's was spent before its save
      cu_v_q <= cu_v; cv_rest <= 1'b0;
      cvsel_q <= cvsel[idx_fn(cu_cmd)];
      cvt_q   <= cvt[{cvsel_q[3:0], cv_tp}];
      if (cu_v && !cu_v_q && !cv_rest) begin cv_st <= 4'd1; cv_el <= 9'd0; end
      else if (!cu_v) cv_st <= 4'd0;
      else if (cv_st != 4'd0) begin
        if (ce && cv_el != 9'h1FF) cv_el <= cv_el + 9'd1;
        case (cv_st)
          4'd1: cv_st <= 4'd2;                                  // (cvsel_q follows cu_cmd)
          4'd2: if (cvsel_q[3:0] == 4'd0) begin                // no conversion time (packed)
                  cv_T <= 8'd0; cv_st <= 4'd9;
                end else if (cvsel_q[4]) begin                   // an integer: zero or normalized
                  cv_src <= (cu_iv == 32'd0) ? 80'd0 : {1'b0, 15'h3FFF, 1'b1, 63'd0};
                  cv_st <= 4'd5;
                end else if (!fpb_we && rst_cnt == 4'd0) begin
                  if (cu_cmd[15:13] == 3'd0) begin fpb_addr <= cu_cmd[12:10]; cv_st <= 4'd3; end
                  else begin cv_src <= widen(cu_cmd[12:10], opnd); cv_st <= 4'd5; end
                end
          4'd3: if (ce) cv_st <= 4'd4;                          // (the read as the peek's)
          4'd4: if (ce) begin cv_src <= fpb_q; cv_st <= 4'd5; end
          4'd5: if (!fpb_we && rst_cnt == 4'd0) begin fpb_addr <= cu_cmd[9:7]; cv_st <= 4'd6; end
          4'd6: if (ce) cv_st <= 4'd7;
          4'd7: if (ce) begin cv_dst <= fpb_q; cv_st <= 4'd8; end
          4'd8: cv_st <= 4'd10;                                 // (cvt_q follows the tags)
          4'd10: begin                                          // Table 8-13's time and the format's rest
                  cv_T <= ($signed({2'b00, cvt_q}) + cvk(cu_cmd, cvsel_q[3:0]) < 0) ? 8'd0
                        : cvt_q + cvk(cu_cmd, cvsel_q[3:0]);
                  cv_st <= 4'd9;
                end
          default: ;
        endcase
      end
      // the hold: an integer source's conversion time (its table, the APU's
      // own tags) from the APU's start; FMOVECR to its end
      hsel_q <= cvsel_h[idx_fn(acmd)];
      hold_T <= cvt_h[{hsel_q[3:0], ap_tp}];
      if (!hold_on) hold_tv <= 2'd0;
      else if (apu_busy && hold_tv != 2'd3) hold_tv <= hold_tv + 2'd1;
      if (ce && hold_t != 9'h1FF) hold_t <= hold_t + 9'd1;

      // the hand-off (7e): the CU's instruction to the idle APU - not while
      // an exception is pending (it waits for the handler's FRESTORE, UM
      // 5.2.3.6), a save is awaited or a frame moves, nor while its PC is
      // still to come; a save or restore access in progress wins the edge.
      // A held move effect is applied first, and a CU write lands first.
      if (cu_v && apu_idle && !pend && !sv_req && !sv_on && !rs_on && bst != B_PCW &&
          !hv && !fpb_we && cv_rdy && cu_v_q &&
          !(cs && (a[4:1] == 4'b0010 || a[4:1] == 4'b0011))) begin
        if (ce && ho_el != 8'hFF) ho_el <= ho_el + 8'd1;
        if (ho_el >= ho_need) begin
          start_apu(cu_cmd[15:13] == 3'd0, cu_cmd[12:10], cu_cmd);
          cu_v <= 1'b0;
        end
      end else
        ho_el <= 8'd0;

      // -- one bus access ------------------------------------------------------
      if (acc_fire) begin
        rdata = 32'hFFFFFFFF;
        if (sv_on || rs_on) begin
          // -- a frame in transit: its operand accesses; a save read is the
          //    nested FSAVE of 7.5.4.6; AB ends it; the rest are ignored
          if (rw && a[4:1] == 4'b0000)      rdata[31:16] = 16'h0802;
          else if (rw && a[4:1] == 4'b0010) rdata[31:16] = 16'h0238;
          else if (rw && a[4:1] == 4'b0011) rdata[31:16] = restore_rd;
          else if (!rw && a[4:1] == 4'b0011) restore_start;
          else if (!rw && a[4:1] == 4'b0001) begin
            if (din[16]) begin                                    // AB
              dead <= 1'b1;
              if (sv_on) begin                                    // the chip is left idle
                sv_on <= 1'b0; bst <= B_IDLE; pend <= 1'b0; pend_rep <= 1'b0; take_fline <= 1'b0;
                cu_v <= 1'b0; cu_pcv <= 1'b0; take_hold <= 1'b0;
                cu_st <= 1'b0; mv_pcw <= 1'b0; hv <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;
                if (apu_susp) apu_abort <= 1'b1;
              end
              rs_on <= 1'b0;
            end
          end else if (x_opr && rw && sv_on) begin                // FSAVE: highest first
            rdata = f_lw;
            if (fk == 6'd1) begin                                 // the last: idle, nothing pending
              sv_on <= 1'b0; bst <= B_IDLE; pend <= 1'b0; pend_rep <= 1'b0; take_fline <= 1'b0;
              mm_have <= 1'b0;
              cu_v <= 1'b0; cu_pcv <= 1'b0; take_hold <= 1'b0;   // the CU's instruction is in the frame
              cu_st <= 1'b0; mv_pcw <= 1'b0; hv <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;         // and its moves'
              if (apu_susp) apu_abort <= 1'b1;
            end else begin
              fk <= fk - 6'd1; fwait <= 2'd3;
            end
          end else if (x_opr && !rw && rs_on) begin               // FRESTORE: lowest first
            if (fk == 6'd1)                           rs_img <= din[31:16];
            else if (fk >= 6'd2 && fk <= 6'd4)        rs_slot <= {rs_slot[63:0], din};
            else if (fk == 6'd5)                      rs_ctl <= din;
            else if (fk == 6'd6)                      begin rs_take <= din[31:16]; rs_cucmd <= din[15:0]; end
            else if (fk == 6'd7)                      rs_iar <= din;
            else if (fk == 6'd8)                      rs_mv <= din;
            else if (fk == 6'd9)                      h_iar <= din;
            else if (fk == f_n - 6'd4)                rs_exop[79:64] <= din[31:16];
            else if (fk == f_n - 6'd3)                rs_exop[63:32] <= din;
            else if (fk == f_n - 6'd2)                rs_exop[31:0] <= din;
            else if (fbz && fk >= 6'd10 && fk <= 6'd15) rs_ctx <= {rs_ctx[159:0], din};
            else if (fbz && fk >= 6'd16 && fk <= 6'd48) begin
              if (f_ts[1:0] == 2'd0)      rs_t[63:32] <= din;
              else if (f_ts[1:0] == 2'd1) rs_t[31:0] <= din;
              else begin x_twe <= 1'b1; x_ta <= f_ts[5:2]; x_td <= {rs_t, din[31:10]}; end
            end
            if (fk == f_n) begin                                  // the BIU flags: reinstate
              rs_on <= 1'b0;
              bst <= rs_ctl[31:27]; pc_next <= rs_ctl[26:22];
              n_long <= rs_ctl[21:20]; i_long <= rs_ctl[19:18];
              st_ca0 <= rs_ctl[17]; st_special <= rs_ctl[16]; cr_mask <= rs_ctl[15:13];
              take_fline <= rs_ctl[12]; mm_mask <= rs_ctl[11:4];
              cu_v <= rs_ctl[3]; cu_pcv <= rs_ctl[2]; pc_apu <= rs_ctl[1]; take_hold <= rs_ctl[0];
              cv_rest <= 1'b1;                                    // (its conversion was spent, 7e-3)
              cu_cmd <= rs_cucmd; cu_iar <= rs_iar;
              {hv, h_ccv, h_iarv, mv_pcw, cu_st, take_cst} <= rs_mv[31:26];
              mv_el <= 8'hFF;                                     // (a store's conversion was spent)
              h_cc <= rs_mv[19:16]; h_exc <= rs_mv[15:8]; h_aexc <= rs_mv[7:0];
              take_prim <= rs_take; img <= rs_img; cmd <= rs_img; pred <= rs_img[5:0];
              if (rs_ctl[31:27] == B_OPW || rs_ctl[3] || rs_mv[27]) opnd <= rs_slot;
              else if (rs_ctl[31:27] == B_MMW) mm_buf <= rs_slot[95:16];
              else                             x_obuf_we <= 1'b1;
              x_exop_we <= 1'b1;
              pend <= !din[27] && (fpu_trapvec(fpsr, fpcr) != 8'd0);
              pend_vec <= fpu_trapvec(fpsr, fpcr);
              pend_rep <= 1'b0;
              mm_have <= 1'b0; mm_step <= 2'd0; used <= 1'b1; kill <= 1'b0;
              if (fbz && rs_ctx[191]) begin ctx_we <= 1'b1; go_pend <= 1'b1; end
            end else
              fk <= fk + 6'd1;
          end
        end else if (viol && !(rw && a[4:1] == 4'b0000) && !(dead && x_opr)) begin
          bst <= B_PV;
          take_prim <= 16'h1D0D;
        end else if (rw) begin
          case (a[4:1])
            4'b0000: begin                                        // response
              case (bst)
                B_IDLE:  rdata[31:16] = pend_rep ? take_prim : (apu_idle ? 16'h0802 : 16'h0900);
                B_CMD:
                  // a pending exception first (the APU's instruction has
                  // ended with it; any held in the CU waits behind it)
                  if (apu_idle && pend && !(c_opclass[2])) begin
                    rdata[31:16] = {8'h1C, pend_vec};
                    take_prim <= {8'h1C, pend_vec}; take_fline <= 1'b0;
                    pend_rep <= 1'b1; bst <= B_TAKE;
                  end else if (mi != 2'd0 || cu_hold ||
                               (hv && apu_idle && (!pend || c_opclass[2:1] == 2'b10)))
                    // the CU busy with a move in, reading FPm for this one,
                    // or (a): it waits; a held effect about to apply
                    // (with one pending, FMOVE of the control registers
                    // waits for the handler, as for the slot)
                    rdata[31:16] = 16'h8900;
                  else if (cu_do_rr) begin
                    // FMOVE FPm,FPn by the CU (7e-2): FPn written, released
                    rdata[31:16] = 16'h0900 | pcbit;
                    fpb_addr <= cmd[9:7]; fpb_d <= cu_fp; fpb_we <= 1'b1;
                    h_rec(1'b1, fcc(cu_fp), 8'd0, 8'd0);
                    mi <= 2'd3; mv_el <= 8'd0; mv_T <= M_RR;          // (the CU busy for its time, 7e-3)
                    mv_pcw <= c_pcb; pc_apu <= 1'b0;
                    pc_next <= B_IDLE; bst <= c_pcb ? B_PCW : B_IDLE;
                  end else if (cu_do_st) begin
                    // FMOVE FPm,<ea> by the CU (7e-2): the image made, the
                    // CA = 0 transfer at the next read
                    rdata[31:16] = 16'h8900 | pcbit;
                    opnd <= st_img; cu_st <= 1'b1; st_ca0 <= 1'b1; st_special <= 1'b0;
                    mv_el <= 8'd0;                                // (its time, 7e-3)
                    h_rec(1'b0, 4'd0, {6'd0, st_inx, 1'b0}, st_inx ? 8'h08 : 8'h00);
                    mv_pcw <= c_pcb; pc_apu <= 1'b0;
                    pc_next <= B_CONV; bst <= c_pcb ? B_PCW : B_CONV;
                  end else if (!apu_idle && !cu_v && !cu_busy && !pend && c_ov && !c_illegal) begin
                    // (not while the APU is still taking the last one's
                    // operand from opnd: cu_busy)
                    // the CU takes it while the APU runs (7e): from a
                    // register, released at once; from memory, the
                    // operand transferred first (B_OPW decides)
                    pc_apu <= 1'b0;
                    if (c_opclass == 3'd0) begin
                      rdata[31:16] = 16'h0900 | pcbit;
                      cu_v <= 1'b1; cu_cmd <= cmd;
                      pc_next <= B_IDLE; bst <= c_pcb ? B_PCW : B_IDLE;
                    end else begin
                      rdata[31:16] = i_prim;
                      n_long <= longs(i_len); i_long <= 2'd0; opnd <= 96'd0;
                      pc_next <= B_OPW; bst <= c_pcb ? B_PCW : B_OPW;
                    end
                  end else if (!apu_idle || cu_v) rdata[31:16] = 16'h8900;   // the CU busy: it waits
                  else if (c_illegal) begin
                    rdata[31:16] = 16'h1C0B;
                    take_prim <= 16'h1C0B; take_fline <= 1'b1; bst <= B_TAKE;
                  end else
                    case (c_opclass)
                      3'd0: begin                                 // register to register
                        // through the slot: the CU converts FPm first (7e-3)
                        rdata[31:16] = 16'h0900 | pcbit;
                        cu_v <= 1'b1; cu_cmd <= cmd; pc_apu <= 1'b0;
                        pc_next <= B_IDLE; bst <= c_pcb ? B_PCW : B_IDLE;
                      end
                      3'd2:
                        if (c_fmovecr) begin
                          // the MPU held to its end (Table 8-3's T = 0, 8.6.14 item 22)
                          rdata[31:16] = 16'h8900 | pcbit;
                          start_apu(1'b0, 3'd0, cmd); pc_apu <= 1'b1;
                          hold_on <= 1'b1; hold_end <= 1'b1;
                          pc_next <= B_REL; bst <= c_pcb ? B_PCW : B_REL;
                        end else begin                            // <ea> to register
                          rdata[31:16] = i_prim; pc_apu <= 1'b0;
                          n_long <= longs(i_len); i_long <= 2'd0; opnd <= 96'd0;
                          pc_next <= B_OPW; bst <= c_pcb ? B_PCW : B_OPW;
                        end
                      3'd3:
                        if (c_rx == 3'd7) begin                   // dynamic k: Dn first
                          rdata[31:16] = {8'h8C, 5'd0, cmd[6:4]} | pcbit;
                          pc_apu <= 1'b0;
                          pc_next <= B_DREG; bst <= c_pcb ? B_PCW : B_DREG;
                        end else begin
                          rdata[31:16] = 16'h8900 | pcbit;
                          start_apu(1'b1, cmd[9:7], cmd); pc_apu <= 1'b1;
                          dreg <= 32'd0;
                          pc_next <= B_CONV; bst <= c_pcb ? B_PCW : B_CONV;
                        end
                      3'd4, 3'd5: begin                           // control registers
                        rdata[31:16] = cr_prim;
                        cr_mask <= cmd[12:10];
                        bst <= c_opclass[0] ? B_CRR : B_CRW;
                      end
                      default:                                    // FMOVEM
                        if (cmd[11]) begin
                          rdata[31:16] = {8'h8C, 5'd0, cmd[6:4]};
                          bst <= B_MDREG;
                        end else begin
                          rdata[31:16] = c_opclass[0] ? 16'hA10C : 16'h810C;
                          mm_mask <= cmd[7:0];
                          bst <= B_RSEL;
                        end
                    endcase
                B_COND:
                  if (!apu_idle) rdata[31:16] = 16'h8900;
                  else if (pend) begin
                    rdata[31:16] = {8'h1C, pend_vec};
                    take_prim <= {8'h1C, pend_vec}; take_fline <= 1'b0;
                    pend_rep <= 1'b1; bst <= B_TAKE;
                  end else if (cu_v || mi != 2'd0 || hv) rdata[31:16] = 16'h8900;   // both units (Table 5-6)
                  else begin
                    if (c_bsun) begin
                      fpsr_we <= 1'b1; fpsr_d <= fpsr | 32'h0000_8080;
                    end
                    if (c_bsun && fpcr[15]) begin                 // BSUN: pending, with the PC
                      rdata[31:16] = 16'h5C30;
                      // (the conditional's PC is FPIAR, whatever the last
                      // dialog left pc_apu - a slot instruction's leaves 0,
                      // which sent it to cu_iar: found by +pairs=3)
                      pc_apu <= 1'b1;
                      take_prim <= 16'h5C30; take_fline <= 1'b0;
                      pend <= 1'b1; pend_vec <= 8'd48; pend_rep <= 1'b1;
                      bst <= B_TAKE;
                    end else begin
                      rdata[31:16] = {15'h0400, c_taken};
                      bst <= B_IDLE;
                    end
                  end
                B_REL:
                  if (!hold_ok) rdata[31:16] = 16'h8900;          // held (7e-3)
                  else begin rdata[31:16] = 16'h0900; bst <= B_IDLE; hold_on <= 1'b0; end
                B_HOLD:
                  // the MPU held in the CU instruction's dialog (7e): the
                  // APU instruction's exception is its take mid-instruction
                  // (UM 7.5, Figure 7-32), after XA back here
                  if (cu_v && pend) begin
                    rdata[31:16] = {8'h1D, pend_vec};
                    take_prim <= {8'h1D, pend_vec}; take_fline <= 1'b0;
                    pend_rep <= 1'b1; take_hold <= 1'b1; bst <= B_TAKE;
                  end else if (cu_v || !hold_ok) rdata[31:16] = 16'h8900;   // (and the hold, 7e-3)
                  else begin rdata[31:16] = 16'h0900; bst <= B_IDLE; hold_on <= 1'b0; end
                B_CONV:
                  if (cu_st && pend) begin
                    // an older instruction's exception, pending since: the
                    // store's first real response reports it (UM 7.5.4.2),
                    // after XA back here
                    rdata[31:16] = {8'h1D, pend_vec};
                    take_prim <= {8'h1D, pend_vec}; take_fline <= 1'b0;
                    pend_rep <= 1'b1; take_cst <= 1'b1; bst <= B_TAKE;
                  end else if (cu_st && mv_el < m_out(c_rx)) begin
                    rdata[31:16] = 16'h8900;                      // converting (7e-3: its time)
                  end else if (cu_st) begin                       // the CU's store: made already
                    rdata[31:16] = o_prim;
                    n_long <= longs(o_len); i_long <= 2'd0;
                    bst <= B_OPR;
                  end else if (!conv_ok) rdata[31:16] = 16'h8900;
                  else begin
                    rdata[31:16] = o_prim;
                    n_long <= longs(o_len); i_long <= 2'd0;
                    bst <= B_OPR;
                  end
                B_FIN:
                  if (pend && !pend_rep) begin
                    rdata[31:16] = {8'h1D, pend_vec};
                    take_prim <= {8'h1D, pend_vec}; take_fline <= 1'b0;
                    pend_rep <= 1'b1; bst <= B_TAKE;
                  end else begin
                    rdata[31:16] = 16'h0802; bst <= B_IDLE;
                  end
                B_MPRIM: begin
                  rdata[31:16] = c_opclass[0] ? 16'hA10C : 16'h810C;
                  bst <= B_RSEL;
                end
                B_DONE:  begin rdata[31:16] = 16'h0802; bst <= B_IDLE; end
                B_TAKE,
                B_PV:    rdata[31:16] = take_prim;
                default: rdata[31:16] = 16'h8900;
              endcase
            end
            4'b0010: begin                                        // save: FSAVE by phase
              dead <= 1'b0;
              if (!used)
                rdata[31:16] = 16'h0038;                          // reset phase: null
              else if (!(apu_idle || (apu_susp && !apu_go)) || mi != 2'd0 ||
                       (cu_v && !(cv_rdy && cu_v_q))) begin      // (or a CU move in, a conversion, 7e-3)
                rdata[31:16] = 16'h0138;                          // come again
                sv_req <= 1'b1;
              end else begin
                rdata[31:16] = (apu_susp || f_initial) ? 16'h1FD4 : 16'h1F38;
                fbz <= apu_susp || f_initial;
                fk <= (apu_susp || f_initial) ? 6'd53 : 6'd14;
                sv_on <= 1'b1; sv_req <= 1'b0; fwait <= 2'd3;
              end
            end
            4'b0011: rdata[31:16] = restore_rd;                   // restore
            default:
              if (x_opr) begin                                    // operand
                if (bst == B_OPR) begin
                  rdata = st_long;
                  i_long <= i_long + 2'd1;
                  if (i_long + 2'd1 == n_long) begin bst <= st_ca0 ? B_IDLE : B_FIN; cu_st <= 1'b0; end
                end else if (bst == B_CRR) begin
                  rdata = cr_mask[2] ? fpcr : cr_mask[1] ? fpsr : fpiar;
                  cr_mask <= cr_mask[2] ? {1'b0, cr_mask[1:0]} : cr_mask[1] ? {2'b00, cr_mask[0]} : 3'd0;
                  if ((cr_mask[2] ? cr_mask[1:0] : cr_mask[1] ? cr_mask[0] : 1'b0) == 0) bst <= B_DONE;
                end else if (bst == B_MMR) begin
                  rdata = (i_long == 2'd0) ? {mm_buf[79:64], 16'd0}
                        : (i_long == 2'd1) ? mm_buf[63:32] : mm_buf[31:0];
                  if (i_long == 2'd2) begin
                    i_long <= 2'd0; mm_have <= 1'b0; mm_mask <= mm_clr;
                    if (mm_clr == 8'd0) bst <= B_DONE;
                  end else
                    i_long <= i_long + 2'd1;
                end
              end else if (x_rsel && bst == B_RSEL) begin          // register select
                rdata[31:16] = {mm_mask, 8'h00};
                i_long <= 2'd0; mm_have <= 1'b0; mm_step <= 2'd0;
                bst <= (mm_mask == 8'd0) ? B_DONE : (c_opclass[0] ? B_MMR : B_MMW);
              end
          endcase
        end else begin                                            // writes
          case (a[4:1])
            4'b0001: begin                                        // control
              if (din[17]) begin                                  // XA
                if (bst == B_PV) begin                            // everything aborted, the CU too
                  bst <= B_IDLE; pend <= 1'b0; pend_rep <= 1'b0;
                  apu_abort <= 1'b1; apu_start <= 1'b0; cu_busy <= 1'b0; cu_step <= 2'd0;
                  cu_v <= 1'b0; cu_pcv <= 1'b0; take_hold <= 1'b0;
                  mi <= 2'd0; cu_st <= 1'b0; mv_pcw <= 1'b0; hv <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;
                end else if (bst == B_TAKE) begin
                  bst <= take_hold ? B_HOLD : take_cst ? B_CONV : B_IDLE;
                  take_hold <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;
                  if (take_fline) take_fline <= 1'b0;
                end
              end
              if (din[16] && bst != B_IDLE && bst != B_TAKE && bst != B_PV) begin   // AB
                bst <= B_IDLE;
                // the dialog aborted: the CU's instruction if it is its
                // own (its PC pass or its hold), else only the dialog's PC
                if (!cu_v || bst == B_PCW || bst == B_HOLD) begin cu_v <= 1'b0; cu_pcv <= 1'b0; end
                // a CU move's own dialog: the move is done, its PC not
                // coming; a CU store's leaves the APU alone (7e-2)
                mv_pcw <= 1'b0; cu_st <= 1'b0; take_cst <= 1'b0; hold_on <= 1'b0;
                if (!cu_st && (bst == B_CONV || bst == B_DREG || bst == B_OPR || bst == B_FIN)) begin
                  apu_abort <= 1'b1; apu_start <= 1'b0; cu_busy <= 1'b0; cu_step <= 2'd0;
                end
              end
            end
            4'b0011: restore_start;                               // restore
            4'b0101: begin                                        // command
              cmd <= din[31:16]; img <= din[31:16];
              bst <= B_CMD;
              used <= 1'b1; dead <= 1'b0;
              if (sv_req) begin                                   // an abandoned save
                sv_req <= 1'b0;
                if (apu_susp) go_pend <= 1'b1;
              end
            end
            4'b0111: begin                                        // condition
              pred <= din[21:16]; img <= din[31:16];
              bst <= B_COND;
              used <= 1'b1; dead <= 1'b0;
              if (sv_req) begin
                sv_req <= 1'b0;
                if (apu_susp) go_pend <= 1'b1;
              end
            end
            default:
              if (x_opr) begin                                    // operand
                case (bst)
                  B_OPW: begin
                    if (i_len == 4'd1)      opnd <= {88'd0, din[31:24]};
                    else if (i_len == 4'd2) opnd <= {80'd0, din[31:16]};
                    else                    opnd <= {opnd[63:0], din};
                    i_long <= i_long + 2'd1;
                    if (i_long + 2'd1 == n_long) begin
                      // (the APU may have ended with an exception while
                      // the operand came: then it waits in the slot, 7e)
                      if (c_mv_in && prec_x && !cu_v && !pend) begin
                        // FMOVE <ea>,FPn: the CU's (7e-2), from the next clock
                        mi <= 2'd1; cu_cmd <= cmd; mv_el <= 8'd0;
                        bst <= B_IDLE;                            // S, D and X are CA = 0
                      end else if (c_sdx && !cu_v) begin
                        // S, D, X: the CU converts it, then hands it off (7e-3)
                        cu_v <= 1'b1; cu_cmd <= cmd;
                        bst <= B_IDLE;                            // (CA = 0)
                      end else if ((c_rx == 3'd0 || c_rx == 3'd4 || c_rx == 3'd6) && !cu_v) begin
                        // B, W, L: through the slot too, the MPU held until the
                        // hand-off (Table 8-3: H + 19 + T; 8.6.14 item 22)
                        cu_v <= 1'b1; cu_cmd <= cmd;
                        bst <= B_HOLD;
                      end else if (apu_idle && !cu_v && !pend && !hv) begin
                        start_apu(1'b0, 3'd0, cmd);
                        bst <= i_ca0 ? B_IDLE : B_REL;
                      end else begin                              // the APU busy: into the CU (7e)
                        cu_v <= 1'b1; cu_cmd <= cmd;
                        bst <= i_ca0 ? B_IDLE : B_HOLD;
                      end
                    end
                  end
                  B_DREG: begin
                    dreg <= din;
                    start_apu(1'b1, cmd[9:7], cmd);
                    bst <= B_CONV;
                  end
                  B_MDREG: begin
                    mm_mask <= din[7:0];
                    bst <= B_MPRIM;
                  end
                  B_CRW: begin
                    if (cr_mask[2]) begin fpcr_we <= 1'b1; fpcr_d <= din; end
                    else if (cr_mask[1]) begin fpsr_we <= 1'b1; fpsr_d <= din; end
                    else fpiar <= din;
                    cr_mask <= cr_mask[2] ? {1'b0, cr_mask[1:0]} : cr_mask[1] ? {2'b00, cr_mask[0]} : 3'd0;
                    if ((cr_mask[2] ? cr_mask[1:0] : cr_mask[1] ? cr_mask[0] : 1'b0) == 0) bst <= B_DONE;
                  end
                  B_MMW: begin
                    mm_buf <= (i_long == 2'd0) ? {din[31:16], 64'd0}
                            : (i_long == 2'd1) ? {mm_buf[79:64], din, 32'd0}
                            : {mm_buf[79:32], din};
                    if (i_long == 2'd2) begin
                      fpb_addr <= mm_reg; fpb_d <= {mm_buf[79:32], din}; fpb_we <= 1'b1;
                      i_long <= 2'd0; mm_mask <= mm_clr;
                      if (mm_clr == 8'd0) bst <= B_DONE;
                    end else
                      i_long <= i_long + 2'd1;
                  end
                  default: ;
                endcase
              end else if (x_ia) begin                            // instruction address
                // FPIAR, once the instruction is in the APU; until then it
                // waits with it (7e: FPIAR stays the APU instruction's)
                // (a CU move's: held with its effect, 7e-2)
                if (mv_pcw) begin h_iar <= din; h_iarv <= 1'b1; mv_pcw <= 1'b0; end
                else if (pc_apu) fpiar <= din;
                else begin cu_iar <= din; cu_pcv <= 1'b1; end
                if (bst == B_PCW) bst <= pc_next;
              end
          endcase
        end
        dout <= rdata;
      end

      // the store's evaluate-and-transfer form, once the conversion is done
      // (UM 7.5.1.3): CA = 0 for S, D, X unless the conditions hold
      if (bst == B_CONV && apu_idle && !cu_st)
        st_ca0 <= (c_rx == 3'd1 || c_rx == 3'd5 || c_rx == 3'd2) && !st_special &&
                  !((c_rx == 3'd1 || c_rx == 3'd5) && (fpsr[12] || fpsr[11] || fpcr[9]));
    end
  end

`ifdef SIMULATION
  // a port B write standing over a p1 edge must not change before its p0 edge
  reg [83:0] pb_prev;
  always @(posedge clk) begin
    pb_prev <= {fpb_we, fpb_addr, fpb_d};
    if (!reset && !ce && fpb_we && pb_prev[83] && pb_prev[82:0] != {fpb_addr, fpb_d})
      $display("SIMERR port B: a standing write changed before its p0 edge");
  end
`endif
endmodule
