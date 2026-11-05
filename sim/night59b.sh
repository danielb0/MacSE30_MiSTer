#!/usr/bin/env bash
# 2026-11-05 14:10 (Daniel: "Let's restart the current chain and let it finish"):
# night59.sh's stages 3 and 4 again after the stop at (a) 194/556 - (a) resumed
# from sweep_all.log (RESUME=1, the bench unchanged), then (b), (c), (d) and the
# regression as night59.sh ran them.  Log: sim/night59.log (continued).
#   bash sim/night59b.sh
set -u
cd "$(dirname "$0")/.."
SIM=$(pwd)/sim
LOG=$SIM/night59.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "night59b: restart on $(git log --oneline -1 | cut -c1-60)"
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  (cd "$SIM/busfault_irq" && ./run_sweep.sh "$@") > "$SIM/night59_$name.out" 2>&1
  S=$SIM/busfault_irq/$S
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min, $S)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "${S%.log}_ki59$name.log"
}
RESUME=1 run a sweep_all.log SET=all CTX="00 11 i11"
run b sweep_all_t1.log TRACE=1 SET=all CTX=11
run c sweep_all_t0.log TRACE=0 SET=all CTX=11
run d sweep_bus.log SET=bus LEVELS=4 CTX=11
t0=$(date +%s)
bash "$SIM/run_regression.sh" > "$SIM/night59_regression.out" 2>&1; rc=$?
log "regression rc=$rc after $(( ($(date +%s) - t0) / 60 )) min: $(tail -1 "$SIM/night59_regression.out")"
[ $rc != 0 ] && grep -vE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$SIM/regression.log" | cut -c1-300 | head -8 >> "$LOG"
log "night59b: done"
