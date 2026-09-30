#!/usr/bin/env bash
# Run tb_se30_machine under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, everything else
# Verilog.  See the header of tb_se30_machine.v.
#
#   MODELSIM  the win32aloem bin directory
#   ROM       the 256 KB SE/30 ROM image (the 97221136 image; not in the repo)
#   DECLROM   the 8 KB declaration ROM image, Apple 341-0650 (not in the repo)
#   CHECKSUM  "short" (the default) patches the ROM's checksum loop, in the
#             bench's copy only, to two iterations with its verdict forced
#             to "passed" - the real loop is 524,280 bus cycles, 130 ms, an
#             hour and more of ModelSim (plan 3.8 item 17, 4.9); "full"
#             leaves the image as it is.
#
# Both images are converted here (rom.hex: 16-bit big-endian words, one per
# line, for the SDRAM model's preload; declrom.hex: bytes) and are ignored
# by git.  Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
ROM=${ROM:-"/c/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM"}
DECLROM=${DECLROM:-/c/temp/Mac/ROMS/MacSE30/se30vrom.uk6}
CHECKSUM=${CHECKSUM:-short}
RTL=../../rtl

python - "$ROM" "$DECLROM" "$CHECKSUM" <<'EOF' || exit 1
import sys
rom = bytearray(open(sys.argv[1], 'rb').read()); assert len(rom) == 262144, len(rom)
if sys.argv[3] == 'short':
    # $408036F8 MOVE.L #$1FFFE,D3 -> #2; $4080370C BEQ.S ok -> BRA.S ok (bytes checked first)
    assert rom[0x36F8:0x36FE] == bytes.fromhex('263c0001fffe') and rom[0x370C:0x370E] == bytes.fromhex('6704'), 'not the 97221136 image'
    rom[0x36FA:0x36FE] = bytes.fromhex('00000002'); rom[0x370C] = 0x60
open('rom.hex', 'w').write(''.join('%02x%02x\n' % (rom[i], rom[i+1]) for i in range(0, len(rom), 2)))
d = open(sys.argv[2], 'rb').read(); assert len(d) == 8192, len(d)
open('declrom.hex', 'w').write(''.join('%02x\n' % b for b in d))
EOF

rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet +define+SIMULATION -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
  "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
  "$RTL/tg68k/tg68k.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_swim.v" "$RTL/se30_fdhd.v" "$RTL/se30_video.v" "$RTL/se30_sdram.v" "$RTL/se30_machine.v"   "$RTL/se30_pic1654.v" "$RTL/se30_adb_xcvr.v" "$RTL/se30_adb_dev.v" "$RTL/se30_rtc.v" "$RTL/se30_asc_stub.v" \
  ../sdram/sdram_model.v tb_se30_machine.v || exit 1
T0=$(date +%s)
"$MODELSIM/vsim.exe" -c -quiet -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_machine > run.log 2>&1
T1=$(date +%s)
grep -E '^# (---- |==== |FAIL |     )' run.log | sed 's/^# //'
echo "---- ModelSim wall clock: $((T1 - T0)) s"
grep -q '^# ==== PASS' run.log
