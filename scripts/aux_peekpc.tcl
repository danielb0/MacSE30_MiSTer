# scripts/aux_peekpc.tcl - where a hung A/UX is spinning, and the code there
# (SE30_PLAN.md KNOWN ISSUES 20, the 16 MB hang: illegal-instruction
# exceptions at ~1,000/s with PIFA near $83AE4).
#
#   quartus_stp -t scripts/aux_peekpc.tcl [logical address, default 83AE4]
#
# 1. samples PIFA (the last instruction fetch) and PLAS (the last bus cycle)
#    while the machine runs and prints how often each was seen;
# 2. then one peek session (the machine is held in reset and restarts at the
#    end): the kernel's process table as in aux_gdevice.tcl, and for every
#    process with a root table the code around the logical address through
#    that process's own tables (A/UX 3: TIA 5, TIB 7, TIC 8, 4 KB pages).
set want 0x83AE4
if {$argc >= 1} { set want 0x[lindex $argv 0] }

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

puts "---- 1. PIFA / PLAS while running (400 samples):"
array set seen {}
for {set i 0} {$i < 400} {incr i} {
	set k [format "PIFA %08X  PLAS %08X" [rd PIFA] [rd PLAS]]
	if {[info exists seen($k)]} { incr seen($k) } else { set seen($k) 1 }
}
foreach k [lsort [array names seen]] { puts [format "  %4d  %s" $seen($k) $k] }

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
	lappend roots [list [format "proc %d (%s)" $i $n] $r]
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

puts [format "---- 3. the code around %08X in every process that maps it:" $want]
foreach pr $roots {
	lassign $pr pname root
	set pa [walk $want]
	if {$pa < 0} { continue }
	puts [format "== %s: %08X -> physical %06X" $pname $want $pa]
	set a0 [expr {($want & ~0xF) - 0x60}]
	for {set a $a0} {$a < $a0 + 0xC0} {incr a 16} {
		puts [format "  %08X: %08X %08X %08X %08X" $a [L $a] [L [expr {$a+4}]] [L [expr {$a+8}]] [L [expr {$a+12}]]]
	}
}
release
end_insystem_source_probe
