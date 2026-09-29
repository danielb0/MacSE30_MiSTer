#!/usr/bin/env bash
# The 68882 reference model's checks (plan 8.7).  Python 3 and mpmath
# (pip install --user mpmath; the model itself needs only the standard
# library).  PYTHON: the interpreter, default `python`.
#
#   ./run.sh          check_tables.py (the manual's tables) and
#                     check_rounding.py 400 (mpmath, about 15 s) - run.log
#   ./run.sh quick    the same with 15 operands a range
#   ./run.sh mutate   mutate.py: every documented fault must be caught -
#                     mutate.log
#
# Exit status is the verdict: 0 when every part prints "==== PASS".
set -u
cd "$(dirname "$0")"
PY=${PYTHON:-python}
if [ "${1:-}" = mutate ]; then
  "$PY" mutate.py | tee mutate.log
  grep -q '^==== PASS' mutate.log
  exit $?
fi
N=400
[ "${1:-}" = quick ] && N=15
{ "$PY" check_tables.py; "$PY" check_rounding.py "$N"; } | tee run.log
[ "$(grep -c '^==== PASS' run.log)" = 2 ]
