#!/usr/bin/env bash
# 2026-10-26 (Daniel: "Yes, start the trimmed sweeps straight after tonight's
# chain"): waits for overnight_k46b.sh to end (30 h at most), then - only if
# it ended "done" - the next chain's trimmed sweeps on the merged kernel
# (KNOWN ISSUES 48-52), one at a time: (a) SET=all CTX="00 11 i11" (472),
# (b) TRACE=1 SET=all CTX=11 (180), (c) TRACE=0 the same (176), (d) SET=bus
# LEVELS=4 CTX=11 (157); ~33 h.  No regression or builds: tonight's chain
# ran both on this kernel.  Every sweep runs even if one fails.
# Log: sim/trimmed_k52.log.
#   bash sim/trimmed_k52.sh
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/trimmed_k52.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "trimmed_k52: waiting for overnight_k46b"
END='overnight_k46b: (done|the )|tree dirty|stamp failed|build FAILED'
n=0
until grep -qE "$END" "$SIM/overnight_k46b.log" 2>/dev/null; do
  n=$((n + 1)); [ $n -gt 360 ] && { log "trimmed_k52: overnight_k46b not ended after 30 h - nothing run"; exit 1; }
  sleep 300
done
grep -q 'overnight_k46b: done' "$SIM/overnight_k46b.log" ||
  { log "trimmed_k52: overnight_k46b did not end done - no sweeps: $(grep -E "$END" "$SIM/overnight_k46b.log" | tail -1)"; exit 1; }
log "trimmed_k52: start on $(git log --oneline -1 | cut -c1-60)"
cd "$SIM/busfault_irq"
cp -n sweep_all.log sweep_all_k46b.log
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  ./run_sweep.sh "$@" > "$SIM/trimmed_k52_$name.out" 2>&1
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min, $S)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "${S%.log}_k52$name.log"
}
run a sweep_all.log SET=all CTX="00 11 i11"
run b sweep_all_t1.log TRACE=1 SET=all CTX=11
run c sweep_all_t0.log TRACE=0 SET=all CTX=11
run d sweep_bus.log SET=bus LEVELS=4 CTX=11
log "trimmed_k52: done"
