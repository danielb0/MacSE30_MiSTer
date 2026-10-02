#!/usr/bin/env bash
# Run tb_se30_system under ModelSim (Starter Edition, as shipped with Quartus
# Prime Lite 17.0).  Mixed-language: the kernel is VHDL, the wrapper, GLUE
# and the bench Verilog.  See the header of tb_se30_system.v.
#
#   MODELSIM  the win32aloem bin directory
#
# Three runs (the bench's header): plain - sim/kernel_bus's program, which
# gen_program.py writes there first; cacheon - the same with the cache
# enabled first, written to cacheon/; cachetest - gen_cache_program.py's,
# in cachetest/.  Logs run.log, run_cacheon.log, run_cachetest.log.
# Exit status: 0 when all three say "==== PASS".
set -u
cd "$(dirname "$0")"

MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
RTL=../../rtl

( cd ../kernel_bus && python gen_program.py --port 32 ) || exit 1
( cd ../kernel_bus && python gen_program.py --port 32 --cache --out ../system/cacheon ) || exit 1
python gen_cache_program.py || exit 1
rm -rf work
"$MODELSIM/vlib.exe" work >/dev/null || exit 1
for f in TG68K_Pack.vhd TG68K_ALU.vhd TG68K_PMMU_030.vhd TG68KdotC_Kernel.vhd; do
  "$MODELSIM/vcom.exe" -quiet -93 -work work "$RTL/tg68k/$f" || exit 1
done
"$MODELSIM/vlog.exe" -quiet -work work "$RTL/tg68k/tg68k.v" "$RTL/tg68k/se30_cache030.v" "$RTL/se30_glue.v" tb_se30_system.v || exit 1
ok=0
for run in plain cacheon cachetest; do
  case $run in
    plain)     log=run.log;           args="" ;;
    cacheon)   log=run_cacheon.log;   args="+PROG=cacheon +CACHEON" ;;
    cachetest) log=run_cachetest.log; args="+PROG=cachetest +CACHETEST" ;;
  esac
  "$MODELSIM/vsim.exe" -c -quiet $args -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" work.tb_se30_system > $log 2>&1
  echo "-- $run"
  grep -E '^# (---- |==== |FAIL )' $log | sed 's/^# //'
  grep -q '^# ==== PASS' $log || ok=1
done
exit $ok
