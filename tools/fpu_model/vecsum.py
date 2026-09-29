"""The sums vecread.v prints, computed in Python from the same file: the
Verilog reader and the Python parser must agree field for field (plan
8.7.4).

    python vecsum.py fpu.vec vecread.out
"""

import sys

MASK = (1 << 128) - 1


def sums(path):
    s = [0] * 17
    n = 0
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        f = line.split()
        n += 1
        s[1] += f[1] == 'C'
        for i in range(2, 17):
            s[i] = (s[i] + int(f[i], 16)) & MASK
    return n, s


def main(vec, vout):
    n, s = sums(vec)
    want = ['vectors %d' % n] + ['sum%d %032x' % (i, s[i]) for i in range(1, 17)]
    got = [l.strip() for l in open(vout) if l.startswith(('vectors', 'sum'))]
    if got == want:
        print('pass the Verilog reader (vecread.v) and the Python parser agree on all %d '
              'vectors, every field: %d' % (n, n))
        print('==== PASS: 1 checks')
        return 0
    print('FAIL the Verilog reader and the Python parser disagree')
    for a, b in zip(want, got):
        if a != b:
            print('     python %s / verilog %s' % (a, b))
    print('==== FAIL: 1 of 1 checks')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
