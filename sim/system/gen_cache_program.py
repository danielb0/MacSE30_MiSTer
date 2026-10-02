#!/usr/bin/env python3
"""The system bench's instruction-cache program (SE30_PLAN.md 1.16, step 1).

Writes cachetest/program.hex (a 64K-word image, as gen_program.py's),
cachetest/stop_at.txt and cachetest/slots.txt (the long each result slot
must hold).  The expectations are the manual's, not the RTL's: MC68030 UM
section 6.

THE PROGRAM (supervisor, from $1000; routines of two words, MOVEQ #1,D2 and
RTS, each at the start of a cache line of its own)
    EI on (CACR = $0001).
    slot 0  a routine called, its MOVEQ overwritten with MOVEQ #2 by a data
            write, called again: the cache is not coherent with writes
            (UM 6.1), the old instruction runs - 1
    slot 1  CI + EI (CACR = $0009), called again: the cache was cleared,
            the new instruction runs - 2
    slot 2  MOVEC CACR,D3 after that: CI reads as zero (UM 6.3.1.8) - 1
    slot 3  overwritten again (MOVEQ #3), FI set, called: a frozen cache
            still hits (UM 6.3.1.10) - 2
    slot 4  a second routine, called frozen, overwritten, called again: a
            frozen cache does not fill on a miss - 2
    slot 5  EI only; two routines in one line, both called, both
            overwritten; CAAR = the first's address, CEI + EI: the first's
            entry is cleared (UM 6.3.1.9) - 2
    slot 6  the second's is not - 1
    slot 7  a fifth routine called, overwritten, EI cleared, called: a
            disabled cache does not hit (UM 6.3.1.11) - 2
    slot 8  EI set again, called: the entries survived disabling - 1
    Then a DBRA loop of 500 turns with the cache on, between marker writes
    to $3088 and $308C, and the same loop with it off, between $3090 and
    $3094: the bench counts the fetch cycles in each.  Then STOP.

    Each routine sits at a line index the code run between its calls does
    not use (with a margin for the kernel's prefetch), so nothing in the
    program evicts it there - a wrong result is the cache's, not the
    program's layout.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "cachetest")
ORG = 0x1000
RESULT = 0x3000
ROUTINES = 0x1800            # 16 lines of 16 bytes, one per index


class Code:
    def __init__(self):
        self.words = []
        self.fix = []        # (word index, routine name, kind) to patch

    @property
    def pc(self):
        return ORG + 2 * len(self.words)

    def emit(self, *ws):
        self.words.extend(ws)

    def bsr(self, r):
        self.fix.append((len(self.words) + 1, r, "bsr"))
        self.emit(0x6100, 0x0000)                                  # BSR.W r

    def patch(self, r, val):
        self.fix.append((len(self.words) + 2, r, "abs"))
        self.emit(0x33FC, 0x7400 | val, 0, 0)                     # MOVE.W #($7400|val),(r).L

    def cacr(self, v):
        self.emit(0x7000 | v, 0x4E7B, 0x0002)                      # MOVEQ #v,D0; MOVEC D0,CACR

    def store(self, reg, slot):
        a = RESULT + 4 * slot
        self.emit(0x23C0 | reg, a >> 16, a & 0xFFFF)               # MOVE.L Dreg,(slot).L

    def marker(self, a):
        self.emit(0x23C0, a >> 16, a & 0xFFFF)                     # MOVE.L D0,(a).L


def build():
    c = Code()
    spans = {}               # routine -> list of (from, to) PCs it must survive
    want = []
    c.cacr(1)
    # slot 0: not coherent with writes
    s = c.pc
    c.bsr("r1"); c.patch("r1", 2); c.bsr("r1")
    c.store(2, 0); want.append(1)
    # slot 1: CI
    c.cacr(9); c.bsr("r1"); c.store(2, 1); want.append(2)
    # slot 2: CACR reads CI as zero
    c.emit(0x4E7A, 0x3002)                                         # MOVEC CACR,D3
    c.store(3, 2); want.append(1)
    # slot 3: frozen, a hit still hits
    c.patch("r1", 3); c.cacr(3); c.bsr("r1")
    spans["r1"] = [(s, c.pc)]
    c.store(2, 3); want.append(2)
    # slot 4: frozen, a miss does not fill
    s = c.pc
    c.bsr("r2"); c.patch("r2", 2); c.bsr("r2")
    spans["r2"] = [(s, c.pc)]
    c.store(2, 4); want.append(2)
    c.cacr(1)
    # slots 5, 6: CEI clears the one entry CAAR names
    s = c.pc
    c.bsr("r3"); c.bsr("r4"); c.patch("r3", 2); c.patch("r4", 2)
    c.fix.append((len(c.words) + 1, "r3", "abs"))
    c.emit(0x203C, 0, 0)                                           # MOVE.L #r3,D0
    c.emit(0x4E7B, 0x0802)                                         # MOVEC D0,CAAR
    c.cacr(5)
    c.bsr("r3"); c.store(2, 5); want.append(2)
    c.bsr("r4")
    spans["r3"] = [(s, c.pc)]
    c.store(2, 6); want.append(1)
    # slots 7, 8: disabled, no hits; enabled, the entries are still there
    s = c.pc
    c.bsr("r5"); c.patch("r5", 2); c.cacr(0); c.bsr("r5"); c.store(2, 7); want.append(2)
    c.cacr(1); c.bsr("r5")
    spans["r5"] = [(s, c.pc)]
    c.store(2, 8); want.append(1)
    # the loops: cached, then not
    for on, m0, m1 in ((1, 0x3088, 0x308C), (0, 0x3090, 0x3094)):
        c.cacr(on)
        c.emit(0x323C, 499)                                        # MOVE.W #499,D1
        c.marker(m0)
        if c.pc & 2:
            c.emit(0x4E71)                                         # NOP: the DBRA on a long
        c.emit(0x51C9, 0xFFFE)                                     # loop: DBRA D1,loop
        c.marker(m1)
    stop_at = c.pc
    c.emit(0x4E72, 0x2700)                                         # STOP #$2700

    # the routines' lines: an index no code between the calls touches
    def indices(a, b):
        return {(x >> 4) & 15 for x in range(a & ~3, b + 16, 4)}
    addr = {}
    used = set()
    for r in ("r1", "r2", "r3", "r5"):
        busy = set()
        for a, b in spans[r]:
            busy |= indices(a, b)
        free = [i for i in range(16) if i not in busy and i not in used]
        assert free, "no free line for %s" % r
        used.add(free[0])
        addr[r] = ROUTINES + 16 * free[0]
    addr["r4"] = addr["r3"] + 4                                    # the same line, the next entry
    for i, r, kind in c.fix:
        a = addr[r]
        if kind == "bsr":
            c.words[i] = (a - (ORG + 2 * i)) & 0xFFFF
        else:
            c.words[i], c.words[i + 1] = a >> 16, a & 0xFFFF
    return c, addr, stop_at, want


def main():
    c, addr, stop_at, want = build()
    mem = [0x4E71] * 65536
    mem[0], mem[1] = 0x0000, 0x0800                                 # SSP
    mem[2], mem[3] = 0x0000, ORG                                    # PC
    for i, w in enumerate(c.words):
        mem[ORG // 2 + i] = w
    assert ORG + 2 * len(c.words) <= ROUTINES
    for a in addr.values():
        mem[a // 2], mem[a // 2 + 1] = 0x7401, 0x4E75               # MOVEQ #1,D2; RTS
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "program.hex"), "w", newline="\n") as f:
        for w in mem:
            f.write("%04x\n" % w)
    with open(os.path.join(OUT, "stop_at.txt"), "w", newline="\n") as f:
        f.write("%08x\n%d\n" % (stop_at, len(c.words)))
    with open(os.path.join(OUT, "slots.txt"), "w", newline="\n") as f:
        for v in want:
            f.write("%08x\n" % v)
    print("cache program: %d words, STOP at $%X, routines %s" %
          (len(c.words), stop_at, " ".join("%s=$%X" % kv for kv in sorted(addr.items()))))


if __name__ == "__main__":
    main()
