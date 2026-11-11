#!/bin/bash
# Follower of rev_regression2.sh (2026-11-11): the $2101 pass's isweep with the arming preamble
# read 207/209, and its failing case names were lost (the ISW_CCR run overwrote isweep.log).
# Waits (bounded, 8 h) for "rev_regression2: done", then reruns that line alone and keeps
# the case list.  Task Scheduler SE30_iswrerun; log sim/rev_regression.log.
set -u
cd /c/Git/MacSE30_MiSTer/sim
LOG=/c/Git/MacSE30_MiSTer/sim/rev_regression.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
log "isw_rerun: waiting for rev_regression2 to finish"
for i in $(seq 1 960); do   # 960 x 30 s = 8 h
  grep -q "rev_regression2: done" $LOG && break
  sleep 30
done
if ! grep -q "rev_regression2: done" $LOG; then log "isw_rerun: gave up after 8 h"; exit 1; fi
cd predec_fault
cp isweep.log isweep.log.ccr1f_2101   # the ISW_CCR=0x1F run's results, kept
log "isw_rerun: start - run_isweep.sh CACR=0x2101 ARMEXT=r"
t0=$(date +%s)
./run_isweep.sh CACR=0x2101 ARMEXT=r > isw_rerun.out 2>&1
log "isw_rerun: after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 isw_rerun.out)"
grep -v "^====\|^sweep_xargs" isw_rerun.out | sed 's/^/  not passed: /' >> $LOG
log "isw_rerun: done"
