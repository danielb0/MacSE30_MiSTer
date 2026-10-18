# scripts/read_jtrace.tcl - the jump-to-low-memory trace (KNOWN ISSUES 22;
# rtl/dbg_jtrace.v via dbg_probes.sv's g_jtrace, PJTD/PJTC, built with
# SE30_JTRACE in the qsf).
#
#   quartus_stp -t scripts/read_jtrace.tcl arm [limit] [all]
#   quartus_stp -t scripts/read_jtrace.tcl status
#   quartus_stp -t scripts/read_jtrace.tcl [dump [rows]]
#   quartus_stp -t scripts/read_jtrace.tcl disarm
#
# The ring is ARMED FROM CONFIGURATION, filtered, with the limit A0, so a
# plain boot is traced with nothing to do first; arm (re)clears it, with a
# new limit if given, and "all" turns the filter off (every kernel beat).
# Filtered it keeps user-space beats (FC 1, 2 - the kernel's MOVES too), the
# beats of PMMU instructions, the walker's descriptor cycles for a user
# access, and every PFLUSH.  It wraps until a user program fetch (FC 2) from
# a logical address below the limit (hex; A0 is below every A/UX COFF
# program's text); 24 records later it freezes.  The kernel's own icode
# (init's bootstrap, run once at the start of the Unix boot) jumps to 0 and
# triggers it: dump that, re-arm, and the next trigger is the event.
# dump [rows] prints the last rows records up to the freeze (default all
# 2048).  Reading does not stop or restart the machine.
# A limit with bit 31 set (KNOWN ISSUES 28) triggers on a SUPERVISOR program
# fetch (FC 6) below the limit's low 31 bits instead: `arm 80400000 all`
# freezes on the first instruction of user code (below $400000 under A/UX,
# whose kernel is at $10000000) run in supervisor mode.  Arm it after the
# boot: the Mac OS start-up runs supervisor code low.
# A limit with bits 31:30 = 01 triggers on a supervisor data read (FC 5) of
# the logical address in its low 30 bits - an exception vector fetch:
# `arm 40000010 all` freezes on vector 4 (illegal instruction) under A/UX
# (VBR 0); 4000002C the F-line, 40000008 a bus error.
#
# A beat: t = clk_sys time (14 bits, 31.33 MHz: 523 us a turn); F fetch,
# R read, W write; FC, SIZ, logical and physical address, the data the
# kernel took (a write: drove); its source - bv the kernel's beat_valid,
# FRC force-released by a PMMU fault, HIT answered by a cache or the DIB
# (DHIT: the data cache; Z: a write-only zero), POST a posted write, FLT the
# PMMU fault line, BERR a bus error; DEC the decode beat; the kernel's
# opcode register and its PC.  An event: WALK-R / WALK-W a descriptor cycle
# (its address, the descriptor, and the parked access it translates with
# its FC), or PFLUSH (its EA, MODE, MASK, FC).
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

# PJTD's source: {disarm, allbeats, limit ^ A0 [31:0], row[10:0]} - 0 = armed, filtered, limit A0
proc src_get {} {
	global idx
	return [expr 0x[read_source_data -instance_index $idx(PJTD) -value_in_hex]]
}
proc src_set {v} {
	global idx
	write_source_data -instance_index $idx(PJTD) -value_in_hex -value [format %012llX $v]
}
# PJTC: {records[31:0], write pointer[10:0], trigger row[10:0], full, armed, triggered, frozen, 6'b0}
proc status {} {
	global idx
	set c [expr 0b[read_probe_data -instance_index $idx(PJTC)]]
	set s [src_get]
	puts [format "JTRACE: %s, %s, limit %08X; %u records; write pointer %d%s; %s" \
		[expr {($s >> 44) & 1 ? "disarmed" : "armed"}] [expr {($s >> 43) & 1 ? "all beats" : "filtered"}] \
		[expr {(($s >> 11) & 0xFFFFFFFF) ^ 0xA0}] \
		[expr {($c >> 32) & 0xFFFFFFFF}] [expr {($c >> 21) & 0x7FF}] [expr {(($c >> 9) & 1) ? " (wrapped)" : ""}] \
		[expr {(($c >> 7) & 1) ? [format "TRIGGERED at row %d%s" [expr {($c >> 10) & 0x7FF}] [expr {(($c >> 6) & 1) ? ", frozen" : ", still logging"}]] : "not triggered"}]]
	return $c
}

switch -- $cmd {
	arm {
		set limit 0xA0; set all 0
		foreach a [lrange $argv 1 end] { if {$a eq "all"} { set all 1 } else { set limit [expr 0x$a] } }
		set l [expr {($limit ^ 0xA0) & 0xFFFFFFFF}]
		src_set [expr {(1 << 44) | ($all << 43) | ($l << 11)}]      ;# disarmed: cleared
		src_set [expr {($all << 43) | ($l << 11)}]
		status
	}
	disarm {
		src_set [expr {[src_get] | (1 << 44)}]
		status
	}
	status { status }
	dump {
		set c [status]
		set full [expr {($c >> 9) & 1}]
		set wp [expr {($c >> 21) & 0x7FF}]
		set tp [expr {($c >> 10) & 0x7FF}]
		set trig [expr {($c >> 7) & 1}]
		set s [src_get]
		set n [expr {$full ? 2048 : $wp}]
		if {$argc >= 2 && [lindex $argv 1] < $n} { set n [lindex $argv 1] }
		set first [expr {($wp - $n) & 0x7FF}]
		set base [expr {$s & ~0x7FF}]
		for {set i 0} {$i < $n} {incr i} {
			set row [expr {($first + $i) & 0x7FF}]
			src_set [expr {$base | $row}]
			set q [expr 0b[read_probe_data -instance_index $idx(PJTD)]]
			set q [expr 0b[read_probe_data -instance_index $idx(PJTD)]]   ;# the ring's read is registered: the second read is the row's
			set kind [expr {($q >> 176) & 3}]
			set fc [expr {($q >> 173) & 7}]
			set mark [expr {($trig && $row == $tp) ? ">>" : "  "}]
			set t [expr {($q >> 178) & 0x3FFF}]
			set la [expr {($q >> 139) & 0xFFFFFFFF}]
			set pa [expr {($q >> 107) & 0xFFFFFFFF}]
			set d [expr {($q >> 75) & 0xFFFFFFFF}]
			set op [expr {($q >> 50) & 0xFFFF}]
			set pc [expr {($q >> 18) & 0xFFFFFFFF}]
			if {$kind == 1} {
				if {$fc == 2} {
					puts [format "%s%4d t=%04X PFLUSH ea %08X mode %d%d%d mask %d%d%d fc %d | op %04X @%08X" $mark $row $t $la \
						[expr {($q >> 74) & 1}] [expr {($q >> 73) & 1}] [expr {($q >> 72) & 1}] \
						[expr {($q >> 71) & 1}] [expr {($q >> 70) & 1}] [expr {($q >> 69) & 1}] [expr {($q >> 66) & 7}] $op $pc]
				} else {
					puts [format "%s%4d t=%04X %s desc %08X = %08X  for FC%d %08X | op %04X @%08X" $mark $row $t \
						[expr {$fc == 1 ? "WALK-W" : "WALK-R"}] $la $d [expr {($q >> 72) & 7}] $pa $op $pc]
				}
			} else {
				set flags ""
				foreach {bit name} {74 bv 73 FRC 72 HIT 71 DHIT 70 Z 69 POST 68 FLT 67 BERR 66 DEC} {
					if {($q >> $bit) & 1} { append flags " $name" }
				}
				puts [format "%s%4d t=%04X %s FC%d SIZ%d log %08X phys %08X data %08X |%s | op %04X @%08X" \
					$mark $row $t [lindex {F ? R W} $kind] $fc [expr {($q >> 171) & 3}] $la $pa $d $flags $op $pc]
			}
		}
		src_set $s
	}
	default { puts "usage: read_jtrace.tcl arm \[limit\] \[all\] | status | dump \[rows\] | disarm" }
}
end_insystem_source_probe
