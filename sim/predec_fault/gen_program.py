#!/usr/bin/env python3
"""The predec_fault bench's program (tb_predec_fault.v's header; SE30_PLAN.md
KNOWN ISSUES 20): the ROM's BlockMove loop, MOVE.L -(A0),-(A1), page-faulting
mid-instruction through the PMMU, resumed by a handler that does what A/UX's
pager does.

THE PROGRAM (supervisor, from $1000)
    CACR from the CACR environment variable (default 0: caches off)
    PMOVE (A0),CRP / PMOVE (A0),TC: TC $80C84800 (E, PS 4 KB, IS 8, TIA 4,
      TIB 8); table A at $4000 (entry 0 -> table B at $4100, short format),
      table B: 256 page descriptors, identity, valid, U and M clear (the
      walker sets them, UM 9.5.3 - A/UX's pages start that way too)
    USP $9000
    each case (CASES): the case's pages made invalid (DT 0) and PFLUSHA;
      A0/A1 = the source and destination ends, D0 = the byte count;
      MOVE #0,SR (user mode, as the Mac environment runs); the ROM's code
      at $4080EFFE-$4080F01F byte for byte (MOVE.L D0,D1; LSR.L #5,D1; the
      8 x MOVE.L -(A0),-(A1) loop under two DBRAs); TRAP #0 back to
      supervisor; A0, A1, D1, the count of destination longs that differ
      from the source, and the handler count to the case's slots
    STOP #$2700
    vector 2 (bus error), $1C00: count the entry ($3100), log the fault
      address, SSW and format word ($3200 on), make the faulting page's
      descriptor valid, PFLUSHA, RTE with the frame untouched (DF set: the
      faulted cycle reruns, UM 8.2.1) - more than 100 entries = a loop:
      stop at $1D80
    TRAP #0 (vector 32), $1D00: drop its frame, JMP (A5) (the case's
      continuation)
    any other exception, $1E00: its format/vector word and PC to $3F00, stop

Writes program.hex (512 KB as 16-bit words), stop_at.txt ({STOP address}),
expect.txt ({slot} {value} {what} per line) and rom.hex is not needed: the
loop is copied out of the ROM image here.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROM", "C:/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM")
CACR = int(os.environ.get("CACR", "0"), 0)
ORG, BERR, TRAP0, LOOPSTOP, EXC = 0x1000, 0x1C00, 0x1D00, 0x1D80, 0x1E00
TBL_A, TBL_B, CRP_AT = 0x4000, 0x4100, 0x3E00
TC = 0x80C84800
SLOTS, COUNT, LOGP, LOG = 0x3000, 0x3100, 0x3104, 0x3200
SIZE = 0x80000                                   # the image: 512 KB

# (source start, destination start, bytes, invalid pages, what)
CASES = [
    (0x20000, 0x30000, 0x2000, [0x30000, 0x31000], "destination pages invalid: the writes fault (LASTWRITE replay)"),
    (0x24000, 0x34000, 0x2000, [0x24000, 0x25000], "source pages invalid: the reads fault (rollback, re-execute)"),
    (0x28000, 0x38000, 0x2000, [0x28000, 0x29000, 0x38000, 0x39000], "both invalid: a read fault, then a write fault, in one instruction"),
    (0x2C800, 0x3C000, 0x2000, [0x2C000, 0x2D000, 0x2E000, 0x3C000, 0x3D000], "source misaligned to the pages: the faults land mid-loop"),
]


def main():
    rom = open(ROM, "rb").read()
    assert len(rom) == 262144 and rom[0:4] == bytes.fromhex("97221136"), "not the 97221136 ROM"
    blockmove = rom[0xEFFE:0xF020]                  # MOVE.L D0,D1 ... the second DBRA
    assert blockmove[:6] == bytes.fromhex("2200EA896012") and blockmove[-4:] == bytes.fromhex("51C9FFE6")
    loop = [int.from_bytes(blockmove[i:i + 2], "big") for i in range(0, len(blockmove), 2)]

    w, at, fix = [], {}, []

    def here():
        return ORG + 2 * len(w)

    def emit(*words):
        w.extend(words)

    def l32(v):
        emit((v >> 16) & 0xFFFF, v & 0xFFFF)

    def absref(name):
        fix.append((len(w), name))
        emit(0, 0)

    emit(0x203C); l32(CACR)                          # MOVE.L #CACR,D0
    emit(0x4E7B, 0x0002)                             # MOVEC D0,CACR
    emit(0x41F9); l32(CRP_AT)                        # LEA CRP_AT,A0
    emit(0xF010, 0x4C00)                             # PMOVE (A0),CRP
    emit(0x41F9); l32(CRP_AT + 8)                    # LEA CRP_AT+8,A0
    emit(0xF010, 0x4000)                             # PMOVE (A0),TC
    emit(0x41F9); l32(0x9000)                        # LEA $9000,A0
    emit(0x4E60)                                     # MOVE.L A0,USP
    expect = []
    handled = 0
    for k, (src, dst, n, bad, what) in enumerate(CASES):
        for p in bad:
            emit(0x02B9); l32(0xFFFFFFFC); l32(TBL_B + 4 * (p >> 12))   # ANDI.L #~3,desc: DT 0
        emit(0xF000, 0x2400)                         # PFLUSHA
        emit(0x4BF9); absref("cont%d" % k)           # LEA cont,A5
        emit(0x207C); l32(src + n)                   # MOVEA.L #src_end,A0
        emit(0x227C); l32(dst + n)                   # MOVEA.L #dst_end,A1
        emit(0x203C); l32(n)                         # MOVE.L #n,D0
        emit(0x46FC, 0x0000)                         # MOVE.W #0,SR: user mode
        emit(*loop)                                  # the ROM's BlockMove loop
        emit(0x4E40)                                 # TRAP #0
        at["cont%d" % k] = here()
        s = SLOTS + 0x20 * k
        emit(0x23C8); l32(s + 0)                     # MOVE.L A0,s
        emit(0x23C9); l32(s + 4)                     # MOVE.L A1,s+4
        emit(0x23C1); l32(s + 8)                     # MOVE.L D1,s+8
        emit(0x45F9); l32(src)                       # LEA src,A2
        emit(0x47F9); l32(dst)                       # LEA dst,A3
        emit(0x243C); l32(n // 4 - 1)                # MOVE.L #n/4-1,D2
        emit(0x7600)                                 # MOVEQ #0,D3
        cmp = here()
        emit(0x281A)                                 # MOVE.L (A2)+,D4
        emit(0xB89B)                                 # CMP.L (A3)+,D4
        emit(0x6702)                                 # BEQ.S +2
        emit(0x5283)                                 # ADDQ.L #1,D3
        emit(0x51CA, (cmp - (here() + 2)) & 0xFFFF)  # DBRA D2,cmp
        emit(0x23C3); l32(s + 12)                    # MOVE.L D3,s+12
        emit(0x2038, COUNT)                          # MOVE.L COUNT.W,D0
        emit(0x23C0); l32(s + 16)                    # MOVE.L D0,s+16
        handled += len(bad)
        expect += [(s + 0, src, "case %d A0 = the source start" % k),
                   (s + 4, dst, "case %d A1 = the destination start" % k),
                   (s + 8, 0xFFFFFFFF, "case %d D1 = -1 (both DBRAs ran out)" % k),
                   (s + 12, 0, "case %d no destination long differs from the source" % k),
                   (s + 16, handled, "case %d handler entries so far = the invalid pages" % k)]
    at["fin"] = here()
    emit(0x4E72, 0x2700)                             # STOP #$2700
    for i, name in fix:
        w[i], w[i + 1] = at[name] >> 16, at[name] & 0xFFFF
    assert here() <= BERR, "main program overruns the handler"

    berr = []
    def b(*ws):
        berr.extend(ws)
    b(0x48E7, 0x8080)                                # MOVEM.L D0/A0,-(A7)
    b(0x52B8, COUNT)                                 # ADDQ.L #1,COUNT.W
    b(0x0CB8, 0x0000, 0x0064, COUNT)                 # CMPI.L #100,COUNT.W
    b(0x6200, 0)                                     # BHI.W LOOPSTOP (fixed below)
    bhi = len(berr) - 1
    b(0x202F, 0x0018)                                # MOVE.L $18(A7),D0: the fault address
    b(0x2078, LOGP)                                  # MOVEA.L LOGP.W,A0
    b(0x20C0)                                        # MOVE.L D0,(A0)+
    b(0x30EF, 0x0012)                                # MOVE.W $12(A7),(A0)+: the SSW
    b(0x30EF, 0x000E)                                # MOVE.W $E(A7),(A0)+: the format word
    b(0x21C8, LOGP)                                  # MOVE.L A0,LOGP.W
    b(0xE088)                                        # LSR.L #8,D0
    b(0xE888)                                        # LSR.L #4,D0: the page
    b(0xE588)                                        # LSL.L #2,D0
    b(0x0680, TBL_B >> 16, TBL_B & 0xFFFF)           # ADDI.L #TBL_B,D0
    b(0x2040)                                        # MOVEA.L D0,A0
    b(0x0090, 0x0000, 0x0001)                        # ORI.L #1,(A0): DT 1, a page
    b(0xF000, 0x2400)                                # PFLUSHA
    b(0x4CDF, 0x0101)                                # MOVEM.L (A7)+,D0/A0
    b(0x4E73)                                        # RTE
    berr[bhi] = (LOOPSTOP - (BERR + 2 * bhi)) & 0xFFFF   # BHI.W: displacement from its extension word
    trap0 = [0x4FEF, 0x0008,                         # LEA 8(A7),A7
             0x4ED5]                                 # JMP (A5)
    loopstop = [0x33FC, 0xBBBB, 0x0000, 0x3F00,      # MOVE.W #$BBBB,$3F00: the handler looped
                0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]
    exc = [0x33EF, 0x0006, 0x0000, 0x3F02,           # MOVE.W 6(A7),$3F02
           0x23EF, 0x0002, 0x0000, 0x3F04,           # MOVE.L 2(A7),$3F04
           0x33FC, 0x0001, 0x0000, 0x3F00,           # MOVE.W #1,$3F00
           0x4EF9, at["fin"] >> 16, at["fin"] & 0xFFFF]

    mem = [0] * (SIZE // 2)
    mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]         # SSP, PC
    for v in range(2, 64):
        t = BERR if v == 2 else TRAP0 if v == 32 else EXC
        mem[2 * v], mem[2 * v + 1] = t >> 16, t & 0xFFFF
    for base, code in ((ORG, w), (BERR, berr), (TRAP0, trap0), (LOOPSTOP, loopstop), (EXC, exc)):
        for i, x in enumerate(code):
            mem[base // 2 + i] = x

    def put32(a, v):
        mem[a // 2], mem[a // 2 + 1] = v >> 16, v & 0xFFFF
    put32(LOGP, LOG)
    put32(CRP_AT, 0x7FFF0002); put32(CRP_AT + 4, TBL_A); put32(CRP_AT + 8, TC)
    put32(TBL_A, TBL_B | 2)                          # entry 0: table B, short descriptors
    for p in range(256):
        put32(TBL_B + 4 * p, (p << 12) | 1)          # identity pages, valid, U and M clear
    for src, dst, n, _, _ in CASES:
        for a in range(src, src + n, 4):
            put32(a, 0xC0000000 | a)                 # the source: every long distinct
        for a in range(dst - 0x40, dst + n + 0x40, 4):
            put32(a, 0xDD000000 | a)                 # the destination before: marked

    with open(os.path.join(HERE, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(HERE, "stop_at.txt"), "w") as f:
        f.write("%x\n" % at["fin"])
    with open(os.path.join(HERE, "expect.txt"), "w") as f:
        for a, v, what in expect:
            f.write("%08x %08x %s\n" % (a, v, what))
    with open(os.path.join(HERE, "listing.bin"), "wb") as f:
        f.write(b"".join(x.to_bytes(2, "big") for x in mem[ORG // 2:(EXC + 0x40) // 2]))
    print("predec_fault: %d cases, CACR $%X, STOP at $%X" % (len(CASES), CACR, at["fin"]))


if __name__ == "__main__":
    main()
