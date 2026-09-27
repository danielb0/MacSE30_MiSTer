#!/usr/bin/env bash
# Run tb_se30_via under Icarus Verilog.  See the header of tb_se30_via.v
# for what it proves.  IVERILOG: the iverilog bin directory.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_via.vvp tb_se30_via.v ../../rtl/se30_via.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_via.vvp | tee run.log
grep -q '^==== PASS' run.log
