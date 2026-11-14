#!/usr/bin/env bash
# The ROM's blind SCSI read on the IIci's bus: tb_iici_machine with a
# program in the ROM's place and hs_forcer.v as the SCSI chip's CPU side.
#   DRQ_LAT  clk from DACK's fall to DRQ again (default 12)
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl
python - <<'PY' || exit 1
prog = bytes.fromhex(
  '00001000' '40800008'            # SSP, PC
  '41f950f06060'                   # LEA $50F06060,A0
  '43f900002000'                   # LEA $2000,A1
  '7207'                           # MOVEQ #7,D1
  '22d0'                           # MOVE.L (A0),(A1)+
  '51c9fffc'                       # DBRA D1,*-2
  '12d0' '12d0'                    # MOVE.B (A0),(A1)+ twice
  '5489'                           # ADDQ.L #2,A1
  '22fcdeadbeef'                   # MOVE.L #$DEADBEEF,(A1)+
  '20bca1a2a3a4'                   # MOVE.L #$A1A2A3A4,(A0): the blind write, four byte cycles
  '20bcb1b2b3b4'                   # MOVE.L #$B1B2B3B4,(A0)
  '60fe')                          # BRA *
rom = bytearray(524288); rom[:len(prog)] = prog
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
  "$RTL/se30_scc_chan.v" ../machine/scsi_idle.v "$RTL/iici_sdram.v" ../sdram/sdram_model.v ../iici/tb_iici_machine.v hs_forcer.v > vlog.log 2>&1 || { cat vlog.log; exit 1; }
"$MODELSIM/vsim.exe" -c -quiet -gSDRAM=0 -ghs_forcer/DRQ_LAT=${DRQ_LAT:-12} +CYCLES=4000 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_iici_machine work.hs_forcer > run.log 2>&1
grep -E '^# (---- the handshake|---- stopped by|      long|      then|      two long|==== HS)' run.log | sed 's/^# //'
grep -q '^# ==== HS PASS' run.log
