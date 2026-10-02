#!/usr/bin/env bash
# Run tb_se30_flp_dkmux under Icarus Verilog - the four-requester disk-port
# mux (SE30_PLAN.md 5.14).  See the bench's header.  Plusargs pass through
# (+seed=N).  Exit status is the verdict: 0 on "==== PASS".
set -u
cd "$(dirname "$0")"
IVERILOG=${IVERILOG:-/c/iverilog/bin}
mkdir -p out
"$IVERILOG/iverilog.exe" -g2005-sv -o out/tb_se30_flp_dkmux.vvp tb_se30_flp_dkmux.v ../../rtl/se30_flp_dkmux.v || exit 1
"$IVERILOG/vvp.exe" -n out/tb_se30_flp_dkmux.vvp "$@" | tee run.log
grep -q '^==== PASS' run.log
