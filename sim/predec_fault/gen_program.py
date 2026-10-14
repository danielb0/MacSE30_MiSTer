#!/usr/bin/env python3
"""The predec_fault bench's program (tb_predec_fault.v's header; SE30_PLAN.md
KNOWN ISSUES 20): instructions page-faulting mid-instruction through the PMMU,
resumed by a handler that does what A/UX's pager does - the two loops the
board's trace caught faulting before the Mac environment's bomb.

  blockmove  the ROM's BlockMove backward loop, $4080EFFE-$4080F01F byte for
             byte: MOVE.L D0,D1; LSR.L #5,D1; 8 x MOVE.L -(A0),-(A1) under
             two DBRAs (the board: #1063-#1097)
  straddle   the BlockMove loop on word-aligned blocks: a long at $xxxFFE spans
             two pages, and the lower or the upper word's page is invalid
  dcmp       the decompressor the board faulted in at $296E5E/$296E7C
             (#1246/#1247), captured from MAME's run of the same image
             (C:\\temp\\Mac\\mame\\aux\\bp296.lua; the routine at $296DE8):
             its expansion loop $296E40-$296E8F byte for byte, entered at
             $296E48 - each flag byte's bits, MSB first, pick for each output
             word two literal bytes (MOVE.B (A0)+,(A2)+ twice, $296E5E) or a
             word from a table (MOVE.W (A1,D0.W),(A2)+, $296E7C), a zero flag
             byte eight literal pairs; D1 = the output words, D5 = 0

THE PROGRAM (supervisor, from $1000)
    CACR from the CACR environment variable (default 0: caches off)
    PMOVE (A0),CRP / PMOVE (A0),TC: TC $80C84800 (E, PS 4 KB, IS 8, TIA 4,
      TIB 8); table A at $4000 (entry 0 -> table B at $4100, short format),
      table B: 256 page descriptors, identity, valid, U and M clear (the
      walker sets them, UM 9.5.3 - A/UX's pages start that way too)
    USP $9000
    each case (CASES; CASESET=blockmove|straddle|dcmp picks one kind): the case's
      pages made invalid (DT 0) and PFLUSHA; the registers; MOVE #0,SR (user
      mode, as the Mac environment runs); the loop; TRAP #0 back to
      supervisor; A0, A1, D1, the count of output longs that differ from the
      reference (the source for blockmove, the model's output for dcmp), the
      handler count and A2 to the case's slots
    STOP #$2700
    vector 2 (bus error), $1C00: count the entry ($3100), log the fault
      address, SSW and format word ($3200 on), make the faulting page's
      descriptor valid, PFLUSHA, RTE with the frame untouched (DF set: the
      faulted cycle reruns, UM 8.2.1) - more than 100 entries = a loop:
      stop at $1D80
    TRAP #0 (vector 32), $1D00: drop its frame, JMP (A5) (the case's
      continuation)
    any other exception, $1E00: its format/vector word and PC to $3F00, stop

Writes program.hex (512 KB as 16-bit words), stop_at.txt ({STOP address} {checks})
and expect.txt ({slot} {value} {what} per line).
"""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
ROM = os.environ.get("ROM", "C:/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM")
CACR = int(os.environ.get("CACR", "0"), 0)
CASESET = os.environ.get("CASESET", "all")
ORG, BERR, TRAP0, LOOPSTOP, EXC = 0x1000, 0x1C00, 0x1D00, 0x1D80, 0x1E00
TBL_A, TBL_B, CRP_AT = 0x4000, 0x4100, 0x3E00
TC = 0x80C84800
SLOTS, COUNT, LOGP, LOG = 0x3000, 0x3100, 0x3104, 0x3200
SIZE = 0x80000                                   # the image: 512 KB

# the decompressor's expansion loop, $296E40-$296E8F (MAME, identical in all 20 hits)
DCMP = bytes.fromhex("4A05674C149060482401028200000007E6896012780716186712D603651814D814D851CCFFF6"
                     "53816AEA601A14D814D851CCFFFA60F070001018D04034F1000051CCFFD860E0380267B6"
                     "7400161860F0")
DCMP_ENTRY = 0x08                                # $296E48

# blockmove: (source start, destination start, bytes, invalid pages, what)
BLOCKMOVE = [
    (0x20000, 0x30000, 0x2000, [0x30000, 0x31000], "destination pages invalid: the writes fault (LASTWRITE replay)"),
    (0x24000, 0x34000, 0x2000, [0x24000, 0x25000], "source pages invalid: the reads fault (rollback, re-execute)"),
    (0x28000, 0x38000, 0x2000, [0x28000, 0x29000, 0x38000, 0x39000], "both invalid: a read fault, then a write fault, in one instruction"),
    (0x2C800, 0x3C000, 0x2000, [0x2C000, 0x2D000, 0x2E000, 0x3C000, 0x3D000], "source misaligned to the pages: the faults land mid-loop"),
]
# straddle: the same loop on word-aligned blocks, so a long at $xxxFFE spans two
# pages (the board, compile 59: #1271/#1272 faulted at $33FFFE/$33BFFE, then the
# process ran on its stack) - (source, destination, bytes, invalid pages, what)
STRADDLE = [
    (0x0A002, 0x0C002, 0x2000, [0x0C000, 0x0D000], "straddling writes, the LOWER word's page invalid (the board's #1271)"),
    (0x10002, 0x14002, 0x2000, [0x10000, 0x11000], "straddling reads, the lower word's page invalid"),
    (0x16000, 0x18002, 0x2000, [0x1A000], "a straddling write, the UPPER word's page invalid: the first word lands, the second faults"),
    (0x1A802, 0x1E000, 0x1800, [0x1C000], "a straddling read, the UPPER word's page invalid"),
    (0x74000, 0x76001, 0x1000, [0x77000], "a long at $xxxFFD: 3 bytes land, the LAST byte's page invalid (SIZE byte)"),
    (0x78000, 0x7A003, 0x1000, [0x7B000], "a long at $xxxFFF: 1 byte lands, the last 3 bytes' page invalid (SIZE 3 bytes)"),
]
# dcmp: (table, source, destination, reference, output words, seed, which pages invalid, what)
DCMP_CASES = [
    (0x40000, 0x41000, 0x48F00, 0x50000, 0x2000, 1, "dst", "destination pages invalid: the byte and word writes fault, as on the board"),
    (0x40000, 0x55000, 0x5A000, 0x60000, 0x1000, 2, "src", "source pages invalid: the (A0)+ reads fault"),
    (0x65000, 0x66000, 0x6AF00, 0x70000, 0x1000, 3, "tbl+dst", "the table and the destination invalid: the indexed read and the writes fault"),
]


def dcmp_stream(nwords, seed):
    """A compressed stream, the table and the output the loop must produce."""
    rnd = random.Random(seed)
    table = [0x7000 | (i * 0x35 + 0x11) & 0x0FFF for i in range(256)]
    src, out = bytearray(), bytearray()
    assert nwords % 8 == 0
    for _ in range(nwords // 8):
        flag = 0 if rnd.random() < 0.15 else rnd.randrange(1, 256)
        src.append(flag)
        for bit in range(7, -1, -1):
            if flag & (1 << bit):
                i = rnd.randrange(256)
                src.append(i)
                out += table[i].to_bytes(2, "big")
            else:
                a, b = rnd.randrange(256), rnd.randrange(256)
                src += bytes((a, b))
                out += bytes((a, b))
    return bytes(src), table, bytes(out)


def pages(lo, hi):
    return list(range(lo & ~0xFFF, hi, 0x1000))


def main():
    rom = open(ROM, "rb").read()
    assert len(rom) == 262144 and rom[0:4] == bytes.fromhex("97221136"), "not the 97221136 ROM"
    blockmove = rom[0xEFFE:0xF020]                  # MOVE.L D0,D1 ... the second DBRA
    assert blockmove[:6] == bytes.fromhex("2200EA896012") and blockmove[-4:] == bytes.fromhex("51C9FFE6")
    words = lambda b: [int.from_bytes(b[i:i + 2], "big") for i in range(0, len(b), 2)]

    mem = [0] * (SIZE // 2)

    def put32(a, v):
        mem[a // 2], mem[a // 2 + 1] = (v >> 16) & 0xFFFF, v & 0xFFFF

    def putbytes(a, b):
        assert a % 2 == 0
        b = b + b"\0" * (len(b) & 1)
        for i in range(0, len(b), 2):
            mem[(a + i) // 2] = (b[i] << 8) | b[i + 1]

    # the cases as (registers, code, entry offset, reference, destination, bytes, invalid pages, A2 wanted, what)
    cases = []
    bm = (BLOCKMOVE if CASESET in ("all", "blockmove") else []) + (STRADDLE if CASESET in ("all", "straddle") else [])
    if bm:
        for src, dst, n, bad, what in bm:
            for a in range(src, src + n, 4):
                put32(a, 0xC0000000 | a)             # the source: every long distinct
            for a in range((dst - 0x40) & ~3, dst + n + 0x40, 4):
                put32(a, 0xDD000000 | a)             # the destination before: marked
            regs = [(0x207C, src + n), (0x227C, dst + n), (0x203C, n)]      # A0, A1, D0
            cases.append((regs, words(blockmove), 0, src, dst, n, bad, None,
                          {"A0": src, "A1": dst}, "blockmove: " + what))
    if CASESET in ("all", "dcmp"):
        for tbl, src, dst, ref, n, seed, which, what in DCMP_CASES:
            s, table, out = dcmp_stream(n, seed)
            for i, t in enumerate(table):
                mem[tbl // 2 + i] = t
            putbytes(src, s)
            putbytes(ref, out)
            for a in range(dst - 0x40, dst + len(out) + 0x40, 4):
                put32(a, 0xDD000000 | a)
            bad = []
            if "src" in which: bad += pages(src, src + len(s))
            if "tbl" in which: bad += pages(tbl, tbl + 512)
            if "dst" in which: bad += pages(dst, dst + len(out))
            assert ref + len(out) <= SIZE and src + len(s) < dst
            regs = [(0x207C, src), (0x227C, tbl), (0x247C, dst), (0x223C, n), (0x7A00, None)]   # A0, A1, A2, D1, MOVEQ #0,D5
            cases.append((regs, words(DCMP) + [0x4E40], DCMP_ENTRY, ref, dst, len(out), bad, dst + len(out),
                          {"A0": src + len(s), "A1": tbl}, "dcmp: " + what))

    w, at, fix = [], {}, []

    def here():
        return ORG + 2 * len(w)

    def emit(*ws):
        w.extend(ws)

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
    for k, (regs, code, entry, ref, dst, n, bad, a2_want, want, what) in enumerate(cases):
        for p in bad:
            emit(0x02B9); l32(0xFFFFFFFC); l32(TBL_B + 4 * (p >> 12))   # ANDI.L #~3,desc: DT 0
        emit(0xF000, 0x2400)                         # PFLUSHA
        emit(0x4BF9); absref("cont%d" % k)           # LEA cont,A5
        for op, v in regs:
            emit(op)
            if v is not None:
                l32(v)
        emit(0x46FC, 0x0000)                         # MOVE.W #0,SR: user mode
        if entry:
            emit(0x6000 | entry)                     # BRA.B the loop's entry
        emit(*code)
        if code[-1] != 0x4E40:
            emit(0x4E40)                             # TRAP #0
        at["cont%d" % k] = here()
        s = SLOTS + 0x20 * k
        emit(0x23C8); l32(s + 0)                     # MOVE.L A0,s
        emit(0x23C9); l32(s + 4)                     # MOVE.L A1,s+4
        emit(0x23C1); l32(s + 8)                     # MOVE.L D1,s+8
        emit(0x23CA); l32(s + 20)                    # MOVE.L A2,s+20
        emit(0x45F9); l32(ref)                       # LEA ref,A2
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
        expect += [(s + 0, want["A0"], "case %d A0 at its end (%s)" % (k, what)),
                   (s + 4, want["A1"], "case %d A1 at its end" % k),
                   (s + 8, 0xFFFFFFFF, "case %d D1 = -1 (the loop ran out)" % k),
                   (s + 12, 0, "case %d no output long differs from the reference" % k),
                   (s + 16, handled, "case %d handler entries so far = the invalid pages" % k)]
        if a2_want is not None:
            expect.append((s + 20, a2_want, "case %d A2 at the output's end" % k))
    at["fin"] = here()
    emit(0x4E72, 0x2700)                             # STOP #$2700
    for i, name in fix:
        w[i], w[i + 1] = at[name] >> 16, at[name] & 0xFFFF
    assert here() <= BERR, "main program overruns the handler"
    assert len(cases) * 0x20 <= COUNT - SLOTS

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

    mem[0:4] = [0x0000, 0x8000, 0x0000, ORG]         # SSP, PC
    for v in range(2, 64):
        t = BERR if v == 2 else TRAP0 if v == 32 else EXC
        mem[2 * v], mem[2 * v + 1] = t >> 16, t & 0xFFFF
    for base, code in ((ORG, w), (BERR, berr), (TRAP0, trap0), (LOOPSTOP, loopstop), (EXC, exc)):
        for i, x in enumerate(code):
            mem[base // 2 + i] = x
    put32(LOGP, LOG)
    put32(CRP_AT, 0x7FFF0002); put32(CRP_AT + 4, TBL_A); put32(CRP_AT + 8, TC)
    put32(TBL_A, TBL_B | 2)                          # entry 0: table B, short descriptors
    for p in range(256):
        put32(TBL_B + 4 * p, (p << 12) | 1)          # identity pages, valid, U and M clear

    with open(os.path.join(HERE, "program.hex"), "w") as f:
        for x in mem:
            f.write("%04x\n" % x)
    with open(os.path.join(HERE, "stop_at.txt"), "w") as f:
        f.write("%x %d\n" % (at["fin"], len(expect)))
    with open(os.path.join(HERE, "expect.txt"), "w") as f:
        for a, v, what in expect:
            f.write("%08x %08x %s\n" % (a, v, what))
    with open(os.path.join(HERE, "listing.bin"), "wb") as f:
        f.write(b"".join(x.to_bytes(2, "big") for x in mem[ORG // 2:(EXC + 0x40) // 2]))
    print("predec_fault: %d cases (%s), %d invalid pages, CACR $%X, STOP at $%X" % (len(cases), CASESET, handled, CACR, at["fin"]))


if __name__ == "__main__":
    main()
