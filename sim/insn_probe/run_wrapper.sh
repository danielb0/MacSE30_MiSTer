#!/usr/bin/env bash
# Run the instruction probe through the whole CPU path - the tg68k wrapper
# (prefetch, pacing, the posted-write buffer, the caches), GLUE and the
# SIMMs - on sim/predec_fault's harness: the program and expect.txt from
# here (+PROG), which the bare-kernel run.sh checks too.
#   CACR      the cache control register the program loads first (default 0)
#   MODELSIM  the win32aloem bin directory
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl
CACR=${CACR:-0} python gen_program.py || exit 1
rm -rf work_w
"$MODELSIM/vlib.exe" work_w >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work_w "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work_w "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_simms.v" "$RTL/dbg_jtrace.v" ../predec_fault/tb_predec_fault.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet +PROG=. "$@" -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work_w.tb_predec_fault > run_wrapper.log 2>&1
grep -E '^# (---- [0-9]|==== |FAIL)' run_wrapper.log | sed 's/^# //'
grep -q '^# ==== PASS' run_wrapper.log
