#!/usr/bin/env bash
# Run tb_busfault under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the rest Verilog.
# See the header of tb_busfault.v for what it proves.
#
#   N         the handler's retry count (default 3; the ROM uses 100)
#   WRITE=1   the probe writes instead of reading (KNOWN ISSUES 7)
#   MODELSIM  the win32aloem bin directory
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

python gen_program.py "${N:-3}" "$([ "${WRITE:-0}" = 1 ] && echo write || echo read)" || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" tb_busfault.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_busfault > run.log 2>&1
grep -E '^# (---- |==== |FAIL |pass |     \+)' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
