#!/usr/bin/env bash
# Run tb_cpfpu under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0): the kernel (VHDL), the wrapper, GLUE and the MC68882
# (Verilog) on the 68030 bus, running gen_program.py's FPU program.  See
# the header of tb_cpfpu.v (plan 8.9.4, item 7d).
#
#   MODELSIM  the win32aloem bin directory
#   PROG      the program: b1 (stage B1, the default), b2, b3a, b3b, b3c, b4
#             or full
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

python gen_program.py "${PROG:-b1}" || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet +define+SIMULATION -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
  "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
  "$RTL/tg68k/tg68k.v" "$RTL/se30_glue.v" tb_cpfpu.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_cpfpu > run.log 2>&1
grep -E '^# (---- |==== |FAIL|** Error|** Fatal)' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
