#!/usr/bin/env python3
"""JEDEC fuse-map disassembler for the SE/30's PAL / GAL devices.

Recovers Boolean equations from a programmed-device fuse map, compares two
fuse maps, and flags dumps that are too degenerate to be real.

WHY THIS EXISTS
    The SE/30's video, clock and RAM-signalling logic sits in six small
    programmable parts.  Their fuse maps are the most primary source we have
    for that logic - more primary than any emulator or schematic redraw,
    because the fuses ARE the circuit.  But a fuse map carries no signal
    names, so equations recovered here must be read alongside the schematic
    before any pin can be given a meaning.

CONVENTIONS ARE DERIVED, NOT ASSUMED
    Fuse polarity and column ordering were established by testing candidates
    until one reproduced National Semiconductor's JED2EQN output EXACTLY on
    bitsavers' 3410633A (Apple, PAL16R8).  Run `validate` to re-prove it
    before trusting any output from this tool.

        intact fuse = 0     (a 0 bit means the link is present, so the
                             literal PARTICIPATES in that product term)
        column order  = pin2, fb19, pin3, fb18, pin4, fb17, pin5, fb16,
                        pin6, fb15, pin7, fb14, pin8, fb13, pin9, fb12
                        with the even column of each pair the true literal

USAGE
    jedec_dis.py validate <file.JED> <reference.EQN>
    jedec_dis.py dis      <file.JED> [--type 16R8|16R4|16V8]
    jedec_dis.py diff     <a.JED> <b.JED>
    jedec_dis.py triage   <file.JED> [...]
"""
import argparse
import re
import sys

# --- device geometry -------------------------------------------------------
# 64 product-term rows of 32 columns.  Rows 0-7 drive pin 19, 8-15 pin 18,
# and so on down to rows 56-63 driving pin 12.
N_ROWS, N_COLS = 64, 32
OUT_PINS = [19, 18, 17, 16, 15, 14, 13, 12]

# Column c selects literal COL_ORDER[c // 2]; an even c is the true literal.
COL_ORDER = [2, 19, 3, 18, 4, 17, 5, 16, 6, 15, 7, 14, 8, 13, 9, 12]

INTACT = 0          # derived by validate(); see module docstring

# In a 16R4 the middle four outputs are registered and the outer four are
# combinatorial.  A combinatorial output spends its FIRST product term on the
# output enable, leaving seven for logic - get this wrong and half the
# equations are silently misread.
REGISTERED = {
    "16R8": set(OUT_PINS),
    "16R4": {17, 16, 15, 14},
    "16L8": set(),
}

# GAL16V8 fuse map beyond the 2048-fuse array.  The AC1 bit order is INFERRED
# as pins 19..12 and has not been confirmed against the datasheet - treat any
# device-type guess from it as a hypothesis, not a finding.
GAL_XOR, GAL_AC1, GAL_SYN, GAL_AC0 = 2048, 2120, 2192, 2193


def parse_jedec(path):
    """Return (fuse_count, [fuse bits]).  Unlisted fuses take the F default."""
    text = open(path, "r", errors="replace").read()
    fields = text.split("*")
    count, default = None, 0
    for f in fields:
        f = f.strip()
        if m := re.match(r"^QF(\d+)", f):
            count = int(m.group(1))
        if m := re.match(r"^F([01])", f):
            default = int(m.group(1))
    if count is None:
        raise ValueError(f"{path}: no QF field, not a JEDEC fuse map")
    fuses = [default] * count
    for f in fields:
        if m := re.match(r"^L0*(\d+)\s+([01\s]+)$", f.strip()):
            addr = int(m.group(1))
            for i, bit in enumerate(re.sub(r"\s", "", m.group(2))):
                if addr + i < count:
                    fuses[addr + i] = int(bit)
    return count, fuses


def decode(fuses, dev="16R8"):
    """Return {pin: [product_term]}, each term a frozenset of (pin, is_true).

    An empty term is the constant TRUE (every literal disconnected); a term
    holding both X and /X can never be true and is dropped, which is how an
    unused product term reads on an unprogrammed row.
    """
    registered = REGISTERED.get(dev, set(OUT_PINS))
    equations = {}
    for group, pin in enumerate(OUT_PINS):
        first = group * 8
        # A combinatorial output burns its first product term on the OE.
        rows = range(first + (0 if pin in registered else 1), first + 8)
        terms = []
        for r in rows:
            literals = set()
            for c in range(N_COLS):
                if fuses[r * N_COLS + c] == INTACT:
                    literals.add((COL_ORDER[c // 2], c % 2 == 0))
            # Both polarities of the same pin present => never true.
            if any((p, True) in literals and (p, False) in literals
                   for p, _ in literals):
                continue
            terms.append(frozenset(literals))
        equations[pin] = terms
    return equations


def parse_eqn(path):
    """Parse a JED2EQN .EQN file into the same shape, for validation."""
    text = open(path, "r", errors="replace").read()
    text = text.replace("!", "/").replace("#", "+")
    names = {m.group(1): int(m.group(2))
             for m in re.finditer(r"/?(\w+)=(\d+)", text)}
    body = re.sub(r"\n\s*\+", " + ", text.split("equations", 1)[1])
    equations = {}
    for line in body.split("\n"):
        line = line.strip()
        if not line or ".oe" in line:
            continue
        if not (m := re.match(r"^/?(\w+)\s*:?=\s*(.+)$", line)):
            continue
        if (pin := names.get(m.group(1))) is None:
            continue
        terms = []
        for product in m.group(2).split("+"):
            literals = set()
            for token in product.split("*"):
                token = token.strip()
                if not token:
                    continue
                negated = token.startswith("/")
                signal = token.lstrip("/")
                if signal in names:
                    literals.add((names[signal], not negated))
            if literals:
                terms.append(frozenset(literals))
        equations[pin] = terms
    return equations


def as_sets(equations):
    """Canonical form for comparison: term order and repeats are irrelevant."""
    return {p: set(t) for p, t in equations.items() if t}


def format_equations(equations, dev):
    registered = REGISTERED.get(dev, set(OUT_PINS))
    name = lambda p: (f"i{p}" if p < 10 else f"o{p}")
    out = []
    for pin in OUT_PINS:
        op = ":=" if pin in registered else "="
        terms = equations.get(pin) or []
        if not terms:
            out.append(f"  /{name(pin)} {op} gnd")
            continue
        rendered = []
        for t in terms:
            if not t:
                rendered.append("vcc")
                continue
            rendered.append(" * ".join(
                ("" if pol else "/") + name(p)
                for p, pol in sorted(t, key=lambda x: x[0])))
        out.append(f"  /{name(pin)} {op} " + "\n        + ".join(rendered))
    return "\n".join(out)


def cmd_validate(args):
    _, fuses = parse_jedec(args.jed)
    got, want = as_sets(decode(fuses, "16R8")), as_sets(parse_eqn(args.eqn))
    if got == want:
        print("PASS - decoder reproduces the reference disassembly exactly.")
        print(f"       intact fuse = {INTACT}, standard column order.")
        return 0
    print("FAIL - decoder does NOT match the reference. Do not trust output.")
    for pin in sorted(set(got) | set(want)):
        if got.get(pin) != want.get(pin):
            print(f"  pin {pin}: {len(got.get(pin, []))} terms decoded, "
                  f"{len(want.get(pin, []))} expected")
    return 1


def cmd_dis(args):
    count, fuses = parse_jedec(args.jed)
    dev = args.type
    if dev == "auto":
        if count > 2048:                      # a GAL carries config fuses
            ac1 = fuses[GAL_AC1:GAL_AC1 + 8]
            comb = sum(ac1)
            dev = {0: "16R8", 4: "16R4", 8: "16L8"}.get(comb, "16R8")
            print(f"; GAL16V8: SYN={fuses[GAL_SYN]} AC0={fuses[GAL_AC0]} "
                  f"AC1={''.join(map(str, ac1))}")
            print(f"; inferred equivalent: {dev}  (AC1 bit order UNCONFIRMED)")
        else:
            dev = "16R8"
    print(f"; {args.jed}  ({count} fuses, decoded as {dev})")
    print("; pin names are positional - a fuse map carries no signal names")
    print(format_equations(decode(fuses, dev), dev))
    return 0


def cmd_diff(args):
    _, a = parse_jedec(args.a)
    _, b = parse_jedec(args.b)
    n = N_ROWS * N_COLS
    differ = [i for i in range(n) if a[i] != b[i]]
    if not differ:
        print(f"IDENTICAL - all {n} array fuses match.")
        return 0
    print(f"{len(differ)} of {n} array fuses differ; first: {differ[:16]}")
    return 1


def cmd_triage(args):
    """Flag fuse maps too uniform to be a real design - a failed read, or a
    part whose security fuse was blown before dumping."""
    for path in args.jed:
        _, fuses = parse_jedec(path)
        rows = [tuple(fuses[r * N_COLS:(r + 1) * N_COLS]) for r in range(N_ROWS)]
        distinct = len(set(rows))
        varied = sum(1 for r in rows
                     if not all(b == 0 for b in r) and not all(b == 1 for b in r))
        # Thresholds are advisory: a genuinely small design can look sparse,
        # so treat SUSPECT as "read the equations before using", not "discard".
        verdict = "ok" if distinct > 12 and varied > 12 else "SUSPECT"
        print(f"  {path}: distinct_rows={distinct:<3} varied={varied:<3} {verdict}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("validate", help="prove the decoder against a known .EQN")
    p.add_argument("jed"); p.add_argument("eqn"); p.set_defaults(fn=cmd_validate)

    p = sub.add_parser("dis", help="disassemble to Boolean equations")
    p.add_argument("jed")
    p.add_argument("--type", default="auto",
                   choices=["auto", "16R8", "16R4", "16L8", "16V8"])
    p.set_defaults(fn=cmd_dis)

    p = sub.add_parser("diff", help="compare two fuse arrays")
    p.add_argument("a"); p.add_argument("b"); p.set_defaults(fn=cmd_diff)

    p = sub.add_parser("triage", help="flag degenerate dumps")
    p.add_argument("jed", nargs="+"); p.set_defaults(fn=cmd_triage)

    args = ap.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
