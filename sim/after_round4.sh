#!/usr/bin/env bash
# Stage 6 of the fourth round (Daniel, 2026-10-21: "add the builds as stage
# 6"), a follower so the running chain's script is not edited under it: waits
# (16 h at most) for sim/predec_fault/run_round4.sh to finish, and if every
# stage passed - the directed set at both CACRs, 50/50 seeds in each random
# stage, every regression line - compiles the release forms of both cores
# (stamp, build_only, sta_corners, archive as <rev>_<sha>_r4release, the qsfs
# and build_tag.v restored), as round 3's overnight_r3.sh did.  The lines go
# to round4.log.
#   bash sim/after_round4.sh [now]     now: skip the wait and the gate
set -u
cd "$(dirname "$0")/.."
LOG=$(pwd)/sim/predec_fault/round4.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
if [ "${1:-}" != now ]; then
  for i in $(seq 1 960); do
    grep -qE "round 4 chain (finished|STOPPED)" "$LOG" 2>/dev/null && break
    sleep 60
  done
  grep -qE "round 4 chain (finished|STOPPED)" "$LOG" || { log "stage 6: the chain did not finish within 16 h - no builds"; exit 1; }
  full() { grep -oE '[0-9]+ / [0-9]+ (PASS|lines pass)' | tail -1 | awk '{exit !($1 == $3 && $3 > 0)}'; }
  ok=1
  for n in 1 2; do grep -E "stage $n \(.*\): " "$LOG" | tail -1 | grep -q "every sweep PASS" || ok=0; done
  for n in 3 4 5; do grep -E "stage $n \(.*\): " "$LOG" | tail -1 | full || ok=0; done
  [ $ok = 1 ] || { log "stage 6: not every stage passed - no builds"; exit 1; }
fi
if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "stage 6: tree dirty - the stamp refuses it; commit first, then: bash sim/after_round4.sh now"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
log "stage 6 (release-form builds) started on $(git rev-parse --short=8 HEAD)"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_r4.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_r4.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; exit 1; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_r4.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_r4.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 r4release -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_r4release.rbf 2>/dev/null | head -1)
  log "$rev: archived $f md5 $(md5sum "$f" 2>/dev/null | cut -c1-8)"
done
log "stage 6: both release-form builds done"
