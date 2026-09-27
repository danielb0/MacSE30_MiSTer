# scripts/sta_corners.tcl - the SDRAM interface's slacks at EVERY timing
# corner, plus the design's worst setup and hold per corner.  Read-only;
# run after a compile with
#   quartus_sta -t scripts/sta_corners.tcl
#
# WHY (2026-09-27, plan 4.11 item 8): the MiSTer template's qsf sets
# TIMEQUEST_MULTICORNER_ANALYSIS OFF, so the compile flow's STA - and the
# "timing met" line scripts/build_only.sh prints from its summary - is the
# slow 100C model alone.  The SDRAM read capture (SDRAM_DQ -> dq_q) had
# -0.128 ns of HOLD at the fast -40C corner while the flow reported +0.906
# setup and +3.232 hold: the next word reaching the capture register before
# the capture edge, which is exactly the $002A002A reset vector the board
# showed.  A number is not "met" until it is met here.
project_open MacSE30
create_timing_netlist
read_sdc
update_timing_netlist
set dq_in  [get_ports {SDRAM_DQ[*]}]
set sd_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_nCAS SDRAM_nRAS SDRAM_nWE SDRAM_nCS SDRAM_CKE SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]}]
set worst 1000
foreach oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    set s  [lindex [report_timing -setup -npaths 1 -from $dq_in  -to [get_keepers {*dq_q[*]}] -detail summary] 1]
    set h  [lindex [report_timing -hold  -npaths 1 -from $dq_in  -to [get_keepers {*dq_q[*]}] -detail summary] 1]
    set os [lindex [report_timing -setup -npaths 1 -to $sd_out -detail summary] 1]
    set oh [lindex [report_timing -hold  -npaths 1 -to $sd_out -detail summary] 1]
    set ds [lindex [report_timing -setup -npaths 1 -detail summary] 1]
    set dh [lindex [report_timing -hold  -npaths 1 -detail summary] 1]
    puts [format "%-24s SDRAM read capture setup %7.3f hold %7.3f | SDRAM outputs setup %7.3f hold %7.3f | design setup %7.3f hold %7.3f" \
        $oc $s $h $os $oh $ds $dh]
    foreach v [list $s $h $os $oh $ds $dh] { if {$v < $worst} { set worst $v } }
}
puts [format "worst slack over every corner: %.3f ns  %s" $worst [expr {$worst < 0 ? "*** TIMING NOT MET ***" : "(met at every corner)"}]]
delete_timing_netlist
project_close
