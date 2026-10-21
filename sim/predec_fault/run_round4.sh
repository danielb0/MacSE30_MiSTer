#!/usr/bin/env bash
# The fourth round's chain (2026-10-21, class 6 of the bug-class review:
# pointer-level faults; Daniel: "Run the whole chain, 50 seeds each"): the
# directed set at CACR 0 and $2101 (run_ptrsweep.sh), then the random sweep
# 50 seeds in user mode (CACR 0) and 50 in supervisor mode (CACR $2101, A/UX's
# m20cache) - one 8-wide sweep at a time.  Every stage runs whatever the one
# before found (each is its own record); the summary is round4.log.
#   ./run_round4.sh [FROM]     FROM: 1 (default) .. 4, the stage to start at
set -u
cd "$(dirname "$0")"
LOG=$(pwd)/round4.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
FROM=${1:-1}
log "round 4 chain started at stage $FROM"
stage() {                                            # stage n, what, command...
  local n=$1 what=$2; shift 2
  [ "$n" -lt "$FROM" ] && return
  log "stage $n ($what) started"
  local r; r=$("$@" 2>&1 | tail -1)
  log "stage $n ($what): $r"
}
stage 1 "directed, CACR 0"           ./run_ptrsweep.sh
stage 2 "directed, CACR \$2101"      ./run_ptrsweep.sh CACR=0x2101
stage 3 "random user, 50 seeds"      ./run_rsweep3.sh ptr 0 50
stage 4 "random super, 50 seeds"     ./run_rsweep3.sh ptrsuper 0 50 CACR=0x2101
log "round 4 chain finished"
