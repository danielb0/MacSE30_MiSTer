#!/usr/bin/env bash
# Run tb_iicx_power under Icarus Verilog.  See the header of tb_iicx_power.v
# for what it proves.  Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_iicx_power.vvp tb_iicx_power.v ../../rtl/iicx_power.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_iicx_power.vvp | tee run.log
grep -q '^==== PASS' run.log
