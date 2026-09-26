#!/usr/bin/env bash
# Run tb_se30_system under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the wrapper, GLUE
# and the bench Verilog.  See the header of tb_se30_system.v.
#
#   MODELSIM  the win32aloem bin directory
#
# The program is sim/kernel_bus's; gen_program.py writes it there first.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

( cd ../kernel_bus && python gen_program.py --port 32 ) || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/se30_glue.v" tb_se30_system.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_system > run.log 2>&1
grep -E '^# (---- |==== |FAIL )' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
