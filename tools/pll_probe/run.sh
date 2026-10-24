#!/usr/bin/env bash
# run.sh <variant>... - build each placement variant of the probe and extract
# the PLL / clock-switch placements (or the fitter's error) into results/<v>.txt
cd "$(dirname "$0")" || exit 1
# Quartus from the repo's scripts/local.env, as build_only.sh
[ -r ../../scripts/local.env ] && . ../../scripts/local.env
export PATH="${QUARTUS_BIN:-/c/intelFPGA_lite/17.0/quartus/bin64}:$PATH"
mkdir -p results
for v in "$@"; do
	[ -r "variants/$v.qsf" ] || { echo "no variants/$v.qsf"; continue; }
	case "$v" in e6a*) F=pll6a.qsf;; e6b*) F=pll6b.qsf;; e6c*) F=pll6c.qsf;; *) F=pll5.qsf;; esac
	cat base.qsf "$F" "variants/$v.qsf" > probe.qsf
	rm -rf db incremental_db output_files
	t0=$(date +%s)
	quartus_map probe > "results/$v.map.log" 2>&1 || { echo "$v: MAP FAILED"; grep -m5 "^Error" "results/$v.map.log"; continue; }
	quartus_fit probe > "results/$v.fit.log" 2>&1
	rc=$?
	t1=$(date +%s)
	R=output_files/probe.fit.rpt
	{
		echo "== $v  (fit rc=$rc, $((t1-t0)) s) =="
		cat "variants/$v.qsf"
		echo "-- errors --"
		grep "Error (" "$R" | grep -v "^Error (11802)\|^Error: Quartus" | cut -c1-260
		echo "-- PLLs --"
		awk '/PLL Usage Summary/{p=1;n=0} p&&/^\+-+/{n++; if(n>=3)p=0} p&&/^; [a-z_]+:/{name=$2} p&&/PLL Location|Refclk Select Location|Reference Clock Sourced|CLKIN\(0\) source/{print name" "$0} p&&/output_counter ;/{cnt=$2} p&&/Output Clock Location|Output Clock Frequency|C Counter ;/{print "   "cnt" "$0}' "$R" | sed 's/  */ /g' | cut -c1-200
		echo "-- clock switches / global buffers --"
		grep "hdmi_tx_clk\|vga_tx_clk\|cap_clkctrl\|CLKCTRL_G\|CLKSEL_" "$R" | grep -v "Info\|Warning\|CLKENA0" | sed 's/  */ /g' | cut -c1-230
	} > "results/$v.txt"
	cat "results/$v.txt"
done
