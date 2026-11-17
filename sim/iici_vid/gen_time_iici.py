#!/usr/bin/env python3
"""The IIci's timing program (SE30_PLAN.md, instruction timings on the
IIci): sim/system's timetest windows that need no SE/30 device - DBRA,
register-only, RAM fill / read / copy, the two branch loops and an indexed
read - run through the IIci machine (the KCLK wrapper, the MDU, the RBV's
video, and the cache card with XCARD + XON).  report_time_iici.py holds
the manual's figure for each.

Each window runs between CLR.L $3000+8w (start) and CLR.L $3004+8w (end);
vid_watch.v (+TT) times it and counts its data cycles and their lengths.
The windows run twice: w and w + 20 (the second pass: with the card, its
reads hit).  The instruction cache on, the data cache off (CACR $0001), as
sim/system's windows 2-17; 1 bit a pixel, so the video takes least.

Writes rom.hex (the ROM's place) and tt_windows.txt (index, turns, name).
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

def w16(*v): return b"".join(struct.pack(">H", x & 0xFFFF) for x in v)
def l32(v): return struct.pack(">I", v & 0xFFFFFFFF)

prog = bytearray()
prog += l32(0x00001000) + l32(0x40800008)                   # SSP, PC
if os.environ.get("DCACHE") == "1":                         # the data cache too, write-allocate, no bursts: ED WA, EI
    prog += w16(0x203C) + l32(0x00002909) + w16(0x4E7B, 0x0002)   # MOVE.L #$2909,D0 ; MOVEC D0,CACR (CD, CI clear first)
else:
    prog += w16(0x7001, 0x4E7B, 0x0002)                     # MOVEQ #1,D0 ; MOVEC D0,CACR (EI)
prog += w16(0x41F9) + l32(0x50F26010) + w16(0x10BC, 0x0000) # LEA $50F26010,A0 ; MOVE.B #0,(A0)  1 bit a pixel
windows = []

def marker(addr): return w16(0x42B9) + l32(addr)           # CLR.L addr

def window(k, turns, name, setup, body):
    """setup: bytes; body: the loop's bytes, ending in DBRA D6 (or its own branch)"""
    global prog
    windows.append((k, turns, name))
    prog += setup
    prog += marker(0x3000 + 8 * k)
    prog += body
    prog += marker(0x3004 + 8 * k)

def dbra(loop_len):                                          # DBRA D6 back to the loop's start
    return w16(0x51CE, -(loop_len + 2))

def all_windows(b):
    window(b + 2, 1000, "DBRA D6 alone", w16(0x3C3C, 999), dbra(0))
    body = w16(0xD481, 0xE58B, 0x2802, 0x9883)               # ADD.L D1,D2 ; LSL.L #2,D3 ; MOVE.L D2,D4 ; SUB.L D3,D4
    window(b + 3, 500, "register-only ADD/LSL/MOVE/SUB/DBRA", w16(0x3C3C, 499), body + dbra(len(body)))
    a0 = w16(0x41F9) + l32(0x00020000)
    a1 = w16(0x43F9) + l32(0x00022000)
    window(b + 4, 500, "RAM fill MOVE.L D0,(A0)+ / DBRA", a0 + w16(0x3C3C, 499), w16(0x20C0) + dbra(2))
    window(b + 5, 500, "RAM read MOVE.L (A0)+,D2 / DBRA", a0 + w16(0x3C3C, 499), w16(0x2418) + dbra(2))
    window(b + 6, 500, "RAM copy MOVE.L (A0)+,(A1)+ / DBRA", a0 + a1 + w16(0x3C3C, 499), w16(0x22D8) + dbra(2))
    # the ROM's BlockMove, its loop for large blocks ($4080C9DC) verbatim: 8 x MOVE.L (A0)+,(A1)+ /
    # SUB.L D2,D0 / BGE.B - each write followed by the next read, nothing to hide its wait states under
    body = w16(0x22D8) * 8 + w16(0x9082)
    window(b + 7, 100, "BlockMove loop 8 x MOVE.L (A0)+,(A1)+ / SUB / BGE", a0 + a1 + w16(0x7420, 0x203C) + l32(32 * 99),
           body + w16(0x6C00 | ((-(len(body) + 2)) & 0xFF)))
    window(b + 15, 500, "SUBQ.W #1,D0 / BNE.B taken", w16(0x303C, 500), w16(0x5340, 0x66FC))
    body = w16(0x4A40, 0x6702, 0x7001)                       # TST.W D0 ; BEQ.B +2 (not taken) ; MOVEQ #1,D0
    window(b + 16, 500, "TST.W / BEQ.B not taken / MOVEQ / DBRA", w16(0x7001, 0x3C3C, 499), body + dbra(len(body)))
    a3 = w16(0x47F9) + l32(0x00020000)
    window(b + 17, 500, "indexed read MOVE.B (A3,D5.W),D1 / DBRA", a3 + w16(0x7A00, 0x3C3C, 499),
           w16(0x1233, 0x5000) + dbra(4))

all_windows(0)
all_windows(20)
prog += w16(0x4E72, 0x2700)                                  # STOP #$2700
prog += w16(0x60FE)

rom = bytearray(524288)
rom[:len(prog)] = prog
with open(os.path.join(HERE, "rom.hex"), "w") as f:
    f.write("".join("%02x%02x\n" % (rom[i], rom[i + 1]) for i in range(0, len(rom), 2)))
with open(os.path.join(HERE, "tt_windows.txt"), "w") as f:
    for k, turns, name in windows:
        f.write("%d %d %s\n" % (k, turns, name))
print("gen_time_iici: %d bytes, %d windows" % (len(prog), len(windows)))
