#!/usr/bin/env bash
# Run tb_iici_sdram under Icarus Verilog.  See its header.
# Exit status is the bench's verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -DSIMULATION -o out/tb.vvp tb_iici_sdram.v ../sdram/sdram_model.v ../../rtl/iici_sdram.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb.vvp | tee run.log
grep -q '^==== PASS' run.log
