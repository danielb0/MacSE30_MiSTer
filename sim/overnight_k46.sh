#!/usr/bin/env bash
# The night of 2026-10-25 (Daniel: "Go ahead with option A, the regression,
# then compile"): KNOWN ISSUES 46's class sweep in full (sim/busfault_irq,
# every shape and handler, the SE/30 without and with the 24-bit row and
# caches, the IIcx's NuBus timeout), then the full regression on the batch's
# kernel (46 with its third item, 47, 48 - rerun 2026-10-25 night), then - only if every line of both passed - the release-form builds
# of both cores (stamp, build_only, sta_corners, archive as
# <rev>_<sha>_k46release, the qsfs and build_tag.v restored).  One sweep at a
# time.  Log: sim/overnight_k46.log.
#   bash sim/overnight_k46.sh
set -u
cd "$(dirname "$0")/.."
SIM=$(pwd)/sim
LOG=$SIM/overnight_k46.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "overnight_k46: start on $(git log --oneline -1 | cut -c1-60)"

# 1. the class sweep
t0=$(date +%s)
(cd "$SIM/busfault_irq" && ./run_sweep.sh SET=all CTX="00 11 i11") > "$SIM/overnight_k46_sweep.out" 2>&1
S=$SIM/busfault_irq/sweep_all.log
log "class sweep: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
tail -1 "$S" | grep -qE ': ([0-9]+) / \1 PASS' || { log "overnight_k46: the class sweep did not pass in full - no regression, no builds"; exit 1; }

# 2. the regression
t0=$(date +%s)
bash "$SIM/run_regression.sh" > "$SIM/overnight_k46_regression.out" 2>&1; rc=$?
log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 "$SIM/overnight_k46_regression.out")"
if [ $rc != 0 ]; then
  grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$SIM/regression.log" | cut -c1-300 | head -8 >> "$LOG"
  log "overnight_k46: the regression did not pass in full - no builds"; exit 1
fi

# 3. the release-form builds
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "builds: tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
log "builds started on $(git rev-parse --short=8 HEAD)"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_k46.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_k46.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; exit 1; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_k46.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_k46.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 k46release -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_k46release.rbf 2>/dev/null | head -1)
  log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
done
log "overnight_k46: done - both release-form builds archived"
