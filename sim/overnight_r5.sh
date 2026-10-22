#!/usr/bin/env bash
# The night of 2026-10-22 (Daniel: "run them overnight"): the frs seeds the
# 50-seed sweep's 25-minute timeout cut (12 15 20 21 22 24 32 34 37; seeds 4
# and 10 rerun alone passed), then the full regression on 40cebb8's kernel
# (KNOWN ISSUES 37 fixed; the new fsx / FIF_SUPER / selfst lines in it).
# One sweep at a time.  Log: sim/overnight_r5.log.
set -u
SIM=/c/Git/MacSE30_MiSTer/sim
LOG=$SIM/overnight_r5.log
log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
cd "$SIM/cpfpu"
log "overnight_r5: start (kernel $(cd $SIM/.. && git log --oneline -1 | cut -c1-7))"
one() {
  k=$1; d=$SIM/_frs_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$SIM/cpfpu/gen_program.py" "$SIM/cpfpu/tb_cpfpu.v" "$SIM/cpfpu/run.sh" "$d/"
  r=$(cd "$d" && env PROG=frs FRS=$k timeout 3600 ./run.sh +IRQSEED=$(printf '%x' $((k * 2654435761 % 4294967296 | 1))) 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k ${r:-(no result: timed out)}"
  rm -rf "$d"
}
export -f one; export SIM
t0=$(date +%s)
printf '%s\n' 12 15 20 21 22 24 32 34 37 | xargs -P 8 -I{} bash -c 'one {}' | sort -n > "$SIM/cpfpu/frs_rest.log"
p=$(grep -c '==== PASS' "$SIM/cpfpu/frs_rest.log")
log "frs, the cut seeds: $p / 9 PASS ($(( ($(date +%s) - t0) / 60 )) min); with seeds 0-49's 39 + 4 and 10: $((p + 41)) / 50"
grep -v '==== PASS' "$SIM/cpfpu/frs_rest.log" | cut -c1-300 >> "$LOG"
t0=$(date +%s)
"$SIM/run_regression.sh" > "$SIM/overnight_r5_regression.out" 2>&1
log "regression: $(tail -1 "$SIM/overnight_r5_regression.out") ($(( ($(date +%s) - t0) / 60 )) min)"
grep -v '^PASS\|: \([0-9]*\) / \1 PASS' "$SIM/regression.log" | cut -c1-300 >> "$LOG"
log "overnight_r5: done"
