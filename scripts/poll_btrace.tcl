# scripts/poll_btrace.tcl - follow the bus-error trace for a whole boot
# (KNOWN ISSUES 20; the same probes as read_btrace.tcl, SE30_BTRACE builds).
#
#   quartus_stp -t scripts/poll_btrace.tcl [seconds] [from]
#
# Keeps one probe session open and reads the ring of every bus-error
# exception over and over, printing each entry once, oldest first, with the
# seconds since the poll began.  The ring holds 256; a burst of more between
# two reads prints a GAP line with the number lost.  Runs for [seconds]
# (default 1800).  [from] = 0 (default) starts with what the ring holds now;
# a sequence number skips everything up to it.  Start it before the boot and
# redirect it to a file; the entries join with read_btrace.tcl's by number.
set secs 1800
set from 0
if {$argc >= 1} { set secs [lindex $argv 0] }
if {$argc >= 2} { set from [lindex $argv 1] }

set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} { set all [get_hardware_names]; if {[llength $all] > 0} { set hw [lindex $all 0] } }
if {$hw eq ""} { puts "ERROR: no JTAG hardware found"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} { puts "ERROR: no Cyclone V FPGA in the chain"; exit 1 }
set info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
if {![info exists idx(PBTD)] || ![info exists idx(PBTC)]} { puts "ERROR: no PBTD/PBTC in this bitstream (built with SE30_BTRACE?)"; exit 1 }

proc entry {row} {
	global idx
	write_source_data -instance_index $idx(PBTD) -value_in_hex -value [format %03X [expr {$row & 0xFF}]]
	return [expr 0b[read_probe_data -instance_index $idx(PBTD)]]
}

start_insystem_source_probe -hardware_name $hw -device_name $dev
set t0 [clock milliseconds]
set last -1
set polls 0
while {[clock milliseconds] - $t0 < $secs * 1000} {
	set c [expr 0b[read_probe_data -instance_index $idx(PBTC)]]
	set n  [expr {($c >> 32) & 0xFFFFFF}]
	set wp [expr {($c >> 8) & 0xFF}]
	set t  [expr {([clock milliseconds] - $t0) / 1000.0}]
	incr polls
	if {$last < 0} {
		set last [expr {$from > 0 ? $from : ($n > 256 ? $n - 256 : 0)}]
		puts [format "%8.1f  poll start: %d bus-error exceptions so far" $t $n]
	}
	if {$n < $last} { puts [format "%8.1f  COUNT FELL %d -> %d (reset?)" $t $last $n]; set last 0 }
	set new [expr {$n - $last}]
	if {$new > 256} { puts [format "%8.1f  GAP: %d entries lost" $t [expr {$new - 256}]]; set new 256 }
	for {set i 0} {$i < $new} {incr i} {
		set e [entry [expr {$wp - $new + $i}]]
		set opc [expr {($e >> 112) & 0xFFFF}]
		set pc  [expr {($e >> 80) & 0xFFFFFFFF}]
		set f   [expr {($e >> 24) & ((1 << 56) - 1)}]
		set seq [expr {$e & 0xFFFFFF}]
		set fa  [expr {$f & 0xFFFFFFFF}]
		set ms  [expr {($f >> 32) & 0xFFFF}]
		set fc  [expr {($f >> 48) & 7}]
		set rd  [expr {($f >> 51) & 1}]
		set ins [expr {($f >> 52) & 1}]
		set bits {}
		foreach {b nm} {15 B 14 L 13 S 11 W 10 I 9 M 6 T} { if {($ms >> $b) & 1} { lappend bits $nm } }
		puts [format "%8.1f  #%-8d opcode %04X at PC %08X   PMMU fault at %08X %s FC=%d%s  MMUSR=%04X (%s)" \
			$t $seq $opc $pc $fa [expr {$rd ? "read" : "write"}] $fc [expr {$ins ? " insn" : ""}] \
			$ms [expr {[llength $bits] ? [join $bits " "] : "-"}]]
	}
	set last $n
	flush stdout
	after 200
}
puts [format "poll end: %d polls, %d bus-error exceptions" $polls $last]
end_insystem_source_probe
