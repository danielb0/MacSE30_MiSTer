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
# word, PACT the bus-cycle count.  The first-boot prediction it is read
# against is the machine bench's (SE30_PLAN.md 3.8 item 8): PIFA in the
# three-instruction VIA1 poll $408036FC / $40803700 / $40803704, PLAS the
# same, PACT advancing between samples, halted 0, bus errors 0.  Anything
# else means the SDRAM path, not the ROM, is the question.
#
# A probe that is NOT in the running bitstream is never reported as data
# (MacPlus's lesson: an absent probe used to read 0 and every field derived
# from it printed as a confident number).  Absent probes are declared and
# their lines suppressed.

set samples 1
set delay   1.0
if {$argc >= 1} { set samples [lindex $argv 0] }
if {$argc >= 2} { set delay   [lindex $argv 1] }

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
			[expr {$in_poll ? "<- in the VIA1 poll the bench predicts" : "<- NOT the predicted poll"}]]
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
		#  rom_loaded, reset_n, 5'b0, berr_cnt[15:0]} -- rtl/dbg_probes.sv;
		# keep the two in step.
		set psta [rd PSTA]
		set fc        [expr {($psta >> 29) & 7}]
		set rw        [expr {($psta >> 28) & 1}]
		set dsack     [expr {($psta >> 26) & 3}]
		set berr_seen [expr {($psta >> 25) & 1}]
		set halted    [expr {($psta >> 24) & 1}]
		set sdram_rdy [expr {($psta >> 23) & 1}]
		set rom_ld    [expr {($psta >> 22) & 1}]
		set reset_n   [expr {($psta >> 21) & 1}]
		set berr_cnt  [expr {$psta & 0xFFFF}]
		set fcname [lindex {"0 (reserved)" "user data" "user program" "3 (reserved)" "4 (reserved)" "super data" "super program" "CPU space"} $fc]
		puts [format "  PSTA  %08X   last cycle FC=%d %s %s, last DSACK*=%d%d" $psta $fc $fcname \
			[expr {$rw ? "read" : "write"}] [expr {($dsack >> 1) & 1}] [expr {$dsack & 1}]]
		puts [format "        reset released=%d  rom loaded=%d  sdram ready=%d  halted=%d  bus error seen=%d  bus errors=%d" \
			$reset_n $rom_ld $sdram_rdy $halted $berr_seen $berr_cnt]
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
puts "How to read this (SE30_PLAN.md 3.8 item 8):"
puts "  * PIFA in 408036FC/40803700/40803704 with PACT advancing and halted 0,"
puts "    bus errors 0: the ROM ran from reset to the VIA1 poll, as the bench"
puts "    predicts. The SDRAM path (ROM in SDRAM, GLUE's 4-clock cycle) works."
puts "  * PACT frozen: the CPU is stalled on a bus cycle; PLAS names it, PSTA's"
puts "    FC and DSACK* say what kind and whether it was ever acknowledged."
puts "  * halted 1 or bus errors > 0: a double fault or a BERR; PLAS is the"
puts "    address that drew it. The SDRAM path, not the ROM, is the question."
puts "  * rom loaded 0 / sdram ready 0 / reset released 0: the machine never"
puts "    left reset -- the HPS download or the SDRAM power-up ladder."
