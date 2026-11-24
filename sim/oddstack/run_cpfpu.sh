#!/usr/bin/env bash
# run_cpfpu.sh - the regression's cpfpu corpus with the supervisor stack off
# alignment (Prince of Persia, 2026-11-24: an interrupt frame on an odd stack).
# Every frame the corpus takes - $0 (traps, F-line, IRQs), $2 (FTRAPcc,
# trace), $9 (mid-instruction, IRQs inside dialogs), $A/$B (bus errors, page
# faults), format errors - and its RTE, at SSP $8000 + 1, 2 and 3
# (gen_program.py's SSP_OFF; b5d at $7F00 + offset).  c10 stays aligned: its
# addresses are discovered.
#
#   ./run_cpfpu.sh [offsets]     (default "1 2 3"; W=8 at a time)
# Results: cpfpu.log (one line per run, written as each ends).
set -u
cd "$(dirname "$0")"
HERE=$(pwd); SIM=$(cd .. && pwd)
LOG=$HERE/cpfpu.log
: > "$LOG"
one() {   # name off prog env...
  name=$1; off=$2; prog=$3; shift 3
  d=$SIM/_oss_${name}_$off; rm -rf "$d"; mkdir -p "$d"
  cp "$SIM/cpfpu/gen_program.py" "$SIM/cpfpu/tb_cpfpu.v" "$SIM/cpfpu/run.sh" "$d/"
  out=$(cd "$d" && env PROG=$prog SSP_OFF=$off "$@" ./run.sh 2>&1); rc=$?
  if [ $rc = 0 ]; then line="PASS $name SSP+$off"
  else line="FAIL $name SSP+$off (exit $rc): $(echo "$out" | grep -E 'FAIL|====' | head -4 | tr '\n' ' ' | cut -c1-300)"; cp "$d/run.log" "$HERE/fail_${name}_$off.log" 2>/dev/null; fi
  echo "$line" >> "$LOG"; echo "$line"
  rm -rf "$d"
}
export -f one; export SIM HERE LOG
{
  for o in ${1:-1 2 3}; do
    for p in b1 b2 b3a b3b b3c b3u b3n b3s b3r b5a b5b b5c b5u b7e mmu b4 cmpm; do echo "$p $o $p"; done
    echo "b5d $o b5d SSP_BASE=0x7F00"   # (its page tables: page 8 invalid - a frame there double-faults, as a 68030 would)
    for p in b3r b5u; do echo "${p}_2101 $o $p B3_CACR=0x2101"; done
    echo "b3x $o b3x B3R_N=8"; echo "b3x_dlg $o b3x B3R_N=8 B3X_DLG=1"
  done
} | xargs -P "${W:-8}" -L 1 bash -c 'one "$@"' _
n=$(grep -c . "$LOG"); p=$(grep -c '^PASS' "$LOG")
echo "==== cpfpu on an odd stack: $p / $n PASS"
[ "$p" = "$n" ]
