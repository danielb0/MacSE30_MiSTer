// build_tag.v -- REGENERATED BEFORE EVERY COMPILE by scripts/stamp_build_tag.ps1.
//
// The COMMITTED value is deliberately 0, meaning "unstamped". Do not commit a
// real SHA here: the file is stamped from HEAD just before a compile, so any
// SHA committed into it necessarily names the PREVIOUS commit. That happened
// on the MacPlus core (the file read ac38fc96 while HEAD was 3426398e), and a
// capture that misnames its own build is worse than no tag at all.
//
// With 0 committed, forgetting to stamp is reported by scripts/read_probes.tcl
// as "bitstream=UNSTAMPED" rather than as a confident, wrong SHA, and a stray
// `git add -A` cannot poison the tag.
//
// Read back on the PBLD probe (rtl/dbg_probes.sv). See SE30_PLAN.md 3.5.
module build_tag(output [31:0] tag);
	assign tag = 32'h00000000;
endmodule
