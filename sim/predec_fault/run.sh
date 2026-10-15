#!/usr/bin/env bash
# Run tb_predec_fault under ModelSim (its header): MOVE.L -(A0),-(A1) - the
# ROM's BlockMove loop - page-faulting mid-instruction through the PMMU and
# resumed by RTE (KNOWN ISSUES 20).  Extra arguments go to vsim as plusargs
# (e.g. +BTLO=00031FF0 +BTHI=00032000).  About 15-20 min a run.
#
#   CACR      the cache control register for the run (default 0)
#   SDRAM     1: the board's memory path - rtl/se30_sdram.v and the chip
#             model (sim/sdram) in place of the bench's RAM array
#   RTRACE    1 (with SDRAM=1): the board's replay trace (rtl/dbg_rtrace.v)
#             on the bench's taps; every replay's three levels must agree
#   MODELSIM  the win32aloem bin directory
#   ROM       the 256 KB SE/30 ROM image (the loop is copied from it)
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
SD=(); [ "${SDRAM:-0}" = 1 ] && SD=(+define+SDRAM +define+SIMULATION "$RTL/se30_sdram.v" ../sdram/sdram_model.v)
# RTRACE=1 (with SDRAM=1): the board's replay trace, rtl/dbg_rtrace.v, checked at the end
[ "${RTRACE:-0}" = 1 ] && SD+=(+define+RTRACE "$RTL/dbg_rtrace.v")
"$MODELSIM/vlog.exe" -quiet -work work "${SD[@]}" "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_simms.v" tb_predec_fault.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet "$@" -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_predec_fault > run.log 2>&1
grep -E '^# (---- |==== |FAIL)' run.log | sed 's/^# //'

grep -q '^# ==== PASS' run.log
