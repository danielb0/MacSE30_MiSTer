#!/usr/bin/env bash
# scripts/build_stages.sh - the Quartus flow one stage at a time, so a stopped
# or failed stage is rerun alone and the stages before it are kept (their
# results live in db/ and incremental_db/).  BUILD ONLY, as build_only.sh.
#
#   bash scripts/build_stages.sh            # map, fit, asm, sta in turn
#   bash scripts/build_stages.sh fit        # from the fitter on (synthesis kept)
#   bash scripts/build_stages.sh asm        # from the assembler on (fit kept)
#   bash scripts/build_stages.sh sta        # timing analysis only
#   bash scripts/build_stages.sh map        # synthesis only (= build_only.sh --check)
#
# Why (2026-10-06, compile 47): the fitter ran an hour in one stage twice, and
# `quartus_sh --flow compile` restarts from synthesis every time.  Each stage
# here is its own program - quartus_map, quartus_fit, quartus_asm, quartus_sta -
# reading the previous one's database, so only the stage that stopped is paid
# for again.  The fitter itself (placement + routing) is indivisible.
#
# Reads scripts/local.env for QUARTUS_BIN (and QUARTUS_REVISION / RBF_NAME),
# exactly as build_only.sh.  Logs to output_files/stages_<date>.log.  Exit
# status: the first failing stage's.  The build ritual is unchanged: stamp
# before, archive while stamped, checkout rtl/build_tag.v after.
set -u
cd "$(dirname "$0")/.."
if [ -f scripts/local.env ]; then . scripts/local.env; fi
export PATH="${QUARTUS_BIN:?set QUARTUS_BIN in scripts/local.env}:$PATH"
if [ -n "${QUARTUS_REVISION:-}" ]; then REV="$QUARTUS_REVISION"; else
  REV=$(basename "$(ls ./*.qsf | head -1)" .qsf); fi
RBF_NAME="${RBF_NAME:-$REV.rbf}"
LOG="output_files/stages_$(date +%Y%m%d_%H%M%S).log"; mkdir -p output_files
FROM="${1:-map}"
case "$FROM" in map) STAGES="map fit asm sta";; fit) STAGES="fit asm sta";;
  asm) STAGES="asm sta";; sta) STAGES="sta";; *) echo "usage: $0 [map|fit|asm|sta]" >&2; exit 2;; esac
for st in $STAGES; do
  t0=$(date +%s)
  echo "[$(date +%H:%M:%S)] quartus_$st $REV" | tee -a "$LOG"
  "quartus_$st" "$REV" 2>&1 | tee -a "$LOG" | grep -E "^(Error|Critical Warning|Info \((170190|170192|170194|11798|128001|332146|179023)\))|Fitter was|Assembler was|Timing Analyzer was|successful" | cut -c1-120
  rc=${PIPESTATUS[0]}
  echo "[$(date +%H:%M:%S)] quartus_$st rc=$rc after $(( $(date +%s)-t0 )) s" | tee -a "$LOG"
  [ "$rc" -eq 0 ] || { echo "stage $st FAILED (see $LOG)"; exit "$rc"; }
  [ "$FROM" = map ] && [ "$st" = map ] && [ "${1:-}" = map ] && break
done
if [ -f "output_files/$RBF_NAME" ]; then
  echo "rbf: output_files/$RBF_NAME ($(stat -c %s "output_files/$RBF_NAME") bytes, $(date -r "output_files/$RBF_NAME" +%H:%M))"
fi
grep -E "Logic utilization|Total registers|Total block memory" output_files/$REV.fit.summary 2>/dev/null | head -3
