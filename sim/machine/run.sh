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
rom = bytearray(open(sys.argv[1], 'rb').read()); assert len(rom) in (262144, 524288), len(rom)
if sys.argv[3] == 'short' and len(rom) == 262144:
    # $408036F8 MOVE.L #$1FFFE,D3 -> #2; $4080370C BEQ.S ok -> BRA.S ok (bytes checked first)
    assert rom[0x36F8:0x36FE] == bytes.fromhex('263c0001fffe') and rom[0x370C:0x370E] == bytes.fromhex('6704'), 'not the 97221136 image'
    rom[0x36FA:0x36FE] = bytes.fromhex('00000002'); rom[0x370C] = 0x60
elif sys.argv[3] == 'short':
    # the IIci ROM ($368CADFE): $408446A0 MOVE.L #$3FFFE,D3 -> #2; $408446B4 BEQ.S ok -> BRA.S ok
    assert rom[0x446A0:0x446A6] == bytes.fromhex('263c0003fffe') and rom[0x446B4:0x446B6] == bytes.fromhex('6704'), 'not the 368CADFE image'
    rom[0x446A2:0x446A6] = bytes.fromhex('00000002'); rom[0x446B4] = 0x60
open('rom.hex', 'w').write(''.join('%02x%02x\n' % (rom[i], rom[i+1]) for i in range(0, len(rom), 2)))
d = open(sys.argv[2], 'rb').read(); assert len(d) == 8192, len(d)
open('declrom.hex', 'w').write(''.join('%02x\n' % b for b in d))
EOF

rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet +define+SIMULATION ${VLOGARGS:-} -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
  "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
  "${TG68K:-$RTL/tg68k/tg68k.v}" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/se30_glue.v" "$RTL/se30_via.v" "$RTL/se30_swim.v" "$RTL/se30_fdhd.v" "$RTL/se30_video.v" "$RTL/nubus_tfb.v" "$RTL/iicx_nuchip.v" "$RTL/se30_sdram.v" "$RTL/se30_machine.v" "$RTL/se30_simms.v" "$RTL/se30_pic1654.v" "$RTL/se30_adb_xcvr.v" "$RTL/se30_adb_dev.v" "$RTL/se30_rtc.v" "$RTL/se30_asc.v" "$RTL/se30_ncr53c80.v" "$RTL/se30_scsi.v" "$RTL/se30_scc.v" "$RTL/se30_scc_chan.v" scsi_idle.v \
  ../sdram/sdram_model.v tb_se30_machine.v || exit 1
T0=$(date +%s)
# TG68K: the wrapper to compile instead of rtl/tg68k/tg68k.v (ref_tg68k_berrlate.v, SE30_PLAN.md STAGE 1 DESIGN)
# IICX=1: the IIcx build (plan 14.3 step 4), logged to run_iicx.log
IICX=${IICX:-0}
LOG=run.log; [ "$IICX" = 1 ] && LOG=run_iicx.log
[ "${KCLK:-0}" = 1 ] && LOG=${LOG%.log}_kclk.log
# a 512 KB ROM image (the IIci's): GLUE's ROM address one bit wider, its own log
ROM_AW=16; [ $(stat -c %s "$ROM") = 524288 ] && { ROM_AW=17; LOG=${LOG%.log}_rom512.log; }
# RAM_SIZE (0-3 = 8/16/32/64 MB) and MODULE_MB (32/64/128), plan 13.6
RAM_SIZE=${RAM_SIZE:-0}; MODULE_MB=${MODULE_MB:-32}
[ "$RAM_SIZE" != 0 ] && LOG=run_ram${RAM_SIZE}_m${MODULE_MB}.log
"$MODELSIM/vsim.exe" -c -quiet -gIICX=$IICX -gKCLK=${KCLK:-0} -gROM_AW=$ROM_AW -gRAM_SIZE=$RAM_SIZE -gMODULE_MB=$MODULE_MB ${VSIMARGS:-} -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_machine > $LOG 2>&1
T1=$(date +%s)
grep -E '^# (---- |==== |FAIL |     )' $LOG | sed 's/^# //'
echo "---- ModelSim wall clock: $((T1 - T0)) s"
grep -q '^# ==== PASS' $LOG
