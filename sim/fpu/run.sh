#!/usr/bin/env bash
# Run the FPU benches under Icarus Verilog (plan 8.9).  BENCH=chip (the
# default): tb_se30_fpu, items 7b-7c - the whole chip through its pins;
# BENCH=apu: tb_se30_fpu_apu, item 7a - the APU alone, with +trace.  See
# each bench's header for what it proves.  IVERILOG: the iverilog bin
# directory; PYTHON: the interpreter, default `python`.
#
#   ./run.sh [plusargs...]   e.g. +only=transcend, +first=100 +count=10,
#                            +directed_only, +detour (chip: a context
#                            switch inside every vector), +pairs=2|3 (chip:
#                            each vector with one or two others issued
#                            without waiting, against one at a time - 7e),
#                            +trace=N (apu: compare
#                            with rtlvec.py --trace N)
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
BENCH=${BENCH:-chip}
UC=../../tools/fpu_ucode
MODEL=../../tools/fpu_model
mkdir -p out
if [ ! -f "$MODEL/out/fpu.vec" ]; then
  (cd "$MODEL" && "$PY" vectors.py out/fpu.vec) || exit 1
fi
"$PY" "$UC/asm.py" "$UC/ucode/fpu.uc" -o out/ucode > /dev/null || exit 1
for f in ucode.urom.hex ucode.nrom.hex ucode.entry.hex ucode.krom.hex ucode.nsel.hex ucode.cvt.hex ucode.cvsel.hex ucode.tadj.hex fpu_ucode.vh; do
  if ! cmp -s "out/ucode/$f" "../../rtl/fpu/ucode/$f"; then
    echo "FAIL rtl/fpu/ucode/$f is not the assembled microcode"
    exit 1
  fi
done
if [ ! -f out/fpu_rtl.vec ] || [ "$MODEL/out/fpu.vec" -nt out/fpu_rtl.vec ] || \
   [ ../../rtl/fpu/ucode/ucode.urom.hex -nt out/fpu_rtl.vec ]; then
  "$PY" "$UC/rtlvec.py" --vec "$MODEL/out/fpu.vec" -o out/fpu_rtl.vec || exit 1
fi
RTL="../../rtl/fpu/se30_fpu_apu.v ../../rtl/fpu/se30_fpu_unpack.v ../../rtl/fpu/se30_fpu_cond.v"
if [ "$BENCH" = apu ]; then TB=tb_se30_fpu_apu; else TB=tb_se30_fpu; RTL="../../rtl/fpu/se30_fpu.v $RTL"; fi
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -I ../../rtl/fpu -I ../../rtl/fpu/ucode   -o out/$TB.vvp $TB.v $RTL || exit 1
"$IVERILOG/vvp.exe" -n out/$TB.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
