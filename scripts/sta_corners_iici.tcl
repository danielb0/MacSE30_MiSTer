# scripts/sta_corners_iici.tcl - scripts/sta_corners.tcl for the MacIIci revision
# (SE30_PLAN.md "THE MacIIci TOP AND ITS SDRAM"): rtl/iici_sdram.v's capture
# chain at 100 MHz, its consumers, the SDRAM pins and every register-to-
# register path at every corner.  The capture phases are PROVISIONAL; the
# per-corner setup and hold of A and B here are what re-derive them.
#   quartus_sta -t scripts/sta_corners_iici.tcl
# scripts/sta_corners.tcl - the SDRAM interface's slacks at EVERY timing
# corner, the read capture under EACH of its two clocks, and the design's
# worst setup and hold per corner.  Read-only; run after a compile with
#   quartus_sta -t scripts/sta_corners.tcl
#
# WHY (2026-09-27, plan 4.11 item 8): the MiSTer template's qsf set
# TIMEQUEST_MULTICORNER_ANALYSIS OFF, so the compile flow's STA - and the
# "timing met" line scripts/build_only.sh prints from its summary - was the
# slow 100C model alone.  The SDRAM read capture (SDRAM_DQ -> dq_q) had
# -0.128 ns of HOLD at the fast -40C corner while the flow reported +0.906
# setup and +3.232 hold: the next word reaching the capture register before
# the capture edge, which is exactly the $002A002A reset vector the board
# showed.  A number is not "met" until it is met here.
#
# Since plan 3.8 item 18 MacSE30.qsf has multicorner analysis ON, and the
# capture is two-valued: dq_q clocks on capture A (clk_mem - 0.266 ns, PLL
# output 3) or B (clk_mem - 2.261 ns, output 4) as the power-up training
# chooses.  MacSE30.sdc cuts the capture for the compile flow (the fitter
# and STA cannot judge a path that is meant to fail under one of two
# clocks at each corner) and constrains it only when se30_time_capture is
# set, which this script does.  The reading: at every corner at least one
# capture met on setup and hold - the expectation is A at the slow corners
# by >= 1.40 ns and B at the fast ones by >= 1.89 (item 18's experiment);
# every other SDRAM path met at every corner.
set ::iici_time_capture 1
# the IIci's: quartus_sta -t scripts/sta_corners_iici.tcl
set rev "MacIIci"
if {[info exists quartus(args)] && [llength $quartus(args)] > 0} { set rev [lindex $quartus(args) 0] }
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist
set dq_in  [get_ports {SDRAM_DQ[*]}]
set dq_q   [get_keepers {*|iici_sdram:sdram|dq_q[*]}]
set dq_r   [get_keepers {*|iici_sdram:sdram|dq_r[*]}]
set rdata  [get_keepers {*|iici_sdram:sdram|m_rdata[*] *|iici_sdram:sdram|hi_w[*] *|iici_sdram:sdram|mb[*][*] *|iici_sdram:sdram|vb[*][*] *|iici_sdram:sdram|tr_w1[*] *|iici_sdram:sdram|tr_good[*] *|iici_sdram:sdram|dk_rdata[*]}]
set sd_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]}]
set caps [list \
    [list "A (clk_mem+1.667)" [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]] \
    [list "B (clk_mem+0.3125)" [get_clocks {emu|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}]]]
set worst 1000
set cap_ok_everywhere 1
foreach oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    set best -1000
    foreach cap $caps {
        set nm [lindex $cap 0]; set ck [lindex $cap 1]
        set s  [lindex [report_timing -setup -npaths 1 -from $dq_in -to $dq_q -to_clock $ck -detail summary] 1]
        set h  [lindex [report_timing -hold  -npaths 1 -from $dq_in -to $dq_q -to_clock $ck -detail summary] 1]
        set ws [lindex [report_timing -setup -npaths 1 -from $dq_q -from_clock $ck -to $dq_r -detail summary] 1]
        set wh [lindex [report_timing -hold  -npaths 1 -from $dq_q -from_clock $ck -to $dq_r -detail summary] 1]
        set m [expr {min($s, $h)}]
        if {$m > $best} { set best $m }
        puts [format "%-22s capture %-18s setup %7.3f hold %7.3f | dq_q -> dq_r %7.3f %7.3f" $oc $nm $s $h $ws $wh]
        foreach v [list $ws $wh] { if {$v < $worst} { set worst $v } }
    }
    if {$best < 0} { set cap_ok_everywhere 0 }
    set cs [lindex [report_timing -setup -npaths 1 -from $dq_r -to $rdata -detail summary] 1]
    set ch [lindex [report_timing -hold  -npaths 1 -from $dq_r -to $rdata -detail summary] 1]
    set os [lindex [report_timing -setup -npaths 1 -to $sd_out -detail summary] 1]
    set oh [lindex [report_timing -hold  -npaths 1 -to $sd_out -detail summary] 1]
    set ds [lindex [report_timing -setup -npaths 1 -detail summary] 1]
    set dh [lindex [report_timing -hold  -npaths 1 -detail summary] 1]
    # every register-to-register path: the capture starts at the SDRAM_DQ
    # pins, so this is the design without it - the column that must not
    # be hidden behind the capture's own numbers (plan 9.8, compile 29:
    # an se30_sdram dq_out path at -0.109 sat behind the capture's -0.370)
    set rs [lindex [report_timing -setup -npaths 1 -from [all_registers] -to [all_registers] -detail summary] 1]
    set rh [lindex [report_timing -hold  -npaths 1 -from [all_registers] -to [all_registers] -detail summary] 1]
    puts [format "%-22s best capture margin %7.3f | dq_r -> consumers %7.3f %7.3f | SDRAM outputs setup %7.3f hold %7.3f | design setup %7.3f hold %7.3f | reg-to-reg setup %7.3f hold %7.3f" $oc $best $cs $ch $os $oh $ds $dh $rs $rh]
    foreach v [list $cs $ch $os $oh $rs $rh] { if {$v < $worst} { set worst $v } }
}
puts [format "worst slack over every corner, the capture excepted (the capture chain, the SDRAM pins, every register-to-register path): %.3f ns  %s" $worst [expr {$worst < 0 ? "*** TIMING NOT MET ***" : "(met at every corner)"}]]
puts [format "the capture: %s" [expr {$cap_ok_everywhere ? "at every corner at least one of A and B is met on setup and hold" : "*** A CORNER WHERE NEITHER CAPTURE IS MET ***"}]]
puts "the design's own worst slack per corner above includes the framework's paths, whose verdict is the flow's summary"
delete_timing_netlist
project_close
