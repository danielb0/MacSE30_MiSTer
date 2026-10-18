#!/usr/bin/env bash
# Every predec_fault case set of the regression list with the +UOK check on
# (the bug-class scans, 2026-10-18): each run's user beats and user walks
# must land on pages its cases put code or data in, make invalid, or the
# inline program and the user stack - a stray access fails it even when
# every result is right.  Each job in its own copy of this directory, 8 at
# a time, about an hour.  The sweeps (isweep, dsweep, xsweep) have their own
# runners, which check always.
#   ./run_uok_all.sh            the log is uok_all.log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
JOBS=(
  "memind CASESET=memind CACR=0x2101"
  "memfull_d2 CASESET=memfull MIPART=d MIBD=2 CACR=0x3111"
  "memfull_s1 CASESET=memfull MIPART=s MIBD=1 CACR=0x3111"
  "memfull_d1aux CASESET=memfull MIPART=d MIBD=1 HANDLER=aux"
  "ctx0 CASESET=ctx TCMODE=aux HANDLER=aux"
  "ctx2101 CASESET=ctx TCMODE=aux HANDLER=aux CACR=0x2101"
  "rts0 CASESET=rts RTSONLY=0" "rts1 CASESET=rts RTSONLY=1" "rts2 CASESET=rts RTSONLY=2"
  "rts3 CASESET=rts RTSONLY=3" "rts4 CASESET=rts RTSONLY=4"
  "jsr CASESET=jsr"
  "bf CASESET=bf"
  "aux7_aux CASESET=aux7 TCMODE=aux HANDLER=aux"
  "aux7_auxirq CASESET=aux7 TCMODE=aux HANDLER=auxirq"
  "aux7_auxfull CASESET=aux7 TCMODE=aux HANDLER=auxfull"
  "aux7_auxfullirq CASESET=aux7 TCMODE=aux HANDLER=auxfullirq IRQIN=1"
  "blockmove CASESET=blockmove"
  "straddle CASESET=straddle"
  "wp CASESET=wp"
  "moves CASESET=moves"
)
for k in 0 1 2 3 4 5 6 7; do JOBS+=("ifetch$k CASESET=ifetch IFONLY=$k TCMODE=aux HANDLER=aux"); done
one() {
  name=${1%% *}; envs=${1#* }; d=$HERE/../_uok_$name
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  r=$(cd "$d" && env $envs timeout 2400 ./run.sh +UOK 2>&1 | grep -E "^(==== |FAIL: an exception|FAIL: a user|FAIL: a walk|---- user beats)" | head -6 | tr '\n' ' ')
  echo "$name $r"
  rm -rf "$d"
}
export -f one; export HERE
printf '%s\n' "${JOBS[@]}" | xargs -P 8 -I{} bash -c 'one "{}"' | sort > uok_all.log
P=$(grep -c '==== PASS' uok_all.log)
grep -v '==== PASS' uok_all.log
echo "==== uok_all: $P / ${#JOBS[@]} PASS"
[ "$P" = "${#JOBS[@]}" ]
