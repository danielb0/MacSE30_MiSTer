#!/usr/bin/env bash
# The 68030 integer corpus (SE30_PLAN.md 1.18.6): run tools/cputest/
# harness_i.py's batches on tb_cpu_int - the kernel, the wrapper and GLUE -
# under ModelSim, in parallel workers.
#
#   run.sh <batch dir> [workers]
#
# Each worker compiles the design once in sim/cputest_int/w<k> and runs its
# share of the batches there (prog_NNN.hex -> program.hex, expect_NNN.txt
# -> expect.txt); results in <batch dir>/run_NNN.log and summary.txt, one
# line per batch.  Exit status 0 when every batch ends "==== PASS".
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
B=$(cd "$1" && pwd)
W=${2:-8}
NB=$(ls "$B"/prog_*.hex | wc -l)
worker() {
  k=$1; D=w$k
  rm -rf "$D"; mkdir -p "$D"; cd "$D"
  RTL=../../../rtl
  "$MODELSIM/vlib.exe" work > /dev/null || exit 1
  for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
    "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
  done
  "$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" \
    "$RTL/se30_glue.v" ../tb_cpu_int.v || exit 1
  for ((i = k; i < NB; i += W)); do
    n=$(printf %03d $i)
    cp "$B/prog_$n.hex" program.hex; cp "$B/expect_$n.txt" expect.txt
    "$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" \
      work.tb_cpu_int > "$B/run_$n.log" 2>&1
    echo "$n $(grep -h '^# ==== ' "$B/run_$n.log" | sed 's/^# //')" >> "$B/summary.txt"
  done
}
rm -f "$B/summary.txt"
for ((k = 0; k < W; k++)); do (worker $k) & done
wait
sort "$B/summary.txt" -o "$B/summary.txt"
grep -c "==== PASS" "$B/summary.txt" | sed "s/^/batches passed: /; s/$/ of $NB/"
! grep -qv "==== PASS" "$B/summary.txt"
