# scripts/read_rtrace.tcl - the format $A replay trace (KNOWN ISSUES 20;
# rtl/dbg_rtrace.v via dbg_probes.sv's g_rtrace, PRTD/PRTC, built with
# SE30_RTRACE in the qsf).
#
#   quartus_stp -t scripts/read_rtrace.tcl arm [mask match] [wrap]
#   quartus_stp -t scripts/read_rtrace.tcl status
#   quartus_stp -t scripts/read_rtrace.tcl [dump]
#   quartus_stp -t scripts/read_rtrace.tcl disarm
#
# arm clears the ring and logs every format $A replay whose fault address
# matches ((fault ^ match) & mask) == 0 (hex; default mask 0 = every
# replay), then the next 4 kernel data writes (K) and 6 SDRAM WRITE pairs
# (S) after it.  It stops at 512 records (the earliest kept) unless "wrap"
# is given (the latest kept).  Arm before A/UX starts; dump once the Mac
# environment has bombed.  disarm clears it.
#
# A record: R = the frame as the RTE read it back (state1, SSW, fault
# address, DOB); K = a kernel write as its cycle started (logical and
# physical address, SIZ, data, FC, posted, the long's byte lanes); S = a
# CPU write's two WRITEs at the SDRAM pins (DQM = A12:11 per word, 00 =
# written; the long address in the SDRAM after the SIMM map; both words).
# t = clk_sys time, 16 bits, wrapping (31.33 MHz: 2.09 ms a turn).
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
if {![info exists idx(PRTD)] || ![info exists idx(PRTC)]} { puts "ERROR: no PRTD/PRTC in this bitstream (built with SE30_RTRACE?)"; exit 1 }

start_insystem_source_probe -hardware_name $hw -device_name $dev

# PRTD's source: {arm, wrap, mask[31:0], match[31:0], row[8:0]}
proc src_get {} {
	global idx
	return [expr 0x[read_source_data -instance_index $idx(PRTD) -value_in_hex]]
}
proc src_set {v} {
	global idx
	write_source_data -instance_index $idx(PRTD) -value_in_hex -value [format %019llX $v]
}
proc status {} {
	global idx
	set c [expr 0b[read_probe_data -instance_index $idx(PRTC)]]
	set s [src_get]
	puts [format "RTRACE: %s%s, mask %08X match %08X; %d replays seen, %d matched; %d records%s" \
		[expr {($s >> 74) & 1 ? "armed" : "disarmed"}] [expr {($s >> 73) & 1 ? " (wrap)" : " (stop at 512)"}] \
		[expr {($s >> 41) & 0xFFFFFFFF}] [expr {($s >> 9) & 0xFFFFFFFF}] \
		[expr {($c >> 40) & 0xFFFFFF}] [expr {($c >> 24) & 0xFFFF}] \
		[expr {(($c >> 14) & 1) ? 512 : (($c >> 15) & 0x1FF)}] [expr {(($c >> 14) & 1) ? " (full)" : ""}]]
	return $c
}

switch -- $cmd {
	arm {
		set mask 0; set match 0; set wrap 0
		if {$argc >= 3} { set mask [expr 0x[lindex $argv 1]]; set match [expr 0x[lindex $argv 2]] }
		if {[lsearch $argv wrap] >= 0} { set wrap 1 }
		src_set [expr {($wrap << 73) | (($mask & 0xFFFFFFFF) << 41) | (($match & 0xFFFFFFFF) << 9)}]   ;# disarmed: cleared
		src_set [expr {(1 << 74) | ($wrap << 73) | (($mask & 0xFFFFFFFF) << 41) | (($match & 0xFFFFFFFF) << 9)}]
		status
	}
	disarm {
		src_set [expr {[src_get] & ~(1 << 74)}]
		status
	}
	status { status }
	dump {
		set c [status]
		set full [expr {($c >> 14) & 1}]
		set wp [expr {($c >> 15) & 0x1FF}]
		set s [src_get]
		set wrap [expr {($s >> 73) & 1}]
		set n [expr {$full ? 512 : $wp}]
		set first [expr {($full && $wrap) ? $wp : 0}]
		set base [expr {$s & ~0x1FF}]
		for {set i 0} {$i < $n} {incr i} {
			set row [expr {($first + $i) & 0x1FF}]
			src_set [expr {$base | $row}]
			set q [expr 0b[read_probe_data -instance_index $idx(PRTD)]]
			set q [expr 0b[read_probe_data -instance_index $idx(PRTD)]]   ;# the ring's read is registered: the second read is the row's
			set kind [expr {($q >> 126) & 3}]
			set t [expr {($q >> 110) & 0xFFFF}]
			switch $kind {
				1 {
					puts [format "%3d R t=%04X  SSW %04X state1 %04X  fault %08X  DOB %08X  replay #%d" $row $t \
						[expr {($q >> 94) & 0xFFFF}] [expr {($q >> 78) & 0xFFFF}] [expr {($q >> 46) & 0xFFFFFFFF}] \
						[expr {($q >> 14) & 0xFFFFFFFF}] [expr {$q & 0x3FFF}]]
				}
				2 {
					set siz [expr {($q >> 12) & 3}]
					puts [format "%3d K t=%04X  log %08X phys %08X  data %08X  SIZ %d (%s)  FC %d  %s  lanes %d%d%d%d" $row $t \
						[expr {($q >> 78) & 0xFFFFFFFF}] [expr {($q >> 46) & 0xFFFFFFFF}] [expr {($q >> 14) & 0xFFFFFFFF}] \
						$siz [lindex {long byte word 3-byte} $siz] [expr {($q >> 9) & 7}] \
						[expr {(($q >> 8) & 1) ? "posted" : "waited"}] \
						[expr {($q >> 7) & 1}] [expr {($q >> 6) & 1}] [expr {($q >> 5) & 1}] [expr {($q >> 4) & 1}]]
				}
				3 {
					set long [expr {((($q >> 104) & 3) << 21) | ((($q >> 91) & 0x1FFF) << 8) | (($q >> 83) & 0xFF)}]
					puts [format "%3d S t=%04X  DQM %d%d/%d%d  SDRAM long %06X (byte %08X)  data %04X %04X" $row $t \
						[expr {($q >> 109) & 1}] [expr {($q >> 108) & 1}] [expr {($q >> 107) & 1}] [expr {($q >> 106) & 1}] \
						$long [expr {$long << 2}] [expr {($q >> 66) & 0xFFFF}] [expr {($q >> 50) & 0xFFFF}]]
				}
				default { puts [format "%3d (empty)" $row] }
			}
		}
		src_set $s
	}
	default { puts "usage: read_rtrace.tcl arm \[mask match\] \[wrap\] | status | dump | disarm" }
}
end_insystem_source_probe
