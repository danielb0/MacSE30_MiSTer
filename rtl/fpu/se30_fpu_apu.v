// se30_fpu_apu.v - the 68882's arithmetic processing unit: the two-level
// microcoded sequencer and the 67-bit datapath of SE30_PLAN.md 8.8.9-
// 8.8.12, running the microcode of tools/fpu_ucode (plan 8.8.19).
// tools/fpu_ucode/sim.py is the definition of every field; this file is
// written against it, and sim/fpu holds it to it - every vector's results
// and clocks, and on request the state each microinstruction leaves.
//
// THE CLOCK (8.8.9, retimed by 8.9.5)
//   The FPU clock is C16M: ce, an enable every second clk.  An FPU clock
//   is two clk periods, and one microinstruction completes in each:
//     at a p1 edge (ce high) - the results, the flags and the next
//       microword (into uir) are registered, and with that word its
//       nanoword and its operands - T[ra], T[rb], K, FP - are read from
//       their RAMs (addresses from the µROM's output; a register written
//       at this same edge is bypassed from the result register);
//     at the p0 edge between (ce low) - the next address is chosen from
//       uir and the flags, and the µROM read for the word after.
//   So the datapath has the whole FPU clock, two clk, from its operands
//   to its results, and a microinstruction still branches on, and reads,
//   what the one before it left, with no delay slots.  Every register the
//   datapath writes changes only at p1 edges (abort included), so the
//   constraints give its paths two clk; only the next address, p1 to p0,
//   is a one-clk path.
//
// THE SEQUENCER (8.8.12, fields.SEQ and WAITMODE)
//   NEXT, JUMP, CALL and RET (a four-deep µPC stack), BRT/BRF on a
//   condition, DISP (a dispatch key ORed into the target), and WAIT: HOLD
//   n holds the word n clocks, UNTIL holds it until the instruction's
//   elapsed clocks reach the budget plus n, ADD adds n to the budget; a
//   WAIT word's nanoword runs on its last clock.  END (a control code)
//   accrues AEXC and holds until the elapsed clocks reach the budget
//   (Tables 8-13 to 8-19, 8.8.19), then the unit is idle.
//
// STARTING AN INSTRUCTION
//   start, sampled at a p1 edge while idle, with the entry-table index
//   (fields.entry_general/ENTRY_FMOVECR/entry_store), the command word,
//   the CU's operand and its tags, and the raw operand (packed decimal
//   and a dynamic k-factor).  Two FPU clocks follow before the first
//   microinstruction - the entry table and the destination's tags (FP[RY]
//   through port A), then the first microword - and are not the
//   instruction's clocks: `clocks` counts from the first microinstruction
//   to the end, as sim.py's do.  The temporaries are not cleared (the
//   microcode never reads one it has not written: every vector passes on
//   the simulator with T0-T31 poisoned at start); every other register is.
//
// THE REGISTER FILE (8.8.6)
//   FP0-FP7, 80 bits, a true dual-port RAM: port A the APU's (a read at
//   each p0 edge, a write at a p1 edge), port B the CU's - here the
//   bench's and the BIU's while the unit is idle.
//
// THE CHECKPOINTS AND THE FRAMES (8.8.12, 8.9.3; item 7c)
//   With save_req set, a CHECKPOINT word completes and the sequencer
//   stops (S_SUSP; susp); upc then holds the next word's address.  ctx is
//   what a busy frame keeps of the APU besides T0-T10 - the µPC stack,
//   LC, SC, the flags, the budget and the elapsed clocks, the command and
//   the tags; Q, MD, MD3, T11-T31 and the operands are dead at every
//   checkpoint (the assembler's liveness, 8.9.3).  save_req also ends
//   END's padding at once (the instruction is finished).  While the unit
//   is stopped or idle the BIU reads T0-T10 through port A's read
//   (x_taddr, x_tq, a p0 edge after the address) and writes them, the
//   exceptional operand and the output buffer; ctx_we loads the context,
//   and resume restarts the sequencer at upc (from S_SUSP, or from idle
//   after a load) - two fetch clocks, not counted, as at a start.
//
// sim.py's SimError cases (a microcode bug, not a machine state) set
// `err` and, in simulation, print SIMERR.

`timescale 1ns/1ps
`include "fpu_ucode.vh"

module se30_fpu_apu #(
  parameter UROM_HEX  = "ucode.urom.hex",
  parameter NROM_HEX  = "ucode.nrom.hex",
  parameter ENTRY_HEX = "ucode.entry.hex",
  parameter KROM_HEX  = "ucode.krom.hex",
  parameter NSEL_HEX  = "ucode.nsel.hex"
) (
  input             clk,
  input             reset,
  input             ce,

  input             start,
  input             abort,       // stop the instruction at once (the BIU: a protocol
                                 // violation's acknowledge, AB, a restore)
  input      [9:0]  entry_idx,
  input      [15:0] cmd,
  input      [85:0] cu_word,
  input      [2:0]  cu_tag,
  input             cu_snan,
  input             cu_den,
  input             cu_neg,
  input      [95:0] operand,
  output            busy,
  output reg [15:0] clocks,      // the instruction's clocks so far
  output reg        err,

  input             fpcr_we,
  input      [31:0] fpcr_d,
  input             fpsr_we,
  input      [31:0] fpsr_d,
  output reg [31:0] fpcr,
  output reg [31:0] fpsr,

  input      [2:0]  fpb_addr,
  input             fpb_we,
  input      [79:0] fpb_d,
  output reg [79:0] fpb_q,

  output reg [95:0] obuf,        // a store's operand
  output reg [79:0] exop,        // the exceptional operand

  // the frames (7c)
  input             save_req,    // stop at the next checkpoint; end END's padding
  output            susp,        // stopped at a checkpoint
  output            in_pad,      // in END's padding
  input             resume,
  input             ctx_we,
  input     [162:0] ctx_d,
  output    [162:0] ctx_q,
  input      [3:0]  x_taddr,
  input             x_twe,
  input      [85:0] x_td,
  output     [85:0] x_tq,
  input             x_exop_we,
  input      [79:0] x_exop,
  input             x_obuf_we,
  input      [95:0] x_obuf,

  // the trace (sim/fpu +trace): a microinstruction executed at this p1 edge
  output            t_exec,
  output     [11:0] t_upc
);
  `include "se30_fpu_fn.vh"

  localparam [66:0] M67 = {67{1'b1}};

  // -- the ROMs and RAMs -------------------------------------------------------
  reg [`MICRO_W-1:0] urom  [0:4095];
  (* romstyle = "M10K" *) reg [`NANO_W-1:0] nrom [0:1023];
  reg [11:0]         entry [0:1023];
  reg [`KWORD_W-1:0] krom  [0:255];
  reg [2:0]          nsel  [0:1023];       // each nanoword's {KLC, FPSEL} (asm.py)
  reg [85:0]         t_a   [0:31];         // the temporaries: two copies,
  reg [85:0]         t_b   [0:31];         // one per read port (8.8.10)
  reg [79:0]         fp    [0:7];

  initial begin
    $readmemh(UROM_HEX, urom);
    $readmemh(NROM_HEX, nrom);
    $readmemh(ENTRY_HEX, entry);
    $readmemh(KROM_HEX, krom);
    $readmemh(NSEL_HEX, nsel);
  end

  wire p0 = ~ce;
  wire p1 = ce;

  // abort is taken at a p1 edge (a pulse at p0 is held for it), so every
  // register the datapath writes changes only at p1 edges: the datapath's
  // paths are two-clk paths, and the constraints say so (8.9.5)
  reg  abort_l;
  wire abort_p = abort || abort_l;
  always @(posedge clk)
    if (reset || p1) abort_l <= 1'b0;
    else if (abort)  abort_l <= 1'b1;

  // -- state ---------------------------------------------------------------------
  localparam S_IDLE = 3'd0, S_ENT = 3'd1, S_FETCH = 3'd2, S_RUN = 3'd3, S_ENDH = 3'd4,
             S_SUSP = 3'd5;
  reg [2:0]  st;
  reg        rsm;                          // S_FETCH is a resume: fetch at upc
  assign busy   = (st != S_IDLE);
  assign susp   = (st == S_SUSP);
  assign in_pad = (st == S_ENDH);

  reg [`MICRO_W-1:0] uir, urom_q;
  reg [`NANO_W-1:0]  nw;                   // the nROM's output: uir's nanoword
  reg [11:0] upc, ua, ent_q;
  reg [85:0] ta_q, tb_q;
  wire [85:0] ta_e, tb_e;                  // the operands, with the bypass (8.9.5)
  wire [79:0] fpa_e;
  reg [`KWORD_W-1:0] k_q;
  reg [79:0] fpa_q;

  reg [11:0] stack [0:3];
  reg [2:0]  sp;
  reg        holding;
  reg [15:0] hcnt;
  reg [15:0] budget;
  reg        rb;

  // the instruction
  reg [15:0] cmd_r;
  reg [9:0]  idx_r;
  reg [85:0] cu;
  reg [95:0] opnd;
  reg [2:0]  stag, dtag;
  reg        s_snan, s_den, s_neg, d_snan, d_den, d_neg;

  // the datapath's registers (8.8.10)
  reg [66:0] q, md, md3;
  reg        qx;
  reg [6:0]  sc;
  reg [7:0]  lc;
  reg        fz, fn, fc, fv, fs, stk, inex, dflag, tiny, huge;
  reg [6:0]  lzc;
  reg [1:0]  kdir;
  reg [1:0]  rprec;
  reg        rm_set;
  reg [1:0]  rm_val;

  // the context a busy frame keeps (8.9.3), 163 bits
  assign ctx_q = {upc, sp, lc, sc, stack[0], stack[1], stack[2], stack[3],
                  fz, fn, fc, fv, fs, stk, inex, dflag, tiny, huge,
                  lzc, kdir, rprec, rm_set, rm_val, rb, budget, clocks, cmd_r,
                  stag, s_snan, s_den, s_neg, dtag, d_snan, d_den, d_neg};

  // -- the microword and its nanoword -----------------------------------------
  wire [9:0]  u_nano   = uir[`MICRO_NANO];
  wire [4:0]  u_ra     = uir[`MICRO_RA];
  wire [7:0]  u_rb     = uir[`MICRO_RB];
  wire [4:0]  u_rd     = uir[`MICRO_RD];
  wire [2:0]  u_seq    = uir[`MICRO_SEQ];
  wire [5:0]  u_cond   = uir[`MICRO_COND];
  wire [11:0] u_target = uir[`MICRO_TARGET];

  wire [1:0] n_asrc  = nw[`NANO_ASRC];
  wire [3:0] n_bsrc  = nw[`NANO_BSRC];
  wire [1:0] n_fpsel = nw[`NANO_FPSEL];
  wire [1:0] n_shk   = nw[`NANO_SHK];
  wire [2:0] n_sha   = nw[`NANO_SHA];
  wire [1:0] n_emode = nw[`NANO_EMODE];
  wire [3:0] n_alu   = nw[`NANO_ALU];
  wire [1:0] n_dir   = nw[`NANO_DIR];
  wire       n_cin   = nw[`NANO_CIN];
  wire [2:0] n_osh   = nw[`NANO_OSH];
  wire [1:0] n_qop   = nw[`NANO_QOP];
  wire [3:0] n_dst   = nw[`NANO_DST];
  wire [2:0] n_sgn   = nw[`NANO_SGN];
  wire [1:0] n_stk   = nw[`NANO_STK];
  wire       n_dl    = nw[`NANO_DL];
  wire       n_a2    = nw[`NANO_A2];
  wire [1:0] n_bx    = nw[`NANO_BX];
  wire [2:0] n_rnd   = nw[`NANO_RND];
  wire [2:0] n_fpsr  = nw[`NANO_FPSR];
  wire [2:0] n_lcop  = nw[`NANO_LCOP];
  wire [4:0] n_ctl   = nw[`NANO_CTL];
  wire [7:0] n_lit   = nw[`NANO_LIT];

  wire [2:0] opclass = cmd_r[15:13];
  wire [2:0] rx = cmd_r[12:10];
  wire [2:0] ry = cmd_r[9:7];
  wire [1:0] fpcr_prec = fpcr[7:6];
  wire [1:0] fpcr_rnd  = fpcr[5:4];
  wire [1:0] rmode = rm_set ? rm_val : fpcr_rnd;

  // The FP register a word reads and writes (fields.FPSEL).
  reg [2:0] fp_sel;
  always @* begin
    case (n_fpsel)
      `NANO_FPSEL_SRC: fp_sel = (opclass == 3'd3) ? ry : rx;
      `NANO_FPSEL_DST: fp_sel = ry;
      `NANO_FPSEL_C:   fp_sel = cmd_r[2:0];
      default:         fp_sel = u_ra[2:0];
    endcase
  end

  // -- the conditions and dispatch keys (sim.Chip.cond, .key) ----------------
  wire [8:0] lc_m_sc = {1'b0, lc} - {2'b0, sc};
  reg cond_v;
  always @* begin
    case (u_cond)
      `COND_TRUE:      cond_v = 1'b1;
      `COND_Z:         cond_v = fz;
      `COND_N:         cond_v = fn;
      `COND_C:         cond_v = fc;
      `COND_V:         cond_v = fv;
      `COND_STK:       cond_v = stk;
      `COND_INEX:      cond_v = inex;
      `COND_RCARRY:    cond_v = fc;
      `COND_LCZ:       cond_v = (lc == 8'd0);
      `COND_Q0:        cond_v = q[0];
      `COND_DFLAG:     cond_v = dflag;
      `COND_SCZ:       cond_v = (sc == 7'd0);
      `COND_KABOVE:    cond_v = (kdir == 2'd1);
      `COND_KBELOW:    cond_v = (kdir == 2'd2);
      `COND_EXCEN:     cond_v = |(fpsr[15:8] & fpcr[15:8]);
      `COND_PENDING:   cond_v = 1'b0;
      `COND_SNORM:     cond_v = (stag == `TAG_NORM);
      `COND_SUNN:      cond_v = (stag == `TAG_UNN);
      `COND_SZERO:     cond_v = (stag == `TAG_ZERO);
      `COND_SINF:      cond_v = (stag == `TAG_INF);
      `COND_SNAN:      cond_v = (stag == `TAG_NAN);
      `COND_SSNAN:     cond_v = s_snan;
      `COND_SNEG:      cond_v = s_neg;
      `COND_SDEN:      cond_v = s_den;
      `COND_DNORM:     cond_v = (dtag == `TAG_NORM);
      `COND_DUNN:      cond_v = (dtag == `TAG_UNN);
      `COND_DZERO:     cond_v = (dtag == `TAG_ZERO);
      `COND_DINF:      cond_v = (dtag == `TAG_INF);
      `COND_DNAN:      cond_v = (dtag == `TAG_NAN);
      `COND_DSNAN:     cond_v = d_snan;
      `COND_DNEG:      cond_v = d_neg;
      `COND_DDEN:      cond_v = d_den;
      `COND_EN_BSUN:   cond_v = fpcr[15];
      `COND_EN_SNAN:   cond_v = fpcr[14];
      `COND_EN_OPERR:  cond_v = fpcr[13];
      `COND_EN_OVFL:   cond_v = fpcr[12];
      `COND_EN_UNFL:   cond_v = fpcr[11];
      `COND_EN_DZ:     cond_v = fpcr[10];
      `COND_EN_INEX2:  cond_v = fpcr[9];
      `COND_EN_INEX1:  cond_v = fpcr[8];
      `COND_PREC_EXT:  cond_v = (fpcr_prec == 2'd0) || (fpcr_prec == 2'd3);
      `COND_PREC_SGL:  cond_v = (fpcr_prec == 2'd1);
      `COND_PREC_DBL:  cond_v = (fpcr_prec == 2'd2);
      `COND_RND_RN:    cond_v = (fpcr_rnd == 2'd0);
      `COND_RND_RZ:    cond_v = (fpcr_rnd == 2'd1);
      `COND_RND_RM:    cond_v = (fpcr_rnd == 2'd2);
      `COND_RND_RP:    cond_v = (fpcr_rnd == 2'd3);
      `COND_DYNK:      cond_v = (opclass == 3'd3) && (rx == 3'd7);
      `COND_SAVEREQ:   cond_v = 1'b0;
      `COND_ABORT:     cond_v = 1'b0;
      `COND_CUHANDOFF: cond_v = 1'b0;
      `COND_SRCREG:    cond_v = (opclass == 3'd0);
      `COND_SAMEREG:   cond_v = (rx == ry);
      `COND_S:         cond_v = fs;
      `COND_RPEXT:     cond_v = (rprec == 2'd0) || (rprec == 2'd3);
      `COND_TINY:      cond_v = tiny;
      `COND_HUGE:      cond_v = huge;
      `COND_LCEQ:      cond_v = (lc == n_lit);
      `COND_LCSCEQ:    cond_v = (lc_m_sc == {1'b0, n_lit});
      `COND_RMRM:      cond_v = (rmode == 2'd2);
      `COND_RMRP:      cond_v = (rmode == 2'd3);
      `COND_LE:        cond_v = fn | fz;
      default:         cond_v = 1'b0;
    endcase
  end

  reg [5:0] dkey;
  always @* begin
    case (u_cond)
      `DISP_TAGPAIR: dkey = stag * 3'd5 + dtag;
      `DISP_STAG:    dkey = {3'd0, stag};
      `DISP_DTAG:    dkey = {3'd0, dtag};
      `DISP_RND:     dkey = {4'd0, fpcr_rnd};
      `DISP_PREC:    dkey = {4'd0, fpcr_prec};
      `DISP_SFMT:    dkey = {3'd0, rx};
      `DISP_DFMT:    dkey = {3'd0, rx};
      `DISP_KFACTOR: dkey = {5'd0, rx == 3'd7};
      `DISP_RPREC:   dkey = {4'd0, rprec};
      `DISP_OPMODE:  dkey = cmd_r[5:0];
      `DISP_RMODE:   dkey = {4'd0, rmode};
      default:       dkey = 6'd0;
    endcase
  end

  // -- the next address (p0) ---------------------------------------------------
  reg [11:0] nxt;
  reg [15:0] wait_h;               // a WAIT's hold, on its first clock
  reg [15:0] wait_add;
  reg signed [17:0] until_h;
  always @* begin
    nxt = upc + 12'd1;
    wait_h = 16'd0;
    wait_add = 16'd0;
    until_h = $signed({2'b00, budget}) + $signed({6'd0, u_target}) - $signed({2'b00, clocks}) - 18'sd1;
    case (u_seq)
      `MICRO_SEQ_JUMP, `MICRO_SEQ_CALL: nxt = u_target;
      `MICRO_SEQ_RET:  nxt = stack[sp - 3'd1];
      `MICRO_SEQ_BRT:  if (cond_v)  nxt = u_target;
      `MICRO_SEQ_BRF:  if (!cond_v) nxt = u_target;
      `MICRO_SEQ_DISP: nxt = u_target | {6'd0, dkey};
      `MICRO_SEQ_WAIT:
        case (u_cond)
          `WAIT_HOLD:  wait_h = {4'd0, u_target};
          `WAIT_ADD:   wait_add = {4'd0, u_target};
          default:     wait_h = (until_h > 0) ? until_h[15:0] : 16'd0;
        endcase
      default: ;
    endcase
  end

  // A word executes on its last clock: at once, or after its WAIT's hold.
  wire exec = (st == S_RUN) && (holding ? (hcnt == 16'd0) : (wait_h == 16'd0));

  // -- the A source and the round logic (sim.Chip.execute, _round) -----------
  function [85:0] fpw;             // an FP register image as a word
    input [79:0] x;
    fpw = {x[79], 3'd0, x[78:64], x[63:0], 3'd0};
  endfunction

  reg [85:0] a_w;
  always @* begin
    case (n_asrc)
      `NANO_ASRC_T:  a_w = ta_e;
      `NANO_ASRC_FP: a_w = fpw(fpa_e);
      `NANO_ASRC_CU: a_w = cu;
      default:       a_w = 86'd0;
    endcase
    if (n_a2)
      a_w = {a_w[85:67], a_w[65:0], 1'b0};
  end
  wire        a_s = a_w[85];
  wire [17:0] a_e = a_w[84:67];
  wire [66:0] a_m = a_w[66:0];

  reg  [6:0]  r_lsb;
  reg  [1:0]  r_mode;
  reg         r_g, r_r, r_st, r_inexact, r_up;
  reg  [66:0] rinc, rmask;
  always @* begin
    case (n_rnd)
      `NANO_RND_SGL:   r_lsb = 7'd43;
      `NANO_RND_DBL:   r_lsb = 7'd14;
      `NANO_RND_RPREC: r_lsb = (rprec == 2'd1 || rprec == 2'd3) ? 7'd43 : (rprec == 2'd2) ? 7'd14 : 7'd3;
      default:         r_lsb = 7'd3;
    endcase
    r_mode = (n_rnd == `NANO_RND_TRUNC) ? 2'd1 : rmode;
    r_g  = a_m[r_lsb - 7'd1];
    r_r  = a_m[r_lsb - 7'd2];
    r_st = ((a_m & ~(M67 << (r_lsb - 7'd2))) != 67'd0) | stk;
    r_inexact = r_g | r_r | r_st;
    case (r_mode)
      2'd0:    r_up = r_g & (r_r | r_st | a_m[r_lsb]);
      2'd1:    r_up = 1'b0;
      2'd2:    r_up = a_s & r_inexact;
      default: r_up = ~a_s & r_inexact;
    endcase
    rinc  = r_up ? (67'd1 << r_lsb) : 67'd0;
    rmask = M67 << r_lsb;
  end

  // -- the B source ---------------------------------------------------------------
  wire [2:0] booth_q = q[2:0];
  wire signed [3:0] booth_d = -$signed({1'b0, booth_q[2], 2'b00}) + $signed({2'b00, booth_q[1], 1'b0})
                            + $signed({3'b000, booth_q[0]}) + $signed({3'b000, qx});
  wire booth_neg = booth_d < 0;
  wire [2:0] booth_mag = booth_neg ? -booth_d[2:0] : booth_d[2:0];
  wire sqt_f = (n_dir == `NANO_DIR_DFLAG) ? dflag : fn;

  reg [85:0] b_w;
  always @* begin
    case (n_bsrc)
      `NANO_BSRC_T:     b_w = tb_e;
      `NANO_BSRC_K,
      `NANO_BSRC_KLC:   b_w = k_q[85:0];
      `NANO_BSRC_FP:    b_w = fpw(fpa_e);
      `NANO_BSRC_OPINT,
      `NANO_BSRC_CU:    b_w = cu;
      `NANO_BSRC_OPRAW: b_w = {1'b0, 18'd0, 35'd0,
                               (lc[1:0] == 2'd0) ? opnd[95:64] :
                               (lc[1:0] == 2'd1) ? opnd[63:32] :
                               (lc[1:0] == 2'd2) ? opnd[31:0] : 32'd0};
      `NANO_BSRC_BOOTH: b_w = {1'b0, 18'd0,
                               (booth_mag == 3'd1) ? md :
                               (booth_mag == 3'd2) ? {md[65:0], 1'b0} :
                               (booth_mag == 3'd3) ? md3 :
                               (booth_mag == 3'd4) ? {md[64:0], 2'b00} : 67'd0};
      `NANO_BSRC_RINC:  b_w = {19'd0, rinc};
      `NANO_BSRC_RMASK: b_w = {19'd0, rmask};
      `NANO_BSRC_SQT:   b_w = {19'd0, {q[65:0], 1'b0} | ((sqt_f ? 67'd3 : 67'd1) << lc)};
      `NANO_BSRC_Q:     b_w = {19'd0, q};
      `NANO_BSRC_SC:    b_w = {1'b0, 11'd0, sc, 60'd0, sc};
      `NANO_BSRC_LC:    b_w = {1'b0, 10'd0, lc, 59'd0, lc};
      `NANO_BSRC_CMD:   b_w = {1'b0, 2'd0, cmd_r, 51'd0, cmd_r};
      default:          b_w = 86'd0;
    endcase
    case (n_bx)
      `NANO_BX_E2M: b_w = {b_w[85:67], {49{b_w[84]}}, b_w[84:67]};
      `NANO_BX_M2E: b_w = {b_w[85], b_w[17:0], b_w[66:0]};
      default: ;
    endcase
  end

  // -- the barrel shifter, on B's mantissa -------------------------------------
  reg [8:0]  sh_amt9;
  reg [6:0]  sh_amt;
  reg [66:0] b_m;
  reg        sh_out;               // bits shifted out right were nonzero
  reg        sh_neg;               // LC - SC < 0: a microcode error
  always @* begin
    case (n_sha)
      `NANO_SHA_LIT:   sh_amt9 = {1'b0, n_lit};
      `NANO_SHA_SC:    sh_amt9 = {2'b0, sc};
      `NANO_SHA_LC:    sh_amt9 = {1'b0, lc};
      `NANO_SHA_LZC:   sh_amt9 = {2'b0, lzc};
      `NANO_SHA_LCPSC: sh_amt9 = {1'b0, lc} + {2'b0, sc};
      default:         sh_amt9 = lc_m_sc;
    endcase
    sh_neg = (n_shk != `NANO_SHK_NONE) && (n_sha == `NANO_SHA_LCMSC) && lc_m_sc[8];
    sh_amt = (sh_amt9 > 9'd67) ? 7'd67 : sh_amt9[6:0];
    b_m = b_w[66:0];
    sh_out = 1'b0;
    case (n_shk)
      `NANO_SHK_LSL: b_m = b_w[66:0] << sh_amt;
      `NANO_SHK_LSR: begin
        b_m = b_w[66:0] >> sh_amt;
        sh_out = (b_w[66:0] & ~(M67 << sh_amt)) != 67'd0;
      end
      `NANO_SHK_ASR: begin
        b_m = $signed(b_w[66:0]) >>> sh_amt;
        sh_out = (b_w[66:0] & ~(M67 << sh_amt)) != 67'd0;
      end
      default: ;
    endcase
  end
  wire        b_s = b_w[85];
  wire [17:0] b_e = b_w[84:67];

  // -- the ALU (exponent mode: the 18-bit exponents in the same ALU) ----------
  wire exp_mode = (n_emode == `NANO_EMODE_EXP) || (n_emode == `NANO_EMODE_EXPB);
  wire [66:0] ax = exp_mode ? {49'd0, a_e} : a_m;
  wire [66:0] by = exp_mode ? {49'd0, b_e} : b_m;
  wire signed [69:0] axs = exp_mode ? {{52{a_e[17]}}, a_e} : {{3{a_m[66]}}, a_m};
  wire signed [69:0] bys = exp_mode ? {{52{b_e[17]}}, b_e} : {{3{b_m[66]}}, b_m};

  reg        alu_flag;
  reg [3:0]  op;
  reg [68:0] ru;                   // the result, zero-extended operands
  reg signed [69:0] rs;            // the result, sign-extended operands
  reg        arith;
  reg [66:0] r;                    // the result at the ALU's width
  reg        z_n, n_n, c_n, v_n;
  always @* begin
    case (n_dir)
      `NANO_DIR_PREVN: alu_flag = fn;
      `NANO_DIR_DFLAG: alu_flag = dflag;
      `NANO_DIR_BSIGN: alu_flag = b_s;
      default:         alu_flag = booth_neg;
    endcase
    op = n_alu;
    if (n_alu == `NANO_ALU_ADDSUB) op = alu_flag ? `NANO_ALU_SUB : `NANO_ALU_ADD;
    if (n_alu == `NANO_ALU_SUBADD) op = alu_flag ? `NANO_ALU_ADD : `NANO_ALU_SUB;
    arith = (op == `NANO_ALU_ADD) || (op == `NANO_ALU_SUB) || (op == `NANO_ALU_RSUB);
    case (op)
      `NANO_ALU_ADD:   begin ru = {2'b0, ax} + {2'b0, by} + n_cin; rs = axs + bys + n_cin; end
      `NANO_ALU_SUB:   begin ru = {2'b0, ax} - {2'b0, by} + n_cin; rs = axs - bys + n_cin; end
      `NANO_ALU_RSUB:  begin ru = {2'b0, by} - {2'b0, ax} + n_cin; rs = bys - axs + n_cin; end
      `NANO_ALU_PASSA: begin ru = {2'b0, ax}; rs = axs; end
      `NANO_ALU_PASSB: begin ru = {2'b0, by}; rs = bys; end
      `NANO_ALU_AND:   begin ru = {2'b0, ax & by};  rs = {3'b0, ax & by}; end
      `NANO_ALU_OR:    begin ru = {2'b0, ax | by};  rs = {3'b0, ax | by}; end
      `NANO_ALU_XOR:   begin ru = {2'b0, ax ^ by};  rs = {3'b0, ax ^ by}; end
      `NANO_ALU_ANDN:  begin ru = {2'b0, ax & ~by}; rs = {3'b0, ax & ~by}; end
      default:         begin ru = 69'd0; rs = 70'sd0; end
    endcase
    if (exp_mode) begin
      r   = {49'd0, ru[17:0]};
      c_n = arith & ru[18];
      n_n = r[17];
      z_n = (r[17:0] == 18'd0);
      v_n = arith & ((rs < -70'sd131072) || (rs >= 70'sd131072));
    end else begin
      r   = ru[66:0];
      c_n = arith & ru[67];
      n_n = r[66];
      z_n = (r == 67'd0);
      v_n = arith & ((rs < -(70'sd1 <<< 66)) || (rs >= (70'sd1 <<< 66)));
    end
  end

  function [6:0] lzc67;            // leading zeros; 67 for zero
    input [66:0] v;
    integer i;
    reg found;
    begin
      lzc67 = 7'd67;
      found = 1'b0;
      for (i = 66; i >= 0; i = i - 1)
        if (!found && v[i]) begin
          lzc67 = 7'd66 - i[6:0];
          found = 1'b1;
        end
    end
  endfunction

  // -- the output shifter and the result word ----------------------------------
  reg [66:0] r2;
  reg [17:0] r2e;
  reg [6:0]  norm;
  reg        dropped;
  reg [66:0] q_n;
  reg        qx_n;
  reg        sgn;
  reg [85:0] res;
  always @* begin
    r2 = r; r2e = r[17:0]; norm = 7'd0; dropped = 1'b0;
    q_n = q; qx_n = qx;
    if (exp_mode) begin
      if (n_osh == `NANO_OSH_R1) r2e = {r[17], r[17:1]};
    end else
      case (n_osh)
        `NANO_OSH_L1:  r2 = {r[65:0], 1'b0};
        `NANO_OSH_L1Q: begin r2 = {r[65:0], 1'b0}; q_n = {q[65:0], ~n_n}; end
        `NANO_OSH_R1:  begin r2 = ru[67:1]; dropped = r[0]; end
        `NANO_OSH_R3Q: begin r2 = rs[69:3]; qx_n = q[2]; q_n = {rs[2:0], q[66:3]}; end
        `NANO_OSH_QBIT: if (lc < 8'd67) q_n = q | ({66'd0, ~n_n} << lc);
        `NANO_OSH_NORM: begin norm = (r == 67'd0) ? 7'd0 : lzc67(r); r2 = r << norm; end
        default: ;
      endcase
    case (n_sgn)
      `NANO_SGN_A:    sgn = a_s;
      `NANO_SGN_B:    sgn = b_s;
      `NANO_SGN_XOR:  sgn = a_s ^ b_s;
      `NANO_SGN_N:    sgn = n_n;
      `NANO_SGN_ZERO: sgn = 1'b0;
      `NANO_SGN_ONE:  sgn = 1'b1;
      `NANO_SGN_NOTA: sgn = ~a_s;
      default:        sgn = ~b_s;
    endcase
    case (n_emode)
      `NANO_EMODE_MANT:  res = {sgn, a_e, r2};
      `NANO_EMODE_MANTB: res = {sgn, b_e, r2};
      `NANO_EMODE_EXP:   res = {sgn, r2e, a_m};
      default:           res = {sgn, r2e, b_m};
    endcase
    if (n_osh == `NANO_OSH_NORM && !exp_mode)
      res[84:67] = res[84:67] - {11'd0, norm};
    // Q: the output shifter's, then the Q operation's
    case (n_qop)
      `NANO_QOP_LOAD:  q_n = res[66:0];
      `NANO_QOP_LOADB: begin q_n = b_m; qx_n = 1'b0; end
      `NANO_QOP_CLEAR: begin q_n = 67'd0; qx_n = 1'b0; end
      default: ;
    endcase
  end

  wire        alu_nop = (n_alu == `NANO_ALU_NOP);
  wire        res_s = res[85];
  wire [17:0] res_e = res[84:67];
  wire [66:0] res_m = res[66:0];

  reg [17:0] rlo, rhi;
  always @* begin
    case (rprec)
      2'd1:    begin rlo = `FPU_RANGE_LO_1; rhi = `FPU_RANGE_HI_1; end
      2'd2:    begin rlo = `FPU_RANGE_LO_2; rhi = `FPU_RANGE_HI_2; end
      2'd3:    begin rlo = `FPU_RANGE_LO_3; rhi = `FPU_RANGE_HI_3; end
      default: begin rlo = `FPU_RANGE_LO_0; rhi = `FPU_RANGE_HI_0; end
    endcase
  end
  wire tiny_n = $signed(res_e) < $signed(rlo);
  wire huge_n = $signed(res_e) > $signed(rhi);

  // the result's class (sim.tag), for FPCC and RETAG
  wire [2:0] res_tag = (res_e == 18'h07FFF) ? ((res_m[65:3] != 63'd0) ? `TAG_NAN : `TAG_INF)
                     : (res_m == 67'd0)     ? `TAG_ZERO
                     : res_m[66]            ? `TAG_NORM : `TAG_UNN;

  // SC from the result, saturated to 0-127
  wire signed [66:0] sc_v = exp_mode ? {{49{res_e[17]}}, res_e} : res_m;
  wire [6:0] sc_sat = (sc_v < 0) ? 7'd0 : (sc_v > 127) ? 7'd127 : sc_v[6:0];

  // Table 8-18 (fields.rtime), for ctl=RTIME
  localparam [383:0] RTIME = `FPU_RTIME_TABLE;
  wire [5:0] rtime_v = RTIME[6 * {rprec, rmode[1], n_lit[2:0]} +: 6];

  wire inex_n = (n_rnd != `NANO_RND_NONE) ? r_inexact : inex;

  // FPSR after this word's action (the fields.FPSR code), then END's accrual
  reg [31:0] fpsr_n;
  always @* begin
    fpsr_n = fpsr;
    case (n_fpsr)
      `NANO_FPSR_CLREXC: fpsr_n[15:8] = 8'd0;
      `NANO_FPSR_ORLIT:  fpsr_n[15:8] = fpsr[15:8] | n_lit;
      `NANO_FPSR_QUOT:   fpsr_n[23:16] = {alu_nop ? 1'b0 : res_s, q_n[6:0]};
      `NANO_FPSR_ACCRUE: fpsr_n = fpu_accrue(fpsr);
      default: ;
    endcase
    if (n_fpsr == `NANO_FPSR_FPCC || n_fpsr == `NANO_FPSR_FPCCINEX)
      fpsr_n[27:24] = {res_s, res_tag == `TAG_ZERO, res_tag == `TAG_INF, res_tag == `TAG_NAN};
    if ((n_fpsr == `NANO_FPSR_INEX2R || n_fpsr == `NANO_FPSR_FPCCINEX) && inex_n)
      fpsr_n[9] = 1'b1;
    if (n_ctl == `NANO_CTL_END)
      fpsr_n = fpu_accrue(fpsr_n);
  end

  reg [15:0] budget_n;
  always @* begin
    budget_n = budget + wait_add;
    case (n_ctl)
      `NANO_CTL_BUDGET:  budget_n = budget_n + {7'd0, n_lit, 1'b0};
      `NANO_CTL_RBUDGET: if (rb) budget_n = budget_n + {7'd0, n_lit, 1'b0};
      `NANO_CTL_RTIME:   if (rb) budget_n = budget_n + {10'd0, rtime_v};
      default: ;
    endcase
  end

  // the FP register write (sim.word_fp): the exponent must be 0-$7FFF
  wire fp_we = exec && !alu_nop && (n_dst == `NANO_DST_FP);
  wire fp_bad = fp_we && (res_e[17:15] != 3'd0);

  assign t_exec = exec && p1;
  assign t_upc  = upc;

  // -- the RAMs' ports (8.9.5) ---------------------------------------------------
  // A word's operands - T[ra], T[rb], K[rb (+ LC)], FP[its select] - are
  // read at the p1 edge that loads the word into uir, from the µROM's
  // output (or, while it holds, from uir): the datapath then has the whole
  // FPU clock, two clk, from the RAMs to the results.  The K address takes
  // the LC this edge leaves, and the FP select and whether the constant is
  // indexed by LC come from nsel, the nanowords' fields by nanoword
  // address (the nanoword itself is read at the same edge).  A temporary or
  // FP register the word before writes at that edge is taken from the
  // result register instead (the RAMs' read during a write of the other
  // port is not the new data).  The FP file's port A only reads; the APU
  // writes through port B, which is the BIU's only while the unit is idle.
  wire        w_load = (st == S_FETCH) || exec;       // uir <= urom_q at this p1 edge
  wire [`MICRO_W-1:0] w_word = w_load ? urom_q : uir;
  wire [4:0]  w_ra   = w_word[`MICRO_RA];
  wire [7:0]  w_rb   = w_word[`MICRO_RB];
  wire [2:0]  w_nsel = nsel[w_word[`MICRO_NANO]];
  reg  [7:0]  lc_n;                                   // LC after this edge
  always @* begin
    lc_n = lc;
    if (exec)
      case (n_lcop)
        `NANO_LCOP_LIT: lc_n = n_lit;
        `NANO_LCOP_DEC: lc_n = lc - 8'd1;
        `NANO_LCOP_INC: lc_n = lc + 8'd1;
        `NANO_LCOP_ALU: lc_n = exp_mode ? res_e[7:0] : res_m[7:0];
        default: ;
      endcase
  end
  wire [7:0]  k_addr_n = w_nsel[2] ? w_rb + lc_n : w_rb;
  reg  [2:0]  fp_sel_n;
  always @* begin
    case (w_nsel[1:0])
      `NANO_FPSEL_SRC: fp_sel_n = (opclass == 3'd3) ? ry : rx;
      `NANO_FPSEL_DST: fp_sel_n = ry;
      `NANO_FPSEL_C:   fp_sel_n = cmd_r[2:0];
      default:         fp_sel_n = w_ra[2:0];
    endcase
  end
  wire [2:0]  fpa_rd = (st == S_IDLE) ? cmd[9:7] : fp_sel_n;   // at a start, FP[RY] for S_ENT's tags
  wire        u_en     = (st == S_FETCH) || exec;
  wire [11:0] u_addr   = (st == S_FETCH) ? (rsm ? upc : ent_q) : nxt;
  wire        x_port   = (st == S_IDLE) || (st == S_SUSP);    // T0-T10 the BIU's
  assign x_tq = ta_q;

  always @(posedge clk) begin
    if (p0) begin
      ent_q <= entry[idx_r];
      if (u_en) begin
        urom_q <= urom[u_addr];
        ua     <= u_addr;
      end
    end
    if (p1) begin
      ta_q  <= t_a[x_port ? {1'b0, x_taddr} : w_ra];
      tb_q  <= t_b[w_rb[4:0]];
      k_q   <= krom[k_addr_n];
    end
  end

  // the writes this edge, and the bypass for the word that reads them
  wire        t_we_c  = exec && !alu_nop && (n_dst == `NANO_DST_T) && !abort_p;
  wire        fp_we_c = fp_we && !abort_p;
  reg         byp_a, byp_b, byp_f;
  reg  [85:0] res_r;
  reg  [79:0] fpw_r;
  wire [79:0] fpa_d = {res_s, res_e[14:0], res_m[66:3]};
  always @(posedge clk)
    if (p1) begin
      byp_a <= t_we_c && (u_rd == w_ra);
      byp_b <= t_we_c && (u_rd == w_rb[4:0]);
      byp_f <= fp_we_c && (fp_sel == fp_sel_n) && (st != S_IDLE);
      if (t_we_c)  res_r <= res;
      if (fp_we_c) fpw_r <= fpa_d;
    end
  assign ta_e  = byp_a ? res_r : ta_q;
  assign tb_e  = byp_b ? res_r : tb_q;
  assign fpa_e = byp_f ? fpw_r : fpa_q;

  // FP port A: the APU's reads, at p1
  always @(posedge clk)
    if (p1) fpa_q <= fp[fpa_rd];
  // FP port B: the APU's writes at p1, else the CU's (here the BIU's, while
  // the unit is idle); a write reads its own data back (the M10K's true
  // dual port reads new data during a write, not old)
  wire        fpb_w  = (p1 && fp_we_c) || fpb_we;
  wire [2:0]  fpb_a  = (p1 && fp_we_c) ? fp_sel : fpb_addr;
  wire [79:0] fpb_dd = (p1 && fp_we_c) ? fpa_d : fpb_d;
  always @(posedge clk)
    if (fpb_w) begin
      fp[fpb_a] <= fpb_dd;
      fpb_q <= fpb_dd;
    end else
      fpb_q <= fp[fpb_a];

  // the temporaries' write, both copies: the datapath's, or the BIU's
  // (a restore) while the unit is idle
  always @(posedge clk)
    if (p1 && t_we_c) begin
      t_a[u_rd] <= res;
      t_b[u_rd] <= res;
    end else if (x_twe && x_port) begin
      t_a[{1'b0, x_taddr}] <= x_td;
      t_b[{1'b0, x_taddr}] <= x_td;
    end

`ifdef SIMULATION
  // A restore that resumes the unit poisons what 8.9.3 says is dead at a
  // checkpoint, so the benches prove it.
  integer pz;
  always @(posedge clk)
    if (ctx_we && !reset)
      for (pz = 11; pz < 32; pz = pz + 1) begin
        t_a[pz] <= {86{1'b1}} ^ (pz * 86'h1234567);
        t_b[pz] <= {86{1'b1}} ^ (pz * 86'h1234567);
      end
`endif

  // the nROM: the next nanoword, read at the p1 edge that loads its
  // microword into uir (the fetch, or a word executed) - in a block of its
  // own, without a reset, and marked for M10K: under the sequencer's reset
  // it was built as logic, and unmarked Quartus judges its ~400 used words
  // cheaper as some 400 ALMs than as seven M10Ks (the plan's rule: arrays in
  // block RAM, 8.8.17)
  wire nrom_en = p1 && !reset && !abort_p && ((st == S_FETCH) || exec);
  always @(posedge clk)
    if (nrom_en) nw <= nrom[urom_q[`MICRO_NANO]];

  // -- the sequencer and the datapath's registers (p1) ------------------------
  always @(posedge clk) begin
    if (reset) begin
      st <= S_IDLE;
      rsm <= 1'b0;
      err <= 1'b0;
      fpcr <= 32'd0;
      fpsr <= 32'd0;
      clocks <= 16'd0;
    end else if (abort_p && p1) begin
      st <= S_IDLE;
      rsm <= 1'b0;
    end else begin
      if (!busy && fpcr_we) fpcr <= fpcr_d;
      if (!busy && fpsr_we) fpsr <= fpsr_d;
      // a restore (7c): the context, the exceptional operand, the output buffer
      if (!busy && ctx_we) begin
        upc <= ctx_d[162:151];  sp <= ctx_d[150:148];  lc <= ctx_d[147:140];  sc <= ctx_d[139:133];
        stack[0] <= ctx_d[132:121];  stack[1] <= ctx_d[120:109];
        stack[2] <= ctx_d[108:97];   stack[3] <= ctx_d[96:85];
        {fz, fn, fc, fv, fs, stk, inex, dflag, tiny, huge} <= ctx_d[84:75];
        lzc <= ctx_d[74:68];  kdir <= ctx_d[67:66];  rprec <= ctx_d[65:64];
        rm_set <= ctx_d[63];  rm_val <= ctx_d[62:61];  rb <= ctx_d[60];
        budget <= ctx_d[59:44];  clocks <= ctx_d[43:28];  cmd_r <= ctx_d[27:12];
        {stag, s_snan, s_den, s_neg} <= ctx_d[11:6];
        {dtag, d_snan, d_den, d_neg} <= ctx_d[5:0];
        holding <= 1'b0;  hcnt <= 16'd0;
`ifdef SIMULATION
        q <= {67{1'b1}};  md <= 67'h5A5A5A5A5A5A5A5A5;  md3 <= 67'h3C3C3C3C3C3C3C3C3;  qx <= 1'b1;
        cu <= {86{1'b1}};  opnd <= {96{1'b1}};
`endif
      end
      if (!busy && x_exop_we) exop <= x_exop;
      if (!busy && x_obuf_we) obuf <= x_obuf;
      if (p1) begin
        case (st)
          S_IDLE:
            if (resume) begin
              st <= S_FETCH;
              rsm <= 1'b1;
            end else if (start) begin
              st <= S_ENT;
              cmd_r <= cmd;
              idx_r <= entry_idx;
              cu <= cu_word;
              opnd <= operand;
              stag <= cu_tag; s_snan <= cu_snan; s_den <= cu_den; s_neg <= cu_neg;
              q <= 67'd0; qx <= 1'b0; md <= 67'd0; md3 <= 67'd0;
              sc <= 7'd0; lc <= 8'd0;
              fz <= 1'b0; fn <= 1'b0; fc <= 1'b0; fv <= 1'b0; fs <= 1'b0;
              stk <= 1'b0; inex <= 1'b0; dflag <= 1'b0; tiny <= 1'b0; huge <= 1'b0;
              lzc <= 7'd0; kdir <= 2'd0; rprec <= 2'd0; rm_set <= 1'b0; rm_val <= 2'd0;
              obuf <= 96'd0; exop <= 80'd0;
              sp <= 3'd0; holding <= 1'b0; hcnt <= 16'd0;
              budget <= 16'd0; rb <= 1'b1;
              clocks <= 16'd0;
            end
          S_ENT: begin
            // the destination's tags, from FP[RY] on port A
            dtag   <= (fpa_q[78:64] == 15'h7FFF) ? ((fpa_q[62:0] != 63'd0) ? `TAG_NAN : `TAG_INF)
                    : (fpa_q[63:0] == 64'd0)    ? `TAG_ZERO
                    : fpa_q[63]                 ? `TAG_NORM : `TAG_UNN;
            d_snan <= (fpa_q[78:64] == 15'h7FFF) && (fpa_q[62:0] != 63'd0) && !fpa_q[62];
            d_den  <= (fpa_q[78:64] == 15'd0) && (fpa_q[63:0] != 64'd0) && !fpa_q[63];
            d_neg  <= fpa_q[79];
            st <= S_FETCH;
          end
          S_FETCH: begin
            uir <= urom_q;
            upc <= ua;
            st  <= S_RUN;
            rsm <= 1'b0;
          end
          S_SUSP:
            if (resume) begin
              st <= S_FETCH;
              rsm <= 1'b1;
            end
          S_RUN: begin
            clocks <= clocks + 16'd1;
            if (!exec) begin
              if (holding) hcnt <= hcnt - 16'd1;
              else begin holding <= 1'b1; hcnt <= wait_h - 16'd1; end
            end else begin
              holding <= 1'b0;
              uir <= urom_q;
              upc <= ua;
              // the µPC stack
              if (u_seq == `MICRO_SEQ_CALL) begin
                if (sp == 3'd4) err <= 1'b1;
                else begin stack[sp[1:0]] <= upc + 12'd1; sp <= sp + 3'd1; end
              end
              if (u_seq == `MICRO_SEQ_RET) begin
                if (sp == 3'd0) err <= 1'b1;
                else sp <= sp - 3'd1;
              end
              // the flags
              if (!alu_nop) begin
                fz <= z_n; fn <= n_n; fc <= c_n; fv <= v_n; fs <= sgn;
                lzc <= lzc67(res_m);
                tiny <= tiny_n; huge <= huge_n;
                if (n_dl) dflag <= n_n;
              end
              if (n_rnd != `NANO_RND_NONE) inex <= r_inexact;
              if (n_bsrc == `NANO_BSRC_K || n_bsrc == `NANO_BSRC_KLC) kdir <= k_q[87:86];
              // sticky, after the round logic has used it
              case (n_stk)
                `NANO_STK_CLR:   stk <= 1'b0;
                `NANO_STK_SHIFT: stk <= stk | sh_out | dropped;
                `NANO_STK_NZ:    stk <= stk | (!alu_nop && r != 67'd0);
                default: ;
              endcase
              // the destinations
              if (!alu_nop)
                case (n_dst)
                  `NANO_DST_MD:    md <= res_m;
                  `NANO_DST_MD3:   md3 <= res_m;
                  `NANO_DST_OBUFH: obuf[95:64] <= res_m[66:35];
                  `NANO_DST_OBUFL: obuf[63:0] <= res_m[66:3];
                  `NANO_DST_OBUFX: obuf <= {res_s, res_e[14:0], 16'd0, res_m[66:3]};
                  `NANO_DST_EXOP:  exop <= {res_s, res_e[14:0], res_m[66:3]};
                  default: ;
                endcase
              if (n_shk != `NANO_SHK_NONE && n_sha == `NANO_SHA_LZC)
                sc <= sh_amt;
              else if (!alu_nop && n_dst == `NANO_DST_SC)
                sc <= sc_sat;
              q <= q_n; qx <= qx_n;
              case (n_lcop)
                `NANO_LCOP_LIT: lc <= n_lit;
                `NANO_LCOP_DEC: lc <= lc - 8'd1;
                `NANO_LCOP_INC: lc <= lc + 8'd1;
                `NANO_LCOP_ALU: lc <= exp_mode ? res_e[7:0] : res_m[7:0];
                default: ;
              endcase
              fpsr <= fpsr_n;
              budget <= budget_n;
              case (n_ctl)
                `NANO_CTL_NORB:    rb <= 1'b0;
                `NANO_CTL_RBON:    rb <= 1'b1;
                `NANO_CTL_RETAG: begin
                  stag   <= res_tag;
                  s_snan <= (res_tag == `TAG_NAN) && !res_m[65];
                  s_den  <= (res_e == 18'd0) && (res_m != 67'd0) && !res_m[66];
                  s_neg  <= res_s;
                end
                `NANO_CTL_RM_FPCR: rm_set <= 1'b0;
                `NANO_CTL_RM_RN:   begin rm_set <= 1'b1; rm_val <= 2'd0; end
                `NANO_CTL_RM_RZ:   begin rm_set <= 1'b1; rm_val <= 2'd1; end
                `NANO_CTL_RM_RM:   begin rm_set <= 1'b1; rm_val <= 2'd2; end
                `NANO_CTL_RM_RP:   begin rm_set <= 1'b1; rm_val <= 2'd3; end
                `NANO_CTL_RP_PREC: rprec <= (fpcr_prec == 2'd3) ? 2'd0 : fpcr_prec;
                `NANO_CTL_RP_EXT:  rprec <= 2'd0;
                `NANO_CTL_RP_SGL:  rprec <= 2'd1;
                `NANO_CTL_RP_DBL:  rprec <= 2'd2;
                `NANO_CTL_RP_SGLX: rprec <= 2'd3;
                `NANO_CTL_RP_DFMT: rprec <= (rx == 3'd1) ? 2'd1 : (rx == 3'd5) ? 2'd2 : 2'd0;
                default: ;
              endcase
              if (n_ctl == `NANO_CTL_END)
                st <= (budget_n > clocks + 16'd1 && !save_req) ? S_ENDH : S_IDLE;
              if (n_ctl == `NANO_CTL_CHECKPOINT && save_req)
                st <= S_SUSP;
              // sim.py's SimErrors: the microcode did what the hardware cannot
              if (fp_bad || sh_neg ||
                  (alu_nop && (n_dst != `NANO_DST_NONE || n_osh != `NANO_OSH_NONE ||
                               n_fpsr == `NANO_FPSR_FPCC || n_fpsr == `NANO_FPSR_FPCCINEX ||
                               n_lcop == `NANO_LCOP_ALU || n_qop == `NANO_QOP_LOAD ||
                               n_ctl == `NANO_CTL_RETAG)))
                err <= 1'b1;
            end
          end
          S_ENDH:
            if (save_req)                  // a save waits: the pad is cut short
              st <= S_IDLE;
            else begin
              clocks <= clocks + 16'd1;
              if (clocks + 16'd1 >= budget) st <= S_IDLE;
            end
          default: st <= S_IDLE;
        endcase
      end
    end
  end

`ifdef SIMULATION
  always @(posedge clk)
    if (p1 && exec && (fp_bad || sh_neg))
      $display("SIMERR at $%03h: %s", upc, fp_bad ? "FP write with an exponent outside 0-$7FFF"
                                                  : "shift amount LC-SC negative");
`endif
endmodule
