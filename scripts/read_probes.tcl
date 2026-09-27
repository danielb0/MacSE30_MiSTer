# Read the SE/30 bring-up probe deck over the DE10-Nano's USB-Blaster.
#
#   quartus_stp -t scripts/read_probes.tcl          one sample, decoded
#   quartus_stp -t scripts/read_probes.tcl 10 0.5   10 samples, 0.5 s apart
#
# READ-ONLY: this observes the board and writes nothing to it (the standing
# rule: reading over JTAG is invited, flashing is never ours).
#
# The deck is rtl/dbg_probes.sv: PBLD the bitstream's git SHA, PIFA the last
# instruction-fetch address, PLAS the last bus-cycle address, PSTA a status
# word, PACT the bus-cycle count.  The machine bench's first-boot picture
# (SE30_PLAN.md 3.8 items 8 and 17): for the first 130 ms the ROM is in its
# CHECKSUM LOOP at $408036FE, fetching $408036FC / $40803700 / $40803704 and
# reading every ROM word (524,280 bus cycles); the bench's 215 us sees only
# the start of it.  Read seconds after boot, PACT past ~524,000 says the
# loop completed through the SDRAM path; what follows depends on the VIAs.
#
# A probe that is NOT in the running bitstream is never reported as data
# (MacPlus's lesson: an absent probe used to read 0 and every field derived
# from it printed as a confident number).  Absent probes are declared and
# their lines suppressed.

set samples 1
set delay   1.0
set peek_mode 0
if {$argc >= 1 && [lindex $argv 0] eq "peek"} {
	set peek_mode 1
	set peek_addr  [expr 0x[lindex $argv 1]]
	set peek_count [expr {$argc >= 3 ? [lindex $argv 2] : 1}]
} else {
	if {$argc >= 1} { set samples [lindex $argv 0] }
	if {$argc >= 2} { set delay   [lindex $argv 1] }
}

# ---- find the board -------------------------------------------------------
# The DE10-Nano's on-board blaster enumerates as "DE-SoC [USB-n]", NOT as
# "USB-Blaster" -- match either.
set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} {
	set all [get_hardware_names]
	if {[llength $all] > 0} { set hw [lindex $all 0] }
}
if {$hw eq ""} {
	puts "ERROR: no JTAG hardware found. Is the DE10-Nano connected and powered?"
	exit 1
}
# The chain is {@1 SOCVHPS, @2 5CSEBA6}: the ARM HPS comes FIRST and carries no
# ISSP hub. Match the FPGA explicitly and never fall back to device 1.
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} {
	puts "ERROR: no Cyclone V FPGA in the chain. Devices seen:"
	foreach d [get_device_names -hardware_name $hw] { puts "   $d" }
	exit 1
}
puts "hardware: $hw"
puts "device:   $dev"
puts ""

# ---- map instance ids -----------------------------------------------------
# The ISSP hub enumerates by index, not by name, so build the mapping once.
# This query must run OUTSIDE a session -- starting one first fails with
# "there is already an active In-System Sources and Probes session".
if {[catch {
	set info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
} err]} { puts "ERROR reading instance info: $err"; exit 1 }
if {[llength $info] == 0} {
	puts "ERROR: no ISSP instances. Is a USE_DBG_PROBES build of MacSE30 actually loaded?"
	exit 1
}
array set idx {}
array set absent {}
foreach inst $info {
	# {index source_width probe_width instance_name}
	set idx([lindex $inst 3]) [lindex $inst 0]
	puts [format "  found %-6s index=%s probe_width=%s" [lindex $inst 3] [lindex $inst 0] [lindex $inst 2]]
}
puts ""

proc have {name} { global idx; return [info exists idx($name)] }
proc rd {name} {
	global idx absent
	if {![info exists idx($name)]} { set absent($name) 1; return 0 }
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}

# One session for the whole run, rather than one per probe read.
start_insystem_source_probe -hardware_name $hw -device_name $dev

# ---- the memory peek (plan 3.8 item 18) --------------------------------------
#   quartus_stp -t scripts/read_probes.tcl peek <longword address, hex> [count]
# Holds the machine in reset (its SDRAM contents survive; it restarts from
# the reset vector when released), reads <count> consecutive longwords of the
# SDRAM through the controller's own CPU port - the same path, without the
# CPU - and prints them.  The address is the controller's: the 32 MB as
# longwords, the ROM image at $200000 (byte $800000, CPU $40800000).  Diff
# against the ROM file with scripts/peek_diff.py.  Read a range twice to see
# whether a wrong word is stable (the image) or varies (the read).
if {$peek_mode} {
	if {![have PPEK] || ![have PPKS]} { puts "ERROR: this bitstream has no PPEK/PPKS (built before plan 3.8 item 18's peek)"; exit 1 }
	set go 0
	for {set i 0} {$i < $peek_count} {incr i} {
		set a [expr {($peek_addr + $i) & 0x7FFFFF}]
		set src [expr {(1 << 30) | $a}]
		set before [expr {[rd PPKS] >> 8}]
		write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X $src]
		set go [expr {1 - $go}]
		write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X [expr {$src | ($go << 31)}]]
		set tries 0
		while {([expr {[rd PPKS] >> 8}]) == $before && $tries < 50} { after 2; incr tries }
		set d [rd PPEK]
		puts [format "  %06X: %08X%s" $a $d [expr {$tries >= 50 ? "   (no acknowledge: the read never completed)" : ""}]]
	}
	write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
	puts "machine released from reset"
	end_insystem_source_probe
	exit 0
}

set prev_pact -1
set prev_pifa -1
for {set n 0} {$n < $samples} {incr n} {
	# ---- which bitstream --------------------------------------------------
	if {[have PBLD]} {
		set pbld [rd PBLD]
		if {$pbld == 0} {
			puts [format "sample %d   bitstream=UNSTAMPED (PBLD present, tag reads 0 -- rtl/build_tag.v was not stamped before the compile)" $n]
		} else {
			puts [format "sample %d   bitstream=%08x" $n $pbld]
		}
	} else {
		set absent(PBLD) 1
		puts [format "sample %d   bitstream=UNKNOWN -- this build has NO PBLD probe (the compile-3 build, MacSE30_069d417_dqrise, predates the tag)" $n]
	}

	# ---- the CPU ----------------------------------------------------------
	if {[have PIFA]} {
		set pifa [rd PIFA]
		set in_poll [expr {$pifa == 0x408036FC || $pifa == 0x40803700 || $pifa == 0x40803704}]
		puts [format "  PIFA  last fetch  %08X   %s" $pifa \
			[expr {$in_poll ? "<- in the ROM checksum loop" : ""}]]
	}
	if {[have PLAS]} {
		puts [format "  PLAS  last cycle  %08X" [rd PLAS]]
	}
	if {[have PACT]} {
		set pact [rd PACT]
		set moving ""
		if {$prev_pact >= 0} {
			set moving [expr {$pact != $prev_pact ? "advancing: the CPU is alive" : "FROZEN since the last sample"}]
		}
		puts [format "  PACT  bus cycles  %10u   %s" $pact $moving]
		set prev_pact $pact
	}
	if {[have PSTA]} {
		# {fc[2:0], rw_n, dsack_n[1:0], berr_seen, halted, sdram_ready,
		#  rom_loaded, reset_n, cap_sel, cap_fail, cap_ok[1:0], 1'b0,
		#  berr_cnt[15:0]} -- rtl/dbg_probes.sv; keep the two in step.
		# The cap_* bits (plan 3.8 item 18) are the SDRAM read-capture
		# training's verdict, set once per configuration: builds before
		# it read them as 0 (capture A, "passed", A and B "failed").
		set psta [rd PSTA]
		set fc        [expr {($psta >> 29) & 7}]
		set rw        [expr {($psta >> 28) & 1}]
		set dsack     [expr {($psta >> 26) & 3}]
		set berr_seen [expr {($psta >> 25) & 1}]
		set halted    [expr {($psta >> 24) & 1}]
		set sdram_rdy [expr {($psta >> 23) & 1}]
		set rom_ld    [expr {($psta >> 22) & 1}]
		set reset_n   [expr {($psta >> 21) & 1}]
		set cap_sel   [expr {($psta >> 20) & 1}]
		set cap_fail  [expr {($psta >> 19) & 1}]
		set cap_ok_a  [expr {($psta >> 18) & 1}]
		set cap_ok_b  [expr {($psta >> 17) & 1}]
		set berr_cnt  [expr {$psta & 0xFFFF}]
		set fcname [lindex {"0 (reserved)" "user data" "user program" "3 (reserved)" "4 (reserved)" "super data" "super program" "CPU space"} $fc]
		puts [format "  PSTA  %08X   last cycle FC=%d %s %s, last DSACK*=%d%d" $psta $fc $fcname \
			[expr {$rw ? "read" : "write"}] [expr {($dsack >> 1) & 1}] [expr {$dsack & 1}]]
		puts [format "        reset released=%d  rom loaded=%d  sdram ready=%d  halted=%d  bus error seen=%d  bus errors=%d" \
			$reset_n $rom_ld $sdram_rdy $halted $berr_seen $berr_cnt]
		puts [format "        SDRAM read capture: chose %s  (A passed=%d  B passed=%d)%s" \
			[expr {$cap_sel ? "B (clk_mem, for fast silicon)" : "A (clk_mem + 3.06 ns, for slow silicon)"}] \
			$cap_ok_a $cap_ok_b \
			[expr {$cap_fail ? "  *** NEITHER PASSED: reads are not trustworthy ***" : ""}]]
	}
	if {[have PCAP]} {
		# {cap_sel, cap_fail, cap_ok[1:0], fail_a[13:0], fail_b[13:0]}: the
		# training's failure counts of 65,536 reads each, saturating at 16,383
		# (plan 3.8 item 18): 0 is a capture with margin, hundreds is one on
		# the edge of the eye
		set pcap [rd PCAP]
		puts [format "  PCAP  %08X   training: %d of 65536 reads failed through A, %d through B" \
			$pcap [expr {($pcap >> 14) & 0x3FFF}] [expr {$pcap & 0x3FFF}]]
	}
	if {[have PMEM]} {
		set pmem [rd PMEM]
		puts [format "  PMEM  %08X   the machine's last memory read%s" $pmem \
			[expr {$pmem == 0x4080002A ? "  (the reset vector's PC, as the ROM has it)" : ""}]]
	}
	if {[have PVIA]} {
		# {overlay, ramsiz[1:0], vsyncen_n, via1 ier[6:0], via1 ifr[6:0],
		#  via2 ier[6:0], via2 ifr[6:0]} -- rtl/dbg_probes.sv, plan 4.8
		set pvia [rd PVIA]
		set overlay   [expr {($pvia >> 31) & 1}]
		set ramsiz    [expr {($pvia >> 29) & 3}]
		set vsyncen_n [expr {($pvia >> 28) & 1}]
		set v1ier     [expr {($pvia >> 21) & 0x7F}]
		set v1ifr     [expr {($pvia >> 14) & 0x7F}]
		set v2ier     [expr {($pvia >> 7) & 0x7F}]
		set v2ifr     [expr {$pvia & 0x7F}]
		puts [format "  PVIA  %08X   overlay=%d %s  ramsiz=%d%d  vsyncen*=%d" $pvia $overlay \
			[expr {$overlay ? "(ROM at 0: the ROM never cleared it)" : "(RAM at 0)"}] \
			[expr {($ramsiz >> 1) & 1}] [expr {$ramsiz & 1}] $vsyncen_n]
		puts [format "        VIA1 IER=%02X IFR=%02X   VIA2 IER=%02X IFR=%02X   %s" $v1ier $v1ifr $v2ier $v2ifr \
			[expr {($v1ier & 2) ? "VBL enabled on VIA1" : "VBL not yet enabled"}]]
	}
	if {[have PIRQ]} {
		set pirq [rd PIRQ]
		set irq1 [expr {$pirq & 0xFFFF}]
		set irq2 [expr {($pirq >> 16) & 0xFFFF}]
		puts [format "  PIRQ  %08X   level-1 acknowledges=%u  level-2=%u   (level 1 advancing ~60/s: the VBL is running)" $pirq $irq1 $irq2]
	}
	puts ""
	if {$n + 1 < $samples} { after [expr {int($delay * 1000)}] }
}

end_insystem_source_probe

if {[array size absent] > 0} {
	puts "############################################################"
	puts "# INCOMPLETE CAPTURE -- probes missing from this bitstream: #"
	puts "#   [lsort [array names absent]]"
	puts "# Their lines were SUPPRESSED, not printed as zero."
	puts "############################################################"
	puts ""
}
puts "How to read this (SE30_PLAN.md 3.8 items 8 and 17):"
puts "  * PACT above ~524,000: the ROM's 256 KB checksum loop ran to its end"
puts "    through the SDRAM path (ROM in SDRAM, GLUE's 4-clock cycle)."
puts "  * PIFA in 408036FC/40803700/40803704 with PACT advancing: still in it."
puts "  * PACT frozen: the CPU is stalled on a bus cycle; PLAS names it, PSTA's"
puts "    FC and DSACK* say what kind and whether it was ever acknowledged."
puts "  * halted 1 or bus errors > 0: a double fault or a BERR; PLAS is the"
puts "    address that drew it. The SDRAM path, not the ROM, is the question."
puts "  * rom loaded 0 / sdram ready 0 / reset released 0: the machine never"
puts "    left reset -- the HPS download or the SDRAM power-up ladder."
puts "Since Section 4 (the VIAs, SE30_PLAN.md 4.6 and 4.9):"
puts "  * PVIA overlay=0: the ROM's first VIA write landed and RAM is at 0;"
puts "    ramsiz is what the ROM's sizing set (11 = 16 Mbit parts, 64 MB banks,"
puts "    also the undriven reading); VIA1 IER bit 1 set: the VBL is enabled."
puts "  * PIRQ level-1 advancing at ~60/s: VIA2 T1 -> PB7 -> VIA1 CA1 -> IRQ ->"
puts "    GLUE -> IPL1 -> the CPU, the whole interrupt path works."
puts "  * The screen is the verdict beyond the probes: a Sad Mac code or the"
puts "    flashing question mark (plan 4.6)."
