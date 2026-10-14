# scripts/aux_trigger.tcl - the bus-error trigger (SE30_PLAN.md KNOWN ISSUES 20;
# rtl/dbg_probes.sv's PBTT, SE30_BTRACE builds).
#
#   quartus_stp -t scripts/aux_trigger.tcl arm [pc, default 007FF4C2]
#   quartus_stp -t scripts/aux_trigger.tcl wait [seconds, default 1800]
#   quartus_stp -t scripts/aux_trigger.tcl dump
#   quartus_stp -t scripts/aux_trigger.tcl disarm
#   quartus_stp -t scripts/aux_trigger.tcl coff <0-3>   (bit 1: I-cache off, bit 0: D-cache off)
#   quartus_stp -t scripts/aux_trigger.tcl procs | peek <phys> [n] | lpeek <logical> [bytes]
#
# arm: the first bus-error exception taken at that PC snapshots D1, A1, A3,
# A5, A6 and holds the machine in reset, memory as it stood.  wait: polls
# until it fires and prints the snapshot.  dump: one peek session with the
# machine still held - finds the process whose logical $7FF4C0 holds the
# stack routine (D3C1 3211: adda.l d1,a1 / move.w (a1),d1), and through its
# page tables prints the routine, the user stack around A6 and the chain
# entry the walk came from (A1 - D1) with the entries before it.  The hold
# stays until disarm, which restarts the machine.
set mode [lindex $argv 0]
set arg  [lindex $argv 1]

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
foreach need {PBTT PPEK PPOK} { if {![info exists idx($need)]} { puts "ERROR: no $need in this bitstream"; exit 1 } }
start_insystem_source_probe -hardware_name $hw -device_name $dev

proc rd {name} { global idx; return [expr 0b[read_probe_data -instance_index $idx($name)]] }
proc snapshot {} {
	set v [rd PBTT]
	set fired [expr {($v >> 199) & 1}]
	set fa [expr {($v >> 160) & 0xFFFFFFFF}]
	set r {}
	foreach n {D1 A1 A3 A5 A6} k {4 3 2 1 0} { lappend r $n [expr {($v >> (32 * $k)) & 0xFFFFFFFF}] }
	return [list $fired $fa $r]
}
proc show {} {
	lassign [snapshot] fired fa r
	puts [format "fired %d  fault address %08X" $fired $fa]
	foreach {n x} $r { puts [format "  %s = %08X" $n $x] }
	return $r
}

if {$mode eq "arm"} {
	set pc [expr {$arg eq "" ? 0x007FF4C2 : "0x$arg"}]
	write_source_data -instance_index $idx(PBTT) -value_in_hex -value [format %09llX [expr {(1 << 32) | $pc}]]
	puts [format "armed at PC %08X" $pc]
	end_insystem_source_probe; exit 0
}
if {$mode eq "coff"} {
	# coff <0-3>: the cache experiment - bit 1 the instruction cache off, bit 0 the data cache off
	if {![info exists idx(PCOF)]} { puts "ERROR: no PCOF in this bitstream"; end_insystem_source_probe; exit 1 }
	if {$arg ne ""} { write_source_data -instance_index $idx(PCOF) -value_in_hex -value [format %X [expr {$arg & 3}]] }
	set v [rd PCOF]
	puts [format "caches: instruction %s, data %s" [expr {$v & 2 ? "OFF" : "on"}] [expr {$v & 1 ? "OFF" : "on"}]]
	end_insystem_source_probe; exit 0
}
if {$mode eq "disarm"} {
	write_source_data -instance_index $idx(PBTT) -value_in_hex -value 000000000
	puts "disarmed: the machine is released (it restarts)"
	end_insystem_source_probe; exit 0
}
if {$mode eq "wait"} {
	set secs [expr {$arg eq "" ? 1800 : $arg}]
	set t0 [clock seconds]
	while {[clock seconds] - $t0 < $secs} {
		if {[lindex [snapshot] 0]} { puts "TRIGGERED after [expr {[clock seconds] - $t0}] s"; show; end_insystem_source_probe; exit 0 }
		after 200
	}
	puts "not triggered in $secs s"; end_insystem_source_probe; exit 1
}
if {$mode ne "dump" && $mode ne "procs" && $mode ne "peek" && $mode ne "lpeek"} { puts "usage: arm \[pc\] | wait \[s\] | dump | procs | disarm"; end_insystem_source_probe; exit 1 }

set regs [show]
array set R $regs

# ---- the peek session (aux_gdevice.tcl's mechanics); the trigger's hold stays
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
proc pl {b} {
	for {set k 0} {$k < 4} {incr k} {
		set r [pk_op 0 [expr {$b >> 2}]]
		if {$::pk_ok} { return $r }
	}
	return $r
}
proc pw {b} { set v [pl [expr {$b & ~3}]]; return [expr {($b & 2) ? ($v & 0xFFFF) : ($v >> 16)}] }
proc plu {b} { if {($b & 3) == 0} { return [pl $b] }; return [expr {(([pw $b] << 16) | [pw [expr {$b + 2}]]) & 0xFFFFFFFF}] }
pk_poke 0x5FFFFE 0 0xF

set RAM [expr {16 * 1024 * 1024}]
proc walk {la} {
	# A/UX 3's TC is $82C07760 (turnon_mmu): SRE, 4 KB pages, IS 0, TIA 7,
	# TIB 7, TIC 6; DT 1 at A or B is early termination (a contiguous block)
	global root
	set a [pl [expr {$root + 4 * (($la >> 25) & 0x7F)}]]
	if {($a & 3) == 0} { return -1 }
	if {($a & 3) == 1} { return [expr {(($a & ~0xFF) + ($la & 0x1FFFFFF)) & 0xFFFFFFFF}] }
	set b [pl [expr {($a & ~0xF) + 4 * (($la >> 18) & 0x7F)}]]
	if {($b & 3) == 0} { return -1 }
	if {($b & 3) == 1} { return [expr {(($b & ~0xFF) + ($la & 0x3FFFF)) & 0xFFFFFFFF}] }
	set c [pl [expr {($b & ~0xF) + 4 * (($la >> 12) & 0x3F)}]]
	if {($c & 3) == 0} { return -1 }
	return [expr {($c & ~0xFFF) | ($la & 0xFFF)}]
}
proc L {la} { set pa [walk $la]; if {$pa < 0} { return -1 }; return [plu $pa] }
proc W {la} { set pa [walk $la]; if {$pa < 0} { return -1 }; return [pw $pa] }
proc block {title la n} {
	puts "  $title"
	set la [expr {$la & ~3}]
	for {set a $la} {$a < $la + $n} {incr a 16} {
		set line [format "    %08X:" $a]
		for {set k 0} {$k < 16} {incr k 4} {
			set v [L [expr {$a + $k}]]
			if {$v < 0} { append line " ????????" } else { append line [format " %08X" $v] }
		}
		puts $line
	}
}

if {$mode eq "lpeek"} {
	# lpeek <logical hex> [bytes]: through the CURRENT process's tables (cpu_rp at $5B06C)
	set root [pl 0x5B06C]
	set la [expr {"0x$arg"}]
	set n [lindex $argv 2]; if {$n eq ""} { set n 0x100 }
	puts [format "  root %08X" $root]
	block [format "logical %08X:" $la] $la $n
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
	end_insystem_source_probe; exit 0
}
set found 0
set base 0x1BC880
if {$mode eq "peek"} {
	# peek <physical hex> [longs]: raw longwords, the machine still held
	set pa [expr {"0x$arg" & ~3}]
	set n [lindex $argv 2]; if {$n eq ""} { set n 8 }
	for {set k 0} {$k < $n} {incr k 4} {
		set line [format "  %08X:" [expr {$pa + 4 * $k}]]
		for {set j 0} {$j < 4 && $k + $j < $n} {incr j} { append line [format " %08X" [pl [expr {$pa + 4 * ($k + $j)}]]] }
		puts $line
	}
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
	end_insystem_source_probe; exit 0
}
if {$mode eq "procs"} {
	set root 0x15B000
	set cu [walk 0x12FFF000]
	set n ""
	for {set k 0} {$k < 16} {incr k 4} { set v [L [expr {0x12FFF340 + $k}]]; if {$v >= 0} { append n [binary decode hex [format %08X $v]] } }
	puts [format "  the CURRENT u-area (kernel's \$12FFF000) -> physical %s, u_comm %s" [expr {$cu < 0 ? "unmapped" : [format %06X $cu]}] $n]
	for {set i 0} {$i < 100} {incr i} {
		set pp [expr {$base + $i * 0x9E}]
		set root [plu [expr {$pp + 0x42}]]
		if {($root & 0xF) != 0 || $root == 0 || $root >= $RAM} { continue }
		set u [plu [expr {$pp + 0x3E}]]
		set n ""
		if {$u != 0 && $u < $RAM && ($u & 0xFFF) == 0} {
			for {set k 0} {$k < 16} {incr k 4} { append n [binary decode hex [format %08X [pl [expr {$u + 0x340 + $k}]]]] }
			set z [string first "\0" $n]; if {$z >= 0} { set n [string range $n 0 [expr {$z - 1}]] }
			if {![string is print $n]} { set n "?" }
		}
		set la 0x7FF4C0
		set a [pl [expr {$root + 4 * ($la >> 27)}]]
		set a2 [pl [expr {$root + 4 * ($la >> 27) + 4}]]
		set b [expr {($a & 3) ? [pl [expr {($a & ~0xF) + 4 * (($la >> 20) & 0x7F)}]] : 0}]
		set c [expr {($b & 3) >= 2 ? [pl [expr {($b & ~0xF) + 4 * (($la >> 12) & 0xFF)}]] : 0}]
		puts [format "    root\[%d\] %08X (next %08X)  B\[%d\] %08X  C\[%d\] %08X" [expr {$la >> 27}] $a $a2 [expr {($la >> 20) & 0x7F}] $b [expr {($la >> 12) & 0xFF}] $c]
		set pa [walk 0x7FF4C0]
		puts [format "    ROMBase(\$2AE) %08X  CurApName \$910: %08X %08X  (\$7FF9E0) %08X %08X  (\$7FDF58) %08X" [L 0x2AE] [L 0x910] [L 0x914] [L 0x7FF9E0] [L 0x7FF9E4] [L 0x7FDF58]]
		puts [format "  proc %2d at %08X root %08X u %08X %-14s 7FF4C0 -> %s  %s  A6 -> %s" $i $pp $root $u $n 			[expr {$pa < 0 ? "unmapped" : [format %06X $pa]}] [expr {$pa < 0 ? "" : [format "%08X %08X" [L 0x7FF4C0] [L 0x7FF4C4]]}] 			[expr {[walk $R(A6)] < 0 ? "unmapped" : [format %06X [walk $R(A6)]]}]]
	}
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
	puts "peek session over; the trigger still holds the machine"
	end_insystem_source_probe; exit 0
}
for {set i 0} {$i < 100} {incr i} {
	set pp [expr {$base + $i * 0x9E}]
	set root [plu [expr {$pp + 0x42}]]
	if {($root & 0xF) != 0 || $root == 0 || $root >= $RAM} { continue }
	if {[W 0x7FF4C0] != 0xD3C1 || [W 0x7FF4C2] != 0x3211} { continue }
	set found 1
	puts [format "==== proc %d at %08X, root table %08X: the routine is on its stack" $i $pp $root]
	block "the routine (\$7FF440-\$7FF500):" 0x7FF440 0xC0
	block "the user stack from A6-\$60:" [expr {$R(A6) - 0x60}] 0xA0
	set entry [expr {($R(A1) - $R(D1)) & 0xFFFFFFFF}]
	puts [format "  the chain: A1 %08X = the entry %08X + D1 %08X" $R(A1) $entry $R(D1)]
	block "around the entry (-\$40 .. +\$40):" [expr {$entry - 0x40}] 0x80
	block "A5's table (+0 .. +\$40):" $R(A5) 0x40
	block "the routine's save area (MAME's A7 here: \$7FDF58 - d0 d1 d2 d3 a0 a1 a2 a4):" 0x7FDF38 0x60
	set a1s [L [expr {0x7FDF58 + 20}]]
	if {$a1s >= 0} { block [format "the chain as passed, saved A1 %08X:" $a1s] [expr {$a1s - 0x20}] 0x80 }
}
if {!$found} { puts "no process has the routine at \$7FF4C0 (paged out, or another PC)" }
write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
puts "peek session over; the trigger still holds the machine - disarm to restart it"
end_insystem_source_probe
