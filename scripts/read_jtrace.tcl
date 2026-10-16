# scripts/read_jtrace.tcl - the jump-to-low-memory trace (KNOWN ISSUES 22;
# rtl/dbg_jtrace.v via dbg_probes.sv's g_jtrace, PJTD/PJTC, built with
# SE30_JTRACE in the qsf).
#
#   quartus_stp -t scripts/read_jtrace.tcl arm [limit]
#   quartus_stp -t scripts/read_jtrace.tcl status
#   quartus_stp -t scripts/read_jtrace.tcl [dump]
#   quartus_stp -t scripts/read_jtrace.tcl disarm
#
# The ring is ARMED FROM CONFIGURATION with the limit A0, so a plain boot
# is traced with nothing to do first; arm (re)clears it, with a new limit if
# given.  Armed, it logs every beat the kernel takes, wrapping, until a user
# program fetch (FC 2) from a logical address below the limit (hex, A0 is
# below every A/UX COFF program's text); 24 records later it freezes.
# Dump once the machine is hung: reading does not stop or restart it.
#
# A record: t = clk_sys time (14 bits, 31.33 MHz: 523 us a turn); the beat
# (F fetch, R read, W write), FC, SIZ, logical and physical address, the
# data the kernel took (a write: drove); then its source - bv the kernel's
# beat_valid, FRC force-released by a PMMU fault, HIT answered by a cache or
# the DIB (DHIT: the data cache; Z: a write-only zero), POST a posted write,
# FLT the PMMU fault line, BERR a bus error; DEC the decode beat, and the
# kernel's opcode register with its PC.
set cmd dump
if {$argc >= 1} { set cmd [lindex $argv 0] }

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
if {![info exists idx(PJTD)] || ![info exists idx(PJTC)]} { puts "ERROR: no PJTD/PJTC in this bitstream (built with SE30_JTRACE?)"; exit 1 }

start_insystem_source_probe -hardware_name $hw -device_name $dev

# PJTD's source: {disarm, limit ^ A0 [31:0], row[8:0]} - 0 is armed, limit A0
proc src_get {} {
	global idx
	return [expr 0x[read_source_data -instance_index $idx(PJTD) -value_in_hex]]
}
proc src_set {v} {
	global idx
	write_source_data -instance_index $idx(PJTD) -value_in_hex -value [format %011llX $v]
}
# PJTC: {beats[31:0], write pointer[8:0], trigger row[8:0], full, armed, triggered, frozen, 10'b0}
proc status {} {
	global idx
	set c [expr 0b[read_probe_data -instance_index $idx(PJTC)]]
	set s [src_get]
	puts [format "JTRACE: %s, limit %08X; %u beats; write pointer %d%s; %s" \
		[expr {($s >> 41) & 1 ? "disarmed" : "armed"}] [expr {(($s >> 9) & 0xFFFFFFFF) ^ 0xA0}] \
		[expr {($c >> 32) & 0xFFFFFFFF}] [expr {($c >> 23) & 0x1FF}] [expr {(($c >> 13) & 1) ? " (wrapped)" : ""}] \
		[expr {(($c >> 11) & 1) ? [format "TRIGGERED at row %d%s" [expr {($c >> 14) & 0x1FF}] [expr {(($c >> 10) & 1) ? ", frozen" : ", still logging"}]] : "not triggered"}]]
	return $c
}

switch -- $cmd {
	arm {
		set limit 0xA0
		if {$argc >= 2} { set limit [expr 0x[lindex $argv 1]] }
		set l [expr {($limit ^ 0xA0) & 0xFFFFFFFF}]
		src_set [expr {(1 << 41) | ($l << 9)}]                     ;# disarmed: cleared
		src_set [expr {$l << 9}]
		status
	}
	disarm {
		src_set [expr {[src_get] | (1 << 41)}]
		status
	}
	status { status }
	dump {
		set c [status]
		set full [expr {($c >> 13) & 1}]
		set wp [expr {($c >> 23) & 0x1FF}]
		set tp [expr {($c >> 14) & 0x1FF}]
		set trig [expr {($c >> 11) & 1}]
		set s [src_get]
		set n [expr {$full ? 512 : $wp}]
		set first [expr {$full ? $wp : 0}]
		set base [expr {$s & ~0x1FF}]
		for {set i 0} {$i < $n} {incr i} {
			set row [expr {($first + $i) & 0x1FF}]
			src_set [expr {$base | $row}]
			set q [expr 0b[read_probe_data -instance_index $idx(PJTD)]]
			set q [expr 0b[read_probe_data -instance_index $idx(PJTD)]]   ;# the ring's read is registered: the second read is the row's
			set bs [expr {($q >> 176) & 3}]
			set flags ""
			foreach {bit name} {74 bv 73 FRC 72 HIT 71 DHIT 70 Z 69 POST 68 FLT 67 BERR 66 DEC} {
				if {($q >> $bit) & 1} { append flags " $name" }
			}
			puts [format "%s%3d t=%04X %s FC%d SIZ%d log %08X phys %08X data %08X |%s | op %04X @%08X" \
				[expr {($trig && $row == $tp) ? ">>" : "  "}] $row [expr {($q >> 178) & 0x3FFF}] \
				[lindex {F ? R W} $bs] [expr {($q >> 173) & 7}] [expr {($q >> 171) & 3}] \
				[expr {($q >> 139) & 0xFFFFFFFF}] [expr {($q >> 107) & 0xFFFFFFFF}] [expr {($q >> 75) & 0xFFFFFFFF}] \
				$flags [expr {($q >> 50) & 0xFFFF}] [expr {($q >> 18) & 0xFFFFFFFF}]]
		}
		src_set $s
	}
	default { puts "usage: read_jtrace.tcl arm \[limit\] | status | dump | disarm" }
}
end_insystem_source_probe
