#!/usr/bin/env bash
# The replay over RAM timings: RAMLAT 0..6 fixed, then RAMJIT 4 with seeds
# 1..SEEDS (default 8).  One compile; each case's verdict to sweep.log as it
# ends (RESUME=1 skips cases already there).  Needs KERNEL and DISK as run.sh.
set -u
cd "$(dirname "$0")"
MODELSIM=${MODELSIM:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
LOG=sweep.log
[ "${RESUME:-0}" = 1 ] || : > "$LOG"
bash run.sh > /dev/null                      # build ram.hex and work/ once (case 0/0)
one() {
  local tag=$1; shift
  grep -q "^$tag " "$LOG" 2>/dev/null && return
  "$MODELSIM/vsim.exe" -c -quiet "$@" -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" \
    work.tb_wsfb_replay > "run_$tag.log" 2>&1
  local v; v=$(grep -E '^# ==== ' "run_$tag.log" | sed 's/^# //')
  local r; r=$(grep -E '^# ---- the run' "run_$tag.log" | sed 's/^# ---- the run: //')
  echo "$tag $v | $r" >> "$LOG"
  echo "$tag $v"
}
for l in 0 1 2 3 4 5 6; do one "lat$l" +RAMLAT=$l; done
for s in $(seq 1 "${SEEDS:-8}"); do one "jit4s$s" +RAMLAT=2 +RAMJIT=4 +RAMSEED=$s; done
grep -c "PASS" "$LOG" | xargs echo "passed:"
