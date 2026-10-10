# scripts/read_cardtrace.tcl - dump the IIcx card's board trace (plan 14.3
# step 6; rtl/se30_machine.v's tr_mem, MacSE30.sv's PCRT/PCRW, built with
# SE30_CARD_PROBE in MacIIcx.qsf).
#
#   quartus_stp -t scripts/read_cardtrace.tcl [n]
#
# Prints the last n entries (default: all 1024), oldest first: every write
# the card received outside its VRAM, every NuBus timeout, every exception
# but A-line, F-line, interrupts and TRAPs.
set n 1024
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
if {![info exists idx(PCRT)] || ![info exists idx(PCRW)]} { puts "ERROR: no PCRT/PCRW in this bitstream"; exit 1 }

start_insystem_source_probe -hardware_name $hw -device_name $dev
set wp [expr 0b[read_probe_data -instance_index $idx(PCRW)] & 0x3FF]
puts [format "write pointer %d (the next entry; the oldest once wrapped); printing the last %d, oldest first" $wp $n]
set regnames {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15}
for {set i 0} {$i < $n} {incr i} {
	set a [expr {($wp - $n + $i) & 0x3FF}]
	write_source_data -instance_index $idx(PCRT) -value_in_hex -value [format %03X $a]
	set e [expr 0b[read_probe_data -instance_index $idx(PCRT)]]
	set type [expr {($e >> 62) & 3}]
	if {$e == 0} { continue }
	if {$type == 2} {
		puts [format "%4d  EXCEPTION vector %3d  opcode %04X  pc %08X" $a [expr {($e >> 48) & 0xFF}] [expr {($e >> 32) & 0xFFFF}] [expr {$e & 0xFFFFFFFF}]]
	} else {
		set be   [expr {($e >> 58) & 0xF}]
		set fc   [expr {($e >> 55) & 7}]
		set siz  [expr {($e >> 53) & 3}]
		set addr [expr {($e >> 32) & 0xFFFFF}]
		set data [expr {$e & 0xFFFFFFFF}]
		set what ""
		switch [expr {$addr >> 16}] {
			8 { set what [format "register %2d" [expr {($addr >> 2) & 15}]] }
			9 { set what "RAMDAC" }
			10 { set what "VBL area" }
			13 { set what "status" }
			default { set what "?" }
		}
		if {$type == 1} {
			puts [format "%4d  TIMEOUT   slot %05X  cpu %08X  fc %d siz %d be %04b   %s" $a $addr $data $fc $siz $be $what]
		} else {
			puts [format "%4d  write     slot %05X  data %08X  lane3 %02X  fc %d siz %d be %04b   %s" $a $addr $data [expr {($data >> 24) & 0xFF}] $fc $siz $be $what]
		}
	}
}
end_insystem_source_probe
