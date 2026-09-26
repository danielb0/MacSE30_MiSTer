#!/usr/bin/env bash
# Run tb_se30_machine under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, everything else
# Verilog.  See the header of tb_se30_machine.v.
#
#   MODELSIM  the win32aloem bin directory
#   ROM       the 256 KB SE/30 ROM image (the 97221136 image; not in the repo)
#   DECLROM   the 8 KB declaration ROM image, Apple 341-0650 (not in the repo)
#
# Both images are converted here (rom.hex: 16-bit big-endian words, one per
# line, for the SDRAM model's preload; declrom.hex: bytes) and are ignored
# by git.  Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
ROM=${ROM:-"/c/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM"}
DECLROM=${DECLROM:-/c/temp/Mac/ROMS/MacSE30/se30vrom.uk6}
RTL=../../rtl

python - "$ROM" "$DECLROM" <<'EOF' || exit 1
import sys
rom = open(sys.argv[1], 'rb').read(); assert len(rom) == 262144, len(rom)
open('rom.hex', 'w').write(''.join('%02x%02x\n' % (rom[i], rom[i+1]) for i in range(0, len(rom), 2)))
d = open(sys.argv[2], 'rb').read(); assert len(d) == 8192, len(d)
open('declrom.hex', 'w').write(''.join('%02x\n' % b for b in d))
EOF

rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet +define+SIMULATION -work work \
  "$RTL/tg68k/tg68k.v" "$RTL/se30_glue.v" "$RTL/se30_video.v" "$RTL/se30_sdram.v" "$RTL/se30_machine.v" \
  ../sdram/sdram_model.v tb_se30_machine.v || exit 1
T0=$(date +%s)
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_machine > run.log 2>&1
T1=$(date +%s)
grep -E '^# (---- |==== |FAIL |     )' run.log | sed 's/^# //'
echo "---- ModelSim wall clock: $((T1 - T0)) s"
grep -q '^# ==== PASS' run.log
