# the experiment's STA: the capture register's slacks under each capture
# clock at every corner, the transfer chain, the outputs at the chip
project_open iotest
create_timing_netlist
read_sdc
update_timing_netlist
set caps [list {A pll|general[2].gpll~PLL_OUTPUT_COUNTER|divclk} {B pll|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]
set dq_in [get_ports {SDRAM_DQ[*]}]
foreach oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    foreach cap $caps {
        set nm [lindex $cap 0]; set ck [get_clocks [lindex $cap 1]]
        set s  [lindex [report_timing -setup -npaths 1 -from $dq_in -to [get_keepers {dq_q[*]}] -to_clock $ck -detail summary] 1]
        set h  [lindex [report_timing -hold  -npaths 1 -from $dq_in -to [get_keepers {dq_q[*]}] -to_clock $ck -detail summary] 1]
        set ws [lindex [report_timing -setup -npaths 1 -from [get_keepers {dq_q[*]}] -to [get_keepers {dq_w[*]}] -to_clock $ck -detail summary] 1]
        set wh [lindex [report_timing -hold  -npaths 1 -from [get_keepers {dq_q[*]}] -to [get_keepers {dq_w[*]}] -to_clock $ck -detail summary] 1]
        set ts [lindex [report_timing -setup -npaths 1 -from [get_keepers {dq_w[*]}] -from_clock $ck -to [get_keepers {dq_m[*]}] -detail summary] 1]
        set th [lindex [report_timing -hold  -npaths 1 -from [get_keepers {dq_w[*]}] -from_clock $ck -to [get_keepers {dq_m[*]}] -detail summary] 1]
        puts [format "%-22s capture %s setup %7.3f hold %7.3f | dq_q -> dq_w %7.3f %7.3f | dq_w -> dq_m %7.3f %7.3f" $oc $nm $s $h $ws $wh $ts $th]
    }
    set cs [lindex [report_timing -setup -npaths 1 -from [get_keepers {dq_m[*]}] -to [get_keepers {q_out*}] -detail summary] 1]
    set ch [lindex [report_timing -hold  -npaths 1 -from [get_keepers {dq_m[*]}] -to [get_keepers {q_out*}] -detail summary] 1]
    set os [lindex [report_timing -setup -npaths 1 -to [get_ports {SDRAM_DQ[*]}] -detail summary] 1]
    set oh [lindex [report_timing -hold  -npaths 1 -to [get_ports {SDRAM_DQ[*]}] -detail summary] 1]
    puts [format "%-22s dq_m -> consumer %7.3f %7.3f | outputs at the chip setup %7.3f hold %7.3f" $oc $cs $ch $os $oh]
}
delete_timing_netlist
project_close
