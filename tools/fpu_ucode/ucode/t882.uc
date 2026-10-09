; t882.uc - Table 8-3's 68882 against the 68881's phases the microcode pads to
; each instruction's clocks adjusted, by operation and
; source class, so that with the table's typical operands (the timing
; bench's matrix: 3.0 into 2.25; 2.5 for FINT, 0.5 for the inverse functions, 7.25 for
; FMOD and FREM; the MPU reading the response at once, UM 8.4) its head, tail and
; total are the table's.  N < 0 starts the APU's elapsed count at -N; N > 0 is
; added at END to whichever ends the instruction, its path or its budget.  The
; classes: a register (reg), memory S, D and X (the same in every row), the
; integers B, W and L, packed P.  Every other case keeps the 68881's difference from the
; typical one.  Written by t882cal.py from a matrix; the cr and out.F lines by hand.
;
;            reg   S/D/X   B/W/L      P
; FABS        +1     +4     -1    +33
; FNEG        +1     +4     -1    +33
; FADD        +0     +3     +1    +27
; FSUB        +0     +3     +1    +27
; FMUL        +0     +3     +1    +27
; FDIV        +0     +3     +1    +27
; FCMP        +0     +3     +5    +31
; FTST        +4     +7     -1    +33
; FSQRT       +0     +3     -1    +33
; FINT        +4     +7    +21    +33
; FINTRZ      +4     +7    +21    +33
; FGETEXP     +4     +7     -1    +33
; FGETMAN     +3     +6     -1    +33
; FSCALE      +0     +3     +1    +27
; FSGLMUL     +6     +9     +7    +33
; FSGLDIV     +0     +3     +7    +33
; FMOD        +5     +8     +6    +32
; FREM       +35    +38    +36    +62
; FSIN        +4     +7     -1    +33
; FCOS        +4     +7     -1    +33
; FTAN        +4     +7     -1    +33
; FSINCOS     +4     +7     -1    +33
; FATAN       +4     +7     -1    +33
; FASIN       +4     +7     -1    +33
; FACOS       +4     +7     -1    +33
; FATANH      +4     +7     -1    +33
; FSINH       +4     +7     -1    +33
; FCOSH       +4     +7     -1    +33
; FTANH       +4     +7     -1    +33
; FETOX       +4     +7     -1    +33
; FETOXM1     +4     +7     -1    +33
; FTWOTOX     +4     +7     -1    +33
; FTENTOX     +4     +7     -1    +33
; FLOGN       +4     +7     -1    +33
; FLOGNP1     +4     +7     -1    +33
; FLOG10      +4     +7     -1    +33
; FLOG2       +4     +7     -1    +33
; FMOVE       +0     +0    -19    +33
.tadj reg $18 1
.tadj S,D,X $18 4
.tadj B,W,L $18 -1
.tadj P $18 33
.tadj reg $1A 1
.tadj S,D,X $1A 4
.tadj B,W,L $1A -1
.tadj P $1A 33
.tadj S,D,X $22 3
.tadj B,W,L $22 1
.tadj P $22 27
.tadj S,D,X $28 3
.tadj B,W,L $28 1
.tadj P $28 27
.tadj S,D,X $23 3
.tadj B,W,L $23 1
.tadj P $23 27
.tadj S,D,X $20 3
.tadj B,W,L $20 1
.tadj P $20 27
.tadj S,D,X $38 3
.tadj B,W,L $38 5
.tadj P $38 31
.tadj reg $3A 4
.tadj S,D,X $3A 7
.tadj B,W,L $3A -1
.tadj P $3A 33
.tadj S,D,X $04 3
.tadj B,W,L $04 -1
.tadj P $04 33
.tadj reg $01 4
.tadj S,D,X $01 7
.tadj B,W,L $01 21
.tadj P $01 33
.tadj reg $03 4
.tadj S,D,X $03 7
.tadj B,W,L $03 21
.tadj P $03 33
.tadj reg $1E 4
.tadj S,D,X $1E 7
.tadj B,W,L $1E -1
.tadj P $1E 33
.tadj reg $1F 3
.tadj S,D,X $1F 6
.tadj B,W,L $1F -1
.tadj P $1F 33
.tadj S,D,X $26 3
.tadj B,W,L $26 1
.tadj P $26 27
.tadj reg $27 6
.tadj S,D,X $27 9
.tadj B,W,L $27 7
.tadj P $27 33
.tadj S,D,X $24 3
.tadj B,W,L $24 7
.tadj P $24 33
.tadj reg $21 5
.tadj S,D,X $21 8
.tadj B,W,L $21 6
.tadj P $21 32
.tadj reg $25 35
.tadj S,D,X $25 38
.tadj B,W,L $25 36
.tadj P $25 62
.tadj reg $0E 4
.tadj S,D,X $0E 7
.tadj B,W,L $0E -1
.tadj P $0E 33
.tadj reg $1D 4
.tadj S,D,X $1D 7
.tadj B,W,L $1D -1
.tadj P $1D 33
.tadj reg $0F 4
.tadj S,D,X $0F 7
.tadj B,W,L $0F -1
.tadj P $0F 33
.tadj reg $30 4
.tadj S,D,X $30 7
.tadj B,W,L $30 -1
.tadj P $30 33
.tadj reg $31 4
.tadj S,D,X $31 7
.tadj B,W,L $31 -1
.tadj P $31 33
.tadj reg $32 4
.tadj S,D,X $32 7
.tadj B,W,L $32 -1
.tadj P $32 33
.tadj reg $33 4
.tadj S,D,X $33 7
.tadj B,W,L $33 -1
.tadj P $33 33
.tadj reg $34 4
.tadj S,D,X $34 7
.tadj B,W,L $34 -1
.tadj P $34 33
.tadj reg $35 4
.tadj S,D,X $35 7
.tadj B,W,L $35 -1
.tadj P $35 33
.tadj reg $36 4
.tadj S,D,X $36 7
.tadj B,W,L $36 -1
.tadj P $36 33
.tadj reg $37 4
.tadj S,D,X $37 7
.tadj B,W,L $37 -1
.tadj P $37 33
.tadj reg $0A 4
.tadj S,D,X $0A 7
.tadj B,W,L $0A -1
.tadj P $0A 33
.tadj reg $0C 4
.tadj S,D,X $0C 7
.tadj B,W,L $0C -1
.tadj P $0C 33
.tadj reg $1C 4
.tadj S,D,X $1C 7
.tadj B,W,L $1C -1
.tadj P $1C 33
.tadj reg $0D 4
.tadj S,D,X $0D 7
.tadj B,W,L $0D -1
.tadj P $0D 33
.tadj reg $02 4
.tadj S,D,X $02 7
.tadj B,W,L $02 -1
.tadj P $02 33
.tadj reg $19 4
.tadj S,D,X $19 7
.tadj B,W,L $19 -1
.tadj P $19 33
.tadj reg $09 4
.tadj S,D,X $09 7
.tadj B,W,L $09 -1
.tadj P $09 33
.tadj reg $10 4
.tadj S,D,X $10 7
.tadj B,W,L $10 -1
.tadj P $10 33
.tadj reg $08 4
.tadj S,D,X $08 7
.tadj B,W,L $08 -1
.tadj P $08 33
.tadj reg $11 4
.tadj S,D,X $11 7
.tadj B,W,L $11 -1
.tadj P $11 33
.tadj reg $12 4
.tadj S,D,X $12 7
.tadj B,W,L $12 -1
.tadj P $12 33
.tadj reg $14 4
.tadj S,D,X $14 7
.tadj B,W,L $14 -1
.tadj P $14 33
.tadj reg $06 4
.tadj S,D,X $06 7
.tadj B,W,L $06 -1
.tadj P $06 33
.tadj reg $15 4
.tadj S,D,X $15 7
.tadj B,W,L $15 -1
.tadj P $15 33
.tadj reg $16 4
.tadj S,D,X $16 7
.tadj B,W,L $16 -1
.tadj P $16 33
.tadj B,W,L $00 -19
.tadj P $00 33
; the APU's own stores and the constant ROM (Table 8-3: FMOVE to memory L 110,
; P 2006; FMOVECR 32), measured the same way
.tadj out.L 29
.tadj out.W 29
.tadj out.B 29
.tadj out.P 25
.tadj cr -6
