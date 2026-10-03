#!/usr/bin/env bash
# Run tb_scc_seam under Icarus Verilog - GLUE and the 8530 (SE30_PLAN.md
# 10.5.4 item 2).  Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb.vvp tb_scc_seam.v ../../rtl/se30_glue.v ../../rtl/se30_scc.v ../../rtl/se30_scc_chan.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
