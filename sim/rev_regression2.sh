#!/bin/bash
# The revised regression's resume after the Windows Update restart of 2026-11-11 02:29: phase 1
# (32/32) and the caches-off pass of phase 2 (13/13) had passed; this runs the $2101 pass and the
# tail lines (each sweep resumes its recorded cases, RESUME=1), then joins the three parts into
# regression.log.  Task Scheduler SE30_revreg2; log sim/rev_regression.log.
set -u
cd /c/Git/MacSE30_MiSTer/sim
LOG=rev_regression.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> $LOG; }
[ -f regression.log.2_cacr0 ] || cp regression.log.2 regression.log.2_cacr0
log "rev_regression2: resume on dev $(git rev-parse --short HEAD) - the \$2101 pass and the tail"
t0=$(date +%s)
CACRS=0x2101 RESUME=1 ./run_regression.sh phase2 > rev_regression2.out 2>&1
cat regression.log.1 regression.log.2_cacr0 regression.log.2 > regression.log
N=$(grep -c . regression.log); P=$(grep -cE '^PASS|: ([0-9]+) / \1 (parts )?PASS' regression.log)
log "rev_regression2: after $(( ($(date +%s) - t0) / 60 )) min: ==== regression: $P / $N lines pass"
grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' regression.log | sed 's/^/  not passed: /' >> $LOG
log "rev_regression2: done"
