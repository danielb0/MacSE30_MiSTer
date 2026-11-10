#!/usr/bin/env bash
# The NetBSD readdisklabel replay (tb_wsfb_replay.v, gen_replay.py; the
# X11/WSFB investigation, 2026-11-09).
#
#   run.sh [vsim args...]          e.g. run.sh +trace
#
# KERNEL: the decompressed netbsd-WSFBSBC (from NetBSD-11.1-mac68k.iso's
# mac68k/binary/kernel); DISK: the raw NetBSD disk image (sd1); GEN: extra
# gen_replay.py options (--cacr 0 for the caches off).
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl
: "${KERNEL:?set KERNEL to the decompressed netbsd-WSFBSBC}"
: "${DISK:?set DISK to the NetBSD disk image}"

python gen_replay.py "$KERNEL" "$DISK" ${GEN:-} || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_simms.v" "$RTL/dbg_jtrace.v" tb_wsfb_replay.v || exit 1
"$MODELSIM/vsim.exe" -c -quiet "$@" -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_wsfb_replay > run.log 2>&1
grep -E '^# (---- |==== |FAIL)' run.log | sed 's/^# //'

grep -q '^# ==== PASS' run.log
