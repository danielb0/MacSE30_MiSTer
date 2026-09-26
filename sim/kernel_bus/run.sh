#!/usr/bin/env bash
# Run tb_kernel_bus under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the bench Verilog.
# See the header of tb_kernel_bus.v for what it proves.
#
#   PORT      the port width the expected beats are for: 16 (default), 32, 8
#   BF5=0     leave the five-byte bit fields out (see gen_program.py)
#   MODELSIM  the win32aloem bin directory
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
PORT=${PORT:-16}
RTL=../../rtl/tg68k

python gen_program.py --port "$PORT" $( [ "${BF5:-1}" = 0 ] && echo --no-bf5 ) || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
# -93: upstream compiles the kernel as VHDL-93 (their Makefile).
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work tb_kernel_bus.v || exit 1
# the numeric warnings are the kernel's own on undefined inputs at reset
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_kernel_bus > run.log 2>&1
# ModelSim prefixes every $display line with "# ".
grep -E '^# (---- |==== |FAIL )' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
