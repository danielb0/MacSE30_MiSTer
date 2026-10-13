# scripts/aux_gdevice.tcl - read A/UX's boot-time Mac environment's screen
# device record off the board's RAM over JTAG (SE30_PLAN.md KNOWN ISSUES 20).
#
#   quartus_stp -t scripts/aux_gdevice.tcl [process name, default StartMonitor]
#
# One peek session (the machine is held in reset for it and restarts from
# the reset vector at the end - run it once the bomb is on the screen):
#   1. every 4 KB page whose +$2AE holds ROMBase $40800000: the Mac
#      environments' low-memory pages;
#   2. the u-area whose +$340 (u_comm) names the process; its proc struct
#      (u+0) holds the PMMU root table's physical address at +$42;
#   3. with that table (A/UX 3: TIA 5, TIB 7, TIC 8, 4 KB pages) the
#      environment's logical low-memory globals ScrnBase $824, MainDevice
#      $8A4, DeviceList $8A8, TheGDevice $CC8, then the GDevice behind the
#      handle and its PixMap - the same walk sim-side on MAME's RAM image
#      gave one device, gdRect 0,0,342,512, PixMap base $FEE08040, rowBytes
#      $8040, 1 bit deep.
set want "StartMonitor"
if {$argc >= 1} { set want [lindex $argv 0] }

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

set RAM [expr {16 * 1024 * 1024}]
puts "---- 1. the Mac environments' low-memory pages (ROMBase at +\$2AE):"
set lowmem {}
for {set p 0} {$p < $RAM} {incr p 4096} {
	set v1 [pl [expr {$p + 0x2AC}]]
	if {($v1 & 0xFFFF) == 0x4080} {
		set v2 [pl [expr {$p + 0x2B0}]]
		if {($v2 >> 16) == 0} {
			lappend lowmem $p
			puts [format "  page %06X: ScrnBase %08X MainDevice %08X DeviceList %08X TheGDevice %08X" $p [pl [expr {$p + 0x824}]] [pl [expr {$p + 0x8A4}]] [pl [expr {$p + 0x8A8}]] [pl [expr {$p + 0xCC8}]]]
		}
	}
}
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

puts "---- 3. through the page tables of every Mac process (its logical 0 is a low-memory page):"
foreach pr $roots {
lassign $pr pname root
if {[walk 0] < 0 || [lsearch -exact $lowmem [expr {[walk 0] & ~0xFFF}]] < 0} { continue }
puts [format "== %s: logical 0 -> physical %06X" $pname [walk 0]]
puts [format "  ScrnBase %08X  MainDevice %08X  DeviceList %08X  TheGDevice %08X  ROMBase %08X" [L 0x824] [L 0x8A4] [L 0x8A8] [L 0xCC8] [L 0x2AE]]
foreach nm {MainDevice TheGDevice DeviceList} off {0x8A4 0xCC8 0x8A8} {
	set h [L $off]
	set mp [L $h]
	puts [format "  %s handle %08X -> master %08X -> physical %s" $nm $h $mp [expr {[walk $mp] < 0 ? "unmapped" : [format %06X [walk $mp]]}]]
	if {[walk $mp] < 0} { continue }
	set gd $mp
	puts [format "    GDevice: gdRefNum %04X gdID %04X gdType %04X gdITable %08X gdResPref %04X gdFlags %04X gdPMap %08X gdRefCon %08X gdNextGD %08X gdRect %d,%d,%d,%d gdMode %08X gdCCBytes %04X gdCCDepth %04X" \
		[W $gd] [W [expr {$gd+2}]] [W [expr {$gd+4}]] [L [expr {$gd+6}]] [W [expr {$gd+0xA}]] [W [expr {$gd+0x14}]] [L [expr {$gd+0x16}]] [L [expr {$gd+0x1A}]] [L [expr {$gd+0x1E}]] \
		[W [expr {$gd+0x22}]] [W [expr {$gd+0x24}]] [W [expr {$gd+0x26}]] [W [expr {$gd+0x28}]] [L [expr {$gd+0x2A}]] [W [expr {$gd+0x2E}]] [W [expr {$gd+0x30}]]]
	set pmh [L [expr {$gd+0x16}]]
	set pmp [L $pmh]
	puts [format "    gdPMap handle %08X -> master %08X -> physical %s" $pmh $pmp [expr {[walk $pmp] < 0 ? "unmapped" : [format %06X [walk $pmp]]}]]
	if {[walk $pmp] < 0} { continue }
	set pm $pmp
	puts [format "    PixMap: baseAddr %08X rowBytes %04X bounds %d,%d,%d,%d pmVersion %04X packType %04X hRes %08X vRes %08X pixelType %04X pixelSize %04X cmpCount %04X cmpSize %04X pmTable %08X" \
		[L $pm] [W [expr {$pm+4}]] [W [expr {$pm+6}]] [W [expr {$pm+8}]] [W [expr {$pm+10}]] [W [expr {$pm+12}]] [W [expr {$pm+0xE}]] [W [expr {$pm+0x10}]] [L [expr {$pm+0x16}]] [L [expr {$pm+0x1A}]] \
		[W [expr {$pm+0x1E}]] [W [expr {$pm+0x20}]] [W [expr {$pm+0x22}]] [W [expr {$pm+0x24}]] [L [expr {$pm+0x2A}]]]
}
set pa [walk 0x2D7C40]
if {$pa < 0} { puts "  2D7C40 unmapped in this process" } else {
	for {set a 0x2D7C40} {$a < 0x2D7C80} {incr a 16} {
		puts [format "  %08X: %08X %08X %08X %08X" $a [L $a] [L [expr {$a+4}]] [L [expr {$a+8}]] [L [expr {$a+12}]]]
	}
}
}
release
end_insystem_source_probe
