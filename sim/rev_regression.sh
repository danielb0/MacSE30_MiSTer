#!/bin/bash
# The revised regression (SE30_PLAN.md, THE NEXT RELEASE AND THE REGRESSION REVISED), launched
# from Task Scheduler (task SE30_revreg) so an app update cannot kill it.  Waits for the release
# builds (sim/rc6162.log "rc6162: done") and any simulators, then runs run_regression.sh.
# Log: sim/rev_regression.log.  A restart: RESUME=1 bash sim/rev_regression.sh
set -u
cd /c/Git/MacSE30_MiSTer/sim
LOG=rev_regression.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
log "rev_regression: waiting for the release builds and any simulators"
deadline=$(( $(date +%s) + 4 * 3600 ))
until grep -q "rc6162: done" rc6162.log && [ "$(tasklist 2>/dev/null | grep -ci vsimk)" = 0 ]; do
  [ $(date +%s) -gt $deadline ] && { log "rev_regression: STOPPED - still waiting after 4 h"; exit 1; }
  sleep 60
done
log "rev_regression: start on dev $(git rev-parse --short HEAD)"
t0=$(date +%s)
./run_regression.sh > rev_regression.out 2>&1; rc=$?
log "rev_regression: rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 rev_regression.out)"
grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' regression.log | sed 's/^/  not passed: /' >> $LOG
log "rev_regression: done"
