# scripts/aux_sigframe.tcl - the illegal instruction a hung A/UX process
# keeps faulting on (SE30_PLAN.md KNOWN ISSUES 20, the 16 MB hang: vector-4
# exceptions at ~1,000/s, the kernel cycling trap/psignal/issig/resched).
#
#   quartus_stp -t scripts/aux_sigframe.tcl [pages of u-area to scan, default 3]
#
# One peek session (the machine is held in reset and restarts at the end):
# the kernel's process table as in aux_gdevice.tcl; for every process with a
# u-area, its pages are scanned for exception frames the CPU stacked from
# user mode - an SR with S clear followed by the PC and a format/vector word
# whose vector is 4 ($x010) or any other; each user-mode frame found prints
# with the code at its PC, read through that process's own page tables.
set npages 3
if {$argc >= 1} { set npages [lindex $argv 0] }

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
foreach need {PPEK PPOK PIFA PLAS} { if {![info exists idx($need)]} { puts "ERROR: no $need in this bitstream"; exit 1 } }
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

set RAM [expr {16 * 1024 * 1024}]
puts "---- 2. the kernel's process table (the proc structs, 158 bytes apart from sched's at \$1BC880; the"
puts "        u-area may be swapped out, the PMMU root table at +\$42 is not):"
set roots {}
set base 0x1BC880
for {set i 0} {$i < 100} {incr i} {
	set pp [expr {$base + $i * 0x9E}]
	set r [plu [expr {$pp + 0x42}]]
	if {($r & 0xF) != 0 || $r == 0 || $r >= $RAM} { continue }
	set u [plu [expr {$pp + 0x3E}]]
	set n ""
	if {$u != 0 && $u < $RAM && ($u & 0xFFF) == 0} {
		for {set k 0} {$k < 16} {incr k 4} { append n [binary decode hex [format %08X [pl [expr {$u + 0x340 + $k}]]]] }
		set z [string first "\0" $n]
		if {$z >= 0} { set n [string range $n 0 [expr {$z - 1}]] }
		if {![string is print $n]} { set n "?" }
	}
	puts [format "  proc %2d at %08X  u-area %08X  root table %08X  u_comm=%s" $i $pp $u $r $n]
	lappend roots [list [format "proc %d (%s)" $i $n] $r $u]
}
if {[llength $roots] == 0} { puts "no process has a root table; stopping"; release; end_insystem_source_probe; exit 1 }

proc walk {la} {
	global root
	set a [pl [expr {$root + 4 * ($la >> 27)}]]
	if {($a & 3) == 0} { return -1 }
	set b [pl [expr {($a & ~0xF) + 4 * (($la >> 20) & 0x7F)}]]
	if {($b & 3) == 0} { return -1 }
	if {($b & 3) == 1} { return [expr {($b & ~0xFFF) | ($la & 0xFFF)}] }
	set c [pl [expr {($b & ~0xF) + 4 * (($la >> 12) & 0xFF)}]]
	if {($c & 3) == 0} { return -1 }
	return [expr {($c & ~0xFFF) | ($la & 0xFFF)}]
}
proc L {la} { set pa [walk $la]; if {$pa < 0} { return -1 }; return [plu $pa] }
proc W {la} { set pa [walk $la]; if {$pa < 0} { return -1 }; return [pw $pa] }

puts "---- 3. user-mode exception frames in each u-area (SR, PC, format/vector):"
foreach pr $roots {
	lassign $pr pname root u
	if {$u == 0 || $u >= $RAM || $root == 0x15B000} { continue }
	set words {}
	for {set b $u} {$b < $u + $npages * 4096} {incr b 4} {
		set v [pl $b]
		lappend words [expr {$v >> 16}] [expr {$v & 0xFFFF}]
	}
	set nf 0
	for {set i 0} {$i + 3 < [llength $words]} {incr i} {
		set sr [lindex $words $i]
		set fv [lindex $words [expr {$i + 3}]]
		set fmt [expr {$fv >> 12}]
		set vo  [expr {$fv & 0xFFF}]
		if {($sr & 0x2700) != 0 || ($sr & 0xFF00) != 0} { continue }
		if {!($fmt == 0 || $fmt == 2 || $fmt == 0xA || $fmt == 0xB)} { continue }
		if {($vo & 3) != 0 || $vo < 8 || $vo > 0xBC} { continue }
		set pc [expr {([lindex $words [expr {$i + 1}]] << 16) | [lindex $words [expr {$i + 2}]]}]
		if {$pc & 1} { continue }
		set code ""
		if {[walk $pc] >= 0} { set code [format "%08X %08X %08X" [L $pc] [L [expr {$pc+4}]] [L [expr {$pc+8}]]] } else { set code "(PC unmapped)" }
		puts [format "  %s  u+%04X: SR %04X PC %08X format %X vector %d   code at PC: %s" $pname [expr {2 * $i}] $sr $pc $fmt [expr {$vo / 4}] $code]
		incr nf
	}
	if {$nf == 0} { puts "  $pname: none" }
}
release
end_insystem_source_probe
