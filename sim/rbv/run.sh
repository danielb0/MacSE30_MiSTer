#!/usr/bin/env bash
# Run tb_iici_rbv under Icarus Verilog.  See the header of tb_iici_rbv.v.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
# both monitors: the 640 x 480 (run.log) and the Portrait Display (run_portrait.log)
ok=0
for P in 0 1; do
  LOG=run.log; [ $P = 1 ] && LOG=run_portrait.log
  "$IVERILOG/iverilog.exe" -g2012 -P tb_iici_rbv.PORTRAIT=$P -o out/tb_iici_rbv_$P.vvp tb_iici_rbv.v ../../rtl/iici_rbv.v || exit 1
  echo "---- PORTRAIT=$P"
  "$IVERILOG/vvp.exe" -n out/tb_iici_rbv_$P.vvp | tee $LOG
  grep -q '^==== PASS' $LOG || ok=1
done
exit $ok
