#!/usr/bin/env bash
# 2026-11-07 (Daniel: "Let's create the fixes for 1 and 2. We can start with just the IIcx
# for testing purposes, because it contains both defects"): the test build of KNOWN ISSUES
# 61 (the Toby card's VRAM acknowledge in the fourth NuBus clock) and 62 (the 53C80's ACK
# held to the next DACK cycle) on the committed tree - stamp, build_only, sta_corners,
# archive "ki6162", restore.  REVS="MacSE30" builds the SE/30 test version the same way.
# Launched through the Task Scheduler (an app update kills the app's children).
# Log: sim/ki6162.log.  Nothing is pushed.
set -u
cd "$(dirname "$0")/.."
LOG=$(pwd)/sim/ki6162.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
REVS=${REVS:-MacIIcx}
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "ki6162: start on $(git log --oneline -1 | cut -c1-60), revisions $REVS"

# no simulator running (the fitter needs the memory), bounded at 1 h
for i in $(seq 1 30); do
  n=$(tasklist 2>/dev/null | grep -ci vsimk); [ "$n" = 0 ] && break; sleep 120
done
[ "$n" != 0 ] && log "ki6162: $n vsimk still running after 1 h; building anyway"

if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "ki6162: tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; exit 1
fi
for rev in $REVS; do
  t0=$(date +%s)
  $PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "$rev: stamp failed"; exit 1; }
  QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_${rev}_ki6162.log 2>&1; rc=$?
  log "$rev: build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_${rev}_ki6162.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
  if [ $rc != 0 ]; then git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf; log "$rev: build FAILED"; continue; fi
  "$QB/quartus_sta" -t scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_ki6162.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_ki6162.log | tr '\n' ' ' | cut -c1-300)"
  $PS scripts/archive_build.ps1 ki6162 -Revision $rev >> "$LOG" 2>&1 || log "$rev: archive failed"
  git checkout -- rtl/build_tag.v MacSE30.qsf MacIIcx.qsf
  f=$(ls -t output_files/${rev}_*_ki6162.rbf 2>/dev/null | head -1)
  log "$rev: archived $f"
done
log "ki6162: done; tree status: $(git status --porcelain | grep -v '^??' | tr '\n' ' ')"
