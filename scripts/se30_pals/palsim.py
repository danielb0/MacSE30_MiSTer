#!/usr/bin/env python3
"""Cycle simulator for the SE/30's video PALs - to read the slot-E access.

WHY THIS EXISTS
    SE30_PLAN.md 2.11 row 15 is open: how many clocks a CPU access to the
    video RAM or declaration ROM takes, and whether that depends on where
    in the line it starts.  The answer is inside UE7 (the slot access state
    machine) and UE6 (its decoder), which arbitrate the CPU against the
    display's own use of the VRAM using HSYNC* and VIDTIME from UG7/UG6.
    Reading five-bit state equations by eye is not reliable; running them
    is.  This simulates the four video PALs plus the two LS393 counters
    from the equations jedec_dis.py recovers, drives a 68030-shaped slot
    cycle into them, and reports what UE6 answers and when.

    The JEDECs are Bolle's rewrites (CC-BY-NC-SA, read-only, not in the
    repo - plan 1.6): what is taken from them is behaviour and timing, which
    is what the RTL is written to.

MODEL
    One step per C16M clock.  UG7, UG6 and UE7 are registered on the rising
    edge, with feedback from their own pin levels.  UE6 is combinatorial
    and is evaluated to a fixpoint in both halves of the clock, because its
    VIDMUX* term uses C16M as a level.  UG8 (CNT0-7) counts falling edges
    of C2M and is cleared while HCTRRST is high; UF8 (VADR0-7) counts
    falling edges of TWOLINE and is cleared while LCTRRST is high - LS393
    behaviour.  Pin polarity follows the GAL XOR bit as jedec_dis renders
    it; a combinatorial pin whose OE is false reads as its pull-up (1).
    Each PAL's equations are compiled once into a Python function.

    Position: px counts clocks from the clock after HCTRRST; line 0 is the
    first full line after LCTRRST fired (LCTRRST is a decode of the
    line-pair counter and fires inside a line, not at its end).

    The CPU: address (SLTE/F, A24, A16, R/W*) valid from the rising edge
    that starts S0; NUBUS* (GLUE's slot select, which follows AS*) asserted
    at the falling edge that starts S1; DSACK0* sampled at every following
    falling edge (end of S2, then each wait state); AS*/NUBUS* negated at
    the falling edge that starts S5, one clock after the sample that saw
    DSACK0* low.  A back-to-back cycle starts S0 at the next rising edge.

USAGE
    palsim.py [--jeds DIR] [--burst N]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import jedec_dis as jd  # noqa: E402


def ident(name):
    """A net name as a Python dict key literal."""
    return repr(name)


class PAL:
    def __init__(self, name, jed, pins):
        self.name = name
        count, fuses = jd.parse_jedec(jed)
        if count <= 2048:
            raise ValueError(f"{jed}: not a GAL image")
        ac1 = fuses[jd.GAL_AC1:jd.GAL_AC1 + 8]
        xor = fuses[jd.GAL_XOR:jd.GAL_XOR + 8]
        self.dev = {0: "16R8", 4: "16R4", 8: "16L8"}[sum(ac1)]
        self.eq = jd.decode(fuses, self.dev)
        self.pins = jd.parse_pins("@" + pins)
        self.registered = jd.REGISTERED[self.dev]
        self.xor = {pin: xor[i] for i, pin in enumerate(jd.OUT_PINS)}
        self.outputs = [p for p in jd.OUT_PINS if self.eq.get(p)]
        self.reg_fn = self.compile([p for p in self.outputs if p in self.registered])
        self.comb_pins = [p for p in self.outputs if p not in self.registered]
        self.comb_fn = self.compile(self.comb_pins, with_oe=True)

    def sig(self, pin):
        """Net name of a pin.  Unwired internal state (Qnint, ncN) is private
        to the device: UG6 and UG7 both have a Q2int and a Q3int."""
        s = self.pins.get(pin, f"p{pin}")
        if re.match(r"^(Q\d+int|nc\d+)$", s):
            return f"{self.name}.{s}"
        return s

    def expr(self, terms):
        if not terms:
            return "False"
        prods = []
        for t in terms:
            if not t:
                return "True"
            prods.append("(" + " and ".join(
                f"n[{ident(self.sig(p))}]" if pol else f"(not n[{ident(self.sig(p))}])"
                for p, pol in sorted(t)) + ")")
        return " or ".join(prods)

    def compile(self, pins, with_oe=False):
        """A function net -> {name: level} for the given output pins."""
        lines = ["def f(n):", "    r = {}"]
        for p in pins:
            s = ident(self.sig(p))
            val = self.expr(self.eq[p])
            lvl = f"(1 if ({val}) else 0)" if self.xor[p] else f"(0 if ({val}) else 1)"
            if with_oe:
                oe = self.eq.get((p, "oe"))
                oe_expr = "False" if oe is None else self.expr(oe)
                lines.append(f"    r[{s}] = {lvl} if ({oe_expr}) else 1")
            else:
                lines.append(f"    r[{s}] = {lvl}")
        lines.append("    return r")
        ns = {}
        exec("\n".join(lines), ns)
        return ns["f"]

    def comb(self, net):
        for _ in range(16):
            r = self.comb_fn(net)
            if all(net.get(k) == v for k, v in r.items()):
                return
            net.update(r)
        raise RuntimeError(f"{self.name}: no fixpoint")


class Board:
    def __init__(self, jeds):
        p = lambda n: PAL(n, os.path.join(jeds, f"{n}_16v8.JED"), os.path.join(HERE, f"{n}.pins"))
        self.ug7, self.ug6, self.ue7, self.ue6 = p("UG7"), p("UG6"), p("UE7"), p("UE6")
        self.regs = [self.ug7, self.ug6, self.ue7]
        self.net = {}
        for pal in self.regs + [self.ue6]:
            for pin in pal.outputs:
                self.net[pal.sig(pin)] = 1
        self.net.update({"SERVID": 1, "SLTE/F": 1, "A24": 1, "NUBUS*": 1,
                         "R/W*": 1, "A16": 0, "C16M": 1, "PD1": 0, "PD7": 0, "PD8": 0})
        self.cnt = self.vadr = 0
        self.counters()
        self.cycle = 0
        self.line = -1
        self.px = 0
        self.frames = 0
        self.hook = None

    def counters(self):
        n = self.net
        c, v = self.cnt, self.vadr
        for i in range(8):
            n[f"CNT{i}"] = (c >> i) & 1
            n[f"VADR{i}"] = (v >> i) & 1

    def step(self, at_fall=None):
        """One clock: high half, falling edge (CPU acts), low half, rising edge.
        Returns DSACK0* as the CPU would sample it at the falling edge."""
        n = self.net
        n["C16M"] = 1
        self.ue6.comb(n)
        sampled = n["DSACK0*"]
        if self.hook:
            self.hook()                         # trace: the clock as the CPU sees it
        if at_fall:
            at_fall()
        n["C16M"] = 0
        self.ue6.comb(n)
        # bookkeeping for the clock that is ending
        if n["HCTRRST"]:
            self.line += 1
            self.px = -1
        if n["LCTRRST"]:
            self.line = -1                       # the next HCTRRST starts line 0
            self.frames += 1
        # rising edge
        prev_c2m, prev_two = n["C2M"], n["TWOLINE"]
        new = {}
        for pal in self.regs:
            new.update(pal.reg_fn(n))
        n.update(new)
        if prev_c2m and not n["C2M"]:
            self.cnt = (self.cnt + 1) & 0xFF
        if n["HCTRRST"]:
            self.cnt = 0
        if prev_two and not n["TWOLINE"]:
            self.vadr = (self.vadr + 1) & 0xFF
        if n["LCTRRST"]:
            self.vadr = 0
        self.counters()
        self.px += 1
        self.cycle += 1
        return sampled

    def run(self, clocks):
        for _ in range(clocks):
            self.step()

    def run_to(self, line, px):
        while not (self.line == line and self.px == px):
            self.step()

    def snapshot(self):
        return (dict(self.net), self.cnt, self.vadr, self.cycle, self.line, self.px, self.frames)

    def restore(self, s):
        net, self.cnt, self.vadr, self.cycle, self.line, self.px, self.frames = s
        self.net = dict(net)


def slot_cycle(b, rw, a16, trace=None):
    """One 68030 slot-E cycle from the current clock (its S0).
    Returns the number of wait states; the cycle is 3 + that clocks."""
    n = b.net
    n["SLTE/F"], n["A24"], n["A16"], n["R/W*"] = 0, 0, a16, rw

    def assert_sel():
        n["NUBUS*"] = 0

    def negate():
        n["NUBUS*"] = 1
        n["SLTE/F"], n["A24"] = 1, 1

    def record():
        if trace is not None:
            trace.append((b.px, n["VIDS4"] << 4 | n["VIDS3"] << 3 | n["VIDS2"] << 2 | n["VIDS1"] << 1 | n["VIDS0"],
                          n["VR*"], n["VID/V"], n["VIDREQ"], n["DSACK0*"], n["VC*"], n["VIDMUX*"],
                          n["DOE*"], n["VIDW*"], n["VIDROM*"], n["VIDTIME"], n["HSYNC*"]))

    b.hook = record if trace is not None else None
    b.step(at_fall=assert_sel)                      # S0, S1
    k = 0
    while True:
        if b.step() == 0:                           # S2 / Sw: sample at the falling edge
            break
        k += 1
        if k > 2000:
            raise RuntimeError("no DSACK0* in 2000 clocks")
    b.step(at_fall=negate)                          # S4, S5
    b.hook = None
    return k


def sweep(b, snap, rw, a16):
    """Wait states for an access starting at each of the 704 phases of the
    line the snapshot is at; returns {waits: [phases]}."""
    waits = {}
    b.restore(snap)
    for phase in range(704):
        s = b.snapshot()
        k = slot_cycle(b, rw, a16)
        waits.setdefault(k, []).append(phase)
        b.restore(s)
        b.step()
    return waits


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--jeds", default="C:/temp/Mac/SE30/Docs/bolle-repro")
    ap.add_argument("--burst", type=int, default=3000, help="back-to-back writes to time")
    a = ap.parse_args(argv[1:])
    b = Board(a.jeds)

    # settle: two frame clears, so both counters and every state machine are in step
    while b.frames < 2:
        b.step()
        if b.cycle > 3 * 372 * 704:
            n = b.net
            print(f"NOT SETTLING after {b.cycle} clocks: line {b.line} cnt {b.cnt} vadr {b.vadr} "
                  f"TWOLINE {n['TWOLINE']} VIDTIME {n['VIDTIME']} LCTRRST {n['LCTRRST']}")
            return 1
    b.run_to(0, 0)
    print(f"settled after {b.cycle} clocks")

    # cross-check against plan 2.9 before trusting anything below
    start = b.cycle
    b.step()
    while b.px != 0:
        b.step()
    print(f"line: {b.cycle - start} clocks (plan 2.9: 704)")
    b.run_to(100, 0)
    while b.net["HSYNC*"] == 0:
        b.step()
    while b.net["HSYNC*"] == 1:
        b.step()
    lo, n = b.px, 0
    while b.net["HSYNC*"] == 0:
        b.step()
        n += 1
    print(f"HSYNC*: low from px {lo} for {n} clocks (plan 2.9: 536, 288)")
    f0 = b.frames
    while b.frames == f0:
        b.step()
    start = b.cycle
    while b.frames == f0 + 1:
        b.step()
    print(f"frame: {b.cycle - start} clocks = {(b.cycle - start) / 704:.1f} lines (plan 2.9: Bolle's UG6 reads 372)")
    vs = None
    b.run_to(300, 0)
    while b.net["VSYNC*"]:
        b.step()
    vs, n = b.line, 0
    while b.net["VSYNC*"] == 0:
        b.step()
        if b.px == 0:
            n += 1
    print(f"VSYNC*: low from line {vs} for {n} lines (plan 2.9: 344, 4)")
    b.run_to(0, 0)
    f0 = b.frames
    first = last = None
    act, seen = 0, False
    while b.frames == f0:
        if b.net["VIDTIME"]:
            seen = True
        if b.net["HCTRRST"]:
            if seen:
                act += 1
                first = b.line if first is None else first
                last = b.line
            seen = False
        b.step()
    print(f"VIDTIME lines: {act}, lines {first}..{last} (plan 2.9: 342 active)")

    # the sweeps
    results = {}
    for line_no, kind in ((100, "active"), (360, "blank")):
        b.run_to(line_no, 0)
        snap = b.snapshot()
        for rw, a16 in ((1, 0), (0, 0), (1, 1)):
            waits = sweep(b, snap, rw, a16)
            label = f"{kind} line, {'read' if rw else 'write'} {'ROM' if a16 else 'VRAM'}"
            results[label] = waits
            ks = sorted(waits)
            hist = ", ".join(f"{k}:{len(waits[k])}" for k in ks)
            print(f"{label:26s} wait states {ks[0]}..{ks[-1]} (clocks {ks[0]+3}..{ks[-1]+3})  histogram {hist}")
        b.restore(snap)

    # traces: the best and worst phase of an active-line read and write
    b.run_to(100, 0)
    snap = b.snapshot()
    hdr = "   px VIDS VR* VID/V REQ DSACK VC* MUX* DOE* VIDW* ROM* VIDTIME HSYNC*"
    for rw, a16 in ((1, 0), (0, 0)):
        label = f"active line, {'read' if rw else 'write'} VRAM"
        w = results[label]
        for phase in (w[min(w)][0], w[max(w)][0]):
            b.restore(snap)
            b.run(phase)
            trace = []
            k = slot_cycle(b, rw, a16, trace)
            print(f"\n{label}, start px {phase}: {k} wait states, {k+3} clocks")
            print(hdr)
            for t in trace:
                print("  %3d   %02x  %d    %d    %d    %d    %d   %d    %d    %d    %d      %d      %d" % t)

    # the per-phase pattern of one active line, as runs
    w = results["active line, read VRAM"]
    per = [None] * 704
    for k, phases in w.items():
        for ph in phases:
            per[ph] = k
    runs, cur, cnt0 = [], per[0], 0
    for v in per:
        if v == cur:
            cnt0 += 1
        else:
            runs.append((cur, cnt0)); cur, cnt0 = v, 1
    runs.append((cur, cnt0))
    print()
    print("wait states by start phase (active line read), as (waits x phases) runs:")
    print("  " + " ".join(f"{k}x{c}" for k, c in runs))

    # back-to-back writes across active lines: the PrimaryInit fill
    b.restore(snap)
    b.run(100)
    trace = []
    ks = [slot_cycle(b, 0, 0, trace) for _ in range(4)]
    print()
    print(f"four back-to-back writes from px 100: wait states {ks}")
    print(hdr)
    for t in trace:
        print("  %3d   %02x  %d    %d    %d    %d    %d   %d    %d    %d    %d      %d      %d" % t)
    b.restore(snap)
    start = b.cycle
    total = 0
    for _ in range(a.burst):
        total += slot_cycle(b, 0, 0)
    clocks = b.cycle - start
    print()
    print(f"{a.burst} back-to-back VRAM writes from line 100: {clocks / a.burst:.2f} clocks each, "
          f"mean wait states {total / a.burst:.2f}; 43,776 writes -> {43776 * clocks / a.burst / 15.6672e3:.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
