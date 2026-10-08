#!/usr/bin/env bash
# Run tb_mmu16 under ModelSim (its header): the ROM's mod-3 RAM test above
# 8 MB through the PMMU in 32-bit mode.  Extra arguments go to vsim as
# plusargs (e.g. +BTLO=00DD6000 +BTHI=00DD6100, +NOPOST).  About 30 min
# (seven regions; MMU16_RUNS="start:end:mode,..." picks others).
# gen_mode32.py's program (MODE32 7.5's own RAM sizing) runs on the same
# build with +PROG=mode32 in seconds.
#
#   MODELSIM  the win32aloem bin directory
#   ROM       the 256 KB SE/30 ROM image (the 97221136 image; not in the repo)
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

python gen_program.py || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_simms.v" tb_mmu16.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet "$@" -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_mmu16 > run.log 2>&1
grep -E '^# (---- |==== |FAIL)' run.log | sed 's/^# //'
python check.py
grep -q '^# ==== PASS' run.log
