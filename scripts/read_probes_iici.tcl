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
	foreach nm {PBE0 PBE1 PBE2} {
		if {[info exists idx($nm)]} {
			set v [rd $nm]
			puts [format "  %s bus error: fc %d rw %d  address %08x  last fetch %08x" $nm [f $v 67 65] [f $v 64 64] [f $v 63 32] [f $v 31 0]]
		}
	}
	if {$i + 1 < $n} { after [expr {int($pause * 1000)}] }
}
end_insystem_source_probe
