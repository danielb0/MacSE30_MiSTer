#!/usr/bin/env bash
# Class 4b (SE30_PLAN.md): every PROG=fswi case - an FPU instruction's memory
# operand page-faulting mid-dialog (fsw's cases), iterated with a level-1
# interrupt at a different clock of each iteration.  A reference run (+EVT:
# iteration 0, no interrupt) gives the instruction's decode, the pager's
# count and the next instruction's decode; the interrupt goes on every
# second clock from 20 before the decode to 200 after, 60 before the
# pager's count to 300 after, 60 around the end, and every 16th clock
# between.  8 cases at a time.  Extra NAME=value arguments go to the
# environment (FSW_WP=1, RTL=...).  Log: fswisweep.log.
#   ./run_fswisweep.sh [FSW_WP=1] [CASES="0 1 2"] [PAR=8]
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
CASES=""; PAR=8
for a in "$@"; do case "$a" in CASES=*) CASES=${a#CASES=} ;; PAR=*) PAR=${a#PAR=} ;; esac; done
EXTRA=$(printf '%s\n' "$@" | grep -v -E '^(CASES|PAR)=' | tr '\n' ' ')
N=$(env $EXTRA FSWLIST=1 python gen_program.py fswi | wc -l)
one() {
  k=$1; d=$HERE/../_fswi_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_cpfpu.v" "$HERE/run.sh" "$d/"
  cd "$d"
  echo 999999 > offsets.txt
  env PROG=fswi FSW=$k $EXTRA timeout 3600 ./run.sh +IRQLOOP +MAXCLK=20000000 > evt.out 2>&1
  python - <<'PY' > offsets.txt
ev = {l.split()[1]: int(l.split()[2]) for l in open("evt.out") if l.startswith("EVT ")}
s, e, pf = ev.get("insn", 0), ev.get("end", 3000), ev.get("pf")
dense = set(range(s - 20, s + 201, 2)) | set(range(e - 60, e + 61, 2))
if pf is not None: dense |= set(range(pf - 60, pf + 301, 2))
print("\n".join(map(str, sorted(o for o in dense | set(range(s - 20, e + 61, 16)) if o >= 0)[:767])))   # the bench's table: 768 iterations
PY
  n=$(wc -l < offsets.txt)
  r=$(env PROG=fswi FSW=$k $EXTRA timeout 43200 ./run.sh +IRQLOOP +MAXCLK=200000000 2>&1 | grep -a -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  cd "$HERE"; rm -rf "$d"
  echo "$k ($n offsets) $r"
}
export -f one; export HERE EXTRA
if [ -n "$CASES" ]; then printf '%s\n' $CASES; else seq 0 $((N-1)); fi | xargs -P $PAR -I{} bash -c 'one {}' | sort -n > fswisweep.log
P=$(grep -c '==== PASS' fswisweep.log); T=$(wc -l < fswisweep.log)
grep -v '==== PASS' fswisweep.log
echo "==== fswisweep: $P / $T PASS"
[ "$P" = "$T" ]
