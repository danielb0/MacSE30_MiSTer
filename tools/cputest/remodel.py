"""Re-expect convert.py's vectors from our reference model - plan 8.9.8.

    python remodel.py <in.vec> -o <out.vec>

The same inputs (WinUAE cputest's), the expected half replaced by the
model's (tools/fpu_model, exceptional operand included), so the microcode
(vec.py) and the RTL (sim/fpu, through rtlvec.py) can be held to the model
on inputs its own generator never chose.  Where our three agree and WinUAE
differs is check.py's and triage.py's business; a difference here is ours.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'fpu_model'))

from replay import parse                                      # noqa: E402
from vectors import execute, fields_of                        # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('vec')
    ap.add_argument('-o', required=True)
    a = ap.parse_args(argv)
    n = bad = 0
    with open(a.o, 'w', newline='\n') as f:
        f.write('# WinUAE cputest inputs, expected by tools/fpu_model (tools/cputest/remodel.py): %s\n'
                % os.path.basename(a.vec))
        for line in open(a.vec):
            if line.startswith('#') or not line.strip():
                continue
            group, kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, _ = parse(line)
            try:
                out = execute(kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg)
            except Exception:
                bad += 1
                continue
            f.write(fields_of('m' + group[1:], kind, cmd, fpcr, fpsr, rx, ry, rc, operand, dreg, out) + '\n')
            n += 1
    print('%d vectors, %d the model refused' % (n, bad))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
