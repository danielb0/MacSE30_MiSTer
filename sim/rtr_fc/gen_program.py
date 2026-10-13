#!/usr/bin/env python3
"""The RTR function-code bench's program (SE30_PLAN.md KNOWN ISSUES 19).

Writes `program.hex`, a 64K-word image for tb_rtr_fc.v, hand-assembled
here so nothing in it comes from the kernel.

    vectors   SSP $00008000, PC $00001000
    $1000     supervisor: push $1010 and the CCR word $0004, RTR  - the
              control: a supervisor RTR pops with FC 5 (supervisor data)
    $1010     USP := $6FF8; MOVE #0,SR drops to user mode; RTR - the case:
              a user RTR must pop its CCR word and PC with FC 1 (user
              data), and take only the CCR bits of the stacked word
    $6FF8     the user stack: word $2715 (S, IPL 7 and the CCR $15 - a real
              RTR takes the CCR alone), long $00001100
    $1100     user: MOVE CCR,D0 -> slot $3004; MOVE.L #$4E77 -> slot $3000
              (the bench's end marker); loop
"""
words = {}

def put(addr, *ws):
    for i, w in enumerate(ws):
        words[(addr >> 1) + i] = w & 0xFFFF

put(0x0000, 0x0000, 0x8000, 0x0000, 0x1000)                 # SSP, PC
put(0x1000, 0x2F3C, 0x0000, 0x1010,                          # move.l #$1010,-(a7)
            0x3F3C, 0x0004,                                  # move.w #$0004,-(a7)
            0x4E77,                                          # rtr          (supervisor)
            0x4E71, 0x4E71)                                  # nop, nop
put(0x1010, 0x207C, 0x0000, 0x6FF8,                          # movea.l #$6FF8,a0
            0x4E60,                                          # move.l a0,usp
            0x46FC, 0x0000,                                  # move.w #$0000,sr   -> user mode
            0x4E77,                                          # rtr          (user)
            0x4E71, 0x4E71)
put(0x6FF8, 0x2715, 0x0000, 0x1100)                          # the user stack: CCR word, PC
put(0x1100, 0x42C0,                                          # move.w ccr,d0
            0x33C0, 0x0000, 0x3004,                          # move.w d0,$3004.l
            0x23FC, 0x0000, 0x4E77, 0x0000, 0x3000,          # move.l #$4E77,$3000.l
            0x60FE)                                          # bra.s *

with open('program.hex', 'w') as f:
    for a in sorted(words):
        f.write('@%04x %04x\n' % (a, words[a]))
print('program.hex: %d words' % len(words))
