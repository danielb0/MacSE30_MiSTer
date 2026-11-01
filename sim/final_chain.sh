#!/usr/bin/env bash
# 2026-11-01 (Daniel: "Please start the trimmed final chain"): the chain on
# the frozen kernel, trimmed - only what has not run since KNOWN ISSUES 53's
# fix (8afce37); the kernel has had comment changes only since.  One sweep at
# a time, each case to disk as it ends (RESUME=1 continues a sweep):
#   (c) busfault_irq TRACE=0 SET=all CTX=11, less the cases class 7's T0 PASSed
#   (b) TRACE=1 the same, less class 7's T1 PASSes; if sim/final_chain_b_only.txt
#       exists when (b) starts, only the shapes it lists (a later trim)
#   the regression, then - only if it passed in full - the release-form
#   builds of both cores (stamp, build_only, sta_corners, archive "frozen").
# Every sweep runs even if one fails.  Log: sim/final_chain.log.
#   bash sim/final_chain.sh
set -u
cd "$(dirname "$0")/.."
SIM=$(pwd)/sim
LOG=$SIM/final_chain.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "final_chain: start on $(git log --oneline -1 | cut -c1-60)"

# 1. the sweeps
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  (cd "$SIM/busfault_irq" && ./run_sweep.sh "$@") > "$SIM/final_chain_$name.out" 2>&1
  S=$SIM/busfault_irq/$S
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min, $S)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "${S%.log}_final$name.log"
}
run c sweep_all_t0.log TRACE=0 SET=all CTX=11 SKIPLOG=sweep_c7_t0.log
if [ -s "$SIM/final_chain_b_only.txt" ]; then
  run b sweep_all_t1.log TRACE=1 SET=all CTX=11 SKIPLOG=sweep_c7_t1.log "ONLY=$(tr '\n' ' ' < "$SIM/final_chain_b_only.txt")"
else
  run b sweep_all_t1.log TRACE=1 SET=all CTX=11 SKIPLOG=sweep_c7_t1.log
fi

# 2. the regression
t0=$(date +%s)
bash "$SIM/run_regression.sh" > "$SIM/final_chain_regression.out" 2>&1; rc=$?
log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 "$SIM/final_chain_regression.out")"
[ $rc != 0 ] && { grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$SIM/regression.log" | cut -c1-300 | head -8 >> "$LOG"
                  log "final_chain: the regression did not pass in full - no builds"; exit 1; }

# 3. the release-form builds
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "builds: tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
log "builds started on $(git rev-parse --short=8 HEAD)"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_final.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_final.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; exit 1; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_final.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_final.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 frozen -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_frozen.rbf 2>/dev/null | head -1)
  log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
done
log "final_chain: done"
