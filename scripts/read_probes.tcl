# Read the SE/30 bring-up probe deck over the DE10-Nano's USB-Blaster.
#
#   quartus_stp -t scripts/read_probes.tcl          one sample, decoded
#   quartus_stp -t scripts/read_probes.tcl 10 0.5   10 samples, 0.5 s apart
#
# and the memory operations of plan 3.8 items 18 and 19, which hold the
# machine in reset and drive the SDRAM controller's ports over JTAG (the
# machine restarts from the reset vector when released):
#   ... peek <longword hex> [count] [step]       read longwords, count of them, step apart (-1: descending)
#   ... poke <longword hex> <data hex> [be hex]  a CPU-port write (byte
#                                                enables, default F), read back
#   ... mode <hex>                               LOAD MODE with this value
#                                                (0221 single-location writes,
#                                                the design; 0021 burst writes)
#   ... raw <word hex> <w0> <w1> <dqm> <oe> <sel> [ap] [second] [read]
#                                                one raw experiment (below),
#                                                the longword read back
#   ... dqmtest [word hex]                       the write-mask experiment set
#   ... dqmread [word hex]                       the masked-read test: DQM on
#                                                a READ blanks its output beats
#                                                two clocks later, if the chip
#                                                sees DQM at all
#   ... dqmforce 1 | 0                           hold both DQM pins high (the
#                                                machine stays held) for a meter
#                                                on the chip's LDQM/UDQM pins, 15
#                                                and 39 of the TSOP-54; 0 releases
#
# The board is never flashed from here (the standing rule); the writes above
# are to the SDRAM, through the design's own controller, for measurement.
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
set op      ""
set opargs  {}
if {$argc >= 1 && [lsearch -exact {peek poke mode raw dqmtest dqmread dqmforce} [lindex $argv 0]] >= 0} {
	set op     [lindex $argv 0]
	set opargs [lrange $argv 1 end]
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

# ---- the memory operations (plan 3.8 items 18 and 19) -------------------------
# MacSE30.sv's poke: PPEK's source is {go, hold, we, raw, 5'b0, longword
# address}; PPOK's {27'b0, odd, byte enables, write data}; PRAW's the
# controller's raw schedule word (rtl/se30_sdram.v, THE RAW EXPERIMENT
# PORT).  PPEK's probe is {operations done[7:0], data[31:0]}: one read gives
# the count and the data of the same operation, so waiting for the count to
# change and taking the data from that very word can never pair a new count
# with old data (item 18's peek kept them in two probes and was seen one
# read behind).  Addresses are the controller's: the 32 MB as longwords, the
# ROM image at $200000 (byte $800000, CPU $40800000).
if {$op ne ""} {
	foreach need {PPEK PPKS PPOK PRAW} {
		if {![have $need]} { puts "ERROR: this bitstream has no $need (built before plan 3.8 item 19's poke)"; exit 1 }
	}
	set ::go 0
	# one operation: flags = {we, raw}; returns {data ok|timeout}
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
			if {(($v >> 32) & 0xFF) != $before} { return [list [expr {$v & 0xFFFFFFFF}] ok] }
			if {[incr tries] >= 50} { return [list [expr {$v & 0xFFFFFFFF}] timeout] }
			after 2
		}
	}
	proc pk_peek {lw} { return [pk_op 0 $lw] }
	proc pk_poke {lw data be} {
		global idx
		write_source_data -instance_index $idx(PPOK) -value_in_hex -value [format %016llX [expr {($be << 32) | ($data & 0xFFFFFFFF)}]]
		return [pk_op 2 $lw]
	}
	# the schedule word: dqm/oe are per clock 2, 3, 4, 5 after the ACTIVE,
	# sel per clock 2, 3, 4; rd makes the command at clock 2 a READ
	proc raw_ctl {w0 w1 dqm oe sel ap second kind mode {rd 0}} {
		return [expr {($mode << 51) | ($kind << 50) | ($second << 49) | ($ap << 48) | ($rd << 47) | (($sel & 7) << 44) | ($oe << 40) | ($dqm << 32) | (($w1 & 0xFFFF) << 16) | ($w0 & 0xFFFF)}]
	}
	proc pk_raw {word ctl} {
		global idx
		write_source_data -instance_index $idx(PRAW) -value_in_hex -value [format %016llX $ctl]
		write_source_data -instance_index $idx(PPOK) -value_in_hex -value [format %016llX [expr {($word & 1) << 36}]]
		return [pk_op 1 [expr {$word >> 1}]]
	}
	proc pk_mode {mode} { return [pk_raw 0 [raw_ctl 0 0 0 0 0 0 0 1 $mode]] }
	# "00.11.00.00" -> the DQM field (clock 2 first); "1100" -> an oe/sel field (clock 2 first)
	proc dqm_field {str} {
		set v 0; set k 0
		foreach pair [split $str .] { set v [expr {$v | ([expr 0b$pair] << (2 * $k))}]; incr k }
		return $v
	}
	proc bit_field {str} {
		set v 0; set k 0
		foreach c [split $str ""] { set v [expr {$v | ($c << $k)}]; incr k }
		return $v
	}
	proc note {st} { return [expr {$st eq "ok" ? "" : "   (no acknowledge: the operation never completed)"}] }
	proc release {} {
		global idx
		write_source_data -instance_index $idx(PPEK) -value_in_hex -value 00000000
		puts "machine released from reset"
	}

	# The first operation of a session flushes the controller: while the
	# machine ran, the hold cut a cycle short and its data waits in the
	# controller's done state, where (until plan 3.8 item 20's fix) no
	# refresh runs, the overdue-refresh flag then blocks every new start, and
	# a request is acknowledged with the old data - one read behind for the
	# whole session.  A write's acknowledge clears that state.  The scratch
	# longword is above the RAM image and below the training pair.
	pk_poke 0x3FFFFE 0 0xF
	switch -- $op {
		peek {
			set a0   [expr 0x[lindex $opargs 0]]
			set n    [expr {[llength $opargs] >= 2 ? [lindex $opargs 1] : 1}]
			set step [expr {[llength $opargs] >= 3 ? [lindex $opargs 2] : 1}]
			for {set i 0} {$i < $n} {incr i} {
				set a [expr {($a0 + $i * $step) & 0x7FFFFF}]
				lassign [pk_peek $a] d st
				puts [format "  %06X: %08X%s" $a $d [note $st]]
			}
		}
		poke {
			set a  [expr 0x[lindex $opargs 0]]
			set d  [expr 0x[lindex $opargs 1]]
			set be [expr {[llength $opargs] >= 3 ? [expr 0x[lindex $opargs 2]] : 0xF}]
			lassign [pk_poke $a $d $be] w st
			puts [format "  poke %06X <- %08X be %X%s" $a $d $be [note $st]]
			lassign [pk_peek $a] r st
			puts [format "  %06X: %08X%s" $a $r [note $st]]
		}
		mode {
			set m [expr 0x[lindex $opargs 0]]
			lassign [pk_mode $m] w st
			puts [format "  LOAD MODE %04X%s" $m [note $st]]
		}
		raw {
			lassign $opargs word w0 w1 dqm oe sel ap second rd
			if {$ap eq ""} { set ap 1 }
			if {$second eq ""} { set second 0 }
			if {$rd eq ""} { set rd 0 }
			set word [expr 0x$word]
			set ctl [raw_ctl [expr 0x$w0] [expr 0x$w1] [dqm_field $dqm] [bit_field $oe] [bit_field $sel] $ap $second 0 0 $rd]
			lassign [pk_raw $word $ctl] w st
			puts [format "  raw at word %06X: ctl %016llX%s%s" $word $ctl \
				[expr {$rd ? [format "   the READ captured %08X" $w] : ""}] [note $st]]
			lassign [pk_peek [expr {$word >> 1}]] r st
			puts [format "  %06X: %08X%s" [expr {$word >> 1}] $r [note $st]]
		}
		dqmforce {
			# item 21: PPOK bit 37 with the hold up forces sd_dqm to 11 in the
			# controller; the hold stays up until `dqmforce 0` so the pins can
			# be measured
			set on [expr {[lindex $opargs 0] ne "0"}]
			global idx
			if {$on} {
				write_source_data -instance_index $idx(PPOK) -value_in_hex -value [format %016llX [expr {1 << 37}]]
				write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X [expr {1 << 30}]]
				puts "DQM FORCED HIGH: both DQM pins should read 3.3 V at the chip (LDQM pin 15, UDQM pin 39 of the TSOP-54)"
				puts "the machine is held in reset until: quartus_stp -t scripts/read_probes.tcl dqmforce 0"
			} else {
				write_source_data -instance_index $idx(PPOK) -value_in_hex -value 0000000000000000
				release
			}
		}
		dqmread {
			# The masked-read test (plan 3.8 item 20).  A READ through the raw
			# port with DQM on its own clock and the next: the chip blanks the
			# two output beats two clocks later (DQM's read latency), so the
			# capture sees the floating bus instead of the words - if, and only
			# if, DQM reaches the chip.  Nothing here depends on write timing.
			set word [expr {[llength $opargs] >= 1 ? [expr 0x[lindex $opargs 0]] : 0x400000}]
			set word [expr {$word & ~1}]
			lassign [pk_peek [expr {$word >> 1}]] truth st
			puts [format "masked-read test at word %06X: the longword reads %08X through the CPU port" $word $truth]
			foreach {name dqm} {"unmasked" 00.00.00.00 "DQM on clocks 2 and 3" 11.11.00.00 "DQM on clock 2" 11.00.00.00 "DQM on clock 3" 00.11.00.00 "DQM on clocks 3 and 4" 00.11.11.00} {
				set ctl [raw_ctl 0 0 [dqm_field $dqm] 0 0 1 0 0 0 1]
				lassign [pk_raw $word $ctl] w st
				set hi [expr {(($w >> 16) & 0xFFFF) == (($truth >> 16) & 0xFFFF)}]
				set lo [expr {($w & 0xFFFF) == ($truth & 0xFFFF)}]
				puts [format "  %-24s raw READ captured %08X   %s%s" $name $w \
					[expr {$hi && $lo ? "both words: DQM did nothing" : (!$hi && !$lo ? "neither word: DQM blanked both beats" : ($hi ? "the second beat blanked (DQM read latency 2)" : "the first beat blanked"))}] [note $st]]
			}
			puts "How to read this: if every row reads the words, DQM never reaches the chip"
			puts "(the pins, the module); if the masked rows are blanked, the chip sees DQM and"
			puts "the write mask alone is what it ignores."
		}
		dqmtest {
			# The write-mask experiment set (plan 3.8 item 19).  Each row: the
			# longword is set to $AAAA5555 through the CPU port, one raw
			# experiment runs at the even word, the longword is read back and
			# printed beside what a chip that masks as the datasheet says would
			# hold.  w0 = $1111 (the word at clock 2), w1 = $2222.  Rows 1-9 run
			# in burst-write mode (A9 = 0, as the design had until compile 9),
			# rows 10-12 in single-location mode (the design since); the mode
			# register is restored at the end.
			set word [expr {[llength $opargs] >= 1 ? [expr 0x[lindex $opargs 0]] : 0x000200}]
			set word [expr {$word & ~1}]
			set lw [expr {$word >> 1}]
			set old 0xAAAA5555
			proc row {name ctl expect} {
				global word lw old
				pk_poke $lw $old 0xF
				lassign [pk_raw $word $ctl] w st1
				lassign [pk_peek $lw] r st2
				set verdict [expr {$r == $expect ? "as the datasheet" : "DIFFERS"}]
				if {$st1 ne "ok" || $st2 ne "ok"} { set verdict "NO ACKNOWLEDGE" }
				puts [format "  %-52s read %08X   datasheet %08X   %s" $name $r $expect $verdict]
			}
			puts [format "write-mask experiments at word %06X (longword %06X), the old contents %08X" $word $lw $old]
			puts "-- single-location mode, the CPU port (the design since compile 9)"
			lassign [pk_poke $lw $old 0xF] w st; lassign [pk_peek $lw] r st
			puts [format "  %-52s read %08X   datasheet %08X   %s" "0a. a longword write, be F" $r $old [expr {$r == $old ? "as the datasheet" : "DIFFERS"}]]
			lassign [pk_poke $lw 0x33334444 0xC] w st; lassign [pk_peek $lw] r st
			puts [format "  %-52s read %08X   datasheet %08X   %s" "0b. be C: the high word only" $r 0x33335555 [expr {$r == 0x33335555 ? "as the datasheet" : "DIFFERS"}]]
			lassign [pk_poke $lw 0x66667777 0x3] w st; lassign [pk_peek $lw] r st
			puts [format "  %-52s read %08X   datasheet %08X   %s" "0c. be 3: the low word only" $r 0x33337777 [expr {$r == 0x33337777 ? "as the datasheet" : "DIFFERS"}]]
			lassign [pk_poke $lw 0x88889999 0x6] w st; lassign [pk_peek $lw] r st
			puts [format "  %-52s read %08X   datasheet %08X   %s" "0d. be 6: the middle bytes" $r 0x33889977 [expr {$r == 0x33889977 ? "as the datasheet" : "DIFFERS"}]]
			puts "-- burst-write mode (LOAD MODE 0021): one WRITE, two beats"
			lassign [pk_mode 0x0021] w st; puts "  LOAD MODE 0021[note $st]"
			row "1. clock 3 masked, w0 still driven (compile 8's download)" [raw_ctl 0x1111 0x2222 [dqm_field 00.11.00.00] [bit_field 1100] [bit_field 0000] 1 0 0 0] 0x11115555
			row "2. clock 3 masked, bus released"                            [raw_ctl 0x1111 0x2222 [dqm_field 00.11.00.00] [bit_field 1000] [bit_field 0000] 1 0 0 0] 0x11115555
			row "3. clock 3 unmasked with w1"                                [raw_ctl 0x1111 0x2222 [dqm_field 00.00.00.00] [bit_field 1100] [bit_field 0100] 1 0 0 0] 0x11112222
			row "4. clocks 3 and 4 masked, w1 driven at 3"                   [raw_ctl 0x1111 0x2222 [dqm_field 00.11.11.00] [bit_field 1100] [bit_field 0100] 1 0 0 0] 0x11115555
			row "5. clock 2 masked (the first beat), w1 at 3"                [raw_ctl 0x1111 0x2222 [dqm_field 11.00.00.00] [bit_field 1100] [bit_field 0100] 1 0 0 0] 0xAAAA2222
			row "6. clocks 2 and 3 masked"                                   [raw_ctl 0x1111 0x2222 [dqm_field 11.11.00.00] [bit_field 1100] [bit_field 0100] 1 0 0 0] 0xAAAA5555
			row "7. clock 4 masked only, w1 at 3"                            [raw_ctl 0x1111 0x2222 [dqm_field 00.00.11.00] [bit_field 1100] [bit_field 0100] 1 0 0 0] 0x11112222
			row "8. two WRITEs (2: w0, 3: w1), clock 4 masked"               [raw_ctl 0x1111 0x2222 [dqm_field 00.00.11.00] [bit_field 1100] [bit_field 0100] 1 1 0 0] 0x11112222
			row "9. two WRITEs, the second masked, clock 4 masked"           [raw_ctl 0x1111 0x2222 [dqm_field 00.11.11.00] [bit_field 1100] [bit_field 0100] 1 1 0 0] 0x11115555
			puts "-- single-location mode (LOAD MODE 0221): a WRITE is one word"
			lassign [pk_mode 0x0221] w st; puts "  LOAD MODE 0221[note $st]"
			row "10. as 1: clock 3 masked, w0 still driven"                  [raw_ctl 0x1111 0x2222 [dqm_field 00.11.00.00] [bit_field 1100] [bit_field 0000] 1 0 0 0] 0x11115555
			row "11. two WRITEs, the second masked"                          [raw_ctl 0x1111 0x2222 [dqm_field 00.11.00.00] [bit_field 1100] [bit_field 0100] 1 1 0 0] 0x11115555
			row "12. clock 2 masked: the one word masked"                    [raw_ctl 0x1111 0x2222 [dqm_field 11.00.00.00] [bit_field 1000] [bit_field 0000] 1 0 0 0] 0xAAAA5555
			row "13. two WRITEs, both unmasked"                              [raw_ctl 0x1111 0x2222 [dqm_field 00.00.00.00] [bit_field 1100] [bit_field 0100] 1 1 0 0] 0x11112222
			puts "How to read this: a row that DIFFERS in burst-write mode names how the chip"
			puts "takes DQM on the clocks after a WRITE; rows 0 and 10-13 are the design's own"
			puts "write forms and must all read as the datasheet."
		}
	}
	if {$op ne "dqmforce"} { release }
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
