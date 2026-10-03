#!/usr/bin/env bash
# Run tb_se30_scc under Icarus Verilog - the 8530 SCC against Zilog's 1986
# manual and the SE/30's own use of it (SE30_PLAN.md 10.5.4 item 1).  See
# the bench's header.  Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb.vvp tb_se30_scc.v ../../rtl/se30_scc.v ../../rtl/se30_scc_chan.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
