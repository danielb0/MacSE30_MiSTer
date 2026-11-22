#!/usr/bin/env bash
# An IIci build of the committed tree, by label (sim/ki6162_build.sh's ritual for the MacIIci
# revision): stamp, build_only, sta_corners_iici, archive, restore.
#   LABEL=cache11 bash sim/iici_build.sh
# Launched through the Task Scheduler (an app update kills the app's children).
# Logs: sim/iici_build.log (this script's), output_files/build_$LABEL.log,
# output_files/sta_corners_$LABEL.log.  The bitstream: output_files/MacIIci_$LABEL.rbf.
# Nothing is pushed.
set -u
cd "$(dirname "$0")/.."
LABEL=${LABEL:?LABEL=<name> bash sim/iici_build.sh}
LOG=$(pwd)/sim/iici_build.log
QB=/c/intelFPGA_lite/17.0/quartus/bin64
PS="powershell -NoProfile -ExecutionPolicy Bypass -File"
rev=${REV:-MacIIci}                      # REV=MacIIxx: the IIxx
log() { echo "[$(date '+%m-%d %H:%M')] $LABEL: $*" >> "$LOG"; }
log "start on $(git log --oneline -1 | cut -c1-60)"

# no simulator running (the fitter needs the memory), bounded at 1 h
for i in $(seq 1 30); do
  n=$(tasklist 2>/dev/null | grep -ci vsimk); [ "$n" = 0 ] && break; sleep 120
done
[ "$n" != 0 ] && log "$n vsimk still running after 1 h; building anyway"

if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
  log "tree dirty - the stamp refuses it"; git status --porcelain | grep -v '^??' >> "$LOG"; log "done (not built)"; exit 1
fi
t0=$(date +%s)
$PS scripts/stamp_build_tag.ps1 >> "$LOG" 2>&1 || { log "stamp failed"; log "done (not built)"; exit 1; }
# the route's limit: no build that routed for more than ~30 min has met timing (SE30_PLAN.md, build cache12),
# so the fitter is stopped ROUTE_LIMIT minutes after its routing begins (the fitter's own message file says when)
ROUTE_LIMIT=${ROUTE_LIMIT:-40}
( t=0
  while [ $t -lt 720 ]; do
    sleep 60; t=$((t + 1))
    tasklist 2>/dev/null | grep -qi "quartus_sh" || { log "route watch: no quartus_sh at minute $t - watch ends"; exit 0; }
    # a heartbeat every 10 min (build rot1's limit never fired; this shows what the watch sees)
    if [ $((t % 10)) = 0 ]; then
      log "route watch: minute $t, qmsg $([ -f db/$rev.fit.qmsg ] && echo yes || echo no), newer $([ db/$rev.fit.qmsg -nt output_files/build_$LABEL.log.start ] && echo yes || echo no), routing $(grep -aq 'Fitter routing operations beginning' db/$rev.fit.qmsg 2>/dev/null && echo yes || echo no), since ${r0:-none}"
    fi
    if [ -f db/$rev.fit.qmsg ] && [ db/$rev.fit.qmsg -nt output_files/build_$LABEL.log.start ] && grep -aq "Fitter routing operations beginning" db/$rev.fit.qmsg; then
      r0=${r0:-$t}
      if [ $((t - r0)) -ge $ROUTE_LIMIT ] && tasklist 2>/dev/null | grep -qi "quartus_fit"; then
        log "routing past $ROUTE_LIMIT min - the fitter stopped: $(grep -ao 'Router estimated peak interconnect usage is [^\"]*' db/$rev.fit.qmsg | tail -1)"
        taskkill //F //IM quartus_fit.exe > /dev/null 2>&1; exit 0
      fi
    fi
  done ) &
touch output_files/build_$LABEL.log.start
QUARTUS_REVISION=$rev bash scripts/build_only.sh > output_files/build_$LABEL.log 2>&1; rc=$?
log "build_only rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(grep -iE 'timing|ALMs|rbf|error' output_files/build_$LABEL.log | grep -v '^Info' | head -4 | tr '\n' ' ' | cut -c1-300)"
log "router: $(grep -hE '170196|170194' output_files/build_$LABEL.log | sed 's/^ *Info ([0-9]*): //' | tr '\n' ' ' | cut -c1-300)"
rm -f output_files/build_$LABEL.log.start
if [ $rc != 0 ]; then
  git checkout -- rtl/build_tag.v $rev.qsf; log "build FAILED"; log "done"; exit 1
fi
"$QB/quartus_sta" -t scripts/sta_corners_iici.tcl $rev > output_files/sta_corners_$LABEL.log 2>&1
log "sta_corners: $(grep -E 'worst slack over every corner|^the capture' output_files/sta_corners_$LABEL.log | tr '\n' ' ' | cut -c1-300)"
cp output_files/$rev.rbf output_files/${rev}_$LABEL.rbf && log "archived output_files/${rev}_$LABEL.rbf md5 $(md5sum output_files/${rev}_$LABEL.rbf | cut -c1-32)"
git checkout -- rtl/build_tag.v $rev.qsf
log "done; tree status: $(git status --porcelain | grep -v '^??' | tr '\n' ' ')"
