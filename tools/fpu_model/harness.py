"""The checks' reporting, in the benches' style: a `pass`/`FAIL` line per
check (with its count, and the first few mismatches on a failure), and a
final `==== PASS: n checks` or `==== FAIL: k of n checks`; the exit status
is the verdict."""


class Checks:
    def __init__(self):
        self.n = 0
        self.failed = 0

    def check(self, what, ok, count='', detail=()):
        self.n += 1
        if ok:
            print('pass %s: %s' % (what, count), flush=True)
        else:
            self.failed += 1
            print('FAIL %s: %s' % (what, count), flush=True)
            for d in detail:
                print('     %s' % d, flush=True)

    def section(self, title):
        print('---- %s' % title, flush=True)

    def summary(self):
        if self.failed:
            print('==== FAIL: %d of %d checks' % (self.failed, self.n), flush=True)
            return 1
        print('==== PASS: %d checks' % self.n, flush=True)
        return 0
