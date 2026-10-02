#!/usr/bin/env bash
# Harness B of the cputest corpus (SE30_PLAN.md 8.9.8, 7e-4): run
# tools/cputest/harness_b.py's batches on tb_cpfpu - the 68030 kernel and
# the MC68882 under ModelSim - in parallel workers.
#
#   run_cputest.sh <batch dir> [workers]
#
# Each worker compiles the design once in sim/cpfpu_cpt<k> (the bench's ROM
# paths are relative: a worker sits at sim/cpfpu's depth) and runs its share of
# the batches there (prog_NN.hex -> program.hex, expect_NN.txt ->
# expect.txt); results in <batch dir>/run_NN.log and summary.txt.  Exit
# status 0 when every batch ends "==== PASS".
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
B=$(cd "$1" && pwd)
W=${2:-4}
NB=$(ls "$B"/prog_*.hex | wc -l)
worker() {
  k=$1; D=../cpfpu_cpt$k
  rm -rf "$D"; mkdir -p "$D"; cd "$D"
  RTL=../../rtl
  "$MODELSIM/vlib.exe" work > /dev/null || exit 1
  for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
    "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
  done
  "$MODELSIM/vlog.exe" -quiet +define+SIMULATION -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
    "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
    "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/se30_glue.v" ../cpfpu/tb_cpfpu.v || exit 1
  for ((i = k; i < NB; i += W)); do
    n=$(printf %02d $i)
    cp "$B/prog_$n.hex" program.hex; cp "$B/expect_$n.txt" expect.txt
    echo "00000000 00000000 ffffffff 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000" > inject.txt
    "$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" \
      work.tb_cpfpu > "$B/run_$n.log" 2>&1
    echo "$n $(grep -h '^# ==== ' "$B/run_$n.log" | sed 's/^# //')" >> "$B/summary.txt"
  done
}
rm -f "$B/summary.txt"
for ((k = 0; k < W; k++)); do (worker $k) & done
wait
sort "$B/summary.txt" -o "$B/summary.txt"
grep -c "==== PASS" "$B/summary.txt" | sed "s/^/batches passed: /; s/$/ of $NB/"
! grep -qv "==== PASS" "$B/summary.txt"
