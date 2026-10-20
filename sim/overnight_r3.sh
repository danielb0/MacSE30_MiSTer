#!/usr/bin/env bash
# The night of 2026-10-20 (Daniel: "chain the regression after it, and go
# ahead with any fixes. When all tests are passed, please compile the
# release-form versions of the IIcx and the SE/30"): wait for round 3's chain
# (sim/predec_fault_r3/round3.log), run the CPU regression list, then the two
# release-form compiles with the build ritual - stamp, build, sta_corners,
# archive while stamped, checkout - the committed qsfs as they are.  One line
# a step in sim/overnight_r3.log; the script stops at the first failure.
#   bash sim/overnight_r3.sh [wait|regress|compile]     the stage to start at
set -u
cd "$(dirname "$0")/.."
LOG=sim/overnight_r3.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
STAGE=${1:-wait}
log "overnight started at stage $STAGE"

if [ "$STAGE" = wait ]; then
  for i in $(seq 1 660); do                               # up to 11 h
    last=$(tail -1 sim/predec_fault_r3/round3.log)
    case "$last" in
      *"round 3 finished"*) break ;;
      *"the chain stops"*) log "round 3 STOPPED: $(tail -2 sim/predec_fault_r3/round3.log | head -1 | cut -c1-300)"; exit 1 ;;
    esac
    sleep 60
  done
  grep -q "round 3 finished" sim/predec_fault_r3/round3.log || { log "round 3 not finished after 11 h"; exit 1; }
  log "round 3 finished: $(grep -c '^PASS' sim/predec_fault_r3/round3.log) steps PASS"
  STAGE=regress
fi

if [ "$STAGE" = regress ]; then
  t0=$(date +%s)
  bash sim/run_regression.sh > sim/regression_r3.out 2>&1; rc=$?
  log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 sim/regression.log 2>/dev/null; tail -1 sim/regression_r3.out)"
  [ $rc = 0 ] || { grep -E '^FAIL|FAIL' sim/regression.log | head -5 >> $LOG; log "regression FAILED - no compile"; exit 1; }
  STAGE=compile
fi

if [ "$STAGE" = compile ]; then
  if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
    log "tree dirty - the stamp refuses it; commit first, then: bash sim/overnight_r3.sh compile"; git status --porcelain | grep -v '^??' >> $LOG; exit 1
  fi
  for rev in MacSE30 MacIIcx; do
    t0=$(date +%s)
    $PS scripts/stamp_build_tag.ps1 >> $LOG 2>&1 || { log "$rev: stamp failed"; exit 1; }
    QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_r3.log 2>&1; rc=$?
    log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_r3.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
    if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; exit 1; fi
    "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_r3.log 2>&1
    log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_r3.log | tr '\n' ' ' | cut -c1-300)"
    $PS scripts/archive_build.ps1 r3release -Revision $rev >> $LOG 2>&1 || log "$rev: archive failed"
    git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
    f=$(ls -t output_files/${rev}_*_r3release.rbf 2>/dev/null | head -1)
    log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
  done
  log "both compiles done"
fi
