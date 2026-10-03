#!/usr/bin/env bash
# Run tb_se30_asc under Icarus Verilog - the ASC against its specification
# and System 7.5.5's use of it (SE30_PLAN.md 11.4 item 1).  Exit status is
# the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb.vvp tb_se30_asc.v ../../rtl/se30_asc.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
