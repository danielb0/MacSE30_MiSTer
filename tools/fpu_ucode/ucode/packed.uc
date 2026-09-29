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

ppq:    d=T0 a=T0 alu=passa osh=norm
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
pw_l:   a=T6 alu=passa
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

; -- m10a: T15 = T15 x 10 + T14 (integers) --
m10a:   d=T12 b=T15<<3 alu=passb
        d=T15 a=T12 b=T15<<1 alu=add
        d=T15 a=T15 b=T14 alu=add | ret

; -- digits: T15 = T15 x 10^8 + the 8 digits of the longword in T13, most
; significant first (a non-decimal nibble counts as its value, Table 3-4
; note 2) --
digits: alu=nop lc=7
dg_l:   d=T14 b=T13>>28 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a
        d=T13 b=T13<<4 alu=passb lc=dec | unless LCZ goto dg_l
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
        d=T0 b=FP[dst] alu=passb mode=mantb sign=b ctl=rp_prec
        d=T9 a=T1 alu=passa ctl=rm_fpcr | dispatch OPMODE ops

; ============================================================================
; decbin (packed.decbin, FPSP decbin.sa A1-A5): the exponent from its three
; digits, signed by SE, less 16; the 17 digits as an integer, exact;
; beyond 10^27 zeros appended or stripped toward zero (A3, in RN); 10^|e|
; in the mode RTABLE gives for RND, SM and the exponent's sign (A4); one
; multiply or divide in that mode (A5).  In: T2-T4 the image's longwords.
; Out: T1; INEX the last step's.
; ============================================================================

decbin: d=T15 b=T2>>24 alu=passb
        d=T15 a=T15 b=K[k15] alu=and                    ; EXP2
        d=T14 b=T2>>20 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a
        d=T14 b=T2>>16 alu=passb
        d=T14 a=T14 b=K[k15] alu=and | call m10a        ; e (three digits)
        a=T2 b=K[b30] alu=and                           ; SE
        d=T6 a=T15 alu=passa | if Z goto db_1
        d=T6 a=0 b=T15 alu=sub                          ; -e
db_1:   d=T6 a=T6 b=K[k16] alu=sub dl=1                 ; - 16: the 17 digits read as an integer
        d=T8 b=0 alu=passb sign=zero | unless DFLAG goto db_2   ; T8's sign: SE'
        d=T6 a=0 b=T6 alu=sub
        d=T8 b=0 alu=passb sign=one
db_2:   d=T15 a=T2 b=K[k15] alu=and                     ; M16
        d=T13 a=T3 alu=passa | call digits
        d=T13 a=T4 alu=passa | call digits              ; M: 17 digits, below 2^61
        d=T7 b=T15 alu=passb
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
