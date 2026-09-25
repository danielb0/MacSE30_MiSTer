#!/usr/bin/env python3
"""Pin-to-net extractor for KiCad v5 (legacy text) schematics.

Prints, for chosen components, which named net each pin is on.  Written
for mishimasensei/macse30mlb - a KiCad redraw of Apple's SE/30 logic-board
schematic 050-0253-01 (MIT licence) - so that the SE/30's six PALs and its
GLUE can be read as tables of named pins instead of by squinting at scans.

WHY THIS EXISTS
    The PAL fuse maps (scripts/jedec_dis.py) give exact logic with anonymous
    pins.  The schematic gives the pin names.  Joining the two by eye across
    a 3500-pixel scan is slow and error-prone; the KiCad redraw makes it a
    parse.  The redraw is a secondary source (it is someone's transcription
    of the scan) - check anything surprising against se30.pdf.

HOW IT WORKS
    KiCad v5 .sch files hold components (position P and a 2x2 transform),
    wires (segments), junctions, and labels (local, global, hierarchical) as
    plain text; pin positions come from the library symbol.  A pin sits on
    the schematic at  P + M * (lx, ly)  with M the component's transform -
    verified here against wire endpoints, not assumed.  Connectivity is a
    union-find over points: a point joins every wire segment it lies on
    (endpoints or interior), and every label at that point names the net.
    Buses are ignored: on a v5 sheet a bus member is always carried by a
    labelled wire, which is what this reads.

    A pin with no label on its net is reported with the other pins on that
    net, so a direct pin-to-pin connection is still readable.  Only .sch
    (v5) sheets are handled; a .kicad_sch (v6) sheet is not.

USAGE
    kicad_nets.py <sheet.sch> <lib.lib> [<lib.lib> ...] REF [REF ...]
    kicad_nets.py <sheet.sch> <lib.lib> --all          every component
"""
import re
import sys
from collections import defaultdict


def parse_libs(paths):
    """DEF name -> list of (pin_number, pin_name, lx, ly)."""
    syms = {}
    for path in paths:
        cur = None
        for line in open(path, encoding="utf-8", errors="replace"):
            t = line.split()
            if not t:
                continue
            if t[0] == "DEF":
                cur = t[1]
                syms[cur] = []
            elif t[0] == "X" and cur:
                # X name number x y length orientation ...
                syms[cur].append((t[2], t[1], int(t[3]), int(t[4])))
            elif t[0] == "ENDDEF":
                cur = None
    return syms


def parse_sheet(path):
    comps, wires, labels = [], [], []
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("$Comp"):
            c = {"fields": {}}
            i += 1
            while not lines[i].startswith("$EndComp"):
                t = lines[i].split()
                if t and t[0] == "L":
                    c["lib"], c["ref"] = t[1], t[2]
                elif t and t[0] == "P":
                    c["p"] = (int(t[1]), int(t[2]))
                elif t and t[0] == "F":
                    m = re.match(r'F\s+(\d+)\s+"(.*?)"', lines[i])
                    if m:
                        c["fields"][int(m.group(1))] = m.group(2)
                elif lines[i].startswith("\t") and len(t) == 4 and all(x.lstrip("-").isdigit() for x in t):
                    c["m"] = tuple(int(x) for x in t)
                i += 1
            comps.append(c)
        elif ln.startswith("Wire Wire Line"):
            x1, y1, x2, y2 = (int(v) for v in lines[i + 1].split())
            wires.append(((x1, y1), (x2, y2)))
            i += 1
        elif ln.startswith("Text Label") or ln.startswith("Text GLabel") or ln.startswith("Text HLabel"):
            t = ln.split()
            labels.append(((int(t[2]), int(t[3])), lines[i + 1].strip()))
            i += 1
        i += 1
    return comps, wires, labels


def on_segment(p, a, b):
    (x, y), (x1, y1), (x2, y2) = p, a, b
    if (x2 - x1) * (y - y1) != (y2 - y1) * (x - x1):
        return False
    return min(x1, x2) <= x <= max(x1, x2) and min(y1, y2) <= y <= max(y1, y2)


class UF:
    def __init__(self):
        self.p = {}

    def find(self, a):
        self.p.setdefault(a, a)
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a, b):
        self.p[self.find(a)] = self.find(b)


def pin_pos(comp, lx, ly):
    a, b, c, d = comp["m"]
    px, py = comp["p"]
    return (px + a * lx + b * ly, py + c * lx + d * ly)


def build(comps, wires, labels, syms):
    uf = UF()
    seg_ids = [("seg", k) for k in range(len(wires))]
    for k, (a, b) in enumerate(wires):
        uf.union(seg_ids[k], ("pt", a))
        uf.union(seg_ids[k], ("pt", b))

    def attach(pt):
        for k, (a, b) in enumerate(wires):
            if on_segment(pt, a, b):
                uf.union(("pt", pt), seg_ids[k])

    for (a, b) in wires:
        attach(a)
        attach(b)
    for pos, _ in labels:
        attach(pos)
    pins = []  # (comp, num, name, pos)
    for c in comps:
        key = c["lib"].replace(":", "_")
        sym = syms.get(key) or syms.get(c["lib"].split(":")[-1])
        if sym is None or "m" not in c:
            continue
        for num, name, lx, ly in sym:
            pos = pin_pos(c, lx, ly)
            attach(pos)
            pins.append((c, num, name, pos))
    names = defaultdict(set)
    for pos, text in labels:
        names[uf.find(("pt", pos))].add(text)
    members = defaultdict(list)
    for c, num, name, pos in pins:
        members[uf.find(("pt", pos))].append("%s.%s(%s)" % (c["ref"], num, name))
    return uf, pins, names, members


def report(refs, pins, uf, names, members):
    for ref in refs:
        rows = [(c, num, name, pos) for (c, num, name, pos) in pins if c["ref"] == ref]
        if not rows:
            print("%s: not found" % ref)
            continue
        c = rows[0][0]
        print("== %s  %s  (%s)" % (ref, c["fields"].get(1, ""), c["lib"]))
        for c, num, name, pos in sorted(rows, key=lambda r: int(re.sub(r"\D", "", r[1]) or 0)):
            root = uf.find(("pt", pos))
            net = " ".join(sorted(names.get(root, ())))
            if not net:
                others = [m for m in members.get(root, []) if not m.startswith(ref + ".")]
                net = ("-- " + " ".join(others)) if others else "-- (unconnected)"
            print("  %3s %-8s %s" % (num, name, net))


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    sheet = argv[1]
    libs = [a for a in argv[2:] if a.lower().endswith(".lib")]
    refs = [a for a in argv[2:] if not a.lower().endswith(".lib")]
    syms = parse_libs(libs)
    comps, wires, labels = parse_sheet(sheet)
    uf, pins, names, members = build(comps, wires, labels, syms)
    if refs == ["--all"]:
        refs = sorted({c["ref"] for c in comps if "m" in c})
    report(refs, pins, uf, names, members)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
