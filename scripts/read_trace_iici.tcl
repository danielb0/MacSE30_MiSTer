# The Macintosh IIci's bus trace over JTAG (MacIIci.sv "PROBES": PTRC, PTRS,
# PTRD; a USE_DBG_PROBES build).
#
#   quartus_stp -t scripts/read_trace_iici.tcl arm <kind> <watch hex> [post]
#        kind: fetch (a program fetch of watch's long), any (any cycle at
#        watch's long), berr (a bus error; watch ignored), none
#        post: cycles kept after the trigger (default 4096; the ring is 8192)
#        Clears the ring and re-arms.  A reset of the Mac does not clear it.
#   quartus_stp -t scripts/read_trace_iici.tcl status
#   quartus_stp -t scripts/read_trace_iici.tcl dump [before] [after] [file]
#        the cycles around the trigger (default 64 before, 512 after); with
#        no trigger yet, the last `before` cycles
#
# The bus carries only what the caches miss: set the experiment switches to
# 4 (scripts/read_probes_iici.tcl cfg 4) for every fetch and data access.
# Addresses are physical.  A row: its distance from the trigger, F fetch /
# R read / W write, FC, SIZ (0 = long, 1 byte, 2 word, 3 three bytes), the
# address, the data on the bus (a byte or word is in the lanes its address
# and port size name), BERR.

set args $quartus(args)
set cmd [lindex $args 0]
if {$cmd eq ""} { set cmd status }

set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} { puts "ERROR: no JTAG hardware found"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} { puts "ERROR: no Cyclone V FPGA in the chain"; exit 1 }
array set idx {}
array set pw {}
foreach inst [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] {
	set idx([lindex $inst 3]) [lindex $inst 0]; set pw([lindex $inst 3]) [lindex $inst 2]
}
if {![info exists idx(PTRC)] || $pw(PTRD) != 72} { puts "ERROR: not a MacIIci build with the bus trace"; exit 1 }

proc rd {name} {
	global idx
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}
proc f {v hi lo} { return [expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)}] }
proc status {} {
	set s [rd PTRS]; set c [rd PTRC]
	puts [format "trigger: %s at %08x, %d cycles after | frozen %d  triggered %d  wrapped %d  write pointer %d  trigger row %d  cycles seen %u" 		[lindex {none fetch any berr} [f $c 47 46]] [f $c 31 0] [f $c 45 32] [f $s 60 60] [f $s 59 59] [f $s 58 58] [f $s 57 45] [f $s 44 32] [f $s 31 0]]
	return $s
}

start_insystem_source_probe -hardware_name $hw -device_name $dev
if {$cmd eq "arm"} {
	set kind [lsearch {none fetch any berr} [lindex $args 1]]
	if {$kind < 0} { puts "ERROR: kind is fetch, any, berr or none"; end_insystem_source_probe; exit 1 }
	set watch [expr {[lindex $args 2] eq "" ? 0 : "0x[lindex $args 2]"}]
	set post  [expr {[lindex $args 3] eq "" ? 4096 : [lindex $args 3]}]
	# two writes, so the value always changes and the ring is cleared
	write_source_data -instance_index $idx(PTRC) -value_in_hex -value 000000000000
	write_source_data -instance_index $idx(PTRC) -value_in_hex -value [format %012llX [expr {($kind << 46) | (($post & 0x3FFF) << 32) | ($watch & 0xFFFFFFFF)}]]
	status
} elseif {$cmd eq "status"} {
	status
} elseif {$cmd eq "dump"} {
	set before [expr {[lindex $args 1] eq "" ? 64  : [lindex $args 1]}]
	set after  [expr {[lindex $args 2] eq "" ? 512 : [lindex $args 2]}]
	set file   [lindex $args 3]
	set s [status]
	set trig [f $s 59 59]; set full [f $s 58 58]; set wp [f $s 57 45]; set tp [f $s 44 32]
	set have [expr {$full ? 8192 : $wp}]
	if {$trig} {
		set aft [expr {($wp - $tp) & 8191}]              ;# rows from the trigger to the write pointer
		if {$after >= $aft} { set after [expr {$aft - 1}] }
		if {$before > $have - $aft} { set before [expr {$have - $aft}] }
		set first [expr {-$before}]; set last $after; set base $tp
	} else {
		if {$before > $have} { set before $have }
		set first [expr {-$before}]; set last -1; set base $wp
	}
	set out [expr {$file ne "" ? [open $file w] : "stdout"}]
	for {set i $first} {$i <= $last} {incr i} {
		write_source_data -instance_index $idx(PTRD) -value_in_hex -value [format %04X [expr {($base + $i) & 8191}]]
		set r [rd PTRD]
		set fc [f $r 70 68]; set rw [f $r 67 67]
		set k [expr {!$rw ? "W" : (($fc & 3) == 2 ? "F" : "R")}]
		puts $out [format "%6d %s fc %d siz %d  %08x  %08x%s" $i $k $fc [f $r 66 65] [f $r 63 32] [f $r 31 0] [expr {[f $r 71 71] ? "  BERR" : ""}]]
	}
	if {$file ne ""} { close $out; puts "written: $file" }
} else {
	puts "ERROR: arm, status or dump"
}
end_insystem_source_probe
