set StdArithNoWarnings 1
set NumericStdNoWarnings 1
run 492700ns
set P /tb_mmu16/cpu/kernel/PMMU_030
for {set i 0} {$i < 48} {incr i} {
  set t [expr {[lindex [runStatus -full] 0]}]
  echo [format "%s req=%s log=%s fc=%s rw=%s busy=%s fhit=%s fphys=%s preg=%s taddr=%s tfc=%s mask=%s fsv=%s phys=%s bus=%s as=%s" \
    $now [examine $P/req] [examine -radix hex $P/addr_log] [examine $P/fc] [examine $P/rw] [examine $P/busy] [examine $P/fast_hit] \
    [examine -radix hex $P/fast_phys] [examine -radix hex $P/addr_phys_reg] [examine -radix hex $P/translated_addr] [examine $P/translated_fc] \
    [examine -radix hex $P/fs_page_mask] [examine $P/fs_valid] [examine -radix hex $P/addr_phys] [examine -radix hex /tb_mmu16/cpu_addr] [examine /tb_mmu16/cpu_as_n]]
  run 32ns
}
quit -f
