# scripts/aux_putbuf.tcl - A/UX's kernel console log, read from a hung or
# crashed machine (SE30_PLAN.md KNOWN ISSUES 20: after compile 71 the Mac
# environment's process, startmac, vanished and the screen stayed grey -
# its death notice, if the kernel printed one, is in this ring).
#
#   quartus_stp -t scripts/aux_putbuf.tcl [keep]
#
# One peek session (the machine is held in reset; it restarts at the end
# unless "keep" is given, so another peek script can follow).  The kernel's
# file header places .data (kernel $11000000) at physical $ED000 and .bss
# ($12000000) at $FF000: putbuf ($120199F4, 10000 bytes, putchar's ring) at
# $1189F4, putindx ($11005B1C) at $F2B1C, putwrap ($11005B24) at $F2B24.
# The proc pointer ($12006D30 -> $105D30) must read the table's $1BC880,
# else the mapping is not what this assumes.  Prints the ring oldest first.
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
foreach need {PPEK PPOK} { if {![info exists idx($need)]} { puts "ERROR: no $need in this bitstream"; exit 1 } }
start_insystem_source_probe -hardware_name $hw -device_name $dev

proc rd {name} { global idx; return [expr 0b[read_probe_data -instance_index $idx($name)]] }
set ::go 0
set ::pk_ok 1
proc pk_op {flags lw} {
	global idx go
	set src [expr {(1 << 30) | ($flags << 28) | ($lw & 0x7FFFFF)}]
	set before [expr {([rd PPEK] >> 32) & 0xFF}]
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X [expr {$src | ($go << 31)}]]
	set go [expr {1 - $go}]
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X [expr {$src | ($go << 31)}]]
	set tries 0
	while {1} {
		set v [rd PPEK]
		if {(($v >> 32) & 0xFF) != $before} { set ::pk_ok 1; return [expr {$v & 0xFFFFFFFF}] }
		if {[incr tries] >= 50} { set ::pk_ok 0; return 0 }
		after 2
	}
}
proc pk_poke {lw data be} {
	global idx
	write_source_data -instance_index $idx(PPOK) -value_in_hex -value [format %016llX [expr {($be << 32) | ($data & 0xFFFFFFFF)}]]
	return [pk_op 2 $lw]
}
proc release {} { global idx; write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000; puts "machine released from reset (it restarts)" }
# a longword at a physical BYTE address (4-aligned)
proc pl {b} {
	# a peek that timed out (rare, ~1 %) is retried; the hold stays up throughout
	for {set k 0} {$k < 4} {incr k} {
		set r [pk_op 0 [expr {$b >> 2}]]
		if {$::pk_ok} { return $r }
	}
	return $r
}
proc pw {b} { set v [pl [expr {$b & ~3}]]; return [expr {($b & 2) ? ($v & 0xFFFF) : ($v >> 16)}] }
# an unaligned longword
proc plu {b} { if {($b & 3) == 0} { return [pl $b] }; return [expr {(([pw $b] << 16) | [pw [expr {$b + 2}]]) & 0xFFFFFFFF}] }

# the first operation of a session flushes the controller (read_probes.tcl)
pk_poke 0x5FFFFE 0 0xF

set procp [pl 0x105D30]
puts [format "proc pointer (kernel \$12006D30, physical \$105D30) = %08X (the table is at \$1BC880 in compile 71's run)" $procp]
set ndx  [pl 0xF2B1C]
set wrap [pl 0xF2B24]
puts [format "putindx %d, putwrap %d" $ndx $wrap]
set bytes {}
for {set a 0} {$a < 10000} {incr a 4} {
	set v [pl [expr {0x1189F4 + $a}]]
	foreach s {24 16 8 0} { lappend bytes [expr {($v >> $s) & 0xFF}] }
}
# (pl reads the long at an address's aligned long: $1189F4 is aligned, so
# the offset below is 0 - kept should the buffer ever move)
set off [expr {0x1189F4 & 3}]
set ring [lrange $bytes $off [expr {$off + 9999}]]
if {$ndx < 0 || $ndx > 9999} { set ndx 0 }
set order [expr {$wrap ? [concat [lrange $ring $ndx end] [lrange $ring 0 [expr {$ndx - 1}]]] : [lrange $ring 0 [expr {$ndx - 1}]]}]
set text ""
foreach c $order {
	if {$c == 10} { append text "
" } elseif {$c >= 32 && $c < 127} { append text [format %c $c] } elseif {$c != 0 && $c != 13} { append text [format "<%02X>" $c] }
}
puts "---- the console log, oldest first:"
puts $text
if {!($argc >= 1 && [lindex $argv 0] eq "keep")} { release }
end_insystem_source_probe
