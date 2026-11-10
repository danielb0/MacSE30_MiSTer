#!/bin/bash
# Release builds of the release tree (KNOWN ISSUES 61 + 62): both revisions, sta_corners, archive.
# Launched from Task Scheduler (task SE30_rc6162) so an app update cannot kill it. Log: sim/rc6162.log
set -u
LOG=/c/Git/MacSE30_MiSTer/sim/rc6162.log
RC=/c/Git/MacSE30_rc
QB=/c/intelFPGA_lite/17.0/quartus/bin64
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
cd "$RC" || { log "rc6162: no release tree"; exit 1; }
[ -n "$(git status --porcelain | grep -v '^??')" ] && { log "rc6162: STOPPED - the release tree has uncommitted changes"; exit 1; }
H=$(git rev-parse --short=7 HEAD)
log "rc6162: builds start on release $H ($(git log --oneline -1 | cut -c1-70))"
for rev in MacSE30 MacIIcx; do
  t0=$(date +%s)
  "$QB/quartus_sh" --flow compile $rev > output_files/${rev}_rc6162_build.log 2>&1; rc=$?
  log "$rev: compile rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -E 'Logic utilization' output_files/$rev.fit.summary 2>/dev/null | tr -s ' ' | tr '\n' ' ')"
  [ $rc != 0 ] && { log "$rev: compile FAILED: $(grep -E '^Error' output_files/${rev}_rc6162_build.log | head -3 | tr '\n' ' ' | cut -c1-300)"; continue; }
  "$QB/quartus_sta" -t /c/Git/MacSE30_MiSTer/scripts/sta_corners.tcl $rev > output_files/sta_corners_${rev}_rc6162.log 2>&1
  log "$rev: sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_${rev}_rc6162.log | tr '\n' ' ' | cut -c1-300)"
  cp output_files/$rev.rbf output_files/${rev}_${H}_rc.rbf
  log "$rev: archived output_files/${rev}_${H}_rc.rbf md5 $(certutil -hashfile output_files/${rev}_${H}_rc.rbf MD5 | sed -n 2p | cut -c1-8)"
done
git checkout -- MacSE30.qsf MacIIcx.qsf 2>/dev/null
log "rc6162: done; release tree status: $(git status --porcelain | grep -v '^??' | tr '\n' ' ')"
