# scripts/read_btrace.tcl - dump the bus-error trace (KNOWN ISSUES 20;
# rtl/dbg_probes.sv's g_btrace, PBTD/PBTC, built with SE30_BTRACE in the qsf).
#
#   quartus_stp -t scripts/read_btrace.tcl [n]
#
# Prints the external ring (every bus error GLUE raised: the bus address,
# FC, direction, at the exception's opcode and PC), then the last n (default
# 256) of the ring of every bus-error exception: the opcode and PC, and the
# PMMU's last fault as it stood (address, MMUSR status, FC, read/write,
# instruction fetch, which kind was pending).  Each entry carries the fault's
# sequence number, so the two rings line up.  Oldest first.  Read the moment
# the Mac environment's bomb appears: A/UX's page faults fill the ring at
# hundreds a second.
set n 256
if {$argc >= 1} { set n [lindex $argv 0] }

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

start_insystem_source_probe -hardware_name $hw -device_name $dev
set c [expr 0b[read_probe_data -instance_index $idx(PBTC)]]
set n_all [expr {($c >> 32) & 0xFFFFFF}]
set n_ext [expr {($c >> 16) & 0xFFFF}]
set wp    [expr {($c >> 8) & 0xFF}]
set wx    [expr {($c >> 3) & 0x1F}]
puts [format "bus-error exceptions: %d in all (write pointer %d), %d external (write pointer %d)" $n_all $wp $n_ext $wx]

proc entry {ring row} {
	global idx
	write_source_data -instance_index $idx(PBTD) -value_in_hex -value [format %03X [expr {($ring << 9) | ($row & 0xFF)}]]
	return [expr 0b[read_probe_data -instance_index $idx(PBTD)]]
}

puts "---- external bus errors (GLUE refused the access), oldest first:"
set k [expr {$n_ext < 32 ? $n_ext : 32}]
for {set i 0} {$i < $k} {incr i} {
	set row [expr {($wx - $k + $i) & 0x1F}]
	set e [entry 1 $row]
	set opc  [expr {($e >> 112) & 0xFFFF}]
	set pc   [expr {($e >> 80) & 0xFFFFFFFF}]
	set addr [expr {($e >> 40) & 0xFFFFFFFF}]
	set fc   [expr {($e >> 33) & 7}]
	set rd   [expr {($e >> 32) & 1}]
	set seq  [expr {$e & 0xFFFFFF}]
	puts [format "  #%-8d opcode %04X at PC %08X   bus error on %s of %08X  FC=%d" $seq $opc $pc [expr {$rd ? "a read" : "a write"}] $addr $fc]
}

puts [format "---- every bus-error exception, the last %d, oldest first:" $n]
set k [expr {$n < 256 ? $n : 256}]
for {set i 0} {$i < $k} {incr i} {
	set row [expr {($wp - $k + $i) & 0xFF}]
	set e [entry 0 $row]
	set opc [expr {($e >> 112) & 0xFFFF}]
	set pc  [expr {($e >> 80) & 0xFFFFFFFF}]
	set f   [expr {($e >> 24) & ((1 << 56) - 1)}]
	set seq [expr {$e & 0xFFFFFF}]
	set fa  [expr {$f & 0xFFFFFFFF}]
	set ms  [expr {($f >> 32) & 0xFFFF}]
	set fc  [expr {($f >> 48) & 7}]
	set rd  [expr {($f >> 51) & 1}]
	set ins [expr {($f >> 52) & 1}]
	set mmu [expr {($f >> 53) & 1}]
	set bus [expr {($f >> 54) & 1}]
	if {$e == 0} { continue }
	set bits {}
	foreach {b nm} {15 B 14 L 13 S 11 W 10 I 9 M 6 T} { if {($ms >> $b) & 1} { lappend bits $nm } }
	puts [format "  #%-8d opcode %04X at PC %08X   PMMU fault at %08X %s FC=%d%s  MMUSR=%04X (%s, levels %d)  pending: MMU=%d bus=%d" \
		$seq $opc $pc $fa [expr {$rd ? "read" : "write"}] $fc [expr {$ins ? " insn" : ""}] \
		$ms [expr {[llength $bits] ? [join $bits " "] : "-"}] [expr {$ms & 7}] $mmu $bus]
}
end_insystem_source_probe
