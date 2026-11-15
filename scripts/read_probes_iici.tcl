# Read the Macintosh IIci's bring-up probes over the DE10-Nano's USB-Blaster
# (MacIIci.sv "PROBES", USE_DBG_PROBES in MacIIci.qsf).
#
#   quartus_stp -t scripts/read_probes_iici.tcl          one sample, decoded
#   quartus_stp -t scripts/read_probes_iici.tcl 20 0.2   20 samples, 0.2 s apart
#   quartus_stp -t scripts/read_probes_iici.tcl cfg <hex>  set the experiment switches (PCFG: 8 posted
#                                                        writes off, 4 CDIS*, 2 instruction cache off,
#                                                        1 data cache off); then reset the Mac from the OSD
#
# Reading only: nothing on the board is changed.

set cfg ""
if {[lindex $quartus(args) 0] eq "cfg"} { set cfg [lindex $quartus(args) 1]; set quartus(args) {} }
set n     [expr {[llength $quartus(args)] > 0 ? [lindex $quartus(args) 0] : 1}]
set pause [expr {[llength $quartus(args)] > 1 ? [lindex $quartus(args) 1] : 0.5}]

# The on-board blaster enumerates as "DE-SoC [USB-n]"; the chain is
# {@1 SOCVHPS, @2 5CSEBA6} and only the FPGA carries the probes' hub.
set hw ""
foreach h [get_hardware_names] {
	if {[string match "*DE-SoC*" $h] || [string match "*USB-Blaster*" $h]} { set hw $h; break }
}
if {$hw eq ""} { puts "ERROR: no JTAG hardware found. Is the DE10-Nano connected and powered?"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
	if {[string match "*5CSEBA6*" $d] || [string match "*5CSEMA6*" $d]} { set dev $d; break }
}
if {$dev eq ""} { puts "ERROR: no Cyclone V FPGA in the chain."; exit 1 }

# the instance query must run outside a session
if {[catch { set info [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev] } err]} {
	puts "ERROR reading instance info: $err"; exit 1
}
if {[llength $info] == 0} { puts "ERROR: no probes. Is a USE_DBG_PROBES build of MacIIci loaded?"; exit 1 }
array set idx {}
foreach inst $info { set idx([lindex $inst 3]) [lindex $inst 0] }
if {![info exists idx(PINT)]} { puts "ERROR: no PINT probe - this is not the MacIIci probe build (found: [array names idx])"; exit 1 }

proc rd {name} {
	global idx
	set bits [read_probe_data -instance_index $idx($name)]
	if {$bits eq ""} { return 0 }
	return [expr 0b$bits]
}
proc f {v hi lo} { return [expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)}] }

start_insystem_source_probe -hardware_name $hw -device_name $dev
if {$cfg ne ""} {
	write_source_data -instance_index $idx(PCFG) -value_in_hex -value [format %X [expr 0x$cfg & 15]]
	puts "PCFG written: $cfg"
}
if {[info exists idx(PCFG)]} { puts [format "PCFG switches: %X (8 posted writes off, 4 CDIS*, 2 instruction cache off, 1 data cache off)" [rd PCFG]] }
set tag [rd PBLD]
puts [expr {$tag == 0 ? "bitstream=UNSTAMPED" : [format "bitstream=%08x" $tag]}]
set last_act -1
for {set i 0} {$i < $n} {incr i} {
	set pifa [rd PIFA]; set plas [rd PLAS]; set pact [rd PACT]; set psta [rd PSTA]
	set pirq [rd PIRQ]; set preg [rd PREG]; set pint [rd PINT]; set plat [rd PLAT]
	puts [format "PIFA %08x  PLAS %08x  PACT %10u%s" $pifa $plas $pact \
		[expr {$last_act >= 0 ? [format "  (+%u)" [expr {($pact - $last_act) & 0xFFFFFFFF}]] : ""}]]
	set last_act $pact
	puts [format "  PSTA fc %d rw %d dsack* %d%d  berr seen %d (%u)  halted %d  sdram ready %d  rom loaded %d  reset released %d  capture %s (ok A %d B %d)  overlay %d  portrait %d" \
		[f $psta 31 29] [f $psta 28 28] [f $psta 27 27] [f $psta 26 26] [f $psta 25 25] [f $psta 15 0] [f $psta 24 24] \
		[f $psta 23 23] [f $psta 22 22] [f $psta 21 21] [expr {[f $psta 20 20] ? "B" : "A"}] [f $psta 19 19] [f $psta 18 18] \
		[f $psta 17 17] [f $psta 16 16]]
	puts [format "  PIRQ level 1 acks %u  level 2 acks %u     PREG D6 %08x D7 %08x     PLAT late %u" \
		[f $pirq 15 0] [f $pirq 31 16] [f $preg 63 32] [f $preg 31 0] $plat]
	puts [format "  PINT RBV slots %02x  slot IER %02x  IFR %02x  IER %02x | IPL* %d  VIA1 IRQ* %d  RBV IRQ* %d  SCC IRQ* %d | VIA1 IFR %02x IER %02x" \
		[f $pint 63 56] [f $pint 54 48] [f $pint 46 40] [f $pint 38 32] [f $pint 19 17] [f $pint 16 16] [f $pint 15 15] [f $pint 14 14] \
		[f $pint 13 7] [f $pint 6 0]]
	if {[info exists idx(PKRN)]} {
		set k [rd PKRN]; set e [rd PEXC]
		puts [format "  PKRN the kernel is in opcode %04x at PC %08x | PEXC %u exceptions, the last: vector %d (offset $%03x), opcode %04x at PC %08x" 			[f $k 47 32] [f $k 31 0] [f $e 71 56] [f $e 55 48] [expr {[f $e 55 48] * 4}] [f $e 47 32] [f $e 31 0]]
	}
	if {[info exists idx(PWRP)]} {
		set w [rd PWRP]
		puts [format "  PWRP s %d post %d park %d walk %d w_req %d w_ack_s %d ack_pending %d | burst: b_done %d b_adv %d cyc_burst %d b_n %d | kk: s0 %d post %d brst %d walk %d wack %d cyc %d bh %d fs %d pgo_q %d pgo_p %d" 			[f $w 41 39] [f $w 38 38] [f $w 37 37] [f $w 36 36] [f $w 35 35] [f $w 34 34] [f $w 33 33] [f $w 32 32] [f $w 31 31] [f $w 30 30] [f $w 29 28] 			[f $w 27 27] [f $w 26 26] [f $w 25 25] [f $w 24 24] [f $w 23 23] [f $w 22 22] [f $w 21 21] [f $w 20 20] [f $w 19 19] [f $w 18 18]]
		puts [format "       kernel: decode %d busstate %d state %d pmmu_busy %d pmmu_fault %d | kc: take %d anyhit %d bblk %d stallq %d wsel %d int %d force %d | berr_hold %d pb_n %d" 			[f $w 17 17] [f $w 16 15] [f $w 14 13] [f $w 12 12] [f $w 11 11] [f $w 10 10] [f $w 9 9] [f $w 8 8] [f $w 7 7] [f $w 6 6] [f $w 5 5] [f $w 4 4] [f $w 3 3] [f $w 2 0]]
	}
	if {[info exists idx(PMDU)]} {
		set m [rd PMDU]; set s [rd PSDR]; set q [rd PFIF]
		puts [format "  PMDU AS* %d  m_act %d m_done %d  m_wpend %d m_hold %d  held %d blocked %d soon %d | v_pend %d v_hold %d  ref_pend %d ref_run %d | m_got %d m_cnt %d m_due %d | dev active %d done %d  as_hi_c %d" 			[f $m 31 31] [f $m 30 30] [f $m 29 29] [f $m 28 28] [f $m 27 27] [f $m 26 26] [f $m 25 25] [f $m 24 24] [f $m 23 23] [f $m 22 18] [f $m 17 17] [f $m 16 14] 			[f $m 13 11] [f $m 10 7] [f $m 6 3] [f $m 2 2] [f $m 1 1] [f $m 0 0]]
		puts [format "  PSDR state %d (1 idle 2 rd 3 wr 4 vid 5 dl 7 dk)  busy %d busy_z %d  m_pend %d v_pend %d  mq %d vq %d  m_wack %d m_ack %d m_hold %d  mb_in %d mb_out %d  a_n %d rd_cnt %d  ready %d" 			[f $s 31 28] [f $s 27 23] [f $s 22 22] [f $s 21 21] [f $s 20 20] [f $s 19 19] [f $s 18 18] [f $s 17 17] [f $s 16 16] [f $s 15 14] [f $s 13 11] [f $s 10 8] [f $s 7 5] [f $s 4 1] [f $s 0 0]]
		puts [format "  PFIF busy %d hold %d vid_req %d  got %d  held %d longs | VID.3ST %d VID.OFF %d depth %d | dots shown with it empty %d (a 16-bit count)" 			[f $q 15 15] [f $q 14 14] [f $q 13 13] [f $q 12 9] [f $q 8 4] [f $q 3 3] [f $q 2 2] [f $q 1 0] [f $q 31 16]]
	}
	foreach nm {PBE0 PBE1 PBE2} {
		if {[info exists idx($nm)]} {
			set v [rd $nm]
			puts [format "  %s bus error: fc %d rw %d  address %08x  last fetch %08x" $nm [f $v 67 65] [f $v 64 64] [f $v 63 32] [f $v 31 0]]
		}
	}
	if {$i + 1 < $n} { after [expr {int($pause * 1000)}] }
}
end_insystem_source_probe
