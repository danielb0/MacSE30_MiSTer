#!/usr/bin/env bash
# sim/oddstack: exception frames on an odd stack (gen.py's header) on tb_cpu_int.
# About 3 minutes.  Exit status 0 when every batch passes.
set -u
cd "$(dirname "$0")"
rm -rf batch; python gen.py batch > /dev/null || exit 1
../cputest_int/run.sh "$(pwd)/batch" ${W:-4}
