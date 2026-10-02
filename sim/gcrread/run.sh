#!/usr/bin/env bash
# Run tb_se30_gcrread under Icarus Verilog: the GCR read gate (plan 5.12.9
# item 6, 5.12.12 item 6), with both drives (5.14).  See the header of
# tb_se30_gcrread.v for what it proves.  IVERILOG: the iverilog bin
# directory.
#
#   ./run.sh          the gate: two runs, one after the other (never in
#                     parallel - each slows the other several times over)
#                     1. every cylinder of both drives, the 400K and
#                        Disk605.dsk parts, on the behavioural clk_sys memory
#                        (-DBEHAV_MEM) - about six hours; run.log
#                     2. the real controller on sim/sdram's chip model: Open,
#                        both loads, the recalibrates and a cylinder of each
#                        speed group on both drives (+groups +no56) - about
#                        four hours; run_sdram.log
#   ./run.sh quick    run 1 with +quick (both edges of each group) only
#
# Progress, and every check as it is made, go to prog.txt (flushed; Icarus
# buffers stdout).  Exit status is the verdict: 0 when every run prints
# "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
R=../../rtl
RTL="$R/se30_glue.v $R/se30_via.v $R/se30_swim.v $R/se30_fdhd.v $R/se30_flp_loader.v $R/se30_flp_encoder.v $R/se30_flp_dkmux.v"
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -DBEHAV_MEM -o out/tb_behav.vvp tb_se30_gcrread.v $RTL || exit 1
if [ "${1:-}" = quick ]; then
  "$IVERILOG/vvp.exe" -n out/tb_behav.vvp +quick | tee run.log
  grep -q '^==== PASS' run.log
  exit $?
fi
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -o out/tb_sdram.vvp tb_se30_gcrread.v \
  ../sdram/sdram_model.v $R/se30_sdram.v $RTL || exit 1
ok=0
"$IVERILOG/vvp.exe" -n out/tb_behav.vvp | tee run.log
grep -q '^==== PASS' run.log || ok=1
"$IVERILOG/vvp.exe" -n out/tb_sdram.vvp +groups +no56 | tee run_sdram.log
grep -q '^==== PASS' run_sdram.log || ok=1
exit $ok
