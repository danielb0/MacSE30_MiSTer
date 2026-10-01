; The 68882's microcode: plan 8.8.19, work 6c.  Assembled by ../asm.py, run
; by ../sim.py (whose docstrings define every field), checked against the
; reference model's vectors by ../vec.py.
;
; Conventions.  T1 the source operand, T0 the destination operand and then
; the result; T5-T7 the post-processing's working copies; T12/T13 the
; rounding precision's exponent limits.  Every instruction ends at `done`
; (AEXC accrued, END: the BIU takes EXC AND ENABLE as the pending
; exception).  The flags a branch tests are the previous word's (8.8.9),
; so a test of a result sits one word after it; tags, FPCR and the trap
; enables may be tested anywhere.

.export idle
.export unimpl
idle:   alu=nop | goto idle
unimpl: alu=nop | goto unimpl                       ; not written yet (vec.py counts these)

.entry default unimpl
.redundant model

done:   ctl=end | goto idle                        ; END accrues AEXC (6.1.10)

; ============================================================================
; The prologues, by source kind (the entry table's index, 8.8.11): the
; source to T1, the destination register to T0, EXC cleared (2.3.3), the
; rounding precision from FPCR, then the operation by its opmode.
; ============================================================================

; Table 8-13's conversion time (8.8.19): each prologue's first word
; dispatches on the tag pair to a slot that reads the destination and adds
; the figure for the source's format and class and the destination's class;
; a monadic operation's memory source has the in-memory monadic figures
; (pro_xm, pro_sm, pro_dm, pro_intm).  The tables: cv_*, below.
pro_reg: d=T1 b=FP[src] alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_reg
pro_go:  d=T9 a=T1 alu=passa | dispatch OPMODE ops      ; T9: the source, for EXOP
pro_x:   d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_x
pro_xm:  d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_xm
; S, D: a denormal is normalized here (Table 8-13's "not normalized" times).
pro_s:   d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_s
pro_sm:  d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_sm
pro_d:   d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_d
pro_dm:  d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_dm
pro_nrm: d=T1 a=T1 alu=passa osh=norm | goto pro_go
; B, W, L: the CU hands the magnitude and sign; the value is |n| x 2^0 (the
; exponent that puts the binary point below bit 0), normalized; 0 is +0.  A
; negative source takes two more clocks (Table 8-13).
pro_int: d=T1 b=OPINT alu=passb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_int
pro_intm: d=T1 b=OPINT alu=passb sign=b fpsr=clrexc ctl=rp_prec | dispatch TAGPAIR cv_intm
pro_int2: d=T1 a=T1 b=K[int_exp] alu=passb mode=exp | unless SNEG goto pro_nrm
         d=T1 a=T1 alu=passa osh=norm budget=2 | goto pro_go

.table cv_reg TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=42 | goto pro_go
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_go
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=34 | goto pro_go
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_go
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
.end

.table cv_x TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=38 | goto pro_go
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=32 | goto pro_go
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=32 | goto pro_go
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
.end

.table cv_xm TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=8 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=8 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=8 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=8 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=8 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=10 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=12 | goto pro_go
.end

.table cv_s TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_nrm
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=48 | goto pro_nrm
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=42 | goto pro_nrm
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=40 | goto pro_nrm
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=42 | goto pro_nrm
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=34 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=38 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=32 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=32 | goto pro_go
.end

.table cv_sm TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_nrm
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_nrm
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_nrm
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_nrm
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_nrm
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
.end

.table cv_d TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=16 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=34 | goto pro_nrm
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=46 | goto pro_nrm
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=40 | goto pro_nrm
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=38 | goto pro_nrm
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=40 | goto pro_nrm
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=32 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=34 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_go
.end

.table cv_dm TAGPAIR cu
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=14 | goto pro_go
  UNN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_nrm
  UNN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_nrm
  UNN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_nrm
  UNN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_nrm
  UNN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_nrm
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=18 | goto pro_go
  INF  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  INF  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  NAN  NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
.end

.table cv_int TAGPAIR hold
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=24 | goto pro_int2
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=36 | goto pro_int2
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_int2
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_int2
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=30 | goto pro_int2
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=34 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=26 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=28 | goto pro_go
  default   unimpl                               ; B/W/L are never UNN, INF or NAN
.end

.table cv_intm TAGPAIR hold
  NORM NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_int2
  NORM UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_int2
  NORM ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_int2
  NORM INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_int2
  NORM NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=22 | goto pro_int2
  ZERO NORM :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO UNN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO ZERO :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO INF  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  ZERO NAN  :: d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr budget=20 | goto pro_go
  default   unimpl                               ; B/W/L are never UNN, INF or NAN
.end

.table ops OPMODE
  $00  :: alu=nop | dispatch STAG t_move                ; FMOVE
  $18  :: alu=nop | dispatch STAG t_abs                 ; FABS
  $1A  :: alu=nop | dispatch STAG t_neg                 ; FNEG
  $38  :: alu=nop | dispatch TAGPAIR t_cmp              ; FCMP
  $3A  :: alu=nop | dispatch STAG t_tst                 ; FTST
  $22  :: alu=nop | dispatch TAGPAIR t_add              ; FADD
  $28  fsub
  $23  :: alu=nop | dispatch TAGPAIR t_mul              ; FMUL
  $27  :: alu=nop ctl=rp_sglx | dispatch TAGPAIR t_sgm  ; FSGLMUL
  $20  :: alu=nop | dispatch TAGPAIR t_div              ; FDIV
  $24  :: alu=nop ctl=rp_sglx | dispatch TAGPAIR t_sgd  ; FSGLDIV
  $04  :: alu=nop | dispatch STAG t_sqrt                ; FSQRT
  $01  :: alu=nop | dispatch STAG t_int                 ; FINT
  $03  :: alu=nop | dispatch STAG t_intrz               ; FINTRZ
  $1E  :: alu=nop | dispatch STAG t_gexp                ; FGETEXP
  $1F  :: alu=nop | dispatch STAG t_gman                ; FGETMAN
  $26  :: alu=nop | dispatch TAGPAIR t_scale            ; FSCALE
  $21  :: alu=nop | dispatch TAGPAIR t_mod              ; FMOD
  $25  :: alu=nop | dispatch TAGPAIR t_rem              ; FREM
  $10  :: alu=nop | dispatch STAG t_exp                 ; FETOX
  $11  :: alu=nop | dispatch STAG t_twotox              ; FTWOTOX
  $12  :: alu=nop | dispatch STAG t_tentox              ; FTENTOX
  $08  :: alu=nop | dispatch STAG t_expm1               ; FETOXM1
  $02  :: alu=nop | dispatch STAG t_sinh                ; FSINH
  $19  :: alu=nop | dispatch STAG t_cosh                ; FCOSH
  $09  :: alu=nop | dispatch STAG t_tanh                ; FTANH
  $14  :: alu=nop | dispatch STAG t_logn                ; FLOGN
  $15  :: alu=nop | dispatch STAG t_log10               ; FLOG10
  $16  :: alu=nop | dispatch STAG t_log2                ; FLOG2
  $06  :: alu=nop | dispatch STAG t_lnp1                ; FLOGNP1
  $0D  :: alu=nop | dispatch STAG t_atanh               ; FATANH
  $0E  :: alu=nop | dispatch STAG t_sin                 ; FSIN
  $1D  :: alu=nop | dispatch STAG t_cos                 ; FCOS
  $0F  :: alu=nop | dispatch STAG t_tan                 ; FTAN
  $0A  :: alu=nop | dispatch STAG t_atan                ; FATAN
  $0C  :: alu=nop | dispatch STAG t_asin                ; FASIN
  $1C  :: alu=nop | dispatch STAG t_acos                ; FACOS
  $30  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $31  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $32  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $33  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $34  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $35  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $36  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  $37  :: alu=nop | dispatch STAG t_sincos              ; FSINCOS
  redundant model
  default unimpl
.end

.entry reg   $00 pro_reg
.entry X     $00 pro_xm
.entry S     $00 pro_sm
.entry D     $00 pro_dm
.entry B,W,L $00 pro_intm
.entry reg   $01 pro_reg
.entry X     $01 pro_xm
.entry S     $01 pro_sm
.entry D     $01 pro_dm
.entry B,W,L $01 pro_intm
.entry reg   $02 pro_reg
.entry X     $02 pro_xm
.entry S     $02 pro_sm
.entry D     $02 pro_dm
.entry B,W,L $02 pro_intm
.entry reg   $03 pro_reg
.entry X     $03 pro_xm
.entry S     $03 pro_sm
.entry D     $03 pro_dm
.entry B,W,L $03 pro_intm
.entry reg   $04 pro_reg
.entry X     $04 pro_xm
.entry S     $04 pro_sm
.entry D     $04 pro_dm
.entry B,W,L $04 pro_intm
.entry reg   $06 pro_reg
.entry X     $06 pro_xm
.entry S     $06 pro_sm
.entry D     $06 pro_dm
.entry B,W,L $06 pro_intm
.entry reg   $08 pro_reg
.entry X     $08 pro_xm
.entry S     $08 pro_sm
.entry D     $08 pro_dm
.entry B,W,L $08 pro_intm
.entry reg   $09 pro_reg
.entry X     $09 pro_xm
.entry S     $09 pro_sm
.entry D     $09 pro_dm
.entry B,W,L $09 pro_intm
.entry reg   $0A pro_reg
.entry X     $0A pro_xm
.entry S     $0A pro_sm
.entry D     $0A pro_dm
.entry B,W,L $0A pro_intm
.entry reg   $0C pro_reg
.entry X     $0C pro_xm
.entry S     $0C pro_sm
.entry D     $0C pro_dm
.entry B,W,L $0C pro_intm
.entry reg   $0D pro_reg
.entry X     $0D pro_xm
.entry S     $0D pro_sm
.entry D     $0D pro_dm
.entry B,W,L $0D pro_intm
.entry reg   $0E pro_reg
.entry X     $0E pro_xm
.entry S     $0E pro_sm
.entry D     $0E pro_dm
.entry B,W,L $0E pro_intm
.entry reg   $0F pro_reg
.entry X     $0F pro_xm
.entry S     $0F pro_sm
.entry D     $0F pro_dm
.entry B,W,L $0F pro_intm
.entry reg   $10 pro_reg
.entry X     $10 pro_xm
.entry S     $10 pro_sm
.entry D     $10 pro_dm
.entry B,W,L $10 pro_intm
.entry reg   $11 pro_reg
.entry X     $11 pro_xm
.entry S     $11 pro_sm
.entry D     $11 pro_dm
.entry B,W,L $11 pro_intm
.entry reg   $12 pro_reg
.entry X     $12 pro_xm
.entry S     $12 pro_sm
.entry D     $12 pro_dm
.entry B,W,L $12 pro_intm
.entry reg   $14 pro_reg
.entry X     $14 pro_xm
.entry S     $14 pro_sm
.entry D     $14 pro_dm
.entry B,W,L $14 pro_intm
.entry reg   $15 pro_reg
.entry X     $15 pro_xm
.entry S     $15 pro_sm
.entry D     $15 pro_dm
.entry B,W,L $15 pro_intm
.entry reg   $16 pro_reg
.entry X     $16 pro_xm
.entry S     $16 pro_sm
.entry D     $16 pro_dm
.entry B,W,L $16 pro_intm
.entry reg   $18 pro_reg
.entry X     $18 pro_xm
.entry S     $18 pro_sm
.entry D     $18 pro_dm
.entry B,W,L $18 pro_intm
.entry reg   $19 pro_reg
.entry X     $19 pro_xm
.entry S     $19 pro_sm
.entry D     $19 pro_dm
.entry B,W,L $19 pro_intm
.entry reg   $1A pro_reg
.entry X     $1A pro_xm
.entry S     $1A pro_sm
.entry D     $1A pro_dm
.entry B,W,L $1A pro_intm
.entry reg   $1C pro_reg
.entry X     $1C pro_xm
.entry S     $1C pro_sm
.entry D     $1C pro_dm
.entry B,W,L $1C pro_intm
.entry reg   $1D pro_reg
.entry X     $1D pro_xm
.entry S     $1D pro_sm
.entry D     $1D pro_dm
.entry B,W,L $1D pro_intm
.entry reg   $1E pro_reg
.entry X     $1E pro_xm
.entry S     $1E pro_sm
.entry D     $1E pro_dm
.entry B,W,L $1E pro_intm
.entry reg   $1F pro_reg
.entry X     $1F pro_xm
.entry S     $1F pro_sm
.entry D     $1F pro_dm
.entry B,W,L $1F pro_intm
.entry reg   $20 pro_reg
.entry X     $20 pro_x
.entry S     $20 pro_s
.entry D     $20 pro_d
.entry B,W,L $20 pro_int
.entry reg   $21 pro_reg
.entry X     $21 pro_x
.entry S     $21 pro_s
.entry D     $21 pro_d
.entry B,W,L $21 pro_int
.entry reg   $22 pro_reg
.entry X     $22 pro_x
.entry S     $22 pro_s
.entry D     $22 pro_d
.entry B,W,L $22 pro_int
.entry reg   $23 pro_reg
.entry X     $23 pro_x
.entry S     $23 pro_s
.entry D     $23 pro_d
.entry B,W,L $23 pro_int
.entry reg   $24 pro_reg
.entry X     $24 pro_x
.entry S     $24 pro_s
.entry D     $24 pro_d
.entry B,W,L $24 pro_int
.entry reg   $25 pro_reg
.entry X     $25 pro_x
.entry S     $25 pro_s
.entry D     $25 pro_d
.entry B,W,L $25 pro_int
.entry reg   $26 pro_reg
.entry X     $26 pro_x
.entry S     $26 pro_s
.entry D     $26 pro_d
.entry B,W,L $26 pro_int
.entry reg   $27 pro_reg
.entry X     $27 pro_x
.entry S     $27 pro_s
.entry D     $27 pro_d
.entry B,W,L $27 pro_int
.entry reg   $28 pro_reg
.entry X     $28 pro_x
.entry S     $28 pro_s
.entry D     $28 pro_d
.entry B,W,L $28 pro_int
.entry reg   $30 pro_reg
.entry X     $30 pro_xm
.entry S     $30 pro_sm
.entry D     $30 pro_dm
.entry B,W,L $30 pro_intm
.entry reg   $31 pro_reg
.entry X     $31 pro_xm
.entry S     $31 pro_sm
.entry D     $31 pro_dm
.entry B,W,L $31 pro_intm
.entry reg   $32 pro_reg
.entry X     $32 pro_xm
.entry S     $32 pro_sm
.entry D     $32 pro_dm
.entry B,W,L $32 pro_intm
.entry reg   $33 pro_reg
.entry X     $33 pro_xm
.entry S     $33 pro_sm
.entry D     $33 pro_dm
.entry B,W,L $33 pro_intm
.entry reg   $34 pro_reg
.entry X     $34 pro_xm
.entry S     $34 pro_sm
.entry D     $34 pro_dm
.entry B,W,L $34 pro_intm
.entry reg   $35 pro_reg
.entry X     $35 pro_xm
.entry S     $35 pro_sm
.entry D     $35 pro_dm
.entry B,W,L $35 pro_intm
.entry reg   $36 pro_reg
.entry X     $36 pro_xm
.entry S     $36 pro_sm
.entry D     $36 pro_dm
.entry B,W,L $36 pro_intm
.entry reg   $37 pro_reg
.entry X     $37 pro_xm
.entry S     $37 pro_sm
.entry D     $37 pro_dm
.entry B,W,L $37 pro_intm
.entry reg   $38 pro_reg
.entry X     $38 pro_x
.entry S     $38 pro_s
.entry D     $38 pro_d
.entry B,W,L $38 pro_int
.entry reg   $3A pro_reg
.entry X     $3A pro_xm
.entry S     $3A pro_sm
.entry D     $3A pro_dm
.entry B,W,L $3A pro_intm
.entry P     $00 pro_p
.entry P     $01 pro_p
.entry P     $02 pro_p
.entry P     $03 pro_p
.entry P     $04 pro_p
.entry P     $06 pro_p
.entry P     $08 pro_p
.entry P     $09 pro_p
.entry P     $0A pro_p
.entry P     $0C pro_p
.entry P     $0D pro_p
.entry P     $0E pro_p
.entry P     $0F pro_p
.entry P     $10 pro_p
.entry P     $11 pro_p
.entry P     $12 pro_p
.entry P     $14 pro_p
.entry P     $15 pro_p
.entry P     $16 pro_p
.entry P     $18 pro_p
.entry P     $19 pro_p
.entry P     $1A pro_p
.entry P     $1C pro_p
.entry P     $1D pro_p
.entry P     $1E pro_p
.entry P     $1F pro_p
.entry P     $20 pro_p
.entry P     $21 pro_p
.entry P     $22 pro_p
.entry P     $23 pro_p
.entry P     $24 pro_p
.entry P     $25 pro_p
.entry P     $26 pro_p
.entry P     $27 pro_p
.entry P     $28 pro_p
.entry P     $30 pro_p
.entry P     $31 pro_p
.entry P     $32 pro_p
.entry P     $33 pro_p
.entry P     $34 pro_p
.entry P     $35 pro_p
.entry P     $36 pro_p
.entry P     $37 pro_p
.entry P     $38 pro_p
.entry P     $3A pro_p

; ============================================================================
; FMOVE, FABS, FNEG to a register (8.6.8): the source through the
; post-processing; a zero, an infinity or a NaN as it is.  FABS and FNEG
; change the sign after the NaN test (a NaN keeps its sign).
; ============================================================================


; Table 8-15's calculation times ride on the slots (budget=, 8.8.19): FMOVE
; 2+, a zero 6, an infinity 6; FABS and FNEG 2 more (4+, 8), a zero 4+ (the
; zero's rounding 6: 4 more than FMOVE's 6).
.table t_move STAG
  NORM :: alu=nop budget=2 | goto mv_fin
  UNN  :: alu=nop budget=2 | goto mv_fin
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=6 | goto mv_copy
  NAN  nan_m
.end
.table t_abs STAG
  NAN  nan_m
  ZERO :: alu=nop budget=4 | goto abs_go
  default :: alu=nop budget=2 | goto abs_go
.end
.table t_neg STAG
  NAN  nan_m
  ZERO :: alu=nop budget=4 | goto neg_go
  default :: alu=nop budget=2 | goto neg_go
.end

abs_go: d=T1 a=T1 alu=passa sign=zero | dispatch STAG t_move
neg_go: d=T1 a=T1 alu=passa sign=nota | dispatch STAG t_move

mv_fin: d=T0 a=T1 alu=passa | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
mv_zero: d=T0 a=T1 b=0 alu=passb mode=exp            ; a signed zero: exponent 0
        d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto done
mv_copy: d=FP[dst] a=T1 alu=passa fpsr=fpcc | goto done

; A monadic NaN (4.5.4): the source made nonsignaling; SNAN for a signaling
; one, and with the SNAN trap enabled FPn and FPCC are left (6.1.2, 8.6.14
; item 18) and the source is the exceptional operand.
nan_m:  d=T0 a=T1 b=K[qbit] alu=or budget=28 | unless SSNAN goto nan_w   ; NAN2 (Table 8-19)
        alu=nop budget=2                                ; an SNAN: 30
        fpsr=orlit exc=SNAN | unless EN_SNAN goto nan_w
        d=EXOP a=T1 alu=passa | goto done
nan_w:  d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto done

; ============================================================================
; FTST: FPCC from the source (a NaN made nonsignaling first, its sign kept).
; ============================================================================

.table t_tst STAG
  NAN  :: alu=nop budget=8 | goto tst_nan               ; NAN5
  default :: alu=nop budget=8 | goto tst_go
.end
tst_go: a=T1 alu=passa fpsr=fpcc | goto done
tst_nan: d=T0 a=T1 b=K[qbit] alu=or | unless SSNAN goto tst_nw
        alu=nop budget=2                                ; an SNAN: 10
        fpsr=orlit exc=SNAN | unless EN_SNAN goto tst_nw
        d=EXOP a=T1 alu=passa | goto done
tst_nw: a=T0 alu=passa fpsr=fpcc | goto done

; ============================================================================
; FCMP (4-32): FPCC from destination - source, exactly; I never set.  The
; FPCC patterns are written by a word of the right class and sign.
; ============================================================================

.table t_cmp TAGPAIR
  NAN  NAN  :: alu=nop | goto cmt_3
  NAN  *    :: alu=nop budget=30 | goto cmt_4           ; NAN4: the source's
  *    NAN  :: alu=nop | goto cmt_1
  INF  INF  :: alu=nop budget=6 | goto cmp_ii
  INF  *    :: alu=nop budget=6 | goto cmt_si           ; source infinite: - src decides
  *    INF  :: alu=nop budget=6 | goto cmp_dsign        ; destination infinite
  ZERO ZERO :: alu=nop budget=6 | goto cmp_zz
  ZERO *    :: alu=nop budget=6 | goto cmp_dsign        ; source zero: the destination's sign
  *    ZERO :: alu=nop budget=6 | goto cmt_dz           ; destination zero: - src
  default   :: alu=nop budget=6 | goto cmp_fin
.end
; the like-signed cases' 2 more (8)
cmt_si: alu=nop | if SNEG goto cmt_sin
        alu=nop | if DNEG goto cmp_srev
        alu=nop budget=2 | goto cmp_srev
cmt_sin: alu=nop | unless DNEG goto cmp_srev
        alu=nop budget=2 | goto cmp_srev
cmt_dz: alu=nop | if SNEG goto cmt_dzn
        alu=nop | if DNEG goto cmp_srev
        alu=nop budget=2 | goto cmp_srev
cmt_dzn: alu=nop | unless DNEG goto cmp_srev
        alu=nop budget=2 | goto cmp_srev
; NaNs: NAN4 an SNAN 32; NAN1 28 (an SNAN 30), 24 more for a denormalized
; source; NAN3 28, 30 or 32 by which signals
cmt_4:  alu=nop | unless SSNAN goto cmp_nan
        alu=nop budget=2 | goto cmp_nan
cmt_1:  alu=nop budget=28 | unless DSNAN goto cmt_1d
        alu=nop budget=2
cmt_1d: alu=nop | unless SDEN goto cmp_nan
        alu=nop budget=24 | goto cmp_nan
cmt_3:  alu=nop budget=28 | if SSNAN goto cmt_3s
        alu=nop | unless DSNAN goto cmp_nan
        alu=nop budget=2 | goto cmp_nan
cmt_3s: alu=nop budget=2 | if DSNAN goto cmp_nan
        alu=nop budget=2 | goto cmp_nan

cc_n:   a=0 b=K[one] alu=passb mode=mantb sign=one fpsr=fpcc | goto done
cc_0:   a=0 b=K[one] alu=passb mode=mantb sign=zero fpsr=fpcc | goto done
cc_z:   a=0 b=0 alu=passb sign=zero fpsr=fpcc | goto done
cc_zn:  a=0 b=0 alu=passb sign=one fpsr=fpcc | goto done

cmp_dsign: alu=nop | if DNEG goto cc_n
        goto cc_0
cmp_srev: alu=nop | if SNEG goto cc_0
        goto cc_n
cmp_zz: alu=nop | if DNEG goto cc_zn
        goto cc_z
cmp_ii: alu=nop | if DNEG goto cmp_iin
        alu=nop | if SNEG goto cc_0                     ; +inf - -inf
        goto cc_z                                       ; +inf - +inf
cmp_iin: alu=nop | if SNEG goto cc_zn                   ; -inf - -inf
        goto cc_n                                       ; -inf - +inf

; Both finite and nonzero: the signs, then the normalized magnitudes.
cmp_fin: alu=nop | if SNEG goto cmp_sneg
        alu=nop | if DNEG goto cc_n                     ; d < 0 < s
        goto cmp_mag
cmp_sneg: alu=nop | unless DNEG goto cc_0               ; s < 0 < d
cmp_mag: d=T0 a=T0 alu=passa osh=norm
        d=T1 a=T1 alu=passa osh=norm
        a=T0 b=T1 mode=exp alu=sub                      ; Ed - Es
        alu=nop budget=2 | if N goto cmp_m8             ; CMP: 8 if Es > Ed ...
        alu=nop budget=2                                ; ... else 10 (a nop keeps the flags)
cmp_m8: alu=nop | if Z goto cmp_m
        alu=nop | if N goto cmp_less
        goto cmp_more
cmp_m:  a=T0 b=T1 alu=sub                               ; Md - Ms: C is the borrow
        alu=nop | if C goto cmp_less
        alu=nop | if Z goto cc_z
cmp_more: alu=nop | if DNEG goto cc_n                   ; |d| > |s|
        goto cc_0
cmp_less: alu=nop | if DNEG goto cc_0                   ; |d| < |s|
        goto cc_n

; A NaN: FPCC NAN alone (8.6.14 item 22: N clear); SNAN for a signaling
; operand; the source is the exceptional operand.
cmp_nan: d=EXOP a=T1 alu=passa | if SSNAN goto cmp_ns
        alu=nop | unless DSNAN goto cmp_nq
cmp_ns: fpsr=orlit exc=SNAN
cmp_nq: a=0 b=K[nan] alu=passb mode=mantb sign=zero fpsr=fpcc | goto done

; ============================================================================
; pp: the post-processing of a register result (8.6.4; UM 4.5.5.2, 6.1.4,
; 6.1.5) at the rounding precision: normalize (one clock, osh=norm), round,
; the range checks by the TINY/HUGE comparators.  In: T0 finite and
; nonzero, STK its sticky bit.  Out: T5 the register image - T0 keeps the
; normalized, unrounded value for the exceptional operand; EXC's UNFL,
; OVFL, INEX2; EXOP for an enabled OVFL or UNFL (the value rounded to 64
; bits at its own exponent, wrapped by $6000, or exponent 0 past the
; catastrophic limits).  Five clocks on the common path (Table 8-18 gives
; extended rounding six).  Each outcome's word names its Table 8-18 row
; (rtime=, 8.8.19): normal, carried, tiny, overflow - carried, or made by
; the carry.
; ============================================================================

pp:     d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=rprec | if TINY goto pp_tiny
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r | if C goto pp_cy
        alu=nop | if HUGE goto pp_ovfl
        rtime=normal | ret
pp_cy:  d=T5 a=T5 b=K[one] alu=passb                    ; carried out: 1.0 ...
        d=T5 a=T5 b=0 alu=add cin=1 mode=exp            ; ... one binade up
        alu=nop | if HUGE goto pp_ovfc
        rtime=carry | ret
; overflowed with the carry: already beyond the maximum, or only by it
pp_ovfc: a=T0 alu=passa
        alu=nop | if HUGE goto pp_ovcc
        rtime=ovflr | goto pp_ov1
pp_ovcc: rtime=ovflc | goto pp_ov1

; pp_md: pp for FMUL and FDIV - a tiny (denormalized) intermediate takes 2
; clocks more (Table 8-14's MUL 48+, DIV 80+).  pp's words again, so the
; common path costs the same.
pp_md:  d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=rprec | if TINY goto pp_tmd
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r | if C goto pp_cy
        alu=nop | if HUGE goto pp_ovfl
        rtime=normal | ret
pp_tmd: alu=nop budget=2 | goto pp_tiny

; T6: T0 rounded to 64 bits with the true sticky bit (the exceptional
; operand's value, before any denormalization).
pp_xop: d=T6 a=T0 b=RINC alu=add rnd=ext
        d=T6 a=T6 b=RMASK alu=and rnd=ext | unless C goto pp_xr
        d=T6 a=T6 b=K[one] alu=passb
        d=T6 a=T6 b=0 alu=add cin=1 mode=exp
pp_xr:  ret

; Overflow (6.1.4): OVFL; the exceptional operand wrapped by -$6000; the
; result infinity or the largest number, by RND and the sign.
pp_ovfl: rtime=ovfl
pp_ov1: fpsr=orlit exc=OVFL | unless EN_OVFL goto pp_ovr
        alu=nop | call pp_xop
        a=T6 b=K[ovfl_cat] mode=exp alu=rsub            ; past 57343: catastrophic
        d=T7 a=T6 b=K[xop_bias] mode=exp alu=sub | if N goto pp_ovc
        d=EXOP a=T7 alu=passa | goto pp_ovr
pp_ovc: d=EXOP a=T6 b=0 alu=passb mode=exp
pp_ovr: alu=nop | dispatch RND pp_ovt
.table pp_ovt RND
  RN  pp_inf
  RZ  pp_big
  RM  pp_ovm
  RP  pp_ovp
.end
pp_ovm: a=T0 alu=passa
        alu=nop | if S goto pp_inf
        goto pp_big
pp_ovp: a=T0 alu=passa
        alu=nop | if S goto pp_big
pp_inf: d=T5 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T5 a=T5 b=0 alu=passb | ret
pp_big: alu=nop | dispatch RPREC pp_emax
.table pp_emax RPREC
  EXT  pp_bx
  SGL  pp_bs
  DBL  pp_bd
  SGLX pp_bx
.end
pp_bx:  d=T5 a=T0 b=K[ext_emax] alu=passb mode=exp | goto pp_bm
pp_bs:  d=T5 a=T0 b=K[sgl_emax] alu=passb mode=exp | goto pp_bm
pp_bd:  d=T5 a=T0 b=K[dbl_emax] alu=passb mode=exp
pp_bm:  d=T5 a=T5 b=RMASK alu=passb rnd=rprec | ret

; Tiny (6.1.5): UNFL; the exceptional operand wrapped by +$6000; shifted
; right to the minimum exponent with the sticky bit and rounded there.
; Extended's range keeps a denormal at exponent 0; single and double are
; normalized again (an extended register holds them).
pp_tiny: fpsr=orlit exc=UNFL | unless EN_UNFL goto pp_dn
        alu=nop | call pp_xop
        a=T6 b=K[unfl_cat] mode=exp alu=sub             ; at or below -24576: catastrophic
        d=T7 a=T6 b=K[xop_bias] mode=exp alu=add | if N goto pp_unc
        d=EXOP a=T7 alu=passa | goto pp_dn
pp_unc: d=EXOP a=T6 b=0 alu=passb mode=exp
pp_dn:  alu=nop | dispatch RPREC pp_emin
.table pp_emin RPREC
  EXT  pp_nx
  SGL  pp_ns
  DBL  pp_nd
  SGLX pp_nx
.end
pp_nx:  d=T12 a=0 b=K[ext_emin] alu=passb mode=exp | goto pp_dn2
pp_ns:  d=T12 a=0 b=K[sgl_emin] alu=passb mode=exp | goto pp_dn2
pp_nd:  d=T12 a=0 b=K[dbl_emin] alu=passb mode=exp
pp_dn2: d=SC a=T12 b=T0 mode=exp alu=sub                ; the minimum - Eb, at most 127
        d=T5 a=T0 b=T12 alu=passb mode=exp
        d=T5 a=T5 b=T5>>SC alu=passb stk=shift
        d=T3 a=T5 b=RINC alu=add rnd=rprec
        d=T7 a=T5 b=RMASK alu=and rnd=rprec             ; chopped
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r
; Table 8-18's row: the rounding carried into a new binade when (rounded
; XOR chopped) > chopped - its highest changed bit above the chopped value's
        d=T6 a=T5 b=T7 alu=xor
        a=T7 b=T6 alu=sub
        alu=nop | if N goto pp_dnc
        rtime=tiny
pp_dn3: a=T5 alu=passa
        alu=nop | if Z goto pp_uz
        alu=nop | if RPEXT goto pp_ret
        d=T5 a=T5 alu=passa osh=norm
pp_ret: ret
pp_uz:  d=T5 a=T5 b=0 alu=passb mode=exp | ret           ; rounded to nothing: a signed zero
pp_dnc: rtime=tinyc | goto pp_dn3

; ============================================================================
; Shared endings.  operr: the chip's NaN with OPERR (6.1.3); dz: T0 (an
; infinity) with DZ (6.1.6).  With the trap enabled FPn and FPCC are left
; and the source is the exceptional operand (6.1.2-6.1.6, 8.6.14 item 18).
; ============================================================================

operr:  d=T0 b=K[nan] alu=passb mode=mantb sign=b fpsr=orlit exc=OPERR | unless EN_OPERR goto wr_t0
        d=EXOP a=T9 alu=passa | goto done
dz:     fpsr=orlit exc=DZ | unless EN_DZ goto wr_t0
        d=EXOP a=T9 alu=passa | goto done
wr_t0:  d=FP[dst] a=T0 alu=passa fpsr=fpcc ctl=end | goto idle
; T0 through the post-processing, then written.
wr_pp:  alu=nop | call pp
wr_t5:  d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
; An infinity with T0's sign.
mk_inf: d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T0 a=T0 b=0 alu=passb | goto wr_t0

; A dyadic NaN (4.5.4): the destination's if it is one, else the source's,
; made nonsignaling; SNAN if either signals.
nan_d:  alu=nop budget=28 | if DNAN goto ndt_d        ; NAN2: 28, an SNAN 30
        alu=nop | unless SSNAN goto nd_go
        alu=nop budget=2 | goto nd_go
ndt_d:  alu=nop | if SNAN goto ndt_3                   ; NAN1: 28, an SNAN 30 ...
        alu=nop | unless DSNAN goto ndt_1
        alu=nop budget=2
ndt_1:  alu=nop | unless SDEN goto nd_go
        alu=nop budget=24 | goto nd_go                  ; ... 24 more for a denormalized source
ndt_3:  alu=nop | if SSNAN goto ndt_3s                 ; NAN3: QQ 28, QS 30, SQ 32, SS 30
        alu=nop | unless DSNAN goto nd_go
        alu=nop budget=2 | goto nd_go
ndt_3s: alu=nop budget=2 | if DSNAN goto nd_go
        alu=nop budget=2 | goto nd_go
nd_go:  alu=nop | if DNAN goto nd_d
        d=T2 a=T1 b=K[qbit] alu=or | goto nd_s
nd_d:   d=T2 a=T0 b=K[qbit] alu=or
nd_s:   alu=nop | if SSNAN goto nd_sn
        alu=nop | unless DSNAN goto nd_w
nd_sn:  fpsr=orlit exc=SNAN | unless EN_SNAN goto nd_w
        d=EXOP a=T9 alu=passa | goto done
nd_w:   d=FP[dst] a=T2 alu=passa fpsr=fpcc | goto done

; ============================================================================
; FADD, FSUB (4-20, 4-110): FSUB negates the source after the NaN test.
; Both operands normalized, the smaller aligned with its shifted-out bits
; jammed into bit 0 (so a subtraction rounds right), added or subtracted
; by the signs, through pp.  inf - inf: OPERR; zeros by the signs; an exact
; zero is +0, or -0 in RM.
; ============================================================================

fsub:   alu=nop | if SNAN goto nan_d
        alu=nop | if DNAN goto nan_d
        d=T1 a=T1 alu=passa sign=nota | dispatch TAGPAIR t_sub

; Table 8-14's times on the slots (8.8.19).  FADD: x + 0, 0 + x 2+; an
; infinity 6; two zeros 6, unlike-signed 26; two infinities 6, unlike (the
; OPERR) 20.  FSUB, its source negated here: 0 - x 4+; an infinity source
; 8; two zeros 8 unlike-signed, 26 like (unlike and like after the
; negation); two infinities 8, like (OPERR) 20.
.table t_add TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  INF  :: alu=nop budget=6 | goto add_ii
  INF  *    :: alu=nop budget=6 | goto add_si
  *    INF  :: alu=nop budget=6 | goto add_di
  ZERO ZERO :: alu=nop budget=6 | goto add_zz
  ZERO *    :: alu=nop budget=2 | goto add_sz
  *    ZERO :: alu=nop budget=2 | goto add_dz
  default   :: d=T0 a=T0 alu=passa osh=norm | goto add_fin
.end
.table t_sub TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  INF  :: alu=nop budget=8 | goto sub_ii
  INF  *    :: alu=nop budget=8 | goto add_si
  *    INF  :: alu=nop budget=6 | goto add_di
  ZERO ZERO :: alu=nop budget=8 | goto sub_zz
  ZERO *    :: alu=nop budget=2 | goto add_sz
  *    ZERO :: alu=nop budget=4 | goto add_dz
  default   :: d=T0 a=T0 alu=passa osh=norm | goto add_fin
.end

add_di: d=T0 a=T0 alu=passa | goto mk_inf               ; the destination's infinity
add_si: d=T0 a=T1 alu=passa | goto mk_inf               ; the source's (FSUB: negated)
add_ii: a=T0 b=T1 alu=passa sign=xor
        alu=nop | unless S goto add_di
        alu=nop budget=14 | goto operr                  ; opposite infinities: 20
sub_ii: a=T0 b=T1 alu=passa sign=xor
        alu=nop | unless S goto add_di
        alu=nop budget=12 | goto operr
add_sz: d=T0 a=T0 alu=passa | goto wr_pp                ; x + 0: x at PREC
add_dz: d=T0 a=T1 alu=passa | goto wr_pp                ; 0 + x
add_zz: a=T0 b=T1 alu=passa sign=xor
        alu=nop | unless S goto add_zk                  ; like signs: that zero
        alu=nop budget=20 | goto add_z0                 ; unlike: 26
sub_zz: a=T0 b=T1 alu=passa sign=xor
        alu=nop | unless S goto add_zk
        alu=nop budget=18                               ; 26
add_z0: alu=nop | if RND_RM goto add_zm
        d=T0 b=0 alu=passb sign=zero | goto wr_t0       ; +0
add_zm: d=T0 b=0 alu=passb sign=one | goto wr_t0        ; -0 (RM)
add_zk: d=T0 a=T0 b=0 alu=passb mode=exp | goto wr_t0   ; the like-signed zero, exponent 0

add_fin: d=T1 a=T1 alu=passa osh=norm
        a=T0 b=T1 mode=exp alu=sub                      ; Ed - Es
        alu=nop budget=24 | if Z goto add_eq            ; ADD/SUB: 24 ... (a nop keeps the flags)
        alu=nop budget=4 | unless N goto add_al         ; ... 28 the exponents unequal
        d=T2 a=T0 alu=passa                             ; the larger exponent to T0
        d=T0 a=T1 alu=passa
        d=T1 a=T2 alu=passa
        goto add_al
add_eq: a=T1 b=T0 alu=sub                               ; Ms - Md: C when Ms < Md
        alu=nop | if C goto add_al
        alu=nop budget=2                                ; 26: Ms >= Md
add_al: d=SC a=T0 b=T1 mode=exp alu=sub
        d=T1 a=T1 b=T1>>SC alu=passb stk=shift
        alu=nop | unless STK goto add_sg
        d=T1 a=T1 b=K[ulp] alu=or stk=clr               ; jam the sticky into bit 0
add_sg: a=T0 b=T1 alu=passa sign=xor
        alu=nop | if S goto add_sub
        d=T2 a=T0 b=T1 alu=add
        alu=nop | unless C goto add_nc
        d=T0 a=T0 b=T1 alu=add osh=r1 stk=shift         ; the carry: one place right
        d=T0 a=T0 b=0 alu=add cin=1 mode=exp | goto wr_pp
add_nc: d=T0 a=T2 alu=passa | goto wr_pp
add_sub: d=T0 a=T0 b=T1 alu=sub
        alu=nop | unless C goto add_sn
        d=T0 a=0 b=T0 alu=sub mode=mantb sign=notb | goto wr_pp  ; borrowed: negate
add_sn: alu=nop | if Z goto add_ez                      ; an exact zero
        goto wr_pp
add_ez: rtime=zero | goto add_z0                        ; rounded as a zero (Table 8-18)

; A zero with T0's sign.
mk_zero: d=T0 a=T0 b=0 alu=passb
        d=T0 a=T0 b=0 alu=passb mode=exp | goto wr_t0
; The FSGLMUL/FSGLDIV inputs: truncated to 24 bits (8.6.14 item 9).
sgl_tr: d=T0 a=T0 b=RMASK alu=and rnd=sgl
        d=T1 a=T1 b=RMASK alu=and rnd=sgl | ret

; ============================================================================
; FMUL, FSGLMUL (4-80, 4-100): the significands by radix-8 Booth shift-and-
; add (8.8.7), 22 steps: the product's high part in T4, its low 66 bits in
; Q; the 67-bit window (a x b) >> 61 and the sticky of the rest.  Exponent
; E0 + E1 - bias + 1 for that window.  FSGLMUL truncates the inputs and
; rounds to single's mantissa in extended's range.
; ============================================================================


.table t_mul TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  ZERO :: alu=nop budget=20 | goto operr
  ZERO INF  :: alu=nop budget=20 | goto operr
  INF  INF  mi_s
  INF  *    mi_d
  *    INF  mi_s
  ZERO ZERO mz_s
  ZERO *    mz_d
  *    ZERO mz_s
  default   :: d=T0 a=T0 alu=passa osh=norm | goto mul_fin
.end

mul_inf: d=T0 a=T0 b=T1 alu=passa sign=xor | goto mk_inf
mul_zero: d=T0 a=T0 b=T1 alu=passa sign=xor | goto mk_zero
mz_d:   alu=nop budget=6 | unless DNEG goto mul_zero
        alu=nop budget=2 | goto mul_zero
mz_s:   alu=nop budget=6 | unless SNEG goto mul_zero
        alu=nop budget=2 | goto mul_zero
mz_x:   alu=nop budget=6 | if SNEG goto mz_xn
        alu=nop | unless DNEG goto mul_zero
        alu=nop budget=2 | goto mul_zero
mz_xn:  alu=nop | if DNEG goto mul_zero
        alu=nop budget=2 | goto mul_zero
mi_d:   alu=nop budget=6 | unless DNEG goto mul_inf
        alu=nop budget=2 | goto mul_inf
mi_s:   alu=nop budget=6 | unless SNEG goto mul_inf
        alu=nop budget=2 | goto mul_inf

mul_fin: d=T1 a=T1 alu=passa osh=norm budget=46
mul_go: d=T2 a=T0 b=T1 mode=exp alu=add sign=xor        ; E0 + E1, the sign
        d=T2 a=T2 b=K[bias] mode=exp alu=sub cin=1      ; - bias + 1
        d=T3 b=T1>>3 alu=passb                          ; the multiplicand's 64 bits
        d=MD a=T3 alu=passa
        d=MD3 a=T3 b=T3<<1 alu=add                      ; three times it
        b=T0>>3 q=loadb                                 ; the multiplier's 64 bits into Q
        d=T4 b=0 alu=passb lc=21
mloop:  d=T4 a=T4 b=BOOTH alu=addsub dir=booth osh=r3q lc=dec | unless LCZ goto mloop
        d=T5 b=T4<<5 alu=passb
        d=T5 a=T5 b=Q>>62 alu=or
        b=Q<<5 alu=passb stk=nz                         ; the product's bits below the window
        d=T0 a=T2 b=T5 alu=passb | call pp_md
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; ============================================================================
; FDIV, FSGLDIV (4-40, 4-98): nonrestoring, one quotient bit a clock into Q
; (8.8.7), the operands pre-shifted two places so the doubled remainder
; fits.  67 steps give floor(a/b x 2^66); when a < b its top bit is 0 and
; one more step is taken (the exponent one lower).  The remainder's nonzero
; is the sticky bit.  0/0, inf/inf: OPERR; x/0: DZ.
; ============================================================================


.table t_div TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  ZERO ZERO :: alu=nop budget=20 | goto operr
  INF  INF  :: alu=nop budget=20 | goto operr
  *    INF  mi_s                                     ; inf / x
  ZERO *    :: alu=nop budget=20 | goto div_dz          ; x / 0
  *    ZERO mz_s                                     ; 0 / x
  INF  *    mz_x                                     ; x / inf
  default   :: d=T0 a=T0 alu=passa osh=norm | goto div_fin
.end

div_dz: d=T0 a=T0 b=T1 alu=passa sign=xor
        d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T0 a=T0 b=0 alu=passb | goto dz

div_fin: d=T1 a=T1 alu=passa osh=norm budget=78
div_go: d=T2 a=T0 b=T1 mode=exp alu=sub sign=xor lc=66  ; E0 - E1, the sign
        d=T2 a=T2 b=K[bias] mode=exp alu=add            ; + bias
        a=T0 b=T1 alu=sub                               ; C: a < b
        d=T4 b=T0>>2 alu=passb q=clear | if C goto div_lo   ; the partial remainder
        d=T5 b=T1>>2 alu=passb                          ; the divisor (N = 0: subtract first)
dloop:  d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto dloop
        goto div_st
; a < b: the quotient's top bit would be 0 - one more step, the exponent one lower.
div_lo: d=T2 a=T2 b=K[exp_one] mode=exp alu=sub lc=67
        d=T5 b=T1>>2 alu=passb
dloop2: d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto dloop2
; The sticky bit: the true remainder is r, or r + D when the last partial
; remainder r is negative (the quotient bits are restoring's) - which is
; zero for an exact quotient that ends at r = -D, as x/x does.  T4 is 2r.
div_st: d=T6 a=T4 b=T5<<1 alu=add | if DFLAG goto div_sn
        a=T4 alu=passa stk=nz
        d=T0 a=T2 b=Q alu=passb | call pp_md
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
div_sn: a=T6 alu=passa stk=nz
        d=T0 a=T2 b=Q alu=passb | call pp_md
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; FSGLMUL: the inputs truncated to 24 bits (8.6.14 item 9); the multiplier's
; 24 bits need 9 Booth steps.  The product's high part in T4, its low 27
; bits in Q's top (bits 66-40); the window (a x b') >> 21 is (P << 6) |
; (Q >> 61) and the rest of Q the sticky bit - with the exponent E0 + E1 -
; bias + 1, as FMUL's.
.table t_sgm TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  ZERO :: alu=nop budget=20 | goto operr
  ZERO INF  :: alu=nop budget=20 | goto operr
  INF  INF  mi_s
  INF  *    mi_d
  *    INF  mi_s
  ZERO ZERO mz_s
  ZERO *    mz_d
  *    ZERO mz_s
  default   :: d=T0 a=T0 alu=passa osh=norm | goto sgm_fin
.end
sgm_fin: d=T1 a=T1 alu=passa osh=norm budget=34 | call sgl_tr
        d=T2 a=T0 b=T1 mode=exp alu=add sign=xor
        d=T2 a=T2 b=K[bias] mode=exp alu=sub cin=1
        d=T3 b=T1>>3 alu=passb
        d=MD a=T3 alu=passa
        d=MD3 a=T3 b=T3<<1 alu=add
        b=T0>>43 q=loadb                                ; b >> 40: the multiplier's 24 bits
        d=T4 b=0 alu=passb lc=8
sgmloop: d=T4 a=T4 b=BOOTH alu=addsub dir=booth osh=r3q lc=dec | unless LCZ goto sgmloop
        d=T5 b=T4<<6 alu=passb
        d=T5 a=T5 b=Q>>61 alu=or
        b=Q<<6 alu=passb stk=nz
        d=T0 a=T2 b=T5 alu=passb | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; FSGLDIV: the inputs truncated to 24 bits; 27 quotient steps (24 bits, the
; guard and round bits and one more), 28 when a < b; the remainder's
; nonzero the sticky bit; the quotient placed at the top (<< 40).
.table t_sgd TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  ZERO ZERO :: alu=nop budget=20 | goto operr
  INF  INF  :: alu=nop budget=20 | goto operr
  *    INF  mi_s                                     ; inf / x
  ZERO *    :: alu=nop budget=20 | goto div_dz          ; x / 0
  *    ZERO mz_s                                     ; 0 / x
  INF  *    mz_x                                     ; x / inf
  default   :: d=T0 a=T0 alu=passa osh=norm | goto sgd_fin
.end
; A result that may over- or underflow extended's range (the exponent
; within one of a limit) with that trap enabled takes FDIV's full quotient:
; the exceptional operand is rounded to 64 bits (6.1.4-6.1.5).  Otherwise
; the 27 quotient bits and the sticky bit round the result - denormalized
; or not - and give its flags exactly, in the manual's times (44 clocks, 62
; on overflow, 90 on underflow: RTIME's SGLX rows, 8.8.19).
sgd_fin: d=T1 a=T1 alu=passa osh=norm budget=44 | call sgl_tr
        d=T2 a=T0 b=T1 mode=exp alu=sub sign=xor lc=26
        d=T2 a=T2 b=K[bias] mode=exp alu=add
        d=T6 a=T2 b=K[exp_one] mode=exp alu=sub         ; E - 1: TINY?
        d=T6 a=T2 b=K[exp_one] mode=exp alu=add | if TINY goto sgd_t   ; E + 1: HUGE?
        a=T0 b=T1 alu=sub | if HUGE goto sgd_h          ; C: a < b
sgd_c:  d=T4 b=T0>>2 alu=passb q=clear | if C goto sgd_lo
        d=T5 b=T1>>2 alu=passb
sgdloop: d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto sgdloop
        goto sgd_st
sgd_lo: d=T2 a=T2 b=K[exp_one] mode=exp alu=sub lc=27
        d=T5 b=T1>>2 alu=passb
sgdloop2: d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto sgdloop2
sgd_st: d=T6 a=T4 b=T5<<1 alu=add | if DFLAG goto sgd_sn
        a=T4 alu=passa stk=nz | goto sgd_q
; The quotient's exponent is E - (a < b): tiny if E is, or E is the minimum
; and a < b; the rounding can overflow it only from E - (a < b) >= the
; maximum.  (A nop keeps the flags.)
sgd_t:  a=T0 b=T1 alu=sub | unless EN_UNFL goto sgd_c
        a=T2 alu=passa
        alu=nop | if TINY goto div_go
        a=T0 b=T1 alu=sub
        alu=nop | if C goto div_go
        alu=nop | goto sgd_c
sgd_h:  alu=nop | unless EN_OVFL goto sgd_c
        alu=nop | unless C goto div_go
        a=T2 alu=passa
        alu=nop | if HUGE goto div_go
        a=T0 b=T1 alu=sub | goto sgd_c
sgd_sn: a=T6 alu=passa stk=nz
sgd_q:  d=T0 a=T2 b=Q<<40 alu=passb | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; ============================================================================
; FSQRT (4-106): the radicand x in [1/4, 1) (the exponent's parity decides
; m >> 3 or m >> 2 for 2x), the root q in [1/2, 1).  From q = 1/2 and W =
; 2x - 1/2, 63 nonrestoring steps W' = 2W -/+ (2q + 01/11 at the new bit)
; give q to 2^-64 - one clock each (a2, SQT, QBIT: Daniel, 2026-09-29) -
; then the remainder restored if negative, the guard bit G = (W > q) and the
; sticky bit G or W != 0 (no tie is possible).  Exponent floor(u/2) + bias
; for the root at bit 66.  -0 stays -0; any other negative: OPERR.
; ============================================================================

.table t_sqrt STAG
  NAN  nan_m
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=6 | goto sq_inf
  default :: d=T1 a=T1 alu=passa osh=norm | goto sq_fin
.end
sq_inf: alu=nop | unless SNEG goto sq_ip
        alu=nop budget=14 | goto operr                  ; -inf: 20
sq_ip:  d=T0 a=T1 alu=passa | goto mk_inf
sq_fin: d=T2 a=T1 b=K[bias] mode=exp alu=sub | if SNEG goto sq_iop   ; u
        a=T2 b=K[exp_one] mode=exp alu=and budget=76    ; Z: u even
        d=T2 a=T2 alu=passa mode=exp osh=r1 | if Z goto sq_ev   ; floor(u/2)
        d=T4 b=T1>>2 alu=passb | goto sq_w              ; u odd: 2x = m >> 2
sq_ev:  d=T4 b=T1>>3 alu=passb                          ; u even: 2x = m >> 3
sq_w:   d=T4 a=T4 b=K[fx_half] alu=sub                  ; W = 2x - 1/2 >= 0 (N = 0)
        b=K[fx_half] q=loadb lc=62                      ; q = 1/2
sloop:  d=T4 a=T4 b=SQT alu=subadd dir=prevn a2=1 osh=qbit lc=dec | unless LCZ goto sloop
        d=T5 b=Q<<1 alu=passb | unless N goto sq_r
        d=T5 a=T5 b=K[ulp] alu=or
        d=T4 a=T4 b=T5 alu=add                          ; restored: W + 2q + 2^-64
sq_r:   d=T5 b=Q alu=passb
        a=T5 b=T4 alu=sub                               ; q - W borrows: G
        d=T0 b=Q<<3 alu=passb | if C goto sq_g          ; the root's 64 bits
        a=T4 alu=passa stk=nz | goto sq_e               ; sticky: W != 0
sq_iop: alu=nop budget=20 | unless SDEN goto operr     ; IOP (Table 8-19)
        alu=nop budget=12 | goto operr
sq_g:   d=T0 a=T0 b=K[gbit] alu=or
        b=K[ulp] alu=passb stk=nz                       ; sticky
sq_e:   d=T0 a=T0 b=T2 alu=passb mode=exp
        d=T0 a=T0 b=K[bias] mode=exp alu=add | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; ============================================================================
; FINT, FINTRZ (4-50, 4-52): the value shifted so its integer's LSB is at
; bit 3, rounded there (by RND, or toward zero), then - the model's default
; for 8.6.14 item 20 - rounded again to PREC by pp.  A value of 2^63 and
; more is an integer already; 0 rounds to a signed zero.
; ============================================================================

.table t_int STAG
  NAN  nan_m
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=60 | goto mv_copy
  default :: d=T1 a=T1 alu=passa osh=norm ctl=norb | goto int_fin
.end
.table t_intrz STAG
  NAN  nan_m
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=60 | goto mv_copy
  default :: d=T1 a=T1 alu=passa osh=norm ctl=norb | goto intrz_fin
.end
int_fin: d=SC a=T1 b=K[int63] mode=exp alu=rsub         ; 63 - u, at least 0
        d=T0 a=T1 alu=passa | if N goto int_big         ; u > 63: already an integer
        d=T3 b=T1>>SC alu=passb sign=b stk=shift
        d=T3 a=T3 b=RINC alu=add rnd=ext
        d=T0 a=T3 b=RMASK alu=and rnd=ext fpsr=inex2r stk=clr | goto int_e
intrz_fin: d=SC a=T1 b=K[int63] mode=exp alu=rsub
        d=T0 a=T1 alu=passa | if N goto int_big
        d=T3 b=T1>>SC alu=passb sign=b stk=shift
        d=T3 a=T3 b=RINC alu=add rnd=trunc
        d=T0 a=T3 b=RMASK alu=and rnd=trunc fpsr=inex2r stk=clr
; Extended PREC: the integer is exact - written normalized, without pp
int_e:  d=T0 a=T0 b=K[int63] alu=passb mode=exp | if Z goto int_z
        alu=nop budget=8 | if INEX goto int_30          ; the fraction 0: 8 ...
int_x:  alu=nop | unless RPEXT goto wr_pp
        d=FP[dst] a=T0 alu=passa osh=norm fpsr=fpcc ctl=end | goto idle
int_30: alu=nop budget=22 | goto int_x                  ; ... else 30
int_big: alu=nop budget=8 | goto int_x
int_z:  d=T0 a=T0 b=0 alu=passb mode=exp budget=28 | goto wr_t0   ; a signed zero

; ============================================================================
; FGETEXP (4-46): the normalized input's unbiased exponent as a number (exact
; at any PREC); FGETMAN (4-48): its mantissa with exponent 0 - unrounded, the
; model's default for 8.6.14 item 21.  An infinity: OPERR.
; ============================================================================

.table t_gexp STAG
  NAN  nan_m
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=20 | goto operr
  default :: d=T1 a=T1 alu=passa osh=norm ctl=norb | goto gexp_fin
.end
gexp_fin: d=T0 b=T1 bx=e2m alu=passb                    ; Eb as an integer
        d=T0 a=T0 b=K[bias] bx=e2m alu=sub dl=1         ; E = Eb - bias; DFLAG: E < 0
        d=T0 a=T0 b=K[int_exp] alu=passb mode=exp | if Z goto gexp_z
        alu=nop budget=20 | unless DFLAG goto wr_pp
        d=T0 a=0 b=T0 alu=sub mode=mantb sign=one budget=2 | goto wr_pp   ; |E|, negative: 22
gexp_z: d=T0 b=0 alu=passb sign=zero budget=16 | goto wr_t0   ; +0

.table t_gman STAG
  NAN  nan_m
  ZERO :: alu=nop budget=6 | goto mv_zero
  INF  :: alu=nop budget=20 | goto operr
  default :: d=T1 a=T1 alu=passa osh=norm budget=6 | goto gman_fin
.end
gman_fin: d=T0 a=T1 b=K[bias] alu=passb mode=exp | goto wr_t0

; ============================================================================
; FSCALE (4-92): the source chopped to an integer n, added to FPn's exponent,
; then pp.  "|src| >= 2^14: an overflow or underflow always results" - the
; model's clamp: n raised to 32832 and held to 65536 (fpu.py _op_fscale).
; A source infinity: OPERR; FPn zero or infinite: as it is; a source zero:
; FPn at PREC.
; ============================================================================

.table t_scale TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  *    :: alu=nop budget=20 | goto operr
  *    ZERO :: alu=nop budget=6 | goto wr_t0
  *    INF  :: alu=nop budget=6 | goto wr_t0
  ZERO *    :: alu=nop budget=6 | goto wr_pp
  default   :: d=T1 a=T1 alu=passa osh=norm | goto sc_fin
.end
sc_fin: a=T1 b=K[e16] mode=exp alu=sub                  ; u - 16
        d=T3 b=K[k65536] alu=passb budget=12 | unless N goto sc_20   ; |n| >= 2^16: 65536
        a=T1 b=K[bias] mode=exp alu=sub                 ; u < 0: 12, else 16
        d=SC a=T1 b=K[int_exp] mode=exp alu=rsub | if N goto sc_neg  ; 66 - u
        alu=nop budget=4
sc_neg: d=T3 b=T1>>SC alu=passb                         ; n = |src| chopped
        a=T3 b=K[k16384] alu=sub
        alu=nop | if C goto sc_go                       ; below 2^14: as it is
        a=T3 b=K[k32832] alu=sub
        alu=nop | unless C goto sc_go
        d=T3 b=K[k32832] alu=passb                      ; raised to 32832
        goto sc_go
sc_20:  alu=nop budget=8                                ; 20: u above 15
sc_go:  d=T3 a=T3 b=T1 alu=passa sign=b                 ; n's sign: the source's
        d=T0 a=T0 b=T3 bx=m2e mode=exp alu=addsub dir=bsign | goto wr_pp

; ============================================================================
; FMOD (4-62), FREM (4-86): the quotient N = |FPn / src| bit by bit, the
; division step of FDIV in chunks of 64 (Table 8-14: 40 + 70 per 64 bits),
; each chunk a checkpoint (Q parked in T8 so a busy frame holds it); T4 ends
; as 2r, r the floor remainder.  FREM rounds N to nearest (ties to even):
; r - |src|.  The quotient byte: N's low 7 bits and the sign FPn^src.  The
; special cases' quotient byte: WinUAE's (8.6.14 item 5).
; ============================================================================

.table t_mod TAGPAIR
  NAN  *    mr_nan
  *    NAN  mr_nan
  ZERO *    :: alu=nop budget=20 | goto mr_operr
  INF  INF  :: alu=nop budget=20 | goto mr_operr
  *    INF  :: alu=nop budget=20 | goto mr_iop
  *    ZERO :: alu=nop budget=12 | goto mr_dz0
  INF  *    :: alu=nop budget=6 | goto mr_sinf
  default   :: d=T0 a=T0 alu=passa osh=norm | goto mod_fin
.end
.table t_rem TAGPAIR
  NAN  *    mr_nan
  *    NAN  mr_nan
  ZERO *    :: alu=nop budget=20 | goto mr_operr
  INF  INF  :: alu=nop budget=20 | goto mr_operr
  *    INF  :: alu=nop budget=20 | goto mr_iop
  *    ZERO :: alu=nop budget=12 | goto mr_dz0
  INF  *    :: alu=nop budget=6 | goto mr_sinf
  default   :: d=T0 a=T0 alu=passa osh=norm | goto rem_fin
.end
mr_nan: alu=nop q=clear
        a=0 alu=passa fpsr=quot | goto nan_d            ; quotient 0, sign 0
mr_z:   rtime=zero | goto mk_zero                       ; an exact zero remainder rounds as a zero
mr_iop: alu=nop | unless SDEN goto mr_operr          ; IOP: 32 for a denormalized source
        alu=nop budget=12
mr_operr: alu=nop q=clear
        a=0 alu=passa fpsr=quot | goto operr
mr_dz0: alu=nop q=clear
        a=T0 b=T1 alu=passa sign=xor fpsr=quot | goto mk_zero
mr_sinf: alu=nop q=clear
        a=T0 b=T1 alu=passa sign=xor fpsr=quot | goto wr_pp     ; FPn at PREC

mod_fin: d=T1 a=T1 alu=passa osh=norm
        d=T7 a=T0 b=T1 mode=exp alu=sub                 ; D = Ed - Es
        d=T5 b=T1>>2 alu=passb q=clear dl=1 | if N goto mod_small
        d=T4 b=T0>>2 alu=passb
        d=T7 a=T7 b=K[exp_one] mode=exp alu=add | call mr_loop
        d=T6 a=T4 b=T5<<1 alu=add | unless DFLAG goto mod_r
        d=T4 a=T6 alu=passa                             ; r + D (the last step went negative)
mod_r:  a=T0 b=T1 mode=exp alu=sub                      ; N = 0 only when D = 0 (one step): 18 ...
        alu=nop budget=18 | unless Z goto mod_r40
        b=Q alu=passb
        alu=nop | if Z goto mod_r2
mod_r40: alu=nop budget=22                              ; ... else 40
mod_r2: a=T4 alu=passa
        a=T0 b=T1 alu=passa sign=xor fpsr=quot | if Z goto mr_z
mr_res: d=T3 a=T1 b=K[exp_one] mode=exp alu=add         ; 2r's exponent: Es + 1
        d=T3 a=T3 b=T4 alu=passb
        d=T0 a=T3 b=T0 alu=passa sign=b | goto wr_pp     ; FPn's sign (FREM: flipped already)
mod_small: a=T0 b=T1 alu=passa sign=xor fpsr=quot budget=18 | goto wr_pp  ; |FPn| < |src|: N = 0, FPn

; The quotient loop (in: T4 the partial remainder, T5 the divisor, T7 the
; steps n = D + 1 in its exponent, DFLAG clear: subtract first).
mr_loop: d=T6 a=T7 b=K[exp64] mode=exp alu=rsub          ; 64 - n
        d=T8 b=Q alu=passb ctl=checkpoint | unless N goto mr_last   ; n <= 64: the last chunk
        b=T8 q=loadb lc=63
        d=T7 a=0 b=T6 mode=exp alu=sub budget=70        ; n - 64; a chunk: 70
mr_step: d=T4 a=T4 b=T5 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto mr_step
        goto mr_loop
mr_last: a=T7 b=K[exp64] mode=exp alu=sub               ; a whole chunk: 70 (INT((1 + D)/64))
        b=T8 q=loadb | unless Z goto mr_l2
        alu=nop budget=70
mr_l2:  d=T6 a=T7 b=K[exp_one] mode=exp alu=sub lc=alu  ; the last n steps
mr_lstep: d=T4 a=T4 b=T5 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto mr_lstep
        ret

rem_fin: d=T1 a=T1 alu=passa osh=norm
        d=T7 a=T0 b=T1 mode=exp alu=sub
        d=T5 b=T1>>2 alu=passb q=clear dl=1 | if N goto rem_small
        d=T4 b=T0>>2 alu=passb
        d=T7 a=T7 b=K[exp_one] mode=exp alu=add budget=40 | call mr_loop   ; D >= 0: N >= 1
        d=T6 a=T4 b=T5<<1 alu=add | unless DFLAG goto rem_n
        d=T4 a=T6 alu=passa
; To nearest: 2r against |src| (in T5's units); a tie goes to the even N.
rem_n:  a=T4 b=T5 alu=sub
        alu=nop | if C goto rem_r                       ; 2r < |src|
        alu=nop | unless Z goto rem_up                  ; 2r > |src|
        alu=nop | unless Q0 goto rem_r                  ; a tie, N even
rem_up: a=0 b=Q alu=add cin=1 q=load                    ; N + 1
        a=T0 b=T1 alu=passa sign=xor fpsr=quot
        d=T6 b=T5<<1 alu=passb
        d=T4 a=T6 b=T4 alu=sub                          ; |r - src| = |src| - r
        d=T0 a=T0 alu=passa sign=nota | goto mr_res     ; the sign flips
rem_r:  a=T4 alu=passa
        a=T0 b=T1 alu=passa sign=xor fpsr=quot | if Z goto mr_z
        goto mr_res
; |FPn| < |src|: N = 0; with D = -1 the nearest may still be N = 1.
rem_small: d=T4 b=T0>>2 alu=passb                       ; 2r in T5's units when D = -1
        a=T7 b=K[exp_one] mode=exp alu=add budget=18    ; D + 1 = 0?
        alu=nop | if Z goto rem_m1
        a=T0 b=T1 alu=passa sign=xor fpsr=quot | goto wr_pp

; D = -1: N is 0 or 1 (40 then)
rem_m1: a=T4 b=T5 alu=sub
        alu=nop | if C goto rem_r
        alu=nop | unless Z goto rem_u1
        alu=nop | unless Q0 goto rem_r
rem_u1: alu=nop budget=22 | goto rem_up

; ============================================================================
; The stores, FMOVE FPm,<ea> (4-64 to 4-69; 8.6.3): FPCC unchanged; the
; exception mid-instruction (the BIU's, from opclass 011).  EXOP holds the
; register for an SNAN or OPERR trap (6.1.2-6.1.3); ppm overwrites it for
; OVFL and UNFL.  The image is built in T6's mantissa, bits 66-3 (OBUFL
; stores them as the operand's low 64 bits), or T5 (OBUFX, extended).
; ============================================================================

pro_st: d=T1 b=FP[src] alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_dfmt
        d=EXOP a=T1 alu=passa stk=clr | dispatch DFMT t_st
.table t_st DFMT
  L    :: d=T12 b=K[lim_l] alu=passb lc=32 | goto st_int
  W    :: d=T12 b=K[lim_w] alu=passb lc=48 | goto st_int
  B    :: d=T12 b=K[lim_b] alu=passb lc=56 | goto st_int
  S    :: alu=nop | dispatch STAG t_sts
  D    :: alu=nop | dispatch STAG t_std
  X    :: alu=nop | dispatch STAG t_stx
  P    sp_ks
  PK   sp_kd
.end
.entry out.L pro_st
.entry out.W pro_st
.entry out.B pro_st
.entry out.S pro_st
.entry out.D pro_st
.entry out.X pro_st
.entry out.P pro_st
.entry out.PK pro_st

st_w:   d=OBUFL a=T6 alu=passa ctl=end | goto idle

; -- X: the register through ppm at extended; a NaN made nonsignaling; an
; infinity with mantissa 0; a zero with exponent 0 --
; Tables 8-16 and 8-17's output conversion times on the slots (8.8.19).
.table t_stx STAG
  NAN  stx_nan
  INF  :: d=T5 a=T1 b=0 alu=passb budget=16 | goto stx_w
  ZERO :: d=T5 a=T1 b=0 alu=passb mode=exp budget=16 | goto stx_w
  UNN  :: d=T0 a=T1 alu=passa budget=26 | goto stx_u
  default :: d=T0 a=T1 alu=passa budget=18 | goto stx_fin
.end
stx_u:  alu=nop | unless SDEN goto stx_fin
        alu=nop budget=30                               ; denormalized: 56
stx_fin: alu=nop ctl=norb | call ppm                  ; Table 8-16's X figures are flat
stx_w:  d=OBUFX a=T5 alu=passa ctl=end | goto idle
stx_nan: d=T5 a=T1 b=K[qbit] alu=or budget=22 | unless SSNAN goto stx_w   ; NAN7
        alu=nop budget=2
        fpsr=orlit exc=SNAN | goto stx_w

; -- S and D: the IEEE image, the exponent field (Eb - the format's minimum)
; plus the hidden bit, so a denormal (hidden bit 0 at the minimum) packs
; the same way; infinity and NaN with the maximum exponent; the sign last.
.table t_sts STAG
  NAN  :: alu=nop budget=22 | goto sts_nan
  INF  :: d=T6 b=K[inf_s] alu=passb budget=18 | goto sts_sg
  ZERO :: d=T6 b=0 alu=passb budget=16 | goto sts_sg
  UNN  :: d=T0 a=T1 alu=passa budget=48 | goto sts_fin
  default :: d=T0 a=T1 alu=passa budget=38 | goto sts_fin
.end
sts_fin: alu=nop | call ppm
        a=T5 b=K[exp_inf] mode=exp alu=sub              ; overflowed to infinity?
        d=T6 b=T5>>40 alu=passb | if Z goto sts_i       ; the 24 bits, the hidden one at bit 26
        d=T7 a=T5 b=K[sgl_emin] mode=exp alu=sub | if Z goto sts_sg   ; rounded to zero: T6 = 0
        d=T7 b=T7<<26 bx=e2m alu=passb
        d=T6 a=T6 b=T7 alu=add
sts_sg: alu=nop | unless SNEG goto st_w
        d=T6 a=T6 b=K[sbit_s] alu=or | goto st_w
sts_i:  d=T6 b=K[inf_s] alu=passb | goto sts_sg
sts_nan: d=T5 a=T1 b=K[qbit] alu=or | unless SSNAN goto sts_nq
        alu=nop budget=2                                ; an SNAN: 24
        fpsr=orlit exc=SNAN
sts_nq: d=T6 b=T5>>40 alu=passb                         ; the fraction's top 23 bits
        d=T6 a=T6 b=K[b26] alu=andn
        d=T6 a=T6 b=K[inf_s] alu=or | goto sts_sg

.table t_std STAG
  NAN  :: alu=nop budget=22 | goto std_nan
  INF  :: d=T6 b=K[inf_d] alu=passb budget=18 | goto std_sg
  ZERO :: d=T6 b=0 alu=passb budget=16 | goto std_sg
  UNN  :: d=T0 a=T1 alu=passa budget=48 | goto std_fin
  default :: d=T0 a=T1 alu=passa budget=38 | goto std_fin
.end
std_fin: alu=nop | call ppm
        a=T5 b=K[exp_inf] mode=exp alu=sub
        d=T6 b=T5>>11 alu=passb | if Z goto std_i       ; the 53 bits, the hidden one at bit 55
        d=T7 a=T5 b=K[dbl_emin] mode=exp alu=sub | if Z goto std_sg
        d=T7 b=T7<<55 bx=e2m alu=passb
        d=T6 a=T6 b=T7 alu=add
std_sg: alu=nop | unless SNEG goto st_w
        d=T6 a=T6 b=K[one] alu=or | goto st_w          ; bit 66: the image's bit 63
std_i:  d=T6 b=K[inf_d] alu=passb | goto std_sg
std_nan: d=T5 a=T1 b=K[qbit] alu=or | unless SSNAN goto std_nq
        alu=nop budget=2                                ; an SNAN: 24
        fpsr=orlit exc=SNAN
std_nq: d=T6 b=T5>>11 alu=passb
        d=T6 a=T6 b=K[b55] alu=andn
        d=T6 a=T6 b=K[inf_d] alu=or | goto std_sg

; -- B, W, L: rounded to an integer by RND; out of range, an infinity or a
; NaN: OPERR (Table 6-2) - a NaN stores its mantissa's top bits (SNAN for a
; signaling one, made nonsignaling), the rest the largest integer of their
; sign.  T12: 2^(n-1) << 3 (the negative limit's pattern); LC: 64 - n. --
st_int: d=T13 a=T12 b=T12 alu=add | dispatch STAG t_sti  ; 2^n << 3
.table t_sti STAG
  NAN  sti_nan
  INF  :: alu=nop budget=24 | goto sti_ovi
  ZERO :: d=T6 b=0 alu=passb budget=18 | goto st_w
  UNN  :: d=T1 a=T1 alu=passa osh=norm budget=60 | goto sti_fin
  default :: d=T1 a=T1 alu=passa osh=norm budget=50 | goto sti_fin
.end
sti_fin: d=T13 a=T13 b=K[ulp8] alu=sub                  ; the n-bit mask << 3
        d=SC a=T1 b=K[int63] mode=exp alu=rsub          ; 63 - u
        d=T3 b=T1>>SC alu=passb sign=b stk=shift | if N goto sti_ovn    ; |x| >= 2^64
        d=T3 a=T3 b=RINC alu=add rnd=ext
        d=T6 a=T3 b=RMASK alu=and rnd=ext fpsr=inex2r stk=clr | if SNEG goto sti_neg
        a=T6 b=T12 alu=sub                              ; K < 2^(n-1): in range
        alu=nop | unless C goto sti_ovn
        goto st_w
sti_neg: a=T12 b=T6 alu=sub                             ; 2^(n-1) < K: out of range
        alu=nop | if C goto sti_ovn
        d=T6 a=0 b=T6 alu=sub budget=2                  ; -K, two's complement
        d=T6 a=T6 b=T13 alu=and | goto st_w
sti_ovn: alu=nop budget=2 | unless SNEG goto sti_ovf     ; out of range: 2, negative 6
        alu=nop budget=4 | goto sti_ovf
sti_ovi: alu=nop | unless SNEG goto sti_ovf             ; an infinity: 24, negative 26
        alu=nop budget=2
sti_ovf: fpsr=orlit exc=OPERR | if SNEG goto sti_min
        d=T6 a=T12 b=K[ulp8] alu=sub | goto st_w        ; 2^(n-1) - 1
sti_min: d=T6 a=T12 alu=passa | goto st_w               ; -2^(n-1)
sti_nan: d=T13 a=T13 b=K[ulp8] alu=sub budget=24
        d=T5 a=T1 b=K[qbit] alu=or | unless SSNAN goto sti_nq
        fpsr=orlit exc=SNAN | goto sti_nb
sti_nq: fpsr=orlit exc=OPERR
sti_nb: d=SC b=LC alu=passb
        d=T6 b=T5>>SC alu=passb                         ; the mantissa's top n bits
        d=T6 a=T6 b=T13 alu=and | goto st_w

; ============================================================================
; ppm: pp for a memory destination (8.6.4; UM 6.1.4-6.1.5): the same
; rounding and range checks at RPREC (the destination's format), but a
; denormal stays at the minimum exponent, unnormalized, and the exceptional
; operand is the value rounded to the format's precision at its own
; exponent, the exponent not wrapped (rounding.exceptional_operand, 'mem').
; ============================================================================

ppm:    d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=rprec | if TINY goto ppm_tiny
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r | if C goto ppm_cy
        alu=nop | if HUGE goto ppm_ovfl
        ret
ppm_cy: d=T5 a=T5 b=K[one] alu=passb rbudget=4          ; round overflow (Table 8-17): 4
        d=T5 a=T5 b=0 alu=add cin=1 mode=exp
        alu=nop | if HUGE goto ppm_ovfl
        ret
; A store's exceptional operand is kept whatever trap follows (an inexact
; trap from an overflow reports it too: fpu.py fmove_out).
ppm_ovfl: alu=nop rbudget=6 | if RMRM goto ppm_o8          ; overflow: 6, RM or RP 8
        alu=nop | unless RMRP goto ppm_o1
ppm_o8: alu=nop rbudget=2
ppm_o1: d=EXOP a=T5 alu=passa fpsr=orlit exc=OVFL | goto pp_ovr   ; rounded at its own exponent
ppm_tiny: alu=nop rbudget=28                             ; underflow: 28
        d=T6 a=T0 b=RINC alu=add rnd=rprec fpsr=orlit exc=UNFL
        d=T6 a=T6 b=RMASK alu=and rnd=rprec | unless C goto ppm_x
        d=T6 a=T6 b=K[one] alu=passb
        d=T6 a=T6 b=0 alu=add cin=1 mode=exp
ppm_x:  d=EXOP a=T6 alu=passa
ppm_dn: alu=nop | dispatch RPREC ppm_emin
.table ppm_emin RPREC
  EXT  :: d=T12 a=0 b=K[ext_emin] alu=passb mode=exp | goto ppm_dn2
  SGL  :: d=T12 a=0 b=K[sgl_emin] alu=passb mode=exp | goto ppm_dn2
  DBL  :: d=T12 a=0 b=K[dbl_emin] alu=passb mode=exp | goto ppm_dn2
  SGLX :: d=T12 a=0 b=K[ext_emin] alu=passb mode=exp | goto ppm_dn2
.end
ppm_dn2: d=SC a=T12 b=T0 mode=exp alu=sub
        d=T5 a=T0 b=T12 alu=passb mode=exp
        d=T5 a=T5 b=T5>>SC alu=passb stk=shift
        d=T3 a=T5 b=RINC alu=add rnd=rprec
        d=T7 a=T5 b=RMASK alu=and rnd=rprec             ; chopped
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r
        d=T6 a=T5 b=T7 alu=xor                          ; carried into a new binade: 4 (pp_dn2's test)
        a=T7 b=T6 alu=sub
        alu=nop | unless N goto ppm_d3
        alu=nop rbudget=4
ppm_d3: a=T5 alu=passa
        alu=nop | unless Z goto ppm_r
        d=T5 a=T5 b=0 alu=passb mode=exp                ; a signed zero
ppm_r:  ret

; ============================================================================
; FMOVECR (4-72): the constant ROM's row by the offset (the OPMODE key is
; command bits 5-0; offsets $40-$7F are the BIU's F-line, 8.6.14 item 7).
; A documented constant is rom64 (8.6.14 item 19, Daniel 2026-09-29): the
; 64-bit image, one unit up in RP when the true value lies above it and down
; in RZ and RM when below, INEX2 when inexact, then pp at PREC.  The
; undocumented rows are WinUAE's, as the model has them (a lead): rounded
; to a single or double mantissa in extended's range with no flags, WinUAE's
; adjustments at bit 39 for rows 1, 2 and 7, and its FPCC bits for rows 3
; and 7 (ORed onto a positive finite value's FPCC: written in its place).
; ============================================================================

.entry cr pro_cr
pro_cr: alu=nop fpsr=clrexc ctl=rp_prec stk=clr | dispatch OPMODE t_cr
.table t_cr OPMODE
  $00 :: d=T0 b=K[$00] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $01 :: d=T0 b=K[$01] alu=passb mode=mantb sign=b budget=18 | goto cr_u1
  $02 :: d=T0 b=K[$02] alu=passb mode=mantb sign=b budget=18 | goto cr_u2
  $03 :: d=T0 b=K[$03] alu=passb mode=mantb sign=b budget=18 | goto cr_u3
  $04 :: d=T0 b=K[$04] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $05 :: d=T0 b=K[$05] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $06 :: d=T0 b=K[$06] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $07 :: d=T0 b=K[$07] alu=passb mode=mantb sign=b budget=18 | goto cr_u7
  $08 :: d=T0 b=K[$08] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $09 :: d=T0 b=K[$09] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $0A :: d=T0 b=K[$0A] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $0B :: d=T0 b=K[$0B] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $0C :: d=T0 b=K[$0C] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $0D :: d=T0 b=K[$0D] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $0E :: d=T0 b=K[$0E] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $0F :: d=T0 b=0 alu=passb sign=zero budget=18 | goto cr_z           ; 0.0
  $10 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $11 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $12 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $13 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $14 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $15 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $16 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $17 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $18 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $19 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1A :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1B :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1C :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1D :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1E :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $1F :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $20 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $21 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $22 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $23 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $24 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $25 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $26 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $27 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $28 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $29 :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2A :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2B :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2C :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2D :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2E :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $2F :: d=T0 b=K[$10] alu=passb mode=mantb sign=b budget=18 | goto cr_u
  $30 :: d=T0 b=K[$30] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $31 :: d=T0 b=K[$31] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $32 :: d=T0 b=K[$32] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $33 :: d=T0 b=K[$33] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $34 :: d=T0 b=K[$34] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $35 :: d=T0 b=K[$35] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $36 :: d=T0 b=K[$36] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $37 :: d=T0 b=K[$37] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $38 :: d=T0 b=K[$38] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $39 :: d=T0 b=K[$39] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3A :: d=T0 b=K[$3A] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3B :: d=T0 b=K[$3B] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3C :: d=T0 b=K[$3C] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3D :: d=T0 b=K[$3D] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3E :: d=T0 b=K[$3E] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
  $3F :: d=T0 b=K[$3F] alu=passb mode=mantb sign=b budget=18 | goto cr_doc
.end

; 8 more at single or double precision; the rounding is the figure's (norb)
cr_doc: alu=nop ctl=norb | if RPEXT goto cr_d2
        alu=nop budget=8
cr_d2:  alu=nop | if KABOVE goto cr_up
        alu=nop | if KBELOW goto cr_dn
cr_pp:  alu=nop | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
cr_up:  fpsr=orlit exc=INEX2 | unless RND_RP goto cr_pp
        d=T0 a=T0 b=K[ulp8] alu=add | goto cr_pp
cr_dn:  fpsr=orlit exc=INEX2 | if RND_RZ goto cr_m1
        alu=nop | unless RND_RM goto cr_pp
cr_m1:  d=T0 a=T0 b=K[ulp8] alu=sub | goto cr_pp

cr_u:   alu=nop | call cr_rnd
cr_w:   d=FP[dst] a=T0 alu=passa fpsr=fpcc ctl=end | goto idle
cr_u1:  alu=nop | call cr_rnd
        alu=nop | call cr_a17
        goto cr_w
cr_u7:  alu=nop | call cr_rnd
        alu=nop | call cr_a17
        d=FP[dst] a=T0 alu=passa
cr_nan: a=0 b=K[nan] alu=passb mode=mantb sign=zero fpsr=fpcc ctl=end | goto idle   ; FPCC NAN
cr_u2:  alu=nop | call cr_rnd
        alu=nop | unless PREC_SGL goto cr_w
        alu=nop | unless RND_RP goto cr_w
        d=T0 a=T0 b=K[b42] alu=sub | goto cr_w
cr_u3:  alu=nop | call cr_rnd
        d=FP[dst] a=T0 alu=passa | unless PREC_SGL goto cr_nan
        alu=nop | if RND_RN goto cr_inf
        alu=nop | unless RND_RP goto cr_nan
cr_inf: a=0 b=K[exp_inf] alu=passb mode=expb sign=zero fpsr=fpcc ctl=end | goto idle  ; FPCC I

cr_z:   alu=nop | if RPEXT goto wr_t0                  ; 0.0: 8 more single or double
        alu=nop budget=8 | goto wr_t0

; Rows 1 and 7, single PREC: RN - 2^39, RZ and RM + 2^39 (of the 64 bits).
cr_a17: alu=nop | unless PREC_SGL goto cr_ar
        alu=nop | if RND_RN goto cr_am
        alu=nop | if RND_RP goto cr_ar
        d=T0 a=T0 b=K[b42] alu=add | ret
cr_am:  d=T0 a=T0 b=K[b42] alu=sub | ret
cr_ar:  ret

; WinUAE's fpp_round32/64: by FPCR PREC's raw code (3 rounds as double),
; the mantissa only, no flags; a zero or $7FFF exponent untouched.
cr_rnd: a=T0 b=K[exp_inf] mode=exp alu=sub | dispatch PREC t_crr
.table t_crr PREC
  EXT  cr_r0
  SGL  :: alu=nop budget=8 | goto cr_rs                 ; (a nop keeps the flags)
  DBL  :: alu=nop budget=8 | goto cr_rd
  SGLX cr_rd
.end
cr_rs:  alu=nop | if Z goto cr_r0                       ; $7FFF: untouched
        a=T0 alu=passa
        alu=nop | if Z goto cr_r0                       ; zero: untouched
        d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=sgl
        d=T0 a=T3 b=RMASK alu=and rnd=sgl | if C goto cr_cy
        goto cr_r0
cr_rd:  alu=nop | if Z goto cr_r0
        a=T0 alu=passa
        alu=nop | if Z goto cr_r0
        d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=dbl
        d=T0 a=T3 b=RMASK alu=and rnd=dbl | if C goto cr_cy
        goto cr_r0
cr_cy:  d=T0 a=T0 b=K[one] alu=passb                    ; carried out
        d=T0 a=T0 b=0 alu=add cin=1 mode=exp
cr_r0:  stk=clr | ret

.include "transcend.uc"
.include "packed.uc"
.include "t882.uc"
