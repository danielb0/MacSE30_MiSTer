#!/usr/bin/env bash
# 2026-10-28 (Daniel: "Yes, add the JSR shape and run the tests after the
# chain"): waits for after_k46c.sh to end (52 h at most), then KNOWN ISSUES
# 53's checks from sim/_stage15 (the bench + w_jsr_wp; the sweep takes
# ONLY="shapes" and KRTL=), one 8-wide sweep at a time:
#   B  the plant: the tree's kernel, w_jsr_wp, TRACE=1 and 0, CTX "00 11"
#      (complete with the MMU must FAIL on the trace)
#   C  the fix (_rtl_c13), the five late-write shapes, TRACE=1 and 0, CTX 11
#   E  the fix, w_jsr_wp, TRACE=1 and 0, CTX 00 (an external bus error)
#   D  the fix, the five shapes, no trace, CTX "00 11" (frames unchanged)
#   A  the tree's kernel, w_jsr_wp, no trace, CTX "00 11 i11" (the bench)
# Log: sim/ki53_tests.log; each sweep's log kept as sweep_ki53_<x>.log.
#   bash sim/ki53_tests.sh
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/ki53_tests.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "ki53_tests: waiting for after_k46c"
n=0
until grep -q 'after_k46c: \(done\|overnight_k46c not done\)' "$SIM/after_k46c.log" 2>/dev/null; do
  n=$((n + 1)); [ $n -gt 624 ] && { log "ki53_tests: after_k46c not ended after 52 h - nothing run"; exit 1; }
  sleep 300
done
FIVE="m_add_wp w_clr_inv w_st_inv w_pack_inv w_jsr_wp"
C13=$SIM/_rtl_c13
cd "$SIM/_stage15"
run() {   # name, run_sweep's log, then its arguments
  local name=$1 S=$2; shift 2; local t0=$(date +%s)
  env "$@" ./run_sweep.sh > "$SIM/ki53_tests_$name.out" 2>&1
  log "($name) $*: $(tail -1 "$S") ($(( ($(date +%s) - t0) / 60 )) min)"
  grep -v '==== PASS' "$S" | grep -v '^====' | cut -c1-300 >> "$LOG"
  cp "$S" "sweep_ki53_$name.log"
}
log "ki53_tests: start on $(git log --oneline -1 | cut -c1-60)"
run B1 sweep_all_t1.log SET=all ONLY=w_jsr_wp TRACE=1 CTX="00 11"
run B0 sweep_all_t0.log SET=all ONLY=w_jsr_wp TRACE=0 CTX="00 11"
run C1 sweep_all_t1.log SET=all ONLY="$FIVE" TRACE=1 CTX=11 KRTL=$C13
run C0 sweep_all_t0.log SET=all ONLY="$FIVE" TRACE=0 CTX=11 KRTL=$C13
run E1 sweep_all_t1.log SET=all ONLY=w_jsr_wp TRACE=1 CTX=00 KRTL=$C13
run E0 sweep_all_t0.log SET=all ONLY=w_jsr_wp TRACE=0 CTX=00 KRTL=$C13
run D sweep_all.log SET=all ONLY="$FIVE" CTX="00 11" KRTL=$C13
run A sweep_all.log SET=all ONLY=w_jsr_wp CTX="00 11 i11"
log "ki53_tests: done"
