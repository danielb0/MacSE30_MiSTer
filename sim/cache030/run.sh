#!/usr/bin/env bash
# Run tb_se30_cache030 under Icarus Verilog - the 68030's caches against
# MC68030 UM section 6 (SE30_PLAN.md 1.16).  See the bench's header.
# Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_cache030.vvp tb_se30_cache030.v ../../rtl/tg68k/se30_cache030.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_cache030.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
