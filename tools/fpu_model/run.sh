#!/usr/bin/env bash
# The 68882 reference model's checks (plan 8.7).  Python 3 and mpmath
# (pip install --user mpmath; the model itself needs only the standard
# library).  PYTHON: the interpreter, default `python`.
#
#   ./run.sh          check_tables.py (the manual's tables),
#                     check_rounding.py 400 (mpmath, about 15 s) and
#                     check_packed.py 2000 (packed decimal) and
#                     check_transcend.py 1000 (the transcendentals), then
#                     the test vectors for the RTL (vectors.py, out/fpu.vec),
#                     replayed through the model (replay.py) and read by
#                     Icarus (vecread.v; vecsum.py compares) - run.log
#   ./run.sh quick    the same with 15 operands a range
#   ./run.sh mutate   mutate.py: every documented fault must be caught -
#                     mutate.log
#
# Exit status is the verdict: 0 when every part prints "==== PASS".
# IVERILOG: the iverilog bin directory.
set -u
cd "$(dirname "$0")"
PY=${PYTHON:-python}
IVERILOG=${IVERILOG:-/c/iverilog/bin}
if [ "${1:-}" = mutate ]; then
  "$PY" mutate.py | tee mutate.log
  grep -q '^==== PASS' mutate.log
  exit $?
fi
N=400; NP=2000; NT=1000
[ "${1:-}" = quick ] && { N=15; NP=150; NT=100; }
mkdir -p out
{ "$PY" check_tables.py; "$PY" check_rounding.py "$N"; "$PY" check_packed.py "$NP"
  "$PY" check_transcend.py "$NT"
  "$PY" vectors.py out/fpu.vec && "$PY" replay.py out/fpu.vec
  "$IVERILOG/iverilog.exe" -g2005 -o out/vecread.vvp vecread.v &&
    "$IVERILOG/vvp.exe" -n out/vecread.vvp +vec=out/fpu.vec > out/vecread.out &&
    "$PY" vecsum.py out/fpu.vec out/vecread.out; } | tee run.log
[ "$(grep -c '^==== PASS' run.log)" = 6 ]
