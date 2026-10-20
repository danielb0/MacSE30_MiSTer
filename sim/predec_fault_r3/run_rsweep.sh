#!/usr/bin/env bash
# Run CASESET=rsweep seeds (random fault-transparency programs, 2026-10-19):
# each seed a random user-mode program run resident and then with random
# code/data/stack pages invalid or write-protected, registers, CCR, the data
# pages and the stack compared (gen_program.py's rsweep), a level-1 interrupt
# raised every 300-2000 clocks (by seed; IRQ=0: none).  8 at a time, ~20 min
# per 8 seeds.
#   ./run_rsweep.sh FIRST COUNT [CACR=0x2101]      the log is rsweep.log
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
FIRST=${1:-0}; COUNT=${2:-16}; shift 2 2>/dev/null
EXTRA="$*"
one() {
  k=$1; d=$HERE/../_r3r_$k
  rm -rf "$d"; mkdir -p "$d"
  cp "$HERE/gen_program.py" "$HERE/tb_predec_fault.v" "$HERE/run.sh" "$d/"
  ie=""; [ "${IRQ:-1}" = 1 ] && ie="+IRQEVERY=$((300 + (k * 7919) % 1701))"   # a level-1 interrupt every 300-2000 clocks, by seed
  r=$(cd "$d" && env CASESET=rsweep RSW=$k TCMODE=aux HANDLER=aux $EXTRA timeout 3600 ./run.sh +UOK +MAXCLK=60000000 $ie 2>&1 | grep -E "^(==== |FAIL)" | head -4 | tr '\n' ' ')
  echo "$k $r"
  rm -rf "$d"
}
export -f one; export HERE EXTRA IRQ
seq $FIRST $((FIRST+COUNT-1)) | xargs -P 8 -I{} bash -c 'one {}' | sort -n > rsweep.log
P=$(grep -c '==== PASS' rsweep.log)
grep -v '==== PASS' rsweep.log
echo "==== rsweep: $P / $COUNT PASS (seeds $FIRST-$((FIRST+COUNT-1)))"
[ "$P" = "$COUNT" ]
