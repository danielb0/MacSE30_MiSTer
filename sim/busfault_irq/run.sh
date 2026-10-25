#!/usr/bin/env bash
# Run tb_busfault_irq under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  See the header of tb_busfault_irq.v for what it proves.
#
#   SHAPE, HMODE, MMU, CACHE, PAD   the program (gen_program.py)
#   PLUSARGS   +EVT (the reference's events), +OFFS (offsets.txt),
#              +LEVEL=n (1, 2 or 4), +PLANT=k
#   IICX=1     the IIcx's GLUE and NuChip: an empty slot is a NuBus timeout
#   NOCOMPILE=1  reuse work/ (the sweep compiles once per directory)
#   MODELSIM   the win32aloem bin directory
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=${RTL:-../../rtl}

python gen_program.py || exit 1
if [ "${NOCOMPILE:-0}" != 1 ]; then
  rm -rf work
  "$MODELSIM/vlib.exe" work >/dev/null || exit 1
  for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
    "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
  done
  DEFS=""; [ "${IICX:-0}" = 1 ] && DEFS="+define+IICX"
  "$MODELSIM/vlog.exe" -quiet -work work $DEFS "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/iicx_nuchip.v" tb_busfault_irq.v || exit 1
fi
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" ${PLUSARGS:-} work.tb_busfault_irq > run.log 2>&1
grep -E '^# (---- |==== |FAIL |EVT |NOTE )' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
