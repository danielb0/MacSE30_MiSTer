#!/usr/bin/env bash
# KNOWN ISSUES 64: compile the system bench and run only the lane test
# (gen_lane_program.py + tb_se30_system.v's +LANETEST).  Log run_lanetest.log.
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl
python gen_lane_program.py || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_video.v" tb_se30_system.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet +PROG=lanetest +LANETEST -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_system > run_lanetest.log 2>&1
grep -E '^# (---- |==== |FAIL )' run_lanetest.log | sed 's/^# //'
grep -q '^# ==== PASS' run_lanetest.log
