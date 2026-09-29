; Packed decimal: tools/fpu_model/packed.py - Motorola's FPSP decbin and
; bindec, step for step (plan 8.7.2) - bit for bit (plan 8.8.19).  FPSP's
; floating-point steps are extended precision in the modes it sets, with no
; flags: the quiet operations below round by RMODE (ctl=rm_*) and leave
; FPSR alone; the inexact of the last one is the INEX latch.

; ============================================================================
; ppq: pp without flags, at extended precision, by RMODE (packed.xround):
; T0 (nonzero) normalized and rounded, a tiny result denormalized to
; exponent 0; overflow cannot happen here.  Out: T5; INEX: inexact.
; ============================================================================

ppq:    d=T0 a=T0 alu=passa osh=norm ctl=checkpoint
        d=T3 a=T0 b=RINC alu=add rnd=ext | if TINY goto pq_t
        d=T5 a=T3 b=RMASK alu=and rnd=ext | if C goto pq_c
        ret
pq_c:   d=T5 a=T5 b=K[one] alu=passb
        d=T5 a=T5 b=0 alu=add cin=1 mode=exp | ret
pq_t:   d=SC a=0 b=T0 mode=exp alu=sub                  ; 0 - E
        d=T5 a=T0 b=0 alu=passb mode=exp
        d=T5 a=T5 b=T5>>SC alu=passb stk=shift
        d=T3 a=T5 b=RINC alu=add rnd=ext
        d=T5 a=T3 b=RMASK alu=and rnd=ext | ret

; -- qmul: T11 x T12 (extended words, nonzero), rounded (packed.xmul) --
qmul:   d=T13 a=T11 b=T12 mode=exp alu=add sign=xor stk=clr
        d=T13 a=T13 b=K[bias] mode=exp alu=sub cin=1
        d=T14 b=T12>>3 alu=passb
        d=MD a=T14 alu=passa
        d=MD3 a=T14 b=T14<<1 alu=add
        b=T11>>3 q=loadb
        d=T15 b=0 alu=passb lc=21
qm_l:   d=T15 a=T15 b=BOOTH alu=addsub dir=booth osh=r3q lc=dec | unless LCZ goto qm_l
        d=T14 b=T15<<5 alu=passb
        d=T14 a=T14 b=Q>>62 alu=or
        b=Q<<5 alu=passb stk=nz
        d=T0 a=T13 b=T14 alu=passb | goto ppq

; -- qdiv: T11 / T12 (T12 nonzero), rounded, the remainder the sticky bit
; (packed.xdiv) --
qdiv:   a=T11 alu=passa stk=clr
        d=T13 a=T11 b=T12 mode=exp alu=sub sign=xor lc=66 | if Z goto qd_z
        d=T13 a=T13 b=K[bias] mode=exp alu=add
        d=T14 b=T11>>2 alu=passb q=clear
        d=T15 b=T12>>2 alu=passb
        a=T14 b=T15 alu=sub
        d=T15 b=T12>>2 alu=passb dl=1 | if C goto qd_lo
qd_l:   d=T14 a=T14 b=T15 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto qd_l
        goto qd_st
qd_lo:  d=T13 a=T13 b=K[exp_one] mode=exp alu=sub lc=67
qd_l2:  d=T14 a=T14 b=T15 alu=subadd dir=dflag osh=l1q dl=1 lc=dec | unless LCZ goto qd_l2
qd_st:  d=T12 a=T14 b=T15<<1 alu=add | if DFLAG goto qd_sn
        a=T14 alu=passa stk=nz | goto qd_q
qd_sn:  a=T12 alu=passa stk=nz
qd_q:   d=T0 a=T13 b=Q alu=passb | goto ppq
qd_z:   d=T5 a=T11 b=T12 alu=passa sign=xor
        d=T5 a=T5 b=0 alu=passb mode=exp rnd=ext | ret  ; a signed zero, exact (INEX clear)

; -- qint: FINT of T11 by RMODE (packed.xint): the integer's LSB to bit 3,
; rounded, back; an integer already stays; a zero stays. --
qint:   a=T11 alu=passa stk=clr
        d=T5 a=T11 alu=passa osh=norm | if Z goto qi_r
        d=SC a=T5 b=K[int63] mode=exp alu=rsub
        alu=nop | if N goto qi_r                        ; 2^63 and more: an integer
        d=T3 b=T5>>SC alu=passb sign=b stk=shift
        d=T3 a=T3 b=RINC alu=add rnd=ext
        d=T5 a=T3 b=RMASK alu=and rnd=ext
        d=T5 a=T5 b=K[int63] alu=passb mode=exp | if Z goto qi_z
        d=T5 a=T5 alu=passa osh=norm | ret
qi_z:   d=T5 a=T5 b=0 alu=passb mode=exp | ret           ; a signed zero
qi_r:   a=0 alu=passa rnd=ext | ret                     ; exact (INEX clear)

; ============================================================================
; pow10: T11 = 10^n (n: T6, an integer below 2^13) by binary powering from
; the ROM's powers of ten (FMOVECR $33-$3F), each rounded by RMODE, the
; table the mode's: one unit up in RP where the true value lies above, one
; down in RM (and RZ) where below (packed._ptens_rom, 8.6.14 item 19).
; ============================================================================

pow10:  d=T10 b=K[one] alu=passb mode=mantb sign=b     ; p = 1
        d=T9 b=0 alu=passb                              ; i (T9: qmul uses LC)
pw_l:   a=T6 alu=passa ctl=checkpoint
        a=T6 b=K[ulp] alu=and | if Z goto pw_r          ; n = 0: done
        d=T9 a=T9 alu=passa lc=alu | if Z goto pw_n     ; LC = i; bit 0 clear: skip
        d=T12 b=K[pten+LC] alu=passb mode=mantb sign=b  ; 10^(2^i), the RN image
        alu=nop | if KABOVE goto pw_up
        alu=nop | unless KBELOW goto pw_m
        alu=nop | unless RMRM goto pw_m
        d=T12 a=T12 b=K[ulp8] alu=sub | goto pw_m
pw_up:  alu=nop | unless RMRP goto pw_m
        d=T12 a=T12 b=K[ulp8] alu=add
pw_m:   d=T11 a=T10 alu=passa | call qmul
        d=T10 a=T5 alu=passa
pw_n:   d=T6 b=T6>>1 alu=passb
        d=T9 a=T9 b=K[ulp] alu=add | goto pw_l
pw_r:   d=T11 a=T10 alu=passa | ret

; -- m10a: T0 = T0 x 10 + T14 (integers) --
m10a:   d=T12 b=T0<<3 alu=passb
        d=T0 a=T12 b=T0<<1 alu=add
        d=T0 a=T0 b=T14 alu=add | ret

; -- digits: T0 = T0 x 10^8 + the 8 digits of the longword in T5, most
; significant first (a non-decimal nibble counts as its value, Table 3-4
; note 2) --
digits: alu=nop lc=7
dg_l:   d=T14 b=T5>>28 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a
        d=T5 b=T5<<4 alu=passb lc=dec ctl=checkpoint | unless LCZ goto dg_l
        ret

; ============================================================================
; FMOVE.P and every arithmetic instruction with a packed source (packed.
; decode_in): the image's special forms first - $FFF with SE and YY set is an
; infinity or a NaN whose image is the extended one, an all-zero integer
; digit and fraction a signed zero - else decbin; INEX1 from its last
; multiply or divide.  Then the operation, its operand retagged (ctl=retag:
; the CU cannot classify a packed operand; the APU converts it).
; ============================================================================

pro_p:  alu=nop fpsr=clrexc ctl=rp_ext stk=clr lc=0
        d=T2 b=OPRAW alu=passb lc=1                     ; SM SE YY EXP2..0 EXP3 M16
        d=T3 b=OPRAW alu=passb lc=2                     ; MANT15..8
        d=T4 b=OPRAW alu=passb                          ; MANT7..0
        d=T13 a=T2 b=K[k7fff0000] alu=and
        a=T13 b=K[k7fff0000] alu=sub
        d=T13 a=T2 b=K[k15] alu=and | if Z goto pk_in
        d=T13 a=T13 b=T3 alu=or
        d=T13 a=T13 b=T4 alu=or
        d=T1 b=0 alu=passb sign=zero | if Z goto pk_sg  ; a signed zero
        alu=nop | call decbin
        alu=nop | unless INEX goto pk_go
        fpsr=orlit exc=INEX1 | goto pk_go
pk_in:  d=T13 b=T3<<32 alu=passb                        ; the extended image's mantissa
        d=T13 a=T13 b=T4 alu=or
        d=T1 b=T13<<3 alu=passb
        d=T1 a=T1 b=K[exp_inf] alu=passb mode=exp
pk_sg:  a=T2 b=K[b31] alu=and                           ; SM
        alu=nop | if Z goto pk_go
        d=T1 a=T1 alu=passa sign=one
pk_go:  d=T1 a=T1 alu=passa ctl=retag stk=clr           ; (the conversion's sticky bit is not the operation's)
        d=T0 b=FP[dst] alu=passb mode=mantb sign=b ctl=rp_prec | dispatch TAGPAIR cv_p
; Table 8-13's packed source (8.8.19): a nonzero finite one the typical
; 822 (Daniel's rule, 8.8.16: the figure, or our own time if longer), 26,
; 20 or 18 more by the destination's class; a zero or an infinity 22, a
; NaN 24, and the usual rows.
.table cv_p TAGPAIR
  NORM NORM :: alu=nop budget=0 | goto pk_big
  NORM UNN  :: alu=nop budget=26 | goto pk_big
  NORM ZERO :: alu=nop budget=20 | goto pk_big
  NORM INF  :: alu=nop budget=18 | goto pk_big
  NORM NAN  :: alu=nop budget=20 | goto pk_big
  UNN  NORM :: alu=nop budget=0 | goto pk_big
  UNN  UNN  :: alu=nop budget=26 | goto pk_big
  UNN  ZERO :: alu=nop budget=20 | goto pk_big
  UNN  INF  :: alu=nop budget=18 | goto pk_big
  UNN  NAN  :: alu=nop budget=20 | goto pk_big
  ZERO NORM :: alu=nop budget=22 | goto pk_go3
  ZERO UNN  :: alu=nop budget=34 | goto pk_go3
  ZERO ZERO :: alu=nop budget=28 | goto pk_go3
  ZERO INF  :: alu=nop budget=26 | goto pk_go3
  ZERO NAN  :: alu=nop budget=28 | goto pk_go3
  INF  NORM :: alu=nop budget=22 | goto pk_go3
  INF  UNN  :: alu=nop budget=34 | goto pk_go3
  INF  ZERO :: alu=nop budget=28 | goto pk_go3
  INF  INF  :: alu=nop budget=26 | goto pk_go3
  INF  NAN  :: alu=nop budget=28 | goto pk_go3
  NAN  NORM :: alu=nop budget=24 | goto pk_go3
  NAN  UNN  :: alu=nop budget=36 | goto pk_go3
  NAN  ZERO :: alu=nop budget=30 | goto pk_go3
  NAN  INF  :: alu=nop budget=28 | goto pk_go3
  NAN  NAN  :: alu=nop budget=30 | goto pk_go3
.end
pk_big: alu=nop | budget 822
pk_go3: d=T9 a=T1 alu=passa ctl=rm_fpcr | dispatch OPMODE ops

; ============================================================================
; decbin (packed.decbin, FPSP decbin.sa A1-A5): the exponent from its three
; digits, signed by SE, less 16; the 17 digits as an integer, exact;
; beyond 10^27 zeros appended or stripped toward zero (A3, in RN); 10^|e|
; in the mode RTABLE gives for RND, SM and the exponent's sign (A4); one
; multiply or divide in that mode (A5).  In: T2-T4 the image's longwords.
; Out: T1; INEX the last step's.
; ============================================================================

decbin: d=T0 b=T2>>24 alu=passb
        d=T0 a=T0 b=K[k15] alu=and                    ; EXP2
        d=T14 b=T2>>20 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a
        d=T14 b=T2>>16 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a        ; e (three digits)
        a=T2 b=K[b30] alu=and                           ; SE
        d=T6 a=T0 alu=passa | if Z goto db_1
        d=T6 a=0 b=T0 alu=sub                          ; -e
db_1:   d=T6 a=T6 b=K[k16] alu=sub dl=1                 ; - 16: the 17 digits read as an integer
        d=T8 b=0 alu=passb sign=zero | unless DFLAG goto db_2   ; T8's sign: SE'
        d=T6 a=0 b=T6 alu=sub
        d=T8 b=0 alu=passb sign=one
db_2:   d=T0 a=T2 b=K[k15] alu=and                     ; M16
        d=T5 a=T3 alu=passa | call digits
        d=T5 a=T4 alu=passa | call digits              ; M: 17 digits, below 2^61
        d=T7 b=T0 alu=passb
        d=T7 a=T7 b=K[int_exp] alu=passb mode=exp
        d=T7 a=T7 alu=passa osh=norm                    ; fp0 = M (exact), positive
        a=T2 b=K[b31] alu=and
        alu=nop | if Z goto db_3
        d=T7 a=T7 alu=passa sign=one                    ; SM
; A3: |e| > 27 - zeros appended (SE' clear: the leading zeros) or stripped
db_3:   a=T6 b=K[k27] alu=sub
        alu=nop | if N goto db_4
        alu=nop | if Z goto db_4
        a=T8 alu=passa
        alu=nop | if S goto db_tz
        alu=nop | call leadz                            ; T14 = count
        d=T6 a=T6 b=T14 alu=sub                         ; e - count
        alu=nop | unless N goto db_3m
        d=T6 a=0 b=T6 alu=sub
        d=T8 b=0 alu=passb sign=one
db_3m:  d=T4 a=T6 alu=passa                             ; keep e (T3/T4 are done with)
        d=T6 a=T14 alu=passa ctl=rm_rn | call pow10     ; 10^count, RN
        d=T12 a=T11 alu=passa
        d=T11 a=T7 alu=passa | call qmul
        d=T7 a=T5 alu=passa
        d=T6 a=T4 alu=passa | goto db_4
db_tz:  alu=nop | call trailz
        d=T6 a=T6 b=T14 alu=sub
        alu=nop | if N goto db_tn
        alu=nop | unless Z goto db_3d
db_tn:  d=T6 a=0 b=T6 alu=sub
        d=T8 b=0 alu=passb sign=zero
db_3d:  d=T4 a=T6 alu=passa
        d=T6 a=T14 alu=passa ctl=rm_rn | call pow10
        d=T12 a=T11 alu=passa
        d=T11 a=T7 alu=passa | call qdiv
        d=T7 a=T5 alu=passa
        d=T6 a=T4 alu=passa
; A4: the mode, RTABLE[RND, SM, SE']
db_4:   alu=nop | dispatch RND db_rt
.table db_rt RND
  RN  :: alu=nop ctl=rm_rn | goto db_5
  RZ  db_rz
  RM  db_rm
  RP  db_rp
.end
db_rz:  a=T8 alu=passa
        alu=nop ctl=rm_rm | unless S goto db_5          ; SE' clear: RM
        alu=nop ctl=rm_rp | goto db_5
db_rm:  d=T13 a=T7 b=T8 alu=passa sign=xor
        alu=nop ctl=rm_rm | unless S goto db_5          ; SM = SE': RM
        alu=nop ctl=rm_rp | goto db_5
db_rp:  d=T13 a=T7 b=T8 alu=passa sign=xor
        alu=nop ctl=rm_rp | unless S goto db_5
        alu=nop ctl=rm_rm
; A5: fp0 x or / 10^e in that mode
db_5:   alu=nop | call pow10
        d=T12 a=T11 alu=passa
        a=T8 alu=passa
        d=T11 a=T7 alu=passa | if S goto db_5d
        alu=nop | call qmul
        d=T1 a=T5 alu=passa | ret
db_5d:  alu=nop | call qdiv
        d=T1 a=T5 alu=passa | ret

; -- leadz (packed._lead_zeros): 0 if M16 is not; else 1 + the leading zero
; digits of MANT15..8, or 9 + those of MANT7..0 when MANT15..8 are all
; zero.  Out: T14. --
leadz:  a=T2 b=K[k15] alu=and
        d=T14 b=0 alu=passb | unless Z goto lz_r
        d=T14 b=K[ulp] alu=passb                        ; 1
        a=T3 alu=passa
        d=T13 a=T3 alu=passa | unless Z goto lz_s
        d=T14 a=T14 b=K[ulp8] alu=add                   ; + 8
        d=T13 a=T4 alu=passa
lz_s:   d=T12 b=T13>>28 alu=passb
        a=T12 b=K[k15] alu=and
        alu=nop | unless Z goto lz_r
        d=T14 a=T14 b=K[ulp] alu=add
        d=T13 b=T13<<4 alu=passb | goto lz_s
lz_r:   ret

; -- trailz (packed._trail_zeros): the trailing zero digits of MANT7..0, or
; 8 + those of MANT15..8 when MANT7..0 are all zero.  Out: T14. --
trailz: d=T14 b=0 alu=passb
        a=T4 alu=passa
        d=T13 a=T4 alu=passa | unless Z goto tz_s
        d=T14 b=K[ulp8] alu=passb                       ; 8
        d=T13 a=T3 alu=passa
tz_s:   a=T13 b=K[k15] alu=and
        alu=nop | unless Z goto lz_r
        d=T14 a=T14 b=K[ulp] alu=add
        d=T13 b=T13>>4 alu=passb | goto tz_s

; -- qadd: T11 + T12 (extended words), rounded by RMODE, quiet (packed.xadd):
; FADD's alignment with the sticky bit jammed; an exact zero is +0, -0 in
; RM. --
qadd:   a=T11 alu=passa stk=clr
        a=T12 alu=passa | if Z goto qa_b
        alu=nop | if Z goto qa_a
        d=T11 a=T11 alu=passa osh=norm
        d=T12 a=T12 alu=passa osh=norm
        a=T11 b=T12 mode=exp alu=sub
        alu=nop | unless N goto qa_al
        d=T13 a=T11 alu=passa
        d=T11 a=T12 alu=passa
        d=T12 a=T13 alu=passa
qa_al:  d=SC a=T11 b=T12 mode=exp alu=sub
        d=T12 a=T12 b=T12>>SC alu=passb stk=shift
        alu=nop | unless STK goto qa_sg
        d=T12 a=T12 b=K[ulp] alu=or stk=clr
qa_sg:  a=T11 b=T12 alu=passa sign=xor
        d=T13 a=T11 b=T12 alu=add | if S goto qa_sub
        alu=nop | unless C goto qa_nc
        d=T0 a=T11 b=T12 alu=add osh=r1 stk=shift
        d=T0 a=T0 b=0 alu=add cin=1 mode=exp | goto ppq
qa_nc:  d=T0 a=T13 alu=passa | goto ppq
qa_sub: d=T0 a=T11 b=T12 alu=sub
        alu=nop | unless C goto qa_sn
        d=T0 a=0 b=T0 alu=sub mode=mantb sign=notb | goto ppq
qa_sn:  alu=nop | unless Z goto ppq
        a=0 alu=passa rnd=ext                           ; exact: INEX clear
        d=T5 b=0 alu=passb sign=zero | unless RMRM goto qa_r
        d=T5 b=0 alu=passb sign=one
qa_r:   ret
qa_a:   d=T0 a=T11 alu=passa | goto ppq                 ; x + 0
qa_b:   d=T0 a=T12 alu=passa | goto ppq                 ; 0 + x

; ============================================================================
; FMOVE.P FPm,<ea> (packed.bindec, FPSP bindec.sa A1-A16; fpu.py _to_packed):
; the k-factor static (command bits 6-0) or dynamic (Dn's low 7 bits, sent
; as the operand), two's complement.  A zero, an infinity or a NaN stores
; the register's image (SNAN: made nonsignaling, SNAN; k > 17: OPERR - the
; manual's page, 8.6.14 item 24).  Across the passes: T1 x, T2 |x|
; normalized, T4 k (its sign: ICTR), T7 ILOG, T8 LEN (its sign: x a
; denormal).
; ============================================================================

sp_kd:  alu=nop lc=2
        d=T4 b=OPRAW alu=passb | goto sp_k              ; dynamic: Dn
sp_ks:  d=T4 b=CMD alu=passb                            ; static
sp_k:   d=T4 a=T4 b=K[k127] alu=and
        a=T4 b=K[k64] alu=and
        alu=nop | if Z goto sp_kp
        d=T4 a=T4 b=K[k128] alu=sub                     ; negative
sp_kp:  d=T4 a=T4 alu=passa sign=zero | dispatch STAG t_sp
; Table 8-16: a nonzero finite value the typical 1,942 (Daniel's rule,
; 8.8.16), 14 more with a dynamic k-factor (Table 8-3's note); a zero or
; an infinity 24; a NaN NAN2 (28, an SNAN 30).
.table t_sp STAG
  NAN  :: alu=nop budget=28 | goto sp_sp
  INF  :: alu=nop budget=24 | goto sp_sp
  ZERO :: alu=nop budget=24 | goto sp_sp
  default :: d=T2 a=T1 alu=passa osh=norm sign=zero | goto sp_n
.end
sp_n:   alu=nop | budget 1942
        alu=nop | unless DYNK goto bindec
        alu=nop budget=14 | goto bindec
sp_sp:  d=T5 a=T1 alu=passa
        alu=nop | unless SSNAN goto sp_sk
        alu=nop budget=2
        d=T5 a=T1 b=K[qbit] alu=or fpsr=orlit exc=SNAN
sp_sk:  a=T4 b=K[k17] alu=sub                           ; k > 17: OPERR
        alu=nop | if N goto sp_sw
        alu=nop | if Z goto sp_sw
        fpsr=orlit exc=OPERR
sp_sw:  d=OBUFX a=T5 alu=passa ctl=end | goto idle

; -- p10: T13 = 10^LC (an integer, LC <= 18) --
p10:    d=T13 b=K[ulp] alu=passb
p10_l:  alu=nop | if LCZ goto p10_r
        d=T12 b=T13<<3 alu=passb
        d=T13 a=T12 b=T13<<1 alu=add lc=dec | goto p10_l
p10_r:  ret

; -- xint: T11 = the non-negative integer in T13 as an extended word --
xint:   a=T13 alu=passa
        d=T11 b=T13 alu=passb sign=zero | if Z goto xi_z
        d=T11 a=T11 b=K[int_exp] alu=passb mode=exp
        d=T11 a=T11 alu=passa osh=norm | ret
xi_z:   d=T11 a=T11 b=0 alu=passb mode=exp | ret

; -- toint: T13 = |T11| as an integer (an integral value below 2^66) --
toint:  d=SC a=T11 b=K[int_exp] mode=exp alu=rsub
        d=T13 b=T11>>SC alu=passb | ret

; A1-A3: a denormal (normalized biased exponent 0 or less: ILOG = -4933);
; else ILOG = floor(log10 |x|) = floor((1.f + E - 1) log10 2), in RM.
bindec: d=T8 b=0 alu=passb sign=zero
        a=T2 b=K[exp_one] mode=exp alu=sub
        alu=nop | unless N goto bd_a3
        d=T8 b=0 alu=passb sign=one
        d=T7 a=0 b=K[k4933] alu=sub | goto bd_6
bd_a3:  d=T13 a=T2 b=K[bias] mode=exp alu=sub ctl=rm_rm ; E
        d=T13 b=T13 bx=e2m alu=passb
        a=T13 alu=passa
        alu=nop | unless N goto bd_ep
        d=T13 a=0 b=T13 alu=sub | call xint              ; |E|
        d=T12 a=T11 alu=passa sign=one | goto bd_e1      ; -|E|
bd_ep:  alu=nop | call xint
        d=T12 a=T11 alu=passa
bd_e1:  d=T11 a=T2 b=K[bias] alu=passb mode=exp | call qadd     ; 1.f + E
        d=T11 a=T5 alu=passa
        d=T12 b=K[one] alu=passb mode=mantb sign=one | call qadd  ; - 1
        a=T5 alu=passa
        d=T11 a=T5 alu=passa | if Z goto bd_iz
        d=T12 b=K[log2dn] alu=passb mode=mantb sign=b | unless S goto bd_lm
        d=T12 b=K[log2up] alu=passb mode=mantb sign=b
bd_lm:  alu=nop | call qmul
        d=T11 a=T5 alu=passa | call floorint            ; T7 = ILOG
        goto bd_6
bd_iz:  d=T7 b=0 alu=passb
; A6: LEN = k (k > 0), else ILOG + 1 - k; at least 1, at most 17 (k > 0 and
; above 17: OPERR)
bd_6:   a=T4 alu=passa ctl=checkpoint
        alu=nop | if N goto bd_6n
        alu=nop | if Z goto bd_6n
        d=T8 a=T8 b=T4 alu=passb | goto bd_6c           ; (T8's sign kept)
bd_6n:  d=T13 a=T7 b=T4 alu=sub
        d=T8 a=T8 b=T13 alu=passb
        d=T8 a=T8 b=K[ulp] alu=add
bd_6c:  a=T8 alu=passa
        alu=nop | if N goto bd_6one
        alu=nop | if Z goto bd_6one
        a=T8 b=K[k17] alu=sub
        alu=nop | if N goto bd_7
        alu=nop | if Z goto bd_7
        d=T8 a=T8 b=K[k17] alu=passb                    ; 17
        a=T4 alu=passa
        alu=nop | if N goto bd_7
        alu=nop | if Z goto bd_7
        fpsr=orlit exc=OPERR | goto bd_7
bd_6one: d=T8 a=T8 b=K[ulp] alu=passb                   ; 1
; A7: k <= 0 and k >= ILOG: ILOG = k.  ISCALE = ILOG + 1 - LEN; LAMBDA its
; sign; at -4908 or below, 24 added (10^8 x 10^16 applied to X instead).
bd_7:   a=T4 alu=passa
        alu=nop | if N goto bd_7k
        alu=nop | unless Z goto bd_7s
bd_7k:  a=T4 b=T7 alu=sub                               ; k - ILOG
        alu=nop | if N goto bd_7s
        d=T7 a=T4 alu=passa sign=zero                   ; ILOG = k
bd_7s:  alu=nop | call iscale                           ; T6 = |ISCALE|; DFLAG: LAMBDA
        alu=nop | dispatch RND bd_rb
; the mode, RBDTBL[RND, LAMBDA, sigma]
.table bd_rb RND
  RN  :: alu=nop ctl=rm_rn | goto bd_89
  RZ  bd_rz
  RM  bd_rm
  RP  bd_rp
.end
bd_rz:  alu=nop ctl=rm_rp | unless DFLAG goto bd_89     ; RP, or RM when LAMBDA
        alu=nop ctl=rm_rm | goto bd_89
bd_rm:  alu=nop | if DFLAG goto bd_rm1
        alu=nop ctl=rm_rp | unless SNEG goto bd_89      ; L = sigma: RP
        alu=nop ctl=rm_rm | goto bd_89
bd_rm1: alu=nop ctl=rm_rp | if SNEG goto bd_89
        alu=nop ctl=rm_rm | goto bd_89
bd_rp:  alu=nop | if DFLAG goto bd_rp1
        alu=nop ctl=rm_rm | unless SNEG goto bd_89      ; L = sigma: RM
        alu=nop ctl=rm_rp | goto bd_89
bd_rp1: alu=nop ctl=rm_rm | if SNEG goto bd_89
        alu=nop ctl=rm_rp
; A7 (SCALE = 10^|ISCALE| in that mode), A8-A9 (in RZ): Y = X / SCALE, or X
; x SCALE (x 10^8 x 10^16 first when 24 was added; after, for a denormal).
bd_89:  alu=nop | call pow10                            ; T11 = SCALE
        d=T10 a=T11 alu=passa ctl=rm_rz
        alu=nop | call iscale                           ; LAMBDA again (pow10 used T6, DFLAG)
        alu=nop | if DFLAG goto bd_9
        d=T11 a=T2 alu=passa
        d=T12 a=T10 alu=passa | call qdiv               ; X / SCALE
        goto bd_10
bd_9:   a=T8 alu=passa
        alu=nop | if S goto bd_9d
        a=T13 alu=passa                                 ; iscale left T13: 24 added?
        d=T5 a=T2 alu=passa | if Z goto bd_9m
        d=T11 a=T2 alu=passa
        d=T12 b=K[pten+3] alu=passb mode=mantb sign=b | call qmul
        d=T11 a=T5 alu=passa
        d=T12 b=K[pten+4] alu=passb mode=mantb sign=b | call qmul
bd_9m:  d=T11 a=T5 alu=passa
        d=T12 a=T10 alu=passa | call qmul               ; x SCALE
        goto bd_10
bd_9d:  d=T11 a=T2 alu=passa
        d=T12 a=T10 alu=passa | call qmul               ; the denormal: x SCALE, then x 10^8 x 10^16
        d=T11 a=T5 alu=passa
        d=T12 b=K[pten+3] alu=passb mode=mantb sign=b | call qmul
        d=T11 a=T5 alu=passa
        d=T12 b=K[pten+4] alu=passb mode=mantb sign=b | call qmul
; A10: an inexact scaling ORs a one into Y's LSB.  A11-A12: YINT = FINT(Y
; with x's sign) in the user's mode - its INEX2 is the instruction's.
bd_10:  alu=nop | unless INEX goto bd_11
        d=T5 a=T5 b=K[ulp8] alu=or
bd_11:  d=T11 a=T5 b=T1 alu=passa sign=b ctl=rm_fpcr | call qint
        alu=nop | unless INEX goto bd_12
        fpsr=orlit exc=INEX2
bd_12:  d=T11 a=T5 alu=passa | call toint               ; a = |YINT|
        d=T9 a=T13 alu=passa ctl=checkpoint  ; (T9: a)
; A13: LEN digits?
        a=T4 alu=passa
        alu=nop | if S goto bd_13b                      ; the second pass
        a=T8 alu=passa
        alu=nop | if S goto bd_13u                      ; a denormal skips the low test
        d=T13 a=T8 b=K[ulp] alu=sub lc=alu
        alu=nop | call p10                              ; 10^(LEN-1)
        a=T9 b=T13 alu=sub ctl=checkpoint
        alu=nop | unless C goto bd_13u
        d=T7 a=T7 b=K[ulp] alu=sub | goto bd_again     ; a < 10^(LEN-1): ILOG - 1
bd_13u: d=T13 a=T8 alu=passa lc=alu ctl=checkpoint
        alu=nop | call p10                              ; 10^LEN
        a=T13 b=T9 alu=sub
        alu=nop | unless C goto bd_13e
        d=T7 a=T7 b=K[ulp] alu=add | goto bd_again      ; a > 10^LEN: ILOG + 1
bd_13e: alu=nop | unless Z goto bd_14
        d=T7 a=T7 b=K[ulp] alu=add
        d=T13 a=T8 b=K[ulp] alu=sub lc=alu | call p10
        d=T9 a=T13 alu=passa ctl=checkpoint  ; a = 10^(LEN-1)
        d=T13 a=T8 alu=passa lc=alu | call p10
        goto bd_14
bd_again: d=T4 a=T4 alu=passa sign=one | goto bd_6      ; ICTR = 1, again
bd_13b: d=T13 a=T8 alu=passa lc=alu | call p10          ; P = 10^LEN
        a=T9 b=T13 alu=sub
        alu=nop | unless Z goto bd_14
        d=T13 a=T8 b=K[ulp] alu=sub lc=alu | call p10   ; a = P: a / 10, ILOG + 1, LEN + 1, P x 10
        d=T9 a=T13 alu=passa ctl=checkpoint
        d=T7 a=T7 b=K[ulp] alu=add
        d=T8 a=T8 b=K[ulp] alu=add
        d=T13 a=T8 alu=passa lc=alu | call p10
; A14: |YINT| / P in RZ as a binary fraction, rounded at bit 7, then LEN
; digits.  T13 = P here.
bd_14:  d=T0 a=T13 alu=passa ctl=checkpoint              ; (parked for a busy frame)
        d=T13 a=T0 alu=passa | call xint
        d=T10 a=T11 alu=passa                           ; P as extended
        d=T13 a=T9 alu=passa | call xint                ; a
        d=T12 a=T10 alu=passa ctl=rm_rz | call qdiv     ; F
        d=T11 a=T5 alu=passa | call frac57              ; T14: the fraction >> 7 (57 bits), rounded
        d=T3 a=T14 alu=passa
        d=T6 b=0 alu=passb                              ; the low 64 bits' digits
        alu=nop | call digit                            ; M16 (LEN >= 1)
        d=T2 a=T14 alu=passa                            ; M16 (T2: |x| is done with)
        d=T0 a=T8 b=K[ulp] alu=sub lc=15                ; 16 more places, LEN - 1 of them digits (T0: a busy frame holds it)
bd_d:   d=T6 b=T6<<4 alu=passb
        a=T0 alu=passa
        alu=nop | if Z goto bd_dz
        d=T0 a=T0 b=K[ulp] alu=sub | call digit
        d=T6 a=T6 b=T14 alu=or
bd_dz:  alu=nop lc=dec ctl=checkpoint | unless LCZ goto bd_d
        goto bd_15

; A15: the exponent's four digits, |ILOG| (a zero fraction: 1; a denormal's
; zero fraction: |ILOG| when k < 0, else 4933) / 10^4 by the same route; a
; thousands digit: OPERR.  A16: the image.
bd_15:  d=T13 a=T7 alu=passa
        alu=nop | unless N goto bd_15a
        d=T13 a=0 b=T7 alu=sub                          ; |ILOG|
bd_15a: a=T5 alu=passa
        alu=nop | unless Z goto bd_15e                  ; F nonzero: |ILOG|
        a=T8 alu=passa
        alu=nop | if S goto bd_15d
        d=T13 b=K[ulp] alu=passb | goto bd_15e          ; 1
bd_15d: a=T4 alu=passa
        alu=nop | if N goto bd_15e                      ; k < 0: |ILOG|
        d=T13 b=K[k4933] alu=passb
bd_15e: d=T3 b=0 alu=passb                              ; (no exponent: all four digits 0)
        a=T13 alu=passa
        alu=nop | if Z goto bd_16
        alu=nop | call xint                             ; expo
        d=T10 a=T11 alu=passa
        d=T13 b=K[k10000] alu=passb | call xint
        d=T12 a=T11 alu=passa
        d=T11 a=T10 alu=passa | call qdiv               ; expo / 10^4, RZ
        d=T11 a=T5 alu=passa | call frac57
        d=T3 a=T14 alu=passa
bd_16:  d=T15 b=0 alu=passb                             ; the high longword
        alu=nop | unless SNEG goto bd_16s
        d=T15 b=K[b31] alu=passb                        ; SM
bd_16s: a=T7 alu=passa
        alu=nop | unless N goto bd_16e
        d=T15 a=T15 b=K[b30] alu=or                     ; SE: ILOG < 0
bd_16e: alu=nop | call digit                            ; thousands
        d=T12 b=T14<<12 alu=passb
        d=T15 a=T15 b=T12 alu=or
        a=T14 alu=passa
        alu=nop | if Z goto bd_16h
        fpsr=orlit exc=OPERR
bd_16h: alu=nop | call digit                            ; hundreds
        d=T12 b=T14<<24 alu=passb
        d=T15 a=T15 b=T12 alu=or | call digit           ; tens
        d=T12 b=T14<<20 alu=passb
        d=T15 a=T15 b=T12 alu=or | call digit           ; units
        d=T12 b=T14<<16 alu=passb
        d=T15 a=T15 b=T12 alu=or
        d=T15 a=T15 b=T2 alu=or                         ; M16
        d=T15 b=T15<<35 alu=passb
        d=OBUFH a=T15 alu=passa
        d=T6 b=T6<<3 alu=passb
        d=OBUFL a=T6 alu=passa ctl=end | goto idle

; -- iscale: T6 = |ISCALE|, ISCALE = ILOG + 1 - LEN, 24 added at -4908 and
; below (T13 nonzero then); DFLAG: LAMBDA (ISCALE < 0) --
iscale: d=T6 a=T7 b=T8 alu=sub
        d=T6 a=T6 b=K[ulp] alu=add dl=1
        d=T13 b=0 alu=passb
        alu=nop | unless DFLAG goto is_r
        a=T6 b=K[k4908] alu=add                         ; ISCALE + 4908 <= 0?
        alu=nop | if N goto is_24
        alu=nop | unless Z goto is_n
is_24:  d=T6 a=T6 b=K[k24] alu=add
        d=T13 b=K[ulp] alu=passb
is_n:   d=T6 a=0 b=T6 alu=sub
is_r:   ret

; -- frac57: T14 = the fraction binstr takes, from the extended value in T11
; below 1 (packed._fraction64, then A14's rounding at bit 7), shifted right
; 7 places: 57 bits, so ten times it fits --
frac57: a=T11 alu=passa
        d=T14 b=0 alu=passb | if Z goto f57_r
        d=SC a=T11 b=K[bias2] mode=exp alu=rsub         ; the binary point left of bit 63
        d=T14 b=T11>>SC alu=passb
        a=T14 alu=passa
        alu=nop | if Z goto f57_r
        d=T14 a=T14 b=K[k128] alu=add                   ; + $80
        d=T14 b=T14>>7 alu=passb
        d=T14 a=T14 b=K[m57] alu=and                    ; (mod 2^64)
f57_r:  ret

; -- digit: T14 = the next decimal digit of the fraction in T3 (binstr: the
; integer part of ten times it) --
digit:  d=T12 b=T3<<3 alu=passb
        d=T3 a=T12 b=T3<<1 alu=add
        d=T14 b=T3>>57 alu=passb
        d=T3 a=T3 b=K[m57] alu=and | ret
