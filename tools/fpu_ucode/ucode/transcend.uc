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
