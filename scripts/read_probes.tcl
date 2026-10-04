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
#   ... dqmforce 1 | 0                           hold the mask high (A12:11 and the
#                                                DQM pins; the machine stays held):
#                                                a peek then reads the floating bus
#                                                if the chip sees it; 0 releases
#   ... scsitime [file]                          the SCSI disk's time (PSCT, plan
#                                                10.4 item 3): the counters, and
#                                                their differences from the last
#                                                scsitime (saved in file, default
#                                                scsitime_last.txt here) - run it
#                                                just before and just after a test;
#                                                the machine is not touched
#   ... fputime [file]                           the Math figure's counters (PFPU,
#                                                plan 10.4 item 4): the 68882's
#                                                instructions and busy time, the
#                                                SANE traps, the I-cache's misses
#                                                and hits; differences from the last
#                                                fputime (default fputime_last.txt)
#   ... profile start | stop | read [file]       the pace's time profile (PPRF, plan
#                                                10.4 item 4): start clears and
#                                                counts, stop stops, read prints every
#                                                decoder row (tools/time030/
#                                                pace_rows.txt) by its share of the
#                                                clocks and writes them to file
#                                                (default profile_last.csv)
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
if {$argc >= 1 && [lsearch -exact {peek peeks poke mode raw dqmtest dqmread dqmforce scsitime fputime profile} [lindex $argv 0]] >= 0} {
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
array set pw {}
array set absent {}
foreach inst $info {
	# {index source_width probe_width instance_name}
	set idx([lindex $inst 3]) [lindex $inst 0]
	set pw([lindex $inst 3]) [lindex $inst 2]
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
if {$op eq "scsitime"} {
	# MacSE30.sv's meter, MSB first: clocks, BSY, hold-off, GLUE's DRQ
	# wait (40 bits each), commands (24), then reads and writes, each
	# {requests 24, round trips summed 40, sd_ack high 40, longest 24}, and
	# since compile 39 (464 bits) the sectors the write requests carried (24)
	if {![have PSCT]} { puts "ERROR: this bitstream has no PSCT (built before plan 10.4 item 3's meter)"; end_insystem_source_probe; exit 1 }
	set v [rd PSCT]
	set names {clk bsy hold hsw cmd rd_n rd_sum rd_ack rd_max wr_n wr_sum wr_ack wr_max}
	set widths {40 40 40 40 24 24 40 40 24 24 40 40 24}
	set sh $pw(PSCT)
	if {$sh >= 464} { lappend names wr_sec; lappend widths 24 }
	array set now {}
	foreach nm $names w $widths {
		set sh [expr {$sh - $w}]
		set now($nm) [expr {($v >> $sh) & ((1 << $w) - 1)}]
	}
	set f [expr {[llength $opargs] >= 1 ? [lindex $opargs 0] : "scsitime_last.txt"}]
	set mhz 31.3344
	proc us {clk n} { global mhz; return [expr {$n > 0 ? double($clk) / $n / $mhz : 0.0}] }
	puts [format "  PSCT  since configuration: %.1f s, %u commands, %u HPS reads, %u HPS writes" \
		[expr {$now(clk) / ($mhz * 1e6)}] $now(cmd) $now(rd_n) $now(wr_n)]
	puts [format "        longest round trip: read %.0f us, write %.0f us" \
		[expr {$now(rd_max) / $mhz}] [expr {$now(wr_max) / $mhz}]]
	if {[file exists $f]} {
		set fh [open $f r]; array set was [read $fh]; close $fh
		array set dt {}
		foreach nm $names w $widths {
			if {![info exists was($nm)]} { set was($nm) $now($nm) }
			set dt($nm) [expr {($now($nm) - $was($nm)) & ((1 << $w) - 1)}]
		}
		# sectors: a read request carries one, a write request sd_blk_cnt + 1
		set dt(rd_sec) $dt(rd_n)
		if {![info exists dt(wr_sec)]} { set dt(wr_sec) $dt(wr_n) }
		set el [expr {$dt(clk) / ($mhz * 1e6)}]
		set pc [expr {$dt(clk) > 0 ? 100.0 / $dt(clk) : 0.0}]
		puts ""
		puts [format "  since the last scsitime: %.3f s" $el]
		puts [format "    SCSI bus busy (a target BSY)   %8.3f s  %5.1f %%   %u commands" \
			[expr {$dt(bsy) / ($mhz * 1e6)}] [expr {$dt(bsy) * $pc}] $dt(cmd)]
		puts [format "    a target waiting on the HPS    %8.3f s  %5.1f %%   (data phase, next byte not there)" \
			[expr {$dt(hold) / ($mhz * 1e6)}] [expr {$dt(hold) * $pc}]]
		puts [format "    GLUE holding the CPU for DRQ   %8.3f s  %5.1f %%" \
			[expr {$dt(hsw) / ($mhz * 1e6)}] [expr {$dt(hsw) * $pc}]]
		foreach k {rd wr} kn {reads writes} {
			set n $dt(${k}_n)
			set ns $dt(${k}_sec)
			puts [format "    HPS %-6s %6u requests, %7u blocks (%.0f KB)  round trip %8.3f s  %5.1f %%" \
				$kn $n $ns [expr {$ns * 0.5}] [expr {$dt(${k}_sum) / ($mhz * 1e6)}] [expr {$dt(${k}_sum) * $pc}]]
			puts [format "           per request: %7.1f us = %7.1f us waiting for Linux + %6.1f us moving the blocks;  per block %6.1f us" \
				[us $dt(${k}_sum) $n] [us [expr {$dt(${k}_sum) - $dt(${k}_ack)}] $n] [us $dt(${k}_ack) $n] [us $dt(${k}_sum) $ns]]
		}
		set nb [expr {$dt(rd_sec) + $dt(wr_sec)}]
		if {$el > 0 && $nb > 0} {
			puts [format "    blocks per elapsed second: %.0f KB/s; per second of HPS round trip: %.0f KB/s" \
				[expr {$nb * 0.5 / $el}] [expr {$nb * 0.5 / (($dt(rd_sum) + $dt(wr_sum)) / ($mhz * 1e6))}]]
		}
	} else {
		puts "  (no earlier snapshot in $f: run scsitime again after the test for the differences)"
	}
	set fh [open $f w]; puts $fh [array get now]; close $fh
	puts "  snapshot saved to $f"
	end_insystem_source_probe
	exit 0
}

if {$op eq "fputime"} {
	# rtl/dbg_probes.sv's PFPU, MSB first
	if {![have PFPU]} { puts "ERROR: this bitstream has no PFPU (built before plan 10.4 item 4's probe)"; end_insystem_source_probe; exit 1 }
	set v [rd PFPU]
	set names  {clk fclk cir cmd cond busy apu fp68k elems aline fetch ihit}
	set widths {40 40 32 32 24 40 40 24 24 32 40 40}
	set sh 408
	array set now {}
	foreach nm $names w $widths {
		set sh [expr {$sh - $w}]
		set now($nm) [expr {($v >> $sh) & ((1 << $w) - 1)}]
	}
	set f [expr {[llength $opargs] >= 1 ? [lindex $opargs 0] : "fputime_last.txt"}]
	set hz 31.3344e6
	puts [format "  PFPU  since configuration: %.1f s, %u FPU instructions (command writes), %u SANE _FP68K, %u _Elems68K" [expr {$now(clk) / $hz}] $now(cmd) $now(fp68k) $now(elems)]
	if {[file exists $f]} {
		set fh [open $f r]; array set was [read $fh]; close $fh
		array set dt {}
		foreach nm $names w $widths { set dt($nm) [expr {($now($nm) - $was($nm)) & ((1 << $w) - 1)}] }
		set el [expr {$dt(clk) / $hz}]
		set pc [expr {$dt(clk) > 0 ? 100.0 / $dt(clk) : 0.0}]
		puts ""
		puts [format "  since the last fputime: %.3f s" $el]
		puts [format "    FPU instructions (command CIR writes)  %9u   conditionals (FBcc etc.) %u   CIR cycles %u" $dt(cmd) $dt(cond) $dt(cir)]
		puts [format "    CPU in bus cycles to the 68882         %8.3f s  %5.1f %%" [expr {$dt(fclk) / $hz}] [expr {$dt(fclk) * $pc}]]
		puts [format "    the 68882 not idle                     %8.3f s  %5.1f %%" [expr {$dt(busy) / $hz}] [expr {$dt(busy) * $pc}]]
		puts [format "    its APU running                        %8.3f s  %5.1f %%" [expr {$dt(apu) / $hz}] [expr {$dt(apu) * $pc}]]
		puts [format "    SANE: _FP68K %u  _Elems68K %u   (every A-line trap: %u)" $dt(fp68k) $dt(elems) $dt(aline)]
		set nf [expr {$dt(fetch) + $dt(ihit)}]
		puts [format "    instruction fetches: %u from the bus, %u I-cache hits  -> %.1f %% went to the bus" $dt(fetch) $dt(ihit) [expr {$nf > 0 ? 100.0 * $dt(fetch) / $nf : 0.0}]]
		if {$dt(cmd) > 0} {
			puts [format "    per FPU instruction: %.1f clocks of the 68882 busy, %.1f of the CPU in its bus cycles (C16M clocks)" [expr {$dt(busy) / 2.0 / $dt(cmd)}] [expr {$dt(fclk) / 2.0 / $dt(cmd)}]]
		}
	} else {
		puts "  (no earlier snapshot in $f: run fputime again after the test for the differences)"
	}
	set fh [open $f w]; puts $fh [array get now]; close $fh
	puts "  snapshot saved to $f"
	end_insystem_source_probe
	exit 0
}

if {$op eq "profile"} {
	# rtl/dbg_probes.sv's PPRF: source {enable, clear toggle, row[7:0]};
	# probe {row[7:0], count[31:0], clocks[39:0], budget[39:0], fetch wait
	# states[31:0], clocks enabled[39:0], enabled, clearing}
	if {![have PPRF]} { puts "ERROR: this bitstream has no PPRF (built before plan 10.4 item 4's profile)"; end_insystem_source_probe; exit 1 }
	set sub [lindex $opargs 0]
	set cur [expr 0x[read_source_data -instance_index $idx(PPRF) -value_in_hex]]
	proc pr_src {v} { global idx; write_source_data -instance_index $idx(PPRF) -value_in_hex -value [format %03X $v] }
	if {$sub eq "start"} {
		set cur [expr {($cur & 0x100) ^ 0x100}]
		pr_src $cur
		set n 0
		while {([rd PPRF] & 1) || $n < 2} { after 5; incr n; if {$n > 200} break }
		pr_src [expr {$cur | 0x200}]
		puts [format "  profile cleared and counting (enable=%d)" [expr {([rd PPRF] >> 1) & 1}]]
	} elseif {$sub eq "stop"} {
		pr_src [expr {$cur & 0x100}]
		set v [rd PPRF]
		puts [format "  profile stopped: %.3f s counted" [expr {(($v >> 2) & ((1 << 40) - 1)) / 31.3344e6}]]
	} elseif {$sub eq "read"} {
		if {($cur >> 9) & 1} { puts "  (counting: stop it first)"; end_insystem_source_probe; exit 1 }
		set names {}
		set rf [file join [file dirname [info script]] .. tools time030 pace_rows.txt]
		array set rname {}
		if {[file exists $rf]} {
			set fh [open $rf r]
			foreach line [split [read $fh] "\n"] {
				if {$line eq "" || [string index $line 0] eq "#"} continue
				set f [split $line "\t"]
				set rname([lindex $f 0]) "[lindex $f 2] [lindex $f 3]"
			}
			close $fh
		}
		set rows {}
		set tclk 0; set tcnt 0; set tbud 0; set ten 0
		for {set r 0} {$r < 256} {incr r} {
			pr_src [expr {($cur & 0x100) | $r}]
			set n 0
			while {1} {
				set v [rd PPRF]
				if {(($v >> 186) & 0xFF) == $r} break
				if {[incr n] > 50} { puts "  row $r: no answer"; break }
			}
			set fc  [expr {($v >> 42) & 0xFFFFFFFF}]
			set bud [expr {($v >> 74) & ((1 << 40) - 1)}]
			set clk [expr {($v >> 114) & ((1 << 40) - 1)}]
			set cnt [expr {($v >> 154) & 0xFFFFFFFF}]
			set ten [expr {($v >> 2) & ((1 << 40) - 1)}]
			if {$cnt == 0} continue
			lappend rows [list $r $cnt $clk $bud $fc]
			incr tclk $clk; incr tcnt $cnt; incr tbud $bud
		}
		set f [expr {[llength $opargs] >= 2 ? [lindex $opargs 1] : "profile_last.csv"}]
		set fh [open $f w]
		puts $fh "row,name,count,clocks,budget,fetch_ws"
		puts [format "  counted %.3f s (%u C16M clocks); %u instructions released, %u clocks in them (budget %u: the core %.3f of its budget)" \
			[expr {$ten / 31.3344e6}] [expr {$ten / 2}] $tcnt $tclk $tbud [expr {$tbud > 0 ? double($tclk) / $tbud : 0}]]
		puts "   row  share   count       avg clk  avg bud  avg fetch-ws  name"
		foreach e [lsort -integer -decreasing -index 2 $rows] {
			lassign $e r cnt clk bud fc
			set nm [expr {[info exists rname($r)] ? $rname($r) : "?"}]
			puts $fh "$r,\"$nm\",$cnt,$clk,$bud,$fc"
			puts [format "  %4d %5.1f%% %10u  %8.2f %8.2f %8.2f      %s" $r [expr {$tclk > 0 ? 100.0 * $clk / $tclk : 0}] $cnt \
				[expr {double($clk) / $cnt}] [expr {double($bud) / $cnt}] [expr {double($fc) / $cnt}] $nm]
		}
		close $fh
		puts "  written to $f"
		pr_src [expr {$cur & 0x100}]
	} else {
		puts "usage: profile start | stop | read \[file\]"
	}
	end_insystem_source_probe
	exit 0
}

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
		peeks {
			# several regions in ONE session: `peeks A1 N1 A2 N2 ...` (longword
			# addresses, hex; counts decimal).  The machine is released only at
			# the end, so every region is the same moment's (a second `peek`
			# would read a machine already restarting - plan 9.8)
			foreach {ah cnt} $opargs {
				set a0 [expr 0x$ah]
				puts [format "  region %06X x %d" $a0 $cnt]
				for {set i 0} {$i < $cnt} {incr i} {
					set a [expr {($a0 + $i) & 0x7FFFFF}]
					lassign [pk_peek $a] d st
					puts [format "  %06X: %08X%s" $a $d [note $st]]
				}
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
			# item 21: PPOK bit 37 with the hold up forces the mask (A12:11, the
			# chip's DQM on the MiSTer modules - plan 3.8 item 22) to 11 in the
			# controller; the hold stays up until `dqmforce 0`
			set on [expr {[lindex $opargs 0] ne "0"}]
			global idx
			if {$on} {
				write_source_data -instance_index $idx(PPOK) -value_in_hex -value [format %016llX [expr {1 << 37}]]
				write_source_data -instance_index $idx(PPEK) -value_in_hex -value [format %08X [expr {1 << 30}]]
				puts "DQM FORCED HIGH on A12:11 and the DQM pins: writes are ignored and reads blanked while it holds"
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
set prev_ih -1
set prev_dh -1
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
	if {[have PREG]} {
		# plan 3.8 item 23: D6 and D7 from the kernel's register file; the
		# test manager's command loop reports D6 and D7's low word
		set preg [rd PREG]
		set d6 [expr {($preg >> 32) & 0xFFFFFFFF}]
		set d7 [expr {$preg & 0xFFFFFFFF}]
		puts [format "  PREG  D6=%08X  D7=%08X   %s" $d6 $d7 			[expr {$d6 != 0 ? "D6 nonzero: in the test manager, a start-up test's failure code" : "D6 zero"}]]
	}
	if {[have PSWM]} {
		# plan 5.8: {the SWIM's 48 bits, the internal drive's 16} -- see
		# rtl/dbg_probes.sv for the layout
		set pswm [rd PSWM]
		set s  [expr {($pswm >> 16) & 0xFFFFFFFFFFFF}]
		set d  [expr {$pswm & 0xFFFF}]
		set ism    [expr {($s >> 47) & 1}]
		set lat    [expr {($s >> 39) & 0xFF}]
		set imode  [expr {($s >> 34) & 0x1F}]
		set mtrd   [expr {($s >> 33) & 1}]
		set en1    [expr {($s >> 32) & 1}]
		set en2    [expr {($s >> 31) & 1}]
		set sense  [expr {($s >> 30) & 1}]
		set smode  [expr {($s >> 19) & 0xFF}]
		set setup  [expr {($s >> 11) & 0xFF}]
		set phdir  [expr {($s >> 7) & 0xF}]
		puts [format "  PSWM  %016llX   %s  L7=%d L6=%d drive=%d MotorOn=%d PH=%X  IWM mode=%02X%s" $pswm \
			[expr {$ism ? "ISM" : "IWM"}] [expr {($lat >> 7) & 1}] [expr {($lat >> 6) & 1}] \
			[expr {($lat >> 5) & 1}] [expr {($lat >> 4) & 1}] [expr {$lat & 0xF}] $imode \
			[expr {$imode == 0x17 ? " (the ROM's start-up value)" : ""}]]
		puts [format "        delayed MotorOn=%d /ENBL1=%d /ENBL2=%d SENSE=%d  ISM mode=%02X setup=%02X dirs=%X" \
			$mtrd $en1 $en2 $sense $smode $setup $phdir]
		puts [format "        internal drive: motor=%d dir=%d eject latch=%d %s track=%d disk=%d /READY=%d%s%s%s" \
			[expr {($d >> 15) & 1}] [expr {($d >> 14) & 1}] [expr {($d >> 13) & 1}] \
			[expr {(($d >> 12) & 1) ? "MFM" : "GCR"}] [expr {$d & 0x7F}] \
			[expr {($d >> 11) & 1}] [expr {($d >> 10) & 1}] \
			[expr {(($d >> 9) & 1) ? " stepping" : ""}] [expr {(($d >> 8) & 1) ? " settling" : ""}] \
			[expr {(($d >> 7) & 1) ? " spinning up" : ""}]]
	}
	if {[have PADB]} {
		# plan 6.6: the transceiver's PIC, the line, the devices -- see
		# rtl/dbg_probes.sv for the layout
		set padb [rd PADB]
		set pc    [expr {($padb >> 55) & 0x1FF}]
		set w     [expr {($padb >> 47) & 0xFF}]
		set lines [expr {($padb >> 38) & 0x1FF}]
		set kst   [expr {($padb >> 34) & 0xF}]
		set mst   [expr {($padb >> 30) & 0xF}]
		set kcmd  [expr {($padb >> 22) & 0xFF}]
		set falls [expr {($padb >> 6) & 0xFFFF}]
		puts [format "  PADB  %016llX   PIC PC=%03o W=%02X  line=%d INT*=%d SCLK=%d DIO=%d ST=%d%d" $padb 			$pc $w [expr {($lines >> 8) & 1}] [expr {($lines >> 7) & 1}] [expr {($lines >> 6) & 1}] 			[expr {($lines >> 5) & 1}] [expr {($lines >> 4) & 1}] [expr {($lines >> 3) & 1}]]
		puts [format "        pulling: transceiver=%d keyboard=%d mouse=%d  engines: kbd=%d mouse=%d  last command=%02X  falls=%d%s" 			[expr {($lines >> 2) & 1}] [expr {($lines >> 1) & 1}] [expr {$lines & 1}] $kst $mst $kcmd $falls 			[expr {$w == 0 && (($lines >> 8) & 1) == 0 && $falls == 0 ? "   (line held low, no traffic: boot2.rom absent?)" : ""}]]
	}
	if {[have PFLP]} {
		# plan 5.12.12 item 7: the loader, the encoder, the disk port, the
		# bytes the ROM took -- see rtl/dbg_probes.sv for the layout
		set pflp [rd PFLP]
		set ld [expr {($pflp >> 48) & 0xFFFF}]
		set en [expr {($pflp >> 32) & 0xFFFF}]
		puts [format "  PFLP  %016llX   loader: disk in=%d loading=%d %s%s%s%s state=%d LBA low=%d" $pflp \
			[expr {($ld >> 15) & 1}] [expr {($ld >> 14) & 1}] \
			[expr {(($ld >> 13) & 1) ? "double-sided " : "single-sided "}] [expr {(($ld >> 12) & 1) ? "800K-file " : ""}] \
			[expr {(($ld >> 11) & 1) ? "tags " : ""}] [expr {(($ld >> 10) & 1) ? "DC42 " : ""}] \
			[expr {($ld >> 7) & 7}] [expr {$ld & 0x7F}]]
		puts [format "        encoder: track valid=%d side=%d state=%d slot=%d cylinder low=%d  port words=%d  bytes taken=%d" \
			[expr {($en >> 15) & 1}] [expr {($en >> 14) & 1}] [expr {($en >> 10) & 0xF}] [expr {($en >> 6) & 0xF}] \
			[expr {$en & 0x3F}] [expr {($pflp >> 16) & 0xFFFF}] [expr {$pflp & 0xFFFF}]]
	}
	if {[have PFL2]} {
		# plan 5.14: the external drive's loader, encoder and drive, the
		# disk-port words they moved -- see rtl/dbg_probes.sv for the layout
		set pfl2 [rd PFL2]
		set ld [expr {($pfl2 >> 48) & 0xFFFF}]
		set en [expr {($pfl2 >> 32) & 0xFFFF}]
		set d  [expr {($pfl2 >> 16) & 0xFFFF}]
		puts [format "  PFL2  %016llX   external loader: disk in=%d loading=%d %s%s%s%s state=%d LBA low=%d" $pfl2 			[expr {($ld >> 15) & 1}] [expr {($ld >> 14) & 1}] 			[expr {(($ld >> 13) & 1) ? "double-sided " : "single-sided "}] [expr {(($ld >> 12) & 1) ? "800K-file " : ""}] 			[expr {(($ld >> 11) & 1) ? "tags " : ""}] [expr {(($ld >> 10) & 1) ? "DC42 " : ""}] 			[expr {($ld >> 7) & 7}] [expr {$ld & 0x7F}]]
		puts [format "        encoder: track valid=%d side=%d state=%d slot=%d cylinder low=%d  port words=%d" 			[expr {($en >> 15) & 1}] [expr {($en >> 14) & 1}] [expr {($en >> 10) & 0xF}] [expr {($en >> 6) & 0xF}] 			[expr {$en & 0x3F}] [expr {$pfl2 & 0xFFFF}]]
		puts [format "        external drive: motor=%d dir=%d eject latch=%d %s track=%d disk=%d /READY=%d%s%s%s" 			[expr {($d >> 15) & 1}] [expr {($d >> 14) & 1}] [expr {($d >> 13) & 1}] 			[expr {(($d >> 12) & 1) ? "MFM" : "GCR"}] [expr {$d & 0x7F}] 			[expr {($d >> 11) & 1}] [expr {($d >> 10) & 1}] 			[expr {(($d >> 9) & 1) ? " stepping" : ""}] [expr {(($d >> 8) & 1) ? " settling" : ""}] 			[expr {(($d >> 7) & 1) ? " spinning up" : ""}]]
	}
	if {[have PSCS]} {
		# plan 9.8: the SCSI bus and the disks' hps_io slots -- see
		# rtl/dbg_probes.sv for the layout
		set pscs [rd PSCS]
		set d [expr {($pscs >> 16) & 0xFFFF}]
		set ph [expr {(($d >> 7) & 1) * 4 + (($d >> 6) & 1) * 2 + (($d >> 5) & 1)}]
		set phn [lindex {"data out" "data in" "command" "status" "?" "?" "message out" "message in"} $ph]
		puts [format "  PSCS  %08X   targets BSY=%d%d  REQ target=%d bus=%d  ACK=%d SEL=%d RST=%d ATN=%d  phase %s  chip BSY=%d DRQ=%d IRQ=%d" $pscs \
			[expr {($d >> 15) & 1}] [expr {($d >> 14) & 1}] [expr {($d >> 13) & 1}] [expr {($d >> 12) & 1}] \
			[expr {($d >> 11) & 1}] [expr {($d >> 10) & 1}] [expr {($d >> 9) & 1}] [expr {($d >> 8) & 1}] $phn \
			[expr {($d >> 4) & 1}] [expr {($d >> 3) & 1}] [expr {($d >> 2) & 1}]]
		puts [format "        a target waiting on the HPS=%d  GLUE holding the CPU for DRQ=%d" [expr {($d >> 1) & 1}] [expr {$d & 1}]]
		puts [format "        disks: rd=%d%d wr=%d%d ack=%d%d  sectors moved (low 10 bits)=%d" \
			[expr {($pscs >> 15) & 1}] [expr {($pscs >> 14) & 1}] [expr {($pscs >> 13) & 1}] [expr {($pscs >> 12) & 1}] \
			[expr {($pscs >> 11) & 1}] [expr {($pscs >> 10) & 1}] [expr {$pscs & 0x3FF}]]
	}
	if {[have PASC]} {
		# plan 11.3: the ASC -- see rtl/dbg_probes.sv for the layout
		set p [rd PASC]
		puts [format "  PASC  %08X   mode=%d (0 off, 1 FIFO, 2 wavetable)  \$804=%X  FIFO A=%d  FIFO B=%d  interrupts raised (low 4 bits)=%d" $p 			[expr {($p >> 30) & 3}] [expr {($p >> 26) & 0xF}] [expr {($p >> 15) & 0x7FF}] [expr {($p >> 4) & 0x7FF}] [expr {$p & 0xF}]]
	}
	if {[have PSCC]} {
		# plan 10.5: the SCC -- see rtl/dbg_probes.sv for the layout
		set p [rd PSCC]
		set r0 [expr {$p & 0xFF}]
		puts [format "  PSCC  %08X   accesses (low 12 bits)=%d  pointer=%d  /INT=%d  MIE=%d  IPs RxA=%d TxA=%d ExtA=%d RxB=%d TxB=%d ExtB=%d" $p 			[expr {($p >> 20) & 0xFFF}] [expr {($p >> 16) & 0xF}] [expr {($p >> 15) & 1}] [expr {($p >> 14) & 1}] 			[expr {($p >> 13) & 1}] [expr {($p >> 12) & 1}] [expr {($p >> 11) & 1}] [expr {($p >> 10) & 1}] [expr {($p >> 9) & 1}] [expr {($p >> 8) & 1}]]
		puts [format "        RR0B=%02X  Break/Abort=%d EOM=%d CTS=%d Sync/Hunt=%d DCD=%d TBE=%d ZC=%d RxAvail=%d   (LocalTalk sees the line free when Sync/Hunt=1)" $r0 			[expr {($r0 >> 7) & 1}] [expr {($r0 >> 6) & 1}] [expr {($r0 >> 5) & 1}] [expr {($r0 >> 4) & 1}] 			[expr {($r0 >> 3) & 1}] [expr {($r0 >> 2) & 1}] [expr {($r0 >> 1) & 1}] [expr {$r0 & 1}]]
	}
	if {[have PCCH]} {
		# plan 1.16.3: the 68030's caches -- {CDIS*, 0, CACR[13:0]}, then the
		# instruction and data hits (24 bits each, wrapping)
		set pcch [rd PCCH]
		set cacr [expr {($pcch >> 48) & 0x3FFF}]
		set cdis [expr {($pcch >> 63) & 1}]
		set ih [expr {($pcch >> 24) & 0xFFFFFF}]
		set dh [expr {$pcch & 0xFFFFFF}]
		set ihd ""; set dhd ""
		if {$prev_ih >= 0} {
			set ihd [format "  (+%u since the last sample)" [expr {($ih - $prev_ih) & 0xFFFFFF}]]
			set dhd [format "  (+%u)" [expr {($dh - $prev_dh) & 0xFFFFFF}]]
		}
		set prev_ih $ih; set prev_dh $dh
		puts [format "  PCCH  %016llX   CACR=%04X  instruction cache %s%s  data cache %s%s%s  CDIS*=%s" $pcch $cacr \
			[expr {($cacr & 1) ? "ON" : "off"}] [expr {($cacr & 2) ? " frozen" : ""}] \
			[expr {($cacr & 0x100) ? "ON" : "off"}] [expr {($cacr & 0x200) ? " frozen" : ""}] \
			[expr {($cacr & 0x2000) ? " WA" : ""}] [expr {$cdis ? "asserted (both off)" : "negated"}]]
		puts [format "        hits: instruction %u%s  data %u%s" $ih $ihd $dh $dhd]
	}
	if {[have PEXC]} {
		# plan 5.12.12 item 8: the CPU's exceptions -- see rtl/dbg_probes.sv
		set pexc [rd PEXC]
		set ring [expr {$pexc & 0xFFFFFFFFFFFFFFFF}]
		set vecs {}
		for {set k 0} {$k < 8} {incr k} { lappend vecs [format %d [expr {($ring >> (8 * $k)) & 0xFF}]] }
		puts [format "  PEXC  exceptions=%d  A-line=%d  interrupts=%d  F-line=%d  address=%d  illegal=%d  bus error=%d  other=%d" \
			[expr {($pexc >> 144) & 0xFFFF}] [expr {($pexc >> 128) & 0xFFFF}] [expr {($pexc >> 112) & 0xFFFF}] \
			[expr {($pexc >> 96) & 0xFFFF}] [expr {($pexc >> 88) & 0xFF}] [expr {($pexc >> 80) & 0xFF}] \
			[expr {($pexc >> 72) & 0xFF}] [expr {($pexc >> 64) & 0xFF}]]
		puts "        the last 8 other vectors, newest first: $vecs   (2 bus error, 3 address, 4 illegal, 11 F-line, 32-47 TRAP #n)"
	}
	if {[have PTRP]} {
		set ptrp [rd PTRP]
		set words {}
		for {set k 0} {$k < 16} {incr k} { lappend words [format %04X [expr {($ptrp >> (16 * $k)) & 0xFFFF}]] }
		puts "  PTRP  the last 16 A-line trap words, newest first:"
		puts "        [lrange $words 0 7]"
		puts "        [lrange $words 8 15]"
	}
	if {[have PFLN]} {
		set pfln [rd PFLN]
		puts "  PFLN  the last 4 F-line exceptions, newest first (opcode at address):"
		set lines {}
		for {set k 0} {$k < 4} {incr k} {
			set e [expr {($pfln >> (48 * $k)) & 0xFFFFFFFFFFFF}]
			lappend lines [format "%04X at %08X" [expr {($e >> 32) & 0xFFFF}] [expr {$e & 0xFFFFFFFF}]]
		}
		puts "        [join $lines {   }]"
	}
	if {[have PRTC]} {
		# plan 6.6: the clock chip
		set prtc [rd PRTC]
		puts [format "  PRTC  %08X   seconds low=%02X  last command=%02X  transactions=%d  write protect=%d" $prtc 			[expr {($prtc >> 24) & 0xFF}] [expr {($prtc >> 16) & 0xFF}] [expr {($prtc >> 8) & 0xFF}] [expr {($prtc >> 7) & 1}]]
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
puts "Since plan 3.8 item 23:"
puts "  * PREG with PIFA in 40802EDC-40803304: the ROM's serial test manager;"
puts "    D6 is the failed test's code and D7 its flags (the Sad Mac's numbers)."
puts "Since Section 5 (the SWIM, rung 1, SE30_PLAN.md 5.6 and 5.11):"
puts "  * PIFA past 408006E6 and PSWM IWM mode=17: the ROM's mode-set loop is done."
puts "  * PSWM phase dirs=F with PH=7 left over: the .Sony Open's SWIM probe"
puts "    ran (\$F5-\$F7 echoed); the drive's motor/track show its commands."
puts "  * The screen is the target: the flashing question-mark disk."
puts "Since plan 5.12.12 item 7 (GCR reading, rung 2):"
puts "  * PFLP loader disk in=1 after a mount: the whole image is in SDRAM (the HPS"
puts "    delivers an 800K file in some tens of seconds; loading=1 until then)."
puts "  * encoder track valid=1 with its cylinder = PSWM's track: the head's track is"
puts "    built; port words climb by about 6,300 a side at each seek."
puts "  * bytes taken climbing by thousands: the ROM is reading the disk. The screen"
puts "    is the verdict: the happy Mac, then as far as the machine goes."
puts "Since plan 5.12.12 item 8 (the stop at \"Welcome to Macintosh\"):"
puts "  * PEXC's counts over several samples: which exception is climbing (F-line"
puts "    with no 68882; address or illegal from an unsupported instruction), and"
puts "    the last vectors that were neither interrupts nor Toolbox traps."
puts "  * PTRP: the Toolbox/OS calls being made - a loop repeats its trap words."
puts "Since Section 6 (the ADB and the clock chip, SE30_PLAN.md 6.7 and 6.10):"
puts "  * PADB W changing and the line released: the transceiver runs its program"
puts "    (with no boot2.rom the PC runs through NOPs, W stays 0, the line stays low)."
puts "  * PADB falls climbing by about a thousand a second (ten per Talk, one Talk"
puts "    every 10.2 ms: the auto-poll), last command 3C (Talk R0 to the mouse):"
puts "    the ADB Manager's initialisation is done."
puts "  * PRTC transactions > 0 and seconds low ticking: InitUtil talked to the"
puts "    clock chip and the one-second interrupt has a source."
