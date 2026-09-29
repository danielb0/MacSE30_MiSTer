; The transcendentals' arithmetic: tools/fpu_model/transcend.py's I67
; operations, bit for bit (plan 8.8.19; the operations are defined there as
; this datapath computes them - Daniel's decision, 2026-09-29).
;
; An I67 value m x 2^e (m of 67 bits, normalized, or zero) is the word
; (s, e + 66 + bias, m).  The helpers take T11 and T12 and leave T11; they
; use T13-T15, Q, MD, MD3, SC and LC.  Values that must live across a
; checkpoint are kept in T0-T10 by the callers.

.export halt
halt:   ctl=end | goto idle                             ; vec.py's unit harness returns here

; -- iadd: T11 + T12 (transcend.i_add): the smaller exponent's mantissa
; shifted right and chopped, added or subtracted by the signs, the result
; chopped to 67 bits and normalized; an exact zero is +0. --
isub:   d=T12 a=T12 alu=passa sign=nota
iadd:   a=T11 alu=passa
        a=T12 alu=passa | if Z goto ia_b                ; T11 zero: T12
        a=T11 b=T12 mode=exp alu=sub | if Z goto ia_r   ; T12 zero: T11
        alu=nop | unless N goto ia_al
        d=T13 a=T11 alu=passa                           ; the larger exponent to T11
        d=T11 a=T12 alu=passa
        d=T12 a=T13 alu=passa
ia_al:  d=SC a=T11 b=T12 mode=exp alu=sub
        d=T12 a=T12 b=T12>>SC alu=passb
        a=T11 b=T12 alu=passa sign=xor
        d=T13 a=T11 b=T12 alu=add | if S goto ia_sub
        alu=nop | unless C goto ia_nc
        d=T11 a=T11 b=T12 alu=add osh=r1                ; carried: one place right, chopped
        d=T11 a=T11 b=0 alu=add cin=1 mode=exp | ret
ia_nc:  d=T11 a=T13 alu=passa | ret
ia_sub: d=T11 a=T11 b=T12 alu=sub
        alu=nop | unless C goto ia_sn
        d=T11 a=0 b=T11 alu=sub mode=mantb sign=notb    ; borrowed: the other sign
ia_sn:  d=T11 a=T11 alu=passa osh=norm
        alu=nop | unless Z goto ia_r
        d=T11 a=T11 alu=passa sign=zero | ret           ; an exact zero: +0
ia_b:   d=T11 a=T12 alu=passa
ia_r:   ret

; -- imul: T11 x T12 (transcend.i_mul): FMUL's multiplier on the 64-bit
; significands, the window (P >> 61) normalized; exponent E11 + E12 -
; bias + 1. --
imul:   a=T11 alu=passa
        a=T12 alu=passa | if Z goto im_z
        d=T13 a=T11 b=T12 mode=exp alu=add sign=xor | if Z goto im_z
        d=T13 a=T13 b=K[bias] mode=exp alu=sub cin=1
        d=T14 b=T12>>3 alu=passb
        d=MD a=T14 alu=passa
        d=MD3 a=T14 b=T14<<1 alu=add
        b=T11>>3 q=loadb
        d=T15 b=0 alu=passb lc=21
im_l:   d=T15 a=T15 b=BOOTH alu=addsub dir=booth osh=r3q lc=dec | unless LCZ goto im_l
        d=T14 b=T15<<5 alu=passb
        d=T14 a=T14 b=Q>>62 alu=or
        d=T11 a=T13 b=T14 alu=passb osh=norm | ret
im_z:   d=T11 a=T11 b=T12 alu=passa sign=xor
        d=T11 a=T11 b=0 alu=passb | ret                 ; zero, the signs' XOR

; -- idiv: T11 / T12, T12 nonzero (transcend.i_div): FDIV's divider on the
; operands chopped to 65 bits (>> 2), 67 quotient bits - 68 steps when the
; chopped dividend is the smaller - the remainder dropped. --
idiv:   a=T11 alu=passa
        d=T13 a=T11 b=T12 mode=exp alu=sub sign=xor lc=66 | if Z goto im_z
        d=T13 a=T13 b=K[bias] mode=exp alu=add
        d=T14 b=T11>>2 alu=passb q=clear
        d=T15 b=T12>>2 alu=passb
        a=T14 b=T15 alu=sub                             ; C: a' < b'
        d=T15 b=T12>>2 alu=passb dl=1 | if C goto id_lo ; DFLAG clear: subtract first
id_l:   d=T14 a=T14 b=T15 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto id_l
        d=T11 a=T13 b=Q alu=passb | ret
id_lo:  d=T13 a=T13 b=K[exp_one] mode=exp alu=sub lc=67
id_l2:  d=T14 a=T14 b=T15 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto id_l2
        d=T11 a=T13 b=Q alu=passb | ret

; -- isqrt: sqrt(T11), T11 >= 0 (transcend.i_sqrt): FSQRT's recurrence on
; the 64-bit radicand, the 64-bit root with three zero bits below. --
isqrt:  a=T11 alu=passa
        d=T13 a=T11 b=K[bias] mode=exp alu=sub | if Z goto ia_r      ; u (zero: zero)
        a=T13 b=K[exp_one] mode=exp alu=and             ; Z: u even
        d=T13 a=T13 alu=passa mode=exp osh=r1 | if Z goto is_ev   ; floor(u/2)
        d=T14 b=T11>>2 alu=passb | goto is_w
is_ev:  d=T14 b=T11>>3 alu=passb
is_w:   d=T14 a=T14 b=K[fx_half] alu=sub                ; W = 2x - 1/2 (N = 0)
        b=K[fx_half] q=loadb lc=62
is_l:   d=T14 a=T14 b=SQT alu=subadd dir=prevn a2=1 osh=qbit lc=dec | unless LCZ goto is_l
        d=T11 b=Q<<3 alu=passb sign=zero
        d=T11 a=T11 b=T13 alu=passb mode=exp
        d=T11 a=T11 b=K[bias] mode=exp alu=add | ret

; -- tofix: T11 as Q2.64 in T14's mantissa, two's complement, chopped toward
; zero (transcend.to_fixed with shift 0; a caller scales T11 first) - for
; |T11| < 2, the shift is right by bias + 2 - E. --
tofix:  d=SC a=T11 b=K[bias2] mode=exp alu=rsub
        d=T14 b=T11>>SC alu=passb
        a=T11 alu=passa
        alu=nop | unless S goto tf_r
        d=T14 a=0 b=T14 alu=sub                         ; negative: its two's complement
tf_r:   ret

; -- fromfix: the Q2.64 value in T14 as an I67 in T11 (transcend.from_fixed
; with shift 0), normalized; zero stays +0. --
fromfix: a=T14 alu=passa
        alu=nop | unless N goto ff_p
        d=T11 a=0 b=T14 alu=sub sign=one | goto ff_e    ; |v|, negative
ff_p:   d=T11 b=T14 alu=passb sign=zero
ff_e:   d=T11 a=T11 b=K[bias2] alu=passb mode=exp
        d=T11 a=T11 alu=passa osh=norm | ret

; ============================================================================
; The instructions' ends (fpu.py _computed): an exact zero stays a signed
; zero; anything else goes through pp with the sticky bit set - INEX2 on
; every computed result (UM 4.3.2).  In: T11.
; ============================================================================

tr_fin: a=T11 alu=passa
        d=T0 a=T11 alu=passa | if Z goto tr_z
        b=K[ulp] alu=passb stk=nz
        alu=nop | call pp
        d=FP[dst] a=T5 alu=passa fpsr=fpcc ctl=end | goto idle
tr_z:   d=T0 a=T11 b=0 alu=passb mode=exp | goto wr_t0
tr_one: d=T0 b=K[one] alu=passb mode=mantb sign=zero | goto wr_t0   ; +1.0, exact

; -- floorint: T7 = floor(T11) as a two's complement integer (|T11| < 2^66;
; math.floor(q.frac())) --
floorint: d=SC a=T11 b=K[int_exp] mode=exp alu=rsub     ; 66 + bias - E
        d=T7 b=T11>>SC alu=passb stk=shift              ; |q| chopped; STK: a fraction
        a=T11 alu=passa
        alu=nop | unless S goto fi_r
        d=T7 a=0 b=T7 alu=sub | unless STK goto fi_r    ; -|q|
        d=T7 a=T7 b=K[ulp] alu=sub                      ; a fraction: floor is one lower
fi_r:   stk=clr | ret

; -- fromint: T11 = the integer in T7 as an I67 (transcend.i_from_int) --
fromint: a=T7 alu=passa
        alu=nop | unless N goto fn_p
        d=T11 a=0 b=T7 alu=sub sign=one | goto fn_e
fn_p:   d=T11 b=T7 alu=passb sign=zero
fn_e:   d=T11 a=T11 b=K[int_exp] alu=passb mode=exp
        d=T11 a=T11 alu=passa osh=norm | ret

; -- reduce: T2 = T2 - n hi - n lo (transcend._reduce, Cody-Waite): n in T7,
; hi in T3, lo in T4; nothing when n = 0 --
reduce: a=T7 alu=passa
        alu=nop | if Z goto rd_r
        alu=nop | call fromint
        d=T6 a=T11 alu=passa                            ; N
        d=T12 a=T3 alu=passa | call imul                ; N hi (exact)
        d=T12 a=T11 alu=passa
        d=T11 a=T2 alu=passa | call isub
        d=T2 a=T11 alu=passa
        d=T11 a=T6 alu=passa
        d=T12 a=T4 alu=passa | call imul                ; N lo
        d=T12 a=T11 alu=passa
        d=T11 a=T2 alu=passa | call isub
        d=T2 a=T11 alu=passa
rd_r:   ret

; -- scale2: T11 x 2^n, n (T7) held to +/-65536 - past the catastrophic
; limits either way, so what software sees is the model's 2^n (8.8.19) --
scale2: a=T7 b=K[k65536] alu=sub
        alu=nop | if N goto s2_lo
        d=T13 b=K[k65536] alu=passb | goto s2_go
s2_lo:  a=T7 b=K[k65536] alu=add
        d=T13 a=T7 alu=passa | unless N goto s2_go
        d=T13 a=0 b=K[k65536] alu=sub
s2_go:  d=T11 a=T11 b=T13 bx=m2e mode=exp alu=add | ret

; -- overflowing: T11 = 2^(+/-65536) by T2's sign (transcend._overflowing:
; only the direction matters) --
overflowing: d=T11 b=K[one] alu=passb mode=mantb sign=zero
        a=T2 alu=passa
        alu=nop | if S goto ov_n
        d=T11 a=T11 b=K[k65536] bx=m2e mode=exp alu=add | ret
ov_n:   d=T11 a=T11 b=K[k65536] bx=m2e mode=exp alu=sub | ret

; -- expfrac: T14 = e^R for R (T14, Q2.64) in [0, ln 2) (transcend._exp_frac):
; Y = 1, and for i = 1 ... 63 the factor 1 + 2^-i while R covers ln(1 + 2^-i)
; - the table's word for i < 34, 2^(64-i) - 1 after it (the ROM's end) --
expfrac: d=T15 b=K[fx_one] alu=passb lc=1
ef_a:   d=T13 a=T14 b=K[lnup+LC]>>>LC alu=sub           ; R - L
        d=T12 a=T15 b=T15>>>LC alu=add | if N goto ef_an ; Y + Y 2^-i, ready
        d=T14 a=T13 alu=passa
        d=T15 a=T12 alu=passa | goto ef_a               ; taken: the same i again
ef_an:  alu=nop lc=inc lit=33 | unless LCEQ goto ef_a
ef_b:   d=T13 a=T14 b=K[fx_one]>>>LC alu=sub cin=1       ; R - (2^(64-i) - 1)
        d=T12 a=T15 b=T15>>>LC alu=add | if N goto ef_bn
        d=T14 a=T13 alu=passa
        d=T15 a=T12 alu=passa | goto ef_b
ef_bn:  alu=nop lc=inc lit=63 | unless LCEQ goto ef_b
        d=T14 a=T15 alu=passa | ret

; ============================================================================
; FETOX (transcend.etox): n = floor(x / ln 2), r = x - n ln 2 (Cody-Waite)
; brought into [0, ln 2), e^r by expfrac, times 2^n.  In: T2 = x.  Out: T11.
; ============================================================================

etox:   a=T2 b=K[b20] mode=exp alu=rsub                 ; |x| >= 2^21: only the direction
        d=T11 a=T2 alu=passa | if N goto overflowing
        d=T12 b=K[inv_ln2] alu=passb mode=mantb sign=b | call imul
        alu=nop | call floorint
        d=T3 b=K[ln2_hi] alu=passb mode=mantb sign=b
        d=T4 b=K[ln2_lo] alu=passb mode=mantb sign=b | call reduce
ex_neg: a=T2 alu=passa                                  ; r < 0: n - 1, r + ln 2
        alu=nop | unless S goto ex_pos
        d=T7 a=T7 b=K[ulp] alu=sub
        d=T11 a=T2 alu=passa
        d=T12 b=K[ln2] alu=passb mode=mantb sign=b | call iadd
        d=T2 a=T11 alu=passa | goto ex_neg
ex_pos: d=T11 a=T2 alu=passa                            ; r - ln 2 >= 0: n + 1, r - ln 2
        d=T12 b=K[ln2] alu=passb mode=mantb sign=b | call isub
        a=T11 alu=passa
        alu=nop | if S goto ex_go
        d=T2 a=T11 alu=passa
        d=T7 a=T7 b=K[ulp] alu=add | goto ex_pos
ex_go:  d=T11 a=T2 alu=passa | call tofix
        alu=nop | call expfrac
        alu=nop | call fromfix
        alu=nop | goto scale2                           ; (returns for etox)

; FTWOTOX (transcend.twotox): n = floor(x), f = x - n exactly, e^(f ln 2).
twotox: a=T2 b=K[b24] mode=exp alu=rsub
        d=T11 a=T2 alu=passa | if N goto overflowing
        alu=nop | call floorint
        a=T7 alu=passa
        alu=nop | if Z goto tt_f
        alu=nop | call fromint
        d=T12 a=T11 alu=passa
        d=T11 a=T2 alu=passa | call isub
        d=T2 a=T11 alu=passa
tt_f:   d=T11 a=T2 alu=passa
        d=T12 b=K[ln2] alu=passb mode=mantb sign=b | call imul
        alu=nop | call tofix
        alu=nop | call expfrac
        alu=nop | call fromfix
        alu=nop | goto scale2

; FTENTOX (transcend.tentox): n = floor(x log2 10), r = x - n log10 2
; (Cody-Waite) in [0, log10 2), e^(r ln 10), times 2^n.
tentox: d=T11 a=T2 alu=passa
        d=T12 b=K[log2_10] alu=passb mode=mantb sign=b | call imul
        a=T11 b=K[b24] mode=exp alu=rsub
        d=T5 a=T11 alu=passa | unless N goto te_n       ; y (|y| < 2^25)
        d=T2 a=T11 alu=passa | goto overflowing         ; the direction: y's
te_n:   d=T11 a=T5 alu=passa | call floorint
        d=T3 b=K[log10_2_hi] alu=passb mode=mantb sign=b
        d=T4 b=K[log10_2_lo] alu=passb mode=mantb sign=b | call reduce
te_neg: a=T2 alu=passa
        alu=nop | unless S goto te_pos
        d=T7 a=T7 b=K[ulp] alu=sub
        d=T11 a=T2 alu=passa
        d=T12 b=K[log10_2] alu=passb mode=mantb sign=b | call iadd
        d=T2 a=T11 alu=passa | goto te_neg
te_pos: d=T11 a=T2 alu=passa
        d=T12 b=K[log10_2] alu=passb mode=mantb sign=b | call isub
        a=T11 alu=passa
        alu=nop | if S goto te_go
        d=T2 a=T11 alu=passa
        d=T7 a=T7 b=K[ulp] alu=add | goto te_pos
te_go:  d=T11 a=T2 alu=passa
        d=T12 b=K[ln10] alu=passb mode=mantb sign=b | call imul
        alu=nop | call tofix
        alu=nop | call expfrac
        alu=nop | call fromfix
        alu=nop | goto scale2

; The instructions (fpu.py _exp_like): 0 -> +1 exactly; -inf -> +0;
; +inf -> +inf; else the function through tr_fin.
.table t_exp STAG
  NAN  nan_m
  ZERO tr_one
  INF  exp_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_etox
.end
.table t_twotox STAG
  NAN  nan_m
  ZERO tr_one
  INF  exp_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_twotox
.end
.table t_tentox STAG
  NAN  nan_m
  ZERO tr_one
  INF  exp_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_tentox
.end
exp_inf: alu=nop | unless SNEG goto mv_copy
        d=T0 b=0 alu=passb sign=zero | goto wr_t0       ; e^-inf = +0
x_etox: alu=nop | call etox
        goto tr_fin
x_twotox: alu=nop | call twotox
        goto tr_fin
x_tentox: alu=nop | call tentox
        goto tr_fin

; ============================================================================
; expm1s: e^u - 1 for |u| < 1/4, keeping its relative precision
; (transcend._expm1_small).  s = -exponent(u) - 1 (SC, 2 or more); R = |u| 2^s
; in Q2.64 (T8); D (T9) is e^u - 1 scaled by 2^s.  For i = s, s + 1 ... the
; factor 1 + 2^-i (u > 0) or 1 - 2^-i (u < 0) while R covers its logarithm
; L: R -= L, D +/-= 2^(64+s-i) + (D >> i) - floor((2^(64+s) + D) 2^-i) while
; i - s <= 64.  L is the table's word placed by i - s for i <= 33, then
; 2^(64+s-i) + C (u > 0) or - C (u < 0), C = floor(-2^(63+s-2i)) kept in T10
; (two places further an i).  u > 0 ends where L is 0 (i = s + 64); u < 0
; after i = s + 64 (the model's last two steps move nothing and leave R =
; 0).  Then D +/-= R.  In: T2 = u.  Out: T11.
; ============================================================================

expm1s: d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s = bias - 1 - E
        d=T11 a=T2 b=K[bm1] alu=passb mode=exp sign=zero ; |u| 2^s (exponent bias - 1)
        d=T9 b=SC alu=passb lc=alu | call tofix         ; i = s
        d=T8 a=T14 alu=passa                            ; R
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s again (tofix used SC)
        d=T10 b=K[fx_negone]>>>SC alu=passb
        d=T10 a=0 b=T10>>>1 alu=passb                   ; C = floor(-2^(63-s))
        d=T9 b=0 alu=passb                              ; D = 0
        a=T2 b=K[bm34] mode=exp alu=sub                 ; s >= 34: no table phase
        a=T2 alu=passa | if N goto em_b
        alu=nop | if S goto da_i
; u > 0, the table phase (i <= 33)
ua_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=34 | if LCEQ goto ub_i2   ; P = 2^(64+s-i); i = 34: synthesized
        d=T12 b=K[lnup+LC]>>>LC-SC alu=passb            ; L
ua_w:   d=T13 a=T8 b=T12 alu=sub                        ; R - L
        d=T14 a=T4 b=T9>>>LC alu=add | if N goto ua_n   ; the step, ready
        d=T8 a=T13 alu=passa
        d=T9 a=T9 b=T14 alu=add | goto ua_w
ua_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto ua_i
; u > 0, synthesized
ub_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb
ub_i2:  d=T12 a=T4 b=T10 alu=add                        ; L = P + C
        alu=nop | if Z goto em_uf                       ; L = 0: the end
ub_w:   d=T13 a=T8 b=T12 alu=sub
        d=T14 a=T4 b=T9>>>LC alu=add | if N goto ub_n
        d=T8 a=T13 alu=passa
        d=T9 a=T9 b=T14 alu=add | goto ub_w
ub_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto ub_i
em_uf:  d=T14 a=T9 b=T8 alu=add | goto em_out           ; D + R
em_b:   alu=nop | if S goto db_i
        goto ub_i
; u < 0, the table phase
da_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=34 | if LCEQ goto db_i2
        d=T12 a=0 b=K[lndn+LC]>>>LC-SC alu=sub          ; L = -(the word placed)
da_w:   d=T13 a=T8 b=T12 alu=sub
        d=T14 a=T4 b=T9>>>LC alu=add | if N goto da_n
        d=T8 a=T13 alu=passa
        d=T9 a=T9 b=T14 alu=sub | goto da_w
da_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto da_i
; u < 0, synthesized: to i = s + 64
db_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=65 | if LCSCEQ goto db_e
db_i2:  d=T12 a=T4 b=T10 alu=sub                        ; L = P - C
db_w:   d=T13 a=T8 b=T12 alu=sub
        d=T14 a=T4 b=T9>>>LC alu=add | if N goto db_n
        d=T8 a=T13 alu=passa
        d=T9 a=T9 b=T14 alu=sub | goto db_w
db_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto db_i
db_e:   d=T14 a=T9 alu=passa                            ; D - 0 (R is 0 by then)
em_out: alu=nop | call fromfix
        d=T11 a=T11 b=SC mode=exp alu=sub | ret         ; 2^-s

; -- etoxm1 (transcend.etoxm1): exponent below -66: u itself; below -2: the
; scaled shift-add; else e^x - 1.  In: T2.  Out: T11. --
etoxm1: a=T2 b=K[bm66] mode=exp alu=sub
        d=T11 a=T2 alu=passa | if N goto em_r
        a=T2 b=K[bm2] mode=exp alu=sub
        alu=nop | if N goto expm1s
        alu=nop | call etox
        d=T12 b=K[one] alu=passb mode=mantb sign=b | goto isub
em_r:   ret

; ============================================================================
; FETOXM1, FSINH, FCOSH, FTANH (transcend.etoxm1, sinh, cosh, tanh; fpu.py's
; special cases).  Straight-line from the instruction, so the calls nest at
; most four deep (etoxm1 > etox > reduce > imul).
; ============================================================================

.table t_expm1 STAG
  NAN  nan_m
  ZERO mv_copy
  INF  em_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_expm1
.end
em_inf: alu=nop | unless SNEG goto mv_copy
        d=T0 b=K[one] alu=passb mode=mantb sign=one | goto wr_t0      ; e^-inf - 1 = -1
x_expm1: alu=nop | call etoxm1
        goto tr_fin

; sinh = sign (z + z/(1 + z))/2, z = e^|x| - 1
.table t_sinh STAG
  NAN  nan_m
  ZERO mv_copy
  INF  mv_copy
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_sinh
.end
x_sinh: d=T2 a=T2 alu=passa sign=zero | call etoxm1
        d=T3 a=T11 alu=passa                            ; z
        d=T12 b=K[one] alu=passb mode=mantb sign=b | call iadd
        d=T12 a=T11 alu=passa
        d=T11 a=T3 alu=passa | call idiv                ; z / (1 + z)
        d=T12 a=T11 alu=passa
        d=T11 a=T3 alu=passa | call iadd
        d=T11 a=T11 b=K[exp_one] mode=exp alu=sub
        d=T11 a=T11 b=T1 alu=passa sign=b | goto tr_fin ; x's sign

; cosh = (t + 1/t)/2, t = e^|x|
.table t_cosh STAG
  NAN  nan_m
  ZERO tr_one
  INF  :: d=T0 a=T1 alu=passa sign=zero | goto mk_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_cosh
.end
x_cosh: d=T2 a=T2 alu=passa sign=zero | call etox
        d=T3 a=T11 alu=passa
        d=T12 a=T11 alu=passa
        d=T11 b=K[one] alu=passb mode=mantb sign=b | call idiv   ; 1/t
        d=T12 a=T3 alu=passa | call iadd
        d=T11 a=T11 b=K[exp_one] mode=exp alu=sub sign=zero | goto tr_fin

; tanh = sign z/(z + 2), z = e^(2|x|) - 1; 2|x| above 2^7: 1 - 2^-67;
; bounded below 1 (transcend.bounded)
.table t_tanh STAG
  NAN  nan_m
  ZERO mv_copy
  INF  :: d=T0 a=T1 b=K[one] alu=passb mode=mantb sign=a | goto wr_t0   ; +/-1
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_tanh
.end
x_tanh: d=T2 a=T2 b=K[exp_one] mode=exp alu=add sign=zero   ; 2|x|
        a=T2 b=K[b7] mode=exp alu=rsub
        alu=nop | if N goto th_one
        alu=nop | call etoxm1
        d=T3 a=T11 alu=passa
        d=T12 b=K[two] alu=passb mode=mantb sign=b | call iadd
        d=T12 a=T11 alu=passa
        d=T11 a=T3 alu=passa | call idiv
        d=T11 a=T11 b=T1 alu=passa sign=b
bounded: a=T11 b=K[bias] mode=exp alu=sub               ; exponent >= 0: 1 - 2^-67
        alu=nop | if N goto tr_fin
th_one: d=T11 a=T1 b=K[almost_one] alu=passb mode=mantb sign=a | goto tr_fin

; ============================================================================
; log1ps: ln(1 + u) for |u| < 1/4, keeping its relative precision
; (transcend._log1p_small).  s = -exponent(u) - 1 (SC); U = u 2^s in Q2.64
; (T8, two's complement); L (T9) the logarithm scaled by 2^s.  For i = s ...
; the step floor((2^(64+s) + U) 2^-i) = 2^(64+s-i) + (U >> i) drives U to 0:
; u > 0 by factors 1 - 2^-i (U -= step while it stays >= 0, L += -ln(1 -
; 2^-i)), u < 0 by 1 + 2^-i (U += step while it stays <= 0, L -= ln(1 +
; 2^-i)); the table's words placed by i - s for i <= 33, then 2^(64+s-i) -
; C (u > 0) or -(2^(64+s-i) + C) (u < 0), C = floor(-2^(63+s-2i)) in T10.
; u > 0 runs to i = s + 64, u < 0 to s + 63 (its step is 0 at s + 64).
; Then L + U.  In: T2 = u.  Out: T11.
; ============================================================================

log1ps: d=T11 a=T2 b=K[bm1] alu=passb mode=exp          ; u 2^s (exponent bias - 1), its sign
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub | call tofix
        d=T8 a=T14 alu=passa                            ; U
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s
        d=T9 b=SC alu=passb lc=alu                      ; i = s
        d=T10 b=K[fx_negone]>>>SC alu=passb
        d=T10 a=0 b=T10>>>1 alu=passb                   ; C = floor(-2^(63-s))
        d=T9 b=0 alu=passb                              ; L = 0
        a=T2 b=K[bm34] mode=exp alu=sub
        a=T2 alu=passa | if N goto lp_b
        alu=nop | if S goto la_i
; u > 0
pa_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=34 | if LCEQ goto pb_i2
        d=T12 a=0 b=K[lndn+LC]>>>LC-SC alu=sub          ; -ln(1 - 2^-i), placed
pa_w:   d=T14 a=T4 b=T8>>>LC alu=add                    ; the step
        d=T13 a=T8 b=T14 alu=sub
        d=T15 a=T9 b=T12 alu=add | if N goto pa_n       ; U - step < 0: the next i
        d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto pa_w
pa_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto pa_i
pb_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=65 | if LCSCEQ goto lp_e
pb_i2:  d=T12 a=T4 b=T10 alu=sub                        ; 2^(64+s-i) - C
pb_w:   d=T14 a=T4 b=T8>>>LC alu=add
        d=T13 a=T8 b=T14 alu=sub
        d=T15 a=T9 b=T12 alu=add | if N goto pb_n
        d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto pb_w
pb_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto pb_i
lp_b:   alu=nop | if S goto lb_i
        goto pb_i
; u < 0
la_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=34 | if LCEQ goto lb_i2
        d=T12 a=0 b=K[lnup+LC]>>>LC-SC alu=sub          ; -ln(1 + 2^-i), placed
la_w:   d=T14 a=T4 b=T8>>>LC alu=add
        d=T13 a=T8 b=T14 alu=add dl=1                   ; U + step; DFLAG: negative
        d=T15 a=T9 b=T12 alu=add | if Z goto la_t       ; U + step = 0: taken
        alu=nop | unless DFLAG goto la_n                ; U + step > 0: the next i
la_t:   d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto la_w
la_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto la_i
lb_i:   d=T4 b=K[fx_one]>>>LC-SC alu=passb lit=64 | if LCSCEQ goto lp_e
lb_i2:  d=T12 a=T4 b=T10 alu=add
        d=T12 a=0 b=T12 alu=sub                         ; -(2^(64+s-i) + C)
lb_w:   d=T14 a=T4 b=T8>>>LC alu=add
        d=T13 a=T8 b=T14 alu=add dl=1
        d=T15 a=T9 b=T12 alu=add | if Z goto lb_t
        alu=nop | unless DFLAG goto lb_n
lb_t:   d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto lb_w
lb_n:   d=T10 a=0 b=T10>>>2 alu=passb lc=inc | goto lb_i
lp_e:   d=T14 a=T9 b=T8 alu=add                         ; L + U
        alu=nop | call fromfix
        d=T11 a=T11 b=SC mode=exp alu=sub | ret         ; 2^-s

; -- log1pf: ln(1 + u) for u (T14, Q2.64) in [0, 1), unscaled
; (transcend._log1p_frac): factors 1 - 2^-i for i = 1 ... 64 while U -
; (1 + U) 2^-i stays >= 0, L += -ln(1 - 2^-i) (the table's for i <= 33, then
; 2^(64-i) + 1).  Out: T14 = L + U. --
log1pf: d=T8 a=T14 alu=passa
        d=T9 b=0 alu=passb lc=1
pf_a:   d=T4 b=K[fx_one]>>>LC alu=passb lit=34 | if LCEQ goto pf_b2
        d=T12 a=0 b=K[lndn+LC]>>>LC alu=sub
pf_aw:  d=T14 a=T4 b=T8>>>LC alu=add                    ; (1 + U) 2^-i
        d=T13 a=T8 b=T14 alu=sub
        d=T15 a=T9 b=T12 alu=add | if N goto pf_an
        d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto pf_aw
pf_an:  alu=nop lc=inc | goto pf_a
pf_b:   d=T4 b=K[fx_one]>>>LC alu=passb lit=65 | if LCEQ goto pf_e
pf_b2:  d=T12 a=T4 b=K[ulp] alu=add                     ; 2^(64-i) + 1
pf_bw:  d=T14 a=T4 b=T8>>>LC alu=add
        d=T13 a=T8 b=T14 alu=sub
        d=T15 a=T9 b=T12 alu=add | if N goto pf_bn
        d=T8 a=T13 alu=passa
        d=T9 a=T15 alu=passa | goto pf_bw
pf_bn:  alu=nop lc=inc | goto pf_b
pf_e:   d=T14 a=T9 b=T8 alu=add | ret

; -- logn (transcend.logn): near 1 (|x - 1| < 1/4) the scaled path; else x
; = 2^E m, E ln 2 + ln m.  In: T2 = x (> 0).  Out: T11. --
logn:   d=T11 a=T2 alu=passa
        d=T12 b=K[one] alu=passb mode=mantb sign=b | call isub   ; u = x - 1
        a=T11 alu=passa
        d=T3 a=T11 alu=passa | if Z goto ln_r            ; u = 0: +0
        a=T11 b=K[bm2] mode=exp alu=sub
        alu=nop | unless N goto ln_m
        d=T2 a=T3 alu=passa | goto log1ps                ; small: ln(1 + u)
ln_m:   d=T11 a=T2 b=K[bias] alu=passb mode=exp          ; m in [1, 2)
        d=T12 b=K[one] alu=passb mode=mantb sign=b | call isub
        alu=nop | call tofix
        alu=nop | call log1pf
        alu=nop | call fromfix                           ; ln m
        d=T3 a=T11 alu=passa
        d=T7 a=T2 b=K[bias] mode=exp alu=sub             ; E
        d=T7 b=T7 bx=e2m alu=passb                       ; as an integer
        alu=nop | if Z goto ln_lm
        alu=nop | call fromint
        d=T12 b=K[ln2] alu=passb mode=mantb sign=b | call imul   ; E ln 2
        d=T12 a=T3 alu=passa | goto iadd                 ; + ln m
ln_lm:  d=T11 a=T3 alu=passa
ln_r:   ret

; -- lognp1 (transcend.lognp1): below 2^-66 x itself; below 1/4 the scaled
; path; else ln(1 + x).  In: T2.  Out: T11. --
lognp1: a=T2 b=K[bm66] mode=exp alu=sub
        d=T11 a=T2 alu=passa | if N goto ln_r
        a=T2 b=K[bm2] mode=exp alu=sub
        alu=nop | if N goto log1ps
        d=T12 b=K[one] alu=passb mode=mantb sign=b | call iadd   ; 1 + x
        d=T2 a=T11 alu=passa | goto logn

; ============================================================================
; FLOGN, FLOG2, FLOG10, FLOGNP1, FATANH (fpu.py _log_like, _op_flognp1,
; _op_fatanh): 0 -> -inf with DZ; below 0 -> OPERR; +inf -> +inf.
; ============================================================================

.table t_logn STAG
  NAN  nan_m
  ZERO log_z
  INF  log_i
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_logn
.end
.table t_log2 STAG
  NAN  nan_m
  ZERO log_z
  INF  log_i
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_log2
.end
.table t_log10 STAG
  NAN  nan_m
  ZERO log_z
  INF  log_i
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_log10
.end
log_z:  d=T0 b=0 alu=passb sign=one
        d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp | goto dz   ; -inf, DZ
log_i:  alu=nop | if SNEG goto operr
        goto mv_copy
x_logn: alu=nop | if SNEG goto operr
        alu=nop | call logn
        goto tr_fin
x_log2: alu=nop | if SNEG goto operr
        alu=nop | call logn
        d=T12 b=K[log2_e] alu=passb mode=mantb sign=b | call imul
        goto tr_fin
x_log10: alu=nop | if SNEG goto operr
        alu=nop | call logn
        d=T12 b=K[log10_e] alu=passb mode=mantb sign=b | call imul
        goto tr_fin

; FLOGNP1: -1 -> NaN with DZ (8.6.14 item 2, the manual's 4-60); below -1:
; OPERR.
.table t_lnp1 STAG
  NAN  nan_m
  ZERO mv_copy
  INF  log_i
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_lnp1
.end
x_lnp1: alu=nop | unless SNEG goto lp1_go
        d=T11 a=T2 alu=passa
        d=T12 b=K[one] alu=passb mode=mantb sign=b | call iadd   ; 1 + x
        a=T11 alu=passa
        alu=nop | if Z goto lp1_m1
        alu=nop | if S goto operr
lp1_go: alu=nop | call lognp1
        goto tr_fin
lp1_m1: d=T0 b=K[nan] alu=passb mode=mantb sign=zero | goto dz

; FATANH: |x| > 1: OPERR; |x| = 1: -sign(x) infinity with DZ (8.6.14 item
; 1, as printed); else sign ln(1 + 2|x|/(1 - |x|))/2.
.table t_atanh STAG
  NAN  nan_m
  ZERO mv_copy
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm sign=zero | goto x_atanh
.end
x_atanh: a=T2 b=K[bias] mode=exp alu=sub                ; |x| against 1
        alu=nop | if N goto at_go                       ; below 1
        alu=nop | unless Z goto operr                   ; 2 or more
        a=T2 b=K[one] alu=sub                           ; the mantissa against 1.0
        alu=nop | unless Z goto operr
        d=T0 a=T1 alu=passa sign=nota                   ; -sign(x)
        d=T0 a=T0 b=K[exp_inf] alu=passb mode=exp
        d=T0 a=T0 b=0 alu=passb | goto dz
at_go:  d=T11 b=K[one] alu=passb mode=mantb sign=b
        d=T12 a=T2 alu=passa | call isub                 ; 1 - |x|
        d=T12 a=T11 alu=passa
        d=T11 a=T2 b=K[exp_one] mode=exp alu=add | call idiv    ; 2|x| / (1 - |x|)
        d=T2 a=T11 alu=passa | call lognp1
        d=T11 a=T11 b=K[exp_one] mode=exp alu=sub
        d=T11 a=T11 b=T1 alu=passa sign=b | goto tr_fin

; ============================================================================
; crot: circular CORDIC, rotation mode (transcend.cordic_rotate): cos and sin
; of z (T2, 0 < z <= pi/4).  Below 2^-34: (1, z).  Else s = -exponent(z) - 1
; (SC), X = the gain for s (T6/T8 alternating), Y = 0 (T7), Z = z 2^s (T9);
; for i = s ... s + 66: by Z's sign (DFLAG) X -/+= Y >> (i + s), Y +/-= X >>
; (i - s), Z -/+= atan(2^-i) 2^s - the table's word for i <= 33, 2^(64+s-i)
; after.  Out: T4 = cos (X), T10 = sin (Y 2^-s).  Three clocks an iteration.
; ============================================================================

crot:   a=T2 b=K[bm34] mode=exp alu=sub
        alu=nop | unless N goto ro_go
        d=T4 b=K[one] alu=passb mode=mantb sign=zero    ; 1
        d=T10 a=T2 alu=passa | ret                      ; z
ro_go:  d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s
        d=T11 a=T2 b=K[bm1] alu=passb mode=exp | call tofix     ; z 2^s
        d=T9 a=T14 alu=passa dl=1                       ; Z >= 0: DFLAG clear
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s again (tofix used SC)
        d=T6 b=SC alu=passb lc=alu                      ; i = s
        d=T6 b=K[gain+LC] alu=passb                     ; X = 1/K(s)
        d=T7 b=0 alu=passb                              ; Y = 0
ro_aa:  d=T8 a=T6 b=T7>>>LC+SC alu=subadd dir=dflag lit=34 | if LCEQ goto ro_ba2
        d=T7 a=T7 b=T6>>>LC-SC alu=addsub dir=dflag
        d=T9 a=T9 b=K[atan+LC]>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
ro_ab:  d=T6 a=T8 b=T7>>>LC+SC alu=subadd dir=dflag lit=34 | if LCEQ goto ro_bb2
        d=T7 a=T7 b=T8>>>LC-SC alu=addsub dir=dflag
        d=T9 a=T9 b=K[atan+LC]>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc | goto ro_aa
ro_ba:  d=T8 a=T6 b=T7>>>LC+SC alu=subadd dir=dflag lit=67 | if LCSCEQ goto ro_ea
ro_ba2: d=T7 a=T7 b=T6>>>LC-SC alu=addsub dir=dflag
        d=T9 a=T9 b=K[fx_one]>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
ro_bb:  d=T6 a=T8 b=T7>>>LC+SC alu=subadd dir=dflag lit=67 | if LCSCEQ goto ro_eb
ro_bb2: d=T7 a=T7 b=T8>>>LC-SC alu=addsub dir=dflag
        d=T9 a=T9 b=K[fx_one]>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc | goto ro_ba
ro_eb:  d=T6 a=T8 alu=passa                             ; X was in T8
ro_ea:  d=T14 a=T6 alu=passa | call fromfix
        d=T4 a=T11 alu=passa                            ; cos
        d=T14 a=T7 alu=passa | call fromfix
        d=T10 a=T11 b=SC mode=exp alu=sub | ret         ; sin = Y 2^-s

; -- bnd: T11 held below 1 (transcend.bounded): exponent >= 0 and nonzero:
; +/-(1 - 2^-67) --
bnd:    a=T11 alu=passa
        a=T11 b=K[bias] mode=exp alu=sub | if Z goto bn_r
        alu=nop | if N goto bn_r
        d=T11 a=T11 b=K[almost_one] alu=passb mode=mantb sign=a
bn_r:   ret

; ============================================================================
; sincos (transcend.sincos): x (T2, nonzero) reduced by 2pi to 65 bits
; (FMOD's loop, mr_loop) when |x| is larger; the quadrant k (LC, then T3) by
; subtracting pi/2 while r > pi/4; crot on |r|, the sine negated for a
; negative r; k & 3's swaps; x's sign on the sine; both bounded.  Out: T10 =
; sin, T4 = cos.
; ============================================================================

sincos: d=T0 a=T2 alu=passa                             ; x's sign (T0 is free until pp)
        a=T2 b=K[twopi] mode=exp alu=sub                ; |x| against 2pi
        alu=nop | if N goto sc_q
        alu=nop | unless Z goto sc_red
        a=T2 b=K[twopi] alu=sub                         ; equal exponents: the mantissas
        alu=nop | if C goto sc_q
        alu=nop | if Z goto sc_q
sc_red: d=T5 b=K[twopi]>>2 alu=passb dl=1               ; the divisor; DFLAG clear
        d=T4 b=T2>>2 alu=passb q=clear
        d=T7 a=T2 b=K[twopi] mode=exp alu=sub
        d=T7 a=T7 b=K[exp_one] mode=exp alu=add | call mr_loop
        d=T6 a=T4 b=T5<<1 alu=add | unless DFLAG goto sc_rr
        d=T4 a=T6 alu=passa                             ; the remainder corrected
sc_rr:  d=T2 a=T2 b=K[twopi] alu=passb mode=exp         ; 2r at 2pi's exponent + 1
        d=T2 a=T2 b=K[exp_one] mode=exp alu=add
        d=T2 a=T2 b=T4 alu=passb osh=norm               ; (x's sign)
sc_q:   d=T2 a=T2 alu=passa sign=zero lc=0              ; z = |z|, k = 0
sc_ql:  a=T2 alu=passa
        alu=nop | if S goto sc_cr                       ; r < 0: done
        alu=nop | if Z goto sc_cr                       ; r = 0: done
        a=T2 b=K[quarterpi] mode=exp alu=sub
        alu=nop | if N goto sc_cr
        alu=nop | unless Z goto sc_sub
        a=T2 b=K[quarterpi] alu=sub
        alu=nop | if C goto sc_cr
        alu=nop | if Z goto sc_cr
sc_sub: d=T11 a=T2 alu=passa
        d=T12 b=K[halfpi] alu=passb mode=mantb sign=b | call isub
        d=T2 a=T11 alu=passa lc=inc | goto sc_ql        ; r - pi/2, k + 1
sc_cr:  d=T3 b=LC alu=passb                             ; k (crot uses LC)
        d=T5 a=T2 alu=passa                             ; r's sign
        d=T2 a=T2 alu=passa sign=zero
        a=T2 alu=passa
        alu=nop | unless Z goto sc_c2
        d=T4 b=K[one] alu=passb mode=mantb sign=zero    ; r = 0: (1, +0)
        d=T10 b=0 alu=passb sign=zero | goto sc_sw
sc_c2:  alu=nop | call crot
sc_sw:  a=T5 alu=passa
        alu=nop | unless S goto sc_k
        d=T10 a=T10 alu=passa sign=nota                 ; r < 0: -sin
sc_k:   d=T3 a=T3 alu=passa lc=alu                      ; k back in LC
        alu=nop lit=1 | if LCEQ goto sc_1
        alu=nop lit=2 | if LCEQ goto sc_2
        alu=nop lit=3 | if LCEQ goto sc_3
        goto sc_n                                       ; k = 0 or 4
sc_1:   d=T13 a=T10 alu=passa sign=nota                 ; (c, -s)
        d=T10 a=T4 alu=passa
        d=T4 a=T13 alu=passa | goto sc_n
sc_2:   d=T10 a=T10 alu=passa sign=nota                 ; (-s, -c)
        d=T4 a=T4 alu=passa sign=nota | goto sc_n
sc_3:   d=T13 a=T10 alu=passa                           ; (-c, s)
        d=T10 a=T4 alu=passa sign=nota
        d=T4 a=T13 alu=passa
sc_n:   a=T0 alu=passa
        alu=nop | unless S goto sc_b
        d=T10 a=T10 alu=passa sign=nota                 ; x < 0: -sin
sc_b:   d=T11 a=T4 alu=passa | call bnd
        d=T4 a=T11 alu=passa
        d=T11 a=T10 alu=passa | call bnd
        d=T10 a=T11 alu=passa | ret

; ============================================================================
; FSIN, FCOS, FTAN, FSINCOS (fpu.py _trig, _op_fcos, _op_fsincos): 0 -> 0
; (FCOS 1); an infinity: OPERR.  FTAN = sin / cos.  FSINCOS writes the
; cosine to FPc, then the sine to FPs (FPs = FPc keeps the sine), FPCC from
; the sine; EXC the sine's and the cosine's INEX2.
; ============================================================================

.table t_sin STAG
  NAN  nan_m
  ZERO mv_copy
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_sin
.end
.table t_cos STAG
  NAN  nan_m
  ZERO tr_one
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_cos
.end
.table t_tan STAG
  NAN  nan_m
  ZERO mv_copy
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_tan
.end
x_sin:  alu=nop | call sincos
        d=T11 a=T10 alu=passa | goto tr_fin
x_cos:  alu=nop | call sincos
        d=T11 a=T4 alu=passa | goto tr_fin
x_tan:  alu=nop | call sincos
        d=T11 a=T10 alu=passa
        d=T12 a=T4 alu=passa | call idiv
        goto tr_fin

.table t_sincos STAG
  NAN  scs_nan
  ZERO scs_z
  INF  scs_inf
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_sincos
.end
x_sincos: alu=nop | call sincos
        a=T4 alu=passa
        d=T0 a=T4 alu=passa | if Z goto scs_cz
        b=K[ulp] alu=passb stk=nz                       ; computed: inexact
        alu=nop | call pp
        d=FP[c] a=T5 alu=passa | goto scs_s
scs_cz: d=T0 a=T4 b=0 alu=passb mode=exp
        d=FP[c] a=T0 alu=passa
scs_s:  d=T11 a=T10 alu=passa | goto tr_fin
scs_z:  d=T0 b=K[one] alu=passb mode=mantb sign=zero
        d=FP[c] a=T0 alu=passa
        d=FP[dst] a=T1 alu=passa fpsr=fpcc ctl=end | goto idle
scs_inf: d=T0 b=K[nan] alu=passb mode=mantb sign=b fpsr=orlit exc=OPERR | if EN_OPERR goto scs_blk
scs_w2: d=FP[c] a=T0 alu=passa
        d=FP[dst] a=T0 alu=passa fpsr=fpcc ctl=end | goto idle
scs_blk: d=EXOP a=T9 alu=passa | goto done
scs_nan: d=T0 a=T1 b=K[qbit] alu=or | unless SSNAN goto scs_w2
        fpsr=orlit exc=SNAN | if EN_SNAN goto scs_blk
        goto scs_w2

; ============================================================================
; atan (transcend.atan): circular CORDIC, vectoring mode, driving Y to 0.
; |v| below 2^-34: v.  |v| < 1: from (1, |v| 2^s), s = -exponent - 1; else
; from (2^-k, |v| 2^-k), k = exponent + 1, s = 0.  For i = s ... s + 66, by
; Y's sign (DFLAG): X +/-= Y >> (i + s), Z +/-= atan(2^-i) 2^s, Y -/+= X >>
; (i - s); an iteration with Y = 0 moves nothing, so Y reaching 0 ends it.
; In: T2 = v (nonzero).  Out: T11 = Z 2^-s with v's sign.  Four clocks an
; iteration.
; ============================================================================

atan:   d=T5 a=T2 alu=passa                             ; v's sign
        d=T2 a=T2 alu=passa sign=zero                   ; a = |v|
        a=T2 b=K[bm34] mode=exp alu=sub
        d=T11 a=T5 alu=passa | if N goto av_r           ; below 2^-34: v
        a=T2 b=K[bias] mode=exp alu=sub
        alu=nop | unless N goto av_big
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub            ; s
        d=T11 a=T2 b=K[bm1] alu=passb mode=exp | call tofix     ; a 2^s
        d=T7 a=T14 alu=passa dl=1                       ; Y > 0: DFLAG clear
        d=SC a=T2 b=K[bm1] mode=exp alu=rsub
        d=T6 b=K[fx_one] alu=passb | goto av_go         ; X = 1
av_big: d=T11 a=T2 b=K[bm1] alu=passb mode=exp | call tofix     ; a 2^-k in [1/2, 1)
        d=T7 a=T14 alu=passa dl=1
        a=T2 b=K[int63] mode=exp alu=sub               ; k >= 64: X = 0
        d=T6 b=0 alu=passb | unless N goto av_x0
        d=T12 a=T2 b=K[bm1] mode=exp alu=sub lc=alu     ; k
        d=T6 b=K[fx_one]>>LC alu=passb                  ; X = 2^-k
av_x0:  d=SC b=0 alu=passb                              ; s = 0
av_go:  d=T9 b=SC alu=passb lc=alu                      ; i = s
        d=T9 b=0 alu=passb                              ; Z = 0
av_aa:  d=T8 a=T6 b=T7>>>LC+SC alu=addsub dir=dflag lit=34 | if LCEQ goto av_ba2
        d=T9 a=T9 b=K[atan+LC]>>>LC-SC alu=addsub dir=dflag
        d=T7 a=T7 b=T6>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
        alu=nop | if Z goto av_e                        ; Y = 0: the rest moves nothing
av_ab:  d=T6 a=T8 b=T7>>>LC+SC alu=addsub dir=dflag lit=34 | if LCEQ goto av_bb2
        d=T9 a=T9 b=K[atan+LC]>>>LC-SC alu=addsub dir=dflag
        d=T7 a=T7 b=T8>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
        alu=nop | unless Z goto av_aa
        goto av_e
av_ba:  d=T8 a=T6 b=T7>>>LC+SC alu=addsub dir=dflag lit=67 | if LCSCEQ goto av_e
av_ba2: d=T9 a=T9 b=K[fx_one]>>>LC-SC alu=addsub dir=dflag
        d=T7 a=T7 b=T6>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
        alu=nop | if Z goto av_e
av_bb:  d=T6 a=T8 b=T7>>>LC+SC alu=addsub dir=dflag lit=67 | if LCSCEQ goto av_e
av_bb2: d=T9 a=T9 b=K[fx_one]>>>LC-SC alu=addsub dir=dflag
        d=T7 a=T7 b=T8>>>LC-SC alu=subadd dir=dflag dl=1 lc=inc
        alu=nop | unless Z goto av_ba
av_e:   d=T14 a=T9 alu=passa | call fromfix
        d=T11 a=T11 b=SC mode=exp alu=sub
        d=T11 a=T11 b=T5 alu=passa sign=b               ; v's sign
av_r:   ret

; ============================================================================
; FATAN, FASIN, FACOS (fpu.py; transcend.atan, asin, acos): FATAN of an
; infinity is +/-pi/2 computed; FASIN and FACOS outside [-1, 1]: OPERR;
; FACOS(0) = pi/2 computed.  asin = atan(x / sqrt((1 - |x|)(1 + |x|))),
; +/-1 -> +/-pi/2; acos = 2 atan(sqrt((1 - x)/(1 + x))), -1 -> pi, 1 -> +0.
; ============================================================================

.table t_atan STAG
  NAN  nan_m
  ZERO mv_copy
  INF  :: d=T11 a=T1 b=K[halfpi] alu=passb mode=mantb sign=a | goto tr_fin
  default :: d=T2 a=T1 alu=passa osh=norm | goto x_atan
.end
x_atan: alu=nop | call atan
        goto tr_fin

.table t_asin STAG
  NAN  nan_m
  ZERO mv_copy
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm | goto as_dom
.end
as_dom: a=T2 b=K[bias] mode=exp alu=sub                 ; |x| against 1
        alu=nop | if N goto x_asin
        alu=nop | unless Z goto operr
        a=T2 b=K[one] alu=sub
        alu=nop | unless Z goto operr
x_asin: d=T3 a=T2 alu=passa sign=zero                   ; a = |x|
        d=T11 b=K[one] alu=passb mode=mantb sign=b
        d=T12 a=T3 alu=passa | call isub                ; 1 - a
        d=T4 a=T11 alu=passa
        d=T11 b=K[one] alu=passb mode=mantb sign=b
        d=T12 a=T3 alu=passa | call iadd                ; 1 + a
        d=T12 a=T11 alu=passa
        d=T11 a=T4 alu=passa | call imul                ; (1 - a)(1 + a)
        a=T11 alu=passa
        alu=nop | if Z goto as_hp
        alu=nop | call isqrt
        d=T12 a=T11 alu=passa
        d=T11 a=T2 alu=passa | call idiv                ; x / sqrt(d)
        d=T2 a=T11 alu=passa | call atan
        goto tr_fin
as_hp:  d=T11 a=T2 b=K[halfpi] alu=passb mode=mantb sign=a | goto tr_fin

.table t_acos STAG
  NAN  nan_m
  ZERO :: d=T11 b=K[halfpi] alu=passb mode=mantb sign=b | goto tr_fin
  INF  operr
  default :: d=T2 a=T1 alu=passa osh=norm | goto ac_dom
.end
ac_dom: a=T2 b=K[bias] mode=exp alu=sub
        alu=nop | if N goto x_acos
        alu=nop | unless Z goto operr
        a=T2 b=K[one] alu=sub
        alu=nop | unless Z goto operr
x_acos: d=T11 b=K[one] alu=passb mode=mantb sign=b
        d=T12 a=T2 alu=passa | call iadd                ; den = 1 + x
        a=T11 alu=passa
        d=T4 a=T11 alu=passa | if Z goto ac_pi
        d=T11 b=K[one] alu=passb mode=mantb sign=b
        d=T12 a=T2 alu=passa | call isub                ; num = 1 - x
        a=T11 alu=passa
        alu=nop | if Z goto ac_z
        d=T12 a=T4 alu=passa | call idiv
        alu=nop | call isqrt
        d=T2 a=T11 alu=passa | call atan
        d=T11 a=T11 b=K[exp_one] mode=exp alu=add | goto tr_fin    ; 2 atan
ac_pi:  d=T11 b=K[pi] alu=passb mode=mantb sign=b | goto tr_fin
ac_z:   d=T11 b=0 alu=passb sign=zero | goto tr_fin
