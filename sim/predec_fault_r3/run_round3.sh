#!/usr/bin/env bash
# The third round in one chain (2026-10-20, Daniel: "start on 1, 3 and 5"),
# quickest and most symptom-matched first; the log is round3.log, one line a
# step, and the chain stops at the first step that fails so the failure can be
# read.  Eight sims at a time (the box's eight physical cores); the last two
# random sweeps run together.  About 8-9 hours.
#   ./run_round3.sh [FROM]      FROM = the step to resume at (1-8)
set -u
cd "$(dirname "$0")"
LOG=round3.log
FROM=${1:-1}
step() {   # n name command...: one line, PASS or FAIL with the tail
  n=$1; name=$2; shift 2
  [ "$n" -lt "$FROM" ] && return 0
  t0=$(date +%s)
  out=$("$@" 2>&1); rc=$?
  t=$(( ($(date +%s) - t0) / 60 ))
  if [ $rc = 0 ]; then echo "PASS step $n $name (${t} min): $(echo "$out" | grep -E '^====' | tail -1)" >> $LOG
  else echo "FAIL step $n $name (${t} min, exit $rc): $(echo "$out" | grep -E 'FAIL|====' | head -4 | tr '\n' ' ' | cut -c1-400)" >> $LOG; echo "---- the chain stops at step $n; ./run_round3.sh $((n+1)) resumes" >> $LOG; exit $rc; fi
}
smoke() {   # one run of each new mode, in a scratch copy: a bench or runner fault shows here, not an hour in
  d=../_r3smoke; rm -rf $d; mkdir -p $d; cp gen_program.py tb_predec_fault.v run.sh $d/
  ( set -o pipefail; cd $d &&
    env CASESET=um TCMODE=aux HANDLER=aux ./run.sh +UOK | grep -E '^(====|FAIL)' | head -5 &&
    env CASESET=ssweep SSW=88 TCMODE=aux HANDLER=aux ./run.sh +UOK | grep -E '^(====|FAIL)' | head -5 &&
    env CASESET=ssweep SSW=5 SSW_WP=1 TCMODE=aux HANDLER=aux ./run.sh +UOK | grep -E '^(====|FAIL)' | head -5 &&
    env CASESET=rsweep RSW=0 TCMODE=aux HANDLER=aux ./run.sh +UOK +MAXCLK=80000000 +IRQEVERY=300 +RAMJIT=6 +RAMSEED=0 | grep -E '^(====|FAIL|---- \+RAMJIT)' | head -5 &&
    env CASESET=rsweep RSW=0 RSW_SUPER=1 TCMODE=aux HANDLER=aux ./run.sh +UOK +MAXCLK=80000000 +IRQEVERY=300 | grep -E '^(====|FAIL)' | head -5 &&
    { env CASESET=rsweep RSW=0 PAIR_SANITY=2 TCMODE=aux HANDLER=aux ./run.sh +UOK +MAXCLK=80000000 > sanity.out || true; } &&
    grep -qE '^FAIL' sanity.out && echo "==== PAIR_SANITY=2 fails as it must: $(grep -E '^FAIL' sanity.out | head -1)" &&
    env CASESET=rsweep RSW=0 SDRAM=1 TCMODE=aux HANDLER=aux ./run.sh +UOK +MAXCLK=80000000 +IRQEVERY=300 | grep -E '^(====|FAIL|---- the SDRAM)' | head -5 )
  rc=$?; rm -rf $d; return $rc
}
echo "==== round 3 started $(date '+%Y-%m-%d %H:%M') from step $FROM" >> $LOG
step 1 "smoke (um, ssweep, ssweep WP, jit, super, sanity, sdram - one run each)" smoke
step 2 "scan 3: um - the walker's U/M write-back, 15 cases (CACR 0 and \$2101)" bash -c 'd=../_r3um; rm -rf $d; mkdir -p $d; cp gen_program.py tb_predec_fault.v run.sh $d/; cd $d && CASESET=um TCMODE=aux HANDLER=aux ./run.sh +UOK && CASESET=um TCMODE=aux HANDLER=aux CACR=0x2101 ./run.sh +UOK; r=$?; cd ..; rm -rf _r3um; exit $r'
step 3 "scan 1: ssweep - supervisor MOVES, invalid pages, 130 cases" ./run_ssweep.sh
step 4 "scan 1: ssweep - supervisor MOVES, write-protected pages, 65 cases" ./run_ssweep.sh SSW_WP=1
step 5 "scan 5: rsweep on the SDRAM path, seeds 0-49" ./run_rsweep3.sh sdram 0 50
step 6 "scan 5: rsweep with random RAM latency, seeds 0-49" ./run_rsweep3.sh jit 0 50
step 7 "scan 1: an interrupt at every second clock around 8 supervisor MOVES faults" ./run_irqsweep3.sh
step 8 "scan 1 + 3 together: rsweep in supervisor mode seeds 0-99, and rsweep with the page table compared seeds 0-99" bash -c './run_rsweep3.sh super 0 100 > super.out 2>&1 & p=$!; ./run_rsweep.sh 0 100 > um_rerun.out 2>&1; r2=$?; wait $p; r1=$?; grep -E "^====" super.out um_rerun.out; [ $r1 = 0 ] && [ $r2 = 0 ]'
echo "==== round 3 finished $(date '+%Y-%m-%d %H:%M')" >> $LOG
