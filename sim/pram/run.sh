#!/usr/bin/env bash
# Run tb_se30_pram under Icarus Verilog.  See the header of tb_se30_pram.v
# for what it proves.  IVERILOG: the iverilog bin directory.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_pram.vvp tb_se30_pram.v ../../rtl/se30_rtc.v ../../rtl/se30_pram.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_pram.vvp | tee run.log
grep -q '^==== PASS' run.log
