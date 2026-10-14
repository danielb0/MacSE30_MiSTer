#!/usr/bin/env bash
# Run tb_insn_probe under ModelSim (Starter Edition, as shipped with Quartus Prime
# Lite 17.0): the jump-table loader's instructions (SE30_PLAN.md KNOWN
# ISSUES 20).  Mixed-language: the kernel is VHDL, the bench Verilog.
#   TRACE=1   print every bus beat to run.log
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl/tg68k
python gen_program.py || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work ${TRACE:+"+define+TRACE"} tb_insn_probe.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_insn_probe > run.log 2>&1
grep -E '^# (---- |==== |FAIL )' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
