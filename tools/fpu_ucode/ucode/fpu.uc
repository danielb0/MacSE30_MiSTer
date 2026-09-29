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

done:   fpsr=accrue ctl=end | goto idle

; ============================================================================
; The prologues, by source kind (the entry table's index, 8.8.11): the
; source to T1, the destination register to T0, EXC cleared (2.3.3), the
; rounding precision from FPCR, then the operation by its opmode.
; ============================================================================

pro_reg: d=T1 b=FP[src] alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | dispatch OPMODE ops
pro_cu:  d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | dispatch OPMODE ops
; B, W, L: the CU hands the magnitude and sign; the value is |n| x 2^0, so
; the exponent is the one that puts the binary point below bit 0.
pro_int: d=T1 b=OPINT alu=passb sign=b fpsr=clrexc ctl=rp_prec
         d=T1 a=T1 b=K[int_exp] alu=passb mode=exp
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | dispatch OPMODE ops

.table ops OPMODE
  $00  fmove
  $18  fabs
  $1A  fneg
  $38  fcmp
  $3A  ftst
  redundant model
  default unimpl
.end

.entry reg   $00 pro_reg
.entry S,D,X $00 pro_cu
.entry B,W,L $00 pro_int
.entry reg   $18 pro_reg
.entry S,D,X $18 pro_cu
.entry B,W,L $18 pro_int
.entry reg   $1A pro_reg
.entry S,D,X $1A pro_cu
.entry B,W,L $1A pro_int
.entry reg   $38 pro_reg
.entry S,D,X $38 pro_cu
.entry B,W,L $38 pro_int
.entry reg   $3A pro_reg
.entry S,D,X $3A pro_cu
.entry B,W,L $3A pro_int

; ============================================================================
; FMOVE, FABS, FNEG to a register (8.6.8): the source through the
; post-processing; a zero, an infinity or a NaN as it is.  FABS and FNEG
; change the sign after the NaN test (a NaN keeps its sign).
; ============================================================================

fmove:  alu=nop | dispatch STAG t_move
fabs:   alu=nop | dispatch STAG t_abs
fneg:   alu=nop | dispatch STAG t_neg

.table t_move STAG
  NORM mv_fin
  UNN  mv_fin
  ZERO mv_zero
  INF  mv_copy
  NAN  nan_m
.end
.table t_abs STAG
  NAN  nan_m
  default abs_go
.end
.table t_neg STAG
  NAN  nan_m
  default neg_go
.end

abs_go: d=T1 a=T1 alu=passa sign=zero | dispatch STAG t_move
neg_go: d=T1 a=T1 alu=passa sign=nota | dispatch STAG t_move

mv_fin: d=T0 a=T1 alu=passa | call pp
        d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto done
mv_zero: d=T0 a=T1 b=0 alu=passb mode=exp            ; a signed zero: exponent 0
        d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto done
mv_copy: d=FP[dst] a=T1 alu=passa fpsr=fpcc | goto done

; A monadic NaN (4.5.4): the source made nonsignaling; SNAN for a signaling
; one, and with the SNAN trap enabled FPn and FPCC are left (6.1.2, 8.6.14
; item 18) and the source is the exceptional operand.
nan_m:  d=T0 a=T1 b=K[qbit] alu=or | unless SSNAN goto nan_w
        fpsr=orlit exc=SNAN | unless EN_SNAN goto nan_w
        d=EXOP a=T1 alu=passa | goto done
nan_w:  d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto done

; ============================================================================
; FTST: FPCC from the source (a NaN made nonsignaling first, its sign kept).
; ============================================================================

ftst:   alu=nop | dispatch STAG t_tst
.table t_tst STAG
  NAN  tst_nan
  default tst_go
.end
tst_go: a=T1 alu=passa fpsr=fpcc | goto done
tst_nan: d=T0 a=T1 b=K[qbit] alu=or | unless SSNAN goto tst_nw
        fpsr=orlit exc=SNAN | unless EN_SNAN goto tst_nw
        d=EXOP a=T1 alu=passa | goto done
tst_nw: a=T0 alu=passa fpsr=fpcc | goto done

; ============================================================================
; FCMP (4-32): FPCC from destination - source, exactly; I never set.  The
; FPCC patterns are written by a word of the right class and sign.
; ============================================================================

fcmp:   alu=nop | dispatch TAGPAIR t_cmp
.table t_cmp TAGPAIR
  NAN  *    cmp_nan
  *    NAN  cmp_nan
  INF  INF  cmp_ii
  INF  *    cmp_srev                                 ; source infinite: - src decides
  *    INF  cmp_dsign                                ; destination infinite
  ZERO ZERO cmp_zz
  ZERO *    cmp_dsign                                ; source zero: the destination's sign
  *    ZERO cmp_srev                                 ; destination zero: - src
  default   cmp_fin
.end

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
cmp_mag: a=T0 alu=passa
        d=T0 b=T0<<LZC alu=passb mode=mantb sign=b
        d=T0 a=T0 b=SC mode=exp alu=sub
        a=T1 alu=passa
        d=T1 b=T1<<LZC alu=passb mode=mantb sign=b
        d=T1 a=T1 b=SC mode=exp alu=sub
        a=T0 b=T1 mode=exp alu=sub                      ; Ed - Es
        alu=nop | if Z goto cmp_m
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
; 6.1.5): normalize, the underflow check, round, the overflow check, at
; the rounding precision.  In: T0 finite and nonzero, STK its sticky bit.
; Out: T0 the register image; EXC's UNFL, OVFL, INEX2; EXOP for an enabled
; OVFL or UNFL (the value rounded to 64 bits at its own exponent, wrapped
; by $6000, or exponent 0 past the catastrophic limits).
; ============================================================================

pp:     d=T0 a=T0 alu=passa                             ; its leading zeros
        d=T0 b=T0<<LZC alu=passb mode=mantb sign=b      ; normalized; SC <- the count
        d=T0 a=T0 b=SC mode=exp alu=sub | dispatch RPREC pp_lim
.table pp_lim RPREC
  EXT   pp_x
  SGL   pp_s
  DBL   pp_d
  PREC3 pp_x
.end
pp_x:   d=T12 b=K[ext_emin] alu=passb mode=expb
        d=T13 b=K[ext_emax] alu=passb mode=expb | goto pp_go
pp_s:   d=T12 b=K[sgl_emin] alu=passb mode=expb
        d=T13 b=K[sgl_emax] alu=passb mode=expb | goto pp_go
pp_d:   d=T12 b=K[dbl_emin] alu=passb mode=expb
        d=T13 b=K[dbl_emax] alu=passb mode=expb | goto pp_go

; With an OVFL or UNFL trap enabled, first the exceptional operand's value:
; T0 rounded to 64 bits (extended) with the true sticky bit, into T6.
pp_go:  alu=nop | if EN_OVFL goto pp_xr
        alu=nop | unless EN_UNFL goto pp_t
pp_xr:  d=T6 a=T0 b=RINC alu=add rnd=ext
        d=T6 a=T6 b=RMASK alu=and rnd=ext | unless C goto pp_t
        d=T6 a=T6 b=K[one] alu=passb                    ; carried out: 1.0 ...
        d=T6 a=T6 b=0 alu=add cin=1 mode=exp            ; ... one binade up

pp_t:   a=T0 b=T12 mode=exp alu=sub                     ; tiny: Eb below the minimum
        alu=nop | if N goto pp_tiny
        d=T0 a=T0 b=RINC alu=add rnd=rprec fpsr=inex2r
        d=T0 a=T0 b=RMASK alu=and rnd=rprec stk=clr | unless C goto pp_ov
        d=T0 a=T0 b=K[one] alu=passb
        d=T0 a=T0 b=0 alu=add cin=1 mode=exp
pp_ov:  a=T0 b=T13 mode=exp alu=rsub                    ; overflow: the maximum - Eb < 0
        alu=nop | if N goto pp_ovfl
        ret

pp_ovfl: fpsr=orlit exc=OVFL | unless EN_OVFL goto pp_ovr
        a=T6 b=K[ovfl_cat] mode=exp alu=rsub            ; past 57343: catastrophic
        d=T7 a=T6 b=K[xop_bias] mode=exp alu=sub | if N goto pp_ovc
        d=EXOP a=T7 alu=passa | goto pp_ovr
pp_ovc: d=EXOP a=T6 b=0 alu=passb mode=exp
; 6.1.4's result: infinity, or the largest number, by RND and the sign.
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
pp_inf: d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T0 a=T0 b=0 alu=passb | ret
pp_big: d=T0 a=T0 b=T13 alu=passb mode=exp
        d=T0 a=T0 b=RMASK alu=passb rnd=rprec | ret

; Tiny (6.1.5): UNFL; shifted right to the minimum exponent with the sticky
; bit, rounded there.  Extended keeps the denormal at exponent 0; single
; and double are normalized again (an extended register holds them).
pp_tiny: fpsr=orlit exc=UNFL | unless EN_UNFL goto pp_dn
        a=T6 b=K[unfl_cat] mode=exp alu=sub             ; at or below -24576: catastrophic
        d=T7 a=T6 b=K[xop_bias] mode=exp alu=add | if N goto pp_unc
        d=EXOP a=T7 alu=passa | goto pp_dn
pp_unc: d=EXOP a=T6 b=0 alu=passb mode=exp
pp_dn:  d=SC a=T12 b=T0 mode=exp alu=sub                ; the minimum - Eb, at most 127
        d=T0 a=T0 b=T12 alu=passb mode=exp
        d=T0 a=T0 b=T0>>SC alu=passb stk=shift
        d=T0 a=T0 b=RINC alu=add rnd=rprec fpsr=inex2r
        d=T0 a=T0 b=RMASK alu=and rnd=rprec stk=clr
        alu=nop | if Z goto pp_uz
        alu=nop | if RPEXT goto pp_ret
        d=T0 b=T0<<LZC alu=passb mode=mantb sign=b
        d=T0 a=T0 b=SC mode=exp alu=sub
pp_ret: ret
pp_uz:  d=T0 a=T0 b=0 alu=passb mode=exp | ret           ; rounded to nothing: a signed zero
