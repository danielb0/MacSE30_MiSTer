; t882.uc - Table 8-3's 68882 against the 68881's phases the microcode pads to
; (SE30_PLAN.md 8.9.7, 7e-3): each instruction's clocks adjusted, by operation and
; source class, so that with the table's typical operands (sim/fpu/tb_fpu_timing.v
; +matrix: 3.0 into 2.25; 2.5 for FINT, 0.5 for the inverse functions, 7.25 for
; FMOD and FREM) its head, tail and total are the table's.  N > 0 lengthens (the
; budget starts at N), N < 0 shortens (the elapsed count starts at -N).  The
; classes: a register (reg), memory S, D and X (the same in every row), the integers
; B, W and L (Table 8-3's integer column).  Every other case keeps the 68881's
; difference from the typical one.  Derived 2026-10-01 from the matrix's tails.
;                       reg   S/D/X   B/W/L
; FABS     $18    -2     +1     -5
; FNEG     $1A    -2     +1     -5
; FADD     $22    -2     +1     +1
; FSUB     $28    -2     +1     +1
; FMUL     $23    -2     +1     +1
; FDIV     $20    -7     -4     +1
; FCMP     $38    -8     -5     +5
; FTST     $3A    +2     +5     -5
; FSQRT    $04    -4     -1     -5
; FINT     $01    +2     +5    +17
; FINTRZ   $03    +2     +5    +17
; FGETEXP  $1E    +2     +5     -5
; FGETMAN  $1F    +1     +4     -5
; FSCALE   $26    -2     +1     +1
; FSGLMUL  $27    +4     +7     +7
; FSGLDIV  $24    -5     -2     +7
; FMOD     $21    +3     +6     +6
; FREM     $25   +33    +36    +36
; FSIN     $0E    +2     +5     -5
; FCOS     $1D    +2     +5     -5
; FTAN     $0F    +2     +5     -5
; FATAN    $0A    +2     +5     -5
; FASIN    $0C    +2     +5     -5
; FACOS    $1C    +2     +5     -5
; FATANH   $0D    +2     +5     -5
; FSINH    $02    +2     +5     -5
; FCOSH    $19    +2     +5     -5
; FTANH    $09    +2     +5     -5
; FETOX    $10    +2     +5     -5
; FETOXM1  $08    +2     +5     -5
; FTWOTOX  $11    +2     +5     -5
; FTENTOX  $12    +2     +5     -5
; FLOGN    $14    +2     +5     -5
; FLOGNP1  $06    +2     +5     -5
; FLOG10   $15    +2     +5     -5
; FLOG2    $16    +2     +5     -5
; FSINCOS  $30    +2     +5     -5
; FSINCOS  $31    +2     +5     -5
; FSINCOS  $32    +2     +5     -5
; FSINCOS  $33    +2     +5     -5
; FSINCOS  $34    +2     +5     -5
; FSINCOS  $35    +2     +5     -5
; FSINCOS  $36    +2     +5     -5
; FSINCOS  $37    +2     +5     -5
; FMOVE    $00    +0     +0    -23
.tadj reg $18 -2
.tadj S,D,X $18 1
.tadj B,W,L $18 -5
.tadj reg $1A -2
.tadj S,D,X $1A 1
.tadj B,W,L $1A -5
.tadj reg $22 -2
.tadj S,D,X $22 1
.tadj B,W,L $22 1
.tadj reg $28 -2
.tadj S,D,X $28 1
.tadj B,W,L $28 1
.tadj reg $23 -2
.tadj S,D,X $23 1
.tadj B,W,L $23 1
.tadj reg $20 -7
.tadj S,D,X $20 -4
.tadj B,W,L $20 1
.tadj reg $38 -8
.tadj S,D,X $38 -5
.tadj B,W,L $38 5
.tadj reg $3A 2
.tadj S,D,X $3A 5
.tadj B,W,L $3A -5
.tadj reg $04 -4
.tadj S,D,X $04 -1
.tadj B,W,L $04 -5
.tadj reg $01 2
.tadj S,D,X $01 5
.tadj B,W,L $01 17
.tadj reg $03 2
.tadj S,D,X $03 5
.tadj B,W,L $03 17
.tadj reg $1E 2
.tadj S,D,X $1E 5
.tadj B,W,L $1E -5
.tadj reg $1F 1
.tadj S,D,X $1F 4
.tadj B,W,L $1F -5
.tadj reg $26 -2
.tadj S,D,X $26 1
.tadj B,W,L $26 1
.tadj reg $27 4
.tadj S,D,X $27 7
.tadj B,W,L $27 7
.tadj reg $24 -5
.tadj S,D,X $24 -2
.tadj B,W,L $24 7
.tadj reg $21 3
.tadj S,D,X $21 6
.tadj B,W,L $21 6
.tadj reg $25 33
.tadj S,D,X $25 36
.tadj B,W,L $25 36
.tadj reg $0E 2
.tadj S,D,X $0E 5
.tadj B,W,L $0E -5
.tadj reg $1D 2
.tadj S,D,X $1D 5
.tadj B,W,L $1D -5
.tadj reg $0F 2
.tadj S,D,X $0F 5
.tadj B,W,L $0F -5
.tadj reg $0A 2
.tadj S,D,X $0A 5
.tadj B,W,L $0A -5
.tadj reg $0C 2
.tadj S,D,X $0C 5
.tadj B,W,L $0C -5
.tadj reg $1C 2
.tadj S,D,X $1C 5
.tadj B,W,L $1C -5
.tadj reg $0D 2
.tadj S,D,X $0D 5
.tadj B,W,L $0D -5
.tadj reg $02 2
.tadj S,D,X $02 5
.tadj B,W,L $02 -5
.tadj reg $19 2
.tadj S,D,X $19 5
.tadj B,W,L $19 -5
.tadj reg $09 2
.tadj S,D,X $09 5
.tadj B,W,L $09 -5
.tadj reg $10 2
.tadj S,D,X $10 5
.tadj B,W,L $10 -5
.tadj reg $08 2
.tadj S,D,X $08 5
.tadj B,W,L $08 -5
.tadj reg $11 2
.tadj S,D,X $11 5
.tadj B,W,L $11 -5
.tadj reg $12 2
.tadj S,D,X $12 5
.tadj B,W,L $12 -5
.tadj reg $14 2
.tadj S,D,X $14 5
.tadj B,W,L $14 -5
.tadj reg $06 2
.tadj S,D,X $06 5
.tadj B,W,L $06 -5
.tadj reg $15 2
.tadj S,D,X $15 5
.tadj B,W,L $15 -5
.tadj reg $16 2
.tadj S,D,X $16 5
.tadj B,W,L $16 -5
.tadj reg $30 2
.tadj S,D,X $30 5
.tadj B,W,L $30 -5
.tadj reg $31 2
.tadj S,D,X $31 5
.tadj B,W,L $31 -5
.tadj reg $32 2
.tadj S,D,X $32 5
.tadj B,W,L $32 -5
.tadj reg $33 2
.tadj S,D,X $33 5
.tadj B,W,L $33 -5
.tadj reg $34 2
.tadj S,D,X $34 5
.tadj B,W,L $34 -5
.tadj reg $35 2
.tadj S,D,X $35 5
.tadj B,W,L $35 -5
.tadj reg $36 2
.tadj S,D,X $36 5
.tadj B,W,L $36 -5
.tadj reg $37 2
.tadj S,D,X $37 5
.tadj B,W,L $37 -5
.tadj B,W,L $00 -23
; the APU's own stores and the constant ROM (Table 8-3: FMOVE to memory L 110,
; P 2006; FMOVECR 32), measured the same way
.tadj out.L 28
.tadj out.W 28
.tadj out.B 28
.tadj out.P 26
.tadj cr -4
