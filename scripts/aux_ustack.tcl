# scripts/aux_ustack.tcl - the user registers and call chain of every A/UX
# process at its last entry to the kernel (SE30_PLAN.md KNOWN ISSUES 20: in
# both 16 MB hangs startmac's last entry was an F-line at PC $00000008 - a
# jump to 0).
#
#   quartus_stp -t scripts/aux_ustack.tcl [frames to follow, default 24]
#
# One peek session (the machine is held in reset and restarts at the end).
# The kernel stack's top frame is at u+$FF6 (SR, PC, format/vector); A/UX's
# entry (fault% $54922, syscall%) reserves $A bytes below it and stores
# d0-d7/a0-a6 from u+$FB0 with the user SP at u+$FEC.  From the user SP and
# a6 the stack is dumped and the a6 chain followed (saved a6, return
# address), each return address with the code before it, all through the
# process's own page tables.
set nfr 24
if {$argc >= 1} { set nfr [lindex $argv 0] }

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

proc hexl {l} { set o {}; foreach x $l { lappend o [format %08X $x] }; return [join $o " "] }
puts "---- 3. each user process at its last kernel entry:"
foreach pr $roots {
	lassign $pr pname root u
	if {$u == 0 || $u >= $RAM || $root == 0x15B000} { continue }
	set F [expr {$u + 0xFF6}]
	set sr [pw $F]
	set pc [expr {(([pw [expr {$F+2}]] << 16) | [pw [expr {$F+4}]]) & 0xFFFFFFFF}]
	set fv [pw [expr {$F+6}]]
	puts [format "== %s: frame SR %04X PC %08X format %X vector %d" $pname $sr $pc [expr {$fv >> 12}] [expr {($fv & 0xFFF) / 4}]]
	set B [expr {$u + 0xFB0}]
	set r {}
	for {set k 0} {$k < 16} {incr k} { lappend r [plu [expr {$B + 4*$k}]] }
	puts [format "  d0-d7 %s" [hexl [lrange $r 0 7]]]
	puts [format "  a0-a6 %s  usp %08X" [hexl [lrange $r 8 14]] [lindex $r 15]]
	if {[walk $pc] >= 0} { puts [format "  code at PC: %08X %08X %08X %08X" [L $pc] [L [expr {$pc+4}]] [L [expr {$pc+8}]] [L [expr {$pc+12}]]] }
	set usp [lindex $r 15]
	if {[walk $usp] < 0} { puts "  user stack unmapped"; continue }
	puts "  user stack from usp:"
	for {set a $usp} {$a < $usp + 0x80} {incr a 16} {
		puts [format "    %08X: %08X %08X %08X %08X" $a [L $a] [L [expr {$a+4}]] [L [expr {$a+8}]] [L [expr {$a+12}]]]
	}
	puts "  a6 chain (frame: saved a6, return address, the code before the return):"
	set fp [lindex $r 14]
	for {set k 0} {$k < $nfr} {incr k} {
		if {$fp == 0 || ($fp & 1) || [walk $fp] < 0} { puts [format "    a6 %08X: end" $fp]; break }
		set nfp [L $fp]
		set ret [L [expr {$fp + 4}]]
		set code "(unmapped)"
		if {[walk [expr {$ret - 8}]] >= 0} { set code [format "%08X %08X" [L [expr {$ret - 8}]] [L [expr {$ret - 4}]]] }
		puts [format "    a6 %08X: saved a6 %08X  return %08X  code before it %s" $fp $nfp $ret $code]
		if {$nfp <= $fp} { puts "    (saved a6 not above this frame: chain broken)"; break }
		set fp $nfp
	}
}
release
end_insystem_source_probe
