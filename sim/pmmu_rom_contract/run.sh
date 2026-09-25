#!/usr/bin/env bash
# Run tb_pmmu_rom_contract under ModelSim (Starter Edition, as shipped with
# Quartus Prime Lite 17.0).  Mixed-language: the PMMU is VHDL, the bench is
# Verilog.  See the header of tb_pmmu_rom_contract.v for what it proves.
#
#   TG68K_SRC  where TG68K_PMMU_030.vhd lives (default: the MacIIvi clone)
#   ROM        the $97221136 256KB ROM image (default: the ROMS folder)
#   MODELSIM   the win32aloem bin directory
#
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
TG68K_SRC=${TG68K_SRC:-/c/Git/MiSTer-devel/MacIIvi_MiSTer/rtl/tg68k}
ROM=${ROM:-"/c/temp/Mac/ROMS/256KB ROMs/1988-09 - 97221136 - Mac II FDHD & IIx & IIcx.ROM"}

cp "$ROM" se30.rom || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
# -93: upstream compiles the PMMU as VHDL-93 (their run_tests.do).
"$MODELSIM/vcom.exe" -quiet -93 -work work "$TG68K_SRC/TG68K_PMMU_030.vhd" || exit 1
"$MODELSIM/vlog.exe" -quiet -work work tb_pmmu_rom_contract.v || exit 1
# The PMMU carries `report ... severity note` on every register write; keep
# the transcript but show only the bench's own lines.
"$MODELSIM/vsim.exe" -c -quiet -do "run -all; quit -f" work.tb_pmmu_rom_contract > run.log 2>&1
# ModelSim prefixes every $display line with "# ".
grep -E '^# (---- |==== |pass |FAIL |walk  )' run.log | sed 's/^# //'
grep -q '^# ==== PASS' run.log
