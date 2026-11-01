#!/usr/bin/env bash
# Run tb_via_race under Icarus Verilog (class 9: the IFR against an access at
# every point around each event).  Extra arguments go to vvp as plusargs
# (+RACE_PLANT: a planted lost event, which must FAIL).
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_via_race.vvp tb_via_race.v ../../rtl/se30_via.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_via_race.vvp "$@" > race.log
grep -E '^(----|====|FAIL)' race.log
grep -q '^==== PASS' race.log
