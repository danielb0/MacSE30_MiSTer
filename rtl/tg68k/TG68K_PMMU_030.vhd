-- TG68K_PMMU_030.vhd - MC68030 PMMU (Minimig-AGA_MiSTer 030_mmu2, apolkosnik; LGPL-3)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity TG68K_PMMU_030 is
  port(
    clk            : in  std_logic;
    nreset         : in  std_logic;
    reg_we         : in  std_logic;
    reg_re         : in  std_logic;
    reg_sel        : in  std_logic_vector(4 downto 0);
    reg_wdat       : in  std_logic_vector(31 downto 0);
    reg_rdat       : out std_logic_vector(31 downto 0);
    reg_part       : in  std_logic;
    reg_fd         : in  std_logic;

    ptest_req      : in  std_logic;
    pflush_req     : in  std_logic;
    pload_req      : in  std_logic;
    pmmu_fc        : in  std_logic_vector(2 downto 0);
    pmmu_addr      : in  std_logic_vector(31 downto 0);
    pmmu_brief     : in  std_logic_vector(15 downto 0);
    req            : in  std_logic;
    is_insn        : in  std_logic;
    rw             : in  std_logic;
    rmw            : in  std_logic := '0';
    fc             : in  std_logic_vector(2 downto 0);
    addr_log       : in  std_logic_vector(31 downto 0);
    addr_phys      : out std_logic_vector(31 downto 0);
    cache_inhibit  : out std_logic;
    write_protect  : out std_logic;
    fault          : out std_logic;
    fault_status   : out std_logic_vector(31 downto 0);
    fault_addr     : out std_logic_vector(31 downto 0);
    fault_fc       : out std_logic_vector(2 downto 0);
    fault_rw       : out std_logic;
    fault_is_insn  : out std_logic;
    tc_enable      : out std_logic;
    mem_req        : buffer std_logic;
    mem_we         : out std_logic;
    mem_addr       : out std_logic_vector(31 downto 0);
    mem_wdat       : out std_logic_vector(31 downto 0);
    mem_ack        : in  std_logic;
    mem_berr       : in  std_logic;
    mem_rdat       : in  std_logic_vector(31 downto 0);
    busy           : out std_logic;
    mmu_config_err : out std_logic;
    mmu_config_ack : in  std_logic;
    ptest_desc_addr : out std_logic_vector(31 downto 0);
    debug_mmusr : out std_logic_vector(15 downto 0);
    debug_tc  : out std_logic_vector(31 downto 0);
    debug_tt0 : out std_logic_vector(31 downto 0);
    debug_tt1 : out std_logic_vector(31 downto 0);
    debug_crp_hi : out std_logic_vector(31 downto 0);
    debug_crp_lo : out std_logic_vector(31 downto 0);
    debug_srp_hi : out std_logic_vector(31 downto 0);
    debug_srp_lo : out std_logic_vector(31 downto 0);
    debug_wstate : out std_logic_vector(4 downto 0);
    debug_atc_buserr : out std_logic_vector(21 downto 0);
    debug_atc_valid  : out std_logic_vector(21 downto 0);
    debug_fault_status : out std_logic_vector(15 downto 0);
    debug_saved_addr   : out std_logic_vector(31 downto 0);
    debug_walk_desc_addr : out std_logic_vector(31 downto 0);
    debug_walk_desc_data : out std_logic_vector(31 downto 0);
    debug_ptr1_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr1_desc_data : out std_logic_vector(31 downto 0);
    debug_ptr2_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr2_desc_data : out std_logic_vector(31 downto 0);
    debug_ptr3_desc_addr : out std_logic_vector(31 downto 0);
    debug_ptr3_desc_data : out std_logic_vector(31 downto 0);
    debug_saved_fc       : out std_logic_vector(2 downto 0);
    debug_pending_flags  : out std_logic_vector(15 downto 0);
    debug_illegal_reg_sel : out std_logic;
    mmudis              : in  std_logic := '0';
    cpu_reset           : in  std_logic := '0'
  );
end TG68K_PMMU_030;
architecture rtl of TG68K_PMMU_030 is
  function slv_to_hex(value : std_logic_vector) return string is
    constant hex_chars : string := "0123456789ABCDEF";
    variable result : string(1 to value'length/4);
    variable nibble : std_logic_vector(3 downto 0);
  begin
    for i in 0 to (value'length/4 - 1) loop
      nibble := value(value'length - 1 - i*4 downto value'length - 4 - i*4);
      result(i+1) := hex_chars(to_integer(unsigned(nibble)) + 1);
    end loop;
    return result;
  end function;

  signal TC     : std_logic_vector(31 downto 0);
  signal CRP_H  : std_logic_vector(31 downto 0);
  signal CRP_L  : std_logic_vector(31 downto 0);
  signal SRP_H  : std_logic_vector(31 downto 0);
  signal SRP_L  : std_logic_vector(31 downto 0);
  signal CRP_H_stage       : std_logic_vector(31 downto 0) := (others => '0');
  signal SRP_H_stage       : std_logic_vector(31 downto 0) := (others => '0');
  signal CRP_H_stage_valid : std_logic := '0';
  signal SRP_H_stage_valid : std_logic := '0';
  signal CRP_FD_stage      : std_logic := '0';
  signal SRP_FD_stage      : std_logic := '0';
  signal TT0    : std_logic_vector(31 downto 0);
  signal TT1    : std_logic_vector(31 downto 0);
  signal MMUSR  : std_logic_vector(15 downto 0);
  signal tc_en  : std_logic;
  signal tc_table_config_valid : std_logic;
  signal desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_desc_return_pending : std_logic := '0';
  signal last_mem_rdat : std_logic_vector(31 downto 0) := (others => '0');
  constant TC_WRITE_MASK : std_logic_vector(31 downto 0) := "10000011111111111111111111111111";
  constant TTR_WRITE_MASK : std_logic_vector(31 downto 0) := (others => '1');
  constant CRP_HIGH_MASK : std_logic_vector(31 downto 0) := "11111111111111110000000000000011";
  constant CRP_LOW_MASK : std_logic_vector(31 downto 0) := "11111111111111111111111111110000";

  signal ttr0_match_comb : std_logic;
  signal ttr1_match_comb : std_logic;
  signal ttr0_ci_comb    : std_logic;
  signal ttr0_wp_comb    : std_logic;
  signal ttr1_ci_comb    : std_logic;
  signal ttr1_wp_comb    : std_logic;
  signal translated_addr    : std_logic_vector(31 downto 0) := (others => '0');
  signal translated_fc      : std_logic_vector(2 downto 0) := (others => '0');
  signal translated_rw      : std_logic := '1';
  signal xlat_cfg_seq       : unsigned(7 downto 0) := (others => '0');
  signal translated_cfg_seq : unsigned(7 downto 0) := (others => '0');
  signal xlat_cfg_seq_seen  : unsigned(7 downto 0) := (others => '0');
  signal xlat_cfg_seq_walk_seen : unsigned(7 downto 0) := (others => '0');
  signal addr_phys_reg      : std_logic_vector(31 downto 0) := (others => '0');
  signal cache_inhibit_reg  : std_logic := '0';
  signal write_protect_reg  : std_logic := '0';
  signal fault_reg          : std_logic := '0';
  signal fault_status_reg   : std_logic_vector(31 downto 0) := (others => '0');
  signal fault_addr_reg     : std_logic_vector(31 downto 0) := (others => '0');
  signal fault_fc_reg       : std_logic_vector(2 downto 0) := (others => '0');
  signal fault_rw_reg       : std_logic := '1';
  signal fault_is_insn_reg  : std_logic := '0';
  signal fault_current_req_match : std_logic := '0';

  signal debug_fault_status_latch : std_logic_vector(15 downto 0) := (others => '0');
  signal debug_fault_status_valid : std_logic := '0';
  signal debug_timeout_seen     : std_logic := '0';
  signal debug_timeout_mem_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal debug_timeout_mem_wdat : std_logic_vector(31 downto 0) := (others => '0');
  signal debug_timeout_mem_we   : std_logic := '0';
  signal debug_timeout_wstate   : std_logic_vector(4 downto 0) := (others => '0');
  signal debug_timeout_count    : std_logic_vector(15 downto 0) := (others => '0');

  signal walker_fault       : std_logic := '0';
  signal walker_fault_status : std_logic_vector(31 downto 0) := (others => '0');
  signal walker_fault_ack   : std_logic := '0';
  signal walker_fault_ack_pending : std_logic := '0';

  signal walker_completed_ack : std_logic := '0';

  signal saved_addr_log     : std_logic_vector(31 downto 0) := (others => '0');
  signal saved_fc           : std_logic_vector(2 downto 0) := (others => '0');
  signal saved_is_insn      : std_logic := '0';
  signal saved_rw           : std_logic := '0';
  signal req_prev           : std_logic := '0';
  signal translation_pending : std_logic := '0';
  constant ATC_ENTRIES : integer := 22;
  type atc_attr_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(3 downto 0);
  type atc_val_t  is array(0 to ATC_ENTRIES-1) of std_logic;
  type atc_base_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(31 downto 0);
  type atc_fc_t   is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);
  type atc_shift_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 32;
  type atc_page_size_t is array(0 to ATC_ENTRIES-1) of integer range 0 to 15;
  type atc_level_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(2 downto 0);
  type atc_fault_status_t is array(0 to ATC_ENTRIES-1) of std_logic_vector(15 downto 0);
  signal atc_log_base : atc_base_t;
  signal atc_phys_base: atc_base_t;
  signal atc_attr  : atc_attr_t;
  signal atc_valid : atc_val_t;
  signal atc_fc    : atc_fc_t;
  signal atc_shift : atc_shift_t;
  signal atc_page_size : atc_page_size_t;
  signal atc_level : atc_level_t;
  signal atc_mru   : atc_val_t;
  signal atc_buserr : atc_val_t;
  signal atc_fault_status : atc_fault_status_t;
  signal atc_mru_update_req : std_logic := '0';
  signal atc_mru_update_idx : integer range 0 to ATC_ENTRIES-1 := 0;
  signal atc_mbit_inval_req : std_logic := '0';
  signal atc_mbit_inval_idx : integer range 0 to ATC_ENTRIES-1 := 0;
  signal fast_hit  : std_logic;
  signal fast_phys : std_logic_vector(31 downto 0);
  signal fast_ci   : std_logic;
  signal fast_wp   : std_logic;
  constant FAST_ENTRIES : integer := 4;
  type fs_addr_t is array(0 to FAST_ENTRIES-1) of std_logic_vector(31 downto 0);
  type fs_fc_t   is array(0 to FAST_ENTRIES-1) of std_logic_vector(2 downto 0);
  type fs_bit_t  is array(0 to FAST_ENTRIES-1) of std_logic;
  signal fs_valid     : fs_bit_t := (others => '0');
  signal fs_mru       : fs_bit_t := (others => '0');
  signal fs_fc        : fs_fc_t  := (others => (others => '0'));
  signal fs_log       : fs_addr_t := (others => (others => '0'));
  signal fs_phys      : fs_addr_t := (others => (others => '0'));
  signal fs_ci        : fs_bit_t := (others => '0');
  signal fs_wp        : fs_bit_t := (others => '0');
  signal fs_wr_ok     : fs_bit_t := (others => '0');
  signal fs_user_ok   : fs_bit_t := (others => '0');
  signal fs_page_mask : std_logic_vector(31 downto 0) := x"FFFFF000";
  signal fs_cfg_seq   : unsigned(7 downto 0) := (others => '0');
  signal translated_match_dbg : std_logic;
  signal walk_req  : std_logic;
  signal walker_completed : std_logic := '0';
  type tc_bits_array_t is array(0 to 3) of integer range 0 to 16;
  constant DEFAULT_TC_BITS : tc_bits_array_t := (8, 8, 4, 0);
  constant DEFAULT_TC_IS   : integer := 0;
  signal tc_idx_bits      : tc_bits_array_t := DEFAULT_TC_BITS;
  signal tc_initial_shift : integer range 0 to 15 := DEFAULT_TC_IS;
  signal tc_page_size     : integer range 0 to 15 := 12;
  signal tc_page_shift    : integer range 8 to 15 := 12;
  signal tc_sre           : std_logic := '0';
  signal tc_fcl           : std_logic := '0';
  signal mmusr_update_req   : std_logic := '0';
  signal mmusr_update_ack   : std_logic := '0';
  signal mmusr_update_value : std_logic_vector(31 downto 0) := (others => '0');
  signal mmu_config_error   : std_logic := '0';
  signal tc_config_check_pending : std_logic := '0';
  signal tc_config_check_value   : std_logic_vector(31 downto 0) := (others => '0');
  signal tc_config_valid         : std_logic := '1';
  signal pmmu_illegal_reg_sel_seen : std_logic := '0';
  type walk_state_t is (W_IDLE, W_ROOT, W_ROOT_LOW, W_PTR1, W_PTR1_LOW, W_PTR2, W_PTR2_LOW, W_PTR3, W_PTR3_LOW, W_PTR4, W_PTR4_LOW, W_INDIRECT, W_INDIRECT_LOW, W_PAGE, W_TABLE_UPDATE, W_UPDATE_DESC, W_PLOAD_FLUSH, W_FILL, W_COMPLETE, W_FAULT);
  signal wstate    : walk_state_t := W_IDLE;

  signal walk_log_base  : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_phys_base : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_page_shift: integer range 0 to 32 := 12;
  signal walk_page_size : integer range 0 to 15 := 12;

  signal ptest_update_mmusr : std_logic := '0';
  signal pflush_clear_atc   : std_logic := '0';
  signal atc_flush_req      : std_logic := '0';

  signal ptest_req_prev  : std_logic := '0';
  signal pflush_req_prev : std_logic := '0';
  signal pload_req_prev  : std_logic := '0';
  signal reg_we_prev     : std_logic := '0';
  signal reg_re_prev     : std_logic := '0';
  signal ptest_active : std_logic := '0';
  signal ptest_done : std_logic := '0';
  signal ptest_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal ptest_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal ptest_rw : std_logic := '1';
  signal ptest_level : std_logic_vector(2 downto 0) := "000";
  signal instr_walk_pending : std_logic := '0';
  signal ptest_walk_pending : std_logic := '0';
  signal ptest_walk_no_update : std_logic := '0';
  signal pload_active : std_logic := '0';
  signal pload_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pload_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pload_rw : std_logic := '1';
  signal pload_flush_pending : std_logic := '0';
  signal pflush_active : std_logic := '0';
  signal pflush_addr : std_logic_vector(31 downto 0) := (others => '0');
  signal pflush_fc : std_logic_vector(2 downto 0) := (others => '0');
  signal pflush_mode : std_logic_vector(2 downto 0) := (others => '0');
  signal pflush_mask : std_logic_vector(2 downto 0) := (others => '0');

  signal walk_level     : integer range 0 to 5 := 0;
  signal walk_desc      : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_desc_high : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_desc_low  : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr1_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr1_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr2_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr2_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr3_desc_addr_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal ptr3_desc_data_reg : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_desc_is_long : std_logic := '0';
  signal walk_page_from_indirect : std_logic := '0';
  signal walk_parent_dt_long : std_logic := '0';
  signal walker_timeout_counter : integer range 0 to 1023 := 0;
  constant WALKER_TIMEOUT_CYCLES : integer := 500;
  signal walk_addr      : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_vpn       : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_fault     : std_logic := '0';
  signal walk_attr      : std_logic_vector(7 downto 0) := (others => '0');
  signal walk_supervisor : std_logic := '0';
  signal walk_write_protect : std_logic := '0';
  signal walk_is_root_pointer : std_logic := '0';
  signal indirect_addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal indirect_target_long : std_logic := '0';
  signal walk_limit_valid : std_logic := '0';
  signal walk_limit_lu    : std_logic := '0';
  signal walk_limit_value : unsigned(14 downto 0) := (others => '0');
  signal desc_update_needed : std_logic := '0';
  signal desc_update_data   : std_logic_vector(31 downto 0) := (others => '0');
  signal walk_next_state    : walk_state_t := W_IDLE;
  function decode_tc_field(field : std_logic_vector(3 downto 0);
                           default_val : integer) return integer is
    variable tmp : integer;
  begin
    tmp := to_integer(unsigned(field));
    if tmp = 0 then
      return default_val;
    else
      return tmp;
    end if;
  end function;
  function align_addr(addr : std_logic_vector(31 downto 0);
                      shift : integer) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0) := addr;
    variable mask : std_logic_vector(31 downto 0) := (others => '1');
  begin
    if shift <= 0 then
      return addr;
    end if;
    if shift >= 32 then
      return x"00000000";
    end if;

    mask := std_logic_vector(shift_left(unsigned(mask), shift));
    result := addr and mask;

    return result;
  end function;
  function get_page_offset_bits(ps_field : integer) return integer is
  begin
    if ps_field >= 8 and ps_field <= 15 then
      return ps_field;
    else
      return 12;
    end if;
  end function;
  function page_shift_from_tc(ps : integer) return integer is
  begin
    return get_page_offset_bits(ps);
  end function;
  function phys_base_from_desc(desc : std_logic_vector(31 downto 0);
                               shift : integer) return std_logic_vector is
    variable base : std_logic_vector(31 downto 0);
  begin
    base(31 downto 8) := desc(31 downto 8);
    base(7 downto 0)  := (others => '0');
    return align_addr(base, shift);
  end function;
  procedure ttr_check(
      tt        : in  std_logic_vector(31 downto 0);
      addr      : in  std_logic_vector(31 downto 0);
      fc        : in  std_logic_vector(2 downto 0);
      is_insn   : in  std_logic;
      rw        : in  std_logic;
      rmw       : in  std_logic;
      matched   : out std_logic;
      ci        : out std_logic;
      wp        : out std_logic) is
    variable enable     : std_logic;
    variable base       : std_logic_vector(7 downto 0);
    variable mask       : std_logic_vector(7 downto 0);
    variable addr_hi    : std_logic_vector(7 downto 0);
    variable fc_base    : std_logic_vector(2 downto 0);
    variable fc_mask    : std_logic_vector(2 downto 0);
    variable addr_match : std_logic;
    variable fc_match   : std_logic;
  begin
    enable     := tt(15);
    base       := tt(31 downto 24);
    mask       := tt(23 downto 16);
    fc_base    := tt(6 downto 4);
    fc_mask    := tt(2 downto 0);
    addr_hi    := addr(31 downto 24);
    if enable = '0' then
      matched := '0';
      ci := '0';
      wp := '0';
      return;
    end if;
    if ((addr_hi XOR base) AND (NOT mask)) = x"00" then
      addr_match := '1';
    else
      addr_match := '0';
    end if;
    if ((fc XOR fc_base) AND (NOT fc_mask)) = "000" then
      fc_match := '1';
    else
      fc_match := '0';
    end if;
    if enable = '1' AND addr_match = '1' AND fc_match = '1' then
      matched := '1';
      if tt(10) = '1' then
        ci := '1';
      else
        ci := '0';
      end if;
      if rmw = '1' and tt(8) = '0' then
        matched := '0';
        ci := '0';
        wp := '0';
      elsif tt(8) = '0' then
        if tt(9) = '1' and rw = '0' then
          matched := '0';
          ci := '0';
          wp := '0';
        elsif tt(9) = '0' and rw = '1' then
          matched := '0';
          ci := '0';
          wp := '0';
        else
          wp := '0';
        end if;
      else
        wp := '0';
      end if;
    else
      matched := '0';
      ci := '0';
      wp := '0';
    end if;
  end procedure;
  procedure ttr_match(
      tt      : in  std_logic_vector(31 downto 0);
      addr    : in  std_logic_vector(31 downto 0);
      fc      : in  std_logic_vector(2 downto 0);
      is_insn : in  std_logic;
      matched : out std_logic) is
    variable dummy_ci : std_logic;
    variable dummy_wp : std_logic;
  begin
    ttr_check(tt, addr, fc, is_insn, '1', '0', matched, dummy_ci, dummy_wp);
  end procedure;

  function get_table_index(addr : std_logic_vector(31 downto 0);
                          level : integer;
                          initial_shift : integer;
                          page_size : integer;
                          idx_bits : tc_bits_array_t) return integer is
    variable result : integer;
    variable shift_amount : integer;
    variable mask_width : integer;
    variable temp_addr : unsigned(31 downto 0);
    variable addr_mask : unsigned(31 downto 0);
    variable remaining_bits : integer;
  begin
    if level < 0 or level > 3 then
      return 0;
    end if;
    mask_width := idx_bits(level);
    if mask_width <= 0 then
      return 0;
    end if;
    remaining_bits := page_size;
    if level < 1 then remaining_bits := remaining_bits + idx_bits(1); end if;
    if level < 2 then remaining_bits := remaining_bits + idx_bits(2); end if;
    if level < 3 then remaining_bits := remaining_bits + idx_bits(3); end if;
    shift_amount := remaining_bits;
    if shift_amount < 0 or shift_amount >= 32 then
      return 0;
    end if;
    temp_addr := unsigned(addr);
    if initial_shift > 0 then
      addr_mask := shift_right(not to_unsigned(0, 32), initial_shift);
      temp_addr := temp_addr AND addr_mask;
    end if;
    temp_addr := shift_right(temp_addr, shift_amount);
    result := to_integer(temp_addr AND to_unsigned((2**mask_width) - 1, 32));
    return result;
  end function;
  function fcl_search_addr(addr : std_logic_vector(31 downto 0);
                           fc   : std_logic_vector(2 downto 0);
                           fcl  : std_logic) return std_logic_vector is
  begin
    return addr;
  end function;
  function get_fcl_table_index(addr : std_logic_vector(31 downto 0);
                               fc   : std_logic_vector(2 downto 0);
                               fcl  : std_logic;
                               level : integer;
                               initial_shift : integer;
                               page_size : integer;
                               idx_bits : tc_bits_array_t) return integer is
  begin
    if fcl = '1' then
      if level = 0 then
        return to_integer(unsigned(fc));
      else
        return get_table_index(addr, level - 1, initial_shift, page_size, idx_bits);
      end if;
    else
      return get_table_index(addr, level, initial_shift, page_size, idx_bits);
    end if;
  end function;
  function is_final_table_level(fcl : std_logic; level : integer; idx_bits : tc_bits_array_t) return boolean is
    variable check_idx : integer;
  begin
    if fcl = '1' then
      check_idx := level;
    else
      check_idx := level + 1;
    end if;
    if check_idx > 3 then
      return true;
    else
      return idx_bits(check_idx) = 0;
    end if;
  end function;
  function early_term_limit_applies(
    is_root_pointer : std_logic;
    fcl             : std_logic;
    level           : integer;
    idx_bits        : tc_bits_array_t
  ) return boolean is
  begin
    if is_root_pointer = '1' then
      if fcl = '1' then
        return false;
      end if;
      return idx_bits(0) /= 0;
    end if;
    return not is_final_table_level(fcl, level, idx_bits);
  end function;
  function early_term_limit_level(
    is_root_pointer : std_logic;
    level           : integer
  ) return integer is
  begin
    if is_root_pointer = '1' then
      return 0;
    end if;
    return level + 1;
  end function;
  function desc_is_page(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "01";
  end function;
  function desc_is_table(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "10" OR desc(1 downto 0) = "11";
  end function;
  function desc_valid(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) /= "00";
  end function;
  function desc_is_long(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "11";
  end function;
  function tc_total_bits(tc : std_logic_vector(31 downto 0)) return integer is
    variable ps_val : integer;
    variable is_val : integer;
    variable tia_val, tib_val, tic_val, tid_val : integer;
    variable total_bits : integer;
  begin
    ps_val := to_integer(unsigned(tc(23 downto 20)));
    is_val := to_integer(unsigned(tc(19 downto 16)));
    if is_val = 0 then
      is_val := DEFAULT_TC_IS;
    end if;
    tia_val := to_integer(unsigned(tc(15 downto 12)));
    tib_val := to_integer(unsigned(tc(11 downto 8)));
    tic_val := to_integer(unsigned(tc(7 downto 4)));
    tid_val := to_integer(unsigned(tc(3 downto 0)));
    total_bits := get_page_offset_bits(ps_val) + is_val;
    if tia_val /= 0 then
      total_bits := total_bits + tia_val;
      if tib_val /= 0 then
        total_bits := total_bits + tib_val;
        if tic_val /= 0 then
          total_bits := total_bits + tic_val;
          if tid_val /= 0 then
            total_bits := total_bits + tid_val;
          end if;
        end if;
      end if;
    end if;
    return total_bits;
  end function;
  function tc_config_invalid(tc : std_logic_vector(31 downto 0)) return boolean is
    variable ps_val : integer;
  begin
    if tc(31) = '0' then
      return false;
    end if;
    ps_val := to_integer(unsigned(tc(23 downto 20)));
    if ps_val < 8 then
      return true;
    end if;
    if tc_total_bits(tc) /= 32 then
      return true;
    end if;
    return false;
  end function;
  function desc_is_short(desc : std_logic_vector(31 downto 0)) return boolean is
  begin
    return desc(1 downto 0) = "10";
  end function;
  function get_supervisor_bit(desc_high : std_logic_vector(31 downto 0);
                              is_long : std_logic) return std_logic is
  begin
    if is_long = '1' then
      return desc_high(8);
    else
      return '0';
    end if;
  end function;
  function get_desc_address(desc_high : std_logic_vector(31 downto 0);
                            desc_low  : std_logic_vector(31 downto 0);
                            is_long   : std_logic) return std_logic_vector is
  begin
    if is_long = '1' then
      return desc_low(31 downto 4) & "0000";
    else
      return desc_high(31 downto 4) & "0000";
    end if;
  end function;
  function access_allowed(desc_high : std_logic_vector(31 downto 0);
                         fc : std_logic_vector(2 downto 0);
                         is_long : std_logic) return boolean is
    variable is_supervisor_fc : boolean;
    variable s_bit : std_logic;
  begin
    is_supervisor_fc := (fc(2) = '1');
    s_bit := get_supervisor_bit(desc_high, is_long);
    if is_supervisor_fc then
      return true;
    else
      return (s_bit = '0');
    end if;
  end function;

  function encode_mmusr_fault(
    bus_error : std_logic;
    limit_violation : std_logic;
    supervisor_violation : std_logic;
    write_protect : std_logic;
    invalid : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    result(15) := bus_error;
    result(14) := limit_violation;
    result(13) := supervisor_violation;
    result(11) := write_protect;
    result(10) := invalid;
    result(9) := modified;
    result(6) := transparent;
    result(2 downto 0) := level;
    return result;
  end function;

  function encode_mmusr_success(
    write_protect : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    result(11) := write_protect;
    result(10) := '0';
    result(9) := modified;
    result(6) := transparent;
    result(2 downto 0) := level;
    return result;
  end function;
  function encode_mmusr_ptest(
    supervisor_violation : std_logic;
    write_protect : std_logic;
    modified : std_logic;
    transparent : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable result : std_logic_vector(31 downto 0);
  begin
    result := (others => '0');
    result(13) := supervisor_violation;
    result(11) := write_protect;
    result(9)  := modified;
    result(6)  := transparent;
    result(2 downto 0) := level;
    return result;
  end function;
  function encode_ptest_table_status(
    fc : std_logic_vector(2 downto 0);
    accum_supervisor : std_logic;
    current_supervisor : std_logic;
    accum_write_protect : std_logic;
    current_write_protect : std_logic;
    level : std_logic_vector(2 downto 0)
  ) return std_logic_vector is
    variable supervisor_violation : std_logic := '0';
  begin
    if fc(2) = '0' and (accum_supervisor = '1' or current_supervisor = '1') then
      supervisor_violation := '1';
    end if;
    return encode_mmusr_ptest(
      supervisor_violation => supervisor_violation,
      write_protect => accum_write_protect or current_write_protect,
      modified => '0',
      transparent => '0',
      level => level
    );
  end function;
  function page_descriptor_count(
    level : integer;
    from_indirect : std_logic;
    root_pointer : std_logic
  ) return std_logic_vector is
    variable count : integer;
  begin
    if root_pointer = '1' then
      count := 0;
    else
      count := level + 1;
      if from_indirect = '1' then
        count := count + 1;
      end if;
    end if;
    return std_logic_vector(to_unsigned(count, 3));
  end function;
  function calc_effective_page_shift(
    base_page_shift : integer;
    level : integer;
    idx_bits : tc_bits_array_t;
    fcl : std_logic;
    is_root_pointer : std_logic := '0'
  ) return integer is
    variable result : integer;
  begin
    result := base_page_shift;
    if is_root_pointer = '1' then
      result := result + idx_bits(0) + idx_bits(1) + idx_bits(2) + idx_bits(3);
      return result;
    end if;
    if fcl = '1' then
      if level <= 3 then
        result := result + idx_bits(3);
      end if;
      if level <= 2 then
        result := result + idx_bits(2);
      end if;
      if level <= 1 then
        result := result + idx_bits(1);
      end if;
      if level = 0 then
        result := result + idx_bits(0);
      end if;
    else
      if level <= 2 then
        result := result + idx_bits(3);
      end if;
      if level <= 1 then
        result := result + idx_bits(2);
      end if;
      if level = 0 then
        result := result + idx_bits(1);
      end if;
    end if;
    return result;
  end function;
begin
  ptest_desc_addr <= ptest_desc_addr_reg;
  process(TT0, TT1, addr_log, fc, is_insn, rw, rmw)
    variable m0, m1 : std_logic;
    variable ci0, wp0, ci1, wp1 : std_logic;
  begin
    m0 := '0'; m1 := '0';
    ci0 := '0'; wp0 := '0';
    ci1 := '0'; wp1 := '0';
    ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, m0, ci0, wp0);
    ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, m1, ci1, wp1);
    ttr0_match_comb <= m0;
    ttr1_match_comb <= m1;
    ttr0_ci_comb <= ci0;
    ttr0_wp_comb <= wp0;
    ttr1_ci_comb <= ci1;
    ttr1_wp_comb <= wp1;
  end process;
  process(clk, nreset)
    variable tc_e : std_logic;
    variable tc_write_val : std_logic_vector(31 downto 0);
    variable ps_val : integer;
    variable is_val : integer;
    variable tia_val, tib_val, tic_val, tid_val : integer;
    variable total_bits : integer;
    variable page_offset_bits : integer;
  begin
    if nreset = '0' then
      TC    <= (others => '0');
      CRP_H <= (others => '0');
      CRP_L <= (others => '0');
      SRP_H <= (others => '0');
      SRP_L <= (others => '0');
      CRP_H_stage <= (others => '0');
      SRP_H_stage <= (others => '0');
      CRP_H_stage_valid <= '0';
      SRP_H_stage_valid <= '0';
      CRP_FD_stage <= '0';
      SRP_FD_stage <= '0';
      TT0   <= (others => '0');
      TT1   <= (others => '0');
      MMUSR <= (others => '0');
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      ptest_active <= '0';
      xlat_cfg_seq <= (others => '0');
      mmu_config_error <= '0';
      tc_config_check_pending <= '0';
      tc_config_check_value <= (others => '0');
      tc_config_valid <= '1';
      pmmu_illegal_reg_sel_seen <= '0';
    elsif rising_edge(clk) then
      atc_flush_req <= '0';
      mmusr_update_ack <= '0';
      if pflush_clear_atc = '1' and wstate = W_IDLE then
        xlat_cfg_seq <= xlat_cfg_seq + 1;
      end if;
      if mmu_config_ack = '1' then
        mmu_config_error <= '0';
      end if;
      if tc_config_check_pending = '1' then
        tc_config_check_pending <= '0';
        tc_e := tc_config_check_value(31);
        ps_val := to_integer(unsigned(tc_config_check_value(23 downto 20)));
        if tc_e = '0' then
          tc_config_valid <= '1';
        elsif ps_val < 8 then
          tc_config_valid <= '1';
          mmu_config_error <= '1';
          TC(31) <= '0';
          report "MMU_CONFIG: Invalid PS field=" & integer'image(ps_val) &
                 " (must be 8-15), raising configuration exception" severity warning;
        else
          total_bits := tc_total_bits(tc_config_check_value);
          if total_bits /= 32 then
            tc_config_valid <= '1';
            mmu_config_error <= '1';
            TC(31) <= '0';
            report "MMU_CONFIG: Field sum=" & integer'image(total_bits) &
                   " (must be 32), raising configuration exception" severity warning;
          else
            tc_config_valid <= '1';
          end if;
        end if;
      end if;
      if cpu_reset = '1' then
        TC(31) <= '0';
        tc_config_valid <= '1';
        TT0(15) <= '0';
        TT1(15) <= '0';
        ptest_active <= '0';
        CRP_H_stage_valid <= '0';
        SRP_H_stage_valid <= '0';
        xlat_cfg_seq <= xlat_cfg_seq + 1;
      elsif ptest_update_mmusr = '1' then
        ptest_active <= '1';
        null;
      elsif mmusr_update_req = '1' then
        MMUSR <= mmusr_update_value(15 downto 0);
        mmusr_update_ack <= '1';
      end if;
      if ptest_done = '1' then
        ptest_active <= '0';
      end if;
      if reg_we = '1' then
        if reg_sel = "00010" or reg_sel = "00011" or reg_sel = "10000" then
          xlat_cfg_seq <= xlat_cfg_seq + 1;
        end if;
        if reg_sel /= "10011" then
          CRP_H_stage_valid <= '0';
        end if;
        if reg_sel /= "10010" then
          SRP_H_stage_valid <= '0';
        end if;
        report "PMMU_REG_WRITE: sel=" & integer'image(to_integer(unsigned(reg_sel))) &
               " wdat_hi=" & integer'image(to_integer(unsigned(reg_wdat(31 downto 16)))) &
               " wdat_lo=" & integer'image(to_integer(unsigned(reg_wdat(15 downto 0)))) &
               " part=" & std_logic'image(reg_part);
        case reg_sel is
          when "00010" =>
            TT0 <= reg_wdat and TTR_WRITE_MASK;
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "00011" =>
            TT1 <= reg_wdat and TTR_WRITE_MASK;
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10000" =>
            tc_write_val := reg_wdat and TC_WRITE_MASK;
            tc_config_check_value <= tc_write_val;
            tc_config_check_pending <= '1';
            tc_config_valid <= not tc_write_val(31);
            TC <= tc_write_val;
            report "BUG387_TC_WRITE: tc_val=0x" &
                   integer'image(to_integer(unsigned(tc_write_val(31 downto 16)))) & "_" &
                   integer'image(to_integer(unsigned(tc_write_val(15 downto 0)))) severity note;
            if reg_fd = '0' then
              atc_flush_req <= '1';
            end if;
          when "10010" =>
            if reg_part = '1' then
              report "PMMU_REG_WRITE: SRP_H reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              SRP_H_stage <= reg_wdat and CRP_HIGH_MASK;
              SRP_H_stage_valid <= '1';
              SRP_FD_stage <= reg_fd;
            else
              report "PMMU_REG_WRITE: SRP_L reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              if SRP_H_stage_valid = '1' then
                SRP_H <= SRP_H_stage;
                SRP_L <= reg_wdat and CRP_LOW_MASK;
                if SRP_H_stage(1 downto 0) = "00" then
                  mmu_config_error <= '1';
                  report "MMU_CONFIG: SRP_H DT=00 (invalid descriptor type)" severity warning;
                end if;
                if SRP_FD_stage = '0' then
                  atc_flush_req <= '1';
                end if;
                xlat_cfg_seq <= xlat_cfg_seq + 1;
              end if;
              SRP_H_stage_valid <= '0';
            end if;
          when "10011" =>
            if reg_part = '1' then
              report "PMMU_REG_WRITE: CRP_H reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              CRP_H_stage <= reg_wdat and CRP_HIGH_MASK;
              CRP_H_stage_valid <= '1';
              CRP_FD_stage <= reg_fd;
            else
              report "PMMU_REG_WRITE: CRP_L reg_part=" & std_logic'image(reg_part) &
                     " reg_wdat=" & integer'image(to_integer(signed(reg_wdat))) severity note;
              if CRP_H_stage_valid = '1' then
                CRP_H <= CRP_H_stage;
                CRP_L <= reg_wdat and CRP_LOW_MASK;
                if CRP_H_stage(1 downto 0) = "00" then
                  mmu_config_error <= '1';
                  report "MMU_CONFIG: CRP_H DT=00 (invalid descriptor type)" severity warning;
                end if;
                if CRP_FD_stage = '0' then
                  atc_flush_req <= '1';
                end if;
                xlat_cfg_seq <= xlat_cfg_seq + 1;
              end if;
              CRP_H_stage_valid <= '0';
            end if;
          when "11000" =>
            MMUSR <= reg_wdat(15 downto 0) and x"EE47";
          when others =>
            assert false
              report "PMMU: illegal PMOVE reg_sel = " &
                     integer'image(to_integer(unsigned(reg_sel))) &
                     " on write (reg_wdat=0x" & slv_to_hex(reg_wdat) & ")"
              severity error;
            pmmu_illegal_reg_sel_seen <= '1';
          end case;
      end if;
      if reg_re = '1' then
        case reg_sel is
          when "00010" | "00011" | "10000" | "10010" | "10011" | "11000" =>
            null;
          when others =>
            pmmu_illegal_reg_sel_seen <= '1';
        end case;
      end if;
    end if;
  end process;
  reg_rdat <= TT0                          when reg_sel = "00010" else
              TT1                          when reg_sel = "00011" else
              TC                           when reg_sel = "10000" else
              SRP_H                        when reg_sel = "10010" and reg_part = '1' else
              SRP_L                        when reg_sel = "10010" and reg_part = '0' else
              CRP_H                        when reg_sel = "10011" and reg_part = '1' else
              CRP_L                        when reg_sel = "10011" and reg_part = '0' else
              X"0000" & MMUSR when reg_sel = "11000" else
              (others => '0');
  debug_mmusr <= MMUSR;
  debug_illegal_reg_sel <= pmmu_illegal_reg_sel_seen;

  process(clk)
  begin
    if rising_edge(clk) then
      if reg_re = '1' then
        case reg_sel is
          when "00010" | "00011" | "10000" | "10010" | "10011" | "11000" =>
            null;
          when others =>
            assert false
              report "PMMU: illegal PMOVE reg_sel = " &
                     integer'image(to_integer(unsigned(reg_sel))) &
                     " on read"
              severity error;
        end case;
      end if;
    end if;
  end process;
  debug_tc  <= TC;
  debug_tt0 <= TT0;
  debug_tt1 <= TT1;
  debug_crp_hi <= CRP_H;
  debug_crp_lo <= CRP_L;
  debug_srp_hi <= SRP_H;
  debug_srp_lo <= SRP_L;
  debug_wstate <= std_logic_vector(to_unsigned(walk_state_t'pos(wstate), 5));
  debug_walk_desc_addr <= desc_addr_reg;
  debug_walk_desc_data <= last_mem_rdat;
  gen_atc_debug: for i in 0 to ATC_ENTRIES-1 generate
    debug_atc_buserr(i) <= atc_buserr(i);
    debug_atc_valid(i)  <= atc_valid(i);
  end generate;
  debug_fault_status <= debug_fault_status_latch;
  debug_saved_addr   <= saved_addr_log;
  debug_saved_fc     <= saved_fc;
  debug_ptr1_desc_addr <= ptr1_desc_addr_reg;
  debug_ptr1_desc_data <= ptr1_desc_data_reg;
  debug_ptr2_desc_addr <= debug_timeout_mem_addr when debug_timeout_seen = '1' else ptr2_desc_addr_reg;
  debug_ptr2_desc_data <= debug_timeout_mem_wdat when debug_timeout_seen = '1' else ptr2_desc_data_reg;
  debug_ptr3_desc_addr <= x"544F" & debug_timeout_count when debug_timeout_seen = '1' else ptr3_desc_addr_reg;
  debug_ptr3_desc_data <= x"54494D" & "00" & debug_timeout_wstate & debug_timeout_mem_we
                          when debug_timeout_seen = '1' else ptr3_desc_data_reg;
  tc_en <= '1' when TC(31) = '1' and mmu_config_error = '0' and tc_config_valid = '1' else '0';
  tc_table_config_valid <= '1' when mmu_config_error = '0' and tc_config_valid = '1' else '0';
  tc_sre <= TC(25);
  tc_fcl <= TC(24);
  tc_enable <= tc_en;

  process(TC)
    variable ps_val : integer;
    variable total_bits : integer;
    variable is_bits : integer;
    variable page_offset_bits : integer;
    variable tia_bits, tib_bits, tic_bits, tid_bits : integer;
  begin
    tia_bits := to_integer(unsigned(TC(15 downto 12)));
    tib_bits := to_integer(unsigned(TC(11 downto 8)));
    tic_bits := to_integer(unsigned(TC(7 downto 4)));
    tid_bits := to_integer(unsigned(TC(3 downto 0)));
    if tia_bits = 0 then
      tib_bits := 0;
      tic_bits := 0;
      tid_bits := 0;
    elsif tib_bits = 0 then
      tic_bits := 0;
      tid_bits := 0;
    elsif tic_bits = 0 then
      tid_bits := 0;
    end if;
    tc_idx_bits(0) <= tia_bits;
    tc_idx_bits(1) <= tib_bits;
    tc_idx_bits(2) <= tic_bits;
    tc_idx_bits(3) <= tid_bits;
    if to_integer(unsigned(TC(19 downto 16))) = 0 then
      is_bits := DEFAULT_TC_IS;
    else
      is_bits := to_integer(unsigned(TC(19 downto 16)));
    end if;
    tc_initial_shift <= is_bits;
    ps_val := to_integer(unsigned(TC(23 downto 20)));
    if ps_val < 8 then
      ps_val := 12;
    end if;
    page_offset_bits := get_page_offset_bits(ps_val);
    tc_page_size  <= ps_val;
    tc_page_shift <= page_offset_bits;

    total_bits := tc_total_bits(TC);

    if TC(31) = '1' and total_bits /= 32 then
    end if;

    if TC(31) = '1' and tia_bits = 0 then
    end if;

    if TC(31) = '1' and tib_bits > 0 and tib_bits < 2 then
    end if;
  end process;

  fast_xlat: process(req, fc, rw, addr_log, tc_en, mmudis, ttr0_match_comb, ttr1_match_comb,
                     atc_flush_req, fault_reg, walker_fault, walker_fault_ack_pending,
                     translation_pending, wstate, pload_active, xlat_cfg_seq_seen, xlat_cfg_seq,
                     fs_valid, fs_fc, fs_log, fs_phys, fs_ci, fs_wp, fs_wr_ok, fs_user_ok,
                     fs_page_mask)
    variable ok    : std_logic;
    variable any   : std_logic;
    variable quiet : std_logic;
    variable sel   : std_logic_vector(31 downto 0);
    variable phys  : std_logic_vector(31 downto 0);
    variable ci    : std_logic;
    variable wp    : std_logic;
  begin
    any := '0'; phys := (others => '0'); ci := '0'; wp := '0';
    for i in 0 to FAST_ENTRIES-1 loop
      if fs_valid(i) = '1' and fs_fc(i) = fc and
         (addr_log and fs_page_mask) = fs_log(i) and
         (rw = '1' or fs_wr_ok(i) = '1') and
         (fc(2) = '1' or fs_user_ok(i) = '1') then
        ok := '1';
      else
        ok := '0';
      end if;
      sel  := (others => ok);
      any  := any or ok;
      phys := phys or (fs_phys(i) and sel);
      ci   := ci or (fs_ci(i) and ok);
      wp   := wp or (fs_wp(i) and ok);
    end loop;
    if req = '1' and fc /= "111" and ttr0_match_comb = '0' and ttr1_match_comb = '0' and
       tc_en = '1' and mmudis = '0' and atc_flush_req = '0' and fault_reg = '0' and
       walker_fault = '0' and walker_fault_ack_pending = '0' and translation_pending = '0' and
       wstate = W_IDLE and pload_active = '0' and xlat_cfg_seq_seen = xlat_cfg_seq then
      quiet := '1';
    else
      quiet := '0';
    end if;
    fast_hit  <= any and quiet;
    fast_phys <= phys or (addr_log and not fs_page_mask);
    fast_ci   <= ci;
    fast_wp   <= wp;
  end process;

  fast_set: process(clk, nreset)
    variable mask    : std_logic_vector(31 downto 0);
    variable idx     : integer range 0 to ATC_ENTRIES-1;
    variable victim  : integer range 0 to FAST_ENTRIES-1;
    variable found   : boolean;
    variable all_mru : boolean;
  begin
    if nreset = '0' then
      fs_valid     <= (others => '0');
      fs_mru       <= (others => '0');
      fs_page_mask <= x"FFFFF000";
      fs_cfg_seq   <= (others => '0');
    elsif rising_edge(clk) then
      mask := std_logic_vector(shift_left(unsigned'(x"FFFFFFFF"), tc_page_shift));
      fs_page_mask <= mask;
      fs_cfg_seq   <= xlat_cfg_seq;
      if wstate /= W_IDLE or walk_req = '1' or atc_flush_req = '1' or pflush_clear_atc = '1' or
         atc_mbit_inval_req = '1' or fs_cfg_seq /= xlat_cfg_seq or tc_en = '0' or mmudis = '1' or
         fs_page_mask /= mask then
        fs_valid <= (others => '0');
        fs_mru   <= (others => '0');
      elsif atc_mru_update_req = '1' then
        idx := atc_mru_update_idx;
        if atc_valid(idx) = '1' and atc_buserr(idx) = '0' and
           (atc_log_base(idx) and not mask) = x"00000000" and
           (atc_phys_base(idx) and not mask) = x"00000000" then
          found := false; victim := 0;
          for i in 0 to FAST_ENTRIES-1 loop
            if fs_valid(i) = '1' and fs_fc(i) = atc_fc(idx) and fs_log(i) = atc_log_base(idx) then
              victim := i; found := true;
            end if;
          end loop;
          if not found then
            for i in 0 to FAST_ENTRIES-1 loop
              if not found and fs_valid(i) = '0' then
                victim := i; found := true;
              end if;
            end loop;
          end if;
          if not found then
            for i in 0 to FAST_ENTRIES-1 loop
              if not found and fs_mru(i) = '0' then
                victim := i; found := true;
              end if;
            end loop;
          end if;
          fs_valid(victim)   <= '1';
          fs_fc(victim)      <= atc_fc(idx);
          fs_log(victim)     <= atc_log_base(idx);
          fs_phys(victim)    <= atc_phys_base(idx);
          fs_ci(victim)      <= atc_attr(idx)(2);
          fs_wp(victim)      <= atc_attr(idx)(0);
          fs_wr_ok(victim)   <= atc_attr(idx)(1) and not atc_attr(idx)(0);
          fs_user_ok(victim) <= atc_attr(idx)(3);
          fs_mru(victim)     <= '1';
          all_mru := true;
          for i in 0 to FAST_ENTRIES-1 loop
            if i /= victim and fs_mru(i) = '0' then
              all_mru := false;
            end if;
          end loop;
          if all_mru then
            for i in 0 to FAST_ENTRIES-1 loop
              if i /= victim then
                fs_mru(i) <= '0';
              end if;
            end loop;
          end if;
        end if;
      end if;
    end if;
  end process;

  addr_phys     <= addr_log when fc = "111"
                   else addr_log when (ttr0_match_comb = '1' or ttr1_match_comb = '1')
                   else addr_log when tc_en = '0'
                   else addr_log when mmudis = '1'
                   else fast_phys when fast_hit = '1'
                   else addr_phys_reg;
  cache_inhibit <= '1' when fc = "111"
                   else (ttr0_ci_comb or ttr1_ci_comb) when (ttr0_match_comb = '1' and ttr1_match_comb = '1')
                   else ttr0_ci_comb when ttr0_match_comb = '1'
                   else ttr1_ci_comb when ttr1_match_comb = '1'
                   else '0' when tc_en = '0'
                   else '0' when mmudis = '1'
                   else fast_ci when fast_hit = '1'
                   else cache_inhibit_reg;
  write_protect <= '0' when fc = "111"
                   else (ttr0_wp_comb or ttr1_wp_comb) when (ttr0_match_comb = '1' and ttr1_match_comb = '1')
                   else ttr0_wp_comb when ttr0_match_comb = '1'
                   else ttr1_wp_comb when ttr1_match_comb = '1'
                   else '0' when tc_en = '0'
                   else '0' when mmudis = '1'
                   else fast_wp when fast_hit = '1'
                   else write_protect_reg;
  fault_current_req_match <= '1' when fault_fc_reg = fc and
                                      fault_rw_reg = rw and
                                      fault_is_insn_reg = is_insn and
                                      (addr_log = fault_addr_reg or
                                       addr_log = std_logic_vector(unsigned(fault_addr_reg) + 2)) else
                             '0';
  fault         <= '0' when fc = "111" else
                   fault_reg when translated_cfg_seq = xlat_cfg_seq and
                                  fault_current_req_match = '1' else
                   '0';
  fault_status  <= fault_status_reg;
  fault_addr    <= fault_addr_reg;
  fault_fc      <= fault_fc_reg;
  fault_rw      <= fault_rw_reg;
  fault_is_insn <= fault_is_insn_reg;
  translated_match_dbg <= '1' when translated_addr = addr_log and
                                   translated_fc = fc and
                                   translated_rw = rw and
                                   translated_cfg_seq = xlat_cfg_seq else '0';
  debug_pending_flags <= req & translation_pending & walk_req & walker_completed &
                         walker_fault & walker_fault_ack_pending &
                         walker_completed_ack & fault_reg & tc_en & mmudis &
                         rw & is_insn & fc & translated_match_dbg;
  process(clk, nreset)
    variable hit       : std_logic;
    variable hit_idx   : integer range 0 to ATC_ENTRIES-1;
    variable tmatch0, tmatch1 : std_logic;
    variable tci0, twp0, tci1, twp1 : std_logic;
    variable status_tmp : std_logic_vector(31 downto 0);
    variable aligned_addr : std_logic_vector(31 downto 0);
    variable offset       : unsigned(31 downto 0);
    variable phys_base    : unsigned(31 downto 0);
    variable phys_result  : unsigned(31 downto 0);
  begin
    if nreset = '0' then
      addr_phys_reg <= x"00000000";
      translated_addr <= (others => '0');
      translated_fc <= (others => '0');
      translated_rw <= '1';
      translated_cfg_seq <= (others => '0');
      cache_inhibit_reg <= '0';
      write_protect_reg <= '0';
      fault_reg <= '0';
      fault_status_reg <= (others => '0');
      fault_addr_reg <= (others => '0');
      fault_fc_reg <= (others => '0');
      fault_rw_reg <= '1';
      debug_fault_status_latch <= (others => '0');
      debug_fault_status_valid <= '0';
      fault_is_insn_reg <= '0';
      saved_addr_log <= (others => '0');
      saved_fc <= (others => '0');
      saved_is_insn <= '0';
      saved_rw <= '0';
      req_prev <= '0';
      translation_pending <= '0';
      walk_req <= '0';
      walker_fault_ack <= '0';
      walker_completed_ack <= '0';
      walker_fault_ack_pending <= '0';
      xlat_cfg_seq_seen <= (others => '0');
      mmusr_update_req <= '0';
      mmusr_update_value <= (others => '0');
      ptest_done <= '0';
      instr_walk_pending <= '0';
      ptest_walk_pending <= '0';
      ptest_walk_no_update <= '0';
      ptest_desc_addr_reg <= (others => '0');
      ptest_desc_return_pending <= '0';
      atc_mru_update_req <= '0';
      atc_mru_update_idx <= 0;
      atc_mbit_inval_req <= '0';
      atc_mbit_inval_idx <= 0;
      pload_flush_pending <= '0';
    elsif rising_edge(clk) then
      status_tmp := fault_status_reg;
      req_prev <= req;
      ptest_done <= '0';
      atc_mru_update_req <= '0';
      atc_mbit_inval_req <= '0';
      if mmusr_update_ack = '1' then
        mmusr_update_req <= '0';
      end if;
      if ptest_update_mmusr = '1' then
        ptest_desc_addr_reg <= (others => '0');
        ptest_desc_return_pending <= '0';
      end if;
      if xlat_cfg_seq_seen /= xlat_cfg_seq then
        xlat_cfg_seq_seen <= xlat_cfg_seq;
        fault_reg <= '0';
        fault_status_reg <= (others => '0');
        fault_addr_reg <= (others => '0');
        fault_fc_reg <= (others => '0');
        fault_rw_reg <= '1';
        fault_is_insn_reg <= '0';
        translation_pending <= '0';
        walk_req <= '0';
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        ptest_desc_return_pending <= '0';
        pload_flush_pending <= '0';
        walker_fault_ack <= '0';
        walker_fault_ack_pending <= '0';
        walker_completed_ack <= '0';
      elsif req = '1' then
        if fault_reg = '1' and req_prev = '1' and
           fault_fc_reg = fc and
           fault_rw_reg = rw and
           fault_is_insn_reg = is_insn and
           (addr_log = fault_addr_reg or
            addr_log = std_logic_vector(unsigned(fault_addr_reg) + 2)) then
          null;
        else
          if walker_fault = '0' and walker_fault_ack_pending = '0' then
            fault_reg <= '0';
            fault_status_reg <= (others => '0');
          end if;
          hit := '0';
          hit_idx := 0;
          tmatch0 := '0'; tmatch1 := '0';
          tci0 := '0';
          twp0 := '0';
          tci1 := '0';
          twp1 := '0';

          if fc = "111" then
            addr_phys_reg      <= addr_log;
            translated_addr    <= addr_log;
            translated_fc      <= fc;
            translated_rw      <= rw;
            translated_cfg_seq <= xlat_cfg_seq;
            cache_inhibit_reg  <= '1';
            write_protect_reg  <= '0';
            fault_reg          <= '0';
            fault_status_reg   <= (others => '0');
            translation_pending <= '0';
          else
            ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, tmatch0, tci0, twp0);
            ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, tmatch1, tci1, twp1);
            if tmatch0 = '1' and tmatch1 = '1' then
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= (tci0 or tci1);
              write_protect_reg  <= (twp0 or twp1);
              fault_reg          <= '0';
              fault_status_reg <= encode_mmusr_success(
                write_protect => (twp0 or twp1),
                modified => '0',
                transparent => '1',
                level => "000"
              );
              translation_pending <= '0';
            elsif tmatch0 = '1' then
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= tci0;
              write_protect_reg  <= twp0;
              fault_reg          <= '0';
              fault_status_reg <= encode_mmusr_success(
                write_protect => twp0,
                modified => '0',
                transparent => '1',
                level => "000"
              );
              if addr_log = x"00002000" then
              end if;
              translation_pending <= '0';
            elsif tmatch1 = '1' then
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= tci1;
              write_protect_reg  <= twp1;
              fault_reg          <= '0';
              fault_status_reg <= encode_mmusr_success(
                write_protect => twp1,
                modified => '0',
                transparent => '1',
                level => "000"
              );
              translation_pending <= '0';
            elsif tc_en = '0' then
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= '0';
              write_protect_reg  <= '0';
              fault_reg          <= '0';
              fault_status_reg   <= encode_mmusr_success(
                write_protect => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              translation_pending <= '0';
            elsif mmudis = '1' then
              addr_phys_reg      <= addr_log;
              translated_addr    <= addr_log;
              translated_fc      <= fc;
              translated_rw      <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg  <= '0';
              write_protect_reg  <= '0';
              fault_reg          <= '0';
              fault_status_reg   <= encode_mmusr_success(
                write_protect => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              translation_pending <= '0';
            else
              hit := '0';
              for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' and atc_flush_req = '0' then
              aligned_addr := align_addr(addr_log, atc_shift(i));
              if addr_log = x"12343000" or addr_log = x"12344000" then
              end if;
              if atc_fc(i) = fc and
                 aligned_addr = atc_log_base(i) then
                if rw = '1' or atc_attr(i)(1) = '1' or atc_attr(i)(0) = '1' or atc_buserr(i) = '1' then
                  hit := '1';
                  hit_idx := i;
                else
                  atc_mbit_inval_req <= '1';
                  atc_mbit_inval_idx <= i;
                end if;
              end if;
            end if;
          end loop;
          if hit = '1' then
            atc_mru_update_idx <= hit_idx;
            atc_mru_update_req <= '1';
            if translation_pending = '1' and wstate = W_IDLE and walk_req = '0' and
               walker_completed = '0' and walker_fault = '0' then
              translation_pending <= '0';
            end if;
            if walker_fault = '1' and walker_fault_ack_pending = '1' then
            elsif atc_buserr(hit_idx) = '1' then
              status_tmp := x"0000" & atc_fault_status(hit_idx);
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              fault_addr_reg <= addr_log;
              fault_fc_reg <= fc;
              fault_rw_reg <= rw;
              fault_is_insn_reg <= is_insn;
              addr_phys_reg <= addr_log;
              translated_addr <= addr_log;
              translated_fc   <= fc;
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= '1';
              write_protect_reg <= '1';
            elsif rw = '0' and atc_attr(hit_idx)(0) = '1' then
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '1',
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              fault_addr_reg <= addr_log;
              fault_fc_reg <= fc;
              fault_rw_reg <= rw;
              fault_is_insn_reg <= is_insn;
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              translated_addr <= addr_log;
              translated_fc   <= fc;
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= atc_attr(hit_idx)(2);
              write_protect_reg <= '1';
            elsif fc(2) = '0' and atc_attr(hit_idx)(3) = '0' then
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',
                write_protect => atc_attr(hit_idx)(0),
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              fault_reg <= '1';
              fault_status_reg <= status_tmp;
              fault_addr_reg <= addr_log;
              fault_fc_reg <= fc;
              fault_rw_reg <= rw;
              fault_is_insn_reg <= is_insn;
              if debug_fault_status_valid = '0' then
                debug_fault_status_latch <= status_tmp(15 downto 0);
                debug_fault_status_valid <= '1';
              end if;
              phys_base := unsigned(atc_phys_base(hit_idx));
              offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
              phys_result := phys_base + offset;
              addr_phys_reg <= std_logic_vector(phys_result);
              translated_addr <= addr_log;
              translated_fc   <= fc;
              translated_rw   <= rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= atc_attr(hit_idx)(2);
              write_protect_reg <= atc_attr(hit_idx)(0);
            else
              if walker_fault = '1' and walker_fault_ack_pending = '1' then
              else
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                if addr_log = x"00001100" then
                end if;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= addr_log;
                translated_fc   <= fc;
                translated_rw   <= rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
                fault_status_reg <= encode_mmusr_success(
                  write_protect => atc_attr(hit_idx)(0),
                  modified => atc_attr(hit_idx)(1),
                  transparent => '0',
                  level => "000"
                );
              end if;
            end if;
          else
            if tmatch0 = '0' and tmatch1 = '0' and translation_pending = '0' then
              if addr_log = x"12343000" or addr_log = x"12344000" then
              end if;
              saved_addr_log <= addr_log;
              saved_fc <= fc;
              saved_is_insn <= is_insn;
              saved_rw <= rw;
              walk_req <= '1';
              translation_pending <= '1';
            else
              if addr_log = x"12343000" or addr_log = x"12344000" then
              end if;
            end if;
            end if;
          end if;
          end if;
        end if;

      end if;
      if ptest_active = '1' and ptest_done = '0' then
        if translation_pending = '0' then
          ttr_check(TT0, ptest_addr, ptest_fc, '0', ptest_rw, '0', tmatch0, tci0, twp0);
          ttr_check(TT1, ptest_addr, ptest_fc, '0', ptest_rw, '0', tmatch1, tci1, twp1);
          if ptest_level = "000" and tmatch0 = '1' and tmatch1 = '1' then
            mmusr_update_value <= encode_mmusr_success(
              write_protect => (twp0 or twp1),
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif ptest_level = "000" and tmatch0 = '1' then
            report "PTEST_TTR0_HIT: ptest_addr=" & slv_to_hex(ptest_addr) & " fc=" &
                   std_logic'image(ptest_fc(2)) & std_logic'image(ptest_fc(1)) & std_logic'image(ptest_fc(0)) severity note;
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp0,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif ptest_level = "000" and tmatch1 = '1' then
            mmusr_update_value <= encode_mmusr_success(
              write_protect => twp1,
              modified => '0',
              transparent => '1',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif ptest_level = "000" then
            hit := '0';
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '1' then
                aligned_addr := align_addr(ptest_addr, atc_shift(i));
                if atc_fc(i) = ptest_fc and
                   aligned_addr = atc_log_base(i) then
                  hit := '1';
                  hit_idx := i;
                end if;
              end if;
            end loop;
            if hit = '1' then
              if atc_buserr(hit_idx) = '1' then
                mmusr_update_value <= encode_mmusr_fault(
                  bus_error => '1',
                  limit_violation => '0',
                  supervisor_violation => '0',
                  write_protect => atc_fault_status(hit_idx)(11),
                  invalid => '1',
                  modified => atc_fault_status(hit_idx)(9),
                  transparent => '0',
                  level => "000"
                );
              else
                mmusr_update_value <= encode_mmusr_success(
                  write_protect => atc_attr(hit_idx)(0),
                  modified => atc_attr(hit_idx)(1),
                  transparent => '0',
                  level => "000"
                );
              end if;
            else
              mmusr_update_value <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => "000"
              );
            end if;
            mmusr_update_req <= '1';
            ptest_done <= '1';
          elsif tc_table_config_valid = '1' then
            report "PTEST_WALK: ptest_addr=" & slv_to_hex(ptest_addr) &
                   " fc=" & std_logic'image(ptest_fc(2)) & std_logic'image(ptest_fc(1)) & std_logic'image(ptest_fc(0)) &
                   " TT0=" & slv_to_hex(TT0) severity note;
            saved_addr_log <= ptest_addr;
            saved_fc <= ptest_fc;
            saved_is_insn <= '0';
            saved_rw <= ptest_rw;
            walk_req <= '1';
            translation_pending <= '1';
            instr_walk_pending <= '1';
            ptest_walk_pending <= '1';
            ptest_desc_return_pending <= '1';
            ptest_walk_no_update <= '1';
            ptest_done <= '1';
          else
            mmusr_update_value <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '1',
              modified => '0',
              transparent => '0',
              level => "000"
            );
            mmusr_update_req <= '1';
            ptest_done <= '1';
          end if;
        end if;
      end if;
      if pload_active = '1' then
        if tc_table_config_valid = '1' and translation_pending = '0' then
          saved_addr_log <= pload_addr;
          saved_fc <= pload_fc;
          saved_is_insn <= '0';
          saved_rw <= pload_rw;
          walk_req <= '1';
          translation_pending <= '1';
          instr_walk_pending <= '1';
          pload_flush_pending <= '1';
        end if;
      end if;

      if walker_fault = '1' and walker_fault_ack = '0' then
        status_tmp := walker_fault_status;
        if ptest_walk_pending = '0' then
          status_tmp(2 downto 0) := "000";
        end if;
        if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
          fault_reg <= '1';
          fault_status_reg <= status_tmp;
          if debug_fault_status_valid = '0' then
            debug_fault_status_latch <= status_tmp(15 downto 0);
            debug_fault_status_valid <= '1';
          end if;
          fault_addr_reg <= saved_addr_log;
          fault_fc_reg <= saved_fc;
          fault_rw_reg <= saved_rw;
          fault_is_insn_reg <= saved_is_insn;
          addr_phys_reg <= saved_addr_log;
          translated_addr <= saved_addr_log;
          translated_fc   <= saved_fc;
          translated_rw   <= saved_rw;
          translated_cfg_seq <= xlat_cfg_seq;
          cache_inhibit_reg <= '1';
          write_protect_reg <= '1';
        end if;
        mmusr_update_value <= status_tmp;
        if ptest_walk_pending = '1' then
          if ptest_desc_return_pending = '1' then
            ptest_desc_addr_reg <= desc_addr_reg;
            ptest_desc_return_pending <= '0';
          end if;
          mmusr_update_req <= '1';
        end if;
        translation_pending <= '0';
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        pload_flush_pending <= '0';
        walker_fault_ack <= '1';
        walker_fault_ack_pending <= '1';
      elsif walker_completed = '1' then
        if ptest_desc_return_pending = '1' then
          ptest_desc_addr_reg <= desc_addr_reg;
          ptest_desc_return_pending <= '0';
        end if;
        pload_flush_pending <= '0';
        ttr_check(TT0, saved_addr_log, saved_fc, saved_is_insn, saved_rw, '0', tmatch0, tci0, twp0);
        ttr_check(TT1, saved_addr_log, saved_fc, saved_is_insn, saved_rw, '0', tmatch1, tci1, twp1);
        if tmatch0 = '1' or tmatch1 = '1' then
          translation_pending <= '0';
        else
          hit := '0';
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              aligned_addr := align_addr(saved_addr_log, atc_shift(i));
              if atc_fc(i) = saved_fc and
                 aligned_addr = atc_log_base(i) then
                hit := '1';
                hit_idx := i;
              end if;
            end if;
          end loop;
          if hit = '1' then
            if atc_buserr(hit_idx) = '1' then
              status_tmp := x"0000" & atc_fault_status(hit_idx);
              mmusr_update_value <= status_tmp;
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            elsif saved_rw = '0' and atc_attr(hit_idx)(0) = '1' then
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '1',
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                fault_reg <= '1';
                fault_status_reg <= status_tmp;
                fault_addr_reg <= saved_addr_log;
                fault_fc_reg <= saved_fc;
                fault_rw_reg <= saved_rw;
                fault_is_insn_reg <= saved_is_insn;
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;
                translated_fc   <= saved_fc;
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= '1';
              end if;
              mmusr_update_value <= status_tmp;
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            elsif saved_fc(2) = '0' and atc_attr(hit_idx)(3) = '0' then
              status_tmp := encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '1',
                write_protect => atc_attr(hit_idx)(0),
                invalid => '0',
                modified => '0',
                transparent => '0',
                level => "000"
              );
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                fault_reg <= '1';
                fault_status_reg <= status_tmp;
                fault_addr_reg <= saved_addr_log;
                fault_fc_reg <= saved_fc;
                fault_rw_reg <= saved_rw;
                fault_is_insn_reg <= saved_is_insn;
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;
                translated_fc   <= saved_fc;
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
              end if;
              mmusr_update_value <= status_tmp;
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            else
              if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
                phys_base := unsigned(atc_phys_base(hit_idx));
                offset    := unsigned(saved_addr_log) - unsigned(atc_log_base(hit_idx));
                phys_result := phys_base + offset;
                addr_phys_reg <= std_logic_vector(phys_result);
                translated_addr <= saved_addr_log;
                translated_fc   <= saved_fc;
                translated_rw   <= saved_rw;
                translated_cfg_seq <= xlat_cfg_seq;
                cache_inhibit_reg <= atc_attr(hit_idx)(2);
                write_protect_reg <= atc_attr(hit_idx)(0);
                fault_reg <= '0';
              end if;
              status_tmp := encode_mmusr_success(
                write_protect => atc_attr(hit_idx)(0),
                modified => atc_attr(hit_idx)(1),
                transparent => '0',
                level => "000"
              );
              fault_status_reg <= status_tmp;
              mmusr_update_value <= status_tmp;
              if ptest_walk_pending = '1' then
                mmusr_update_req <= '1';
              end if;
            end if;
          else
            if instr_walk_pending = '0' and (req = '0' or addr_log = saved_addr_log) then
              addr_phys_reg <= saved_addr_log;
              translated_addr <= saved_addr_log;
              translated_fc   <= saved_fc;
              translated_rw   <= saved_rw;
              translated_cfg_seq <= xlat_cfg_seq;
              cache_inhibit_reg <= '1';
              write_protect_reg <= '0';
              if walker_fault_ack_pending = '0' then
                fault_reg <= '0';
              end if;
            end if;
          end if;
          translation_pending <= '0';
        end if;
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        walker_completed_ack <= '1';
      else
        if walker_completed = '0' then
          walker_completed_ack <= '0';
        end if;
        if walker_fault = '0' and walker_fault_ack_pending = '1' then
          walker_fault_ack <= '0';
          walker_fault_ack_pending <= '0';
        end if;
      end if;

      if translation_pending = '1' and wstate = W_IDLE and walk_req = '0' and
         walker_completed = '0' and walker_fault = '0' and
         walker_fault_ack_pending = '0' then
        translation_pending <= '0';
        instr_walk_pending <= '0';
        ptest_walk_pending <= '0';
        ptest_walk_no_update <= '0';
        ptest_desc_return_pending <= '0';
        pload_flush_pending <= '0';
      end if;

      if wstate /= W_IDLE then
        walk_req <= '0';
      end if;
    end if;
  end process;
  process(clk, nreset)
    variable table_index : integer;
    variable desc_addr_v : std_logic_vector(31 downto 0);
    variable tmatch0, tmatch1 : std_logic;
    variable tci0, twp0, tci1, twp1 : std_logic;
    variable lu_flag : std_logic;
    variable limit_fault : boolean;
    variable limit_value : unsigned(14 downto 0);
    variable rp_high : std_logic_vector(31 downto 0);
    variable replace_idx : integer range 0 to ATC_ENTRIES-1;
    variable found_invalid : boolean;
    variable found_match : boolean;
    variable all_mru_set : boolean;
    variable early_term_desc_addr : std_logic_vector(31 downto 0);
    variable early_term_page_addr : std_logic_vector(31 downto 0);
    variable early_term_offset    : std_logic_vector(31 downto 0);
    variable page_user_access     : std_logic;
    variable page_cache_inhibit   : std_logic;
    variable page_modified        : std_logic;
    variable page_write_protect   : std_logic;
  begin
    if nreset = '0' then
      for i in 0 to ATC_ENTRIES-1 loop
        atc_valid(i)     <= '0';
        atc_log_base(i)  <= (others => '0');
        atc_phys_base(i) <= (others => '0');
        atc_fc(i)        <= (others => '0');
        atc_shift(i)     <= 12;
        atc_page_size(i) <= 12;
        atc_attr(i)      <= (others => '0');
        atc_level(i)     <= (others => '0');
        atc_buserr(i)    <= '0';
        atc_fault_status(i) <= (others => '0');
      end loop;
      for i in 0 to ATC_ENTRIES-1 loop
        atc_mru(i)   <= '0';
      end loop;
      wstate      <= W_IDLE;
      walk_level  <= 0;
      walk_desc   <= (others => '0');
      walk_addr   <= (others => '0');
      walk_vpn    <= (others => '0');
      walk_fault  <= '0';
      walk_attr   <= (others => '0');
      walk_log_base  <= (others => '0');
      walk_phys_base <= (others => '0');
      walk_page_shift <= 12;
      walk_page_size <= 12;
      walker_fault <= '0';
      walker_fault_status <= (others => '0');
      walker_completed <= '0';
      mem_req     <= '0';
      mem_we      <= '0';
      mem_addr    <= (others => '0');
      mem_wdat    <= (others => '0');
      desc_update_needed <= '0';
      desc_update_data   <= (others => '0');
      walk_limit_valid <= '0';
      walk_limit_lu    <= '0';
      walk_limit_value <= (others => '0');
      walk_is_root_pointer <= '0';
      walker_timeout_counter <= 0;
      debug_timeout_seen <= '0';
      debug_timeout_mem_addr <= (others => '0');
      debug_timeout_mem_wdat <= (others => '0');
      debug_timeout_mem_we <= '0';
      debug_timeout_wstate <= (others => '0');
      debug_timeout_count <= (others => '0');
      xlat_cfg_seq_walk_seen <= (others => '0');
      ptr1_desc_addr_reg <= (others => '0');
      ptr1_desc_data_reg <= (others => '0');
      ptr2_desc_addr_reg <= (others => '0');
      ptr2_desc_data_reg <= (others => '0');
      ptr3_desc_addr_reg <= (others => '0');
      ptr3_desc_data_reg <= (others => '0');
      last_mem_rdat <= (others => '0');
      walk_page_from_indirect <= '0';
    elsif rising_edge(clk) then
      if xlat_cfg_seq_walk_seen /= xlat_cfg_seq then
        xlat_cfg_seq_walk_seen <= xlat_cfg_seq;
        wstate <= W_IDLE;
        mem_req <= '0';
        mem_we <= '0';
        mem_addr <= (others => '0');
        mem_wdat <= (others => '0');
        walk_fault <= '0';
        walker_fault <= '0';
        walker_fault_status <= (others => '0');
        walker_completed <= '0';
        walker_timeout_counter <= 0;
        desc_update_needed <= '0';
      else
        if mem_ack = '1' then
          last_mem_rdat <= mem_rdat;
        end if;
        if wstate = W_IDLE then
          walker_timeout_counter <= 0;
        elsif mem_req = '1' and mem_ack = '0' and mem_berr = '0' then
          if walker_timeout_counter < 1023 then
            walker_timeout_counter <= walker_timeout_counter + 1;
          end if;
        elsif mem_ack = '1' or mem_berr = '1' then
          walker_timeout_counter <= 0;
        end if;
        if walker_timeout_counter >= WALKER_TIMEOUT_CYCLES and mem_req = '1' then
          if debug_timeout_seen = '0' then
            debug_timeout_seen <= '1';
            if wstate = W_ROOT_LOW or wstate = W_PTR1_LOW or
               wstate = W_PTR2_LOW or wstate = W_PTR3_LOW or
               wstate = W_PTR4_LOW then
              debug_timeout_mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
            elsif wstate = W_INDIRECT then
              debug_timeout_mem_addr <= indirect_addr;
            elsif wstate = W_INDIRECT_LOW then
              debug_timeout_mem_addr <= std_logic_vector(unsigned(indirect_addr) + 4);
            else
              debug_timeout_mem_addr <= desc_addr_reg;
            end if;
            debug_timeout_mem_wdat <= desc_update_data;
            if wstate = W_TABLE_UPDATE or wstate = W_UPDATE_DESC then
              debug_timeout_mem_we <= '1';
            else
              debug_timeout_mem_we <= '0';
            end if;
            debug_timeout_wstate <= std_logic_vector(to_unsigned(walk_state_t'pos(wstate), 5));
            debug_timeout_count <= std_logic_vector(to_unsigned(walker_timeout_counter, 16));
          end if;
          walk_fault <= '1';
          walker_fault <= '1';
          walker_fault_status <= encode_mmusr_fault(
            bus_error => '1',
            limit_violation => '0',
            supervisor_violation => '0',
            write_protect => '0',
            invalid => '1',
            modified => '0',
            transparent => '0',
            level => std_logic_vector(to_unsigned(walk_level, 3))
          );
          mem_req <= '0';
          walker_timeout_counter <= 0;
          wstate <= W_FAULT;
        else
          case wstate is
        when W_IDLE =>
          if walker_fault = '1' and walker_fault_ack = '1' then
            walker_fault <= '0';
          end if;
          if walk_req = '1' then
            if pload_flush_pending = '1' then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_valid(i) = '1' then
                  if align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                    atc_valid(i) <= '0';
                    atc_mru(i) <= '0';
                    atc_buserr(i) <= '0';
                    atc_fault_status(i) <= (others => '0');
                  end if;
                end if;
              end loop;
            end if;
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
            end if;
            walk_level <= 0;
            walk_vpn  <= saved_addr_log;
            walk_fault <= '0';
            walk_attr <= (others => '0');
            mem_we <= '0';
            desc_update_needed <= '0';
            desc_addr_reg <= (others => '0');
            walk_desc <= (others => '0');
            walk_desc_high <= (others => '0');
            walk_desc_low <= (others => '0');
            walk_desc_is_long <= '0';
            walk_page_from_indirect <= '0';
            indirect_addr <= (others => '0');
            indirect_target_long <= '0';
            walk_limit_valid <= '0';
            walk_supervisor <= '0';
            walk_write_protect <= '0';
            walk_is_root_pointer <= '0';
            ptr1_desc_addr_reg <= (others => '0');
            ptr1_desc_data_reg <= (others => '0');
            ptr2_desc_addr_reg <= (others => '0');
            ptr2_desc_data_reg <= (others => '0');
            ptr3_desc_addr_reg <= (others => '0');
            ptr3_desc_data_reg <= (others => '0');
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            walk_phys_base  <= (others => '0');
            if saved_fc(2) = '1' and tc_sre = '1' then
              walk_addr <= SRP_L(31 downto 4) & "0000";
              walk_parent_dt_long <= SRP_H(1) and SRP_H(0);
              if SRP_H(1 downto 0) = "00" then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '0',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => "000"
                );
                wstate <= W_FAULT;
              elsif SRP_H(1 downto 0) = "01" then
                walk_desc_high <= SRP_H;
                walk_desc_low <= SRP_L;
                walk_desc <= SRP_L;
                walk_desc_is_long <= '1';
                walk_is_root_pointer <= '1';
                wstate <= W_PAGE;
              else
                walk_is_root_pointer <= '0';
                wstate <= W_ROOT;
              end if;
            else
              walk_addr <= CRP_L(31 downto 4) & "0000";
              walk_parent_dt_long <= CRP_H(1) and CRP_H(0);
              if CRP_H(1 downto 0) = "00" then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '0',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => "000"
                );
                wstate <= W_FAULT;
              elsif CRP_H(1 downto 0) = "01" then
                walk_desc_high <= CRP_H;
                walk_desc_low <= CRP_L;
                walk_desc <= CRP_L;
                walk_desc_is_long <= '1';
                walk_is_root_pointer <= '1';
                wstate <= W_PAGE;
              else
                walk_is_root_pointer <= '0';
                wstate <= W_ROOT;
              end if;
            end if;
          end if;

        when W_ROOT =>
          limit_fault := false;
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          if tc_fcl = '0' then
            if saved_fc(2) = '1' and tc_sre = '1' then
              rp_high := SRP_H;
            else
              rp_high := CRP_H;
            end if;
            lu_flag := rp_high(31);
            limit_value := unsigned(rp_high(30 downto 16));
            if lu_flag = '1' then
              if to_unsigned(table_index, 15) < limit_value then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '1',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => std_logic_vector(to_unsigned(walk_level, 3))
                );
                wstate <= W_FAULT;
                limit_fault := true;
              end if;
            else
              if to_unsigned(table_index, 15) > limit_value then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0',
                  limit_violation => '1',
                  supervisor_violation => '0',
                  write_protect => '0',
                  invalid => '1',
                  modified => '0',
                  transparent => '0',
                  level => std_logic_vector(to_unsigned(walk_level, 3))
                );
                wstate <= W_FAULT;
                limit_fault := true;
              end if;
            end if;
          end if;
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
          end if;
          if mem_req = '0' and not limit_fault then
            mem_req <= '1';
            mem_addr <= desc_addr_v;
            desc_addr_reg <= desc_addr_v;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1',
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '1',
              modified => '0',
              transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;
            ptr1_desc_addr_reg <= desc_addr_reg;
            ptr1_desc_data_reg <= mem_rdat;
            mem_req <= '0';
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" or saved_addr_log = x"12345000" then
            end if;
            if mem_rdat(1 downto 0) = "00" then
              if saved_addr_log = x"12345000" then
              end if;
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              walk_desc_is_long <= '1';
              wstate <= W_ROOT_LOW;
            elsif desc_is_page(mem_rdat) then
              if saved_addr_log = x"12345000" then
              end if;
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 0, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR1;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_PTR1;
              end if;
            end if;
          end if;
        when W_ROOT_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_is_page(walk_desc_high) then
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 0, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR1;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_PTR1;
              end if;
            end if;
          end if;
        when W_PTR1 =>
          limit_fault := false;
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          if mem_req = '0' then
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              else
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              end if;
            end if;
            if not limit_fault then
              if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
              end if;
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;
            ptr2_desc_addr_reg <= desc_addr_reg;
            ptr2_desc_data_reg <= mem_rdat;
            mem_req <= '0';
            if saved_addr_log = x"00400000" or saved_addr_log = x"12345000" then
            end if;
            if mem_rdat(1 downto 0) = "00" then
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
              if saved_addr_log = x"00400000" then
              end if;
            elsif walk_parent_dt_long = '1' then
              walk_desc_is_long <= '1';
              wstate <= W_PTR1_LOW;
            elsif desc_is_page(mem_rdat) then
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 1, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR2;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_PTR2;
              end if;
            end if;
          end if;
        when W_PTR1_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_is_page(walk_desc_high) then
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 1, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR2;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_PTR2;
              end if;
            end if;
          end if;
        when W_PTR2 =>
          limit_fault := false;
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          if mem_req = '0' then
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              else
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              end if;
            end if;
            if not limit_fault then
              if saved_addr_log = x"00400000" then
              end if;
              if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
              end if;
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;
            ptr3_desc_addr_reg <= desc_addr_reg;
            ptr3_desc_data_reg <= mem_rdat;
            mem_req <= '0';
            if saved_addr_log = x"12343000" or saved_addr_log = x"12344000" then
            end if;
            if mem_rdat(1 downto 0) = "00" then
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
              if saved_addr_log = x"12343000" then
              end if;
            elsif walk_parent_dt_long = '1' then
              walk_desc_is_long <= '1';
              wstate <= W_PTR2_LOW;
            elsif desc_is_page(mem_rdat) then
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 2, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR3;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_PTR3;
              end if;
            end if;
          end if;
        when W_PTR2_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_is_page(walk_desc_high) then
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 2, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR3;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_PTR3;
              end if;
            end if;
          end if;
        when W_PTR3 =>
          limit_fault := false;
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          if mem_req = '0' then
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              else
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              end if;
            end if;
            if not limit_fault then
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;
            mem_req <= '0';
            if mem_rdat(1 downto 0) = "00" then
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              walk_desc_is_long <= '1';
              wstate <= W_PTR3_LOW;
            elsif desc_is_page(mem_rdat) then
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 3, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and mem_rdat(3) = '0'
                 and not (saved_fc(2) = '0' and walk_supervisor = '1') then
                desc_update_data <= mem_rdat(31 downto 4) & '1' & mem_rdat(2 downto 0);
                walk_next_state <= W_PTR4;
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                walk_addr <= mem_rdat(31 downto 4) & "0000";
                walk_level <= walk_level + 1;
                walk_limit_valid <= '0';
                walk_parent_dt_long <= mem_rdat(1) and mem_rdat(0);
                walk_write_protect <= walk_write_protect or mem_rdat(2);
                wstate <= W_PTR4;
              end if;
            end if;
          end if;
        when W_PTR3_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_is_page(walk_desc_high) then
              wstate <= W_PAGE;
            elsif is_final_table_level(tc_fcl, 3, tc_idx_bits) then
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            else
              if ptest_walk_no_update = '0' and walk_desc_high(3) = '0' and
                 not (saved_fc(2) = '0' and (walk_supervisor = '1' or walk_desc_high(8) = '1')) then
                desc_update_data <= walk_desc_high(31 downto 4) & '1' & walk_desc_high(2 downto 0);
                walk_next_state <= W_PTR4;
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_TABLE_UPDATE;
              elsif ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_addr <= get_desc_address(walk_desc_high, mem_rdat, '1');
                walk_level <= walk_level + 1;
                walk_limit_valid <= '1';
                walk_limit_lu    <= walk_desc_high(31);
                walk_limit_value <= unsigned(walk_desc_high(30 downto 16));
                walk_supervisor <= walk_supervisor or walk_desc_high(8);
                walk_write_protect <= walk_write_protect or walk_desc_high(2);
                walk_parent_dt_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_PTR4;
              end if;
            end if;
          end if;
        when W_PTR4 =>
          limit_fault := false;
          table_index := get_fcl_table_index(walk_vpn, saved_fc, tc_fcl, walk_level, tc_initial_shift, tc_page_size, tc_idx_bits);
          desc_addr_v := walk_addr(31 downto 4) & "0000";
          if walk_parent_dt_long = '1' then
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 8, 32));
          else
            desc_addr_v := std_logic_vector(unsigned(desc_addr_v) + to_unsigned(table_index * 4, 32));
          end if;
          if mem_req = '0' then
            if walk_limit_valid = '1' then
              if walk_limit_lu = '1' then
                if to_unsigned(table_index, 15) < walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              else
                if to_unsigned(table_index, 15) > walk_limit_value then
                  walker_fault <= '1';
                  walker_fault_status <= encode_mmusr_fault(
                    bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                    write_protect => '0', invalid => '1', modified => '0', transparent => '0',
                    level => std_logic_vector(to_unsigned(walk_level, 3))
                  );
                  wstate <= W_FAULT;
                  limit_fault := true;
                end if;
              end if;
            end if;
            if not limit_fault then
              mem_req <= '1';
              mem_addr <= desc_addr_v;
              desc_addr_reg <= desc_addr_v;
            end if;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc <= mem_rdat;
            walk_desc_high <= mem_rdat;
            mem_req <= '0';
            if mem_rdat(1 downto 0) = "00" then
              walk_desc_is_long <= '0';
              walk_fault <= '1';
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 1, 3))
              );
              wstate <= W_FAULT;
            elsif walk_parent_dt_long = '1' then
              walk_desc_is_long <= '1';
              wstate <= W_PTR4_LOW;
            elsif desc_is_page(mem_rdat) then
              walk_desc_is_long <= '0';
              wstate <= W_PAGE;
            else
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => '0',
                  accum_write_protect => walk_write_protect,
                  current_write_protect => mem_rdat(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                walk_desc_is_long <= '0';
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= mem_rdat(1) and mem_rdat(0);
                wstate <= W_INDIRECT;
              end if;
            end if;
          end if;
        when W_PTR4_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(desc_addr_reg) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            if desc_is_page(walk_desc_high) then
              wstate <= W_PAGE;
            else
              if ptest_walk_pending = '1' and
                 to_unsigned(walk_level + 1, 3) >= unsigned(ptest_level) then
                walker_fault <= '1';
                walker_fault_status <= encode_ptest_table_status(
                  fc => saved_fc,
                  accum_supervisor => walk_supervisor,
                  current_supervisor => walk_desc_high(8),
                  accum_write_protect => walk_write_protect,
                  current_write_protect => walk_desc_high(2),
                  level => std_logic_vector(to_unsigned(walk_level + 1, 3))
                );
                wstate <= W_FAULT;
              else
                indirect_addr <= mem_rdat(31 downto 2) & "00";
                indirect_target_long <= walk_desc_high(1) and walk_desc_high(0);
                wstate <= W_INDIRECT;
              end if;
            end if;
          end if;
        when W_INDIRECT =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= indirect_addr;
            desc_addr_reg <= indirect_addr;
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            mem_req <= '0';
            if mem_rdat(1 downto 0) = "01" then
              walk_desc_high <= mem_rdat;
              walk_page_from_indirect <= '1';
              if indirect_target_long = '0' then
                walk_desc <= mem_rdat;
                walk_desc_is_long <= '0';
                wstate <= W_PAGE;
              else
                walk_desc_is_long <= '1';
                wstate <= W_INDIRECT_LOW;
              end if;
            elsif mem_rdat(1 downto 0) = "00" then
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 2, 3))
              );
              wstate <= W_FAULT;
            else
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_fault(
                bus_error => '0',
                limit_violation => '0',
                supervisor_violation => '0',
                write_protect => '0',
                invalid => '1',
                modified => '0',
                transparent => '0',
                level => std_logic_vector(to_unsigned(walk_level + 2, 3))
              );
              wstate <= W_FAULT;
            end if;
          end if;
        when W_INDIRECT_LOW =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_addr <= std_logic_vector(unsigned(indirect_addr) + 4);
          elsif mem_berr = '1' then
            mem_req <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level + 1, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            walk_desc_low <= mem_rdat;
            walk_desc <= mem_rdat;
            mem_req <= '0';
            wstate <= W_PAGE;
          end if;
        when W_PAGE =>
          if (walk_desc_is_long = '1' and not desc_valid(walk_desc_high)) or
             (walk_desc_is_long = '0' and not desc_valid(walk_desc)) then
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '0',
              write_protect => '0',
              invalid => '1',
              modified => '0',
              transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            wstate <= W_FAULT;
          elsif saved_fc(2) = '0' and
                (walk_supervisor = '1' or get_supervisor_bit(walk_desc_high, walk_desc_is_long) = '1') and
                walk_is_root_pointer = '0' then
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '0',
              limit_violation => '0',
              supervisor_violation => '1',
              write_protect => walk_desc_high(2) or walk_write_protect,
              invalid => '0',
              modified => '0',
              transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            wstate <= W_FAULT;
          else
            walk_page_shift <= tc_page_shift;
            walk_page_size  <= tc_page_size;
            walk_log_base   <= align_addr(saved_addr_log, tc_page_shift);
            early_term_desc_addr := align_addr(saved_addr_log, calc_effective_page_shift(tc_page_shift, walk_level, tc_idx_bits, tc_fcl, walk_is_root_pointer));
            early_term_page_addr := align_addr(saved_addr_log, tc_page_shift);
            early_term_offset := std_logic_vector(unsigned(early_term_page_addr) - unsigned(early_term_desc_addr));
            if walk_desc_is_long = '1' then
              early_term_desc_addr := walk_desc_low(31 downto 8) & x"00";
              walk_phys_base <= std_logic_vector(
                unsigned(early_term_desc_addr) + unsigned(early_term_offset));
            else
              early_term_desc_addr := walk_desc_high(31 downto 8) & x"00";
              walk_phys_base <= std_logic_vector(
                unsigned(early_term_desc_addr) + unsigned(early_term_offset));
            end if;
            limit_fault := false;
            if walk_desc_is_long = '1'
               and early_term_limit_applies(walk_is_root_pointer, tc_fcl, walk_level, tc_idx_bits) then
              table_index := get_fcl_table_index(
                walk_vpn,
                saved_fc,
                tc_fcl,
                early_term_limit_level(walk_is_root_pointer, walk_level),
                tc_initial_shift,
                tc_page_size,
                tc_idx_bits
              );
              if walk_desc_high(31) = '1' and to_unsigned(table_index, 15) < unsigned(walk_desc_high(30 downto 16)) then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                  write_protect => '0', invalid => '1', modified => '0',
                  transparent => '0', level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer));
                wstate <= W_FAULT;
                limit_fault := true;
              elsif walk_desc_high(31) = '0' and to_unsigned(table_index, 15) > unsigned(walk_desc_high(30 downto 16)) then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_fault(
                  bus_error => '0', limit_violation => '1', supervisor_violation => '0',
                  write_protect => '0', invalid => '1', modified => '0',
                  transparent => '0', level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer));
                wstate <= W_FAULT;
                limit_fault := true;
              end if;
            end if;
            page_user_access   := not (walk_supervisor or get_supervisor_bit(walk_desc_high, walk_desc_is_long));
            page_cache_inhibit := walk_desc_high(6);
            page_modified      := walk_desc_high(4);
            page_write_protect := walk_desc_high(2) or walk_write_protect;
            walk_attr(3) <= page_user_access;
            walk_attr(2) <= page_cache_inhibit;
            walk_attr(1) <= page_modified;
            walk_attr(0) <= page_write_protect;
            walk_fault <= '0';
            if walk_desc_is_long = '1' then
            end if;
            if limit_fault then
              null;
            elsif ptest_walk_no_update = '1' or walk_is_root_pointer = '1' then
              if ptest_walk_pending = '1' then
                walker_fault <= '1';
                if walk_is_root_pointer = '1' then
                  walker_fault_status <= encode_mmusr_success(
                    write_protect => page_write_protect,
                    modified => page_modified,
                    transparent => '0',
                    level => "000"
                  );
                else
                  walker_fault_status <= encode_mmusr_success(
                    write_protect => page_write_protect,
                    modified => page_modified,
                    transparent => '0',
                    level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
                  );
                end if;
                wstate <= W_FAULT;
              elsif pload_flush_pending = '1' then
                wstate <= W_PLOAD_FLUSH;
              else
                wstate <= W_FILL;
              end if;
            elsif walk_desc_high(3) = '0' or (saved_rw = '0' and walk_desc_high(4) = '0' and walk_desc_high(2) = '0' and walk_write_protect = '0') then
              desc_update_needed <= '1';
              desc_update_data <= walk_desc_high(31 downto 5) &
                                  (walk_desc_high(4) or ((not saved_rw) and (not ptest_walk_pending) and (not walk_desc_high(2)) and (not walk_write_protect))) &
                                  '1' &
                                  walk_desc_high(2 downto 0);
              wstate <= W_UPDATE_DESC;
            else
              if ptest_walk_pending = '1' then
                walker_fault <= '1';
                walker_fault_status <= encode_mmusr_success(
                  write_protect => page_write_protect,
                  modified => page_modified,
                  transparent => '0',
                  level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
                );
                wstate <= W_FAULT;
              elsif pload_flush_pending = '1' then
                wstate <= W_PLOAD_FLUSH;
              else
                wstate <= W_FILL;
              end if;
            end if;
          end if;
        when W_TABLE_UPDATE =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_we <= '1';
            mem_addr <= desc_addr_reg;
            mem_wdat <= desc_update_data;
          elsif mem_berr = '1' then
            mem_req <= '0';
            mem_we <= '0';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => std_logic_vector(to_unsigned(walk_level, 3))
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            mem_req <= '0';
            mem_we <= '0';
            if ptest_walk_pending = '1' and
               to_unsigned(walk_level, 3) >= unsigned(ptest_level) then
              walker_fault <= '1';
              walker_fault_status <= encode_ptest_table_status(
                fc => saved_fc,
                accum_supervisor => walk_supervisor,
                current_supervisor => '0',
                accum_write_protect => walk_write_protect,
                current_write_protect => '0',
                level => std_logic_vector(to_unsigned(walk_level, 3))
              );
              wstate <= W_FAULT;
            else
              wstate <= walk_next_state;
            end if;
          end if;
        when W_UPDATE_DESC =>
          if mem_req = '0' then
            mem_req <= '1';
            mem_we <= '1';
            mem_addr <= desc_addr_reg;
            mem_wdat <= desc_update_data;
          elsif mem_berr = '1' then
            mem_req <= '0';
            mem_we <= '0';
            walk_fault <= '1';
            walker_fault <= '1';
            walker_fault_status <= encode_mmusr_fault(
              bus_error => '1', limit_violation => '0', supervisor_violation => '0',
              write_protect => '0', invalid => '1', modified => '0', transparent => '0',
              level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
            );
            wstate <= W_FAULT;
          elsif mem_ack = '1' then
            mem_req <= '0';
            mem_we <= '0';
            desc_update_needed <= '0';
            walk_attr(1) <= desc_update_data(4);
            if ptest_walk_pending = '1' then
              walker_fault <= '1';
              walker_fault_status <= encode_mmusr_success(
                write_protect => desc_update_data(2) or walk_write_protect,
                modified => desc_update_data(4),
                transparent => '0',
                level => page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer)
              );
              wstate <= W_FAULT;
            elsif pload_flush_pending = '1' then
              wstate <= W_PLOAD_FLUSH;
            else
              wstate <= W_FILL;
            end if;
          end if;
        when W_PLOAD_FLUSH =>
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
              end if;
            end if;
          end loop;
          wstate <= W_FILL;
        when W_FILL =>
          found_match := false;
          found_invalid := false;
          replace_idx := 0;
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' and not found_match and atc_fc(i) = saved_fc and
               align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
              replace_idx := i;
              found_match := true;
            end if;
          end loop;
          if not found_match then
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '0' and not found_invalid then
                replace_idx := i;
                found_invalid := true;
              end if;
            end loop;
          end if;
          if not found_match and not found_invalid then
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_mru(i) = '0' then
                replace_idx := i;
                exit;
              end if;
            end loop;
          end if;
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= replace_idx and atc_valid(i) = '1' and atc_fc(i) = saved_fc and
               align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
              atc_valid(i) <= '0';
              atc_mru(i) <= '0';
              atc_buserr(i) <= '0';
              atc_fault_status(i) <= (others => '0');
            end if;
          end loop;
          atc_log_base(replace_idx)  <= walk_log_base;
          atc_phys_base(replace_idx) <= align_addr(walk_phys_base, walk_page_shift);
          atc_shift(replace_idx)     <= walk_page_shift;
          atc_page_size(replace_idx) <= walk_page_size;
          atc_attr(replace_idx)      <= walk_attr(3 downto 0);
          atc_fc(replace_idx)        <= saved_fc;
          atc_level(replace_idx)     <= page_descriptor_count(walk_level, walk_page_from_indirect, walk_is_root_pointer);
          atc_valid(replace_idx)     <= '1';
          atc_buserr(replace_idx)    <= '0';
          atc_fault_status(replace_idx) <= (others => '0');
          atc_mru(replace_idx) <= '1';
          all_mru_set := true;
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= replace_idx and atc_mru(i) = '0' then
              all_mru_set := false;
            end if;
          end loop;
          if all_mru_set then
            for i in 0 to ATC_ENTRIES-1 loop
              if i /= replace_idx then
                atc_mru(i) <= '0';
              end if;
            end loop;
          end if;
          wstate <= W_COMPLETE;

        when W_COMPLETE =>
          walker_completed <= '1';

          wstate <= W_IDLE;

        when W_FAULT =>
          mem_req <= '0';
          if ptest_walk_pending = '1' then
            wstate <= W_IDLE;
          else
            found_match := false;
            found_invalid := false;
            replace_idx := 0;
            for i in 0 to ATC_ENTRIES-1 loop
              if atc_valid(i) = '1' and not found_match and atc_fc(i) = saved_fc and
                 align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                replace_idx := i;
                found_match := true;
              end if;
            end loop;
            if not found_match then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_valid(i) = '0' and not found_invalid then
                  replace_idx := i;
                  found_invalid := true;
                end if;
              end loop;
            end if;
            if not found_match and not found_invalid then
              for i in 0 to ATC_ENTRIES-1 loop
                if atc_mru(i) = '0' then
                  replace_idx := i;
                  exit;
                end if;
              end loop;
            end if;
            for i in 0 to ATC_ENTRIES-1 loop
              if i /= replace_idx and atc_valid(i) = '1' and atc_fc(i) = saved_fc and
                 align_addr(saved_addr_log, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
              end if;
            end loop;
            atc_log_base(replace_idx)  <= walk_log_base;
            atc_phys_base(replace_idx) <= (others => '0');
            atc_shift(replace_idx)     <= walk_page_shift;
            atc_page_size(replace_idx) <= walk_page_size;
            atc_attr(replace_idx)      <= (others => '0');
            atc_fc(replace_idx)        <= saved_fc;
            atc_level(replace_idx)     <= (others => '0');
            atc_valid(replace_idx)     <= '1';
            atc_buserr(replace_idx)    <= '1';
            atc_fault_status(replace_idx) <= walker_fault_status(15 downto 3) & "000";
            atc_mru(replace_idx) <= '1';
            walker_completed <= '1';
            wstate <= W_IDLE;
          end if;

        when others =>
          wstate <= W_IDLE;
        end case;
        end if;
      end if;
      if atc_mru_update_req = '1' then
        atc_mru(atc_mru_update_idx) <= '1';
        all_mru_set := true;
        for i in 0 to ATC_ENTRIES-1 loop
          if i /= atc_mru_update_idx and atc_mru(i) = '0' then
            all_mru_set := false;
          end if;
        end loop;
        if all_mru_set then
          for i in 0 to ATC_ENTRIES-1 loop
            if i /= atc_mru_update_idx then
              atc_mru(i) <= '0';
            end if;
          end loop;
        end if;
      end if;
      if atc_mbit_inval_req = '1' then
        atc_valid(atc_mbit_inval_idx) <= '0';
        atc_mru(atc_mbit_inval_idx) <= '0';
        atc_buserr(atc_mbit_inval_idx) <= '0';
        atc_fault_status(atc_mbit_inval_idx) <= (others => '0');
      end if;
      if atc_flush_req = '1' then
        for i in 0 to ATC_ENTRIES-1 loop
          atc_valid(i) <= '0';
          atc_mru(i) <= '0';
          atc_buserr(i) <= '0';
          atc_fault_status(i) <= (others => '0');
        end loop;
      end if;
      if pflush_clear_atc = '1' and wstate = W_IDLE then
        if pflush_mode = "001" then
          for i in 0 to ATC_ENTRIES-1 loop
            atc_valid(i) <= '0';
            atc_mru(i) <= '0';
            atc_buserr(i) <= '0';
            atc_fault_status(i) <= (others => '0');
          end loop;
        elsif pflush_mode = "100" then
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if ((atc_fc(i) xor pflush_fc) and pflush_mask) = "000" then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
              end if;
            end if;
          end loop;
        else
          for i in 0 to ATC_ENTRIES-1 loop
            if atc_valid(i) = '1' then
              if ((atc_fc(i) xor pflush_fc) and pflush_mask) = "000" and
                 align_addr(pflush_addr, atc_shift(i)) = atc_log_base(i) then
                atc_valid(i) <= '0';
                atc_mru(i) <= '0';
                atc_buserr(i) <= '0';
                atc_fault_status(i) <= (others => '0');
              end if;
            end if;
          end loop;
        end if;
      end if;

      if walker_fault = '1' and walker_fault_ack = '1' then
        walker_fault <= '0';
      end if;

      if walker_completed = '1' and walker_completed_ack = '1' then
        walker_completed <= '0';
      end if;
    end if;
  end process;
  process(wstate, addr_log, fc, rw, rmw, is_insn, TT0, TT1, tc_en, translation_pending, walker_fault, walker_completed, walker_fault_ack_pending, translated_addr, translated_fc, translated_rw, translated_cfg_seq, xlat_cfg_seq, req, fault_reg, fault_current_req_match, pload_active, pflush_active, ptest_update_mmusr, ptest_active, ptest_walk_pending, ptest_desc_return_pending, mmusr_update_req, tc_config_check_pending, tc_config_valid, fast_hit)
    variable tmatch0, tmatch1 : std_logic;
    variable dummy_ci, dummy_wp : std_logic;
  begin
    if ptest_update_mmusr = '1' or ptest_active = '1' or ptest_desc_return_pending = '1' or
       mmusr_update_req = '1' or pflush_active = '1' then
      busy <= '1';
    elsif tc_config_check_pending = '1' and tc_config_valid = '0' then
      busy <= '1';
    elsif tc_en = '0' and pload_active = '0' and ptest_walk_pending = '0'
       and translation_pending = '0' and wstate = W_IDLE then
      busy <= '0';
    else
      ttr_check(TT0, addr_log, fc, is_insn, rw, rmw, tmatch0, dummy_ci, dummy_wp);
      ttr_check(TT1, addr_log, fc, is_insn, rw, rmw, tmatch1, dummy_ci, dummy_wp);
      if (pload_active = '0' and
          (tmatch0 = '1' or tmatch1 = '1' or fast_hit = '1' or
          (fault_reg = '1' and translated_cfg_seq = xlat_cfg_seq and fault_current_req_match = '1') or
          (translation_pending = '0' and wstate = W_IDLE and walker_fault = '0' and walker_fault_ack_pending = '0' and
           (req = '0' or (translated_addr = addr_log and translated_fc = fc and translated_rw = rw and translated_cfg_seq = xlat_cfg_seq))))) then
        busy <= '0';
      else
        busy <= '1';
      end if;
    end if;
  end process;

  process(clk, nreset)
  begin
    if nreset = '0' then
      ptest_update_mmusr <= '0';
      pflush_active <= '0';
      pflush_clear_atc <= '0';
      ptest_req_prev <= '0';
      pflush_req_prev <= '0';
      pload_req_prev <= '0';
      reg_we_prev <= '0';
      reg_re_prev <= '0';
      ptest_addr <= (others => '0');
      ptest_fc <= (others => '0');
      ptest_rw <= '1';
      ptest_level <= "000";
      pload_active <= '0';
      pload_addr <= (others => '0');
      pload_fc <= (others => '0');
      pload_rw <= '1';
    elsif rising_edge(clk) then
      ptest_req_prev <= ptest_req;
      pflush_req_prev <= pflush_req;
      pload_req_prev <= pload_req;
      reg_we_prev <= reg_we;
      reg_re_prev <= reg_re;

      if ptest_req = '1' and ptest_req_prev = '0' then
        ptest_update_mmusr <= '1';
        ptest_addr <= pmmu_addr;
        ptest_fc <= pmmu_fc;
        ptest_rw <= pmmu_brief(9);
        ptest_level <= pmmu_brief(12 downto 10);
      else
        ptest_update_mmusr <= '0';
      end if;

      if pflush_req = '1' and pflush_req_prev = '0' then
        pflush_active <= '1';
        pflush_addr <= pmmu_addr;
        pflush_fc <= pmmu_fc;
        pflush_mode <= pmmu_brief(12 downto 10);
        pflush_mask <= pmmu_brief(7 downto 5);
        pflush_clear_atc <= '1';
      elsif pflush_active = '1' then
        if wstate = W_IDLE then
          pflush_active <= '0';
          pflush_clear_atc <= '0';
        else
          pflush_clear_atc <= '1';
        end if;
      else
        pflush_clear_atc <= '0';
      end if;

      if pload_req = '1' and pload_req_prev = '0' then
        pload_active <= '1';
        pload_addr <= pmmu_addr;
        pload_fc <= pmmu_fc;
        pload_rw <= pmmu_brief(9);
      elsif pload_active = '1' then
        if translation_pending = '0' then
          pload_active <= '0';
        end if;
      end if;
    end if;
  end process;
  mmu_config_err <= mmu_config_error;
end rtl;
