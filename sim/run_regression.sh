#!/usr/bin/env bash
# The CPU regression list in one run (2026-10-18, after the bug-class scans):
# phase 1 the benches, 8 at a time, each in its own directory (the cpfpu
# programs each in a copy of sim/cpfpu); phase 2 the fault sweeps one after
# another (each runs 8 at a time), with the caches off and with A/UX's CACR
# $2101.  About 3 hours.  The log is sim/regression.log; exit status 0 when
# every line passed.
#   ./run_regression.sh [phase1|phase2]
set -u
cd "$(dirname "$0")"
SIM=$(pwd)
LOG=$SIM/regression.log
WHAT=${1:-all}
job() {   # name dir command...: one line, PASS or FAIL with the run's tail
  name=$1; dir=$2; shift 2
  out=$(cd "$SIM/$dir" && "$@" 2>&1); rc=$?
  if [ $rc = 0 ]; then echo "PASS $name"; else echo "FAIL $name (exit $rc): $(echo "$out" | grep -E 'FAIL|====' | head -4 | tr '\n' ' ' | cut -c1-300)"; fi
}
cpjob() { # name prog env...: a cpfpu program in its own copy of the bench
  name=$1; prog=$2; shift 2
  d=$SIM/_cpr_$name; rm -rf "$d"; mkdir -p "$d"
  cp "$SIM/cpfpu/gen_program.py" "$SIM/cpfpu/tb_cpfpu.v" "$SIM/cpfpu/run.sh" "$d/"
  r=$(job "cpfpu $name" "_cpr_$name" env PROG=$prog "$@" ./run.sh); echo "$r"; rm -rf "$d"
}
export -f job cpjob; export SIM
if [ "$WHAT" != phase2 ]; then
  {
    echo "job 'insn_probe (bare, wrapper CACR 0, \$0101)' insn_probe bash -c './run.sh && ./run_wrapper.sh && CACR=0x0101 ./run_wrapper.sh'"
    for b in mmu16 machine system pmmu_rom_contract busfault busfault_dib kernel_bus rtr_fc cache030; do echo "job $b $b ./run.sh"; done
    for p in b1 b2 b3a b3b b3c b3u b3n b3s b3r b5a b5b b5c b5d b5u b7e mmu b4 cmpm; do echo "cpjob $p $p"; done
    # (b3u under the caches: its FM3 bus error is absorbed by the data cache, a bench
    # artefact - SE30_PLAN.md KNOWN ISSUES 28's notes - so only b3r and b5u run with them)
    for p in b3r b5u; do echo "cpjob ${p}_2101 $p B3_CACR=0x2101"; done
    # (KNOWN ISSUES 38: xeyes's shapes under A/UX's context switch - random, and at every suspended dialog)
    echo "cpjob b3x b3x B3R_N=8"; echo "cpjob b3x_dlg b3x B3R_N=8 B3X_DLG=1"
  } | xargs -d '\n' -P 8 -I{} bash -c '{}' | sort > "$LOG.1"
  cat "$LOG.1"
fi
if [ "$WHAT" != phase1 ]; then
  {
    for c in 0 0x2101; do
      for s in "predec_fault ./run_isweep.sh" "predec_fault ./run_dsweep.sh" "predec_fault ./run_dsweep.sh DSW_WP=1" "predec_fault ./run_xsweep.sh"                "predec_fault ./run_ssweep.sh" "predec_fault ./run_ssweep.sh SSW_WP=1"; do   # (the third round: supervisor MOVES, KNOWN ISSUES 34)
        set -- $s; d=$1; shift
        r=$(cd "$SIM/$d" && "$@" CACR=$c 2>&1 | tail -1); echo "$r CACR=$c $*"
      done
      for w in 0 1; do
        r=$(cd "$SIM/cpfpu" && ./run_fsweep.sh B3_CACR=$c FSW_WP=$w 2>&1 | tail -1); echo "$r B3_CACR=$c FSW_WP=$w"
      done
      r=$(cd "$SIM/cpfpu" && ./run_fifsweep.sh B3_CACR=$c 2>&1 | tail -1); echo "$r"   # (KNOWN ISSUES 38/39: an FPU fetch faulting mid-dialog)
      for w in 0 1; do   # (the FPU sweep gap's item 1: data faults over every EA form)
        r=$(cd "$SIM/cpfpu" && ./run_fsxsweep.sh B3_CACR=$c FSX_WP=$w 2>&1 | tail -1); echo "$r"
      done
    done
    r=$(cd "$SIM/predec_fault" && ./run_uok_all.sh 2>&1 | tail -1); echo "$r"
    r=$(cd "$SIM/cpfpu" && ./run_fifsweep.sh FIF_IRQ=1 2>&1 | tail -1); echo "$r"   # (... with A/UX's switch at the suspended dialog)
    r=$(cd "$SIM/cpfpu" && ./run_fifsweep.sh FIF_SUPER=1 2>&1 | tail -1); echo "$r"   # (KNOWN ISSUES 40/41: supervisor, the PMMU forms; 42/43 deferred)
    for c in 0 0x2101; do   # the third round: the walker's U/M write-back (UM 9.5.3), 15 cases
      job "um U/M write-back CACR=$c" predec_fault bash -c "d=../_um_$c; rm -rf \$d; mkdir \$d; cp gen_program.py tb_predec_fault.v run.sh \$d/; cd \$d && CASESET=um TCMODE=aux HANDLER=aux CACR=$c ./run.sh +UOK; r=\$?; cd ..; rm -rf \$d; exit \$r"
    done
    for c in 0 0x2101; do   # the fourth round: KNOWN ISSUES 36's other side - a real zero divisor still traps, 8 cases
      job "zdiv zero-divide traps CACR=$c" predec_fault bash -c "d=../_zd_$c; rm -rf \$d; mkdir \$d; cp gen_program.py tb_predec_fault.v run.sh \$d/; cd \$d && CASESET=zdiv TCMODE=aux HANDLER=aux CACR=$c ./run.sh +UOK; r=\$?; cd ..; rm -rf \$d; exit \$r"
    done
    for c in 0 0x2101; do   # KNOWN ISSUES 37's class: an address register stored through its own (An)+/-(An), 132 cases
      r=$(cd "$SIM/predec_fault" && ./run_selfst.sh CACR=$c 2>&1 | tail -1); echo "$r"
    done
    job "bfx (KNOWN ISSUES 21)" predec_fault bash -c 'd=../_bfx; rm -rf $d; mkdir $d; cp gen_program.py tb_predec_fault.v run.sh $d/; cd $d && CASESET=bfx ./run.sh +UOK; r=$?; cd ..; rm -rf _bfx; exit $r'
  } > "$LOG.2"
  cat "$LOG.2"
fi
cat "$LOG.1" "$LOG.2" 2>/dev/null > "$LOG"
N=$(grep -c . "$LOG"); P=$(grep -cE '^PASS|: ([0-9]+) / \1 (parts )?PASS' "$LOG")
echo "==== regression: $P / $N lines pass"
[ "$P" = "$N" ]
