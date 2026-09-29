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

pro_reg: d=T1 b=FP[src] alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr
pro_go:  d=T9 a=T1 alu=passa | dispatch OPMODE ops      ; T9: the source, for EXOP
pro_x:   d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | goto pro_go
; S, D: a denormal is normalized here (Table 8-13's "not normalized" times).
pro_sd:  d=T1 b=CU alu=passb mode=mantb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | unless SUNN goto pro_go
pro_nrm: d=T1 a=T1 alu=passa osh=norm | goto pro_go
; B, W, L: the CU hands the magnitude and sign; the value is |n| x 2^0 (the
; exponent that puts the binary point below bit 0), normalized; 0 is +0.
pro_int: d=T1 b=OPINT alu=passb sign=b fpsr=clrexc ctl=rp_prec
         d=T0 b=FP[dst] alu=passb mode=mantb sign=b stk=clr | if SZERO goto pro_go
         d=T1 a=T1 b=K[int_exp] alu=passb mode=exp | goto pro_nrm

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
  redundant model
  default unimpl
.end

.entry reg   $00 pro_reg
.entry X     $00 pro_x
.entry S,D   $00 pro_sd
.entry B,W,L $00 pro_int
.entry reg   $18 pro_reg
.entry X     $18 pro_x
.entry S,D   $18 pro_sd
.entry B,W,L $18 pro_int
.entry reg   $1A pro_reg
.entry X     $1A pro_x
.entry S,D   $1A pro_sd
.entry B,W,L $1A pro_int
.entry reg   $38 pro_reg
.entry X     $38 pro_x
.entry S,D   $38 pro_sd
.entry B,W,L $38 pro_int
.entry reg   $3A pro_reg
.entry X     $3A pro_x
.entry S,D   $3A pro_sd
.entry B,W,L $3A pro_int
.entry reg   $22 pro_reg
.entry X     $22 pro_x
.entry S,D   $22 pro_sd
.entry B,W,L $22 pro_int
.entry reg   $23 pro_reg
.entry X     $23 pro_x
.entry S,D   $23 pro_sd
.entry B,W,L $23 pro_int
.entry reg   $27 pro_reg
.entry X     $27 pro_x
.entry S,D   $27 pro_sd
.entry B,W,L $27 pro_int
.entry reg   $20 pro_reg
.entry X     $20 pro_x
.entry S,D   $20 pro_sd
.entry B,W,L $20 pro_int
.entry reg   $24 pro_reg
.entry X     $24 pro_x
.entry S,D   $24 pro_sd
.entry B,W,L $24 pro_int
.entry reg   $28 pro_reg
.entry X     $28 pro_x
.entry S,D   $28 pro_sd
.entry B,W,L $28 pro_int

; ============================================================================
; FMOVE, FABS, FNEG to a register (8.6.8): the source through the
; post-processing; a zero, an infinity or a NaN as it is.  FABS and FNEG
; change the sign after the NaN test (a NaN keeps its sign).
; ============================================================================


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
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
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
cmp_mag: d=T0 a=T0 alu=passa osh=norm
        d=T1 a=T1 alu=passa osh=norm
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
; 6.1.5) at the rounding precision: normalize (one clock, osh=norm), round,
; the range checks by the TINY/HUGE comparators.  In: T0 finite and
; nonzero, STK its sticky bit.  Out: T5 the register image - T0 keeps the
; normalized, unrounded value for the exceptional operand; EXC's UNFL,
; OVFL, INEX2; EXOP for an enabled OVFL or UNFL (the value rounded to 64
; bits at its own exponent, wrapped by $6000, or exponent 0 past the
; catastrophic limits).  Five clocks on the common path (Table 8-18 gives
; extended rounding six).
; ============================================================================

pp:     d=T0 a=T0 alu=passa osh=norm
        d=T3 a=T0 b=RINC alu=add rnd=rprec | if TINY goto pp_tiny
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r | if C goto pp_cy
        alu=nop | if HUGE goto pp_ovfl
        ret
pp_cy:  d=T5 a=T5 b=K[one] alu=passb                    ; carried out: 1.0 ...
        d=T5 a=T5 b=0 alu=add cin=1 mode=exp            ; ... one binade up
        alu=nop | if HUGE goto pp_ovfl
        ret

; T6: T0 rounded to 64 bits with the true sticky bit (the exceptional
; operand's value, before any denormalization).
pp_xop: d=T6 a=T0 b=RINC alu=add rnd=ext
        d=T6 a=T6 b=RMASK alu=and rnd=ext | unless C goto pp_xr
        d=T6 a=T6 b=K[one] alu=passb
        d=T6 a=T6 b=0 alu=add cin=1 mode=exp
pp_xr:  ret

; Overflow (6.1.4): OVFL; the exceptional operand wrapped by -$6000; the
; result infinity or the largest number, by RND and the sign.
pp_ovfl: fpsr=orlit exc=OVFL | unless EN_OVFL goto pp_ovr
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
pp_nx:  d=T12 b=K[ext_emin] alu=passb mode=expb | goto pp_dn2
pp_ns:  d=T12 b=K[sgl_emin] alu=passb mode=expb | goto pp_dn2
pp_nd:  d=T12 b=K[dbl_emin] alu=passb mode=expb
pp_dn2: d=SC a=T12 b=T0 mode=exp alu=sub                ; the minimum - Eb, at most 127
        d=T5 a=T0 b=T12 alu=passb mode=exp
        d=T5 a=T5 b=T5>>SC alu=passb stk=shift
        d=T3 a=T5 b=RINC alu=add rnd=rprec
        d=T5 a=T3 b=RMASK alu=and rnd=rprec fpsr=inex2r
        alu=nop | if Z goto pp_uz
        alu=nop | if RPEXT goto pp_ret
        d=T5 a=T5 alu=passa osh=norm
pp_ret: ret
pp_uz:  d=T5 a=T5 b=0 alu=passb mode=exp | ret           ; rounded to nothing: a signed zero

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
nan_d:  alu=nop | if DNAN goto nd_d
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
        d=T1 a=T1 alu=passa sign=nota | dispatch TAGPAIR t_add

.table t_add TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  INF  add_ii
  INF  *    add_si
  *    INF  add_di
  ZERO ZERO add_zz
  ZERO *    add_sz
  *    ZERO add_dz
  default   :: d=T0 a=T0 alu=passa osh=norm | goto add_fin
.end

add_di: d=T0 a=T0 alu=passa | goto mk_inf               ; the destination's infinity
add_si: d=T0 a=T1 alu=passa | goto mk_inf               ; the source's (FSUB: negated)
add_ii: a=T0 b=T1 alu=passa sign=xor
        alu=nop | if S goto operr                       ; opposite infinities
        goto add_di
add_sz: d=T0 a=T0 alu=passa | goto wr_pp                ; x + 0: x at PREC
add_dz: d=T0 a=T1 alu=passa | goto wr_pp                ; 0 + x
add_zz: a=T0 b=T1 alu=passa sign=xor
        alu=nop | unless S goto add_zk                  ; like signs: that zero
add_z0: alu=nop | if RND_RM goto add_zm
        d=T0 b=0 alu=passb sign=zero | goto wr_t0       ; +0
add_zm: d=T0 b=0 alu=passb sign=one | goto wr_t0        ; -0 (RM)
add_zk: d=T0 a=T0 b=0 alu=passb mode=exp | goto wr_t0   ; the like-signed zero, exponent 0

add_fin: d=T1 a=T1 alu=passa osh=norm
        a=T0 b=T1 mode=exp alu=sub                      ; Ed - Es
        alu=nop | unless N goto add_al
        d=T2 a=T0 alu=passa                             ; the larger exponent to T0
        d=T0 a=T1 alu=passa
        d=T1 a=T2 alu=passa
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
add_sn: alu=nop | if Z goto add_z0                      ; an exact zero
        goto wr_pp

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
  INF  ZERO operr
  ZERO INF  operr
  INF  *    mul_inf
  *    INF  mul_inf
  ZERO *    mul_zero
  *    ZERO mul_zero
  default   :: d=T0 a=T0 alu=passa osh=norm | goto mul_fin
.end

mul_inf: d=T0 a=T0 b=T1 alu=passa sign=xor | goto mk_inf
mul_zero: d=T0 a=T0 b=T1 alu=passa sign=xor | goto mk_zero

mul_fin: d=T1 a=T1 alu=passa osh=norm
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
        d=T0 a=T2 b=T5 alu=passb | call pp
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
  ZERO ZERO operr
  INF  INF  operr
  *    INF  mul_inf                                  ; inf / x
  ZERO *    div_dz                                   ; x / 0
  *    ZERO mul_zero                                 ; 0 / x
  INF  *    mul_zero                                 ; x / inf
  default   :: d=T0 a=T0 alu=passa osh=norm | goto div_fin
.end

div_dz: d=T0 a=T0 b=T1 alu=passa sign=xor
        d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T0 a=T0 b=0 alu=passb | goto dz

div_fin: d=T1 a=T1 alu=passa osh=norm
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
        d=T0 a=T2 b=Q alu=passb | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
div_sn: a=T6 alu=passa stk=nz
        d=T0 a=T2 b=Q alu=passb | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle

; FSGLMUL: the inputs truncated to 24 bits (8.6.14 item 9); the multiplier's
; 24 bits need 9 Booth steps.  The product's high part in T4, its low 27
; bits in Q's top (bits 66-40); the window (a x b') >> 21 is (P << 6) |
; (Q >> 61) and the rest of Q the sticky bit - with the exponent E0 + E1 -
; bias + 1, as FMUL's.
.table t_sgm TAGPAIR
  NAN  *    nan_d
  *    NAN  nan_d
  INF  ZERO operr
  ZERO INF  operr
  INF  *    mul_inf
  *    INF  mul_inf
  ZERO *    mul_zero
  *    ZERO mul_zero
  default   :: d=T0 a=T0 alu=passa osh=norm | goto sgm_fin
.end
sgm_fin: d=T1 a=T1 alu=passa osh=norm | call sgl_tr
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
  ZERO ZERO operr
  INF  INF  operr
  *    INF  mul_inf
  ZERO *    div_dz
  *    ZERO mul_zero
  INF  *    mul_zero
  default   :: d=T0 a=T0 alu=passa osh=norm | goto sgd_fin
.end
; A result that may over- or underflow extended's range (the exponent
; within one of a limit) takes FDIV's full quotient: the exceptional
; operand is rounded to 64 bits (6.1.4-6.1.5) - which is what the manual's
; FSGLDIV times say (44 clocks, 62 on overflow, 90 on underflow).
sgd_fin: d=T1 a=T1 alu=passa osh=norm | call sgl_tr
        d=T2 a=T0 b=T1 mode=exp alu=sub sign=xor lc=26
        d=T2 a=T2 b=K[bias] mode=exp alu=add
        d=T6 a=T2 b=K[exp_one] mode=exp alu=sub         ; E - 1: TINY?
        d=T6 a=T2 b=K[exp_one] mode=exp alu=add | if TINY goto div_go   ; E + 1: HUGE?
        a=T0 b=T1 alu=sub | if HUGE goto div_go         ; C: a < b
        d=T4 b=T0>>2 alu=passb q=clear | if C goto sgd_lo
        d=T5 b=T1>>2 alu=passb
sgdloop: d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto sgdloop
        goto sgd_st
sgd_lo: d=T2 a=T2 b=K[exp_one] mode=exp alu=sub lc=27
        d=T5 b=T1>>2 alu=passb
sgdloop2: d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q dl=1 lc=dec | unless LCZ goto sgdloop2
sgd_st: d=T6 a=T4 b=T5<<1 alu=add | if DFLAG goto sgd_sn
        a=T4 alu=passa stk=nz | goto sgd_q
sgd_sn: a=T6 alu=passa stk=nz
sgd_q:  d=T0 a=T2 b=Q<<40 alu=passb | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
