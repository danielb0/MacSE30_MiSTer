#!/usr/bin/env bash
# Run tb_iici_machine under ModelSim (Starter Edition, Quartus Prime Lite
# 17.0): the kernel is VHDL, everything else Verilog.  See the header of
# tb_iici_machine.v.
#   MODELSIM  the win32aloem bin directory
#   ROM       the IIci ROM (368CADFE, 512 KB; not in the repo)
#   CHECKSUM  "short" (default) patches the ROM's checksum loop in the
#             bench's copy, as sim/machine does; "full" leaves it
#   CHIME     "short" (default) skips the boot chime in the bench's copy
#             (its body returns at once); "full" leaves it
#   CYCLES    the bus-cycle limit (default 200000)
# Exit status: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
ROM=${ROM:-"/c/temp/Mac/ROMS/512KB ROMs/1989-09 - 368CADFE - Mac IIci.ROM"}
CHECKSUM=${CHECKSUM:-short}
RTL=../../rtl
python - "$ROM" "$CHECKSUM" "${CHIME:-short}" <<'PY' || exit 1
import sys
rom = bytearray(open(sys.argv[1], 'rb').read()); assert len(rom) == 524288, len(rom)
if sys.argv[2] == 'short':
    # $408446A0 MOVE.L #$3FFFE,D3 -> #2; $408446B4 BEQ.S ok -> BRA.S ok
    assert rom[0x446A0:0x446A6] == bytes.fromhex('263c0003fffe') and rom[0x446B4:0x446B6] == bytes.fromhex('6704'), 'not the 368CADFE image'
    rom[0x446A2:0x446A6] = bytes.fromhex('00000002'); rom[0x446B4] = 0x60
if sys.argv[3] == 'short':
    # the boot chime ($4080706E, the body every chime entry runs, returning
    # through A6 at $40807156) -> JMP (A6); NOP: a second of sound is hours
    # of ModelSim, and its sound is not this bench's
    assert rom[0x706E:0x7072] == bytes.fromhex('422b0801') and rom[0x7156:0x7158] == bytes.fromhex('4ed6'), 'not the 368CADFE image'
    rom[0x706E:0x7072] = bytes.fromhex('4ed64e71')
open('rom.hex', 'w').write(''.join('%02x%02x\n' % (rom[i], rom[i+1]) for i in range(0, len(rom), 2)))
PY
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -sv +define+SIMULATION -work work +incdir+$RTL/fpu +incdir+$RTL/fpu/ucode \
  "$RTL/fpu/se30_fpu.v" "$RTL/fpu/se30_fpu_apu.v" "$RTL/fpu/se30_fpu_unpack.v" "$RTL/fpu/se30_fpu_cond.v" \
  "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/tg68k/se30_pace030.v" "$RTL/iici_mdu.v" "$RTL/iici_rbv.v" "$RTL/iici_machine.v" \
  "$RTL/se30_via.v" "$RTL/se30_swim.v" "$RTL/se30_fdhd.v" "$RTL/iicx_nuchip.v" "$RTL/se30_pic1654.v" "$RTL/se30_adb_xcvr.v" \
  "$RTL/se30_adb_dev.v" "$RTL/se30_rtc.v" "$RTL/se30_asc.v" "$RTL/se30_ncr53c80.v" "$RTL/se30_scsi.v" "$RTL/se30_scc.v" \
  "$RTL/se30_scc_chan.v" ../machine/scsi_idle.v tb_iici_machine.v > vlog.log 2>&1 || { cat vlog.log; exit 1; }
T0=$(date +%s)
"$MODELSIM/vsim.exe" -c -quiet ${VSIMARGS:-} -gPORTRAIT=${PORTRAIT:-0} +CYCLES=${CYCLES:-200000} -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_iici_machine > run.log 2>&1
T1=$(date +%s)
grep -E '^# (---- |==== |FAIL |      )' run.log | sed 's/^# //'
echo "---- ModelSim wall clock: $((T1 - T0)) s"
grep -q '^# ==== PASS' run.log
