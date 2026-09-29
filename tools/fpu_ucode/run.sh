#!/usr/bin/env bash
# The 68882 microcode assembler's checks (plan 8.8.18).  Python 3; imports
# the reference model from ../fpu_model for the constant ROM and the
# redundant opmodes.  PYTHON: the interpreter, default `python`.
#
#   ./run.sh      test_asm.py (the formats, the constant ROM against the
#                 model, the sample's round trip, every check broken on
#                 purpose), then the sample assembled to out/sample - run.log
#
# Exit status is the verdict.
set -u
cd "$(dirname "$0")"
PY=${PYTHON:-python}
{
  "$PY" test_asm.py && "$PY" asm.py tests/sample.uc -o out/sample
} 2>&1 | tee run.log
exit "${PIPESTATUS[0]}"
