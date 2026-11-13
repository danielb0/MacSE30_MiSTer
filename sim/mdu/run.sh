#!/usr/bin/env bash
# Run tb_iici_mdu under Icarus Verilog.  See the header of tb_iici_mdu.v
# for what it proves.  IVERILOG: the iverilog bin directory.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2012 -o out/tb_iici_mdu.vvp tb_iici_mdu.v ../../rtl/iici_mdu.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_iici_mdu.vvp | tee run.log
grep -q '^==== PASS' run.log
