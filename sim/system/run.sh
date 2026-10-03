#!/usr/bin/env bash
# Run tb_se30_system under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the wrapper, GLUE
# and the bench Verilog.  See the header of tb_se30_system.v.
#
#   MODELSIM  the win32aloem bin directory
#
# Eight runs (the bench's header): plain - sim/kernel_bus's program, which
# gen_program.py writes there first; cacheon - the same with both caches
# enabled first, in cacheon/; cachewa - with WA too, in cachewa/;
# cachetest - gen_cache_program.py's, in cachetest/; vramtest -
# gen_vram_program.py's video-RAM measurement, in vramtest/; berrtest -
# gen_berr_program.py's SCSI handshake bus errors, in berrtest/; timetest -
# gen_time_program.py's timing windows, in timetest/ (report_time.py prints
# them against the MC68030 UM); clrtest - gen_clr_program.py's CLR, Scc and
# MOVE from SR/CCR, in clrtest/.  Logs run.log and run_<name>.log.  Exit
# status: 0 when all eight say "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

( cd ../kernel_bus && python gen_program.py --port 32 ) || exit 1
( cd ../kernel_bus && python gen_program.py --port 32 --cache 0x0101 --out ../system/cacheon ) || exit 1
( cd ../kernel_bus && python gen_program.py --port 32 --cache 0x2101 --out ../system/cachewa ) || exit 1
python gen_cache_program.py || exit 1
python gen_vram_program.py || exit 1
python gen_berr_program.py || exit 1
python gen_time_program.py || exit 1
python gen_clr_program.py || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/se30_glue.v" "$RTL/se30_video.v" tb_se30_system.v || exit 1
ok=0
for run in plain cacheon cachewa cachetest vramtest berrtest timetest clrtest; do
  case $run in
    plain)     log=run.log;           args="" ;;
    cacheon)   log=run_cacheon.log;   args="+PROG=cacheon +CACHEON" ;;
    cachewa)   log=run_cachewa.log;   args="+PROG=cachewa +CACHEON" ;;
    cachetest) log=run_cachetest.log; args="+PROG=cachetest +CACHETEST" ;;
    vramtest)  log=run_vramtest.log;  args="+PROG=vramtest +VRAMTEST" ;;
    berrtest)  log=run_berrtest.log;  args="+PROG=berrtest +BERRTEST" ;;
    timetest)  log=run_timetest.log;  args="+PROG=timetest +TIMETEST" ;;
    clrtest)   log=run_clrtest.log;   args="+PROG=clrtest +CLRTEST" ;;
  esac
  "$MODELSIM/vsim.exe" -c -quiet $args -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_system > $log 2>&1
  echo "-- $run"
  grep -E '^# (---- |==== |FAIL )' $log | sed 's/^# //'
  grep -q '^# ==== PASS' $log || ok=1
done
python report_time.py
exit $ok
