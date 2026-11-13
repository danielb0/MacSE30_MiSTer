#!/usr/bin/env bash
# Run tb_iici_rbv under Icarus Verilog.  See the header of tb_iici_rbv.v.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2012 -o out/tb_iici_rbv.vvp tb_iici_rbv.v ../../rtl/iici_rbv.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_iici_rbv.vvp | tee run.log
grep -q '^==== PASS' run.log
