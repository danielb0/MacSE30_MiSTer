#!/usr/bin/env python3
"""The system bench's byte-lane program (KNOWN ISSUES 64: NetBSD's 1-bit
console draws only column 0 - its glyphs are plain MOVE.B stores to the
SE/30's 8-bit video port at every byte offset of a 64-byte scanline).
Stores to VRAM at every A1A0, three ways, and the bench compares the
video module's VRAM array against want.hex at STOP (+LANETEST).

Writes lanetest/program.hex, stop_at.txt, want.hex, lane_count.txt.

THE PROGRAM (supervisor, from $1000, I-cache on as the ROM leaves it)
  three phases, each into its own 2 KB of VRAM at $FE000000 + $800*p:
    p0  data cache OFF (CACR = EI)                 - the old bench's state
    p1  data cache ON (CACR = EI|ED), TT0 = $FE008507: $FExxxxxx cache-
        inhibited, as NetBSD maps the frame buffer (and as the ROM's tables
        make it)
    p2  data cache ON, TT0 cleared: the video cacheable (not a real
        machine's state - a probe of the write path alone)
  in each phase:
    a  256 x MOVE.B D0,(A0)+ with D0 = (i ^ $5A) + p: every A1A0, a ramp
    b  64 x MOVE.L D2,(A0)+ with D2 = $A5C33C5A ^ p: longs, 4 beats each
    c  8 scanline stores: MOVE.B D3,(A0); ADDA.W #64,A0; D3 = $C0+p+k -
       rasops1_putchar8's shape (one byte per scanline, stride 64)
    d  MOVE.B D4,1(A0) / 2(A0) / 3(A0) / 5(A0) / 6(A0) / 7(A0) with D4 =
       $E1.. : explicit odd offsets through d16(An)
  Then STOP.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "lanetest")
ORG = 0x1000
VRAM = 0xFE000000
PHASE = 0x800


def main():
    w = []
    want = {}                                                         # VRAM offset -> byte

    def pc(): return ORG + 2 * len(w)
    def lea_a0(a): w.extend([0x41F9, a >> 16, a & 0xFFFF])             # LEA a,A0
    def movel_imm(reg_code, v): w.extend([0x203C | (reg_code << 9), v >> 16, v & 0xFFFF])  # MOVE.L #v,Dn

    def cacr(v):                                                      # MOVE.L #v,D0; MOVEC D0,CACR
        movel_imm(0, v); w.extend([0x4E7B, 0x0002])

    def tt0(v):                                                       # MOVE.L #v,-(SP); PMOVE (SP),TT0; ADDQ.L #4,SP
        w.extend([0x2F3C, v >> 16, v & 0xFFFF])
        w.extend([0xF017, 0x0800])
        w.extend([0x588F])

    w.extend([0x7001, 0x4E7B, 0x0002])                                # MOVEQ #1,D0; MOVEC D0,CACR: EI
    for p in range(3):
        base = VRAM + PHASE * p
        off = PHASE * p
        if p == 1:
            cacr(0x0101); tt0(0xFE008507)
        if p == 2:
            tt0(0x00000000); cacr(0x0101)
        # a: the byte ramp, 256 stores through every lane
        lea_a0(base)
        w.extend([0x7000])                                            # MOVEQ #0,D0 (counter i in D1, value in D0)
        w.extend([0x7200])                                            # MOVEQ #0,D1
        loop = pc()
        w.extend([0x2001])                                            # MOVE.L D1,D0
        w.extend([0x0A00, 0x005A])                                    # EORI.B #$5A,D0
        w.extend([0x0600, p & 0xFF])                                  # ADDI.B #p,D0
        w.extend([0x10C0])                                            # MOVE.B D0,(A0)+
        w.extend([0x5281])                                            # ADDQ.L #1,D1
        w.extend([0x0C81, 0x0000, 0x0100])                            # CMPI.L #256,D1
        disp = loop - (pc() + 2)
        w.extend([0x6600, disp & 0xFFFF])                             # BNE loop
        for i in range(256):
            want[off + i] = ((i ^ 0x5A) + p) & 0xFF
        # b: 64 longs
        lea_a0(base + 0x100)
        movel_imm(2, 0xA5C33C5A ^ p)
        w.extend([0x323C, 63])                                        # MOVE.W #63,D1
        w.extend([0x20C2, 0x51C9, 0xFFFC])                            # loop: MOVE.L D2,(A0)+; DBRA D1,loop
        v = 0xA5C33C5A ^ p
        for i in range(64):
            for k in range(4):
                want[off + 0x100 + 4 * i + k] = (v >> (24 - 8 * k)) & 0xFF
        # c: scanline stores, stride 64, column 1 (offset 1 of the row)
        lea_a0(base + 0x200 + 1)
        w.extend([0x163C, 0xC0 + p])                                  # MOVE.B #$C0+p,D3
        for k in range(8):
            w.extend([0x1083])                                        # MOVE.B D3,(A0)
            w.extend([0xD0FC, 0x0040])                                # ADDA.W #64,A0
            w.extend([0x5203])                                        # ADDQ.B #1,D3
            want[off + 0x200 + 1 + 64 * k] = (0xC0 + p + k) & 0xFF
        # d: explicit odd offsets through d16(A0)
        lea_a0(base + 0x400)
        for n, d in enumerate((1, 2, 3, 5, 6, 7)):
            w.extend([0x183C, 0xE1 + n + 0x10 * p])                   # MOVE.B #v,D4
            w.extend([0x1144, d])                                     # MOVE.B D4,d(A0)
            want[off + 0x400 + d] = (0xE1 + n + 0x10 * p) & 0xFF
    stop_at = pc()
    w.extend([0x4E72, 0x2700])                                        # STOP #$2700
    mem = [0x4E71] * 65536
    mem[0], mem[1] = 0x0000, 0x0800
    mem[2], mem[3] = 0x0000, ORG
    for i, x in enumerate(w):
        mem[ORG // 2 + i] = x
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "program.hex"), "w", newline="\n") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(OUT, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n%d\n" % (stop_at, len(w)))
    count = PHASE * 3
    with open(os.path.join(OUT, "want.hex"), "w", newline="\n") as f:   # 9-bit entries: $100 = not written, skip
        for a in range(count):
            f.write("%03x\n" % want.get(a, 0x100))
    with open(os.path.join(OUT, "lane_count.txt"), "w", newline="\n") as f:
        f.write("%d\n" % count)
    print("lane program: %d words, STOP at $%X, %d bytes expected" % (len(w), stop_at, len(want)))


if __name__ == "__main__":
    main()
