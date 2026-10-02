#!/bin/bash
# Build WinUAE's cputest generator on Linux (WSL Ubuntu, g++) for the
# 68882 corpus - plan 8.9.8.  WinUAE builds it with Visual Studio; here:
# the Windows project's sources (od-win32/cputester/cputester.vcxproj),
# the od-unix port's headers, od-win32's machdep/m68k.h (the tester's flag
# layout - od-unix's defines cctrue inline, which cputest.cpp defines too),
# wprintf -> printf and _wmkdir -> mkdir, od-unix/charset.cpp for the
# string helpers, and se30dump.py's text records.
#
#   build.sh <WinUAE clone> <build dir>
# e.g. build.sh /mnt/c/Git/MiSTer-devel/WinUAE ~/winuae   (WinUAE 12ad6ac)
set -e
SRC=$1; B=$2; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$B"; cp -r "$SRC" "$B"; cd "$B"
CF="-w -fpermissive -O2 -Iovl -Iod-unix -Iinclude -I."
mkdir -p ovl/machdep obj
cp od-win32/machdep/m68k.h ovl/machdep/m68k.h
cp "$HERE/wshim.h" ovl/
# 1. the test cores: gencpu with CPU_TESTER (cpudefs.cpp is in the tree)
sed -i 's/^#define CPU_TESTER 0$/#define CPU_TESTER 1/' gencpu.cpp
g++ $CF -c od-unix/charset.cpp -o obj/charset.o
g++ $CF -o gencpu gencpu.cpp readcpu.cpp cpudefs.cpp missing.cpp obj/charset.o
./gencpu > gencpu.log
# 2. the generator
sed -i "s/wprintf(/printf(/g" cputest.cpp cputest_support.cpp
python3 "$HERE/se30dump.py" cputest.cpp
CF="$CF -include ovl/wshim.h -DCPUEMU_90 -DCPUEMU_91 -DCPUEMU_92 -DCPUEMU_93 -DCPUEMU_94 -DCPUEMU_95 -DCPU_TESTER"
for f in cpudefs.cpp cpuemu_90_test.cpp cpuemu_91_test.cpp cpuemu_92_test.cpp cpuemu_93_test.cpp \
         cpuemu_94_test.cpp cpuemu_95_test.cpp cpustbl_test.cpp cputest.cpp cputest_support.cpp disasm.cpp \
         fpp.cpp fpp_softfloat.cpp ini.cpp newcpu_common.cpp readcpu.cpp softfloat/softfloat.cpp \
         softfloat/softfloat_decimal.cpp softfloat/softfloat_fpsp.cpp; do
  g++ $CF -c $f -o obj/$(echo $f | tr / _).o
done
g++ -o cputestgen obj/*.o -lz
echo "built $B/cputestgen"
