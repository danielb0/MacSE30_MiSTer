#!/usr/bin/env bash
# The night of 2026-10-21 (Daniel: "chain the builds onto the end"), after
# KNOWN ISSUES 38/39's fix (1b393b3): waits (2 h at most) for the round-4
# chain's regression to end, installs sim/staged/run_regression.sh (the fif
# sweeps and b3x added - staged because the running regression was reading
# the old file) and commits it, runs the whole regression on the fixed
# kernel, and if every line passes builds the release forms of both cores
# (sim/after_round4.sh now: stamp, build_only, sta_corners, archive as
# <rev>_<sha>_r4release).  The lines go to sim/predec_fault/round4.log.
#   bash sim/overnight_r4.sh
set -u
cd "$(dirname "$0")/.."
LOG=$(pwd)/sim/predec_fault/round4.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "overnight_r4 started: waiting for the round-4 regression"
for i in $(seq 1 120); do
  grep -qE "round 4 chain (finished|STOPPED)" "$LOG" && break
  sleep 60
done
grep -qE "round 4 chain (finished|STOPPED)" "$LOG" || { log "overnight_r4: the round-4 chain did not end within 2 h - stopped"; exit 1; }
log "overnight_r4: the round-4 regression (on the kernel before 1b393b3 for its cpfpu jobs): $(tail -1 sim/regression.log 2>/dev/null)"
cp sim/staged/run_regression.sh sim/run_regression.sh
git add sim/run_regression.sh
git rm -q --cached sim/staged/run_regression.sh 2>/dev/null
rm -f sim/staged/run_regression.sh
git commit -q -m "run_regression.sh: the fif sweeps (CACR 0, \$2101, FIF_IRQ=1) and b3x (random, every suspended dialog) - KNOWN ISSUES 38/39

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" || { log "overnight_r4: the regression script's commit failed - stopped"; exit 1; }
log "overnight_r4: run_regression.sh installed ($(git rev-parse --short HEAD)); the regression started"
t0=$(date +%s)
bash sim/run_regression.sh > sim/regression_r4.out 2>&1; rc=$?
log "overnight_r4: the regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 sim/regression_r4.out)"
if [ $rc != 0 ]; then
  grep -E '^FAIL|: [0-9]+ / [0-9]+ PASS' sim/regression.log | grep -vE ': ([0-9]+) / \1 PASS' | head -8 >> "$LOG"
  log "overnight_r4: the regression did not pass in full - no builds"; exit 1
fi
log "overnight_r4: every line passed - the release-form builds"
bash sim/after_round4.sh now > sim/after_round4.out 2>&1
log "overnight_r4 finished"
