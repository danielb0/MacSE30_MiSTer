#!/usr/bin/env bash
# Run upstream's own kernel benches (apolkosnik/Minimig-AGA_MiSTer@030_mmu2,
# tests/tg68k_030/) against the kernel in THIS tree, under ModelSim - the
# safety net for every kernel change (SE30_PLAN.md 1.13, 1.15).  Their suite
# is make-driven and there is no make here, so this replays the recipe every
# target uses: compile the four kernel files -93, compile the bench, run it
# for the time the Makefile gives it.  A bench passes when its transcript
# holds no "** Error" or "** Failure" report and no FAIL line other than a
# "0 failed" summary.
#
#   run.sh                 every bench in suite.txt
#   run.sh tb_x [time]     one bench
#
#   RTL       the kernel directory (default ../../rtl/tg68k; point it at the
#             upstream clone's rtl/tg68k for the baseline)
#   TESTS     upstream's tests/tg68k_030 (default: the clone)
#   MODELSIM  the win32aloem bin directory
#
# Results go to results/<tb>.log; the summary line per bench is printed.
# Exit status 0 when every bench passes.
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=${RTL:-../../rtl/tg68k}
TESTS=${TESTS:-/c/Git/MiSTer-devel/Minimig-AGA_MiSTer_030_mmu2/tests/tg68k_030}
mkdir -p results

compile_kernel() {
  rm -rf work
  "$MODELSIM/vlib.exe" work >/dev/null || exit 1
  for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
    "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/$f" || exit 1
  done
}

run_one() {
  local tb=$1 t=$2 log=results/$1.log
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$TESTS/$tb.vhd" > "$log" 2>&1 || { echo "$tb: COMPILE FAILED"; return 1; }
  "$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run $t; quit -f" work.$tb >> "$log" 2>&1
  local bad
  # severity error/failure reports, or a FAIL line that is not a "0 failed" summary
  bad=$(grep -E '\*\* (Error|Failure)|FAIL' "$log" | grep -v -E '0 FAILED|FAILED: 0|failed=0|0 failed' | grep -c .)
  if [ "$bad" = 0 ]; then echo "$tb: pass"; return 0; else echo "$tb: FAIL ($bad lines)"; return 1; fi
}

compile_kernel
status=0
if [ $# -ge 1 ]; then
  run_one "$1" "${2:-2ms}" || status=1
else
  while read -r tb t; do
    case "$tb" in ''|\#*) continue;; esac
    run_one "$tb" "$t" || status=1
  done < suite.txt
fi
exit $status
