#!/usr/bin/env bash
# Run tb_busfault_dib under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the rest Verilog.
# See the header of tb_busfault_dib.v for what it proves.
#
#   INSTR     cmp (default): MODE32's check, CMP.L $38(A6),D6 - the board's
#             loop; move: the ROM's own, MOVE.L $38(A6),D0; write: MOVE.L
#             D6,$38(A6) with a handler that says it did the write (an open
#             item, SE30_PLAN.md 1.18.4: fails on both kernels, not in the gate)
#   HANDLER   zero (default): the ROM's $4080E590, clr.l the DIB; ones: its
#             $4080E59C, moveq #-1
#   VARIANT   board (default): the board's misaligned read; aligned: one long cycle
#   MMU=1 CACHE=1  the board's translation and caches (gen_program.py)
#   SP        the initial SSP, hex (default 8000; 7FFE: word-aligned)
#   PLUSARGS=+ipl  a masked level-2 interrupt pending throughout
#   MODELSIM  the win32aloem bin directory
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

python gen_program.py "${VARIANT:-board}" || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" tb_busfault_dib.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" ${PLUSARGS:-} work.tb_busfault_dib > run.log 2>&1
grep -E '^# (---- |==== |FAIL |pass |     \+)' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
