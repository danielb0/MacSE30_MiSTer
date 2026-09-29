#!/usr/bin/env bash
# Run tb_se30_fpu_apu under Icarus Verilog (plan 8.9, item 7a).  See the
# header of tb_se30_fpu_apu.v for what it proves.  IVERILOG: the iverilog
# bin directory; PYTHON: the interpreter, default `python`.
#
#   ./run.sh [plusargs...]   e.g. +only=transcend, +first=100 +count=10,
#                            +trace=N (compare with rtlvec.py --trace N)
#
# First: the model's vectors (tools/fpu_model/out/fpu.vec) if missing; the
# microcode assembled afresh and compared with the images the RTL reads
# (rtl/fpu/ucode - a stale copy fails here: reassemble with
# `python asm.py ucode/fpu.uc -o ../../rtl/fpu/ucode` in tools/fpu_ucode);
# the simulator's clocks for every vector (rtlvec.py, out/fpu_rtl.vec).
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
PY=${PYTHON:-python}
UC=../../tools/fpu_ucode
MODEL=../../tools/fpu_model
mkdir -p out
if [ ! -f "$MODEL/out/fpu.vec" ]; then
  (cd "$MODEL" && "$PY" vectors.py out/fpu.vec) || exit 1
fi
"$PY" "$UC/asm.py" "$UC/ucode/fpu.uc" -o out/ucode > /dev/null || exit 1
for f in ucode.urom.hex ucode.nrom.hex ucode.entry.hex ucode.krom.hex fpu_ucode.vh; do
  if ! cmp -s "out/ucode/$f" "../../rtl/fpu/ucode/$f"; then
    echo "FAIL rtl/fpu/ucode/$f is not the assembled microcode"
    exit 1
  fi
done
if [ ! -f out/fpu_rtl.vec ] || [ "$MODEL/out/fpu.vec" -nt out/fpu_rtl.vec ] || \
   [ out/ucode/ucode.urom.hex -nt out/fpu_rtl.vec ]; then
  "$PY" "$UC/rtlvec.py" --vec "$MODEL/out/fpu.vec" -o out/fpu_rtl.vec || exit 1
fi
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -I ../../rtl/fpu -I ../../rtl/fpu/ucode \
  -o out/tb_se30_fpu_apu.vvp tb_se30_fpu_apu.v \
  ../../rtl/fpu/se30_fpu_apu.v ../../rtl/fpu/se30_fpu_unpack.v ../../rtl/fpu/se30_fpu_cond.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_fpu_apu.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
