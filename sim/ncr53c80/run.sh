#!/usr/bin/env bash
# Run tb_se30_ncr53c80 under Icarus Verilog - the 53C80 against NCR's
# SP-1051 manual (SE30_PLAN.md 9.6 item 1).  See the bench's header.
# Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb.vvp tb_se30_ncr53c80.v ../../rtl/se30_ncr53c80.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
