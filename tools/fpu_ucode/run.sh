#!/usr/bin/env bash
# The 68882 microcode's checks (plan 8.8.18-8.8.19).  Python 3; imports the
# reference model from ../fpu_model (the constant ROM, the redundant
# opmodes, the conditionals' table).  PYTHON: the interpreter, default
# `python`.
#
#   ./run.sh   test_asm.py (the formats, the constant ROM against the model,
#              the sample's round trip, every check broken on purpose); the
#              sample and the microcode assembled (out/); then vec.py - the
#              model's vectors (../fpu_model/out/fpu.vec, made by its
#              run.sh or `python vectors.py out/fpu.vec`) through the
#              microcode on the simulator - run.log
#
# Exit status is the verdict: a failing check, an assembly error, or a
# vector that fails (instructions not yet written are counted, not failed).
set -u
cd "$(dirname "$0")"
PY=${PYTHON:-python}
VEC=../fpu_model/out/fpu.vec
{
  "$PY" test_asm.py &&
  "$PY" asm.py tests/sample.uc -o out/sample &&
  "$PY" asm.py ucode/fpu.uc -o out/fpu &&
  if [ -f "$VEC" ]; then "$PY" vec.py --vec "$VEC"; else echo "no $VEC: run ../fpu_model/run.sh"; false; fi
} 2>&1 | tee run.log
exit "${PIPESTATUS[0]}"
