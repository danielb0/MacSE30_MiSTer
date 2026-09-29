; The assembler's test program (plan 8.8.18): every construct the
; assembler accepts, in fragments shaped like the real microcode's.  It is
; not the FPU's microcode and nothing checks what it computes.

.export idle
idle:   alu=nop | goto idle                           ; the BIU/CU start an instruction

; -- a dyadic operation: dispatch on the operands' classes (Table 8-14) --
fadd:   fpsr=clrexc | dispatch TAGPAIR fadd_tab

.table fadd_tab TAGPAIR
  NORM NORM   fadd_nn
  NAN  *      nan2
  *    NAN    nan2
  default     special
.end

fadd_nn:
        d=T2 a=T0 b=T1 mode=exp alu=sub               ; Ed - Es
        d=SC a=0 b=T2 mode=exp alu=passb | if N goto fadd_swap
        d=T1 a=0 b=T1>>SC alu=passb mode=mantb sign=b stk=shift
        d=T0 a=T0 b=T1 alu=add
        d=T0 a=0 b=T0<<LZC alu=passb mode=mantb sign=b ; normalise, SC <- LZC
        d=T0 a=T0 b=SC mode=exp alu=sub | call round
        ctl=end fpsr=accrue | goto idle
fadd_swap:
        d=T3 a=T0 alu=passa
        d=T0 a=0 b=T1 alu=passb mode=mantb sign=b
        d=T1 a=T3 alu=passa | goto fadd_nn

nan2:   d=T0 a=0 b=FP[src] alu=passb mode=mantb sign=b    ; one FP register a clock
        d=FP[dst] a=T0 alu=passa fpsr=fpcc | goto finish
special:
        fpsr=orlit exc=OPERR | goto finish
finish: ctl=end fpsr=accrue | goto idle

; -- rounding, a subroutine with a PREC dispatch and a nested call --
round:  alu=nop | dispatch PREC round_tab
.table round_tab PREC
  EXT    round_x
  SGL    round_s
  DBL    round_d
  SGLX   round_x
.end
round_x: d=T0 a=T0 b=RINC alu=add rnd=ext fpsr=inex2r | call range
         ret
round_s: d=T0 a=T0 b=RINC alu=add rnd=sgl fpsr=inex2r | call range
         ret
round_d: d=T0 a=T0 b=RINC alu=add rnd=dbl fpsr=inex2r | call range
         ret
range:   a=T0 b=K[ext_emax] mode=exp alu=sub | if N goto range_ok
         fpsr=orlit exc=OVFL,INEX2
range_ok: d=FP[dst] a=T0 alu=passa fpsr=fpcc | ret

; -- nonrestoring divide: one quotient bit a clock into Q --
fdiv:   d=T4 a=0 b=T1 alu=passb mode=mantb q=clear lc=67
fdiv_loop:
        d=T4 a=T4 b=T5 alu=subadd dir=prevn osh=l1q lc=dec | unless LCZ goto fdiv_loop
        d=T0 a=0 b=Q alu=passb stk=nz | wait 10         ; padded to Table 8-14
        ctl=end fpsr=accrue | goto idle

; -- radix-8 multiply --
fmul:   d=MD a=0 b=T1 alu=passb q=loadb lc=22             ; one literal a word:
        d=MD3 a=T1 b=T1<<1 alu=add                      ; the shift's here
fmul_loop:
        d=T6 a=T6 b=BOOTH alu=addsub dir=booth osh=r3q lc=dec | unless LCZ goto fmul_loop
        ctl=end | goto idle

; -- a CORDIC iteration pair, with a checkpoint where only T0-T10 live --
fsin:   d=T7 a=0 b=K[gain] alu=passb lc=0
        d=T8 a=0 b=0 alu=passb
cordic: d=T9 a=T7 b=T8>>>LC+SC alu=subadd dir=dflag
        d=T8 a=T8 b=T7>>>LC-SC alu=addsub dir=dflag
        d=T10 a=T10 b=K[atan+LC]>>>LC-SC alu=subadd dir=dflag dl=1
        d=T7 a=T9 alu=passa lc=dec ctl=checkpoint | unless LCZ goto cordic
        d=FP[dst] a=T7 alu=passa | wait 100
        ctl=end fpsr=accrue | goto idle

; -- FMOVECR: the ROM word by the command's offset --
fmovecr: d=T0 a=0 b=CMD alu=passb lc=alu
         d=T0 a=0 b=K[fmovecr+LC] alu=passb mode=mantb sign=b | if KABOVE goto cr_above
         d=FP[dst] a=T0 alu=passa rnd=rprec | goto finish
cr_above:
         d=T0 a=T0 b=RINC alu=add rnd=ext | goto finish

; -- a store: the output buffer --
fmove_out:
        d=OBUFX a=FP[src] alu=passa
        d=OBUFH a=FP[src] alu=passa ctl=stored | goto finish

.entry * $22 fadd
.entry * $20 fdiv
.entry * $23 fmul
.entry * $0E fsin
.entry cr fmovecr
.entry out.X fmove_out
.redundant model
.entry default special
