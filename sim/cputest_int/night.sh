#!/usr/bin/env bash
# The overnight integer-corpus run (SE30_PLAN.md 1.18.6): each batch set in
# turn on run.sh's 8 workers, then hi_report.py's named failures.
#
#   night.sh <batch dir>...      e.g. night.sh $C/full/hb6 $C/full24/hb24
#
# Writes <batch dir>/summary.txt, report.txt and timing.txt (start, end and
# wall time), and night_<date>.log beside this script with one line per set.
# Exit status 0 when every batch of every set passed.
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
LOG=$HERE/night_$(date +%Y%m%d_%H%M).log
ok=0
for B in "$@"; do
  t0=$(date +%s); echo "start $(date)" > "$B/timing.txt"
  bash run.sh "$B" 8 > "$B/run_sh.out" 2>&1 || ok=1
  t1=$(date +%s); echo "end   $(date)" >> "$B/timing.txt"
  echo "wall  $(( (t1 - t0) / 60 )) min" >> "$B/timing.txt"
  python ../../tools/cputest/hi_report.py "$B" > "$B/report.txt" 2>&1
  nb=$(ls "$B"/prog_*.hex | wc -l)
  np=$(grep -c "==== PASS" "$B/summary.txt")
  nf=$(grep -c "^\[.*\] round" "$B/report.txt")
  echo "$B: $np of $nb batches passed, $nf failing fields, $(( (t1 - t0) / 60 )) min" | tee -a "$LOG"
done
exit $ok
