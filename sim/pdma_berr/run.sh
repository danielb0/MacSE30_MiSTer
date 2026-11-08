#!/usr/bin/env bash
# Run tb_pdma_berr under ModelSim (as sim/busfault_dib).  K=n (default 18):
# the bytes the target sends before DRQ stops; K=all sweeps 0-32.
# Exit status: 0 when every run printed "==== PASS".
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
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" tb_pdma_berr.v || exit 1
KS=${K:-18}; [ "$KS" = all ] && KS=$(seq 0 32)
rc=0; : > run.log
for k in $KS; do
  "$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" +K=$k work.tb_pdma_berr > run_k.log 2>&1
  cat run_k.log >> run.log
  grep -E '^# (---- |==== |FAIL )' run_k.log | sed 's/^# //'
  grep -q '^# ==== PASS' run_k.log || rc=1
done
rm -f run_k.log
exit $rc
