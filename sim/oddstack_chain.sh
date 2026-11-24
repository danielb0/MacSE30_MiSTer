#!/bin/bash
# The odd-stack RTE fix (6c81d03, 2026-11-24): the revised regression, then - only if every line
# passes - the IIci release tree's build (C:/Git/MacIIci_release, sim/iici_release_build.sh).
# Task Scheduler SE30_oddstack; log sim/oddstack_chain.log.  Nothing is pushed.
# Argument "resume": phase 2 only, its first 8 lines from regression.log.2.keep (P2_SKIP),
# RESUME=1 (phase 1's regression.log.1 kept: same kernel).
set -u
cd /c/Git/MacSE30_MiSTer/sim
LOG=oddstack_chain.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
MODE=${1:-}
log "regression ${MODE:-start} on $(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD)"
t0=$(date +%s)
if [ "$MODE" = resume ]; then P2_SKIP=8 RESUME=1 ./run_regression.sh phase2 > oddstack_regression2.out 2>&1
else ./run_regression.sh > oddstack_regression.out 2>&1; fi
cat regression.log.1 regression.log.2 > regression.log 2>/dev/null
N=$(grep -c . regression.log); P=$(grep -cE '^PASS|: ([0-9]+) / \1 (parts )?PASS' regression.log)
log "regression after $(( ($(date +%s) - t0) / 60 )) min: $P / $N lines pass"
grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' regression.log | sed 's/^/  not passed: /' >> $LOG
if [ "$P" = "$N" ] && [ "$N" -gt 70 ]; then
  log "IIci release build start"; bash ./iici_release_build.sh; log "IIci release build ended (sim/iici_build.log)"
else
  log "no build: not every line passed"
fi
log "done"
