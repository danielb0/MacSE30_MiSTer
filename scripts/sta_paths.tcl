# scripts/sta_paths.tcl - print the worst setup paths of a compiled MacSE30,
# per clock domain, with their nodes and delays.  Read-only; run after a
# compile with
#   quartus_sta -t scripts/sta_paths.tcl [n]
# where n is the number of paths per domain (default 8).  One file per
# domain in output_files/sta_paths_<clock>.txt, and a summary on the console.
set n 8
if {$argc > 0} { set n [lindex $argv 0] }
project_open MacSE30
create_timing_netlist
read_sdc
update_timing_netlist
foreach_in_collection c [get_clocks] {
    set clk [get_clock_info -name $c]
    set fname "output_files/sta_paths_[string map {| _ [ _ ] _ . _ ~ _} $clk].txt"
    set res [report_timing -setup -npaths $n -to_clock $clk -detail path_only -file $fname]
    puts "== $clk : worst setup slack [lindex $res 1] -> $fname"
}
delete_timing_netlist
project_close
