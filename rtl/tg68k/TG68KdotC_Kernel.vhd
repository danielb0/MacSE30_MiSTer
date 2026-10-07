------------------------------------------------------------------------------
------------------------------------------------------------------------------
--                                                                          --
-- Copyright (c) 2009-2020 Tobias Gubener                                   --
-- Patches by MikeJ, Till Harbaum, Rok Krajnk, ...                          --
-- Subdesign fAMpIGA by TobiFlex                                            --
--                                                                          --
-- This source file is free software: you can redistribute it and/or modify --
-- it under the terms of the GNU Lesser General Public License as published --
-- by the Free Software Foundation, either version 3 of the License, or     --
-- (at your option) any later version.                                      --
--                                                                          --
-- This source file is distributed in the hope that it will be useful,      --
-- but WITHOUT ANY WARRANTY; without even the implied warranty of           --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            --
-- GNU General Public License for more details.                             --
--                                                                          --
-- You should have received a copy of the GNU General Public License        --
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.    --
--                                                                          --
------------------------------------------------------------------------------
------------------------------------------------------------------------------

-- 14.10.2020 TG bugfix chk2.b
-- 13.10.2020 TG go back to old aligned design and bugfix chk2
-- 11.10.2020 TG next try CHK2 flags
-- 10.10.2020 TG bugfix division N-flag
-- 09.10.2020 TG bugfix division overflow
-- 2/3.10.2020 some tweaks by retrofun, gyurco and robinsonb5
-- 17.03.2020 TG bugfix move data to (extended address)
-- 13.03.2020 TG bugfix extended addess mode - thanks Adam Polkosnik
-- 15.02.2020 TG bugfix DIVS.W with result $8000
-- 08.01.2020 TH fix the byte-mirroring
-- 25.11.2019 TG bugfix ILLEGAL.B handling
-- 24.11.2019 TG next try CMP2 and CHK2.l
-- 24.11.2019 retrofun(RF) commit ILLEGAL.B handling
-- 18.11.2019 TG insert CMP2 and CHK2.l
-- 17.11.2019 TG insert CAS and CAS2
-- 10.11.2019 TG insert TRAPcc
-- 08.11.2019 TG bugfix movem in 68020 mode
-- 06.11.2019 TG bugfix CHK
-- 06.11.2019 TG bugfix flags and stackframe DIVU
-- 04.11.2019 TG insert RTE from TH
-- 03.11.2019 TG insert TrapV from TH
-- 03.11.2019 TG bugfix MUL 64Bit
-- 03.11.2019 TG rework barrel shifter - some other tweaks
-- 02.11.2019 TG bugfig N-Flag and Z-Flag for DIV
-- 30.10.2019 TG bugfix RTR in 68020-mode
-- 30.10.2019 TG bugfix BFINS again
-- 19.10.2019 TG insert some bugfixes from apolkosnik
-- 05.12.2018 TG insert RTD opcode
-- 03.12.2018 TG insert barrel shifter
-- 01.11.2017 TG bugfix V-Flag for ASL/ASR - thanks Peter Graf
-- 29.05.2017 TG decode 0x4AFB as illegal, needed for QL BKP - thanks Peter Graf
-- 21.05.2017 TG insert generic for hardware multiplier for MULU & MULS
-- 04.04.2017 TG change GPL to LGPL
-- 04.04.2017 TG BCD handling with all undefined behavior!
-- 02.04.2017 TG bugfix Bitfield Opcodes
-- 19.03.2017 TG insert PACK/UNPACK
-- 19.03.2017 TG bugfix CMPI ...(PC) - thanks Till Harbaum
--     ???    MJ bugfix non_aligned movem access
-- add berr handling 10.03.2013 - needed for ATARI Core

-- bugfix session 07/08.Feb.2013
-- movem ,-(an)
-- movem (an)+,          - thanks  Gerhard Suttner
-- btst dn,#data         - thanks  Peter Graf
-- movep                 - thanks  Till Harbaum
-- IPL vector            - thanks  Till Harbaum
--

-- optimize Register file

-- to do 68010:
-- (MOVEC)
-- BKPT
-- MOVES
--
-- to do 68020:
-- (CALLM)
-- (RETM)

-- bugfix CHK2, CMP2
-- rework barrel shifter
-- CHK2
-- CMP2
-- cpXXX Coprozessor stuff

-- done 020:
-- CAS, CAS2
-- TRAPcc
-- PACK
-- UNPK
-- Bitfields
-- address modes
-- long bra
-- DIVS.L, DIVU.L
-- LINK long
-- MULS.L, MULU.L
-- extb.l

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use work.TG68K_Pack.all;

entity TG68KdotC_Kernel is
	generic(
		SR_Read : integer:= 2;
		VBR_Stackframe : integer:= 2;
		extAddr_Mode : integer:= 2;
		MUL_Mode : integer := 2;
		DIV_Mode : integer := 2;
		BitField : integer := 2;

		BarrelShifter : integer := 1;
		MUL_Hardware : integer := 1;
		DATA_WIDTH : integer := 16
		);
	port(clk						: in std_logic;
		nReset					: in std_logic;
		clkena_in				: in std_logic:='1';
		beat_valid				: in std_logic:='1';
		data_in					: in std_logic_vector(DATA_WIDTH-1 downto 0);
		dsack						: in std_logic_vector(1 downto 0):="00";
		IPL						: in std_logic_vector(2 downto 0):="111";
		IPL_autovector			: in std_logic:='0';
		berr						: in std_logic:='0';
		CPU						: in std_logic_vector(1 downto 0);
		addr_out					: out std_logic_vector(31 downto 0);
		addr_log_out				: out std_logic_vector(31 downto 0);
		data_write				: out std_logic_vector(DATA_WIDTH-1 downto 0);
		siz						: out std_logic_vector(1 downto 0);
		nWr						: out std_logic;
		nUDS						: out std_logic;
		nLDS						: out std_logic;
		busstate					: out std_logic_vector(1 downto 0);
		longword					: out std_logic;
		nResetOut				: out std_logic;
		FC							: out std_logic_vector(2 downto 0);
		clr_berr					: out std_logic;
		cp_berr_ack				: out std_logic;
		skipFetch				: out std_logic;
		regin_out				: out std_logic_vector(31 downto 0);
		CACR_out					: out std_logic_vector(31 downto 0);
		VBR_out					: out std_logic_vector(31 downto 0);
		cache_inv_req			: out std_logic;
		cache_op_scope			: out std_logic_vector(1 downto 0);
		cache_op_cache			: out std_logic_vector(1 downto 0);
		cacr_ie					: out std_logic;
		cacr_de					: out std_logic;
		cacr_ifreeze				: out std_logic;
		cacr_dfreeze				: out std_logic;
		cacr_ibe				: out std_logic;
		cacr_dbe				: out std_logic;
		cacr_wa				: out std_logic;
		pmmu_reg_we				: out std_logic;
		pmmu_reg_re				: out std_logic;
		pmmu_reg_sel			: out std_logic_vector(4 downto 0);
		pmmu_reg_wdat			: out std_logic_vector(31 downto 0);
		pmmu_reg_part			: out std_logic;
		pmmu_addr_log			: out std_logic_vector(31 downto 0);
		pmmu_addr_phys			: out std_logic_vector(31 downto 0);
		pmmu_cache_inhibit		: out std_logic;
		rmc_out					: out std_logic;
		wronly_rd_out			: out std_logic;
		dib_sub_out				: out std_logic;
		cache_op_addr			: out std_logic_vector(31 downto 0);
		pmmu_walker_req		: out std_logic;
		pmmu_walker_we		: out std_logic;
		pmmu_walker_addr		: out std_logic_vector(31 downto 0);
		pmmu_walker_wdat		: out std_logic_vector(31 downto 0);
		pmmu_walker_ack		: in  std_logic;
		pmmu_walker_data		: in  std_logic_vector(31 downto 0);
		pmmu_walker_berr		: in  std_logic;
		debug_SVmode			: out std_logic;
		debug_preSVmode		: out std_logic;
		debug_FlagsSR_S		: out std_logic;
		debug_changeMode		: out std_logic;
		debug_setopcode		: out std_logic;
		debug_exec_directSR	: out std_logic;
		debug_exec_to_SR		: out std_logic;
		debug_pmove_dn_mode : out std_logic;
		debug_pmove_dn_regnum : out std_logic_vector(2 downto 0);
		debug_opcode : out std_logic_vector(15 downto 0);
		debug_state : out std_logic_vector(1 downto 0);
		debug_setstate : out std_logic_vector(1 downto 0);
		debug_last_opc_read : out std_logic_vector(15 downto 0);
		debug_data_read : out std_logic_vector(31 downto 0);
		debug_direct_data : out std_logic;
		debug_setnextpass : out std_logic;
		debug_TG68_PC : out std_logic_vector(31 downto 0);
		debug_memaddr_reg : out std_logic_vector(31 downto 0);
		debug_memaddr_delta : out std_logic_vector(31 downto 0);
		debug_oddout : out std_logic;
		debug_decodeOPC : out std_logic;
		debug_brief : out std_logic_vector(15 downto 0);
		debug_moves_bus_pending : out std_logic;
		debug_moves_writeback_pending : out std_logic;
		debug_clkena_lw : out std_logic;
		debug_regfile_d0 : out std_logic_vector(31 downto 0);
		debug_regfile_a0 : out std_logic_vector(31 downto 0);
		debug_fline_context_valid : out std_logic;
		debug_trap_1111 : out std_logic;
		debug_trapmake : out std_logic;
		debug_exc_take : out std_logic;
		debug_opcode_pc : out std_logic_vector(31 downto 0);
		debug_pmmu_brief : out std_logic_vector(15 downto 0);
		debug_use_base : out std_logic;
		debug_rf_source_addr : out std_logic_vector(3 downto 0);
		debug_pmove_ea_latched : out std_logic_vector(31 downto 0);
		debug_reg_QA : out std_logic_vector(31 downto 0);
		debug_last_data_read : out std_logic_vector(31 downto 0);
		debug_last_opc_pc : out std_logic_vector(31 downto 0);
		debug_getbrief : out std_logic;
		debug_get_2ndopc : out std_logic;
		debug_fline_brief_pending : out std_logic;
		debug_fline_opcode_pc : out std_logic_vector(31 downto 0);
		debug_exe_PC : out std_logic_vector(31 downto 0);
		debug_memaddr_delta_rega : out std_logic_vector(31 downto 0);
		debug_memaddr_delta_regb : out std_logic_vector(31 downto 0);
		debug_addsub_q : out std_logic_vector(31 downto 0);
		debug_memmaskmux : out std_logic_vector(5 downto 0);
		debug_fline_opcode_latch : out std_logic_vector(15 downto 0);
		debug_pmmu_ea_mode_latched : out std_logic_vector(5 downto 0);
		debug_exec_direct_delta : out std_logic;
		debug_exec_directPC : out std_logic;
		debug_bus_beat_poisoned : out std_logic;
		debug_exec_mem_addsub : out std_logic;
		debug_set_addrlong : out std_logic;
		debug_mdelta_src : out std_logic_vector(7 downto 0);
		debug_pc_brw : out std_logic;
		debug_pc_word : out std_logic;
		debug_regfile_d1 : out std_logic_vector(31 downto 0);
		debug_regfile_d2 : out std_logic_vector(31 downto 0);
		debug_regfile_d3 : out std_logic_vector(31 downto 0);
		debug_regfile_d4 : out std_logic_vector(31 downto 0);
		debug_regfile_d5 : out std_logic_vector(31 downto 0);
		debug_regfile_d6 : out std_logic_vector(31 downto 0);
		debug_regfile_d7 : out std_logic_vector(31 downto 0);
		debug_regfile_a1 : out std_logic_vector(31 downto 0);
		debug_regfile_a2 : out std_logic_vector(31 downto 0);
		debug_regfile_a3 : out std_logic_vector(31 downto 0);
		debug_regfile_a4 : out std_logic_vector(31 downto 0);
		debug_regfile_a5 : out std_logic_vector(31 downto 0);
		debug_regfile_a6 : out std_logic_vector(31 downto 0);
		debug_regfile_a7 : out std_logic_vector(31 downto 0);
		debug_regfile_we : out std_logic;
		debug_regfile_waddr : out std_logic_vector(3 downto 0);
		debug_regfile_wdata : out std_logic_vector(31 downto 0);
		debug_trap_illegal : out std_logic;
		debug_trap_priv : out std_logic;
		debug_trap_addr_error : out std_logic;
		debug_trap_berr : out std_logic;
		debug_trap_mmu_berr : out std_logic;
		debug_trap_vector : out std_logic_vector(31 downto 0);
		debug_pc_add : out std_logic_vector(31 downto 0);
		debug_pc_dataa : out std_logic_vector(31 downto 0);
		debug_pc_datab : out std_logic_vector(31 downto 0);
		debug_pmmu_busy : out std_logic;
		debug_cpu_halted : out std_logic;
		debug_stop : out std_logic;
		debug_interrupt : out std_logic;
		debug_setendOPC : out std_logic;
		debug_IPL_nr : out std_logic_vector(2 downto 0);
		debug_micro_state : out integer range 0 to 255;
		debug_next_micro_state : out integer range 0 to 255;
		debug_memmask : out std_logic_vector(5 downto 0);
		debug_sndOPC : out std_logic_vector(15 downto 0);
		debug_pmmu_reg_we : out std_logic;
		debug_pmmu_reg_re : out std_logic;
		debug_pmmu_reg_sel : out std_logic_vector(4 downto 0);
		debug_pmmu_reg_wdat : out std_logic_vector(31 downto 0);
		debug_pmmu_reg_part : out std_logic;
		debug_pmmu_reg_rdat : out std_logic_vector(31 downto 0);
		debug_make_berr : out std_logic;
		debug_pmmu_fault : out std_logic;
		debug_berr_exception_active : out std_logic;
		debug_pmmu_fault_dispatched : out std_logic;
		debug_pmmu_fault_was_cleared : out std_logic;
		debug_pmmu_fault_rw : out std_logic;
		debug_pmmu_fault_is_insn : out std_logic;
		debug_pmmu_fault_fc : out std_logic_vector(2 downto 0);
		debug_pmmu_fault_addr  : out std_logic_vector(31 downto 0);
		debug_pmmu_fault_mmusr : out std_logic_vector(15 downto 0);
		debug_trap_format_error : out std_logic;
		debug_format_error_rte_word : out std_logic_vector(15 downto 0);
		debug_format_error_pc : out std_logic_vector(31 downto 0);
		debug_format_error_addr : out std_logic_vector(31 downto 0);
		debug_format_error_sr : out std_logic_vector(7 downto 0);
		debug_pmmu_tc  : out std_logic_vector(31 downto 0);
		debug_pmmu_tt0 : out std_logic_vector(31 downto 0);
		debug_pmmu_tt1 : out std_logic_vector(31 downto 0);
		debug_pmmu_crp_hi : out std_logic_vector(31 downto 0);
		debug_pmmu_crp_lo : out std_logic_vector(31 downto 0);
		debug_pmmu_srp_hi : out std_logic_vector(31 downto 0);
		debug_pmmu_srp_lo : out std_logic_vector(31 downto 0);
		debug_pmmu_wstate : out std_logic_vector(4 downto 0);
		debug_pmmu_atc_buserr : out std_logic_vector(21 downto 0);
		debug_pmmu_atc_valid  : out std_logic_vector(21 downto 0);
			debug_pmmu_pending_flags : out std_logic_vector(15 downto 0);
			debug_pmmu_fault_status : out std_logic_vector(15 downto 0);
			debug_pmmu_saved_addr   : out std_logic_vector(31 downto 0);
			debug_pmmu_walk_desc_addr : out std_logic_vector(31 downto 0);
			debug_pmmu_walk_desc_data : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr1_desc_addr : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr1_desc_data : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr2_desc_addr : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr2_desc_data : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr3_desc_addr : out std_logic_vector(31 downto 0);
			debug_pmmu_ptr3_desc_data : out std_logic_vector(31 downto 0);
			debug_pmmu_saved_fc       : out std_logic_vector(2 downto 0);
		debug_make_trace         : out std_logic;
		debug_trace_pending_grp2 : out std_logic;
		debug_useStackframe2     : out std_logic;
		debug_exec_trap_chk      : out std_logic;
		debug_set_trap_chk       : out std_logic;
		debug_data_write_tmp     : out std_logic_vector(31 downto 0);
		debug_FlagsSR            : out std_logic_vector(7 downto 0);
		debug_USP                : out std_logic_vector(31 downto 0);
		debug_MSP                : out std_logic_vector(31 downto 0);
		debug_ISP                : out std_logic_vector(31 downto 0);
		debug_a7_is_msp          : out std_logic;
		debug_interrupt_mode     : out std_logic;
		debug_rte_saved_mbit     : out std_logic;
		debug_rte_format_word    : out std_logic_vector(15 downto 0);
		debug_rte_mmu_fix_ssw    : out std_logic_vector(15 downto 0);
		debug_rte_mmu_fix_opcode : out std_logic_vector(15 downto 0);
		debug_rte_mmu_fix_write  : out std_logic;
		debug_rte_fmt_a_state1 : out std_logic_vector(15 downto 0);
		debug_rte_fmt_a_ssw : out std_logic_vector(15 downto 0);
		debug_rte_fmt_a_fault_addr : out std_logic_vector(31 downto 0);
		debug_rte_fmt_a_data_out : out std_logic_vector(31 downto 0);
		debug_rte_fmt_a_replay_needed : out std_logic;
		debug_rte_format_b_version_error : out std_logic
			);
end TG68KdotC_Kernel;

architecture logic of TG68KdotC_Kernel is

	signal use_VBR_Stackframe	: std_logic;

	signal syncReset			: std_logic_vector(3 downto 0);
	signal Reset				: std_logic;
	signal clkena_lw			: std_logic;
	signal TG68_PC				: std_logic_vector(31 downto 0);
	signal tmp_TG68_PC		: std_logic_vector(31 downto 0);
	signal TG68_PC_add		: std_logic_vector(31 downto 0);
	signal PC_dataa			: std_logic_vector(31 downto 0);
	signal PC_datab			: std_logic_vector(31 downto 0);
	signal memaddr				: std_logic_vector(31 downto 0);
	signal state				: std_logic_vector(1 downto 0);
	signal datatype			: std_logic_vector(1 downto 0);
	signal set_datatype		: std_logic_vector(1 downto 0);
	signal exe_datatype		: std_logic_vector(1 downto 0);
	signal setstate			: std_logic_vector(1 downto 0);
	signal setaddrvalue		: std_logic;
	signal addrvalue			: std_logic;

	signal opcode				: std_logic_vector(15 downto 0);
	signal exe_opcode			: std_logic_vector(15 downto 0);
	signal sndOPC				: std_logic_vector(15 downto 0);

	signal exe_pc				: std_logic_vector(31 downto 0);
	signal opcode_pc			: std_logic_vector(31 downto 0);
	signal last_opc_pc		: std_logic_vector(31 downto 0);
	signal last_opc_read		: std_logic_vector(15 downto 0);
	signal registerin			: std_logic_vector(31 downto 0);
	signal reg_QA				: std_logic_vector(31 downto 0);
	signal reg_QB				: std_logic_vector(31 downto 0);
	signal Wwrena,Lwrena		: bit;
	signal Bwrena				: bit;
	signal Regwrena_now		: bit;
	signal rf_dest_addr		: std_logic_vector(3 downto 0);
	signal rf_source_addr	: std_logic_vector(3 downto 0);
	signal rf_source_addrd	: std_logic_vector(3 downto 0);

	signal regin				: std_logic_vector(31 downto 0);
	type   regfile_t is array(0 to 15) of std_logic_vector(31 downto 0);
	signal regfile				: regfile_t := (OTHERS => (OTHERS => '0'));
	signal regfile_shadow		: regfile_t := (OTHERS => (OTHERS => '0'));
	signal flags_shadow		: std_logic_vector(7 downto 0) := (OTHERS => '0');
	signal berr_restart_pc		: std_logic_vector(31 downto 0) := (OTHERS => '0');
	signal mmu_restart_pending	: std_logic;
	signal mmu_restart_restore	: std_logic;
	signal mmu_restart_active	: std_logic;
	signal mmu_restart_restore_now	: std_logic;
	signal pmmu_fault_restart_live	: std_logic;
	signal insn_fetch_consumer	: std_logic;
	signal berr_stack_fetch_squash	: std_logic;
	signal rte_b_resume_refetch	: std_logic := '0';
	signal opc_buf_valid		: std_logic := '1';
	signal mmu_restart_soft	: std_logic;
	signal pmmu_fault_restart_dispatch : std_logic;
	signal berr_pmmu_fault_lastwrite : std_logic;
	signal berr_pmmu_fault_from_rte_replay : std_logic;
	signal RDindex_A			: integer range 0 to 15;
	signal RDindex_B			: integer range 0 to 15;
	signal WR_AReg				: std_logic;

	signal addr					: std_logic_vector(31 downto 0);
	signal memaddr_reg		: std_logic_vector(31 downto 0);
	signal memaddr_delta		: std_logic_vector(31 downto 0);
	signal memaddr_delta_rega	: std_logic_vector(31 downto 0);
	signal memaddr_delta_regb	: std_logic_vector(31 downto 0);
	signal use_base			: bit;

	signal ea_data				: std_logic_vector(31 downto 0);
	signal OP1out				: std_logic_vector(31 downto 0);
	signal OP2out				: std_logic_vector(31 downto 0);
	signal OP1outbrief		: std_logic_vector(15 downto 0);
	signal OP1in				: std_logic_vector(31 downto 0);
	signal ALUout	: std_logic_vector(31 downto 0);
	signal data_write_tmp	: std_logic_vector(31 downto 0);
	signal data_write_muxin	: std_logic_vector(31 downto 0);
	signal nextpass			: bit;
	signal setnextpass		: bit;
	signal setdispbyte		: bit;
	signal setdisp				: bit;
	signal regdirectsource	:bit;
	signal addsub_q			: std_logic_vector(31 downto 0);
	signal briefdata			: std_logic_vector(31 downto 0);
	signal c_out				: std_logic_vector(2 downto 0);

	signal mem_address		: std_logic_vector(31 downto 0);
	signal memaddr_a			: std_logic_vector(31 downto 0);

	signal pmove_disp_latched : std_logic_vector(31 downto 0);
	signal pmove_ea_latched	: std_logic_vector(31 downto 0);
	signal pmove_ea_captured : std_logic := '0';

	signal TG68_PC_brw		: bit;
	signal TG68_PC_word		: bit;
	signal getbrief			: bit;
	signal movec_regsel     : std_logic_vector(11 downto 0);
	signal brief				: std_logic_vector(15 downto 0);
	signal data_is_source	: bit;
	signal store_in_tmp		: bit;
	signal write_back			: bit;
	signal exec_write_back	: bit;
	signal setstackaddr		: bit;
	signal writePC				: bit;
	signal writePCbig			: bit;
	signal set_writePCbig	: bit;
	signal writePCnext		: bit;
	signal setopcode			: bit;
	signal decodeOPC			: bit;
	signal execOPC				: bit;
	signal execOPC_ALU		: bit;
	signal setexecOPC			: bit;
	signal endOPC				: bit;
	signal setendOPC			: bit;
	signal Flags				: std_logic_vector(7 downto 0);
	signal FlagsSR				: std_logic_vector(7 downto 0);
	signal SRin					: std_logic_vector(7 downto 0);
	constant SR_trace_mask : std_logic_vector(7 downto 0) := "00111111";
	constant RTE_030_FORMAT_B_VERSION : std_logic_vector(3 downto 0) := "0000";
	signal exec_DIRECT		: bit;
	signal exec_tas			: std_logic;
	signal set_exec_tas		: std_logic;
	signal exec_cas			: std_logic;
	signal set_exec_cas		: std_logic;
	signal locked_rmw_active : std_logic;
	signal pmmu_fault_effective_rw : std_logic;
	signal pmmu_fault_lastwrite_ok : std_logic;

	signal exe_condition		: std_logic;
	signal ea_only				: bit;
	signal source_areg		: std_logic;
	signal source_lowbits	: bit;
	signal moves_bus_pending : std_logic := '0';
	signal moves_fc_override : std_logic := '0';
	signal moves_ea_areg     : std_logic := '0';
	signal moves_ea_regnum   : std_logic_vector(2 downto 0) := "000";
	signal moves_d16_phase   : std_logic := '0';
	signal moves_writeback_pending : std_logic := '0';
	signal moves_active : std_logic := '0';
	signal moves_direction : std_logic := '0';
	signal moves_reg : std_logic_vector(3 downto 0) := "0000";
	signal moves_ea_latched : std_logic_vector(31 downto 0) := (others => '0');
	signal moves_ea_use_base : bit := '0';
	signal source_LDRLbits 	: bit;
	signal source_LDRMbits 	: bit;
	signal source_2ndHbits	: bit;
	signal source_2ndMbits	: bit;
	signal source_2ndLbits	: bit;
	signal dest_areg			: std_logic;
	signal dest_LDRareg		: std_logic;
	signal dest_LDRHbits		: bit;
	signal dest_LDRLbits		: bit;
	signal dest_2ndHbits		: bit;
	signal dest_2ndLbits		: bit;
	signal dest_hbits			: bit;
	signal rot_bits			: std_logic_vector(1 downto 0);
	signal set_rot_bits		: std_logic_vector(1 downto 0);
	signal rot_cnt				: std_logic_vector(5 downto 0);
	signal set_rot_cnt		: std_logic_vector(5 downto 0);
	signal movem_actiond		: bit;
	signal movem_regaddr		: std_logic_vector(3 downto 0);
	signal movem_mux			: std_logic_vector(3 downto 0);
	signal movem_presub		: bit;
	signal movem_run			: bit;
	signal ea_calc_b			: std_logic_vector(31 downto 0);
	signal set_direct_data	: bit;
	signal use_direct_data	: bit;
	signal direct_data		: bit;

	signal set_V_Flag			: bit;
	signal set_vectoraddr	: bit;
	signal writeSR				: bit;
	signal trap_berr			: bit;
	signal trap_illegal		: bit;
	signal trap_addr_error	: bit;
	signal trap_priv			: bit;
	signal trap_trace			: bit;
	signal trap_1010			: bit;
	signal trap_1111			: bit;
	signal trap_trap			: bit;
	signal trap_trapv			: bit;
	signal trap_interrupt	: bit;
	signal trap_mmu_config	: bit;
	signal trap_mmu_berr    : bit;
	signal trap_format_error : bit;
	signal rte_format_word  : std_logic_vector(15 downto 0);
	signal rte_saved_mbit   : std_logic;
	signal rte_saved_sr_high : std_logic_vector(7 downto 0);
	signal rte_saved_a7     : std_logic_vector(31 downto 0);
	signal a7_is_msp        : std_logic;
	signal rte_saved_ccr    : std_logic_vector(7 downto 0);
	signal rte_mmu_fix_capture_active : std_logic := '0';
	signal rte_mmu_fix_armed : std_logic := '0';
	signal rte_mmu_fix_long_index : integer range 0 to 31 := 0;
	signal rte_mmu_fix_ssw : std_logic_vector(15 downto 0) := (others => '0');
	signal rte_mmu_fix_opcode : std_logic_vector(15 downto 0) := (others => '0');
	signal rte_mmu_fix_input_buffer : std_logic_vector(31 downto 0) := (others => '0');
	signal rte_mmu_fix_write : std_logic := '0';
	signal rte_mmu_fix_commit : std_logic := '0';
	signal rte_mmu_fix_ccr_update : std_logic := '0';
	signal rte_mmu_fix_ccr_value : std_logic_vector(7 downto 0) := (others => '0');
	signal rte_mmu_fix_dest : std_logic_vector(2 downto 0) := (others => '0');
	signal rte_mmu_fix_size : std_logic_vector(1 downto 0) := (others => '0');
	signal rte_mmu_fix_len  : std_logic_vector(2 downto 0) := "010";
	signal rte_mmu_fix_is_tst : std_logic := '0';
	signal rte_mmu_fix_faddr	: std_logic_vector(31 downto 0) := (others => '0');
	signal dib_sub_valid		: std_logic := '0';
	signal dib_sub_fresh		: std_logic := '0';
	signal bus_beat_poisoned	: std_logic := '0';
	signal bus_datum_dirty		: std_logic := '0';
	signal ea_to_pc_datum_invalid : std_logic := '0';
	signal directpc_retry_hold : std_logic := '0';
	signal dib_sub_addr		: std_logic_vector(31 downto 0) := (others => '0');
	signal dib_sub_data		: std_logic_vector(31 downto 0) := (others => '0');
	signal dib_sub_hit		: std_logic;
	signal dib_sub_rw		: std_logic := '1';
	signal dib_sub_pre		: std_logic;
	signal rte_format_b_version_error : std_logic := '0';
	signal rte_fmt_a_capture_active : std_logic := '0';
	signal rte_fmt_a_long_index : integer range 0 to 7 := 0;
	signal rte_fmt_a_state1 : std_logic_vector(15 downto 0) := (others => '0');
	signal rte_fmt_a_ssw : std_logic_vector(15 downto 0) := (others => '0');
	signal rte_fmt_a_fault_addr : std_logic_vector(31 downto 0) := (others => '0');
	signal rte_fmt_a_data_out : std_logic_vector(31 downto 0) := (others => '0');
	signal rte_fmt_a_replay_needed : std_logic := '0';
	signal rte_fmt_a_replay_size : std_logic_vector(1 downto 0) := "10";
	signal restore_ccr_sig  : std_logic;
	signal restore_ccr_value_mux : std_logic_vector(7 downto 0);
	signal fmt_err_latched       : std_logic;
	signal fmt_err_rte_word      : std_logic_vector(15 downto 0);
	signal fmt_err_pc            : std_logic_vector(31 downto 0);
	signal fmt_err_addr          : std_logic_vector(31 downto 0);
	signal fmt_err_sr            : std_logic_vector(7 downto 0);
	signal trapmake			: bit;
	signal trapd				: bit;
	signal trap_SR				: std_logic_vector(7 downto 0);
	signal trap_pc_latched		: std_logic_vector(31 downto 0) := (others => '0');
	signal make_trace			: std_logic;
	signal make_trace_t0		: std_logic;
	signal dbcc_t0_suppress	: std_logic := '0';
	signal trace_pending_group2	: std_logic;
	signal trace_group2_sr		: std_logic_vector(7 downto 0) := (others => '0');
	signal make_berr			: std_logic;
	signal make_mmu_berr     : std_logic;
	signal berr_exception_active : std_logic;
	signal cpu_halted        : std_logic;
	signal pmmu_fault_dispatched : std_logic;
	signal pmmu_fault_was_cleared : std_logic;
	signal berr_fault_addr   : std_logic_vector(31 downto 0);
	signal berr_frame_pc     : std_logic_vector(31 downto 0);
	signal stream_consumed_pc : std_logic_vector(31 downto 0) := (others => '0');
	signal insn_next_pc : std_logic_vector(31 downto 0) := (others => '0');
	signal berr_pmmu_fault_next_pc : std_logic_vector(31 downto 0) := (others => '0');
	signal berr_opcode_saved : std_logic_vector(15 downto 0);
	signal berr_ssw          : std_logic_vector(15 downto 0);
	signal berr_data_out_saved : std_logic_vector(31 downto 0);
	signal berr_pmmu_write_data : std_logic_vector(31 downto 0);
	signal berr_long_frame   : std_logic;
	signal berr_external_rw       : std_logic;
	signal berr_external_fc       : std_logic_vector(2 downto 0);
	signal berr_external_datatype : std_logic_vector(1 downto 0);
	signal berr_external_siz      : std_logic_vector(1 downto 0);
	signal berr_external_rmw      : std_logic;
	signal berr_pmmu_datatype     : std_logic_vector(1 downto 0);
	signal berr_pmmu_fault_addr   : std_logic_vector(31 downto 0);
	signal berr_pmmu_fault_fc     : std_logic_vector(2 downto 0);
	signal berr_pmmu_fault_rw     : std_logic;
	signal berr_pmmu_fault_rmw    : std_logic;
	signal berr_pmmu_fault_is_insn : std_logic;
	signal berr_pmmu_fault_valid  : std_logic;
	signal berr_external_addr    : std_logic_vector(31 downto 0);
	signal useStackframe2	: std_logic;

	signal set_stop			: bit;
	signal stop					: bit;
	signal trap_vector		: std_logic_vector(31 downto 0);
	signal trap_vector_vbr	: std_logic_vector(31 downto 0);
	signal trap_vector_latched : std_logic_vector(31 downto 0);
	signal USP					: std_logic_vector(31 downto 0);
	signal SSP					: std_logic_vector(31 downto 0);
	signal MSP					: std_logic_vector(31 downto 0);
	signal ISP					: std_logic_vector(31 downto 0);
	signal interrupt_mode		: std_logic := '0';
	signal interrupt_mode_set_req : std_logic := '0';
	signal interrupt_mode_clr_req : std_logic := '0';
	signal format1_chain_active : std_logic := '0';

	signal IPL_nr				: std_logic_vector(2 downto 0);
	signal rIPL_nr				: std_logic_vector(2 downto 0);
	signal IPL_vec				: std_logic_vector(7 downto 0);
	signal interrupt			: bit;
	signal setinterrupt		: bit;
	signal SVmode				: std_logic;
	signal preSVmode			: std_logic;
	signal Suppress_Base		: bit;
	signal set_Suppress_Base: bit;
	signal set_Z_error 		: bit;
	signal Z_error 			: bit;
	signal ea_build_now		: bit;
	signal build_logical		: bit;
	signal build_bcd			: bit;

	signal data_read			: std_logic_vector(31 downto 0);
	signal bf_ext_in			: std_logic_vector(7 downto 0);
	signal bf_ext_out			: std_logic_vector(7 downto 0);
	signal long_start			: bit;
	signal long_start_alu	: bit;
	signal non_aligned		: std_logic;
	signal check_aligned		: std_logic;
	signal long_done			: bit;
	signal memmask				: std_logic_vector(5 downto 0);
	signal set_memmask		: std_logic_vector(5 downto 0);
	signal memread				: std_logic_vector(3 downto 0);
	signal wbmemmask			: std_logic_vector(5 downto 0);
	signal memmaskmux			: std_logic_vector(5 downto 0);
	signal beat_rem				: integer range 0 to 5;
	signal beat_n				: integer range 0 to 4;
	signal beat_step			: std_logic_vector(2 downto 0);
	signal op5					: std_logic;
	signal op5_now				: std_logic;
	signal op_size				: integer range 0 to 5;
	signal byte_in				: std_logic_vector(7 downto 0);
	signal bus_in				: std_logic_vector(31 downto 0);
	signal bus_out				: std_logic_vector(31 downto 0);
	signal lane_in				: std_logic_vector(31 downto 0);
	signal first_lane			: integer range 0 to 3;
	signal port_room			: integer range 1 to 4;
	signal lane_raw				: std_logic_vector(31 downto 0);
	signal clkena_core			: std_logic;
	signal busstate_raw			: std_logic_vector(1 downto 0);
	signal fetch_hit			: std_logic;
	signal fetch_bus			: std_logic;
	signal fetch_ok				: std_logic;
	signal fetch_done			: integer range 0 to 4;
	signal fetch_n				: integer range 0 to 4;
	signal fetch_room			: integer range 1 to 4;
	signal fetch_first			: integer range 0 to 3;
	signal fetch_a10			: std_logic_vector(1 downto 0);
	signal fetch_lane			: std_logic_vector(31 downto 0);
	signal fetch_buf			: std_logic_vector(31 downto 0);
	signal fetch_long			: std_logic_vector(31 downto 0);
	signal fetch_word			: std_logic_vector(15 downto 0);
	signal hold_valid			: std_logic;
	signal hold_addr			: std_logic_vector(31 downto 2);
	signal hold_data			: std_logic_vector(31 downto 0);
	signal addr_xlat			: std_logic_vector(31 downto 0);
	signal oddout				: std_logic;
	signal set_oddout			: std_logic;
	signal PCbase				: std_logic;
	signal set_PCbase			: std_logic;

	signal last_data_read	: std_logic_vector(31 downto 0);
	signal last_data_in		: std_logic_vector(31 downto 0);

	signal bf_offset			: std_logic_vector(5 downto 0);
	signal bf_width			: std_logic_vector(5 downto 0);
	signal bf_bhits			: std_logic_vector(5 downto 0);
	signal bf_shift			: std_logic_vector(5 downto 0);
	signal alu_width			: std_logic_vector(5 downto 0);
	signal alu_bf_shift		: std_logic_vector(5 downto 0);
	signal bf_loffset			: std_logic_vector(5 downto 0);
	signal bf_full_offset	: std_logic_vector(31 downto 0);
	signal alu_bf_ffo_offset: std_logic_vector(31 downto 0);
	signal alu_bf_loffset	: std_logic_vector(5 downto 0);

	signal movec_data			: std_logic_vector(31 downto 0);
	signal VBR					: std_logic_vector(31 downto 0);
	signal CACR					: std_logic_vector(31 downto 0);
	signal CAAR                : std_logic_vector(31 downto 0);
	signal DFC					: std_logic_vector(2 downto 0);
	signal SFC					: std_logic_vector(2 downto 0);

	signal pmmu_reg_rdat    : std_logic_vector(31 downto 0);
	signal pmmu_src_data    : std_logic_vector(31 downto 0);
	signal pmmu_dn_data     : std_logic_vector(31 downto 0);
	signal pmove_dn_regnum  : std_logic_vector(2 downto 0);
	signal pmove_dn_areg    : std_logic;
	signal pmove_dn_mode    : std_logic;
	signal pmove_mmu_read_active : std_logic;
	signal pmmu_rd_carry : bit;
	signal fline_opcode_latch  : std_logic_vector(15 downto 0) := (others => '0');
	signal fline_opcode_pc     : std_logic_vector(31 downto 0) := (others => '0');
	signal fline_brief_latch   : std_logic_vector(15 downto 0) := (others => '0');
	signal fline_context_valid : std_logic := '0';
	signal fline_is_pmmu       : std_logic := '0';
	signal fline_is_fpu        : std_logic := '0';
	signal fline_has_brief     : std_logic := '0';
	signal cp_cir_next  : std_logic;
	signal cp_cir_off   : std_logic_vector(4 downto 0);
	signal cp_wdata     : std_logic_vector(31 downto 0);
	signal cp_cir       : std_logic := '0';
	signal cp_prim      : std_logic_vector(15 downto 0) := (others => '0');
	signal cp_pcdone    : std_logic := '0';
	signal trap_cp      : bit;
	signal cp_trap_pc   : std_logic := '0';
	signal cp_br_sel    : std_logic;
	signal cp_br_disp   : std_logic_vector(31 downto 0);
	signal cp_mem_next  : std_logic;
	signal cp_reg_we    : std_logic;
	signal cp_reg_n     : std_logic_vector(3 downto 0);
	signal cp_reg_d     : std_logic_vector(31 downto 0);
	signal cp_ea        : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_len       : std_logic_vector(7 downto 0) := (others => '0');
	signal cp_part      : std_logic_vector(2 downto 0);
	signal cp_psize     : std_logic_vector(1 downto 0);
	signal cp_psize0    : std_logic_vector(1 downto 0);
	signal cp_data      : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_w         : std_logic_vector(15 downto 0) := (others => '0');
	signal cp_wh        : std_logic_vector(15 downto 0) := (others => '0');
	signal cp_pcbase    : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_anew      : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_mm        : std_logic := '0';
	signal cp_mmcnt     : std_logic_vector(3 downto 0) := (others => '0');
	signal cp_mmbase    : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_half      : std_logic := '0';
	signal cp_an        : std_logic_vector(31 downto 0);
	signal cp_xn        : std_logic_vector(31 downto 0);
	signal cp_ea_ok     : std_logic;
	signal cp_pv        : std_logic;
	signal cp_ss        : std_logic;
	signal cp_frcp      : std_logic;
	signal cp_badlen    : std_logic;
	signal trap_cpfmt   : bit;
	signal cp_scc       : std_logic;
	signal trap_cptrap  : bit;
	signal cp_trap2     : std_logic := '0';
	signal cp_npc       : std_logic_vector(31 downto 0) := (others => '0');
	signal trap_cp9     : bit;
	signal trap_cppv    : bit;
	signal cp_f9        : std_logic := '0';
	signal cp_scanpc    : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_tea       : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_tea_ld    : std_logic := '0';
	signal cp_irq_take  : std_logic;
	signal cp_init      : std_logic := '0';
	signal cp_nocp      : std_logic;
	signal berr_k       : std_logic;
	signal cp_cof       : std_logic := '0';
	signal cp_bf_now    : std_logic;
	signal cp_pmmu_f    : std_logic;
	signal cp_bfr       : std_logic := '0';
	signal cp_bk_st     : std_logic_vector(4 downto 0) := (others => '0');
	signal cp_bk_ss     : std_logic_vector(1 downto 0) := (others => '0');
	signal cp_bk_dt     : std_logic_vector(1 downto 0) := (others => '0');
	signal cp_bk_cir    : std_logic := '0';
	signal cp_bk_mem    : std_logic := '0';
	signal cp_bk_off    : std_logic_vector(4 downto 0) := (others => '0');
	signal cp_bk_wd     : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_bk_pc     : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_rb        : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_rb_prim   : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_rb_wd, cp_rb_ea, cp_rb_data, cp_rb_anew, cp_rb_mmb, cp_rb_iw, cp_rb_opc, cp_rb_w,
	       cp_rb_pcb, cp_rb_tea, cp_rb_spc : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_twait     : std_logic;
	signal cp_rte_pc    : std_logic_vector(31 downto 0) := (others => '0');
	signal cp_rte_iw    : std_logic_vector(31 downto 0) := (others => '0');
	signal pmmu_ea_mode_latched  : std_logic_vector(5 downto 0);
	signal pmmu_brief          : std_logic_vector(15 downto 0);
	signal pmmu_opcode         : std_logic_vector(15 downto 0);
	signal pmmu_reg_part_d  : std_logic;
	signal pmmu_reg_part_int : std_logic;
	signal pmmu_reg_we_d    : std_logic;
	signal pmmu_reg_re_d    : std_logic;
	signal pmmu_reg_sel_d   : std_logic_vector(4 downto 0);
	signal pmmu_reg_sel_int : std_logic_vector(4 downto 0);
	signal pmmu_reg_sel_valid : boolean;
	signal pmmu_reg_wdat_d  : std_logic_vector(31 downto 0);
	signal pmmu_reg_fd_d    : std_logic;

	signal dbg_brief_capture : std_logic_vector(15 downto 0);
	signal dbg_pmmu_reg_sel_when_set : std_logic_vector(4 downto 0);
	signal dbg_brief_when_sel_set : std_logic_vector(15 downto 0);

	signal pmmu_req         : std_logic;
	signal pmmu_is_insn     : std_logic;
	signal pmmu_rw          : std_logic;
	signal pmmu_rmw         : std_logic;
	signal pmmu_fc          : std_logic_vector(2 downto 0);
	signal pmmu_fc_from_dn  : std_logic_vector(2 downto 0);
	signal pmmu_addr_log_int : std_logic_vector(31 downto 0);
	signal pmmu_addr_phys_int : std_logic_vector(31 downto 0);
	signal pmmu_desc_addr : std_logic_vector(31 downto 0);
	signal pmmu_debug_mmusr : std_logic_vector(15 downto 0);
	signal pmmu_ptest_a : std_logic;

	signal cache_op_scope_int : std_logic_vector(1 downto 0);
	signal cache_op_cache_int : std_logic_vector(1 downto 0);
	signal pmmu_ch_inhibit  : std_logic;
	signal pmmu_wr_protect  : std_logic;
	signal pmmu_fault       : std_logic;
	signal pmmu_fault_stat  : std_logic_vector(31 downto 0);
	signal pmmu_fault_addr_out : std_logic_vector(31 downto 0);
	signal pmmu_fault_fc_out   : std_logic_vector(2 downto 0);
	signal pmmu_fault_rw_out   : std_logic;
	signal pmmu_fault_is_insn_out : std_logic;
	signal pmmu_pending_flags : std_logic_vector(15 downto 0);
	signal pmmu_tc_en       : std_logic;

	signal pmmu_ptest_req   : std_logic;
	signal pmmu_pflush_req  : std_logic;
	signal pmmu_pload_req   : std_logic;
	signal pmmu_cmd_fc      : std_logic_vector(2 downto 0);
	signal pmmu_cmd_addr    : std_logic_vector(31 downto 0);
	signal pmmu_cmd_rw      : std_logic;
	signal pmmu_cmd_brief   : std_logic_vector(15 downto 0);

	signal pmmu_mem_req   : std_logic;
	signal pmmu_mem_we    : std_logic;
	signal pmmu_mem_addr  : std_logic_vector(31 downto 0);
	signal pmmu_mem_wdat  : std_logic_vector(31 downto 0);
	signal pmmu_mem_ack   : std_logic;
	signal pmmu_mem_berr  : std_logic;
	signal pmmu_mem_rdat  : std_logic_vector(31 downto 0);
	signal pmmu_busy      : std_logic;
	signal pmmu_config_err : std_logic;
	signal pmmu_config_ack : std_logic;
	signal pmmu_cpu_reset : std_logic;

	signal fc_internal    : std_logic_vector(2 downto 0);

	signal set					: bit_vector(lastOpcBit downto 0);
	signal set_exec			: bit_vector(lastOpcBit downto 0);
	signal exec					: bit_vector(lastOpcBit downto 0);

	signal micro_state		: micro_states;
	signal next_micro_state	: micro_states;
	signal next_micro_state_c	: micro_states;

	FUNCTION cp_st_enc(s : micro_states) RETURN std_logic_vector IS
	BEGIN
		CASE s IS
			WHEN cp_rsp   => RETURN "00001";
			WHEN cp_rspw  => RETURN "00010";
			WHEN cp_pcw   => RETURN "00011";
			WHEN cp_tsr   => RETURN "00100";
			WHEN cp_extw  => RETURN "00101";
			WHEN cp_extw2 => RETURN "00110";
			WHEN cp_dlw   => RETURN "00111";
			WHEN cp_imw   => RETURN "01000";
			WHEN cp_tsk   => RETURN "01001";
			WHEN cp_mrdw  => RETURN "01010";
			WHEN cp_oww   => RETURN "01011";
			WHEN cp_ordw  => RETURN "01100";
			WHEN cp_mww   => RETURN "01101";
			WHEN cp_rdreg => RETURN "01110";
			WHEN cp_rselw => RETURN "01111";
			WHEN cp_fmtw  => RETURN "10000";
			WHEN cp_sfw   => RETURN "10001";
			WHEN cp_rfr   => RETURN "10010";
			WHEN OTHERS   => RETURN "00000";
		END CASE;
	END FUNCTION;
	FUNCTION cp_st_dec(v : std_logic_vector(4 downto 0)) RETURN micro_states IS
	BEGIN
		CASE v IS
			WHEN "00001" => RETURN cp_rsp;
			WHEN "00010" => RETURN cp_rspw;
			WHEN "00011" => RETURN cp_pcw;
			WHEN "00100" => RETURN cp_tsr;
			WHEN "00101" => RETURN cp_extw;
			WHEN "00110" => RETURN cp_extw2;
			WHEN "00111" => RETURN cp_dlw;
			WHEN "01000" => RETURN cp_imw;
			WHEN "01001" => RETURN cp_tsk;
			WHEN "01010" => RETURN cp_mrdw;
			WHEN "01011" => RETURN cp_oww;
			WHEN "01100" => RETURN cp_ordw;
			WHEN "01101" => RETURN cp_mww;
			WHEN "01110" => RETURN cp_rdreg;
			WHEN "01111" => RETURN cp_rselw;
			WHEN "10000" => RETURN cp_fmtw;
			WHEN "10001" => RETURN cp_sfw;
			WHEN "10010" => RETURN cp_rfr;
			WHEN OTHERS  => RETURN cp_done;
		END CASE;
	END FUNCTION;

BEGIN

  pmmu_cpu_reset <= '0';

  PMMU_030: entity work.TG68K_PMMU_030
    port map(
      clk           => clk,
      nreset        => nReset,

      reg_we        => pmmu_reg_we_d,
      reg_re        => pmmu_reg_re_d,
      reg_sel       => pmmu_reg_sel_int,
      reg_wdat      => pmmu_src_data,
      reg_rdat      => pmmu_reg_rdat,
      reg_part      => pmmu_reg_part_int,
      reg_fd        => pmmu_reg_fd_d,

      ptest_req     => pmmu_ptest_req,
      pflush_req    => pmmu_pflush_req,
      pload_req     => pmmu_pload_req,
      pmmu_fc       => pmmu_cmd_fc,
      pmmu_addr     => pmmu_cmd_addr,
      pmmu_brief    => pmmu_brief,

      req           => pmmu_req,
      is_insn       => pmmu_is_insn,
      rw            => pmmu_rw,
      rmw           => pmmu_rmw,
      fc            => pmmu_fc,
      addr_log      => pmmu_addr_log_int,
      addr_phys     => pmmu_addr_phys_int,
      cache_inhibit => pmmu_ch_inhibit,
      write_protect => pmmu_wr_protect,
      fault         => pmmu_fault,
      fault_status  => pmmu_fault_stat,
      fault_addr    => pmmu_fault_addr_out,
      fault_fc      => pmmu_fault_fc_out,
      fault_rw      => pmmu_fault_rw_out,
      fault_is_insn => pmmu_fault_is_insn_out,
      tc_enable     => pmmu_tc_en,
      mem_req       => pmmu_mem_req,
      mem_we        => pmmu_mem_we,
      mem_addr      => pmmu_mem_addr,
      mem_wdat      => pmmu_mem_wdat,
      mem_ack       => pmmu_mem_ack,
      mem_berr      => pmmu_mem_berr,
      mem_rdat      => pmmu_mem_rdat,
      busy          => pmmu_busy,
      mmu_config_err => pmmu_config_err,
      mmu_config_ack => pmmu_config_ack,
      ptest_desc_addr => pmmu_desc_addr,
      debug_mmusr => pmmu_debug_mmusr,
      debug_tc    => debug_pmmu_tc,
      debug_tt0   => debug_pmmu_tt0,
      debug_tt1   => debug_pmmu_tt1,
      debug_crp_hi => debug_pmmu_crp_hi,
      debug_crp_lo => debug_pmmu_crp_lo,
      debug_srp_hi => debug_pmmu_srp_hi,
      debug_srp_lo => debug_pmmu_srp_lo,
      debug_wstate => debug_pmmu_wstate,
      debug_atc_buserr => debug_pmmu_atc_buserr,
      debug_atc_valid  => debug_pmmu_atc_valid,
      debug_pending_flags => pmmu_pending_flags,
      debug_fault_status => debug_pmmu_fault_status,
      debug_saved_addr   => debug_pmmu_saved_addr,
      debug_walk_desc_addr => debug_pmmu_walk_desc_addr,
      debug_walk_desc_data => debug_pmmu_walk_desc_data,
      debug_ptr1_desc_addr => debug_pmmu_ptr1_desc_addr,
      debug_ptr1_desc_data => debug_pmmu_ptr1_desc_data,
      debug_ptr2_desc_addr => debug_pmmu_ptr2_desc_addr,
      debug_ptr2_desc_data => debug_pmmu_ptr2_desc_data,
      debug_ptr3_desc_addr => debug_pmmu_ptr3_desc_addr,
      debug_ptr3_desc_data => debug_pmmu_ptr3_desc_data,
      debug_saved_fc       => debug_pmmu_saved_fc,
      debug_illegal_reg_sel => open,
      cpu_reset            => pmmu_cpu_reset
    );

  debug_pmmu_pending_flags <= pmmu_pending_flags;

  pmmu_brief  <= fline_brief_latch when fline_context_valid = '1' else brief;
  pmmu_opcode <= fline_opcode_latch when fline_context_valid = '1' else opcode;

  pmmu_reg_we   <= pmmu_reg_we_d when CPU(1) = '1' else '0';
  pmmu_reg_re   <= pmmu_reg_re_d when CPU(1) = '1'  else '0';
  pmmu_reg_sel_int <= pmmu_brief(14 downto 10) when CPU(1) = '1' AND
                          (set(pmmu_rd)='1' OR exec(pmmu_rd)='1' OR set(pmmu_wr)='1' OR
                           exec(pmmu_wr)='1' OR set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR
                           micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo OR
                           micro_state=pmove_mem_to_mmu_hi OR micro_state=pmove_mem_to_mmu_lo OR
                           next_micro_state_c=pmove_mmu_to_mem_hi OR next_micro_state_c=pmove_mmu_to_mem_lo OR
                           next_micro_state_c=pmove_mem_to_mmu_hi OR next_micro_state_c=pmove_mem_to_mmu_lo) else
                      pmmu_reg_sel_d when CPU(1) = '1' else
                      (others => '0');

  pmmu_ptest_a <= '1' when pmmu_brief(15 downto 13)="100" and pmmu_brief(8)='1' and
                           ((micro_state=ptest1 and pmmu_busy='0') or
                            (micro_state=pmmu_dn_read_wait and exec(Regwrena)='1'))
                  else '0';
  pmmu_reg_sel_valid <= true when (pmmu_reg_sel_int = "00010" OR pmmu_reg_sel_int = "00011" OR pmmu_reg_sel_int = "10000" OR
                                   pmmu_reg_sel_int = "10010" OR pmmu_reg_sel_int = "10011" OR pmmu_reg_sel_int = "11000")
                        else false;
  pmmu_reg_sel  <= pmmu_reg_sel_int;
  pmmu_reg_wdat <= pmmu_src_data when CPU(1) = '1'  else (others => '0');
  pmmu_reg_part <= pmmu_reg_part_int when CPU(1) = '1'  else '0';

  pmmu_addr_log  <= pmmu_addr_log_int;
  pmmu_addr_phys <= pmmu_addr_phys_int;

  pmmu_ptest_req  <= '1' when set(pmmu_ptest) = '1' else '0';
  pmmu_pflush_req <= '1' when set(pmmu_pflush) = '1' else '0';
  pmmu_pload_req  <= '1' when set(pmmu_pload) = '1' else '0';

  pmmu_reg_we_d <= '1' when CPU(1)='1' AND set_exec(pmmu_wr)='1' AND pmmu_reg_sel_valid
                         AND clkena_lw='1'
                   else '0';
  pmmu_reg_re_d <= '1' when CPU(1)='1' AND (set(pmmu_rd)='1' OR exec(pmmu_rd)='1' OR set_exec(pmmu_rd)='1') AND pmmu_reg_sel_valid
	                   else '0';

  pmmu_reg_part_int <= '1' when CPU(1)='1' AND
                                (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011") AND
                                (micro_state = pmove_mem_to_mmu_hi OR
                                 micro_state = pmove_mmu_to_mem_hi OR
                                 micro_state = pmove_dn_hi OR
                                 (micro_state = pmove_decode AND pmmu_opcode(5 downto 3) = "000"))
                       else '0' when CPU(1)='1' AND
                                     (pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011") AND
                                     (micro_state = pmove_mem_to_mmu_lo OR
                                      micro_state = pmove_mmu_to_mem_lo OR
                                      micro_state = pmove_dn_lo)
                       else pmmu_reg_part_d;

  pmove_mmu_read_active <= '1' when (micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo
                                     OR next_micro_state_c=pmove_mmu_to_mem_hi OR next_micro_state_c=pmove_mmu_to_mem_lo)
                           else '0';

  pmmu_cmd_fc     <= pmmu_brief(2 downto 0) when ((set(pmmu_ptest) = '1' or set(pmmu_pload) = '1' or
                                              (set(pmmu_pflush) = '1' and pmmu_brief(12 downto 10) /= "001"))
                                              and pmmu_brief(4 downto 3) = "10")
                     else pmmu_fc_from_dn when ((set(pmmu_ptest) = '1' or set(pmmu_pload) = '1' or
                                    (set(pmmu_pflush) = '1' and pmmu_brief(12 downto 10) /= "001"))
                                    and pmmu_brief(4 downto 3) = "01")
                     else SFC when ((set(pmmu_ptest) = '1' or set(pmmu_pload) = '1' or
                                    (set(pmmu_pflush) = '1' and pmmu_brief(12 downto 10) /= "001"))
                                    and pmmu_brief(4 downto 3) = "00" and pmmu_brief(0) = '0')
                     else DFC when ((set(pmmu_ptest) = '1' or set(pmmu_pload) = '1' or
                                    (set(pmmu_pflush) = '1' and pmmu_brief(12 downto 10) /= "001"))
                                    and pmmu_brief(4 downto 3) = "00" and pmmu_brief(0) = '1')
                     else fc_internal;

  pmmu_cmd_addr   <= OP1out when (set(pmmu_ptest) = '1' or set(pmmu_pload) = '1' or set(pmmu_pflush) = '1')
                     else pmmu_addr_log_int;

  cache_inv_req  <= '1' when (CACR(2) = '1' or CACR(3) = '1' or CACR(10) = '1' or CACR(11) = '1') else '0';

  process(CACR)
  begin
    if CACR(3) = '1' then
      cache_op_scope_int <= "10";
      cache_op_cache_int <= "10";
    elsif CACR(11) = '1' then
      cache_op_scope_int <= "10";
      cache_op_cache_int <= "01";
    elsif CACR(2) = '1' then
      cache_op_scope_int <= "00";
      cache_op_cache_int <= "10";
    elsif CACR(10) = '1' then
      cache_op_scope_int <= "00";
      cache_op_cache_int <= "01";
    else
      cache_op_scope_int <= "10";
      cache_op_cache_int <= "00";
    end if;
  end process;

  cache_op_scope <= cache_op_scope_int;
  cache_op_cache <= cache_op_cache_int;

  cache_op_addr <= CAAR when (CACR(2) = '1' or CACR(10) = '1') else pmmu_addr_phys_int;

  pmmu_cache_inhibit <= pmmu_ch_inhibit;
  rmc_out <= pmmu_rmw;
  wronly_rd_out <= '1' when state = "10" and exec_write_back = '1' and berr_exception_active = '0' and
                          (opcode(15 downto 8) = X"42" or
                           opcode(15 downto 6) = "0100000011" or
                           (opcode(15 downto 12) = "0101" and opcode(7 downto 6) = "11"))
                   else '0';

  cacr_ie     <= CACR(0);
  cacr_ifreeze <= CACR(1);
  cacr_ibe    <= CACR(4);
  cacr_de     <= CACR(8);
  cacr_dfreeze <= CACR(9);
  cacr_dbe    <= CACR(12);
  cacr_wa     <= CACR(13);
  pmmu_dn_data <= regfile(conv_integer('0' & pmmu_opcode(2 downto 0))) when (micro_state = pmove_decode AND pmmu_opcode(5 downto 3) = "000") else
                  regfile(conv_integer('1' & pmmu_opcode(2 downto 0))) when (micro_state = pmove_decode AND pmmu_opcode(5 downto 3) = "001") else
                  regfile(conv_integer(pmove_dn_areg & pmove_dn_regnum));

  pmmu_src_data   <= data_read when (micro_state = pmove_mem_to_mmu_hi or micro_state = pmove_mem_to_mmu_lo) else
                     pmmu_dn_data;

  pmmu_req      <= '1' when (state /= "01" and pmmu_tc_en = '1'
                             and (mmu_restart_pending = '0' or mmu_restart_soft = '1')
                             and not (state = "00" and TG68_PC(0) = '1')
                             and not (state = "00" and berr_stack_fetch_squash = '1')
                             and not (pmmu_addr_log_int(31 downto 16) = x"00DD" and
                                      pmmu_addr_log_int(15 downto 13) = "010")) else '0';
  pmmu_is_insn  <= '1' when state = "00" else '0';
  pmmu_rw       <= '0' when state = "11" else '1';
  locked_rmw_active <= '1' when berr_exception_active = '0' and
                                (exec_tas = '1' or set_exec_tas = '1' or
                                 exec_cas = '1' or set_exec_cas = '1' or
                                 micro_state = cas1 or micro_state = cas2 or
                                 micro_state = cas21 or micro_state = cas22 or
                                 micro_state = cas23 or micro_state = cas24 or
                                 micro_state = cas25 or micro_state = cas26 or
                                 micro_state = cas27 or micro_state = cas28)
                       else '0';
  pmmu_rmw      <= '1' when locked_rmw_active = '1' and state(1) = '1' else '0';
  pmmu_fc       <= rte_fmt_a_ssw(2 downto 0)
                     when micro_state = rte_mmu_replay
                     else "111" when cp_cir = '1'
                     else fc_internal;

  pmmu_fc_from_dn <= regfile(conv_integer(pmmu_brief(2 downto 0)))(2 downto 0);

  pmmu_walker_req  <= pmmu_mem_req;
  pmmu_walker_we   <= pmmu_mem_we;
  pmmu_walker_addr <= pmmu_mem_addr;
  pmmu_walker_wdat <= pmmu_mem_wdat;
  pmmu_mem_ack     <= pmmu_walker_ack;
  pmmu_mem_rdat    <= pmmu_walker_data;
  pmmu_mem_berr    <= pmmu_walker_berr;

  restore_ccr_sig <= '1' WHEN mmu_restart_restore_now='1' OR trap_format_error='1' OR rte_mmu_fix_ccr_update='1' ELSE '0';
  restore_ccr_value_mux <= flags_shadow WHEN mmu_restart_restore_now='1' ELSE
                           rte_mmu_fix_ccr_value WHEN rte_mmu_fix_ccr_update='1' ELSE
                           rte_saved_ccr;

ALU: TG68K_ALU
	generic map(
		MUL_Mode => MUL_Mode,
		MUL_Hardware => MUL_Hardware,
		DIV_Mode => DIV_Mode,
		BarrelShifter => BarrelShifter
		)
	port map(
		clk => clk,
		Reset => Reset,
		CPU => CPU,
		clkena_lw => clkena_lw,
		execOPC => execOPC_ALU,
		decodeOPC => decodeOPC,
		exe_condition => exe_condition,
		exec_tas => exec_tas,
		long_start => long_start_alu,
		non_aligned => non_aligned,
		check_aligned => check_aligned,
		movem_presub => movem_presub,
		set_stop => set_stop,
		Z_error => Z_error,

		rot_bits => rot_bits,
		exec => exec,
		OP1out => OP1out,
		OP2out => OP2out,
		reg_QA => reg_QA,
		reg_QB => reg_QB,
		opcode => opcode,
		exe_opcode => exe_opcode,
		exe_datatype => exe_datatype,
		sndOPC => sndOPC,
		last_data_read => last_data_read(15 downto 0),
		data_read => data_read(15 downto 0),
		FlagsSR => FlagsSR,
		micro_state => micro_state,
		bf_ext_in => bf_ext_in,
		bf_ext_out => bf_ext_out,
		bf_shift => alu_bf_shift,
		bf_width => alu_width,
		bf_ffo_offset => alu_bf_ffo_offset,
		bf_loffset => alu_bf_loffset(4 downto 0),
		beat_step => beat_step,

		set_V_Flag => set_V_Flag,
		Flags => Flags,
		c_out => c_out,
		addsub_q => addsub_q,
		ALUout => ALUout,

		restore_ccr => restore_ccr_sig,
		restored_ccr_value => restore_ccr_value_mux
	);

	longword <= not memmaskmux(3);

	long_start_alu <= to_bit(NOT memmaskmux(3));
	execOPC_ALU <= execOPC OR exec(alu_exec);
	moves_fc_override <= '1' when micro_state = moves1 or
	                     (moves_bus_pending = '1' and
	                      not (memmaskmux(3) = '1' and (state = "10" or state = "11")))
	                     else '0';

		process(fc_internal, moves_fc_override, moves_direction, SFC, DFC, micro_state, rte_fmt_a_ssw, rot_cnt, rte_fmt_a_replay_needed, cp_cir)
		begin
			if micro_state = rte_mmu_replay then
				FC <= rte_fmt_a_ssw(2 downto 0);
			elsif cp_cir = '1' then
				FC <= "111";
			elsif moves_fc_override = '1' then
				if moves_direction='0' then
					FC <= SFC;
				else
					FC <= DFC;
				end if;
			else
				FC <= fc_internal;
			end if;
		end process;

	process(clk, nReset)
	begin
		if nReset = '0' then
			moves_bus_pending <= '0';
			moves_ea_areg <= '0';
			moves_ea_regnum <= "000";
			moves_active <= '0';
			moves_direction <= '0';
			moves_reg <= "0000";
		elsif rising_edge(clk) then
			if clkena_core = '1' then
				if micro_state = moves0 and moves_d16_phase = '0' then
					moves_direction <= brief(11);
					moves_reg <= brief(15 downto 12);
				end if;
				if micro_state = ld_dAn1 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "101" then
					moves_ea_latched <= memaddr_a;
					moves_ea_use_base <= '1';
				end if;
				if micro_state = ld_AnXn2 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					moves_ea_latched <= memaddr_a;
					if brief(8) = '1' and brief(2 downto 0) /= "000" then
						moves_ea_use_base <= '0';
					elsif brief(8) = '1' and brief(7) = '1' then
						moves_ea_use_base <= '0';
					else
						moves_ea_use_base <= '1';
					end if;
				end if;
				if micro_state = ld_229_1 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					if brief(5) = '1' and state = "00" then
						moves_ea_latched <= data_read;
					else
						moves_ea_latched <= memaddr_a;
					end if;
					if brief(7) = '1' then
						moves_ea_use_base <= '0';
					else
						moves_ea_use_base <= '1';
					end if;
				end if;
				if micro_state = ld_229_4 and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "110" then
					if brief(1) = '1' then
						moves_ea_latched <= ea_data + data_read;
					else
						moves_ea_latched <= ea_data;
					end if;
					moves_ea_use_base <= '0';
				end if;
				if micro_state = ld_nn and opcode(15 downto 8) = "00001110" and
				   opcode(7 downto 6) /= "11" and opcode(5 downto 3) = "111" then
					if opcode(2 downto 0) = "001" then
						moves_ea_latched <= last_opc_read & data_read(15 downto 0);
					else
						moves_ea_latched <= last_data_read;
					end if;
					moves_ea_use_base <= '0';
				end if;
				if micro_state = moves1 then
					moves_bus_pending <= '1';
					if opcode(5 downto 3) = "010" or opcode(5 downto 3) = "011" or opcode(5 downto 3) = "100" then
						moves_ea_areg <= '1';
					else
						moves_ea_areg <= '0';
					end if;
					moves_ea_regnum <= opcode(2 downto 0);
				elsif moves_bus_pending = '1' and pmmu_fault = '1' then
					moves_bus_pending <= '0';
				elsif moves_bus_pending = '1' and clkena_lw = '1' and memmaskmux(3) = '1' and
				      (state = "10" or state = "11") then
					moves_bus_pending <= '0';
				elsif micro_state = idle then
					moves_bus_pending <= '0';
				end if;
				if micro_state = moves0 or micro_state = moves1 then
					moves_active <= '1';
				elsif moves_active = '1' and moves_bus_pending = '0' and moves_writeback_pending = '0' then
					moves_active <= '0';
				end if;
			end if;
		end if;
		end process;

		process(clk, nReset)
		begin
			if nReset = '0' then
				moves_writeback_pending <= '0';
			elsif rising_edge(clk) then
				if clkena_core = '1' then
					if micro_state = moves1 and moves_direction = '0' then
						moves_writeback_pending <= '1';
					elsif moves_writeback_pending = '1' and pmmu_fault = '1' then
						moves_writeback_pending <= '0';
					elsif state = "10" and memmaskmux(3) = '1' and moves_writeback_pending = '1' then
						moves_writeback_pending <= '0';
					end if;
				end if;
			end if;
		end process;

		process(clk, nReset)
		begin
			if nReset = '0' then
				moves_d16_phase <= '0';
			elsif rising_edge(clk) then
				if clkena_core = '1' then
					if micro_state /= moves0 then
						moves_d16_phase <= '0';
					elsif opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" then
						if moves_d16_phase = '0' then
							moves_d16_phase <= '1';
						else
							moves_d16_phase <= '0';
						end if;
					else
						moves_d16_phase <= '0';
					end if;
				end if;
			end if;
		end process;

		process (memmaskmux)
		begin
			non_aligned <= '0';
		if (memmaskmux(5 downto 4) = "01") or (memmaskmux(5 downto 4) = "10") then
			non_aligned <= '1';
		end if;
	end process;
   regin_out <= regin;

	nWr <= '0' WHEN state="11" AND pmmu_busy='0' AND (mmu_restart_pending='0' OR mmu_restart_soft='1') ELSE '1';
	berr_stack_fetch_squash <= '1' WHEN micro_state = berr_fill OR micro_state = berr1 OR
	                                     micro_state = berr2 OR micro_state = berr3 OR
	                                     micro_state = berr4 OR micro_state = berr5 OR
	                                     micro_state = berr6 OR micro_state = berr7 OR
	                                     micro_state = berr8 OR micro_state = trap3 OR
	                                     (interrupt = '1' AND (trap_berr = '1' OR trap_mmu_berr = '1'))
	                           ELSE '0';
	busstate_raw <= "01" WHEN (state="00" AND TG68_PC(0)='1') OR pmmu_busy='1' OR (mmu_restart_pending='1' AND mmu_restart_soft='0')
	                      OR (state="00" AND berr_stack_fetch_squash='1') ELSE state;
	busstate <= "01" WHEN fetch_hit='1' ELSE busstate_raw;
	clkena_core <= clkena_in AND fetch_ok;

	g_fetch16: IF DATA_WIDTH /= 32 GENERATE
		fetch_hit <= '0'; fetch_bus <= '0'; fetch_ok <= '1';
		fetch_word <= (OTHERS => '0'); fetch_a10 <= "00";
	END GENERATE;
	g_fetch32: IF DATA_WIDTH = 32 GENERATE
		fetch_hit <= '1' WHEN busstate_raw = "00" AND hold_valid = '1' AND hold_addr = addr(31 downto 2) ELSE '0';
		fetch_bus <= '1' WHEN busstate_raw = "00" AND fetch_hit = '0' ELSE '0';
		fetch_a10 <= "00" WHEN fetch_done = 0 ELSE "01" WHEN fetch_done = 1 ELSE "10" WHEN fetch_done = 2 ELSE "11";
		PROCESS (fetch_a10, dsack)
		BEGIN
			IF dsack = "10" THEN
				fetch_room <= 1; fetch_first <= 0;
			ELSIF dsack /= "01" THEN
				fetch_room <= 4 - conv_integer(fetch_a10); fetch_first <= conv_integer(fetch_a10);
			ELSIF fetch_a10(0)='1' THEN
				fetch_room <= 1; fetch_first <= 1;
			ELSE
				fetch_room <= 2; fetch_first <= 0;
			END IF;
		END PROCESS;
		fetch_n <= 4 - fetch_done WHEN fetch_room > 4 - fetch_done ELSE fetch_room;
		fetch_lane <= bus_in WHEN fetch_first = 0 ELSE
		              bus_in(23 downto 0) & X"00" WHEN fetch_first = 1 ELSE
		              bus_in(15 downto 0) & X"0000" WHEN fetch_first = 2 ELSE
		              bus_in(7 downto 0) & X"000000";
		PROCESS (fetch_buf, fetch_lane, fetch_done, fetch_n)
			VARIABLE v : std_logic_vector(31 downto 0);
		BEGIN
			v := fetch_buf;
			FOR k IN 0 TO 3 LOOP
				IF k >= fetch_done AND k < fetch_done + fetch_n THEN
					v(31-8*k downto 24-8*k) := fetch_lane(31-8*(k-fetch_done) downto 24-8*(k-fetch_done));
				END IF;
			END LOOP;
			fetch_long <= v;
		END PROCESS;
		fetch_word <= hold_data(31 downto 16) WHEN fetch_hit = '1' AND addr(1) = '0' ELSE
		              hold_data(15 downto 0)  WHEN fetch_hit = '1' ELSE
		              fetch_long(31 downto 16) WHEN addr(1) = '0' ELSE
		              fetch_long(15 downto 0);
		fetch_ok <= '0' WHEN fetch_bus = '1' AND beat_valid = '1' AND fetch_done + fetch_n < 4 ELSE '1';
		PROCESS (clk)
		BEGIN
			IF rising_edge(clk) THEN
				IF Reset = '1' THEN
					hold_valid <= '0'; fetch_done <= 0; fetch_buf <= (OTHERS => '0');
					hold_addr <= (OTHERS => '0'); hold_data <= (OTHERS => '0');
				ELSIF clkena_in = '1' THEN
					IF fetch_bus = '1' AND beat_valid = '1' THEN
						IF fetch_done + fetch_n >= 4 THEN
							fetch_done <= 0;
							hold_valid <= '1'; hold_addr <= addr(31 downto 2); hold_data <= fetch_long;
						ELSE
							fetch_done <= fetch_done + fetch_n; fetch_buf <= fetch_long;
						END IF;
					ELSE
						fetch_done <= 0;
					END IF;
					IF state = "11" AND addr(31 downto 2) = hold_addr THEN
						hold_valid <= '0';
					END IF;
				END IF;
			END IF;
		END PROCESS;
	END GENERATE;
	nResetOut <= '0' WHEN exec(opcRESET)='1' ELSE '1';

	beat_rem <= 5 WHEN memmask(0)='0' ELSE
	            4 WHEN memmask(1)='0' ELSE
	            3 WHEN memmask(2)='0' ELSE
	            2 WHEN memmask(3)='0' ELSE
	            1 WHEN memmask(4)='0' ELSE 0;
	op5_now <= '1' WHEN memmask="100000" OR op5='1' ELSE '0';
	PROCESS (addr, dsack)
	BEGIN
		IF DATA_WIDTH = 32 AND dsack = "10" THEN
			port_room <= 1; first_lane <= 0;
		ELSIF DATA_WIDTH = 32 AND dsack /= "01" THEN
			port_room <= 4 - conv_integer(addr(1 downto 0)); first_lane <= conv_integer(addr(1 downto 0));
		ELSIF addr(0)='1' THEN
			port_room <= 1; first_lane <= 1;
		ELSE
			port_room <= 2; first_lane <= 0;
		END IF;
	END PROCESS;
	PROCESS (beat_rem, op5_now, port_room, state)
		VARIABLE room, cyc, n : integer range 0 to 5;
	BEGIN
		room := port_room;
		IF state = "00" THEN room := 2; END IF;
		cyc := beat_rem;
		IF op5_now='1' AND beat_rem > 1 THEN cyc := beat_rem - 1; END IF;
		n := beat_rem;
		IF cyc < n THEN n := cyc; END IF;
		IF room < n THEN n := room; END IF;
		beat_n <= n;
	END PROCESS;
	beat_step <= "001" WHEN beat_n = 1 ELSE "010" WHEN beat_n = 2 ELSE
	             "011" WHEN beat_n = 3 ELSE "100" WHEN beat_n = 4 ELSE "000";
	g_bus32: IF DATA_WIDTH = 32 GENERATE
		bus_in <= data_in;
		data_write <= bus_out;
	END GENERATE;
	g_bus16: IF DATA_WIDTH /= 32 GENERATE
		bus_in <= data_in & X"0000";
		data_write <= bus_out(31 downto 16);
	END GENERATE;
	lane_raw <= bus_in WHEN first_lane = 0 ELSE
	            bus_in(23 downto 0) & X"00" WHEN first_lane = 1 ELSE
	            bus_in(15 downto 0) & X"0000" WHEN first_lane = 2 ELSE
	            bus_in(7 downto 0) & X"000000";
	lane_in <= fetch_word & X"0000" WHEN DATA_WIDTH = 32 AND state = "00" ELSE lane_raw;
	byte_in <= lane_in(31 downto 24);
	siz <= "01" WHEN fetch_bus = '1' AND fetch_done = 3 ELSE
	       "10" WHEN fetch_bus = '1' AND fetch_done = 2 ELSE
	       "11" WHEN fetch_bus = '1' AND fetch_done = 1 ELSE
	       "00" WHEN fetch_bus = '1' ELSE
	       "01" WHEN beat_rem = 1 ELSE "10" WHEN beat_rem = 2 ELSE "11" WHEN beat_rem = 3 ELSE "00";
	memmaskmux(2 downto 0) <= memmask(2 downto 0) WHEN addr(0)='1' ELSE memmask(1 downto 0) & '1';
	memmaskmux(3) <= '1' WHEN beat_n = beat_rem OR (berr_k = '1' AND state(1) = '1') ELSE '0';
	memmaskmux(5 downto 4) <= "11" WHEN beat_n = 0 ELSE
	                          "00" WHEN beat_n >= 2 ELSE
	                          "10" WHEN addr(0)='1' ELSE "01";
	nUDS <= memmaskmux(5) OR pmmu_busy OR pmmu_fault OR (mmu_restart_pending AND NOT mmu_restart_soft);
	nLDS <= memmaskmux(4) OR pmmu_busy OR pmmu_fault OR (mmu_restart_pending AND NOT mmu_restart_soft);
	clkena_lw <= '1' WHEN clkena_core='1' AND memmaskmux(3)='1' AND pmmu_busy='0' AND
	                       directpc_retry_hold='0' ELSE '0';
	directpc_retry_hold <= '1' WHEN (exec(directPC)='1' OR exec(directSR)='1' OR
	                                 exec(directCCR)='1') AND state="10" AND
	                                  beat_valid='0' AND
	                                  dib_sub_hit='0' AND berr_k='0' AND
	                                  pmmu_walker_berr='0' AND
	                                  (pmmu_fault='0' OR pmmu_fault_is_insn_out='1') AND
	                                  (make_berr='0' OR
	                                   (berr_pmmu_fault_valid='1' AND
	                                    berr_pmmu_fault_is_insn='1'))
	                       ELSE '0';
	clr_berr <= '1' WHEN setopcode='1' AND trap_berr='1' ELSE '0';
	cp_berr_ack <= cp_nocp;

	insn_fetch_consumer <= '1' WHEN getbrief='1' OR setnextpass='1' OR exec(update_ld)='1' OR
	                                 set(get_2ndOPC)='1' OR
	                                 micro_state = ld_nn  OR micro_state = st_nn  OR
	                                 micro_state = ld_dAn1 OR micro_state = st_dAn1 OR
	                                 micro_state = ld_AnXn1 OR micro_state = ld_AnXn2 OR
	                                 micro_state = st_AnXn1 OR micro_state = st_AnXn2 OR
	                                 micro_state = ld_AnXnbd1 OR micro_state = ld_AnXnbd2 OR micro_state = ld_AnXnbd3 OR
	                                 micro_state = ld_229_1 OR micro_state = ld_229_2 OR
	                                 micro_state = ld_229_3 OR micro_state = ld_229_4 OR
	                                 micro_state = st_229_1 OR micro_state = st_229_2 OR
	                                 micro_state = st_229_3 OR micro_state = st_229_4
	                        ELSE '0';
	pmmu_fault_restart_live <= '1' WHEN pmmu_tc_en = '1' AND
	                                     pmmu_fault = '1' AND
	                                     (pmmu_fault_is_insn_out = '0' OR insn_fetch_consumer = '1') AND
	                                     pmmu_fault_lastwrite_ok = '0'
	                            ELSE '0';
	pmmu_fault_restart_dispatch <= '1' WHEN TG68_PC(0) = '0' AND
	                                         ((mmu_restart_pending = '1' AND make_berr = '1') OR
	                                          (pmmu_fault_restart_live = '1' AND
	                                           pmmu_fault_dispatched = '0' AND
	                                           berr_exception_active = '0' AND
	                                           trap_berr = '0' AND trap_mmu_berr = '0'))
	                                ELSE '0';
	mmu_restart_active <= mmu_restart_pending;
	mmu_restart_restore_now <= '1' WHEN mmu_restart_restore = '1' OR
	                                      (setinterrupt = '1' AND pmmu_fault_restart_dispatch = '1')
	                           ELSE '0';

	pmmu_fault_effective_rw <= pmmu_fault_rw_out WHEN pmmu_fault = '1' ELSE berr_pmmu_fault_rw;
	pmmu_fault_lastwrite_ok <= '1' WHEN pmmu_fault_effective_rw = '0' AND locked_rmw_active = '0' AND
	                                    NOT ((exec(movem_action) = '1' OR movem_actiond = '1') AND movem_run = '1') AND
	                                    NOT (micro_state = movep1 OR micro_state = movep2 OR micro_state = movep3 OR
	                                         micro_state = movep4 OR micro_state = movep5)
	                           ELSE '0';

	PROCESS (clk, nReset)
	BEGIN
		IF nReset='0' THEN
			syncReset <= "0000";
			Reset <= '1';
	  	ELSIF rising_edge(clk) THEN
			IF clkena_core='1' THEN
				syncReset <= syncReset(2 downto 0)&'1';
				Reset <= NOT syncReset(3);
			END IF;
		END IF;
		IF rising_edge(clk) THEN
			IF VBR_Stackframe=1 or (cpu /="00" and VBR_Stackframe=2) THEN
				use_VBR_Stackframe<='1';
			ELSE
				use_VBR_Stackframe<='0';
			END IF;
		END IF;
	END PROCESS;

	rte_mmu_fix_dest <= rte_mmu_fix_opcode(11 downto 9);
	rte_mmu_fix_is_tst <= '1' when rte_mmu_fix_opcode(15 downto 8) = "01001010" AND
	                                rte_mmu_fix_opcode(7 downto 6) /= "11" else '0';
	rte_mmu_fix_size <= rte_mmu_fix_opcode(7 downto 6) when rte_mmu_fix_is_tst = '1' else
	                   "00" when rte_mmu_fix_opcode(15 downto 12) = "0001" else
	                   "10" when rte_mmu_fix_opcode(15 downto 12) = "0010" else
	                   "01";
	rte_fmt_a_replay_needed <= '1' when
		rte_format_word(15 downto 12) = "1010" AND
		rte_fmt_a_state1(8) = '1' AND
		rte_fmt_a_ssw(8) = '1' AND
		rte_fmt_a_ssw(7) = '0' AND
		rte_fmt_a_ssw(6) = '0'
		else '0';
	rte_fmt_a_replay_size <= "00" when rte_fmt_a_ssw(5 downto 4) = "01" else
	                         "01" when rte_fmt_a_ssw(5 downto 4) = "10" else
	                         "10";
	rte_mmu_fix_write <= '1' when
		rte_mmu_fix_armed = '1' AND
		micro_state = rte5 AND
		rot_cnt = "000010" AND
		rte_format_word(15 downto 12) = "1011" AND
		(rte_mmu_fix_ssw(9) = '1' OR
		 (rte_mmu_fix_ssw(15) = '0' AND rte_mmu_fix_ssw(14) = '0' AND
		  rte_mmu_fix_ssw(13) = '0' AND rte_mmu_fix_ssw(12) = '0')) AND
		rte_mmu_fix_ssw(8) = '0' AND
		rte_mmu_fix_ssw(7) = '0' AND
		rte_mmu_fix_ssw(6) = '1' AND
		(rte_mmu_fix_opcode(5 downto 3) = "010" OR
		 rte_mmu_fix_opcode(5 downto 3) = "101" OR
		 (rte_mmu_fix_opcode(5 downto 3) = "111" AND
		  (rte_mmu_fix_opcode(2 downto 0) = "000" OR
		   rte_mmu_fix_opcode(2 downto 0) = "001" OR
		   rte_mmu_fix_opcode(2 downto 0) = "010"))) AND
		((rte_mmu_fix_opcode(8 downto 6) = "000" AND
		  (rte_mmu_fix_opcode(15 downto 12) = "0001" OR
		   rte_mmu_fix_opcode(15 downto 12) = "0010" OR
		   rte_mmu_fix_opcode(15 downto 12) = "0011")) OR
		 (rte_mmu_fix_opcode(8 downto 6) = "001" AND
		  (rte_mmu_fix_opcode(15 downto 12) = "0010" OR
		   rte_mmu_fix_opcode(15 downto 12) = "0011")) OR
		 rte_mmu_fix_is_tst = '1')
		else '0';
	rte_mmu_fix_len <= "010" when rte_mmu_fix_opcode(5 downto 3) = "010" else
	                   "110" when (rte_mmu_fix_opcode(5 downto 3) = "111" AND
	                               rte_mmu_fix_opcode(2 downto 0) = "001") else
	                   "100";
	rte_mmu_fix_commit <= rte_mmu_fix_write AND clkena_lw;
	dib_sub_pre <= '1' when dib_sub_valid = '1' AND state(1) = '1' AND pmmu_fault = '0' AND
	                         pmmu_rw = dib_sub_rw AND
	                         (addr(31 downto 1) = dib_sub_addr(31 downto 1) OR
	                          addr(31 downto 1) = dib_sub_addr(31 downto 1) + 1)
	               else '0';
	dib_sub_out <= dib_sub_pre;
	dib_sub_hit <= '1' when (dib_sub_pre = '1' AND dib_sub_rw = '1') OR
	                        (dib_sub_valid = '1' AND pmmu_fault = '1' AND
	                         pmmu_fault_rw_out = '1' AND
	                         (pmmu_fault_addr_out(31 downto 1) = dib_sub_addr(31 downto 1) OR
	                          pmmu_fault_addr_out(31 downto 1) = dib_sub_addr(31 downto 1) + 1))
	               else '0';
	rte_mmu_fix_ccr_update <= '1' when rte_mmu_fix_commit = '1' AND
		(rte_mmu_fix_opcode(8 downto 6) = "000" OR rte_mmu_fix_is_tst = '1') else '0';

	PROCESS (Flags, rte_mmu_fix_size, rte_mmu_fix_input_buffer)
	BEGIN
		rte_mmu_fix_ccr_value <= (others => '0');
		rte_mmu_fix_ccr_value(4) <= Flags(4);
		CASE rte_mmu_fix_size IS
			WHEN "00" =>
				rte_mmu_fix_ccr_value(3) <= rte_mmu_fix_input_buffer(7);
				IF rte_mmu_fix_input_buffer(7 downto 0) = x"00" THEN
					rte_mmu_fix_ccr_value(2) <= '1';
				END IF;
			WHEN "01" =>
				rte_mmu_fix_ccr_value(3) <= rte_mmu_fix_input_buffer(15);
				IF rte_mmu_fix_input_buffer(15 downto 0) = x"0000" THEN
					rte_mmu_fix_ccr_value(2) <= '1';
				END IF;
			WHEN OTHERS =>
				rte_mmu_fix_ccr_value(3) <= rte_mmu_fix_input_buffer(31);
				IF rte_mmu_fix_input_buffer = x"00000000" THEN
					rte_mmu_fix_ccr_value(2) <= '1';
				END IF;
		END CASE;
	END PROCESS;

PROCESS (clk, long_done, last_data_in, data_in, addr, long_start, memmaskmux, memread, memmask, data_read, dib_sub_hit, dib_sub_data, beat_n, byte_in, lane_in, bus_in, beat_rem, op_size)
	BEGIN
		CASE beat_n IS
			WHEN 1 => data_read <= last_data_in(23 downto 0)&lane_in(31 downto 24);
			WHEN 2 => data_read <= last_data_in(15 downto 0)&lane_in(31 downto 16);
			WHEN 3 => data_read <= last_data_in(7 downto 0)&lane_in(31 downto 8);
			WHEN 4 => data_read <= lane_in;
			WHEN OTHERS => data_read <= last_data_in(23 downto 0)&bus_in(31 downto 24);
		END CASE;
		IF (memread(1 downto 0)="11" AND beat_rem <= 2) OR (memread(1 downto 0)/="11" AND op_size <= 2) THEN
			data_read(31 downto 16) <= (OTHERS=>data_read(15));
		END IF;
		IF dib_sub_hit='1' THEN
			data_read <= dib_sub_data;
		END IF;

		IF rising_edge(clk) THEN
			IF clkena_lw='1' AND state="10" THEN
				CASE beat_n IS
					WHEN 2 => bf_ext_in <= last_data_in(23 downto 16);
					WHEN 3 => bf_ext_in <= last_data_in(15 downto 8);
					WHEN 4 => bf_ext_in <= last_data_in(7 downto 0);
					WHEN OTHERS => bf_ext_in <= last_data_in(31 downto 24);
				END CASE;
			END IF;
			IF Reset='1' THEN
				last_data_read <= (OTHERS => '0');
			ELSIF clkena_core='1' THEN
				IF beat_valid='1' OR dib_sub_hit='1' THEN
					IF state="00" OR exec(update_ld)='1' THEN
						last_data_read <= data_read;
						IF state(1)='0' AND memmask(1)='0' THEN
							last_data_read(31 downto 16) <= last_opc_read;
						ELSIF state(1)='0' THEN
							last_data_read(31 downto 16) <= (OTHERS=>lane_in(31));
						END IF;
					END IF;
					CASE beat_n IS
						WHEN 1 => last_data_in <= last_data_in(23 downto 0)&lane_in(31 downto 24);
						WHEN 3 => last_data_in <= last_data_in(7 downto 0)&lane_in(31 downto 8);
						WHEN 4 => last_data_in <= lane_in;
						WHEN 2 => last_data_in <= last_data_in(15 downto 0)&lane_in(31 downto 16);
						WHEN OTHERS => last_data_in <= last_data_in(15 downto 0)&bus_in(31 downto 16);
					END CASE;
				END IF;
			END IF;
		END IF;
				long_start <= to_bit(NOT memmask(1));
				long_done <= to_bit(NOT memread(1));
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				rte_format_word <= (others => '0');
			ELSIF clkena_core='1' THEN
				IF micro_state = rte3 AND next_micro_state = rte4 THEN
					IF dib_sub_hit='1' THEN
						rte_format_word <= dib_sub_data(15 downto 0);
					ELSIF beat_valid='1' THEN
						rte_format_word <= lane_in(31 downto 16);
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				format1_chain_active <= '0';
				rte_saved_mbit <= '0';
				rte_saved_sr_high <= x"27";
				rte_saved_a7 <= (others => '0');
				a7_is_msp <= '0';
			ELSIF clkena_lw='1' THEN
				IF next_micro_state = rte1 AND micro_state /= rte6 THEN
					rte_saved_mbit <= FlagsSR(4);
					rte_saved_sr_high <= FlagsSR;
					rte_saved_a7 <= regfile(15);
					rte_saved_ccr <= Flags;
				END IF;
				IF exec(to_SR)='1' THEN
					rte_saved_mbit <= FlagsSR(4);
				END IF;
				IF exec(from_MSP)='1' AND exec(from_USP)='0' THEN
					a7_is_msp <= '1';
				ELSIF exec(from_ISP)='1' AND exec(from_USP)='0' THEN
					a7_is_msp <= '0';
				END IF;
				IF exec(to_SR)='1' AND cpu(1)='1' AND preSVmode='1' AND SRin(5)='1' AND SRin(4) /= FlagsSR(4) THEN
					a7_is_msp <= SRin(4);
				END IF;
				IF set_stop='1' AND cpu(1)='1' AND preSVmode='1' AND data_read(13)='1' AND data_read(12) /= FlagsSR(4) THEN
					a7_is_msp <= data_read(12);
				END IF;
				IF setopcode='1' THEN
					format1_chain_active <= '0';
				ELSIF micro_state = rte4 THEN
					IF rte_format_word(15 downto 12) = "0001" AND FlagsSR(4)='1' AND cpu(1)='1' THEN
						format1_chain_active <= '1';
					ELSIF rte_format_word(15 downto 12) = "0000" AND format1_chain_active='1' THEN
						format1_chain_active <= '0';
					END IF;
				ELSIF micro_state = rte5 AND rot_cnt = "000001" AND format1_chain_active='1' THEN
					format1_chain_active <= '0';
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				bus_beat_poisoned <= '0';
				bus_datum_dirty <= '0';
				ea_to_pc_datum_invalid <= '0';
			ELSIF clkena_core='1' THEN
				IF setopcode='1' OR
				   micro_state = trap0 OR micro_state = trap00 OR
				   micro_state = berr_fill OR micro_state = berr1 OR
				   micro_state = int1 THEN
					bus_beat_poisoned <= '0';
					bus_datum_dirty <= '0';
					ea_to_pc_datum_invalid <= '0';
				ELSIF beat_valid='0' AND dib_sub_hit='0' AND state /= "01" THEN
					bus_beat_poisoned <= '1';
					IF state = "10" AND micro_state = ld_229_3 THEN
						ea_to_pc_datum_invalid <= '1';
					END IF;
					IF directpc_retry_hold='1' THEN
						bus_datum_dirty <= bus_datum_dirty;
					ELSIF state = "10" THEN
						IF clkena_lw='1' THEN
							bus_datum_dirty <= '0';
						ELSE
							bus_datum_dirty <= '1';
						END IF;
					END IF;
				ELSIF state = "10" AND beat_valid='1' AND clkena_lw='0' THEN
					bus_datum_dirty <= '0';
				ELSIF clkena_lw='1' THEN
					bus_datum_dirty <= '0';
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				rte_mmu_fix_capture_active <= '0';
				rte_mmu_fix_armed <= '0';
				rte_mmu_fix_long_index <= 0;
				rte_mmu_fix_ssw <= (others => '0');
				rte_mmu_fix_opcode <= (others => '0');
				rte_mmu_fix_input_buffer <= (others => '0');
				rte_format_b_version_error <= '0';
			ELSIF clkena_lw='1' THEN
				IF trapmake='1' THEN
					rte_mmu_fix_capture_active <= '0';
					rte_mmu_fix_long_index <= 0;
					rte_format_b_version_error <= '0';
					IF trap_mmu_berr='1' AND berr_long_frame='1' THEN
						rte_mmu_fix_armed <= '1';
					ELSE
						rte_mmu_fix_armed <= '0';
					END IF;
				ELSIF micro_state = berr8 AND trap_mmu_berr='1' AND berr_long_frame='1' THEN
					rte_mmu_fix_armed <= '1';
				ELSIF setopcode='1' THEN
					rte_mmu_fix_capture_active <= '0';
					rte_mmu_fix_long_index <= 0;
					rte_format_b_version_error <= '0';
				ELSIF micro_state = rte4 THEN
					rte_format_b_version_error <= '0';
					IF rte_format_word(15 downto 12) = "1011" THEN
						rte_mmu_fix_capture_active <= '1';
						rte_mmu_fix_armed <= '1';
						rte_mmu_fix_long_index <= 0;
						rte_mmu_fix_ssw <= (others => '0');
						rte_mmu_fix_opcode <= (others => '0');
						rte_mmu_fix_input_buffer <= (others => '0');
					ELSE
						rte_mmu_fix_capture_active <= '0';
						rte_mmu_fix_long_index <= 0;
					END IF;
				ELSIF micro_state = rte5 AND rte_mmu_fix_capture_active = '1' THEN
					IF (beat_valid='1' AND bus_datum_dirty='0') OR dib_sub_hit='1' THEN
						CASE rte_mmu_fix_long_index IS
							WHEN 0 =>
								rte_mmu_fix_ssw <= data_read(15 downto 0);
							WHEN 2 =>
								rte_mmu_fix_faddr <= data_read;
							WHEN 3 =>
								rte_mmu_fix_opcode <= data_read(15 downto 0);
							WHEN 9 =>
								rte_mmu_fix_input_buffer <= data_read;
							WHEN OTHERS =>
								NULL;
						END CASE;
						IF rte_mmu_fix_long_index = 11 AND
						   data_read(15 downto 12) /= RTE_030_FORMAT_B_VERSION THEN
							rte_format_b_version_error <= '1';
						END IF;
					END IF;
					IF rot_cnt = "000001" THEN
						rte_mmu_fix_capture_active <= '0';
						rte_mmu_fix_armed <= '0';
					ELSE
						rte_mmu_fix_long_index <= rte_mmu_fix_long_index + 1;
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset='1' THEN
				rte_fmt_a_capture_active <= '0';
				rte_fmt_a_long_index <= 0;
				rte_fmt_a_state1 <= (others => '0');
				rte_fmt_a_ssw <= (others => '0');
				rte_fmt_a_fault_addr <= (others => '0');
				rte_fmt_a_data_out <= (others => '0');
			ELSIF clkena_lw='1' THEN
				IF setopcode='1' THEN
					rte_fmt_a_capture_active <= '0';
					rte_fmt_a_long_index <= 0;
				ELSIF micro_state = rte4 THEN
					IF rte_format_word(15 downto 12) = "1010" THEN
						rte_fmt_a_capture_active <= '1';
						rte_fmt_a_long_index <= 0;
						rte_fmt_a_state1 <= (others => '0');
						rte_fmt_a_ssw <= (others => '0');
						rte_fmt_a_fault_addr <= (others => '0');
						rte_fmt_a_data_out <= (others => '0');
					ELSE
						rte_fmt_a_capture_active <= '0';
						rte_fmt_a_long_index <= 0;
					END IF;
				ELSIF micro_state = rte5 AND rte_fmt_a_capture_active = '1' THEN
					IF (beat_valid='1' AND bus_datum_dirty='0') OR dib_sub_hit='1' THEN
						CASE rte_fmt_a_long_index IS
							WHEN 0 =>
								rte_fmt_a_state1 <= data_read(31 downto 16);
								rte_fmt_a_ssw <= data_read(15 downto 0);
							WHEN 2 =>
								rte_fmt_a_fault_addr <= data_read;
							WHEN 4 =>
								rte_fmt_a_data_out <= data_read;
							WHEN OTHERS =>
								NULL;
						END CASE;
					END IF;
					IF rot_cnt = "000001" THEN
						rte_fmt_a_capture_active <= '0';
					ELSE
						rte_fmt_a_long_index <= rte_fmt_a_long_index + 1;
					END IF;
				END IF;
			END IF;
		END IF;
	END PROCESS;

	PROCESS (long_start, reg_QB, data_write_tmp, exec, data_read, beat_rem, bf_ext_out, addr,
			 data_write_muxin, memmask,
			 moves_bus_pending, moves_direction, moves_reg, addsub_q, opcode)
		VARIABLE op_bytes : std_logic_vector(39 downto 0);
		VARIABLE r0, r1, r2, r3 : std_logic_vector(7 downto 0);
	BEGIN
		IF exec(write_reg)='1' THEN
			IF moves_bus_pending = '1' AND moves_direction = '1' AND
			   (exec(postadd) = '1' OR exec(presub) = '1') AND
			   moves_reg = ('1' & opcode(2 downto 0)) AND
			   long_start = '0' THEN
				data_write_muxin <= addsub_q;
			ELSE
				data_write_muxin <= reg_QB;
			END IF;
		ELSE
			data_write_muxin <= data_write_tmp;
		END IF;

		op_bytes := bf_ext_out & data_write_muxin;
		CASE beat_rem IS
			WHEN 5 => r0 := op_bytes(39 downto 32); r1 := op_bytes(31 downto 24); r2 := op_bytes(23 downto 16); r3 := op_bytes(15 downto 8);
			WHEN 4 => r0 := op_bytes(31 downto 24); r1 := op_bytes(23 downto 16); r2 := op_bytes(15 downto 8);  r3 := op_bytes(7 downto 0);
			WHEN 3 => r0 := op_bytes(23 downto 16); r1 := op_bytes(15 downto 8);  r2 := op_bytes(7 downto 0);   r3 := op_bytes(23 downto 16);
			WHEN 2 => r0 := op_bytes(15 downto 8);  r1 := op_bytes(7 downto 0);   r2 := op_bytes(15 downto 8);  r3 := op_bytes(7 downto 0);
			WHEN OTHERS => r0 := op_bytes(7 downto 0); r1 := r0; r2 := r0; r3 := r0;
		END CASE;
		IF beat_rem = 1 THEN
			bus_out <= r0 & r0 & r0 & r0;
		ELSIF beat_rem = 2 THEN
			IF addr(0)='0' THEN
				bus_out <= r0 & r1 & r0 & r1;
			ELSE
				bus_out <= r0 & r0 & r1 & r0;
			END IF;
		ELSE
			CASE addr(1 downto 0) IS
				WHEN "00" => bus_out <= r0 & r1 & r2 & r3;
				WHEN "01" => bus_out <= r0 & r0 & r1 & r2;
				WHEN "10" => bus_out <= r0 & r1 & r0 & r1;
				WHEN OTHERS => bus_out <= r0 & r0 & r1 & r0;
			END CASE;
		END IF;
		IF exec(mem_byte)='1' THEN
			bus_out <= data_write_tmp(15 downto 8) & data_write_tmp(15 downto 8) & data_write_tmp(15 downto 8) & data_write_tmp(15 downto 8);
		END IF;
	END PROCESS;

PROCESS (clk, regfile, RDindex_A, RDindex_B, exec, rte_mmu_fix_commit, rte_mmu_fix_dest, rte_mmu_fix_size, rte_mmu_fix_input_buffer, rte_mmu_fix_opcode, mmu_restart_restore_now)
	variable v_regfile : regfile_t;
	variable v_hold_a7 : std_logic_vector(31 downto 0);
	BEGIN
		reg_QA <= regfile(RDindex_A);
		reg_QB <= regfile(RDindex_B);
		IF rising_edge(clk) THEN
		    IF clkena_lw='1' THEN
					v_regfile := regfile;
					rf_source_addrd <= rf_source_addr;
					WR_AReg <= rf_dest_addr(3);
					RDindex_A <= conv_integer(rf_dest_addr(3 downto 0));
					RDindex_B <= conv_integer(rf_source_addr(3 downto 0));
					IF Wwrena='1' THEN
						v_regfile(RDindex_A) := regin;
					END IF;
					IF cp_reg_we = '1' THEN
						v_regfile(conv_integer(cp_reg_n)) := cp_reg_d;
					END IF;
				IF moves_writeback_pending = '1' AND state = "10" THEN
					CASE exe_datatype IS
						WHEN "00" =>
							IF moves_reg(3) = '1' THEN
								v_regfile(conv_integer(moves_reg)) := (31 downto 8 => data_read(7)) & data_read(7 downto 0);
							ELSE
								v_regfile(conv_integer(moves_reg))(7 downto 0) := data_read(7 downto 0);
							END IF;
						WHEN "01" =>
							IF moves_reg(3) = '1' THEN
								v_regfile(conv_integer(moves_reg)) := (31 downto 16 => data_read(15)) & data_read(15 downto 0);
							ELSE
								v_regfile(conv_integer(moves_reg))(15 downto 0) := data_read(15 downto 0);
							END IF;
						WHEN OTHERS =>
							v_regfile(conv_integer(moves_reg)) := data_read;
					END CASE;
				END IF;
				IF rte_mmu_fix_commit = '1' AND rte_mmu_fix_is_tst = '0' THEN
					IF rte_mmu_fix_opcode(8 downto 6) = "001" THEN
						IF rte_mmu_fix_size = "01" THEN
							v_regfile(conv_integer('1' & rte_mmu_fix_dest)) := (31 downto 16 => rte_mmu_fix_input_buffer(15)) & rte_mmu_fix_input_buffer(15 downto 0);
						ELSE
							v_regfile(conv_integer('1' & rte_mmu_fix_dest)) := rte_mmu_fix_input_buffer;
						END IF;
					ELSE
						CASE rte_mmu_fix_size IS
							WHEN "00" =>
								v_regfile(conv_integer('0' & rte_mmu_fix_dest))(7 downto 0) := rte_mmu_fix_input_buffer(7 downto 0);
							WHEN "01" =>
								v_regfile(conv_integer('0' & rte_mmu_fix_dest))(15 downto 0) := rte_mmu_fix_input_buffer(15 downto 0);
							WHEN OTHERS =>
								v_regfile(conv_integer('0' & rte_mmu_fix_dest)) := rte_mmu_fix_input_buffer;
						END CASE;
					END IF;
				END IF;
				IF cpu(1)='1' AND preSVmode='1' AND exec(to_SR)='1' AND SRin(5)='1' AND SRin(4) /= FlagsSR(4) THEN
					IF SRin(4) = '1' THEN
						v_regfile(15) := MSP;
					ELSE
						v_regfile(15) := ISP;
					END IF;
				END IF;
				IF cpu(1)='1' AND preSVmode='1' AND set_stop='1' AND data_read(13)='1' AND data_read(12) /= FlagsSR(4) THEN
					IF data_read(12) = '1' THEN
						v_regfile(15) := MSP;
					ELSE
						v_regfile(15) := ISP;
					END IF;
				END IF;
				IF exec(movec_wr)='1' AND FlagsSR(5)='1' THEN
					IF movec_regsel=X"803" AND a7_is_msp='1' THEN
						v_regfile(15) := reg_QA;
					ELSIF movec_regsel=X"804" AND a7_is_msp='0' THEN
						v_regfile(15) := reg_QA;
					END IF;
				END IF;
				IF trap_format_error='1' THEN
					v_regfile(15) := rte_saved_a7;
				END IF;

				IF mmu_restart_restore_now='1' THEN
					v_hold_a7 := v_regfile(15);
					v_regfile := regfile_shadow;
					IF mmu_restart_restore='1' THEN
						IF exec(postadd)='0' AND exec(presub)='0' AND
						   exec(save_memaddr)='0' THEN
							v_regfile(15) := v_hold_a7;
						END IF;
					END IF;
				END IF;
				IF decodeOPC='1' THEN
					regfile_shadow <= v_regfile;
				END IF;
				regfile <= v_regfile;
			END IF;
		END IF;
	END PROCESS;

PROCESS (OP1in, reg_QA, Regwrena_now, Bwrena, Lwrena, exe_datatype, WR_AReg, movem_actiond, exec, ALUout, memaddr, memaddr_a, ea_only, USP, SSP, MSP, ISP, movec_data, pmmu_reg_rdat, pmmu_ptest_a, pmmu_desc_addr)
	BEGIN
		regin <= ALUout;
		IF exec(save_memaddr)='1' THEN
			regin <= memaddr;
		ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN
			regin <= memaddr_a;
		ELSIF exec(from_USP)='1' THEN
			regin <= USP;
		ELSIF exec(from_SSP)='1' THEN
			regin <= SSP;
		ELSIF exec(from_MSP)='1' THEN
			regin <= MSP;
		ELSIF exec(from_ISP)='1' THEN
			regin <= ISP;
		ELSIF exec(movec_rd)='1' THEN
			regin <= movec_data;
		ELSIF pmmu_ptest_a='1' THEN
			regin <= pmmu_desc_addr;
			ELSIF (set(pmmu_rd)='1' OR exec(pmmu_rd)='1') AND
			      exec(presub)='0' AND exec(postadd)='0' AND exec(changeMode)='0' THEN
				regin <= pmmu_reg_rdat;
			END IF;

			IF Bwrena='1' AND
			   NOT ((set(pmmu_rd)='1' OR exec(pmmu_rd)='1') AND
			        exec(presub)='0' AND exec(postadd)='0' AND exec(changeMode)='0') THEN
				regin(15 downto 8) <= reg_QA(15 downto 8);
			END IF;
			IF Lwrena='0' AND
			   NOT ((set(pmmu_rd)='1' OR exec(pmmu_rd)='1') AND
			        exec(presub)='0' AND exec(postadd)='0' AND exec(changeMode)='0') THEN
				regin(31 downto 16) <= reg_QA(31 downto 16);
			END IF;

		Bwrena <= '0';
		Wwrena <= '0';
		Lwrena <= '0';
		IF exec(presub)='1' OR exec(postadd)='1' OR exec(changeMode)='1' THEN
			Wwrena <= '1';
			Lwrena <= '1';
		ELSIF Regwrena_now='1' THEN
			Wwrena <= '1';
		ELSIF exec(Regwrena)='1' THEN
			Wwrena <= '1';
			CASE exe_datatype IS
				WHEN "00" =>
					Bwrena <= '1';
				WHEN "01" =>
					IF WR_AReg='1' OR movem_actiond='1' THEN
						Lwrena <='1';
					END IF;
				WHEN OTHERS =>
					Lwrena <= '1';
			END CASE;
		END IF;
	END PROCESS;

	PROCESS (opcode, rf_source_addrd, brief, setstackaddr, dest_hbits, dest_areg, dest_LDRareg, data_is_source, sndOPC, exec, set, dest_2ndHbits, dest_2ndLbits, dest_LDRHbits, dest_LDRLbits, last_data_read, last_opc_read, micro_state, next_micro_state, pmove_dn_regnum, pmove_dn_areg, pmove_dn_mode, fline_context_valid, fline_opcode_latch, moves_bus_pending, moves_ea_areg, moves_ea_regnum, moves_direction, moves_reg, setopcode, pmmu_ptest_a, pmmu_brief)
	BEGIN
			IF exec(movem_action) ='1' THEN
				rf_dest_addr <= rf_source_addrd;
			ELSIF setstackaddr='1' THEN
				rf_dest_addr <= "1111";
			ELSIF pmmu_ptest_a='1' THEN
			rf_dest_addr <= '1' & pmmu_brief(7 downto 5);
		ELSIF moves_bus_pending = '1' AND setopcode = '0' AND micro_state /= idle THEN
			rf_dest_addr <= moves_ea_areg & moves_ea_regnum;
		ELSIF micro_state = moves0 OR micro_state = moves1 THEN
			IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR
			   opcode(5 downto 3)="100" OR opcode(5 downto 3)="101" OR
			   opcode(5 downto 3)="110" THEN
				rf_dest_addr <= '1'&opcode(2 downto 0);
			ELSE
				rf_dest_addr <= '0'&opcode(2 downto 0);
			END IF;
		ELSIF set(briefext)='1' THEN
			rf_dest_addr <= brief(15 downto 12);
		ELSIF set(get_bfoffset)='1' THEN
				rf_dest_addr <= '0'&sndOPC(8 downto 6);
		ELSIF dest_2ndHbits='1' THEN
			rf_dest_addr <= dest_LDRareg&sndOPC(14 downto 12);
		ELSIF dest_LDRHbits='1' THEN
			rf_dest_addr <= last_data_read(15 downto 12);
		ELSIF dest_LDRLbits='1' THEN
			rf_dest_addr <= '0'&last_data_read(2 downto 0);
		ELSIF dest_2ndLbits='1' THEN
			rf_dest_addr <= '0'&sndOPC(2 downto 0);
			ELSIF micro_state = pmove_dn_lo OR next_micro_state_c = pmove_dn_lo THEN
			rf_dest_addr <= pmove_dn_areg&(pmove_dn_regnum + "001");
		ELSIF micro_state = pmove_decode AND fline_context_valid = '1' AND
		      (fline_opcode_latch(5 downto 3) = "000" OR fline_opcode_latch(5 downto 3) = "001") THEN
			rf_dest_addr <= fline_opcode_latch(3) & fline_opcode_latch(2 downto 0);
		ELSIF micro_state = pmove_decode AND fline_context_valid = '1' AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			rf_dest_addr <= '1' & fline_opcode_latch(2 downto 0);
		ELSIF pmove_dn_mode = '1' AND fline_context_valid = '1' THEN
			rf_dest_addr <= pmove_dn_areg&pmove_dn_regnum;
		ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
		       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo OR
		       micro_state = ptest1 OR micro_state = pload1 OR micro_state = pflush1) AND
		      fline_context_valid = '1' AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			rf_dest_addr <= '1'&fline_opcode_latch(2 downto 0);
		ELSIF dest_hbits='1' THEN
			rf_dest_addr <= dest_areg&opcode(11 downto 9);
		ELSE
			IF opcode(5 downto 3)="000" OR data_is_source='1' THEN
				rf_dest_addr <= dest_areg&opcode(2 downto 0);
			ELSE
				rf_dest_addr <= '1'&opcode(2 downto 0);
			END IF;
		END IF;
	END PROCESS;

	PROCESS (opcode, exe_opcode, movem_presub, movem_regaddr, source_lowbits, source_areg, sndOPC, exec, set, source_2ndLbits, source_2ndHbits, 	source_LDRLbits, source_LDRMbits, last_data_read, last_opc_read, source_2ndMbits, micro_state, pmove_dn_regnum, pmove_dn_areg, pmove_dn_mode, fline_context_valid, fline_opcode_latch, moves_bus_pending, moves_ea_areg, moves_ea_regnum, moves_direction, moves_reg, setopcode)
	BEGIN
		IF exec(movem_action)='1' OR set(movem_action) ='1' THEN
			IF movem_presub='1' THEN
				rf_source_addr <= movem_regaddr XOR "1111";
			ELSE
				rf_source_addr <= movem_regaddr;
			END IF;
		ELSIF source_2ndLbits='1' THEN
			rf_source_addr <= '0'&sndOPC(2 downto 0);
		ELSIF source_2ndHbits='1' THEN
			rf_source_addr <= '0'&sndOPC(14 downto 12);
		ELSIF source_2ndMbits='1' THEN
			rf_source_addr <= '0'&sndOPC(8 downto 6);
		ELSIF source_LDRLbits='1' THEN
			rf_source_addr <= '0'&last_data_read(2 downto 0);
		ELSIF source_LDRMbits='1' THEN
			rf_source_addr <= '0'&last_data_read(8 downto 6);
		ELSIF moves_bus_pending = '1' AND setopcode = '0' AND micro_state /= idle THEN
			IF moves_direction = '1' THEN
				rf_source_addr <= moves_reg;
			ELSE
				rf_source_addr <= moves_ea_areg & moves_ea_regnum;
			END IF;
		ELSIF micro_state = moves0 OR micro_state = moves1 THEN
			IF moves_direction = '1' THEN
				rf_source_addr <= moves_reg;
			ELSE
				IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR
				   opcode(5 downto 3)="100" OR opcode(5 downto 3)="101" OR
				   opcode(5 downto 3)="110" THEN
					rf_source_addr <= '1'&opcode(2 downto 0);
				ELSE
					rf_source_addr <= '0'&opcode(2 downto 0);
				END IF;
			END IF;
		ELSIF source_lowbits='1' THEN
			rf_source_addr <= source_areg&opcode(2 downto 0);
		ELSIF exec(linksp)='1' THEN
			rf_source_addr <= "1111";
		ELSIF micro_state = pmove_dn_lo THEN
			rf_source_addr <= pmove_dn_areg&(pmove_dn_regnum + "001");
		ELSIF pmove_dn_mode = '1' AND fline_context_valid = '1' THEN
			rf_source_addr <= pmove_dn_areg&pmove_dn_regnum;
		ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
		       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
		      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR fline_opcode_latch(5 downto 3)="100") THEN
			rf_source_addr <= '1'&fline_opcode_latch(2 downto 0);
		ELSE
			rf_source_addr <= source_areg&opcode(11 downto 9);
		END IF;
	END PROCESS;

PROCESS (reg_QA, store_in_tmp, ea_data, long_start, addr, exec, memmaskmux, micro_state, pmove_ea_latched)
	BEGIN
		OP1out <= reg_QA;
		IF exec(OP1out_zero)='1' THEN
			OP1out <= (OTHERS => '0');
		ELSIF (exec(postadd)='1' OR exec(presub)='1') AND
		      (memmaskmux(3)='1' OR micro_state = pmove_mem_to_mmu_lo) THEN
			NULL;
		ELSIF exec(ea_data_OP1)='1' AND store_in_tmp='1' THEN
			OP1out <= ea_data;
		ELSIF exec(movem_action)='1' OR memmaskmux(3)='0' OR exec(OP1addr)='1' THEN
			IF micro_state = pmove_mmu_to_mem_lo AND memmaskmux(3)='1' THEN
				OP1out <= pmove_ea_latched;
			ELSE
				OP1out <= addr;
			END IF;
		END IF;
	END PROCESS;

PROCESS (OP2out, reg_QB, exe_opcode, exe_datatype, execOPC, exec, use_direct_data,
	     store_in_tmp, data_write_tmp, ea_data, pmove_mmu_read_active, pmmu_reg_rdat, micro_state)
	BEGIN
		OP2out(15 downto 0) <= reg_QB(15 downto 0);
		OP2out(31 downto 16) <= (OTHERS => OP2out(15));
		IF exec(OP2out_one)='1' THEN
			OP2out(15 downto 0) <= "1111111111111111";
		ELSIF pmove_mmu_read_active='1' AND exec(postadd)='0' AND exec(presub)='0' THEN
			OP2out <= pmmu_reg_rdat;
		ELSIF micro_state = chk22 AND exe_opcode(10 downto 9)="00" AND exec(opcEXTB)='1' THEN
			OP2out <= ea_data;
		ELSIF exec(opcCHK2)='1' AND exe_opcode(10 downto 9)="00" THEN
			OP2out <= ea_data;
		ELSIF use_direct_data='1' OR (exec(exg)='1' AND execOPC='1') OR exec(get_bfoffset)='1' THEN
			OP2out <= data_write_tmp;
		ELSIF (exec(ea_data_OP1)='0' AND store_in_tmp='1') OR exec(ea_data_OP2)='1' THEN
			OP2out <= ea_data;
		ELSIF exec(opcMOVEQ)='1' THEN
			OP2out(7 downto 0) <= exe_opcode(7 downto 0);
			OP2out(15 downto 8) <= (OTHERS => exe_opcode(7));
		ELSIF exec(opcADDQ)='1' THEN
			OP2out(2 downto 0) <= exe_opcode(11 downto 9);
			IF exe_opcode(11 downto 9)="000" THEN
				OP2out(3) <='1';
			ELSE
				OP2out(3) <='0';
			END IF;
			OP2out(15 downto 4) <= (OTHERS => '0');
		ELSIF exe_datatype="10" AND exec(opcEXT)='0'  THEN
			OP2out(31 downto 16) <= reg_QB(31 downto 16);
		END IF;
		IF exec(opcEXTB)='1' THEN
			OP2out(31 downto 8) <= (OTHERS => OP2out(7));
		END IF;
	END PROCESS;

PROCESS (clk)
	BEGIN
     	IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				store_in_tmp <='0';
				direct_data <= '0';
				use_direct_data <= '0';
				Z_error <= '0';
				writePCnext <= '0';
			ELSIF clkena_lw='1' THEN
				useStackframe2<='0';
				direct_data <= '0';
				IF exec(hold_OP2)='1' THEN
					use_direct_data <= '1';
				END IF;
				IF set_direct_data='1' THEN
					direct_data <= '1';
					use_direct_data <= '1';
				ELSIF endOPC='1' OR set(ea_data_OP2)='1' THEN
					use_direct_data <= '0';
				END IF;
				exec_DIRECT <= set_exec(opcMOVE);

				IF endOPC='1' THEN
					store_in_tmp <='0';
					Z_error <= '0';
					writePCnext <= '0';
				ELSE
					IF set_Z_error='1'  THEN
						Z_error <= '1';
					END IF;
					IF set_exec(opcMOVE)='1' AND state="11" THEN
						use_direct_data <= '1';
					END IF;

					IF state="10" OR exec(store_ea_packdata)='1' THEN
						store_in_tmp <= '1';
					END IF;
					IF direct_data='1' AND state="00" THEN
						store_in_tmp <= '1';
					END IF;
				END IF;

				IF state="10" AND exec(hold_ea_data)='0' THEN
					ea_data <= data_read;
				ELSIF exec(get_2ndOPC)='1' THEN
					ea_data <= addr;
				ELSIF exec(store_ea_data)='1' OR (direct_data='1' AND state="00") THEN
					ea_data <= last_data_read;
				END IF;

				IF (cp_cir_next='1' OR cp_mem_next='1') AND setstate="11" THEN
					data_write_tmp <= cp_wdata;
				ELSIF writePC='1' THEN
					IF cp_f9='1' THEN
						data_write_tmp <= cp_scanpc;
					ELSIF cp_trap_pc='1' AND trap_interrupt='1' THEN
						data_write_tmp <= opcode_pc;
					ELSIF trap_interrupt='1' OR trap_trace='1' THEN
						data_write_tmp <= trap_pc_latched;
					ELSE
						data_write_tmp <= TG68_PC;
					END IF;
				ELSIF micro_state=trap00 THEN
					data_write_tmp <= exe_pc;
					useStackframe2 <= '1';
					IF trap_trace='0' THEN
						writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR set(trap_chk) OR Z_error;
					END IF;
				ELSIF exec(writePC_add)='1' THEN
					IF cp_f9 = '1' THEN
						data_write_tmp <= cp_scanpc;
					ELSIF cp_trap2 = '1' THEN
						data_write_tmp <= cp_npc;
					ELSIF trap_vector(9 downto 0) = "00" & X"10" OR
					   trap_vector(9 downto 0) = "00" & X"20" OR
					   trap_vector(9 downto 0) = "00" & X"28" OR
					   trap_vector(9 downto 0) = "00" & X"2C" OR
					   cp_trap_pc = '1' THEN
						data_write_tmp <= opcode_pc;
					ELSIF trap_vector(9 downto 0) = "00" & X"38" THEN
						data_write_tmp <= exe_pc;
					ELSIF trap_interrupt='1' OR trap_trace='1' THEN
						data_write_tmp <= trap_pc_latched;
					ELSE
						data_write_tmp <= TG68_PC_add;
					END IF;
				ELSIF micro_state = cp9a THEN
					data_write_tmp <= cp_tea;
				ELSIF micro_state = cp9b THEN
					data_write_tmp <= fline_brief_latch & fline_opcode_latch;
				ELSIF micro_state = cp9c THEN
					data_write_tmp <= opcode_pc;
				ELSIF micro_state = trap0 THEN
					IF cp_f9='1' THEN
						data_write_tmp(15 downto 0) <= "1001" & trap_vector(11 downto 0);
					ELSIF useStackframe2='1' THEN
						data_write_tmp(15 downto 0) <= "0010" & trap_vector(11 downto 0);
					ELSE
						data_write_tmp(15 downto 0) <= "0000" & trap_vector(11 downto 0);
						IF trap_trace='0' THEN
							writePCnext <= trap_trap OR trap_trapv OR exec(trap_chk) OR set(trap_chk) OR Z_error;
						END IF;
					END IF;
				ELSIF micro_state = int3 THEN
					data_write_tmp(15 downto 0) <= "0001" & trap_vector(11 downto 0);
					ELSIF micro_state = berr_fill AND cp_bfr = '1' AND
					      rot_cnt /= "000010" AND rot_cnt /= "000100" AND rot_cnt /= "000110" THEN
						CASE rot_cnt IS
							WHEN "000001" => data_write_tmp <= opcode_pc;
							WHEN "000011" => data_write_tmp <= cp_w & cp_wh;
							WHEN "000101" => data_write_tmp <= cp_prim & cp_len & cp_mm & cp_half & cp_pcdone & cp_cof & cp_mmcnt;
							WHEN "000111" => data_write_tmp <= "1100" & "000" & cp_bk_st & cp_bk_ss & cp_bk_dt & cp_bk_cir & cp_bk_mem &
							                                   cp_bk_off & "000000000";
							WHEN "001000" => data_write_tmp <= cp_bk_wd;
							WHEN "001001" => data_write_tmp <= cp_ea;
							WHEN "001010" => data_write_tmp <= cp_data;
							WHEN "001011" => data_write_tmp <= cp_anew;
							WHEN "001100" => data_write_tmp <= cp_mmbase;
							WHEN "001101" => data_write_tmp <= fline_brief_latch & fline_opcode_latch;
							WHEN "001110" => data_write_tmp <= cp_scanpc;
							WHEN OTHERS   => data_write_tmp <= (others => '0');
						END CASE;
					ELSIF micro_state = berr_fill THEN
						CASE rot_cnt IS
							WHEN "000100" =>
								data_write_tmp <= berr_fault_addr;
							WHEN "000010" =>
								data_write_tmp <= berr_fault_addr;
							WHEN OTHERS =>
								data_write_tmp <= (others => '0');
						END CASE;
				ELSIF micro_state = berr1 AND cp_bfr = '1' THEN
					data_write_tmp <= cp_tea;
				ELSIF micro_state = berr3 AND cp_bfr = '1' THEN
					data_write_tmp <= cp_pcbase;
				ELSIF micro_state = berr1 THEN
					data_write_tmp <= (others => '0');
				ELSIF micro_state = berr2 THEN
					data_write_tmp <= berr_data_out_saved;
				ELSIF micro_state = berr3 THEN
					data_write_tmp <= last_opc_read(15 downto 0) & berr_opcode_saved;
				ELSIF micro_state = berr4 THEN
					data_write_tmp <= berr_fault_addr;
				ELSIF micro_state = berr5 THEN
					data_write_tmp <= opcode & last_opc_read(15 downto 0);
				ELSIF micro_state = berr6 THEN
					IF berr_long_frame='0' THEN
						data_write_tmp <= x"0100" & berr_ssw;
					ELSE
						data_write_tmp <= x"0000" & berr_ssw;
					END IF;
				ELSIF micro_state = berr7 THEN
					IF trap_addr_error='1' OR berr_long_frame='1' THEN
						data_write_tmp <= berr_frame_pc(15 downto 0) & "1011" & trap_vector(11 downto 0);
					ELSE
						data_write_tmp <= berr_frame_pc(15 downto 0) & "1010" & trap_vector(11 downto 0);
					END IF;
				ELSIF micro_state = berr8 THEN
					data_write_tmp <= (trap_SR & Flags) & berr_frame_pc(31 downto 16);
				ELSIF micro_state = rte5 AND rot_cnt = "000001" AND rte_fmt_a_replay_needed = '1' THEN
					data_write_tmp <= rte_fmt_a_data_out;
				ELSIF exec(hold_dwr)='1' AND NOT (clkena_lw='1' AND micro_state=pmove_mmu_to_mem_lo) THEN
					data_write_tmp <= data_write_tmp;
				ELSIF micro_state=pmove_mmu_to_mem_hi OR micro_state=pmove_mmu_to_mem_lo
				      OR next_micro_state_c=pmove_mmu_to_mem_hi OR next_micro_state_c=pmove_mmu_to_mem_lo THEN
					data_write_tmp <= pmmu_reg_rdat;
				ELSIF exec(exg)='1' THEN
					data_write_tmp <= OP1out;
				ELSIF exec(get_ea_now)='1' AND ea_only='1' THEN
					data_write_tmp <= addr;
				ELSIF execOPC='1' THEN
					data_write_tmp <= ALUout;
				ELSIF (exec_DIRECT='1' AND state="10") THEN
					data_write_tmp <= data_read;
					IF  exec(movepl)='1' THEN
						data_write_tmp(31 downto 8) <= data_write_tmp(23 downto 0);
					END IF;
                ELSIF exec(movepl)='1' THEN
                    data_write_tmp(15 downto 0) <= reg_QB(31 downto 16);
                ELSIF direct_data='1' THEN
                    data_write_tmp <= last_data_read;
                ELSIF micro_state=int5 THEN
                    data_write_tmp(15 downto 0) <= (trap_SR(7 downto 5) & '0' & trap_SR(3 downto 0)) & Flags(7 downto 0);
                ELSIF writeSR='1'THEN
                    data_write_tmp(15 downto 0) <= trap_SR(7 downto 0)& Flags(7 downto 0);
                ELSE
                    data_write_tmp <= OP2out;
                END IF;
			END IF;
		END IF;
	END PROCESS;

	cp_an    <= regfile(conv_integer('1' & fline_opcode_latch(2 downto 0)));
	cp_part  <= "100" WHEN cp_len(7 downto 2) /= "000000" ELSE cp_len(2 downto 0);
	cp_psize <= "10" WHEN cp_len(7 downto 2) /= "000000" ELSE
	            "01" WHEN cp_len(1) = '1' ELSE "00";
	cp_psize0 <= "10" WHEN cp_prim(7 downto 2) /= "000000" ELSE
	             "01" WHEN cp_prim(1) = '1' ELSE "00";
	cp_ss    <= '1' WHEN fline_opcode_latch(8 downto 7) = "10" ELSE '0';
	cp_twait <= '1' WHEN make_trace = '1' AND fline_opcode_latch(8 downto 6) = "000" AND
	                     cp_prim(15) = '0' AND cp_prim(1) = '0' ELSE '0';
	cp_irq_take <= '1' WHEN (FlagsSR(2 downto 0) < IPL_nr OR IPL_nr = "111") AND
	                        ((micro_state = cp_dsp AND (cp_prim(15) = '1' OR cp_twait = '1') AND
	                          cp_prim(13 downto 8) = "001001" AND
	                          NOT (cp_prim(14) = '1' AND cp_pcdone = '0')) OR
	                         (micro_state = cp_fmt AND fline_opcode_latch(8 downto 6) = "100" AND
	                          cp_prim(15 downto 8) = x"01")) ELSE '0';
	cp_nocp <= '1' WHEN cp_init = '1' AND berr = '1' ELSE '0';
	berr_k  <= '0' WHEN cp_init = '1' ELSE berr;
	cp_pmmu_f <= '1' WHEN pmmu_tc_en = '1' AND pmmu_fault = '1' AND dib_sub_hit = '0' AND
	                      ((berr_exception_active = '0' AND pmmu_fault_dispatched = '0') OR pmmu_fault_was_cleared = '1') AND
	                      trap_berr = '0' AND trap_mmu_berr = '0' ELSE '0';
	cp_bf_now <= '1' WHEN cp_st_enc(micro_state) /= "00000" AND cp_init = '0' AND
	                      (berr_k = '1' OR cp_pmmu_f = '1') AND
	                      fline_context_valid = '1' AND fline_is_fpu = '1' ELSE '0';
	next_micro_state <= cp_bf WHEN cp_bf_now = '1' ELSE next_micro_state_c;
	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			ASSERT NOT (cp_bf_now = '1' AND
			            (next_micro_state_c = pmove_mmu_to_mem_hi OR next_micro_state_c = pmove_mmu_to_mem_lo OR
			             next_micro_state_c = pmove_mem_to_mmu_hi OR next_micro_state_c = pmove_mem_to_mmu_lo OR
			             next_micro_state_c = pmove_dn_lo))
				REPORT "SIMERR a coprocessor dialog's fault with a PMOVE state next" SEVERITY error;
		END IF;
	END PROCESS;
	cp_scc   <= '1' WHEN fline_opcode_latch(8 downto 6) = "001" AND fline_opcode_latch(5 downto 3) /= "001" AND
	                     NOT (fline_opcode_latch(5 downto 3) = "111" AND fline_opcode_latch(2 downto 1) /= "00") ELSE '0';
	cp_frcp  <= NOT fline_opcode_latch(6) WHEN cp_ss = '1' ELSE cp_prim(13);
	cp_badlen <= '1' WHEN (fline_opcode_latch(6) = '0' AND cp_prim(15 downto 12) /= "0000" AND
	                       cp_prim(1 downto 0) /= "00") OR
	                      (fline_opcode_latch(6) = '1' AND cp_data(31 downto 28) /= "0000" AND
	                       cp_data(17 downto 16) /= "00") ELSE '0';

	PROCESS (cp_w, regfile)
		VARIABLE x : std_logic_vector(31 downto 0);
	BEGIN
		x := regfile(conv_integer(cp_w(15 downto 12)));
		IF cp_w(11) = '0' THEN
			x(31 downto 16) := (OTHERS => x(15));
		END IF;
		CASE cp_w(10 downto 9) IS
			WHEN "01"   => x := x(30 downto 0) & '0';
			WHEN "10"   => x := x(29 downto 0) & "00";
			WHEN "11"   => x := x(28 downto 0) & "000";
			WHEN OTHERS => NULL;
		END CASE;
		cp_xn <= x;
	END PROCESS;

	PROCESS (fline_opcode_latch, cp_prim)
		VARIABLE m, r : std_logic_vector(2 downto 0);
		VARIABLE dn, an, mem, ctl, alt, dat, val, imm, ok, pv : boolean;
		VARIABLE len : std_logic_vector(7 downto 0);
	BEGIN
		m := fline_opcode_latch(5 downto 3);
		r := fline_opcode_latch(2 downto 0);
		len := cp_prim(7 downto 0);
		dn  := m = "000";
		an  := m = "001";
		val := m /= "111" OR r(2) = '0' OR r(1 downto 0) = "00";
		imm := m = "111" AND r = "100";
		mem := (m /= "000" AND m /= "001" AND m /= "111") OR (m = "111" AND val);
		ctl := m = "010" OR m = "101" OR m = "110" OR (m = "111" AND r(2) = '0');
		alt := m /= "111" OR r(2 downto 1) = "00";
		dat := val AND NOT an;
		IF cp_prim(12 downto 8) = "00001" THEN
			IF cp_prim(13) = '0' THEN
				ok := ctl OR m = "011";
			ELSE
				ok := (ctl AND alt) OR m = "100";
			END IF;
			pv := len(0) = '1';
		ELSE
			CASE cp_prim(10 downto 8) IS
				WHEN "000"  => ok := ctl AND alt;
				WHEN "001"  => ok := dat AND alt;
				WHEN "010"  => ok := mem AND alt;
				WHEN "011"  => ok := alt;
				WHEN "100"  => ok := ctl;
				WHEN "101"  => ok := dat;
				WHEN "110"  => ok := mem;
				WHEN OTHERS => ok := val;
			END CASE;
			pv := ((dn OR an) AND NOT (len = x"01" OR len = x"02" OR len = x"04")) OR
			      (imm AND (cp_prim(13) = '1' OR (len(0) = '1' AND len /= x"01"))) OR
			      (cp_prim(13) = '1' AND NOT alt);
		END IF;
		IF ok THEN cp_ea_ok <= '1'; ELSE cp_ea_ok <= '0'; END IF;
		IF pv THEN cp_pv <= '1'; ELSE cp_pv <= '0'; END IF;
	END PROCESS;

	PROCESS (micro_state, fline_opcode_latch, cp_ea, cp_anew, cp_mmbase, cp_mm, cp_mmcnt, cp_prim, data_read, regfile, cp_bf_now)
		VARIABLE n : std_logic_vector(3 downto 0);
	BEGIN
		n := fline_opcode_latch(3 downto 0);
		cp_reg_we <= '0';
		cp_reg_n  <= '1' & fline_opcode_latch(2 downto 0);
		cp_reg_d  <= cp_ea;
		IF micro_state = cp_prea THEN
			cp_reg_we <= '1';
		ELSIF micro_state = cp_fin AND NOT (cp_mm = '1' AND cp_mmcnt /= "0000") THEN
			IF fline_opcode_latch(5 downto 3) = "011" THEN
				cp_reg_we <= '1';
				IF cp_mm = '0' THEN
					cp_reg_d <= cp_anew;
				END IF;
			ELSIF fline_opcode_latch(5 downto 3) = "100" AND cp_mm = '1' THEN
				cp_reg_we <= '1';
				cp_reg_d <= cp_mmbase;
			END IF;
		ELSIF micro_state = cp_sccd THEN
			cp_reg_we <= '1';
			cp_reg_n <= '0' & n(2 downto 0);
			cp_reg_d <= regfile(conv_integer('0' & n(2 downto 0)));
			cp_reg_d(7 downto 0) <= (others => cp_prim(0));
		ELSIF micro_state = cp_db THEN
			cp_reg_we <= '1';
			cp_reg_n <= '0' & n(2 downto 0);
			cp_reg_d <= regfile(conv_integer('0' & n(2 downto 0)));
			cp_reg_d(15 downto 0) <= regfile(conv_integer('0' & n(2 downto 0)))(15 downto 0) - 1;
		ELSIF micro_state = cp_rdreg THEN
			cp_reg_we <= '1';
			cp_reg_n <= n;
			IF n(3) = '1' THEN
				IF cp_prim(7 downto 0) = x"01" THEN
					cp_reg_d <= (31 downto 8 => data_read(7)) & data_read(7 downto 0);
				ELSIF cp_prim(7 downto 0) = x"02" THEN
					cp_reg_d <= (31 downto 16 => data_read(15)) & data_read(15 downto 0);
				ELSE
					cp_reg_d <= data_read;
				END IF;
			ELSE
				cp_reg_d <= regfile(conv_integer(n));
				IF cp_prim(7 downto 0) = x"01" THEN
					cp_reg_d(7 downto 0) <= data_read(7 downto 0);
				ELSIF cp_prim(7 downto 0) = x"02" THEN
					cp_reg_d(15 downto 0) <= data_read(15 downto 0);
				ELSE
					cp_reg_d <= data_read;
				END IF;
			END IF;
		END IF;
		IF cp_bf_now = '1' THEN
			cp_reg_we <= '0';
		END IF;
	END PROCESS;

	PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				cp_cir <= '0';
				cp_prim <= (others => '0');
				cp_pcdone <= '0';
				cp_trap_pc <= '0';
				cp_init <= '0';
				cp_bfr <= '0';
			ELSIF clkena_lw = '1' AND cp_bf_now = '1' THEN
				cp_cir <= '0';
			ELSIF clkena_lw = '1' THEN
				cp_cir <= cp_cir_next;
				IF (micro_state = cp_rspw OR micro_state = cp_fmtw) AND beat_valid = '1' THEN
					cp_prim <= data_read(15 downto 0);
					cp_pcdone <= '0';
				END IF;
				IF micro_state = cp_pcw THEN
					cp_pcdone <= '1';
				END IF;
				IF micro_state = cp_eat AND cp_ss = '1' THEN
					cp_half <= '0';
					cp_mm <= '0';
					cp_w <= pmmu_brief;
					cp_pcbase <= fline_opcode_pc;
					IF cp_prim(15 downto 12) = "0000" THEN
						cp_len <= x"00";
					ELSE
						cp_len <= cp_prim(7 downto 0);
					END IF;
					IF fline_opcode_latch(5 downto 3) = "100" THEN
						IF cp_prim(15 downto 12) = "0000" THEN
							cp_ea <= cp_an - 4;
						ELSE
							cp_ea <= cp_an - 4 - cp_prim(7 downto 0);
						END IF;
					ELSE
						cp_ea <= cp_an;
					END IF;
				ELSIF micro_state = cp_eat AND cp_scc = '1' THEN
					cp_len <= x"01";
					cp_half <= '0';
					cp_mm <= '0';
					cp_pcbase <= TG68_PC;
					IF fline_opcode_latch(5 downto 3) = "100" THEN
						IF fline_opcode_latch(2 downto 0) = "111" THEN
							cp_ea <= cp_an - 2;
						ELSE
							cp_ea <= cp_an - 1;
						END IF;
					ELSE
						cp_ea <= cp_an;
					END IF;
					IF fline_opcode_latch(2 downto 0) = "111" THEN
						cp_anew <= cp_an + 2;
					ELSE
						cp_anew <= cp_an + 1;
					END IF;
				ELSIF micro_state = cp_eat THEN
					cp_len <= cp_prim(7 downto 0);
					cp_half <= '0';
					cp_pcbase <= TG68_PC;
					IF cp_prim(12 downto 8) = "00001" THEN
						cp_mm <= '1';
					ELSE
						cp_mm <= '0';
					END IF;
					IF fline_opcode_latch(5 downto 3) = "100" AND cp_prim(12 downto 8) /= "00001" THEN
						IF fline_opcode_latch(2 downto 0) = "111" AND cp_prim(7 downto 0) = x"01" THEN
							cp_ea <= cp_an - 2;
						ELSE
							cp_ea <= cp_an - cp_prim(7 downto 0);
						END IF;
					ELSE
						cp_ea <= cp_an;
					END IF;
					IF fline_opcode_latch(2 downto 0) = "111" AND cp_prim(7 downto 0) = x"01" THEN
						cp_anew <= cp_an + 2;
					ELSE
						cp_anew <= cp_an + cp_prim(7 downto 0);
					END IF;
				END IF;
				IF micro_state = cp_sfw THEN
					cp_ea <= cp_ea + cp_len;
				END IF;
				IF micro_state = cp_rfr AND beat_valid = '1' THEN
					cp_data <= data_read;
				END IF;
				IF micro_state = cp_rfww THEN
					cp_ea <= cp_ea + 4;
					cp_len <= cp_data(23 downto 16);
					IF cp_data(31 downto 28) = "0000" THEN
						cp_anew <= cp_ea + 4;
					ELSE
						cp_anew <= cp_ea + 4 + cp_data(23 downto 16);
					END IF;
				END IF;
				IF (micro_state = cp_extw OR micro_state = cp_dlw) AND beat_valid = '1' THEN
					cp_w <= data_read(15 downto 0);
				END IF;
				IF micro_state = cp_cond THEN
					cp_half <= '0';
				ELSIF micro_state = cp_tsk THEN
					cp_half <= '1';
				END IF;
				IF micro_state = cp_trp THEN
					cp_npc <= TG68_PC;
				END IF;
				IF micro_state = cp_dsp THEN
					IF fline_opcode_latch(8 downto 7) = "01" THEN
						cp_scanpc <= fline_opcode_pc;
					ELSE
						cp_scanpc <= TG68_PC;
					END IF;
				END IF;
				IF micro_state = cp_eat OR micro_state = cp_ea1 OR micro_state = cp_extw2 THEN
					cp_tea_ld <= '1';
				ELSE
					cp_tea_ld <= '0';
				END IF;
				IF cp_tea_ld = '1' THEN
					cp_tea <= cp_ea;
				END IF;
				IF micro_state = rte5 AND beat_valid = '1' AND rte_format_word(15 downto 12) = "1001" THEN
					CASE rot_cnt IS
						WHEN "000011" => cp_rte_pc <= data_read;
						WHEN "000010" => cp_rte_iw <= data_read;
						WHEN "000001" => cp_tea <= data_read;
						WHEN OTHERS   => NULL;
					END CASE;
				END IF;
				IF trap_cp9 = '1' OR (micro_state = cp_irq AND interrupt = '1' AND trap_interrupt = '1' AND
				                      fline_opcode_latch(8 downto 6) /= "100") THEN
					cp_f9 <= '1';
				ELSIF setopcode = '1' THEN
					cp_f9 <= '0';
				END IF;
				IF micro_state = cp_ea1 THEN
					CASE fline_opcode_latch(5 downto 3) IS
						WHEN "101" =>
							cp_ea <= cp_an + ((31 downto 16 => cp_w(15)) & cp_w);
						WHEN "110" =>
							cp_ea <= cp_an + ((31 downto 8 => cp_w(7)) & cp_w(7 downto 0)) + cp_xn;
						WHEN OTHERS =>
							CASE fline_opcode_latch(2 downto 0) IS
								WHEN "000" => cp_ea <= (31 downto 16 => cp_w(15)) & cp_w;
								WHEN "001" => cp_wh <= cp_w;
								WHEN "010" => cp_ea <= cp_pcbase + ((31 downto 16 => cp_w(15)) & cp_w);
								WHEN OTHERS => cp_ea <= cp_pcbase + ((31 downto 8 => cp_w(7)) & cp_w(7 downto 0)) + cp_xn;
							END CASE;
					END CASE;
				END IF;
				IF micro_state = cp_extw2 AND beat_valid = '1' THEN
					cp_ea <= cp_wh & data_read(15 downto 0);
				END IF;
				IF (micro_state = cp_mrdw OR micro_state = cp_ordw) AND beat_valid = '1' THEN
					cp_data <= data_read;
				END IF;
				IF micro_state = cp_oww OR micro_state = cp_mww THEN
					IF cp_ss = '1' AND cp_frcp = '1' THEN
						cp_ea <= cp_ea - 4;
					ELSE
						cp_ea <= cp_ea + cp_part;
					END IF;
					cp_len <= cp_len - cp_part;
				END IF;
				IF micro_state = cp_rdreg THEN
					cp_len <= x"00";
				END IF;
				IF micro_state = cp_imw AND beat_valid = '1' THEN
					IF cp_part = "100" AND cp_half = '0' THEN
						cp_data(31 downto 16) <= data_read(15 downto 0);
						cp_half <= '1';
					ELSE
						IF cp_part = "001" THEN
							cp_data(7 downto 0) <= data_read(7 downto 0);
						ELSE
							cp_data(15 downto 0) <= data_read(15 downto 0);
						END IF;
						cp_half <= '0';
					END IF;
				END IF;
				IF micro_state = cp_rselw AND beat_valid = '1' THEN
					cp_mmcnt <= ("000" & data_read(15)) + ("000" & data_read(14)) + ("000" & data_read(13)) +
					            ("000" & data_read(12)) + ("000" & data_read(11)) + ("000" & data_read(10)) +
					            ("000" & data_read(9)) + ("000" & data_read(8));
					cp_mmbase <= cp_ea;
				END IF;
				IF micro_state = cp_mmreg AND cp_mmcnt /= "0000" THEN
					cp_len <= cp_prim(7 downto 0);
					cp_mmcnt <= cp_mmcnt - 1;
					IF fline_opcode_latch(5 downto 3) = "100" THEN
						cp_mmbase <= cp_mmbase - cp_prim(7 downto 0);
						cp_ea <= cp_mmbase - cp_prim(7 downto 0);
					END IF;
				END IF;
				IF trap_cp = '1' OR (micro_state = cp_irq AND interrupt = '1' AND trap_interrupt = '1' AND
				                     fline_opcode_latch(8 downto 6) = "100") THEN
					cp_trap_pc <= '1';
				ELSIF setopcode = '1' THEN
					cp_trap_pc <= '0';
				END IF;
				IF trap_cptrap = '1' THEN
					cp_trap2 <= '1';
				ELSIF setopcode = '1' THEN
					cp_trap2 <= '0';
				END IF;
				IF micro_state = cp_bcc AND cp_ss = '0' THEN
					cp_cof <= '1';
				ELSIF setopcode = '1' THEN
					cp_cof <= '0';
				END IF;
				IF (micro_state = cp_decode AND fline_context_valid = '1' AND
				    fline_opcode_latch(8 downto 6) /= "101") OR micro_state = cp_rfw THEN
					cp_init <= '1';
				ELSIF micro_state = cp_rsp OR micro_state = cp_fmtw OR micro_state = cp_rfww THEN
					cp_init <= '0';
				END IF;
				IF cp_st_enc(next_micro_state) /= "00000" AND setstate /= "01" THEN
					cp_bk_st  <= cp_st_enc(next_micro_state);
					cp_bk_ss  <= setstate;
					cp_bk_dt  <= datatype;
					cp_bk_cir <= cp_cir_next;
					cp_bk_mem <= cp_mem_next;
					cp_bk_off <= cp_cir_off;
					cp_bk_wd  <= cp_wdata;
					cp_bk_pc  <= TG68_PC;
				END IF;
				IF micro_state = cp_bf THEN
					cp_bfr <= '1';
				ELSIF setopcode = '1' THEN
					cp_bfr <= '0';
				END IF;
				IF micro_state = rte5 AND beat_valid = '1' AND rte_format_word(15 downto 12) = "1011" THEN
					CASE rot_cnt IS
						WHEN "010010" => cp_rb_pcb  <= data_read;
						WHEN "010000" => cp_rb_tea  <= data_read;
						WHEN "001111" => cp_rb_opc  <= data_read;
						WHEN "001101" => cp_rb_w    <= data_read;
						WHEN "001011" => cp_rb_prim <= data_read;
						WHEN "001001" => cp_rb      <= data_read;
						WHEN "001000" => cp_rb_wd   <= data_read;
						WHEN "000111" => cp_rb_ea   <= data_read;
						WHEN "000110" => cp_rb_data <= data_read;
						WHEN "000101" => cp_rb_anew <= data_read;
						WHEN "000100" => cp_rb_mmb  <= data_read;
						WHEN "000011" => cp_rb_iw   <= data_read;
						WHEN "000010" => cp_rb_spc  <= data_read;
						WHEN OTHERS   => NULL;
					END CASE;
				END IF;
				IF micro_state = cp_rsm THEN
					cp_prim   <= cp_rb_prim(31 downto 16);
					cp_len    <= cp_rb_prim(15 downto 8);
					cp_mm     <= cp_rb_prim(7);
					cp_half   <= cp_rb_prim(6);
					cp_pcdone <= cp_rb_prim(5);
					cp_cof    <= cp_rb_prim(4);
					cp_mmcnt  <= cp_rb_prim(3 downto 0);
					cp_bk_st  <= cp_rb(24 downto 20);
					cp_bk_ss  <= cp_rb(19 downto 18);
					cp_bk_dt  <= cp_rb(17 downto 16);
					cp_bk_cir <= cp_rb(15);
					cp_bk_mem <= cp_rb(14);
					cp_bk_off <= cp_rb(13 downto 9);
					cp_bk_wd  <= cp_rb_wd;
					cp_ea     <= cp_rb_ea;
					cp_data   <= cp_rb_data;
					cp_anew   <= cp_rb_anew;
					cp_mmbase <= cp_rb_mmb;
					cp_w      <= cp_rb_w(31 downto 16);
					cp_wh     <= cp_rb_w(15 downto 0);
					cp_pcbase <= cp_rb_pcb;
					cp_tea    <= cp_rb_tea;
					cp_scanpc <= cp_rb_spc;
				END IF;
			END IF;
		END IF;
	END PROCESS;

PROCESS (brief, OP1out, OP1outbrief, cpu)
	BEGIN
		IF brief(11)='1' THEN
			OP1outbrief <= OP1out(31 downto 16);
		ELSE
			OP1outbrief <= (OTHERS=>OP1out(15));
		END IF;
		briefdata <= OP1outbrief&OP1out(15 downto 0);
		IF extAddr_Mode=1 OR (cpu(1)='1' AND extAddr_Mode=2) THEN
			CASE brief(10 downto 9) IS
				WHEN "00" => briefdata <= OP1outbrief&OP1out(15 downto 0);
				WHEN "01" => briefdata <= OP1outbrief(14 downto 0)&OP1out(15 downto 0)&'0';
				WHEN "10" => briefdata <= OP1outbrief(13 downto 0)&OP1out(15 downto 0)&"00";
				WHEN "11" => briefdata <= OP1outbrief(12 downto 0)&OP1out(15 downto 0)&"000";
				WHEN OTHERS => NULL;
			END CASE;
		END IF;
	END PROCESS;

	PROCESS (clk, setdisp, memaddr_a, briefdata, memaddr_delta, setdispbyte, datatype, interrupt, rIPL_nr, IPL_vec,
	         memaddr_reg, memaddr_delta_rega, memaddr_delta_regb, reg_QA, use_base, VBR, last_data_read, trap_vector, exec, set, cpu, use_VBR_Stackframe,
	         pmove_disp_latched, micro_state, opcode, fline_opcode_latch, moves_ea_areg, moves_bus_pending, memmaskmux, rot_cnt,
	         moves_ea_latched, moves_ea_use_base, pmove_ea_latched, pmmu_brief,
	         rte_fmt_a_replay_needed, rte_fmt_a_fault_addr)
	BEGIN

		IF rising_edge(clk) THEN
			IF clkena_core='1' THEN
				trap_vector(31 downto 10) <= (others => '0');
				IF trap_illegal='1' THEN
					trap_vector(9 downto 0) <= "00" & X"10";
				END IF;
				IF trap_priv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"20";
				END IF;
				IF set_Z_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"14";
				END IF;
				IF exec(trap_chk)='1' OR set(trap_chk)='1' THEN
					trap_vector(9 downto 0) <= "00" & X"18";
				END IF;
				IF trap_trapv='1' AND trap_trace='0' THEN
					trap_vector(9 downto 0) <= "00" & X"1C";
				END IF;
				IF trap_trace='1' THEN
					trap_vector(9 downto 0) <= "00" & X"24";
				END IF;
				IF trap_1010='1' THEN
					trap_vector(9 downto 0) <= "00" & X"28";
				END IF;
				IF trap_1111='1' THEN
					trap_vector(9 downto 0) <= "00" & X"2C";
				END IF;
				IF trap_cptrap='1' THEN
					trap_vector(9 downto 0) <= "00" & X"1C";
				END IF;
				IF trap_cppv='1' THEN
					trap_vector(9 downto 0) <= "00" & X"34";
				END IF;
				IF trap_cp='1' AND trap_cpfmt='1' THEN
					trap_vector(9 downto 0) <= "00" & X"38";
				ELSIF trap_cp='1' THEN
					trap_vector(9 downto 0) <= cp_prim(7 downto 0) & "00";
				END IF;
				IF trap_trap='1' AND trap_trace='0' THEN
					trap_vector(9 downto 0) <= "0010" & opcode(3 downto 0) & "00";
				END IF;
					IF trap_interrupt='1' THEN
						trap_vector(9 downto 0) <= IPL_vec & "00";
					END IF;
				IF trap_mmu_config='1' THEN
					trap_vector(9 downto 0) <= "00" & X"E0";
				END IF;
				IF trap_addr_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"0C";
				END IF;
				IF trap_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;
				IF trap_mmu_berr='1' THEN
					trap_vector(9 downto 0) <= "00" & X"08";
				END IF;
				IF trap_format_error='1' THEN
					trap_vector(9 downto 0) <= "00" & X"38";
				END IF;
				IF micro_state = trace_stk_grp2 THEN
					trap_vector(9 downto 0) <= "00" & X"24";
				END IF;

				trap_vector_latched <= trap_vector_vbr;
			END IF;
		END IF;
		IF use_VBR_Stackframe='1' THEN
			trap_vector_vbr <= trap_vector+VBR;
		ELSE
			trap_vector_vbr <= trap_vector;
		END IF;

		memaddr_a(4 downto 0) <= "00000";
		memaddr_a(7 downto 5) <= (OTHERS=>memaddr_a(4));
		memaddr_a(15 downto 8) <= (OTHERS=>memaddr_a(7));
		memaddr_a(31 downto 16) <= (OTHERS=>memaddr_a(15));
		IF setdisp='1' THEN
			IF exec(briefext)='1' THEN
				memaddr_a <= briefdata+memaddr_delta;
			ELSIF setdispbyte='1' THEN
				memaddr_a(7 downto 0) <= last_data_read(7 downto 0);
			ELSE
				memaddr_a <= last_data_read;
			END IF;
			ELSIF set(presub)='1' THEN
				IF set(pmmu_dbl)='1' THEN
					memaddr_a(4 downto 0) <= "11000";
				ELSIF set(longaktion)='1' THEN
					memaddr_a(4 downto 0) <= "11100";
				ELSIF datatype="00" AND set(use_SP)='0' THEN
					memaddr_a(4 downto 0) <= "11111";
				ELSE
					memaddr_a(4 downto 0) <= "11110";
				END IF;
		ELSIF interrupt='1' THEN
			memaddr_a(4 downto 0) <= '1'&rIPL_nr&'0';
		END IF;

		IF rising_edge(clk) THEN
			IF clkena_core='1' THEN
				IF exec(get_2ndOPC)='1' OR (state="10" AND memread(1 downto 0)="11") THEN
					tmp_TG68_PC <= addr;
				END IF;
					use_base <= '0';
					memaddr_delta_regb <= (others => '0');
					IF micro_state = rte_mmu_replay AND
					   (state = "00" OR (state(1) = '1' AND memmaskmux(3) = '1' AND setstate = "00")) THEN
						memaddr_delta_rega <= TG68_PC_add;
						use_base <= '0';
					ELSIF cp_cir_next = '1' AND memmaskmux(3) = '1' THEN
						memaddr_delta_rega <= x"0002" & fline_opcode_latch(11 downto 9) & x"00" & cp_cir_off;
						use_base <= '0';
					ELSIF cp_mem_next = '1' AND memmaskmux(3) = '1' THEN
						memaddr_delta_rega <= cp_ea;
						use_base <= '0';
					ELSIF (micro_state = rte5 AND rot_cnt = "000001" AND
					       rte_fmt_a_replay_needed = '1' AND memmaskmux(3) = '1') OR
					      (micro_state = rte_mmu_replay AND memmaskmux(3) = '1') THEN
						memaddr_delta_rega <= rte_fmt_a_fault_addr;
						use_base <= '0';
					ELSIF moves_bus_pending = '1' AND
				   (state = "00" OR (state(1) = '1' AND memmaskmux(3) = '1' AND setstate = "00")) AND
				   micro_state /= moves0 AND micro_state /= moves1 THEN
					memaddr_delta_rega <= TG68_PC_add;
				ELSIF (micro_state = moves1 OR moves_bus_pending = '1') AND
				    opcode(15 downto 8) = "00001110" AND opcode(7 downto 6) /= "11" AND
				    (opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" OR opcode(5 downto 3) = "111") AND
				    memmaskmux(3)='1' THEN
					memaddr_delta_rega <= moves_ea_latched;
					use_base <= moves_ea_use_base;
				ELSIF (micro_state = moves0 OR micro_state = moves1 OR moves_bus_pending = '1') AND
				    (moves_ea_areg = '1' OR opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100") AND
				    opcode(5 downto 3) /= "100" AND
				    memmaskmux(3)='1' THEN
					memaddr_delta_rega <= (others => '0');
					use_base <= '1';
					ELSIF (micro_state = pmove_mmu_to_mem_lo OR micro_state = pmove_mem_to_mmu_lo) AND
					      memmaskmux(3)='1' AND setstate /= "00" THEN
						memaddr_delta_rega <= pmove_ea_latched;
						use_base <= '0';
					ELSIF micro_state = pmove_decode AND
					      fline_opcode_latch(15 downto 12) = "1111" AND
					      fline_opcode_latch(5 downto 3) = "100" AND
					      (pmmu_brief(15 downto 13) = "000" OR pmmu_brief(15 downto 13) = "010" OR
					       pmmu_brief(15 downto 13) = "011") THEN
						IF pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" THEN
							memaddr_delta_rega <= x"FFFFFFF8";
						ELSIF pmmu_brief(14 downto 10) = "11000" THEN
							memaddr_delta_rega <= x"FFFFFFFE";
						ELSE
							memaddr_delta_rega <= x"FFFFFFFC";
						END IF;
						use_base <= '1';

					ELSIF micro_state = pmove_decode AND setstate /= "00" AND
					      fline_opcode_latch(15 downto 12)="1111" AND
					      (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") AND
					      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011") THEN
						memaddr_delta_rega <= (others => '0');
						use_base <= '1';

					ELSIF (micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo OR
					       micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_mem_to_mmu_lo) AND
					      fline_opcode_latch(15 downto 12)="1111" AND
					      (pmmu_brief(15 downto 13)="000" OR pmmu_brief(15 downto 13)="010" OR pmmu_brief(15 downto 13)="011") AND
					      (fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011" OR
					       fline_opcode_latch(5 downto 3)="100" OR
					       fline_opcode_latch(5 downto 3)="101" OR fline_opcode_latch(5 downto 3)="110" OR
					       fline_opcode_latch(5 downto 3)="111") AND
					      memmaskmux(3)='1' AND setstate /= "00" THEN
						IF micro_state = pmove_mem_to_mmu_hi AND
						   (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
							memaddr_delta_rega <= addr + ("00000000000000000000000000000" & beat_step);
							use_base <= '0';
						ELSIF fline_opcode_latch(5 downto 3)="010" OR fline_opcode_latch(5 downto 3)="011"
						   OR fline_opcode_latch(5 downto 3)="100" THEN
							memaddr_delta_rega <= (others => '0');
							use_base <= '1';
						ELSIF fline_opcode_latch(5 downto 3)="101" THEN
							memaddr_delta_rega <= last_data_read;
							use_base <= '1';
						ELSIF fline_opcode_latch(5 downto 3)="110" THEN
							use_base <= '1';
						ELSIF fline_opcode_latch(5 downto 3)="111" THEN
							IF fline_opcode_latch(2 downto 0)="001" THEN
									memaddr_delta_rega <= pmove_disp_latched;
								ELSE
									memaddr_delta_rega <= last_data_read;
								END IF;
							use_base <= '0';
						END IF;
					ELSIF directpc_retry_hold='1' THEN
						use_base <= use_base;
						memaddr_delta_regb <= memaddr_delta_regb;
					ELSIF (memmaskmux(3)='0' OR exec(mem_addsub)='1') AND NOT
				      ((micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mmu_to_mem_lo) AND
				       fline_opcode_latch(5 downto 3)="100" AND state /= "11") AND NOT
				      (state="11" AND memmaskmux(3)='1' AND setstate="00") THEN
						memaddr_delta_rega <= addsub_q;
				ELSIF set(restore_ADDR)='1' THEN
					memaddr_delta_rega <= tmp_TG68_PC;
				ELSIF exec(direct_delta)='1' THEN
					memaddr_delta_rega <= data_read;
				ELSIF exec(ea_to_pc)='1' AND setstate="00" THEN
					memaddr_delta_rega <= addr;
				ELSIF set(addrlong)='1' AND micro_state = pmmu_ld_nn AND
				      fline_context_valid = '1' AND
				      fline_opcode_latch(5 downto 3)="111" AND fline_opcode_latch(2 downto 0)="001" THEN
						memaddr_delta_rega <= pmove_disp_latched;
						use_base <= '0';
				ELSIF set(addrlong)='1' THEN
					memaddr_delta_rega <= last_data_read;
				ELSIF setstate="00" AND moves_bus_pending = '0' THEN
					memaddr_delta_rega <= TG68_PC_add;
				ELSIF exec(dispouter)='1' THEN
					memaddr_delta_rega <= ea_data;
					memaddr_delta_regb <= memaddr_a;
				ELSIF set_vectoraddr='1' THEN
					use_base <= '0';
					memaddr_delta_rega <= trap_vector_latched;
				ELSIF micro_state = ld_229_1 AND state = "00" AND brief(5) = '1' AND
				      opcode(15 downto 8) = "00001110" AND opcode(7 downto 6) /= "11" AND
				      opcode(5 downto 3) = "110" THEN
					memaddr_delta_rega <= data_read;
					IF brief(7) = '0' THEN
						use_base <= '1';
					END IF;
				ELSIF (micro_state = pload1 OR micro_state = ptest1 OR micro_state = pflush1) AND
				      fline_context_valid = '1' AND setstate /= "00" THEN
					memaddr_delta_rega <= memaddr_delta_rega;
					use_base <= use_base;
				ELSE
					memaddr_delta_rega <= memaddr_a;
					IF interrupt='0' AND Suppress_Base='0' THEN
						use_base <= '1';
					END IF;
				END IF;

					if ((memread(1 downto 0) = "11") and state(1) = '1') or movem_presub = '0' then
						memaddr <= addr;
					END IF;
			END IF;
		END IF;

		memaddr_delta <= memaddr_delta_rega + memaddr_delta_regb;

        addr <= memaddr_reg+memaddr_delta;
        pmmu_addr_log_int <= memaddr_reg + memaddr_delta;

		IF use_base='0' THEN
			memaddr_reg <= (others=>'0');
		ELSE
			memaddr_reg <= reg_QA;
		END IF;
    END PROCESS;

PROCESS (clk, IPL, setstate, addrvalue, state, exec_write_back, set_direct_data, direct_data, next_micro_state, micro_state, stop, make_trace, make_trace_t0, make_berr, IPL_nr, FlagsSR, set_rot_cnt, opcode, writePCbig, set_exec, exec,
        PC_dataa, PC_datab, setnextpass, last_data_read, TG68_PC_brw, TG68_PC_word, Z_error, trap_trap, trap_trapv, interrupt, tmp_TG68_PC, TG68_PC, use_VBR_Stackframe, writePCnext, pmove_dn_mode, cpu_halted, exe_condition, dbcc_t0_suppress, c_out,
        rte_b_resume_refetch, opc_buf_valid, beat_valid, dib_sub_hit, cp_br_sel, cp_br_disp, fline_opcode_pc, cp_irq_take, cp_cof)
	variable v_is_cof : std_logic;
	variable v_irq_pending : std_logic;
	variable v_pmmu_datatype : std_logic_vector(1 downto 0);
	BEGIN

		PC_dataa <= TG68_PC;
		IF TG68_PC_brw = '1' THEN
			PC_dataa <= tmp_TG68_PC;
		END IF;
		IF cp_br_sel = '1' THEN
			PC_dataa <= fline_opcode_pc;
		END IF;

		PC_datab(2 downto 0) <= (others => '0');
		PC_datab(3) <= PC_datab(2);
		PC_datab(7 downto 4) <= (others => PC_datab(3));
		PC_datab(15 downto 8) <= (others => PC_datab(7));
		PC_datab(31 downto 16) <= (others => PC_datab(15));
		IF interrupt='1' THEN
			PC_datab(2 downto 1) <= "11";
		END IF;
		IF exec(writePC_add) ='1' THEN
			IF writePCbig='1' OR set_writePCbig='1' THEN
				PC_datab(1) <= '1';
			ELSE
				PC_datab(2) <= '1';
			END IF;
			IF (use_VBR_Stackframe='0' AND (trap_trap='1' OR trap_trapv='1' OR exec(trap_chk)='1' OR set(trap_chk)='1' OR Z_error='1')) OR writePCnext='1' THEN
				PC_datab(1) <= '1';
			END IF;
		ELSIF state="00" AND pmmu_busy='0' THEN
			PC_datab(1) <= '1';
		END IF;
		IF TG68_PC_brw = '1' THEN
			IF TG68_PC_word='1' THEN
				PC_datab <= last_data_read;
			ELSE
				PC_datab(7 downto 0) <= opcode(7 downto 0);
			END IF;
		END IF;
		IF cp_br_sel = '1' THEN
			PC_datab <= cp_br_disp;
		END IF;

		TG68_PC_add <= PC_dataa+PC_datab;

		setopcode <= '0';
		setendOPC <= '0';
		setinterrupt <= '0';

		v_is_cof := '0';
		IF cpu(1) = '1' THEN
			IF opcode(15 downto 12) = "0110" AND opcode(11 downto 8) = "0000" THEN
				v_is_cof := '1';
			END IF;
			IF opcode(15 downto 12) = "0110" AND opcode(11 downto 8) = "0001" THEN
				v_is_cof := '1';
			END IF;
			IF opcode(15 downto 12) = "0110" AND opcode(11 downto 8) /= "0000"
			   AND opcode(11 downto 8) /= "0001" AND exe_condition = '1' THEN
				v_is_cof := '1';
			END IF;
			IF opcode(15 downto 12) = "0101" AND opcode(7 downto 3) = "11001"
			   AND exe_condition = '0' THEN
				IF micro_state = dbcc1 THEN
					IF c_out(1) = '1' OR last_data_read(0) = '1' THEN
						v_is_cof := '1';
					END IF;
				ELSIF dbcc_t0_suppress = '0' THEN
					v_is_cof := '1';
				END IF;
			END IF;
			IF opcode(15 downto 6) = "0100111011" THEN
				v_is_cof := '1';
			END IF;
			IF opcode(15 downto 6) = "0100111010" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"4E75" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"4E73" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"4E77" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"4E74" THEN
				v_is_cof := '1';
			END IF;
			IF opcode(15 downto 6) = "0100011011" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"027C" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"007C" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"0A7C" THEN
				v_is_cof := '1';
			END IF;
			IF opcode = x"4E72" THEN
				v_is_cof := '1';
			END IF;
			IF cp_cof = '1' THEN
				v_is_cof := '1';
			END IF;
		END IF;
		v_irq_pending := '0';
		IF FlagsSR(2 downto 0)<IPL_nr OR IPL_nr="111" THEN
			v_irq_pending := '1';
		END IF;
		IF (setstate="00" OR (setstate="01" AND fline_context_valid='1')) AND next_micro_state=idle AND setnextpass='0' AND (exec_write_back='0' OR state="11") AND set_rot_cnt="000001" AND set_exec(opcCHK)='0' AND (micro_state /= pmmu_dn_read_wait OR state="00") AND micro_state /= pmove_decode AND micro_state /= pmove_mem_to_mmu_hi AND micro_state /= pmove_mem_to_mmu_lo AND micro_state /= pmove_mmu_to_mem_hi AND micro_state /= pmove_mmu_to_mem_lo AND micro_state /= ptest1 AND micro_state /= pflush1 AND micro_state /= pload1 AND cpu_halted='0' THEN
			setendOPC <= '1';
			IF ((v_irq_pending = '1') AND opcode /= x"4E73") OR make_trace='1' OR (make_trace_t0='1' AND v_is_cof='1') OR make_berr='1'
			   OR (pmmu_tc_en='1' AND pmmu_fault='1' AND dib_sub_hit='0' AND
			       ((berr_exception_active='0' AND pmmu_fault_dispatched='0') OR pmmu_fault_was_cleared='1') AND
			       trap_berr='0' AND trap_mmu_berr='0')
			   OR TG68_PC(0)='1' THEN
				setinterrupt <= '1';
			ELSIF stop='0' AND NOT (rte_b_resume_refetch='1' AND state /= "00")
			              AND NOT (state /= "00" AND opc_buf_valid='0')
			              AND NOT (state = "00" AND beat_valid='0') THEN
				setopcode <= '1';
			END IF;
		END IF;
		IF cp_irq_take = '1' OR (micro_state = cp_bf AND make_berr = '1' AND interrupt = '0') THEN
			setinterrupt <= '1';
		END IF;
		setexecOPC <= '0';
		IF setstate="00" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) THEN
			setexecOPC <= '1';
		ELSIF setstate="01" AND next_micro_state=idle AND set_direct_data='0' AND (exec_write_back='0' OR (state="10" AND addrvalue='0')) AND
		      (set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR set(pmmu_rd)='1') THEN
			setexecOPC <= '1';
		END IF;

		IPL_nr <= NOT IPL;
		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				state <= "01";
				addrvalue <= '0';
				opcode <= X"2E79";
				opcode_pc <= (others => '0');
				opc_buf_valid <= '1';
				rte_b_resume_refetch <= '0';
				trap_interrupt <= '0';
				interrupt <= '0';
				last_opc_read  <= X"4EF9";
				TG68_PC <= X"00000004";
				decodeOPC <= '0';
				endOPC <= '0';
				TG68_PC_word <= '0';
				execOPC <= '0';
				stop <= '0';
				rot_cnt <="000001";
				trap_trace <= '0';
				trap_SR <= (others => '0');
					trap_berr <= '0';
					trap_addr_error <= '0';
					writePCbig <= '0';
					Suppress_Base <= '0';
					make_berr <= '0';
					berr_exception_active <= '0';
					cpu_halted <= '0';
					pmmu_fault_dispatched <= '0';
					pmmu_fault_was_cleared <= '0';
					mmu_restart_pending <= '0';
					mmu_restart_soft <= '0';
					mmu_restart_restore <= '0';
					berr_pmmu_fault_lastwrite <= '0';
					berr_fault_addr <= (others => '0');
					berr_frame_pc <= (others => '0');
					berr_opcode_saved <= (others => '0');
					berr_ssw <= (others => '0');
					berr_data_out_saved <= (others => '0');
					berr_long_frame <= '0';
					berr_external_rw <= '1';
					berr_external_fc <= (others => '0');
					berr_external_datatype <= "10";
					berr_external_siz <= "10";
					berr_external_rmw <= '0';
					berr_pmmu_datatype <= "10";
					berr_pmmu_fault_addr <= (others => '0');
					berr_pmmu_fault_fc <= (others => '0');
					berr_pmmu_fault_rw <= '1';
					berr_pmmu_fault_rmw <= '0';
					berr_pmmu_fault_is_insn <= '0';
					berr_pmmu_fault_valid <= '0';
					berr_pmmu_fault_lastwrite <= '0';
					berr_pmmu_fault_from_rte_replay <= '0';
					berr_restart_pc <= (others => '0');
					mmu_restart_pending <= '0';
					mmu_restart_soft <= '0';
					mmu_restart_restore <= '0';
					flags_shadow <= (others => '0');
					berr_external_addr <= (others => '0');
					memmask <= "111111";
					op5 <= '0';
					op_size <= 0;
					exec_write_back <= '0';
					pmove_dn_regnum <= (others => '0');
					pmove_dn_areg <= '0';
					pmove_dn_mode <= '0';
					fline_opcode_latch <= (others => '0');
					fline_brief_latch <= (others => '0');
						fline_context_valid <= '0';
						fline_is_pmmu <= '0';
						fline_is_fpu <= '0';
						fline_has_brief <= '0';
						movec_regsel <= (others => '0');
						pmmu_ea_mode_latched <= (others => '0');
						trace_pending_group2 <= '0';
			ELSE
				IF clkena_core='1' THEN
					IF NOT (state = "00" AND pmmu_busy = '1') AND directpc_retry_hold='0' THEN
						CASE beat_n IS
							WHEN 1 => memmask <= memmask(4 downto 0)&'1';
							WHEN 3 => memmask <= memmask(2 downto 0)&"111";
							WHEN 4 => memmask <= memmask(1 downto 0)&"1111";
							WHEN OTHERS => memmask <= memmask(3 downto 0)&"11";
						END CASE;
						IF memmaskmux(3)='1' THEN
							op5 <= '0';
						ELSIF memmask="100000" THEN
							op5 <= '1';
						END IF;
						IF memread(1 downto 0)="11" THEN
							op_size <= beat_rem;
						END IF;
						memread <= memread(1 downto 0)&memmaskmux(5 downto 4);
					END IF;
					IF rte_mmu_fix_commit='1' THEN
						TG68_PC <= TG68_PC + rte_mmu_fix_len;
					ELSIF exec(directPC)='1' THEN
						IF clkena_lw='1' AND
						   ((beat_valid='1' AND bus_beat_poisoned='0' AND
						    (pmmu_tc_en='0' OR pmmu_fault='0')) OR
						    dib_sub_hit='1' OR
						    (beat_valid='1' AND bus_datum_dirty='0' AND
							     (make_berr='0' OR
							      (berr_pmmu_fault_valid='1' AND
							       berr_pmmu_fault_is_insn='1')) AND
						     trapmake='0' AND
						     (pmmu_tc_en='0' OR pmmu_fault='0' OR
						      pmmu_fault_is_insn_out='1'))) THEN
							TG68_PC <= data_read;
						END IF;
					ELSIF exec(ea_to_pc)='1' THEN
						IF ea_to_pc_datum_invalid='0' THEN
							TG68_PC <= addr;
						END IF;
					ELSIF (((state ="00") AND pmmu_busy='0') OR TG68_PC_brw = '1') AND stop='0'
					      AND NOT (micro_state = pmmu_ld_nn AND nextpass = '1') THEN
						TG68_PC <= TG68_PC_add;
					END IF;

					IF getbrief='1' THEN
						IF (next_micro_state = pmove_decode OR next_micro_state = cp_decode) AND fline_context_valid='0' AND clkena_lw='0' THEN
							IF beat_valid='1' THEN
								brief <= lane_in(31 downto 16);
							END IF;
						ELSIF state(1)='1' THEN
							IF opc_buf_valid='1' THEN
								brief <= last_opc_read(15 downto 0);
							END IF;
						ELSE
							IF beat_valid='1' THEN
								brief <= data_read(15 downto 0);
							END IF;
						END IF;
						IF next_micro_state = movec1 THEN
							IF state(1)='1' THEN
								IF opc_buf_valid='1' THEN
									movec_regsel <= last_opc_read(11 downto 0);
								END IF;
							ELSE
								IF beat_valid='1' THEN
									movec_regsel <= data_read(11 downto 0);
								END IF;
							END IF;
						END IF;
					END IF;

					IF micro_state = pmove_decode AND next_micro_state = pmmu_ld_AnXn1 AND
					   beat_valid='1' THEN
						brief <= data_read(15 downto 0);
					END IF;

						IF (next_micro_state = pmove_decode OR next_micro_state = cp_decode) AND fline_context_valid = '0' AND getbrief = '1' AND
						   ((clkena_lw='0' AND beat_valid='1') OR
						    (clkena_lw='1' AND state(1)='1' AND opc_buf_valid='1') OR
						    (clkena_lw='1' AND state(1)='0' AND beat_valid='1')) THEN
							fline_opcode_latch <= opcode;
						IF clkena_lw='0' THEN
							fline_brief_latch <= lane_in(31 downto 16);
						ELSIF state(1)='1' THEN
							fline_brief_latch <= last_opc_read(15 downto 0);
						ELSE
							fline_brief_latch <= data_read(15 downto 0);
						END IF;
						IF next_micro_state = cp_decode THEN
							fline_is_pmmu <= '0';
							fline_is_fpu <= '1';
						ELSE
							fline_is_pmmu <= '1';
							fline_is_fpu <= '0';
						END IF;
						fline_has_brief <= '1';
						pmmu_ea_mode_latched <= opcode(5 downto 0);
						fline_context_valid <= '1';
						fline_opcode_pc <= TG68_PC;
					END IF;

					IF micro_state = pmove_decode THEN
						IF fline_context_valid = '1' THEN
							IF fline_opcode_latch(5 downto 3) = "000" OR fline_opcode_latch(5 downto 3) = "001" THEN
								pmove_dn_regnum <= fline_opcode_latch(2 downto 0);
								IF fline_opcode_latch(5 downto 3) = "001" THEN
									pmove_dn_areg <= '1';
								ELSE
									pmove_dn_areg <= '0';
								END IF;
								pmove_dn_mode <= '1';
							ELSE
								pmove_dn_areg <= '0';
								pmove_dn_mode <= '0';
							END IF;
						ELSIF opcode(5 downto 3) = "000" OR opcode(5 downto 3) = "001" THEN
							pmove_dn_regnum <= opcode(2 downto 0);
							IF opcode(5 downto 3) = "001" THEN
								pmove_dn_areg <= '1';
							ELSE
								pmove_dn_areg <= '0';
							END IF;
							pmove_dn_mode <= '1';
						ELSE
							pmove_dn_areg <= '0';
							pmove_dn_mode <= '0';
						END IF;
					ELSIF micro_state = pmove_dn_hi THEN
						pmove_dn_regnum <= pmove_dn_regnum + "001";
					END IF;

					IF (setendOPC = '1' OR trapmake = '1') AND
					   micro_state /= pmove_decode AND
					   micro_state /= pmove_dn_hi AND
					   micro_state /= pmove_mem_to_mmu_hi AND
					   micro_state /= pmove_mem_to_mmu_lo AND
					   micro_state /= pmove_mmu_to_mem_hi AND
					   micro_state /= pmove_mmu_to_mem_lo AND
					   micro_state /= ptest1 AND
					   micro_state /= pflush1 AND
					   micro_state /= pload1 AND
					   (micro_state /= pmmu_dn_read_wait OR state="00") AND
					   micro_state /= pmmu_ld_nn AND
					   micro_state /= pmmu_ld_dAn1 AND
					   micro_state /= pmmu_ld_AnXn1 AND
					   micro_state /= pmmu_ld_AnXn2 AND
					   micro_state /= pmmu_ld_229_1 AND
					   micro_state /= pmmu_ld_229_2 AND
					   micro_state /= pmmu_ld_229_3 AND
					   micro_state /= pmmu_ld_229_4 THEN
						fline_context_valid <= '0';
					END IF;
					IF micro_state = cp_rte THEN
						fline_opcode_latch <= cp_rte_iw(15 downto 0);
						fline_brief_latch <= cp_rte_iw(31 downto 16);
						fline_opcode_pc <= cp_rte_pc + 2;
						fline_is_pmmu <= '0';
						fline_is_fpu <= '1';
						fline_has_brief <= '1';
						pmmu_ea_mode_latched <= cp_rte_iw(5 downto 0);
						fline_context_valid <= '1';
					ELSIF micro_state = cp_rsm THEN
						fline_opcode_latch <= cp_rb_iw(15 downto 0);
						fline_brief_latch <= cp_rb_iw(31 downto 16);
						fline_opcode_pc <= cp_rb_opc + 2;
						fline_is_pmmu <= '0';
						fline_is_fpu <= '1';
						fline_has_brief <= '1';
						pmmu_ea_mode_latched <= cp_rb_iw(5 downto 0);
						fline_context_valid <= '1';
					END IF;

					IF (micro_state=pmove_mem_to_mmu_hi OR micro_state=pmove_mem_to_mmu_lo) AND
					   next_micro_state=idle AND setstate="00" THEN
						exec_write_back <= '0';
					END IF;
				END IF;
				IF clkena_lw='1' THEN
					pmmu_fault_was_cleared <= '0';
					mmu_restart_restore <= '0';
					v_pmmu_datatype := berr_pmmu_datatype;
					interrupt <= setinterrupt;
					decodeOPC <= setopcode;
					endOPC <= setendOPC;
					execOPC <= setexecOPC;
					IF decodeOPC='1' THEN
						flags_shadow <= Flags;
					END IF;
					if pmmu_fault = '0' then
						pmmu_fault_dispatched <= '0';
					end if;

					exe_datatype <= set_datatype;
					exe_opcode <= opcode;

					if(trap_berr='0' and trap_mmu_berr='0') then
						if pmmu_tc_en = '1' then
							if pmmu_fault='1' and dib_sub_hit='0' and ((berr_exception_active='0' and pmmu_fault_dispatched='0') OR pmmu_fault_was_cleared='1') then
								make_berr <= '1';
								pmmu_fault_dispatched <= '1';
							else
								make_berr <= (berr_k OR make_berr OR pmmu_walker_berr);
							end if;
							if (pmmu_fault = '1' and dib_sub_hit = '0' and pmmu_fault_stat(15) = '1' and
							    ((berr_exception_active='0' and pmmu_fault_dispatched='0') OR pmmu_fault_was_cleared='1')) or
							   pmmu_walker_berr = '1' then
								make_mmu_berr <= '1';
							else
								make_mmu_berr <= make_mmu_berr;
							end if;
						else
							make_berr <= (berr_k OR make_berr);
							make_mmu_berr <= '0';
						end if;
						if berr_k='1' and make_berr='0' then
							berr_external_rw <= pmmu_rw;
							berr_external_fc <= fc_internal;
							berr_external_datatype <= datatype;
							berr_external_rmw <= pmmu_rmw;
							berr_external_addr <= addr;
							if beat_rem = 1 then berr_external_siz <= "01";
							elsif beat_rem = 2 then berr_external_siz <= "10";
							elsif beat_rem = 3 then berr_external_siz <= "11";
							else berr_external_siz <= "00"; end if;
						end if;
					else
							if cpu(1) = '1' and (berr_k = '1' or (pmmu_tc_en = '1' and pmmu_fault = '1' and pmmu_fault_was_cleared = '1')) then
								cpu_halted <= '1';
								report "DOUBLE BUS FAULT: fault during bus error exception processing - CPU HALTED" severity warning;
								report "HALT_CTX_A: cpu(1)=" & std_logic'image(cpu(1)) &
								       " berr_k=" & std_logic'image(berr_k) &
								       " pmmu_tc_en=" & std_logic'image(pmmu_tc_en) &
								       " pmmu_fault=" & std_logic'image(pmmu_fault) &
								       " pmmu_fault_dispatched=" & std_logic'image(pmmu_fault_dispatched) &
								       " pmmu_fault_was_cleared=" & std_logic'image(pmmu_fault_was_cleared) &
								       " trap_berr=" & bit'image(trap_berr) &
								       " trap_mmu_berr=" & bit'image(trap_mmu_berr) &
								       " berr_exception_active=" & std_logic'image(berr_exception_active)
								       severity warning;
							end if;
						make_berr <= '0';
						make_mmu_berr <= '0';
					end if;
					if (pmmu_tc_en='0' or pmmu_fault='0') and make_berr='0' and trap_berr='0' and trap_mmu_berr='0' and berr_exception_active='0' then
						berr_pmmu_datatype <= "10";
						berr_pmmu_fault_valid <= '0';
						berr_pmmu_fault_from_rte_replay <= '0';
						mmu_restart_pending <= '0';
						mmu_restart_soft <= '0';
					elsif pmmu_tc_en='1' and pmmu_fault='1' and dib_sub_hit='0' and make_berr='0' and trap_berr='0' and trap_mmu_berr='0' then
						IF berr_pmmu_fault_valid = '0' THEN
							berr_pmmu_datatype <= datatype;
							IF opc_buf_valid='1' AND last_opc_pc > insn_next_pc THEN
								berr_pmmu_fault_next_pc <= last_opc_pc;
							ELSE
								berr_pmmu_fault_next_pc <= insn_next_pc;
							END IF;
							berr_pmmu_fault_addr <= pmmu_fault_addr_out;
							berr_pmmu_fault_fc <= pmmu_fault_fc_out;
							berr_pmmu_fault_rw <= pmmu_fault_rw_out;
							berr_pmmu_fault_rmw <= pmmu_rmw;
							berr_pmmu_fault_is_insn <= pmmu_fault_is_insn_out;
							berr_pmmu_fault_lastwrite <= pmmu_fault_lastwrite_ok;
							IF micro_state = rte_mmu_replay THEN
								berr_pmmu_fault_from_rte_replay <= '1';
							ELSE
								berr_pmmu_fault_from_rte_replay <= '0';
							END IF;
							berr_pmmu_fault_valid <= '1';
							IF (pmmu_fault_is_insn_out = '0' OR insn_fetch_consumer = '1') AND
							   pmmu_fault_lastwrite_ok = '0' AND
							   cp_bf_now = '0' THEN
								mmu_restart_pending <= '1';
								mmu_restart_soft <= pmmu_fault_is_insn_out;
								berr_restart_pc <= exe_pc;
							END IF;
							v_pmmu_datatype := datatype;
							berr_pmmu_write_data <= data_write_muxin;
						END IF;
					end if;

					IF berr_k='1' AND make_berr='0' AND trap_berr='0' AND trap_mmu_berr='0' AND
					   berr_exception_active='0' AND cp_bf_now='0' AND
					   fc_internal(1 downto 0)="01" AND pmmu_rmw='0' THEN
						mmu_restart_pending <= '1';
						mmu_restart_soft <= '0';
						berr_restart_pc <= exe_pc;
					END IF;

					IF exec(directPC)='1' AND clkena_lw='1' AND
						   make_berr='1' AND berr_pmmu_fault_valid='1' AND
						   berr_pmmu_fault_is_insn='1' AND
					   trap_berr='0' AND trap_mmu_berr='0' AND
					   (pmmu_tc_en='0' OR pmmu_fault='0' OR
					    pmmu_fault_is_insn_out='1') THEN
							make_berr <= '0';
							make_mmu_berr <= '0';
							berr_pmmu_fault_valid <= '0';
					END IF;
					stop <= set_stop OR (stop AND NOT setinterrupt);
					IF setinterrupt='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
						make_berr <= '0';
						make_mmu_berr <= '0';
						trap_berr <= '0';
						trap_mmu_berr <= '0';
						trap_addr_error <= '0';
						berr_long_frame <= '0';
						IF pmmu_fault_restart_dispatch = '1' THEN
							mmu_restart_pending <= '0';
							mmu_restart_soft <= '0';
							mmu_restart_restore <= '1';
						END IF;
						IF TG68_PC(0)='1' THEN
								IF (cpu(1) = '1' AND berr_exception_active = '1') THEN
									cpu_halted <= '1';
									report "DOUBLE FAULT: address error during exception - CPU HALTED" severity warning;
									report "HALT_CTX_C: cpu(1)=" & std_logic'image(cpu(1)) &
									       " TG68_PC(0)=" & std_logic'image(TG68_PC(0)) &
									       " berr_exception_active=" & std_logic'image(berr_exception_active) &
									       " trap_berr=" & bit'image(trap_berr) &
									       " trap_mmu_berr=" & bit'image(trap_mmu_berr) &
									       " make_berr=" & std_logic'image(make_berr)
									       severity warning;
								ELSE
								trap_addr_error <= '1';
								berr_exception_active <= '1';
								berr_long_frame <= '1';
								berr_fault_addr <= TG68_PC;
								berr_frame_pc <= TG68_PC;
								berr_opcode_saved <= opcode;
								berr_data_out_saved <= (others => '0');
								berr_ssw <= (others => '0');
								berr_ssw(2 downto 0) <= fc_internal;
								berr_ssw(6) <= '1';
								berr_ssw(5 downto 4) <= "10";
								berr_ssw(13) <= '1';
								berr_ssw(12) <= '1';
								END IF;
						ELSIF make_berr='1' OR
						      (pmmu_tc_en='1' AND pmmu_fault='1' AND
						       ((berr_exception_active='0' AND pmmu_fault_dispatched='0') OR pmmu_fault_was_cleared='1') AND
						       trap_berr='0' AND trap_mmu_berr='0') THEN
								IF (cpu(1) = '1' AND berr_exception_active = '1') THEN
									cpu_halted <= '1';
									report "DOUBLE BUS FAULT: bus error at handler dispatch - CPU HALTED" severity warning;
									report "HALT_CTX_B: cpu(1)=" & std_logic'image(cpu(1)) &
									       " make_berr=" & std_logic'image(make_berr) &
									       " berr_k=" & std_logic'image(berr_k) &
									       " pmmu_tc_en=" & std_logic'image(pmmu_tc_en) &
									       " pmmu_fault=" & std_logic'image(pmmu_fault) &
									       " pmmu_fault_Bbit=" & std_logic'image(pmmu_fault_stat(15)) &
									       " trap_berr=" & bit'image(trap_berr) &
									       " trap_mmu_berr=" & bit'image(trap_mmu_berr) &
									       " berr_exception_active=" & std_logic'image(berr_exception_active)
									       severity warning;
								ELSE
									IF make_mmu_berr='1' OR
									   (pmmu_fault='1' AND pmmu_fault_stat(15)='1' AND
									    ((berr_exception_active='0' AND pmmu_fault_dispatched='0') OR pmmu_fault_was_cleared='1')) THEN
										trap_mmu_berr <= '1';
										IF berr_pmmu_fault_valid = '1' THEN
											berr_long_frame <= NOT berr_pmmu_fault_lastwrite;
										ELSIF pmmu_fault = '1' THEN
											berr_long_frame <= NOT pmmu_fault_lastwrite_ok;
											ELSE
												berr_long_frame <= NOT berr_pmmu_fault_lastwrite;
											END IF;
									ELSE
										trap_berr <= '1';
											IF pmmu_fault = '1' OR berr_pmmu_fault_valid = '1' THEN
											IF berr_pmmu_fault_valid = '1' THEN
												berr_long_frame <= NOT berr_pmmu_fault_lastwrite;
											ELSIF pmmu_fault = '1' THEN
												berr_long_frame <= NOT pmmu_fault_lastwrite_ok;
												ELSE
													berr_long_frame <= NOT berr_pmmu_fault_lastwrite;
												END IF;
											ELSE
												berr_long_frame <= '1';
											END IF;
									END IF;
								if pmmu_fault = '1' then
									pmmu_fault_dispatched <= '1';
								end if;
								berr_exception_active <= '1';
								IF berr_pmmu_fault_valid = '1' AND berr_pmmu_fault_from_rte_replay = '1' THEN
									berr_frame_pc <= TG68_PC;
								ELSIF micro_state = rte_mmu_replay AND pmmu_fault = '1' THEN
									berr_frame_pc <= TG68_PC;
								ELSIF pmmu_fault_restart_live = '1' THEN
									berr_frame_pc <= exe_pc;
								ELSIF mmu_restart_pending = '1' THEN
									berr_frame_pc <= berr_restart_pc;
								ELSIF pmmu_fault_lastwrite_ok='1' AND berr_pmmu_fault_valid='1' THEN
									berr_frame_pc <= berr_pmmu_fault_next_pc;
								ELSIF pmmu_fault_lastwrite_ok='1' THEN
									IF opc_buf_valid='1' AND last_opc_pc > insn_next_pc THEN
										berr_frame_pc <= last_opc_pc;
									ELSE
										berr_frame_pc <= insn_next_pc;
									END IF;
								ELSE
									berr_frame_pc <= TG68_PC;
								END IF;
								report "BERR_FRAMEPC: restart_live=" & std_logic'image(pmmu_fault_restart_live) &
								       " pending=" & std_logic'image(mmu_restart_pending) &
								       " lastwrite=" & std_logic'image(pmmu_fault_lastwrite_ok) &
								       " scp=" & integer'image(conv_integer(stream_consumed_pc(15 downto 0))) &
								       " exe_pc=" & integer'image(conv_integer(exe_pc(15 downto 0))) &
								       " last_opc_pc=" & integer'image(conv_integer(last_opc_pc(15 downto 0))) &
								       " tg68_pc=" & integer'image(conv_integer(TG68_PC(15 downto 0))) &
								       " faddr=" & integer'image(conv_integer(pmmu_fault_addr_out(15 downto 0))) &
								       " faddr_hi=" & integer'image(conv_integer(pmmu_fault_addr_out(31 downto 16))) severity note;
								berr_opcode_saved <= exe_opcode;
								IF micro_state = cp_bf THEN
									berr_long_frame <= '1';
									IF cp_bk_ss = "00" THEN
										berr_frame_pc <= cp_bk_pc;
									ELSE
										berr_frame_pc <= TG68_PC;
									END IF;
								END IF;
								IF berr_pmmu_fault_valid = '1' and berr_pmmu_fault_rw = '0' THEN
									berr_data_out_saved <= berr_pmmu_write_data;
								ELSIF pmmu_fault = '1' and pmmu_fault_rw_out = '0' THEN
									berr_data_out_saved <= data_write_muxin;
								ELSE
									berr_data_out_saved <= data_write_tmp;
								END IF;
								berr_ssw <= (others => '0');
								if pmmu_fault = '1' or berr_pmmu_fault_valid = '1' or make_mmu_berr = '1' then
									if berr_pmmu_fault_valid = '1' then
										berr_fault_addr <= berr_pmmu_fault_addr;
										berr_ssw(2 downto 0) <= berr_pmmu_fault_fc;
										berr_ssw(6) <= berr_pmmu_fault_rw;
									elsif pmmu_fault = '1' then
										berr_fault_addr <= pmmu_fault_addr_out;
										berr_ssw(2 downto 0) <= pmmu_fault_fc_out;
										berr_ssw(6) <= pmmu_fault_rw_out;
									elsif make_mmu_berr = '1' then
										berr_fault_addr <= berr_pmmu_fault_addr;
										berr_ssw(2 downto 0) <= berr_pmmu_fault_fc;
										berr_ssw(6) <= berr_pmmu_fault_rw;
									end if;
									if (berr_pmmu_fault_valid = '1' and berr_pmmu_fault_is_insn = '1') or
									   (berr_pmmu_fault_valid = '0' and pmmu_fault = '1' and pmmu_fault_is_insn_out = '1') or
									   (berr_pmmu_fault_valid = '0' and pmmu_fault = '0' and make_mmu_berr = '1' and
									    berr_pmmu_fault_is_insn = '1') then
										berr_ssw(15) <= '0';
										berr_ssw(14) <= '1';
										berr_ssw(13) <= '0';
										berr_ssw(12) <= '1';
										berr_ssw(8) <= '0';
										berr_ssw(5 downto 4) <= "10";
									else
										berr_ssw(15) <= '0';
										berr_ssw(14) <= '0';
										berr_ssw(13) <= '0';
										berr_ssw(12) <= '0';
										berr_ssw(8) <= '1';
											berr_ssw(9) <= '0';
										case v_pmmu_datatype is
											when "00" => berr_ssw(5 downto 4) <= "01";
											when "01" => berr_ssw(5 downto 4) <= "10";
											when others => berr_ssw(5 downto 4) <= "00";
										end case;
									end if;
										berr_ssw(11 downto 10) <= "00";
									if berr_pmmu_fault_valid = '1' or
									   (pmmu_fault = '0' and make_mmu_berr = '1') then
										berr_ssw(7) <= berr_pmmu_fault_rmw;
									else
										berr_ssw(7) <= pmmu_rmw;
									end if;
									berr_ssw(3) <= '0';
									berr_pmmu_fault_valid <= '0';
									berr_pmmu_fault_from_rte_replay <= '0';
								else
									berr_fault_addr <= berr_external_addr;
									berr_ssw(2 downto 0) <= berr_external_fc;
									berr_ssw(6) <= berr_external_rw;
									if berr_external_fc(0) = '1' then
										berr_ssw(15) <= '0';
										berr_ssw(14) <= '0';
										berr_ssw(13) <= '0';
										berr_ssw(12) <= '0';
										berr_ssw(8) <= '1';
											berr_ssw(9) <= '0';
									else
										berr_ssw(15) <= '0';
										berr_ssw(14) <= '1';
										berr_ssw(13) <= '0';
										berr_ssw(12) <= '1';
										berr_ssw(8) <= '0';
											berr_ssw(9) <= '0';
									end if;
									berr_ssw(5 downto 4) <= berr_external_siz;
									berr_ssw(11 downto 10) <= "00";
									berr_ssw(7) <= berr_external_rmw;
									berr_ssw(3) <= '0';
								end if;
							END IF;
						ELSIF (make_trace='1' OR (make_trace_t0='1' AND v_is_cof='1')) AND cp_irq_take='0' THEN
							trap_trace <= '1';
						ELSE
							rIPL_nr <= IPL_nr;
							IPL_vec <= "00011"&IPL_nr;
							trap_interrupt <= '1';
							berr_exception_active <= '0';
						END IF;
					END IF;
					IF micro_state=trap0 AND IPL_autovector='0' THEN
						IPL_vec <= last_data_read(7 downto 0);
					END IF;

					IF state="00" AND beat_valid='0' THEN
						opc_buf_valid <= '0';
					END IF;
					IF state="00" AND beat_valid='1' THEN
						opc_buf_valid <= '1';
						last_opc_read <= data_read(15 downto 0);
						last_opc_pc <= tg68_pc;
					END IF;
					IF setopcode='1' THEN
						IF state="00" THEN
							stream_consumed_pc <= tg68_pc;
							insn_next_pc <= tg68_pc + 2;
						ELSE
							stream_consumed_pc <= last_opc_pc;
							insn_next_pc <= last_opc_pc + 2;
						END IF;
					ELSIF getbrief='1' THEN
						IF state(1)='1' THEN
							stream_consumed_pc <= last_opc_pc;
						ELSE
							stream_consumed_pc <= tg68_pc;
						END IF;
						insn_next_pc <= insn_next_pc + 2;
					ELSIF state="00" AND
					      (exec(update_ld)='1' OR
					       micro_state = ld_nn  OR micro_state = st_nn  OR
					       micro_state = ld_dAn1 OR micro_state = st_dAn1 OR
					       micro_state = ld_AnXn1 OR micro_state = ld_AnXn2 OR
					       micro_state = st_AnXn1 OR micro_state = st_AnXn2 OR
					       micro_state = ld_AnXnbd1 OR micro_state = ld_AnXnbd2 OR micro_state = ld_AnXnbd3 OR
					       micro_state = ld_229_1 OR micro_state = ld_229_2 OR
					       micro_state = ld_229_3 OR micro_state = ld_229_4 OR
					       micro_state = st_229_1 OR micro_state = st_229_2 OR
					       micro_state = st_229_3 OR micro_state = st_229_4) THEN
						stream_consumed_pc <= tg68_pc;
						insn_next_pc <= insn_next_pc + 2;
					ELSIF state="00" AND
					      (micro_state = pmmu_ld_nn OR micro_state = pmmu_ld_dAn1 OR
					       micro_state = pmmu_ld_AnXn1 OR micro_state = pmmu_ld_AnXn2 OR
					       micro_state = pmmu_ld_229_1 OR micro_state = pmmu_ld_229_2 OR
					       micro_state = pmmu_ld_229_3 OR micro_state = pmmu_ld_229_4) THEN
						insn_next_pc <= insn_next_pc + 2;
					END IF;
					IF clkena_lw='1' AND micro_state = rte5 AND
					   (rot_cnt = "000010" OR rot_cnt = "000001") AND
					   rte_format_word(15 downto 12) = "1011" THEN
						rte_b_resume_refetch <= '1';
					END IF;
					IF clkena_lw='1' AND micro_state = rte5 AND rot_cnt = "000010" AND
					   rte_format_word(15 downto 12) = "1011" AND
					   rte_mmu_fix_armed = '1' AND
					   rte_mmu_fix_write = '0' AND
					   rte_mmu_fix_ssw(15) = '0' AND rte_mmu_fix_ssw(14) = '0' AND
					   rte_mmu_fix_ssw(13) = '0' AND rte_mmu_fix_ssw(12) = '0' AND
					   rte_mmu_fix_ssw(8) = '0' AND
					   rte_mmu_fix_ssw(7) = '0' THEN
						dib_sub_valid <= '1';
						dib_sub_fresh <= '1';
						dib_sub_rw    <= rte_mmu_fix_ssw(6);
						dib_sub_addr  <= rte_mmu_fix_faddr;
						dib_sub_data  <= rte_mmu_fix_input_buffer;
					END IF;
					IF trapmake='1' AND clkena_lw='1' THEN
						dib_sub_valid <= '0';
						dib_sub_fresh <= '0';
					ELSIF setopcode='1' AND clkena_lw='1' THEN
						IF dib_sub_fresh='1' THEN
							dib_sub_fresh <= '0';
						ELSE
							dib_sub_valid <= '0';
						END IF;
					END IF;
					IF setopcode='1' THEN
						trap_interrupt <= '0';
						trap_trace <= '0';
						TG68_PC_word <= '0';
						trap_berr <= '0';
						trap_mmu_berr <= '0';
						trap_addr_error <= '0';
						rte_b_resume_refetch <= '0';
						IF make_berr='0' AND (pmmu_tc_en='0' OR pmmu_fault='0') THEN
							berr_exception_active <= '0';
							pmmu_fault_was_cleared <= '0';
						END IF;
					ELSIF opcode(7 downto 0)="00000000" OR opcode(7 downto 0)="11111111" OR data_is_source='1' THEN
						TG68_PC_word <= '1';
					END IF;

					IF exec(get_bfoffset)='1' THEN
						alu_width <= bf_width;
						alu_bf_shift <= bf_shift;
						alu_bf_loffset <= bf_loffset;
						alu_bf_ffo_offset <= bf_full_offset+bf_width+1;
					END IF;
					memread <= "1111";
					fc_internal(1) <= NOT setstate(1) OR (PCbase AND NOT setstate(0));
					fc_internal(0) <= setstate(1) AND (NOT PCbase OR setstate(0));
					IF interrupt='1' THEN
						fc_internal(1 downto 0) <= "11";
					END IF;
					IF (set(use_sfc_dfc)='1' OR exec(use_sfc_dfc)='1') AND
					   moves_fc_override = '1' THEN
						IF set(sfc_not_dfc)='1' OR exec(sfc_not_dfc)='1' THEN
							fc_internal(1 downto 0) <= SFC(1 downto 0);
						ELSE
							fc_internal(1 downto 0) <= DFC(1 downto 0);
						END IF;
					END IF;

					IF state="11" THEN
						exec_write_back <= '0';
					ELSIF setstate="10" AND setaddrvalue='0' AND write_back='1' THEN
						exec_write_back <= '1';
					END IF;
				IF directpc_retry_hold='1' THEN
					NULL;
				ELSIF (state="10" AND addrvalue='0' AND write_back='1' AND setstate/="10") OR (set_rot_cnt/="000001" AND next_micro_state /= rte5 AND next_micro_state /= berr_fill) OR (stop='1' AND interrupt='0') OR set_exec(opcCHK)='1' THEN
						state <= "01";
						memmask <= "111111";
						addrvalue <= '0';
					ELSIF execOPC='1' AND exec_write_back='1' THEN
						state <= "11";
						fc_internal(1 downto 0) <= "01";
						memmask <= wbmemmask;
						addrvalue <= '0';
					ELSE
						state <= setstate;
						addrvalue <= setaddrvalue;
						IF setstate="01" THEN
							memmask <= "111111";
							wbmemmask <= "111111";
						ELSIF exec(get_bfoffset)='1' THEN
							memmask <= set_memmask;
							wbmemmask <= set_memmask;
							oddout <= set_oddout;
						ELSIF set(longaktion)='1' THEN
							 	memmask <= "100001";
							 	wbmemmask <= "100001";
							oddout <= '0';
						ELSIF set_datatype="00" AND setstate(1)='1' THEN
							memmask <= "101111";
							wbmemmask <= "101111";
							IF set(mem_byte)='1' THEN
								oddout <= '0';
							ELSE
								oddout <= '1';
							END IF;
						ELSE
								memmask <= "100111";
								wbmemmask <= "100111";
							oddout <= '0';
						END IF;
					END IF;

					IF decodeOPC='1' THEN
						rot_bits <= set_rot_bits;
						writePCbig <= '0';
					ELSE
						writePCbig <= set_writePCbig OR writePCbig;
					END IF;
					IF decodeOPC='1' OR exec(ld_rot_cnt)='1' OR rot_cnt/="000001" THEN
						rot_cnt <= set_rot_cnt;
					END IF;
					IF micro_state = rte4 AND set_rot_cnt /= "000001" THEN
						rot_cnt <= set_rot_cnt;
					END IF;
					IF interrupt='1' AND cpu(1)='1' AND
					   (trap_addr_error='1' OR ((trap_berr='1' OR trap_mmu_berr='1') AND berr_long_frame='1')) THEN
						rot_cnt <= "001111";
					END IF;

					IF set_Suppress_Base='1' THEN
						Suppress_Base <= '1';
					ELSIF setstate(1)='1' OR (ea_only='1' AND set(get_ea_now)='1') THEN
						Suppress_Base <= '0';
					END IF;

						IF micro_state = cp_rte THEN
							opcode <= cp_rte_iw(15 downto 0);
							exe_pc <= cp_rte_pc;
							opcode_pc <= cp_rte_pc;
						ELSIF micro_state = cp_rsm THEN
							opcode <= cp_rb_iw(15 downto 0);
							exe_pc <= cp_rb_opc;
							opcode_pc <= cp_rb_opc;
						END IF;
						IF setopcode='1' AND berr_k='0' THEN
							IF state="00" THEN
								opcode <= data_read(15 downto 0);
								exe_pc <= tg68_pc;
								opcode_pc <= tg68_pc;
							ELSE
								opcode <= last_opc_read(15 downto 0);
								exe_pc <= last_opc_pc;
								opcode_pc <= last_opc_pc;
							END IF;
						nextpass <= '0';
					ELSIF setinterrupt='1' OR setopcode='1' THEN
						opcode <= X"4E71";
						nextpass <= '0';
					ELSE
						IF setnextpass='1' OR regdirectsource='1' THEN
							nextpass <= '1';
						END IF;
					END IF;

					IF trapmake='1' AND trapd='0' AND cpu(1)='1' AND (make_trace='1' OR make_trace_t0='1') AND
					   (next_micro_state = trap00 OR trap_trap='1') AND trap_mmu_config='0' THEN
						trace_pending_group2 <= '1';
						trace_group2_sr <= FlagsSR;
						trace_group2_sr(7 downto 6) <= "00";
						trace_group2_sr(5) <= '1';
					END IF;
					IF micro_state = trace_stk_grp2 THEN
						trap_pc_latched <= data_read;
						trap_trace <= '1';
						trap_SR <= trace_group2_sr;
						trace_pending_group2 <= '0';
					END IF;

					IF decodeOPC='1' OR interrupt='1' THEN
						trap_SR <= FlagsSR;
					END IF;
					IF setinterrupt='1' THEN
						IF exec(directPC)='1' AND clkena_lw='1' AND
						   (((beat_valid='1' AND bus_beat_poisoned='0') AND
						     (pmmu_tc_en='0' OR pmmu_fault='0')) OR dib_sub_hit='1' OR
						    (beat_valid='1' AND bus_datum_dirty='0' AND
							     (make_berr='0' OR
							      (berr_pmmu_fault_valid='1' AND
							       berr_pmmu_fault_is_insn='1')) AND
						     trapmake='0' AND
						     (pmmu_tc_en='0' OR pmmu_fault='0' OR
						      pmmu_fault_is_insn_out='1'))) THEN
							trap_pc_latched <= data_read;
						ELSIF exec(ea_to_pc)='1' THEN
							IF ea_to_pc_datum_invalid='0' THEN
								trap_pc_latched <= addr;
							ELSE
								trap_pc_latched <= exe_pc;
							END IF;
						ELSIF state="00" THEN
							trap_pc_latched <= tg68_pc;
						ELSE
							trap_pc_latched <= last_opc_pc;
						END IF;
					END IF;
					IF decodeOPC='1' AND (opcode = x"4E73" OR opcode = x"4E77") THEN
						berr_exception_active <= '0';
						pmmu_fault_was_cleared <= '0';
					END IF;
					IF exec(directSR)='1' THEN
						trap_SR <= data_read(15 downto 8);
					END IF;
					IF trap_format_error='1' THEN
						trap_SR <= rte_saved_sr_high AND SR_trace_mask;
					END IF;
					IF (micro_state = rte4 AND rte_format_word(15 downto 12) = "0000") OR
					   (micro_state = rte5 AND rot_cnt = "000001") THEN
						berr_exception_active <= '0';
						pmmu_fault_was_cleared <= '0';
					END IF;
				ELSE
					IF pmmu_fault = '0' THEN
						pmmu_fault_was_cleared <= '1';
					END IF;
				END IF;
			END IF;
		END IF;

		IF rising_edge(clk) THEN
			IF Reset = '1' THEN
				PCbase <= '1';
			ELSIF clkena_lw='1' THEN
				PCbase <= set_PCbase OR PCbase;
				IF setexecOPC='1' OR (state(1)='1' AND movem_run='0') THEN
					PCbase <= '0';
				END IF;
			END IF;
				IF clkena_lw='1' THEN
					exec <= set;
				exec(alu_move) <= set(opcMOVE) OR set(alu_move);
				exec(alu_setFlags) <= set(opcADD) OR set(alu_setFlags);
				exec_tas <= '0';
				exec(subidx) <= set(presub) or set(subidx);
					IF setexecOPC='1' THEN
						exec <= set_exec OR set;
					exec(alu_move) <= set_exec(opcMOVE) OR set(opcMOVE) OR set(alu_move);
					exec(alu_setFlags) <= set_exec(opcADD) OR set(opcADD) OR set(alu_setFlags);
					exec_tas <= set_exec_tas;
				exec_cas <= set_exec_cas;
						IF set(pmmu_rd)='0' AND exec(pmmu_rd)='0' AND
						   set_exec(pmmu_wr)='0' AND set(pmmu_wr)='0' AND exec(pmmu_wr)='0' AND
						   exec(Regwrena)='0' THEN
							pmove_dn_areg <= '0';
							pmove_dn_mode <= '0';
						END IF;
					END IF;
				exec(get_2ndOPC) <= set(get_2ndOPC) OR setopcode;

				IF setexecOPC='1' AND setinterrupt='1' AND set(changeMode)='1' THEN
					exec(changeMode) <= '0';
					exec(to_USP) <= '0';
					exec(from_USP) <= '0';
					exec(to_ISP) <= '0';
					exec(from_ISP) <= '0';
					exec(to_MSP) <= '0';
					exec(from_MSP) <= '0';
				END IF;

				END IF;
			END IF;
		END PROCESS;

PROCESS (clk, Reset, sndOPC, reg_QA, reg_QB, bf_width, bf_offset, bf_bhits, opcode, setstate, bf_shift)
	BEGIN
		IF sndOPC(11)='1' THEN
			bf_offset <= '0'&reg_QA(4 downto 0);
		ELSE
			bf_offset <= '0'&sndOPC(10 downto 6);
		END IF;
		IF sndOPC(11)='1' THEN
			bf_full_offset <= reg_QA;
		ELSE
			bf_full_offset <= (others => '0');
			bf_full_offset(4 downto 0) <= sndOPC(10 downto 6);
		END IF;

		bf_width(5) <= '0';
		IF sndOPC(5)='1' THEN
			bf_width(4 downto 0) <= reg_QB(4 downto 0)-1;
		ELSE
			bf_width(4 downto 0) <= sndOPC(4 downto 0)-1;
		END IF;
		bf_bhits <= bf_width+bf_offset;
		set_oddout <= NOT bf_bhits(3);

		IF opcode(10 downto 8)="111" THEN
			bf_loffset <= 32-bf_shift;
		ELSE
			bf_loffset <= bf_shift;
		END IF;
		bf_loffset(5) <= '0';

		IF opcode(4 downto 3)="00" THEN
			IF opcode(10 downto 8)="111" THEN
				bf_shift <= bf_bhits+1;
			ELSE
				bf_shift <= 31-bf_bhits;
			END IF;
			bf_shift(5) <= '0';
		ELSE
			IF opcode(10 downto 8)="111" THEN
				bf_shift <= "011001"+("000"&bf_bhits(2 downto 0));
				bf_shift(5) <= '0';
			ELSE
				bf_shift <= "000"&("111"-bf_bhits(2 downto 0));
			END IF;
			bf_offset(4 downto 3) <= "00";
		END IF;

		CASE bf_bhits(5 downto 3) IS
			WHEN "000" =>
				set_memmask <= "101111";
			WHEN "001" =>
				set_memmask <= "100111";
			WHEN "010" =>
				set_memmask <= "100011";
			WHEN "011" =>
				set_memmask <= "100001";
			WHEN OTHERS =>
				set_memmask <= "100000";
		END CASE;
		IF setstate="00" THEN
			set_memmask <= "100111";
		END IF;
	END PROCESS;

PROCESS (clk, Reset, FlagsSR, last_data_read, OP2out, exec)
	BEGIN
		IF exec(andiSR)='1' THEN
			SRin <= FlagsSR AND last_data_read(15 downto 8);
		ELSIF exec(eoriSR)='1' THEN
			SRin <= FlagsSR XOR last_data_read(15 downto 8);
		ELSIF exec(oriSR)='1' THEN
			SRin <= FlagsSR OR last_data_read(15 downto 8);
		ELSE
			SRin <= OP2out(15 downto 8);
		END IF;

		IF rising_edge(clk) THEN
				IF Reset='1' THEN
					fc_internal(2) <= '1';
					SVmode <= '1';
					preSVmode <= '1';
					FlagsSR <= "00100111";
					make_trace <= '0';
					make_trace_t0 <= '0';
					dbcc_t0_suppress <= '0';
					interrupt_mode <= '0';
				ELSIF clkena_lw = '1' THEN
				IF micro_state = cp9a OR micro_state = cp_bf OR (micro_state = cp_irq AND interrupt = '1' AND trap_interrupt = '1') THEN
					make_trace <= '0';
					make_trace_t0 <= '0';
				ELSIF micro_state = cp_rte OR micro_state = cp_rsm THEN
					make_trace <= FlagsSR(7);
					make_trace_t0 <= FlagsSR(6) AND NOT FlagsSR(7);
				END IF;
				IF setopcode='1' THEN
					IF exec(directSR)='1' OR set_stop='1' THEN
						make_trace <= data_read(15);
						make_trace_t0 <= data_read(14) AND NOT data_read(15);
					ELSIF exec(to_SR)='1' THEN
						make_trace <= SRin(7);
						make_trace_t0 <= SRin(6) AND NOT SRin(7);
					ELSE
						make_trace <= FlagsSR(7);
						make_trace_t0 <= FlagsSR(6) AND NOT FlagsSR(7);
					END IF;
					IF NOT (opcode(15 downto 12) = "0101" AND opcode(7 downto 3) = "11001") THEN
						dbcc_t0_suppress <= '0';
					END IF;
					IF set(changeMode)='1' THEN
						SVmode <= NOT SVmode;
					ELSE
						SVmode <= preSVmode;
					END IF;
				END IF;
				IF micro_state = dbcc1 AND exe_condition = '0' AND c_out(1) = '0' AND last_data_read(0) = '0' THEN
					dbcc_t0_suppress <= '1';
				END IF;
				IF trap_berr='1' OR trap_illegal='1' OR trap_addr_error='1' OR trap_priv='1' OR trap_1010='1' OR trap_1111='1' OR trap_mmu_config='1' OR trap_mmu_berr='1' OR trap_format_error='1' THEN
					make_trace <= '0';
					make_trace_t0 <= '0';
					FlagsSR(7) <= '0';
					FlagsSR(6) <= '0';
				END IF;
				IF set(changeMode)='1' AND NOT (setexecOPC='1' AND setinterrupt='1') THEN
					preSVmode <= NOT preSVmode;
					FlagsSR(5) <= NOT preSVmode;
					fc_internal(2) <= NOT preSVmode;
				END IF;
				IF set_stop='1' THEN
					SVmode <= data_read(13);
				END IF;
				IF micro_state=trap3 THEN
					FlagsSR(7) <= '0';
					FlagsSR(6) <= '0';
					IF preSVmode='1' AND FlagsSR(5)='0' THEN
						FlagsSR(5) <= '1';
						fc_internal(2) <= '1';
					END IF;
				END IF;
				IF trap_trace='1' AND state="10" THEN
					make_trace <= '0';
					make_trace_t0 <= '0';
				END IF;
				IF exec(directSR)='1' OR set_stop='1' THEN
					FlagsSR <= data_read(15 downto 8);
				END IF;
				IF set_stop='1' THEN
					FlagsSR(3) <= '0';
				END IF;
				IF interrupt='1' AND trap_interrupt='1' THEN
					FlagsSR(2 downto 0) <=rIPL_nr;
					IF cpu(1)='1' THEN
						FlagsSR(4) <= '0';
					END IF;
				END IF;
				IF exec(to_SR)='1' THEN
					FlagsSR(7 downto 0) <= SRin;
					fc_internal(2) <= SRin(5);
				ELSIF exec(update_FC)='1' THEN
					fc_internal(2) <= FlagsSR(5);
				ELSIF exec(directSR)='1' OR set_stop='1' THEN
					fc_internal(2) <= data_read(13);
				ELSE
					fc_internal(2) <= FlagsSR(5);
				END IF;
				IF (set(use_sfc_dfc)='1' OR exec(use_sfc_dfc)='1') AND
				   moves_fc_override = '1' THEN
					IF set(sfc_not_dfc)='1' OR exec(sfc_not_dfc)='1' THEN
						fc_internal(2) <= SFC(2);
					ELSE
						fc_internal(2) <= DFC(2);
					END IF;
				END IF;
				IF cpu(1)='1' AND (
				   next_micro_state = rte1 OR next_micro_state = rte2 OR
				   next_micro_state = rte3 OR next_micro_state = rte4 OR
				   next_micro_state = rte5 OR next_micro_state = rte6) THEN
					fc_internal(2) <= '1';
				END IF;
				IF interrupt='1' THEN
					fc_internal(2) <= '1';
					IF preSVmode='1' AND FlagsSR(5)='0' THEN
						FlagsSR(5) <= '1';
					END IF;
				END IF;
					IF trap_format_error='1' THEN
						FlagsSR <= rte_saved_sr_high AND SR_trace_mask;
						fc_internal(2) <= '1';
					END IF;
					IF interrupt_mode_set_req='1' THEN
						interrupt_mode <= '1';
					ELSIF interrupt_mode_clr_req='1' THEN
						interrupt_mode <= '0';
					END IF;
					IF cpu(1)='0' THEN
						FlagsSR(4) <= '0';
						FlagsSR(6) <= '0';
					END IF;
					IF exec(to_SR)='1' THEN
						FlagsSR(3) <= '0';
					END IF;
			END IF;
		END IF;
	END PROCESS;

PROCESS (clk, cpu, OP1out, OP2out, opcode, exe_condition, nextpass, micro_state, decodeOPC, state, setexecOPC, Flags, FlagsSR, direct_data, build_logical,
		 build_bcd, set_Z_error, trapd, movem_run, last_data_read, set, set_V_Flag, z_error, trap_trace, trap_interrupt,
		 SVmode, preSVmode, stop, long_done, ea_only, setstate, addrvalue, execOPC, exec_write_back, exe_datatype,
		 datatype, interrupt, c_out, trapmake, rot_cnt, brief, addr, trap_trapv, last_data_in, use_VBR_Stackframe,
		 long_start, set_datatype, sndOPC, set_exec, exec, ea_build_now, reg_QA, reg_QB, make_berr, trap_berr, last_opc_read,
			 moves_writeback_pending, moves_active, pmmu_opcode, pmmu_brief, rte_format_word, rte_format_b_version_error,
			 rte_fmt_a_replay_needed, rte_fmt_a_replay_size, mmu_restart_active,
			 cp_prim, cp_pcdone, opcode_pc, fline_opcode_latch, fline_context_valid, clkena_lw,
			 cp_ea_ok, cp_pv, cp_len, cp_part, cp_psize, cp_psize0, cp_data, cp_half, cp_mm, cp_mmcnt, regfile,
			 cp_ss, cp_frcp, cp_badlen, cp_scc, cp_w, cp_irq_take, cp_f9, cp_nocp, cp_twait,
			 cp_bf_now, cp_bk_st, cp_bk_ss, cp_bk_dt, cp_bk_cir, cp_bk_mem, cp_bk_off, cp_bk_wd, cp_rb, trap_mmu_berr)
	variable v_rte_format_valid : std_logic;
	BEGIN
		TG68_PC_brw <= '0';
		setstate <= "00";
		setaddrvalue <= '0';
		Regwrena_now <= '0';
		movem_presub <= '0';
		setnextpass <= '0';
		regdirectsource <= '0';
		setdisp <= '0';
		setdispbyte <= '0';
		getbrief <= '0';
		dest_LDRareg <= '0';
		dest_areg <= '0';
		source_areg <= '0';
		data_is_source <= '0';
		write_back <= '0';
		setstackaddr <= '0';
		writePC <= '0';
		ea_build_now <= '0';
		set_rot_bits <= opcode(4 downto 3);
		set_rot_cnt <= "000001";
		dest_hbits <= '0';
		source_lowbits <= '0';
		source_LDRLbits <= '0';
		source_LDRMbits <= '0';
		source_2ndHbits <= '0';
		source_2ndMbits <= '0';
		source_2ndLbits <= '0';
		dest_LDRHbits <= '0';
		dest_LDRLbits <= '0';
		dest_2ndHbits <= '0';
		dest_2ndLbits <= '0';
		ea_only <= '0';
			set_direct_data <= '0';
			set_exec_tas <= '0';
			set_exec_cas <= '0';
			interrupt_mode_set_req <= '0';
			interrupt_mode_clr_req <= '0';
			trap_illegal <='0';
		trap_priv <='0';
		trap_1010 <='0';
		trap_1111 <='0';
		trap_cp <= '0';
		trap_cpfmt <= '0';
		trap_cptrap <= '0';
		trap_cp9 <= '0';
		trap_cppv <= '0';
		cp_cir_next <= '0';
		cp_cir_off <= "00000";
		cp_wdata <= (others => '0');
		cp_br_sel <= '0';
		cp_br_disp <= (others => '0');
		cp_mem_next <= '0';
		trap_trap <='0';
		trap_trapv <= '0';
		trap_mmu_config <= '0';
		trap_format_error <= '0';
		trapmake <='0';
		set_vectoraddr <='0';
		v_rte_format_valid := '0';
		IF rte_format_word(15 downto 12) = "0000"
		   OR rte_format_word(15 downto 12) = "0001"
		   OR rte_format_word(15 downto 12) = "0010"
		   OR rte_format_word(15 downto 12) = "1001"
		   OR rte_format_word(15 downto 12) = "1010"
		   OR rte_format_word(15 downto 12) = "1011"
		THEN
			v_rte_format_valid := '1';
		END IF;
		writeSR <= '0';
		set_stop <= '0';
		set_Z_error <= '0';
		check_aligned <='0';

		IF pmmu_config_err = '1' THEN
			trap_mmu_config <= '1';
			trapmake <= '1';
			report "TRAPMAKE_MMU_CONFIG: micro_state=" & micro_states'image(micro_state) severity warning;
		END IF;

		next_micro_state_c <= idle;
		build_logical <= '0';
		build_bcd <= '0';
		skipFetch <= make_berr;
		set_writePCbig <= '0';
		set_Suppress_Base <= '0';
		set_PCbase <= '0';

		IF rot_cnt/="000001" THEN
			set_rot_cnt <= rot_cnt-1;
		END IF;
		set_datatype <= datatype;

		set <= (OTHERS=>'0');
		set_exec <= (OTHERS=>'0');
		set(update_ld) <= '0';
		CASE opcode(7 downto 6) IS
			WHEN "00" => datatype <= "00";
			WHEN "01" => datatype <= "01";
			WHEN OTHERS => datatype <= "10";
		END CASE;

		IF execOPC='1' AND exec_write_back='1' THEN
			set(restore_ADDR) <= '1';
		END IF;

		IF interrupt='1' AND (trap_berr='1' OR trap_mmu_berr='1') THEN
			IF cpu(1)='1' THEN
				IF berr_long_frame='1' THEN
					next_micro_state_c <= berr_fill;
				ELSE
					next_micro_state_c <= berr1;
				END IF;
			ELSE
				next_micro_state_c <= trap0;
			END IF;
			setstackaddr <= '1';
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;
		IF interrupt='1' AND trap_addr_error='1' THEN
			IF cpu(1)='1' THEN
				next_micro_state_c <= berr_fill;
			ELSE
				next_micro_state_c <= trap0;
			END IF;
			setstackaddr <= '1';
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;
		IF trapmake='1' AND trapd='0' THEN
			IF cpu(1)='1' AND (trap_berr='1' OR trap_mmu_berr='1') THEN
				IF berr_long_frame='1' THEN
					next_micro_state_c <= berr_fill;
				ELSE
					next_micro_state_c <= berr1;
				END IF;
				setstackaddr <= '1';
			ELSIF cpu(1)='1' AND (trap_trapv='1' OR set_Z_error='1' OR exec(trap_chk)='1' OR
			                       set(trap_chk)='1' OR trap_mmu_config='1' OR trap_cptrap='1') THEN
				next_micro_state_c <= trap00;
			ELSIF cpu(1)='1' AND trap_cp9='1' THEN
				next_micro_state_c <= cp9a;
			else
				next_micro_state_c <= trap0;
			end if;
			IF use_VBR_Stackframe='0' THEN
				set(writePC_add) <= '1';
			END IF;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;
		IF micro_state=int1 OR (interrupt='1' AND trap_trace='1') THEN
			if trap_trace='1' AND cpu(1) = '1' then
				next_micro_state_c <= trap00;
			elsif cp_f9='1' then
				next_micro_state_c <= cp9a;
			else
				next_micro_state_c <= trap0;
			end if;
			IF preSVmode='0' THEN
				set(changeMode) <= '1';
			END IF;
			setstate <= "01";
		END IF;

		IF setexecOPC='1' AND trapmake='0' AND interrupt='0' AND FlagsSR(5)/=preSVmode AND
		   NOT (micro_state = rte4 AND cpu(1)='1' AND v_rte_format_valid='0') THEN
			set(changeMode) <= '1';
		END IF;

			IF interrupt='1' AND trap_interrupt='1'THEN
				next_micro_state_c <= int1;
				set(update_ld) <= '1';
				setstate <= "10";
				interrupt_mode_set_req <= '1';
			END IF;

		IF set(changeMode)='1' THEN
			IF cpu(1)='1' THEN
				IF preSVmode='0' THEN
					set(to_USP) <= '1';
					IF interrupt_mode='1' THEN
						IF FlagsSR(4)='1' THEN
							set(from_MSP) <= '1';
						ELSE
							set(from_ISP) <= '1';
						END IF;
					ELSIF FlagsSR(4)='1' THEN
						set(from_MSP) <= '1';
					ELSE
						set(from_ISP) <= '1';
					END IF;
				ELSE
						IF interrupt_mode='1' OR
						   ((stop='1') AND a7_is_msp='0') OR
						   ((stop='0') AND rte_saved_mbit='0') THEN
							set(to_ISP) <= '1';
						ELSE
							set(to_MSP) <= '1';
						END IF;
					set(from_USP) <= '1';
				END IF;
			ELSE
				set(to_USP) <= '1';
				set(from_USP) <= '1';
			END IF;
			setstackaddr <='1';
		END IF;

		IF ea_only='0' AND set(get_ea_now)='1' THEN
			setstate <= "10";
		END IF;

		IF setstate(1)='1' AND set_datatype(1)='1' THEN
			set(longaktion) <= '1';
		END IF;

		IF (ea_build_now='1' AND decodeOPC='1') OR exec(ea_build)='1' THEN
			IF (exec(ea_build)='1' OR set(ea_build)='1') AND fline_context_valid='1' AND fline_is_pmmu='1' AND
			   fline_opcode_latch(5 downto 3)="101" THEN
				next_micro_state_c <= ld_dAn1;
			ELSIF (exec(ea_build)='1' OR set(ea_build)='1') AND fline_context_valid='1' AND fline_is_pmmu='1' AND
			   fline_opcode_latch(5 downto 3)="110" THEN
				next_micro_state_c <= ld_AnXn1;
			ELSE
			CASE opcode(5 downto 3) IS
				WHEN "010"|"011"|"100" =>
					set(get_ea_now) <='1';
					IF ea_build_now='1' AND decodeOPC='1' THEN
						setnextpass <= '1';
					ELSIF exec(ea_build)='1' AND NOT (fline_context_valid='1' AND fline_is_pmmu='1') THEN
						setnextpass <= '1';
					END IF;
					IF opcode(3)='1' THEN
						IF NOT (fline_context_valid='1' AND fline_is_pmmu='1' AND
						        (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011")) THEN
							set(postadd) <= '1';
						END IF;
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;
					IF opcode(5)='1' THEN
							set(presub) <= '1';
							IF opcode(2 downto 0)="111" THEN
								set(use_SP) <= '1';
						END IF;
					END IF;
				WHEN "101" =>
					next_micro_state_c <= ld_dAn1;
				WHEN "110" =>
					next_micro_state_c <= ld_AnXn1;
					getbrief <='1';
				WHEN "111" =>
					CASE opcode(2 downto 0) IS
						WHEN "000" =>
							next_micro_state_c <= ld_nn;
						WHEN "001" =>
							set(longaktion) <= '1';
							next_micro_state_c <= ld_nn;
						WHEN "010" =>
							next_micro_state_c <= ld_dAn1;
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "011" =>
							next_micro_state_c <= ld_AnXn1;
							getbrief <= '1';
							set(dispouter) <= '1';
							set_Suppress_Base <= '1';
							set_PCbase <= '1';
						WHEN "100" =>
							setnextpass <= '1';
							set_direct_data <= '1';
							IF datatype="10" THEN
								set(longaktion) <= '1';
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				WHEN OTHERS => NULL;
			END CASE;
			END IF;
		END IF;
		CASE opcode(15 downto 12) IS
			WHEN "0000" =>
			IF opcode(8)='1' AND opcode(5 downto 3)="001" THEN
				datatype <= "00";
				set(use_SP) <= '1';
				set(no_Flags) <='1';
				IF opcode(7)='0' THEN
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVE) <= '1';
					set(movepl) <= '1';
				END IF;
				IF decodeOPC='1' THEN
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						set_direct_data <= '1';
					END IF;
					next_micro_state_c <= movep1;
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <='1';
				END IF;
			ELSE
				IF opcode(8)='1' OR opcode(11 downto 9)="100" THEN
					IF opcode(5 downto 3)/="001" AND
					   (opcode(8 downto 3)/="000111" OR opcode(2)='0') AND
					   (opcode(8 downto 2)/="1001111" OR opcode(1 downto 0)="00") AND
					   (opcode(7 downto 6)="00" OR opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
						set_exec(opcBITS) <= '1';
						set_exec(ea_data_OP1) <= '1';
						IF opcode(7 downto 6)/="00" THEN
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							write_back <= '1';
						END IF;
						IF opcode(5 downto 4)="00" THEN
							datatype <= "10";
						ELSE
							datatype <= "00";
						END IF;
						IF opcode(8)='0' THEN
							IF decodeOPC='1' THEN
								next_micro_state_c <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
						ELSE
							ea_build_now <= '1';
						END IF;
                ELSE
                    trap_illegal <= '1';
                    trapmake <= '1';
                END IF;
				ELSIF opcode(8 downto 6)="011" THEN
					IF cpu(1)='1' THEN
						IF opcode(11)='1' THEN
							IF (opcode(10 downto 9)/="00" AND
							   opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) OR
							   (opcode(10)='1' AND opcode(5 downto 0)="111100") THEN
								CASE opcode(10 downto 9) IS
									WHEN "01" => datatype <= "00";
									WHEN "10" => datatype <= "01";
									WHEN OTHERS => datatype <= "10";
								END CASE;
								set_exec_cas <= '1';
								IF opcode(10)='1' AND opcode(5 downto 0)="111100" THEN
									IF decodeOPC='1' THEN
										set(get_2ndOPC) <= '1';
										next_micro_state_c <= cas21;
									END IF;
								ELSE
									IF decodeOPC='1' THEN
										next_micro_state_c <= nop;
										set(get_2ndOPC) <= '1';
										set(ea_build) <= '1';
									END IF;
									IF micro_state=idle AND nextpass='1' THEN
										source_2ndLbits <= '1';
										set(ea_data_OP1) <= '1';
										set(addsub) <= '1';
										set(alu_exec) <= '1';
										set(alu_setFlags) <= '1';
										setstate <= "01";
										next_micro_state_c <= cas1;
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF opcode(10 downto 9)/="11" AND
							   opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN
								set(trap_chk) <= '1';
								datatype <= opcode(10 downto 9);
								IF decodeOPC='1' THEN
									next_micro_state_c <= nop;
									set(get_2ndOPC) <= '1';
									set(ea_build) <= '1';
								END IF;
								IF set(get_ea_now)='1' THEN
									set(mem_addsub) <= '1';
									set(OP1addr) <= '1';
								END IF;
								IF micro_state=idle AND nextpass='1' THEN
									setstate <= "10";
									set(hold_OP2) <='1';
									IF exe_datatype/="00" THEN
										check_aligned <='1';
									END IF;
									next_micro_state_c <= chk20;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(11 downto 8)="1110" AND opcode(7 downto 6)/="11" THEN
					IF cpu(0)='1' OR cpu(1)='1' THEN
						IF opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
							IF SVmode='1' THEN
								datatype <= opcode(7 downto 6);
								source_lowbits <= '1';
								IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
									source_areg <= '1';
								END IF;
								IF decodeOPC='1' THEN
									next_micro_state_c <= moves0;
									getbrief <='1';
								END IF;
							ELSE
								trap_priv <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(11 downto 9)="111" THEN
					trap_illegal <= '1';
					trapmake <= '1';
				ELSE
					IF opcode(7 downto 6)/="11" AND opcode(5 downto 3)/="001" THEN
						IF opcode(11 downto 9)="000" THEN
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="001" THEN
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcAND) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="010" OR opcode(11 downto 9)="011" THEN
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN
								set_exec(opcADD) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="101" THEN
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" OR (opcode(2 downto 0)="100" AND opcode(7)='0') THEN
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF opcode(11 downto 9)="110" THEN
							IF opcode(5 downto 3)/="111" OR opcode(2)='0' THEN
								set_exec(opcCMP) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
						IF (set_exec(opcor) OR set_exec(opcand) OR set_exec(opcADD) OR set_exec(opcEor) OR set_exec(opcCMP))='1' THEN
							IF opcode(7)='0' AND opcode(5 downto 0)="111100" AND (set_exec(opcAND) OR set_exec(opcOR) OR set_exec(opcEOR))='1' THEN
								IF decodeOPC='1' AND SVmode='0' AND opcode(6)='1' THEN
									trap_priv <= '1';
									trapmake <= '1';
								ELSE
									set(no_Flags) <= '1';
									IF decodeOPC='1' THEN
										IF opcode(6)='1' THEN
											set(to_SR) <= '1';
										END IF;
										set(to_CCR) <= '1';
										set(andiSR) <= set_exec(opcAND);
										set(eoriSR) <= set_exec(opcEOR);
										set(oriSR) <= set_exec(opcOR);
										setstate <= "01";
										next_micro_state_c <= nopnop;
									END IF;
								END IF;
							ELSIF opcode(7)='0' OR opcode(5 downto 0)/="111100" OR (set_exec(opcand) OR set_exec(opcor) OR set_exec(opcEor))='0' THEN
								IF decodeOPC='1' THEN
									next_micro_state_c <= andi;
									set(get_2ndOPC) <='1';
									set(ea_build) <= '1';
									set_direct_data <= '1';
									IF datatype="10" THEN
										set(longaktion) <= '1';
									END IF;
								END IF;
								IF opcode(5 downto 4)/="00" THEN
									set_exec(ea_data_OP1) <= '1';
								END IF;
								IF opcode(11 downto 9)/="110" THEN
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									write_back <= '1';
								END IF;
								IF opcode(10 downto 9)="10" THEN
									set(addsub) <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
			END IF;

			WHEN "0001"|"0010"|"0011" =>
				IF ((opcode(11 downto 10)="00" OR opcode(8 downto 6)/="111") AND
				   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND
				   (opcode(13)='1' OR (opcode(8 downto 6)/="001" AND opcode(5 downto 3)/="001"))) THEN
					set_exec(opcMOVE) <= '1';
					ea_build_now <= '1';
					IF opcode(8 downto 6)="001" THEN
						set(no_Flags) <= '1';
					END IF;
					IF opcode(5 downto 4)="00" THEN
						IF opcode(8 downto 7)="00" THEN
							set_exec(Regwrena) <= '1';
						END IF;
					END IF;
					CASE opcode(13 downto 12) IS
						WHEN "01" => datatype <= "00";
						WHEN "10" => datatype <= "10";
						WHEN OTHERS => datatype <= "01";
					END CASE;
					source_lowbits <= '1';
					IF opcode(3)='1' THEN
						source_areg <= '1';
					END IF;

					IF nextpass='1' OR opcode(5 downto 4)="00" THEN
						dest_hbits <= '1';
						IF opcode(8 downto 6)/="000" THEN
							dest_areg <= '1';
						END IF;
					END IF;

					IF micro_state=idle AND (nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1')) THEN
						CASE opcode(8 downto 6) IS
							WHEN "000"|"001" =>
									set_exec(Regwrena) <= '1';
							WHEN "010"|"011"|"100" =>
								IF opcode(6)='1' THEN
									set(postadd) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								IF opcode(8)='1' THEN
									set(presub) <= '1';
									IF opcode(11 downto 9)="111" THEN
										set(use_SP) <= '1';
									END IF;
								END IF;
								setstate <= "11";
								next_micro_state_c <= nop;
								IF nextpass='0' THEN
									set(write_reg) <= '1';
								END IF;
								IF ea_build_now='1' AND decodeOPC='1' THEN
									setnextpass <= '1';
								END IF;
							WHEN "101" =>
								next_micro_state_c <= st_dAn1;
							WHEN "110" =>
								next_micro_state_c <= st_AnXn1;
								getbrief <= '1';
							WHEN "111" =>
								CASE opcode(11 downto 9) IS
									WHEN "000" =>
										next_micro_state_c <= st_nn;
									WHEN "001" =>
										set(longaktion) <= '1';
										next_micro_state_c <= st_nn;
									WHEN OTHERS => NULL;
								END CASE;
							WHEN OTHERS => NULL;
						END CASE;
					END IF;
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;
			WHEN "0100" =>
				IF opcode(8)='1' THEN
					IF opcode(6)='1' THEN
						IF opcode(11 downto 9)="100" AND opcode(5 downto 3)="000" THEN
							IF opcode(7)='1' AND cpu(1)='1' THEN
								source_lowbits <= '1';
								set_exec(opcEXT) <= '1';
								set_exec(opcEXTB) <= '1';
								set_exec(opcMOVE) <= '1';
								set_exec(Regwrena) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSE
							IF opcode(7)='1' AND
							   (opcode(5)='1' OR opcode(4 downto 3)="10") AND
							   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN
								source_lowbits <= '1';
								source_areg <= '1';
								ea_only <= '1';
								set_exec(Regwrena) <= '1';
								set_exec(opcMOVE) <='1';
								set(no_Flags) <='1';
								IF opcode(5 downto 3)="010" THEN
									dest_areg <= '1';
									dest_hbits <= '1';
								ELSE
									ea_build_now <= '1';
								END IF;
								IF set(get_ea_now)='1' THEN
									setstate <= "01";
									set_direct_data <= '1';
								END IF;
								IF setexecOPC='1' THEN
									dest_areg <= '1';
									dest_hbits <= '1';
								END IF;
							ELSE
								trap_illegal <='1';
								trapmake <='1';
							END IF;
						END IF;
					ELSE
						IF opcode(5 downto 3)/="001" AND
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
							IF opcode(7)='1' THEN
								datatype <= "01";
								set(trap_chk) <= '1';
								IF (c_out(1)='0' OR OP1out(15)='1' OR OP2out(15)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSIF cpu(1)='1' THEN
								datatype <= "10";
								set(trap_chk) <= '1';
								IF (c_out(2)='0' OR OP1out(31)='1' OR OP2out(31)='1') AND exec(opcCHK)='1' THEN
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
							IF opcode(7)='1' OR cpu(1)='1' THEN
								IF (nextpass='1' OR opcode(5 downto 4)="00") AND exec(opcCHK)='0' AND micro_state=idle THEN
									set_exec(opcCHK) <= '1';
								END IF;
								ea_build_now <= '1';
								set(addsub) <= '1';
								IF setexecOPC='1' THEN
									dest_hbits <= '1';
									source_lowbits <='1';
								END IF;
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE
					CASE opcode(11 downto 9) IS
						WHEN "000"=>
							IF (opcode(5 downto 3)/="001" AND
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN
								IF opcode(7 downto 6)="11" THEN
									IF SR_Read=0 OR (cpu(0)='0' AND cpu(1)='0' AND SR_Read=2) OR SVmode='1'  THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';
										IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
											skipFetch <= '1';
										END IF;
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE
									ea_build_now <= '1';
									set_exec(use_XZFlag) <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "001"=>
							IF (opcode(5 downto 3)/="001" AND
							   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN
								IF opcode(7 downto 6)="11" THEN
									IF SR_Read=1 OR ((cpu(0)='1' OR cpu(1)='1') AND SR_Read=2) THEN
										ea_build_now <= '1';
										set_exec(opcMOVESR) <= '1';
										datatype <= "01";
										write_back <='1';
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								ELSE
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcAND) <= '1';
									IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
										skipFetch <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						WHEN "010"=>
							IF opcode(7 downto 6)="11" THEN
								IF opcode(5 downto 3)/="001" AND
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
									ea_build_now <= '1';
									datatype <= "01";
									source_lowbits <= '1';
									IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
										set(to_CCR) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								IF (opcode(5 downto 3)/="001" AND
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcADD) <= '1';
									set(addsub) <= '1';
									source_lowbits <= '1';
									IF opcode(5 downto 4)="00" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP1out_zero) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "011"=>
							IF opcode(7 downto 6)="11" THEN
								IF opcode(5 downto 3)/="001" AND
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
									IF SVmode='1' THEN
										ea_build_now <= '1';
										datatype <= "01";
										source_lowbits <= '1';
										IF (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											set(to_SR) <= '1';
											set(to_CCR) <= '1';
										END IF;
										IF exec(to_SR)='1' OR (decodeOPC='1' AND opcode(5 downto 4)="00") OR (state="10" AND addrvalue='0') OR direct_data='1' THEN
											setstate <="01";
										END IF;
									ELSE
										trap_priv <= '1';
										trapmake <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								IF opcode(5 downto 3)/="001" AND
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
									ea_build_now <= '1';
									write_back <='1';
									set_exec(opcEOR) <= '1';
									set_exec(ea_data_OP1) <= '1';
									IF opcode(5 downto 3)="000" THEN
										set_exec(Regwrena) <= '1';
									END IF;
									IF setexecOPC='1' THEN
										set(OP2out_one) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "100"|"110"=>
							IF opcode(7)='1' THEN
								IF opcode(5 downto 3)="000" AND opcode(10)='0' THEN
									source_lowbits <= '1';
									set_exec(opcEXT) <= '1';
									set_exec(opcMOVE) <= '1';
									set_exec(Regwrena) <= '1';
									IF opcode(6)='0' THEN
										datatype <= "01";
										set_exec(opcEXTB) <= '1';
									END IF;
								ELSE
									IF (opcode(10)='1' OR ((opcode(5)='1' OR opcode(4 downto 3)="10") AND
									   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND
									   (opcode(10)='0' OR (opcode(5 downto 4)/="00" AND
									   opcode(5 downto 3)/="100" AND
									   opcode(5 downto 2)/="1111")) THEN
										ea_only <= '1';
										set(no_Flags) <= '1';
										IF opcode(6)='0' THEN
											datatype <= "01";
										END IF;
										IF (opcode(5 downto 3)="100" OR opcode(5 downto 3)="011") AND state="01" THEN
											set_exec(save_memaddr) <= '1';
											set_exec(Regwrena) <= '1';
										END IF;
										IF opcode(5 downto 3)="100" THEN
											movem_presub <= '1';
											set(subidx) <= '1';
										END IF;
										IF state="10" AND addrvalue='0' THEN
											set(Regwrena) <= '1';
											set(opcMOVE) <= '1';
										END IF;
										IF decodeOPC='1' THEN
											set(get_2ndOPC) <='1';
											IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
												next_micro_state_c <= movem1;
											ELSE
												next_micro_state_c <= nop;
												set(ea_build) <= '1';
											END IF;
										END IF;
										IF set(get_ea_now)='1' THEN
											IF movem_run='1' THEN
												set(movem_action) <= '1';
												IF opcode(10)='0' THEN
													setstate <="11";
													set(write_reg) <= '1';
												ELSE
													setstate <="10";
												END IF;
												next_micro_state_c <= movem2;
												set(mem_addsub) <= '1';
											ELSE
												setstate <="01";
											END IF;
										END IF;
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;
								END IF;
							ELSE
								IF opcode(10)='1' THEN
									IF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND
									   MUL_Hardware=1 AND (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2))) THEN
										IF decodeOPC='1' THEN
											next_micro_state_c <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										IF (micro_state=idle AND nextpass='1') OR
										   (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
											dest_2ndHbits <= '1';
											datatype <= "10";
											set(opcMULU) <= '1';
											set(write_lowlong) <= '1';
											IF sndOPC(10)='1' THEN
												setstate <="01";
												next_micro_state_c <= mul_end2;
											END IF;
											set(Regwrena) <= '1';
										END IF;
										source_lowbits <='1';
										datatype <= "10";

									ELSIF opcode(8 downto 7)="00" AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") AND
									   ((opcode(6)='1' AND (DIV_Mode=1 OR (cpu(1)='1' AND DIV_Mode=2))) OR
									   (opcode(6)='0' AND (MUL_Mode=1 OR (cpu(1)='1' AND MUL_Mode=2)))) THEN
										IF decodeOPC='1' THEN
											next_micro_state_c <= nop;
											set(get_2ndOPC) <= '1';
											set(ea_build) <= '1';
										END IF;
										IF (micro_state=idle AND nextpass='1') OR
										   (opcode(5 downto 4)="00" AND exec(ea_build)='1') THEN
											setstate <="01";
											dest_2ndHbits <= '1';
											source_2ndLbits <= '1';
											IF opcode(6)='1' THEN
												next_micro_state_c <= div1;
											ELSE
												next_micro_state_c <= mul1;
												set(ld_rot_cnt) <= '1';
											END IF;
										END IF;
										source_lowbits <='1';
										IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
											dest_hbits <= '1';
										END IF;
										datatype <= "10";
									ELSE
										trap_illegal <= '1';
										trapmake <= '1';
									END IF;

								ELSE
									IF opcode(6)='1' THEN
										datatype <= "10";
										IF opcode(5 downto 3)="000" THEN
											set_exec(opcSWAP) <= '1';
											set_exec(Regwrena) <= '1';
										ELSIF opcode(5 downto 3)="001" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSE
											IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
											   opcode(5 downto 3)/="100" AND
											   opcode(5 downto 2)/="1111" THEN
												ea_only <= '1';
												ea_build_now <= '1';
												IF nextpass='1' AND micro_state=idle THEN
													set(presub) <= '1';
													setstackaddr <='1';
													setstate <="11";
													next_micro_state_c <= nop;
												END IF;
												IF set(get_ea_now)='1' THEN
													setstate <="01";
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;
									ELSE
										IF opcode(5 downto 3)="001" THEN
											datatype <= "10";
											set_exec(opcADD) <= '1';
											set_exec(Regwrena) <= '1';
											set(no_Flags) <= '1';
											IF decodeOPC='1' THEN
												set(linksp) <= '1';
												set(longaktion) <= '1';
												next_micro_state_c <= link1;
												set(presub) <= '1';
												setstackaddr <='1';
												set(mem_addsub) <= '1';
												source_lowbits <= '1';
												source_areg <= '1';
												set(store_ea_data) <= '1';
											END IF;
										ELSE
											IF opcode(5 downto 3)/="001" AND
											   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
												ea_build_now <= '1';
												set_exec(use_XZFlag) <= '1';
												write_back <='1';
												set_exec(opcADD) <= '1';
												set_exec(opcSBCD) <= '1';
												set(addsub) <= '1';
												source_lowbits <= '1';
												IF opcode(5 downto 4)="00" THEN
													set_exec(Regwrena) <= '1';
												END IF;
												IF setexecOPC='1' THEN
													set(OP1out_zero) <= '1';
												END IF;
											ELSE
												trap_illegal <= '1';
												trapmake <= '1';
											END IF;
										END IF;
									END IF;
								END IF;
							END IF;
						WHEN "101"=>
							IF opcode(7 downto 3)="11111" AND opcode(2 downto 1)/="00" THEN
								trap_illegal <= '1';
								trapmake <= '1';
							ELSE
								IF (opcode(7 downto 6)/="11" OR
								   (opcode(5 downto 3)/="001" AND
								   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) AND
								   ((opcode(7 downto 6)/="00" OR (opcode(5 downto 3)/="001")) AND
								   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) THEN
									ea_build_now <= '1';
									IF setexecOPC='1' THEN
										source_lowbits <= '1';
										IF opcode(3)='1' THEN
											source_areg <= '1';
										END IF;
									END IF;
									set_exec(opcMOVE) <= '1';
									IF opcode(7 downto 6)="11" THEN
										set_exec_tas <= '1';
										write_back <= '1';
										datatype <= "00";
										IF opcode(5 downto 4)="00" THEN
											set_exec(Regwrena) <= '1';
										END IF;
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							END IF;
						WHEN "111"=>

							IF opcode(7)='1' AND micro_state /= moves0 AND micro_state /= moves1 THEN
								IF (opcode(5)='1' OR opcode(4 downto 3)="10") AND
								   opcode(5 downto 3)/="100" AND opcode(5 downto 2)/="1111" THEN
									datatype <= "10";
									ea_only <= '1';
									ea_build_now <= '1';
									IF exec(ea_to_pc)='1' THEN
										next_micro_state_c <= nop;
									END IF;
									IF nextpass='1' AND micro_state=idle AND opcode(6)='0' THEN
										set(presub) <= '1';
										setstackaddr <='1';
										setstate <="11";
										next_micro_state_c <= nopnop;
									END IF;

									IF micro_state=ld_AnXn1 AND brief(8)='0'THEN
										skipFetch <= '1';
									END IF;
									IF micro_state=ld_dAn1 THEN
										skipFetch <= '1';
									END IF;
									IF state="00" THEN
										writePC <= '1';
									END IF;
									set(hold_dwr) <= '1';
									set(no_Flags) <= '1';
									IF set(get_ea_now)='1' THEN
										IF exec(longaktion)='0' OR long_done='1' THEN
											skipFetch <= '1';
										END IF;
										setstate <="01";
										set(ea_to_pc) <= '1';
									END IF;
								ELSE
									trap_illegal <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								CASE opcode(6 downto 0) IS
									WHEN "1000000"|"1000001"|"1000010"|"1000011"|"1000100"|"1000101"|"1000110"|"1000111"|
									     "1001000"|"1001001"|"1001010"|"1001011"|"1001100"|"1001101"|"1001110"|"1001111" =>
											trap_trap <='1';
											trapmake <= '1';

									WHEN "1010000"|"1010001"|"1010010"|"1010011"|"1010100"|"1010101"|"1010110"|"1010111"=>
										datatype <= "10";
										set_exec(opcADD) <= '1';
										set_exec(Regwrena) <= '1';
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											next_micro_state_c <= link1;
											set(presub) <= '1';
											setstackaddr <='1';
											set(mem_addsub) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											set(store_ea_data) <= '1';
										END IF;

									WHEN "1011000"|"1011001"|"1011010"|"1011011"|"1011100"|"1011101"|"1011110"|"1011111" =>
										datatype <= "10";
										set_exec(Regwrena) <= '1';
										set_exec(opcMOVE) <= '1';
										set(no_Flags) <= '1';
										IF decodeOPC='1' THEN
											setstate <= "01";
											next_micro_state_c <= unlink1;
											set(opcMOVE) <= '1';
											set(Regwrena) <= '1';
											setstackaddr <='1';
											source_lowbits <= '1';
											source_areg <= '1';
										END IF;

									WHEN "1100000"|"1100001"|"1100010"|"1100011"|"1100100"|"1100101"|"1100110"|"1100111" =>
										IF SVmode='1' THEN
											set(to_USP) <= '1';
											source_lowbits <= '1';
											source_areg <= '1';
											datatype <= "10";
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;

									WHEN "1101000"|"1101001"|"1101010"|"1101011"|"1101100"|"1101101"|"1101110"|"1101111" =>
										IF SVmode='1' THEN
											set(from_USP) <= '1';
											datatype <= "10";
											set_exec(Regwrena) <= '1';
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;

									WHEN "1110000" =>
										IF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											set(opcRESET) <= '1';
											IF decodeOPC='1' THEN
												set(ld_rot_cnt) <= '1';
												set_rot_cnt <= "000000";
											END IF;
										END IF;

									WHEN "1110001" =>

										WHEN "1110010" =>
											IF SVmode='0' AND stop='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											IF decodeOPC='1' THEN
												setnextpass <= '1';
												set_stop <= '1';
											END IF;
											IF stop='1' THEN
												skipFetch <= '1';
											END IF;

										END IF;

									WHEN "1110011"|"1110111" =>
										IF SVmode='1' OR opcode(2)='1' THEN
											IF decodeOPC='1' THEN
												setstate <= "10";
												set(postadd) <= '1';
												setstackaddr <= '1';
												IF opcode(2)='1' THEN
													set(directCCR) <= '1';
												ELSE
													set(directSR) <= '1';
												END IF;
												next_micro_state_c <= rte1;
											END IF;
										ELSE
											trap_priv <= '1';
											trapmake <= '1';
										END IF;

									WHEN "1110100" =>
										IF cpu="00" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSE
											datatype <= "10";
											IF decodeOPC='1' THEN
												setstate <= "10";
												set(postadd) <= '1';
												setstackaddr <= '1';
												set(direct_delta) <= '1';
												set(directPC) <= '1';
												set_direct_data <= '1';
												next_micro_state_c <= rtd1;
											END IF;
										END IF;

									WHEN "1110101" =>
										datatype <= "10";
										IF decodeOPC='1' THEN
											setstate <= "10";
											set(postadd) <= '1';
											setstackaddr <= '1';
											set(direct_delta) <= '1';
											set(directPC) <= '1';
											next_micro_state_c <= nopnop;
										END IF;

									WHEN "1110110" =>
										IF decodeOPC='1' THEN
											setstate <= "01";
										END IF;
										IF Flags(1)='1' AND state="01" THEN
											trap_trapv <= '1';
											trapmake <= '1';
										END IF;

									WHEN "1111000" =>
										trap_illegal <= '1';
										trapmake <= '1';

									WHEN "1111010"|"1111011" =>
										IF cpu="00" THEN
											trap_illegal <= '1';
											trapmake <= '1';
										ELSIF SVmode='0' THEN
											trap_priv <= '1';
											trapmake <= '1';
										ELSE
											datatype <= "10";
											IF opcode(0)='0' THEN
												set_exec(movec_rd) <= '1';
											ELSE
												set_exec(movec_wr) <= '1';
											END IF;
											IF decodeOPC='1' THEN
												next_micro_state_c <= movec1;
												getbrief <='1';
												setnextpass <= '1';
											END IF;
										END IF;

									WHEN OTHERS =>
										trap_illegal <= '1';
										trapmake <= '1';
								END CASE;
							END IF;
						WHEN OTHERS => NULL;
					END CASE;
				END IF;
			WHEN "0101" =>
					IF opcode(7 downto 6)="11" THEN
						IF opcode(5 downto 3)="001" THEN
							IF decodeOPC='1' THEN
								next_micro_state_c <= dbcc1;
								set(OP2out_one) <= '1';
								data_is_source <= '1';
							END IF;
						ELSIF opcode(5 downto 3)="111" AND (opcode(2 downto 1)="01" OR opcode(2 downto 0)="100") THEN
							IF cpu(1)='1' THEN
								IF opcode(2 downto 1)="01" THEN
									IF decodeOPC='1' THEN
										IF opcode(0)='1' THEN
											set(longaktion) <= '1';
										END IF;
										next_micro_state_c <= nop;
									END IF;
								ELSE
									IF decodeOPC='1' THEN
										setstate <= "01";
									END IF;
								END IF;
								IF exe_condition='1' AND decodeOPC='0' THEN
									trap_trapv <= '1';
									trapmake <= '1';
								END IF;
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						ELSIF (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
							datatype <= "00";
							ea_build_now <= '1';
							write_back <= '1';
							set_exec(opcScc) <= '1';
							IF (cpu(0)='1' OR cpu(1)='1') AND state="10" AND addrvalue='0' THEN
								skipFetch <= '1';
							END IF;
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						IF opcode(7 downto 3)/="00001" AND
						   (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
							ea_build_now <= '1';
							IF opcode(5 downto 3)="001" THEN
								set(no_Flags) <= '1';
							END IF;
							IF opcode(8)='1' THEN
								set(addsub) <= '1';
							END IF;
							write_back <= '1';
							set_exec(opcADDQ) <= '1';
							set_exec(opcADD) <= '1';
							set_exec(ea_data_OP1) <= '1';
							IF opcode(5 downto 4)="00" THEN
								set_exec(Regwrena) <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
			WHEN "0110" =>
				datatype <= "10";

				IF micro_state=idle THEN
					IF opcode(11 downto 8)="0001" THEN
						set(presub) <= '1';
						setstackaddr <='1';
						IF opcode(7 downto 0)="11111111" THEN
							next_micro_state_c <= bsr2;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state_c <= bsr2;
						ELSE
							next_micro_state_c <= bsr1;
							setstate <= "11";
							writePC <= '1';
						END IF;
					ELSE
						IF opcode(7 downto 0)="11111111" THEN
							next_micro_state_c <= bra1;
							set(longaktion) <= '1';
						ELSIF opcode(7 downto 0)="00000000" THEN
							next_micro_state_c <= bra1;
						ELSE
							setstate <= "01";
							next_micro_state_c <= bra1;
						END IF;
					END IF;
				END IF;

			WHEN "0111" =>
				IF opcode(8)='0' THEN
					datatype <= "10";
					set_exec(Regwrena) <= '1';
					set_exec(opcMOVEQ) <= '1';
					set_exec(opcMOVE) <= '1';
					dest_hbits <= '1';
				ELSE
					trap_illegal <= '1';
					trapmake <= '1';
				END IF;

			WHEN "1000" =>
				IF opcode(7 downto 6)="11" THEN
					IF DIV_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
						IF opcode(5 downto 4)="00" THEN
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							setstate <="01";
							next_micro_state_c <= div1;
						END IF;
						ea_build_now <= '1';
						IF z_error='0' AND set_V_Flag='0' THEN
							set_exec(Regwrena) <= '1';
						END IF;
							source_lowbits <='1';
						IF nextpass='1' OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN
					IF opcode(7 downto 6)="00" THEN
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcSBCD) <= '1';
						set(addsub) <= '1';
					ELSIF opcode(7 downto 6)="01" OR opcode(7 downto 6)="10" THEN
						set_exec(ea_data_OP1) <= '1';
						set(no_Flags) <= '1';
						source_lowbits <='1';
						IF opcode(7 downto 6) = "01" THEN
							set_exec(opcPACK) <= '1';
							datatype <= "01";
						ELSE
							set_exec(opcUNPACK) <= '1';
							datatype <= "00";
						END IF;
						IF opcode(3)='0' THEN
							IF opcode(7 downto 6) = "01" THEN
								set_datatype <= "00";
							ELSE
								set_datatype <= "01";
							END IF;
							set_exec(Regwrena) <= '1';
							dest_hbits <= '1';
							IF decodeOPC='1' THEN
								next_micro_state_c <= nop;
								set(store_ea_packdata) <= '1';
								set(store_ea_data) <= '1';
							END IF;
						ELSE
							write_back <= '1';
							IF decodeOPC='1' THEN
								next_micro_state_c <= pack1;
								set_direct_data <= '1';
							END IF;
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE
					IF opcode(7 downto 6)/="11" AND
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN
						set_exec(opcOR) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;

			WHEN "1001"|"1101" =>
				IF opcode(8 downto 3)/="000001" AND
				   (((opcode(8)='0' OR opcode(7 downto 6)="11") AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR
				   (opcode(8)='1' AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN
					set_exec(opcADD) <= '1';
					ea_build_now <= '1';
					IF opcode(14)='0' THEN
						set(addsub) <= '1';
					END IF;
					IF opcode(7 downto 6)="11" THEN
						IF opcode(8)='0' THEN
							datatype <= "01";
						END IF;
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF opcode(3)='1' THEN
							source_areg <= '1';
						END IF;
						set(no_Flags) <= '1';
						IF setexecOPC='1' THEN
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
					ELSE
						IF opcode(8)='1' AND opcode(5 downto 4)="00" THEN
							build_bcd <= '1';
						ELSE
							build_logical <= '1';
						END IF;
					END IF;
				ELSE
						trap_illegal <= '1';
						trapmake <= '1';
				END IF;
			WHEN "1010" =>
				trap_1010 <= '1';
				trapmake <= '1';
			WHEN "1011" =>
				IF opcode(7 downto 6)="11" THEN
					IF opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00" THEN
						ea_build_now <= '1';
						IF opcode(8)='0' THEN
							datatype <= "01";
							set_exec(opcCPMAW) <= '1';
						END IF;
						set_exec(opcCMP) <= '1';
						IF setexecOPC='1' THEN
							source_lowbits <='1';
							IF opcode(3)='1' THEN
								source_areg <= '1';
							END IF;
							dest_areg <='1';
							dest_hbits <= '1';
						END IF;
						set(addsub) <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSE
					IF opcode(8)='1' THEN
						IF opcode(5 downto 3)="001" THEN
							ea_build_now <= '1';
							set_exec(opcCMP) <= '1';
							IF decodeOPC='1' THEN
								IF opcode(2 downto 0)="111" THEN
									set(use_SP) <= '1';
								END IF;
								setstate <= "10";
								set(update_ld) <= '1';
								set(postadd) <= '1';
								next_micro_state_c <= cmpm;
							END IF;
							set_exec(ea_data_OP1) <= '1';
							set(addsub) <= '1';
						ELSE
							IF opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00" THEN
								ea_build_now <= '1';
								build_logical <= '1';
								set_exec(opcEOR) <= '1';
							ELSE
								trap_illegal <= '1';
								trapmake <= '1';
							END IF;
						END IF;
					ELSE
						IF opcode(8 downto 3)/="000001" AND
						   (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
							ea_build_now <= '1';
							build_logical <= '1';
							set_exec(opcCMP) <= '1';
							set(addsub) <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				END IF;
			WHEN "1100" =>
				IF opcode(7 downto 6)="11" THEN
					IF MUL_Mode/=3 AND
					   opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00") THEN
						IF opcode(5 downto 4)="00" THEN
							regdirectsource <= '1';
						END IF;
						IF (micro_state=idle AND nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							IF MUL_Hardware=0 THEN
								setstate <="01";
								set(ld_rot_cnt) <= '1';
								next_micro_state_c <= mul1;
							ELSE
								set_exec(write_lowlong) <= '1';
								set_exec(opcMULU) <= '1';
							END IF;
						END IF;
						ea_build_now <= '1';
						set_exec(Regwrena) <= '1';
						source_lowbits <='1';
						IF (nextpass='1') OR (opcode(5 downto 4)="00" AND decodeOPC='1') THEN
							dest_hbits <= '1';
						END IF;
						datatype <= "01";
						IF setexecOPC='1' THEN
							datatype <= "10";
						END IF;
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				ELSIF opcode(8)='1' AND opcode(5 downto 4)="00" THEN
					IF opcode(7 downto 6)="00" THEN
						build_bcd <= '1';
						set_exec(opcADD) <= '1';
						set_exec(opcABCD) <= '1';
					ELSE
						IF opcode(7 downto 4)="0100" OR opcode(7 downto 3)="10001" THEN
							datatype <= "10";
							set(Regwrena) <= '1';
							set(exg) <= '1';
							set(alu_move) <= '1';
							IF opcode(6)='1' AND opcode(3)='1' THEN
								dest_areg <= '1';
								source_areg <= '1';
							END IF;
							IF decodeOPC='1' THEN
								setstate <= "01";
							ELSE
								dest_hbits <= '1';
							END IF;
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					END IF;
				ELSE
					IF opcode(7 downto 6)/="11" AND
					   ((opcode(8)='0' AND opcode(5 downto 3)/="001" AND (opcode(5 downto 2)/="1111" OR opcode(1 downto 0)="00")) OR
					   (opcode(8)='1' AND opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00"))) THEN
						set_exec(opcAND) <= '1';
						build_logical <= '1';
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;
				END IF;
			WHEN "1110" =>
				IF opcode(7 downto 6)="11" THEN
					IF opcode(11)='0' THEN
					   IF (opcode(5 downto 4)/="00" AND (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00")) THEN
							IF BarrelShifter=0 THEN
								set_exec(opcROT) <= '1';
							ELSE
								set_exec(exec_BS) <='1';
							END IF;
							ea_build_now <= '1';
							datatype <= "01";
							set_rot_bits <= opcode(10 downto 9);
							set_exec(ea_data_OP1) <= '1';
							write_back <= '1';
						ELSE
							trap_illegal <= '1';
							trapmake <= '1';
						END IF;
					ELSE
						IF BitField=0 OR (cpu(1)='0' AND BitField=2) OR
						   ((opcode(10 downto 9)="11" OR opcode(10 downto 8)="010" OR opcode(10 downto 8)="100") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR (opcode(5 downto 3)="111" AND opcode(2 downto 1)/="00"))) OR
						   ((opcode(10 downto 9)="00" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101") AND
						   (opcode(5 downto 3)="001" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" OR opcode(5 downto 2)="1111")) THEN
							trap_illegal <= '1';
							trapmake <= '1';
						ELSE
							IF decodeOPC='1' THEN
								next_micro_state_c <= nop;
								set(get_2ndOPC) <= '1';
								set(ea_build) <= '1';
							END IF;
							set_exec(opcBF) <= '1';
							IF opcode(10)='1' OR opcode(8)='0' THEN
								set_exec(opcBFwb) <= '1';
							END IF;
							IF opcode(10 downto 8)="111" THEN
								set_exec(ea_data_OP1) <= '1';
							END IF;
							IF opcode(10 downto 8)="010" OR opcode(10 downto 8)="100" OR opcode(10 downto 8)="110" OR opcode(10 downto 8)="111" THEN
								write_back <= '1';
							END IF;
							ea_only <= '1';
							IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN
								set_exec(Regwrena) <= '1';
							END IF;
							IF opcode(4 downto 3)="00" THEN
								IF opcode(10 downto 8)/="000" THEN
									set_exec(Regwrena) <= '1';
								END IF;
								IF exec(ea_build)='1' THEN
									dest_2ndHbits <= '1';
									source_2ndLbits <= '1';
									set(get_bfoffset) <='1';
									setstate <= "01";
								END IF;
							END IF;
							IF set(get_ea_now)='1' THEN
								setstate <= "01";
							END IF;
							IF exec(get_ea_now)='1' THEN
								dest_2ndHbits <= '1';
								source_2ndLbits <= '1';
								set(get_bfoffset) <='1';
								setstate <= "01";
								set(mem_addsub) <='1';
								next_micro_state_c <= bf1;
							END IF;
							IF setexecOPC='1' THEN
								IF opcode(10 downto 8)="111" THEN
									source_2ndHbits <= '1';
								ELSE
									source_lowbits <= '1';
								END IF;
								IF opcode(10 downto 8)="001" OR opcode(10 downto 8)="011" OR opcode(10 downto 8)="101" THEN
									dest_2ndHbits <= '1';
								END IF;
							END IF;
						END IF;
					END IF;
				ELSE
					data_is_source <= '1';
					IF BarrelShifter=0 OR (cpu(1)='0' AND BarrelShifter=2) THEN
						set_exec(opcROT) <= '1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
						IF decodeOPC='1' THEN
							IF opcode(5)='1' THEN
								next_micro_state_c <= rota1;
								set(ld_rot_cnt) <= '1';
								setstate <= "01";
							ELSE
								set_rot_cnt(2 downto 0) <= opcode(11 downto 9);
								IF opcode(11 downto 9)="000" THEN
									set_rot_cnt(3) <='1';
								ELSE
									set_rot_cnt(3) <='0';
								END IF;
							END IF;
						END IF;
					ELSE
						set_exec(exec_BS) <='1';
						set_rot_bits <= opcode(4 downto 3);
						set_exec(Regwrena) <= '1';
					END IF;
				END IF;
			WHEN "1111" =>
                IF cpu(1)='1' AND opcode(11 downto 8)="0000" THEN
					IF SVmode='1' THEN
						IF decodeOPC='1' THEN
								IF clkena_lw='0' THEN
									set(get_2ndOPC) <= '1';
									setstate <= "00";
								ELSE
								set(get_2ndOPC) <= '1';
								IF opcode(5 downto 3) = "101" OR opcode(5 downto 3) = "110" OR opcode(5 downto 3) = "111" THEN
									null;
								ELSE
									setstate <= "01";
								END IF;
								getbrief <= '1';
								next_micro_state_c <= pmove_decode;
							END IF;

						END IF;
					ELSE
						trap_priv <= '1';
						trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(11 downto 9)/="000" AND
				      (opcode(8 downto 6)="000" OR opcode(8 downto 7)="01" OR
				       (opcode(8 downto 6)="001" AND
				        (opcode(5 downto 3)/="111" OR opcode(2 downto 0)="000" OR opcode(2 downto 0)="001" OR
				         opcode(2 downto 0)="010" OR opcode(2 downto 0)="011" OR opcode(2 downto 0)="100"))) THEN
					IF decodeOPC='1' THEN
						IF clkena_lw='0' THEN
							set(get_2ndOPC) <= '1';
							setstate <= "00";
						ELSE
							set(get_2ndOPC) <= '1';
							setstate <= "01";
							getbrief <= '1';
							next_micro_state_c <= cp_decode;
						END IF;
					END IF;
					ELSIF cpu(1)='1' AND opcode(8 downto 6)="100" THEN
						IF SVmode='0' THEN
							trap_priv <= '1';
							trapmake <= '1';
						ELSIF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND
						      (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") AND
						      opcode(11 downto 9)/="000" THEN
							IF decodeOPC='1' THEN
								IF clkena_lw='0' THEN
									set(get_2ndOPC) <= '1';
									setstate <= "00";
								ELSE
									set(get_2ndOPC) <= '1';
									setstate <= "01";
									getbrief <= '1';
									next_micro_state_c <= cp_decode;
								END IF;
							END IF;
						ELSIF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="011" AND
						      (opcode(5 downto 3)/="111" OR opcode(2 downto 1)="00") THEN
							trap_1111 <= '1';
							trapmake <= '1';
						ELSE
							trap_1111 <= '1';
							trapmake <= '1';
					END IF;
				ELSIF cpu(1)='1' AND opcode(8 downto 6)="101" THEN
						IF SVmode='0' THEN
							trap_priv <= '1';
							trapmake <= '1';
						ELSIF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="100" AND
						      (opcode(5 downto 3)/="111" OR opcode(2)='0') AND
						      opcode(11 downto 9)/="000" THEN
							IF decodeOPC='1' THEN
								IF clkena_lw='0' THEN
									set(get_2ndOPC) <= '1';
									setstate <= "00";
								ELSE
									set(get_2ndOPC) <= '1';
									setstate <= "01";
									getbrief <= '1';
									next_micro_state_c <= cp_decode;
								END IF;
							END IF;
						ELSIF opcode(5 downto 4)/="00" AND opcode(5 downto 3)/="100" AND
						      (opcode(5 downto 3)/="111" OR opcode(2)='0') THEN
							trap_1111 <= '1';
							trapmake <= '1';
						ELSE
							trap_1111 <= '1';
							trapmake <= '1';
					END IF;
				ELSE
					trap_1111 <= '1';
					trapmake <= '1';
				END IF;
			WHEN OTHERS =>
				trap_illegal <= '1';
				trapmake <= '1';

		END CASE;

		IF build_logical='1' THEN
			ea_build_now <= '1';
			IF set_exec(opcCMP)='0' AND (opcode(8)='0' OR opcode(5 downto 4)="00" ) THEN
				set_exec(Regwrena) <= '1';
			END IF;
			IF opcode(8)='1' THEN
				write_back <= '1';
				set_exec(ea_data_OP1) <= '1';
			ELSE
				source_lowbits <='1';
				IF opcode(3)='1' THEN
					source_areg <= '1';
				END IF;
				IF setexecOPC='1' THEN
					dest_hbits <= '1';
				END IF;
			END IF;
		END IF;

		IF build_bcd='1' THEN
			set_exec(use_XZFlag) <= '1';
			source_lowbits <='1';
			IF opcode(3)='1' THEN
				set_exec(ea_data_OP1) <= '1';
				write_back <= '1';
				IF decodeOPC='1' THEN
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					setstate <= "10";
					set(update_ld) <= '1';
					set(presub) <= '1';
					next_micro_state_c <= op_AxAy;
					dest_areg <= '1';
				END IF;
			ELSE
				dest_hbits <= '1';
				set_exec(Regwrena) <= '1';
			END IF;
		END IF;

		IF set_Z_error='1'  THEN
			trapmake <= '1';
			IF trapd='0' THEN
				writePC <= '1';
			END IF;
		END IF;

		IF mmu_restart_active='1' THEN
			trap_trapv <= '0';
			set_Z_error <= '0';
			set(trap_chk) <= '0';
			set_exec(opcCHK) <= '0';
			IF make_berr='0' AND trap_berr='0' AND trap_mmu_berr='0' THEN
				trapmake <= '0';
				writePC <= '0';
			END IF;
		END IF;

		IF rising_edge(clk) THEN
	        IF Reset='1' THEN
				micro_state <= ld_nn;
				pmmu_config_ack <= '0';
				pmove_disp_latched <= (others => '0');
			ELSIF clkena_lw='1' THEN
				trapd <= trapmake;
				micro_state <= next_micro_state;

				assert NOT (exec(directPC) = '1' AND exec(ea_to_pc) = '1')
					report "INV5a: exec(directPC) and exec(ea_to_pc) both asserted"
					severity error;
				assert NOT (exec(pmmu_rd) = '1' AND exec(pmmu_wr) = '1')
					report "INV5b: exec(pmmu_rd) and exec(pmmu_wr) both asserted"
					severity error;

				if trap_mmu_config='1' and trapd='0' then
					pmmu_config_ack <= '1';
				else
					pmmu_config_ack <= '0';
				end if;
				if micro_state = ld_dAn1 and setdisp='1' and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and
				   (fline_opcode_latch(5 downto 3)="101" OR fline_opcode_latch(5 downto 3)="110") then
						pmove_disp_latched <= memaddr_a;
					end if;
				if (micro_state = ld_AnXn2 OR micro_state = pmmu_ld_AnXn2) and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and
				   fline_opcode_latch(5 downto 3)="110" and
				   (next_micro_state = pmove_mem_to_mmu_hi OR next_micro_state = pmove_mmu_to_mem_hi) then
					pmove_disp_latched <= addr;
				end if;
				if micro_state = pmmu_ld_nn and fline_context_valid = '1' and
				   fline_opcode_latch(15 downto 12)="1111" and
				   fline_opcode_latch(5 downto 3)="111" and fline_opcode_latch(2 downto 0)="001" then
					if nextpass = '0' then
						report "BUG387_LW: nextpass=0 last_opc_read=" & integer'image(conv_integer(last_opc_read)) & " data_read=" & integer'image(conv_integer(data_read(15 downto 0))) severity note;
						pmove_disp_latched <= last_opc_read & data_read(15 downto 0);
					else
						report "BUG387_LW: nextpass=1 last_opc_read=" & integer'image(conv_integer(last_opc_read)) & " data_read=" & integer'image(conv_integer(data_read(15 downto 0))) severity note;
					end if;
				end if;
			END IF;
		END IF;

		CASE micro_state IS

				WHEN ld_nn =>
					set(get_ea_now) <='1';
					set(addrlong) <= '1';
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
					   opcode(5 downto 3)="111" THEN
						setnextpass <= '0';
						setstate <= "01";
						ea_only <= '1';
						next_micro_state_c <= moves1;
					ELSE
						setnextpass <= '1';
					END IF;

				WHEN st_nn =>
					setstate <= "11";
					set(addrlong) <= '1';
					next_micro_state_c <= nop;

				WHEN ld_dAn1 =>
					set(get_ea_now) <='1';
					setdisp <= '1';
					setnextpass <= '1';
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND opcode(5 downto 3)="101" THEN
						setnextpass <= '0';
						setstate <= "01";
						ea_only <= '1';
						next_micro_state_c <= moves1;
					END IF;

					WHEN ld_AnXn1 =>
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state_c <= ld_AnXn2;
					ELSE
						IF brief(7)='1'THEN
							set_suppress_base <= '1';
						ELSIF exec(dispouter)='1' THEN
							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN
							setstate <= "01";
						ELSE
							IF brief(4)='1' THEN
								set(longaktion) <= '1';
							END IF;
						END IF;
						next_micro_state_c <= ld_229_1;
					END IF;

				WHEN ld_AnXn2 =>
					set(get_ea_now) <='1';
					setdisp <= '1';
					setnextpass <= '1';
					IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
					   opcode(5 downto 3)="110" THEN
						setnextpass <= '0';
						setstate <= "01";
						ea_only <= '1';
						next_micro_state_c <= moves1;
					END IF;

				WHEN ld_229_1 =>
					IF brief(5)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state_c <= ld_AnXn2;
						ELSE
							next_micro_state_c <= ld_229_2;
						END IF;
					ELSE
						IF brief(1 downto 0)="00" THEN
							set(get_ea_now) <='1';
							setnextpass <= '1';
							IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
							   opcode(5 downto 3)="110" THEN
								setnextpass <= '0';
								setstate <= "01";
								ea_only <= '1';
								next_micro_state_c <= moves1;
							END IF;
						ELSE
							setstate <= "10";
							setaddrvalue <= '1';
							set(longaktion) <= '1';
							next_micro_state_c <= ld_229_3;
						END IF;
					END IF;

				WHEN ld_229_2 =>
					setdisp <= '1';
					setstate <= "10";
					setaddrvalue <= '1';
					set(longaktion) <= '1';
					next_micro_state_c <= ld_229_3;

				WHEN ld_229_3 =>
					set_suppress_base <= '1';
					set(dispouter) <= '1';
					IF brief(1)='0' THEN
						setstate <= "01";
					ELSE
						IF brief(0)='1' THEN
							set(longaktion) <= '1';
						END IF;
					END IF;
					next_micro_state_c <= ld_229_4;

				WHEN ld_229_4 =>
					IF brief(1)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state_c <= ld_AnXn2;
					ELSE
						set(get_ea_now) <='1';
						setnextpass <= '1';

						IF opcode(15 downto 8)="00001110" AND opcode(7 downto 6)/="11" AND
						   opcode(5 downto 3)="110" THEN
							setnextpass <= '0';
							setstate <= "01";
							ea_only <= '1';
							next_micro_state_c <= moves1;
						END IF;
					END IF;

				WHEN pmmu_ld_nn =>
					IF nextpass='0' AND fline_opcode_latch(2 downto 0)="001" THEN
						setstate <= "00";
						setnextpass <= '1';
						next_micro_state_c <= pmmu_ld_nn;
					ELSE
						set(get_ea_now) <='1';
						set(addrlong) <= '1';
						setnextpass <= '0';
						IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
							set(OP1addr) <= '1';
							setstate <= "01";
							IF pmmu_brief(15 downto 13) = "100" THEN
								next_micro_state_c <= ptest1;
							ELSIF pmmu_brief(12 downto 10) = "000" THEN
								next_micro_state_c <= pload1;
							ELSE
								next_micro_state_c <= pflush1;
							END IF;
						ELSIF pmmu_brief(9)='1' THEN
							setstate <= "01";
							next_micro_state_c <= pmove_mmu_to_mem_hi;
						ELSE
							setstate <= "10";
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";
							ELSE
								datatype <= "10";
							END IF;
							set(longaktion) <= '1';
							next_micro_state_c <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;

				WHEN pmmu_ld_dAn1 =>
					set(get_ea_now) <='1';
					setdisp <= '1';
				IF fline_opcode_latch(2 downto 0)="111" THEN
					set(use_SP) <= '1';
				END IF;
					setnextpass <= '0';
					IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
						set(OP1addr) <= '1';
						setstate <= "01";
						IF pmmu_brief(15 downto 13) = "100" THEN
							next_micro_state_c <= ptest1;
						ELSIF pmmu_brief(12 downto 10) = "000" THEN
							next_micro_state_c <= pload1;
						ELSE
							next_micro_state_c <= pflush1;
						END IF;
					ELSIF pmmu_brief(9)='1' THEN
						setstate <= "01";
						next_micro_state_c <= pmove_mmu_to_mem_hi;
					ELSE
						set(OP1addr) <= '1';
						setstate <= "10";
						IF pmmu_brief(14 downto 10) = "11000" THEN
							datatype <= "01";
						ELSE
							datatype <= "10";
							set(longaktion) <= '1';
						END IF;
						next_micro_state_c <= pmove_mem_to_mmu_hi;
					END IF;

				WHEN pmmu_ld_AnXn1 =>
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state_c <= pmmu_ld_AnXn2;
					ELSE
						IF brief(7)='1'THEN
							set_suppress_base <= '1';
						ELSIF exec(dispouter)='1' THEN
							set(dispouter) <= '1';
						END IF;
						IF brief(5)='0' THEN
							setstate <= "01";
						ELSE
							IF brief(4)='1' THEN
								set(longaktion) <= '1';
							END IF;
						END IF;
						next_micro_state_c <= pmmu_ld_229_1;
					END IF;

				WHEN pmmu_ld_AnXn2 =>
					set(get_ea_now) <='1';
					setdisp <= '1';
					setnextpass <= '0';
					IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
						set(OP1addr) <= '1';
						setstate <= "01";
						IF pmmu_brief(15 downto 13) = "100" THEN
							next_micro_state_c <= ptest1;
						ELSIF pmmu_brief(12 downto 10) = "000" THEN
							next_micro_state_c <= pload1;
						ELSE
							next_micro_state_c <= pflush1;
						END IF;
					ELSIF pmmu_brief(9)='1' THEN
						setstate <= "01";
						next_micro_state_c <= pmove_mmu_to_mem_hi;
					ELSE
						setstate <= "10";
						IF pmmu_brief(14 downto 10) = "11000" THEN
							datatype <= "01";
						ELSE
							datatype <= "10";
							set(longaktion) <= '1';
						END IF;
						next_micro_state_c <= pmove_mem_to_mmu_hi;
					END IF;

				WHEN pmmu_ld_229_1 =>
					IF brief(5)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state_c <= pmmu_ld_AnXn2;
						ELSE
							next_micro_state_c <= pmmu_ld_229_2;
						END IF;
					ELSE
						IF brief(1 downto 0)="00" THEN
							set(get_ea_now) <='1';
							setnextpass <= '0';
							IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
								set(OP1addr) <= '1';
								setstate <= "01";
								IF pmmu_brief(15 downto 13) = "100" THEN
									next_micro_state_c <= ptest1;
								ELSIF pmmu_brief(12 downto 10) = "000" THEN
									next_micro_state_c <= pload1;
								ELSE
									next_micro_state_c <= pflush1;
								END IF;
							ELSIF pmmu_brief(9)='1' THEN
								setstate <= "01";
								next_micro_state_c <= pmove_mmu_to_mem_hi;
							ELSE
								setstate <= "10";
								IF pmmu_brief(14 downto 10) = "11000" THEN
									datatype <= "01";
								ELSE
									datatype <= "10";
								set(longaktion) <= '1';
								END IF;
								next_micro_state_c <= pmove_mem_to_mmu_hi;
							END IF;
						ELSE
							setstate <= "10";
							setaddrvalue <= '1';
							set(longaktion) <= '1';
							next_micro_state_c <= pmmu_ld_229_3;
						END IF;
					END IF;

				WHEN pmmu_ld_229_2 =>
					setdisp <= '1';
					setstate <= "10";
					setaddrvalue <= '1';
					set(longaktion) <= '1';
					next_micro_state_c <= pmmu_ld_229_3;

				WHEN pmmu_ld_229_3 =>
					set_suppress_base <= '1';
					set(dispouter) <= '1';
					IF brief(1)='0' THEN
						setstate <= "01";
					ELSE
						IF brief(0)='1' THEN
							set(longaktion) <= '1';
						END IF;
					END IF;
					next_micro_state_c <= pmmu_ld_229_4;

				WHEN pmmu_ld_229_4 =>
					IF brief(1)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state_c <= pmmu_ld_AnXn2;
					ELSE
						set(get_ea_now) <='1';
						setnextpass <= '0';
						IF pmmu_brief(15 downto 13) = "001" OR pmmu_brief(15 downto 13) = "100" THEN
							set(OP1addr) <= '1';
							setstate <= "01";
							IF pmmu_brief(15 downto 13) = "100" THEN
								next_micro_state_c <= ptest1;
							ELSIF pmmu_brief(12 downto 10) = "000" THEN
								next_micro_state_c <= pload1;
							ELSE
								next_micro_state_c <= pflush1;
							END IF;
						ELSIF pmmu_brief(9)='1' THEN
							setstate <= "01";
							next_micro_state_c <= pmove_mmu_to_mem_hi;
						ELSE
							setstate <= "10";
							IF pmmu_brief(14 downto 10) = "11000" THEN
								datatype <= "01";
							ELSE
							set(longaktion) <= '1';
								datatype <= "10";
							END IF;
							next_micro_state_c <= pmove_mem_to_mmu_hi;
						END IF;
					END IF;

				WHEN st_dAn1 =>
					setstate <= "11";
					setdisp <= '1';
					next_micro_state_c <= nop;

				WHEN st_AnXn1 =>
					IF brief(8)='0' OR extAddr_Mode=0 OR (cpu(1)='0' AND extAddr_Mode=2) THEN
						setdisp <= '1';
						setdispbyte <= '1';
						setstate <= "01";
						set(briefext) <= '1';
						next_micro_state_c <= st_AnXn2;
					ELSE
						IF brief(7)='1'THEN
							set_suppress_base <= '1';
						END IF;
						IF brief(5)='0' THEN
							setstate <= "01";
						ELSE
							IF brief(4)='1' THEN
								set(longaktion) <= '1';
							END IF;
						END IF;
						next_micro_state_c <= st_229_1;
					END IF;

				WHEN st_AnXn2 =>
					setstate <= "11";
					setdisp <= '1';
					set(hold_dwr) <= '1';
					next_micro_state_c <= nop;

				WHEN st_229_1 =>
					IF brief(5)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='0' THEN
						set(briefext) <= '1';
						setstate <= "01";
						IF brief(1 downto 0)="00" THEN
							next_micro_state_c <= st_AnXn2;
						ELSE
							next_micro_state_c <= st_229_2;
						END IF;
					ELSE
						IF brief(1 downto 0)="00" THEN
							setstate <= "11";
							next_micro_state_c <= nop;
						ELSE
							set(hold_dwr) <= '1';
							setstate <= "10";
							set(longaktion) <= '1';
							next_micro_state_c <= st_229_3;
						END IF;
					END IF;

				WHEN st_229_2 =>
					setdisp <= '1';
					set(hold_dwr) <= '1';
					setstate <= "10";
					set(longaktion) <= '1';
					next_micro_state_c <= st_229_3;

				WHEN st_229_3 =>
					set(hold_dwr) <= '1';
					set_suppress_base <= '1';
					set(dispouter) <= '1';
					IF brief(1)='0' THEN
						setstate <= "01";
					ELSE
						IF brief(0)='1' THEN
							set(longaktion) <= '1';
						END IF;
					END IF;
					next_micro_state_c <= st_229_4;

				WHEN st_229_4 =>
					set(hold_dwr) <= '1';
					IF brief(1)='1' THEN
						setdisp <= '1';
					END IF;
					IF brief(6)='0' AND brief(2)='1' THEN
						set(briefext) <= '1';
						setstate <= "01";
						next_micro_state_c <= st_AnXn2;
					ELSE
						setstate <= "11";
						next_micro_state_c <= nop;
					END IF;

				WHEN bra1 =>
					IF exe_condition='1' THEN
						TG68_PC_brw <= '1';
						next_micro_state_c <= nop;
						if long_start='0' then
							skipFetch <= '1';
						end if;
					END IF;

				WHEN bsr1 =>
					TG68_PC_brw <= '1';
					next_micro_state_c <= nop;

				WHEN bsr2 =>
					IF long_start='0' THEN
						TG68_PC_brw <= '1';
						skipFetch <= '1';
					END IF;
					set(longaktion) <= '1';
					writePC <= '1';
					setstate <= "11";
					next_micro_state_c <= nopnop;
					setstackaddr <='1';
				WHEN nopnop =>
					next_micro_state_c <= nop;

				WHEN dbcc1 =>
					IF exe_condition='0' THEN
						Regwrena_now <= '1';
						IF c_out(1)='1' THEN
							skipFetch <= '1';
							next_micro_state_c <= nop;
							TG68_PC_brw <= '1';
						ELSIF last_data_read(0)='1' THEN
							skipFetch <= '1';
							next_micro_state_c <= nop;
							TG68_PC_brw <= '1';
						END IF;
					END IF;

				WHEN chk20 =>
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state_c <= chk21;
				WHEN chk21 =>
					dest_2ndHbits <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";
						dest_LDRareg <= '1';
						IF opcode(10 downto 9)="00" THEN
							set(opcEXTB) <= '1';
						END IF;
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					setstate <="01";
					next_micro_state_c <= chk22;
				WHEN chk22 =>
					dest_2ndHbits <= '1';
					set(ea_data_OP2) <= '1';
					IF sndOPC(15)='1' THEN
						set_datatype <="10";
						dest_LDRareg <= '1';
					END IF;
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(opcCHK2) <= '1';
					IF sndOPC(11)='1' THEN
						setstate <="01";
						next_micro_state_c <= chk23;
					END IF;
				WHEN chk23 =>
						setstate <="01";
						next_micro_state_c <= chk24;
				WHEN chk24 =>
					IF Flags(0)='1'THEN
						trapmake <= '1';
					END IF;

				WHEN cas1 =>
						setstate <="01";
						next_micro_state_c <= cas2;
				WHEN cas2 =>
					source_2ndMbits <= '1';
					IF Flags(2)='1'THEN
						setstate<="11";
						set(write_reg) <= '1';
						set(restore_ADDR) <= '1';
						next_micro_state_c <= nop;
					ELSE
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						dest_2ndLbits <= '1';
						set(alu_move) <= '1';
					END IF;

				WHEN cas21 =>
					dest_2ndHbits <= '1';
					dest_LDRareg <= sndOPC(15);
					set(get_ea_now) <='1';
					next_micro_state_c <= cas22;
				WHEN cas22 =>
					setstate <= "01";
					source_2ndLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					set(alu_setFlags) <= '1';
					next_micro_state_c <= cas23;
				WHEN cas23 =>
					dest_LDRHbits <= '1';
					set(get_ea_now) <='1';
					next_micro_state_c <= cas24;
				WHEN cas24 =>
					IF Flags(2)='1'THEN
						set(alu_setFlags) <= '1';
					END IF;
					setstate <="01";
					set(hold_dwr) <= '1';
					source_LDRLbits <= '1';
					set(ea_data_OP1) <= '1';
					set(addsub) <= '1';
					set(alu_exec) <= '1';
					next_micro_state_c <= cas25;
				WHEN cas25 =>
					setstate <= "01";
					set(hold_dwr) <= '1';
					next_micro_state_c <= cas26;
				WHEN cas26 =>
					IF Flags(2)='1'THEN
						source_2ndMbits <= '1';
						set(write_reg) <= '1';
						dest_2ndHbits <= '1';
						dest_LDRareg <= sndOPC(15);
						setstate <= "11";
						set(get_ea_now) <='1';
						next_micro_state_c <= cas27;
					ELSE
						set(hold_dwr) <= '1';
						set(hold_OP2) <='1';
						dest_LDRLbits <= '1';
						set(alu_move) <= '1';
						set(Regwrena) <= '1';
						set(ea_data_OP2) <='1';
						next_micro_state_c <= cas28;
					END IF;
				WHEN cas27 =>
					source_LDRMbits <= '1';
					set(write_reg) <= '1';
					dest_LDRHbits <= '1';
					setstate <= "11";
					set(get_ea_now) <='1';
					next_micro_state_c <= nopnop;
				WHEN cas28 =>
					dest_2ndLbits <= '1';
					set(alu_move) <= '1';
					set(Regwrena) <= '1';

				WHEN movem1 =>
					IF last_data_read(15 downto 0)/=X"0000" THEN
						setstate <="01";
						IF opcode(5 downto 3)="100" THEN
							set(mem_addsub) <= '1';
							IF cpu(1)='1' THEN
								set(Regwrena) <= '1';
							END IF;
						END IF;
						next_micro_state_c <= movem2;
					END IF;
				WHEN movem2 =>
					IF movem_run='0' THEN
						setstate <="01";
					ELSE
						set(movem_action) <= '1';
						set(mem_addsub) <= '1';
						next_micro_state_c <= movem2;
						IF opcode(10)='0' THEN
							setstate <="11";
							set(write_reg) <= '1';
						ELSE
							setstate <="10";
						END IF;
					END IF;

				WHEN andi =>
					IF opcode(5 downto 4)/="00" THEN
						setnextpass <= '1';
					ELSIF state /= "00" THEN
						next_micro_state_c <= nop;
					END IF;

				WHEN pack1 =>
					IF opcode(2 downto 0)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';
					set(update_ld) <= '1';
					setstate <= "10";
					set(presub) <= '1';
					next_micro_state_c <= pack2;
					dest_areg <= '1';
				WHEN pack2 =>
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set(hold_ea_data) <= '1';
					set_direct_data <= '1';
					IF opcode(7 downto 6) = "01" THEN
						datatype <= "00";
					ELSE
						datatype <= "01";
					END IF;
					set(presub) <= '1';
					dest_hbits <= '1';
					dest_areg <= '1';
					setstate <= "10";
					next_micro_state_c <= pack3;
				WHEN pack3 =>
					skipFetch <= '1';

				WHEN op_AxAy =>
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(presub) <= '1';
					dest_hbits <= '1';
					dest_areg <= '1';
					setstate <= "10";

				WHEN cmpm =>
					IF opcode(11 downto 9)="111" THEN
						set(use_SP) <= '1';
					END IF;
					set_direct_data <= '1';
					set(postadd) <= '1';
					dest_hbits <= '1';
					dest_areg <= '1';
					setstate <= "10";

				WHEN link1 =>
					setstate <="11";
					source_areg <= '1';
					set(opcMOVE) <= '1';
					set(Regwrena) <= '1';
					next_micro_state_c <= link2;
				WHEN link2 =>
					setstackaddr <='1';
					set(ea_data_OP2) <= '1';

				WHEN unlink1 =>
					setstate <="10";
					setstackaddr <='1';
					set(postadd) <= '1';
					next_micro_state_c <= unlink2;
				WHEN unlink2 =>
					set(ea_data_OP2) <= '1';

				WHEN trace_stk_grp2 =>
					next_micro_state_c <= trap00;
					setstate <= "01";

				WHEN trap00 =>
					IF exec(changeMode)='1' THEN
						next_micro_state_c <= trap00;
						setstackaddr <= '1';
						setstate <= "01";
					ELSE
						next_micro_state_c <= trap0;
						set(presub) <= '1';
						setstackaddr <='1';
						setstate <= "11";
						datatype <= "10";
					END IF;
				WHEN trap0 =>
					IF exec(changeMode)='1' THEN
						next_micro_state_c <= trap0;
						setstackaddr <= '1';
						setstate <= "01";
					ELSE
						set(presub) <= '1';
						setstackaddr <='1';
						setstate <= "11";
						IF use_VBR_Stackframe='1' THEN
							set(writePC_add) <= '1';
							datatype <= "01";
							next_micro_state_c <= trap1;
						ELSE
							IF trap_interrupt='1' OR trap_trace='1' OR trap_berr='1' THEN
								writePC <= '1';
							END IF;
							datatype <= "10";
							next_micro_state_c <= trap2;
						END IF;
					END IF;

				WHEN trap1 =>
					IF trap_interrupt='1' OR trap_trace='1' THEN
						writePC <= '1';
					END IF;
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					next_micro_state_c <= trap2;
				WHEN trap2 =>
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					IF trap_berr='1' THEN
						next_micro_state_c <= trap4;
					ELSIF cpu(1)='1' AND trap_interrupt='1' AND trap_SR(4)='1' THEN
						next_micro_state_c <= int2;
					ELSE
						next_micro_state_c <= trap3;
					END IF;
				WHEN int2 =>
					set(to_MSP) <= '1';
					set(from_ISP) <= '1';
					set(Regwrena) <= '1';
					setstackaddr <= '1';
					setstate <= "01";
					next_micro_state_c <= int3;
				WHEN int3 =>
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";
					datatype <= "01";
					next_micro_state_c <= int4;
				WHEN int4 =>
					writePC <= '1';
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";
					datatype <= "10";
					next_micro_state_c <= int5;
				WHEN int5 =>
					set(presub) <= '1';
					setstackaddr <= '1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state_c <= trap3;

				WHEN trap3 =>
					set_vectoraddr <= '1';
					datatype <= "10";
					set(direct_delta) <= '1';
					set(directPC) <= '1';
					setstate <= "10";
					IF trace_pending_group2 = '1' THEN
						next_micro_state_c <= trace_stk_grp2;
					ELSE
						next_micro_state_c <= nopnop;
					END IF;

                WHEN berr_fill =>
                    IF exec(changeMode)='1' THEN
                        setstate <= "01";
                        setstackaddr <= '1';
                        next_micro_state_c <= berr_fill;
                        set_rot_cnt <= rot_cnt;
                    ELSE
                        setstate <= "11";
                        set(presub) <= '1';
                        set(longaktion) <= '1';
                        setstackaddr <= '1';
                        datatype <= "10";
                        IF rot_cnt = "000001" THEN
                            next_micro_state_c <= berr1;
                        ELSE
                            next_micro_state_c <= berr_fill;
                        END IF;
                    END IF;

                WHEN berr1 =>
                    IF exec(changeMode)='1' THEN
                        setstate <= "01";
                        setstackaddr <= '1';
                        next_micro_state_c <= berr1;
                    ELSE
                        setstate <= "11";
                        set(presub) <= '1';
                        set(longaktion) <= '1';
                        setstackaddr <= '1';
                        datatype <= "10";
                        next_micro_state_c <= berr2;
                    END IF;
                WHEN berr2 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr3;
                WHEN berr3 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr4;
                WHEN berr4 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr5;
                WHEN berr5 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr6;
                WHEN berr6 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr7;
                WHEN berr7 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= berr8;
                WHEN berr8 =>
                    setstate <= "11";
                    set(presub) <= '1';
                    set(longaktion) <= '1';
                    setstackaddr <= '1';
                    datatype <= "10";
                    next_micro_state_c <= trap3;

				WHEN trap4 =>
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state_c <= trap5;
				WHEN trap5 =>
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "10";
					writeSR <= '1';
					next_micro_state_c <= trap6;
				WHEN trap6 =>
					set(presub) <= '1';
					setstackaddr <='1';
					setstate <= "11";
					datatype <= "01";
					writeSR <= '1';
					next_micro_state_c <= trap3;

				WHEN rte1 =>
					datatype <= "10";
					setstate <= "10";
					set(postadd) <= '1';
					setstackaddr <= '1';
					set(directPC) <= '1';
					IF use_VBR_Stackframe='0' OR opcode(2)='1' THEN
						set(update_FC) <= '1';
						set(direct_delta) <= '1';
					END IF;
					next_micro_state_c <= rte2;
				WHEN rte2 =>
					datatype <= "01";
					set(update_FC) <= '1';
					IF use_VBR_Stackframe='1' AND opcode(2)='0' THEN
						setstate <= "10";
						set(postadd) <= '1';
						setstackaddr <= '1';
						next_micro_state_c <= rte3;
					ELSE
						next_micro_state_c <= nop;
					END IF;
				when rte3 =>
					setstate <= "01";
					next_micro_state_c <= rte4;
				WHEN rte4 =>
					CASE rte_format_word(15 downto 12) IS
						WHEN "0001" =>
							IF cpu(1)='1' THEN
								IF FlagsSR(4)='1' THEN
									set(to_ISP) <= '1';
									set(from_MSP) <= '1';
									set(Regwrena) <= '1';
								END IF;
								setstackaddr <= '1';
								setstate <= "01";
								next_micro_state_c <= rte6;
							ELSE
								datatype <= "01";
								next_micro_state_c <= nop;
							END IF;
						WHEN "0000" =>
							datatype <= "01";
							next_micro_state_c <= nop;
							IF format1_chain_active='1' THEN
								set(to_MSP) <= '1';
								IF FlagsSR(4)='0' THEN
									set(from_ISP) <= '1';
								END IF;
								set(Regwrena) <= '1';
								setstackaddr <= '1';
								setstate <= "01";
							ELSIF cpu(1)='1' AND FlagsSR(5)='1' AND FlagsSR(4) /= rte_saved_mbit THEN
								setstackaddr <= '1';
								set(Regwrena) <= '1';
								IF FlagsSR(4) = '1' THEN
									set(to_ISP) <= '1';
									set(from_MSP) <= '1';
								ELSE
									set(to_MSP) <= '1';
									set(from_ISP) <= '1';
								END IF;
								END IF;
								IF FlagsSR(5)='0' THEN
									interrupt_mode_clr_req <= '1';
								END IF;
						WHEN "0010" =>
							setstate <= "10";
							datatype <= "10";
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000001";
							next_micro_state_c <= rte5;
						WHEN "1001" =>
							setstate <= "10";
							datatype <= "10";
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000011";
							next_micro_state_c <= rte5;
						WHEN "1010" =>
							setstate <= "10";
							datatype <= "10";
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "000110";
							next_micro_state_c <= rte5;
						WHEN "1011" =>
							setstate <= "10";
							datatype <= "10";
							set(postadd) <= '1';
							setstackaddr <= '1';
							set_rot_cnt <= "010101";
							next_micro_state_c <= rte5;
						WHEN OTHERS =>
							setstate <= "01";
							trap_format_error <= '1';
							trapmake <= '1';
					END CASE;
				WHEN rte5 =>
					IF rot_cnt = "000001" THEN
						IF rte_fmt_a_replay_needed = '1' THEN
							setstate <= "11";
							datatype <= rte_fmt_a_replay_size;
							set_datatype <= rte_fmt_a_replay_size;
							IF rte_fmt_a_replay_size = "10" THEN
								set(longaktion) <= '1';
							END IF;
							next_micro_state_c <= rte_mmu_replay;
						ELSIF rte_format_word(15 downto 12) = "1001" AND cp_rte_iw(15 downto 12) = "1111" THEN
							setstate <= "01";
							next_micro_state_c <= cp_rte;
						ELSIF rte_format_word(15 downto 12) = "1011" AND cp_rb(31 downto 28) = "1100" THEN
							setstate <= "01";
							next_micro_state_c <= cp_rsm;
						ELSE
							next_micro_state_c <= nop;
						END IF;
						IF format1_chain_active='1' THEN
							set(to_MSP) <= '1';
							IF FlagsSR(4)='0' THEN
								set(from_ISP) <= '1';
							END IF;
							set(Regwrena) <= '1';
							setstackaddr <= '1';
							setstate <= "01";
						ELSIF cpu(1)='1' AND FlagsSR(5)='1' AND FlagsSR(4) /= rte_saved_mbit THEN
							setstackaddr <= '1';
							set(Regwrena) <= '1';
							IF FlagsSR(4) = '1' THEN
								set(to_ISP) <= '1';
								set(from_MSP) <= '1';
							ELSE
								set(to_MSP) <= '1';
								set(from_ISP) <= '1';
							END IF;
							END IF;
							IF FlagsSR(5)='0' THEN
								interrupt_mode_clr_req <= '1';
							END IF;
					ELSE
						setstate <= "10";
						datatype <= "10";
						set(postadd) <= '1';
						setstackaddr <= '1';
							next_micro_state_c <= rte5;
						END IF;

					WHEN rte_mmu_replay =>
						datatype <= rte_fmt_a_replay_size;
						set_datatype <= rte_fmt_a_replay_size;
						next_micro_state_c <= rte_mmu_replay_sync;

					WHEN rte_mmu_replay_sync =>
						next_micro_state_c <= idle;

					WHEN rte6 =>
					setstate <= "10";
					set(postadd) <= '1';
					setstackaddr <= '1';
					set(directSR) <= '1';
					datatype <= "01";
					next_micro_state_c <= rte1;

				WHEN rtd1 =>
					next_micro_state_c <= rtd2;
				WHEN rtd2 =>
					setstackaddr <= '1';
					set(Regwrena) <= '1';

				WHEN movec1 =>
					set(briefext) <= '1';
					set_writePCbig <='1';
					IF movec_regsel=X"800" THEN
						set(from_USP) <= '1';
						IF opcode(0)='1' THEN
							set(to_USP) <= '1';
						END IF;
					ELSIF cpu(1)='1' THEN
						CASE movec_regsel IS
							WHEN X"803" =>
								IF opcode(0)='1' THEN
									set(to_MSP) <= '1';
								END IF;
							WHEN X"804" =>
								IF opcode(0)='1' THEN
									set(to_ISP) <= '1';
								END IF;
							WHEN OTHERS =>
								NULL;
						END CASE;
					END IF;
					IF (movec_regsel=X"000" OR movec_regsel=X"001" OR movec_regsel=X"800" OR movec_regsel=X"801") OR
					   (cpu(1)='1' AND (movec_regsel=X"002" OR movec_regsel=X"802" OR movec_regsel=X"803" OR movec_regsel=X"804")) THEN
						IF opcode(0)='0' THEN
							set(Regwrena) <= '1';
						END IF;
						setstate <= "00";
					ELSE
						trap_illegal <= '1';
						trapmake <= '1';
					END IF;

					WHEN moves0 =>
					source_lowbits <= '1';
					IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
						source_areg <= '1';
					END IF;
					IF opcode(5 downto 3)="100" THEN
						set(subidx) <= '1';
					END IF;
					datatype <= opcode(7 downto 6);
					set_datatype <= opcode(7 downto 6);
					set(no_Flags) <= '1';
					set(use_sfc_dfc) <= '1';
						IF brief(11)='0' THEN
							set(sfc_not_dfc) <= '1';

						END IF;
						IF opcode(5 downto 3)="101" THEN
							setstate <= "01";
							next_micro_state_c <= ld_dAn1;
						ELSIF opcode(5 downto 3)="110" THEN
							getbrief <= '1';
							setstate <= "01";
							next_micro_state_c <= ld_AnXn1;
						ELSIF opcode(5 downto 3)="111" THEN
							IF opcode(2 downto 0)="001" THEN
								NULL;
							ELSE
								setstate <= "01";
							END IF;
							next_micro_state_c <= ld_nn;
						ELSE
							setstate <= "01";
							next_micro_state_c <= moves1;
						END IF;

				WHEN moves1 =>
					datatype <= opcode(7 downto 6);
					set_datatype <= opcode(7 downto 6);
					set(briefext) <= '1';
					set(use_sfc_dfc) <= '1';
					set(no_Flags) <= '1';
					source_lowbits <= '1';
					IF opcode(5 downto 3)="010" OR opcode(5 downto 3)="011" OR opcode(5 downto 3)="100" THEN
						source_areg <= '1';
					END IF;
					IF opcode(5 downto 3)="011" THEN
						set(postadd) <= '1';
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;
					IF opcode(5 downto 3)="100" THEN
						set(presub) <= '1';
						set(addsub) <= '1';
						IF opcode(2 downto 0)="111" THEN
							set(use_SP) <= '1';
						END IF;
					END IF;
					IF opcode(5 downto 3)="101" OR opcode(5 downto 3)="110" OR opcode(5 downto 3)="111" THEN
						next_micro_state_c <= nopnop;
					ELSE
						next_micro_state_c <= nop;
					END IF;
					IF moves_direction='1' THEN
						setstate <= "11";
						set(write_reg) <= '1';
						ELSE
							setstate <= "10";
							set(sfc_not_dfc) <= '1';
							set(no_Flags) <= '1';
						END IF;

                WHEN cp_decode =>
                    setstate <= "01";
                    IF fline_context_valid = '0' THEN
                        next_micro_state_c <= cp_decode;
                    ELSIF fline_opcode_latch(8 downto 6) = "100" THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00100";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_fmtw;
                    ELSIF fline_opcode_latch(8 downto 6) = "101" THEN
                        next_micro_state_c <= cp_eat;
                    ELSE
                        cp_cir_next <= '1';
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "11";
                        IF fline_opcode_latch(8 downto 6) = "000" THEN
                            cp_cir_off <= "01010";
                            cp_wdata <= x"0000" & pmmu_brief;
                        ELSIF fline_opcode_latch(8 downto 6) = "001" THEN
                            cp_cir_off <= "01110";
                            cp_wdata <= x"0000" & pmmu_brief;
                        ELSE
                            cp_cir_off <= "01110";
                            cp_wdata <= x"0000" & fline_opcode_latch;
                        END IF;
                        next_micro_state_c <= cp_rsp;
                    END IF;

                WHEN cp_rsp =>
                    IF cp_nocp = '1' THEN
                        setstate <= "01";
                        trap_1111 <= '1';
                        trapmake <= '1';
                    ELSE
                        cp_cir_next <= '1';
                        cp_cir_off <= "00000";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_rspw;
                    END IF;

                WHEN cp_rspw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_dsp;

                WHEN cp_dsp =>
                    setstate <= "01";
                    IF cp_prim(14) = '1' AND cp_pcdone = '0' THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "11000";
                        cp_wdata <= opcode_pc;
                        datatype <= "10";
                        set_datatype <= "10";
                        setstate <= "11";
                        next_micro_state_c <= cp_pcw;
                    ELSIF cp_prim(13 downto 9) = "00100" THEN
                        IF cp_irq_take = '1' THEN
                            next_micro_state_c <= cp_irq;
                        ELSIF cp_prim(15) = '1' OR cp_twait = '1' THEN
                            cp_cir_next <= '1';
                            cp_cir_off <= "00000";
                            datatype <= "01";
                            set_datatype <= "01";
                            setstate <= "10";
                            next_micro_state_c <= cp_rspw;
                        ELSIF fline_opcode_latch(8 downto 6) = "000" THEN
                            next_micro_state_c <= cp_done;
                        ELSE
                            next_micro_state_c <= cp_cond;
                        END IF;
                    ELSIF fline_opcode_latch(8 downto 6) = "000" AND
                          (cp_prim(12 downto 11) = "10" OR cp_prim(12 downto 8) = "00001") THEN
                        next_micro_state_c <= cp_eat;
                    ELSIF cp_prim(12 downto 8) = "01100" AND cp_prim(13) = '0' AND
                          (fline_opcode_latch(8 downto 6) = "000" OR cp_prim(15) = '1') THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "10000";
                        cp_wdata <= regfile(conv_integer(cp_prim(3 downto 0)));
                        datatype <= "10";
                        set_datatype <= "10";
                        setstate <= "11";
                        next_micro_state_c <= cp_tsr;
                    ELSIF cp_prim(13 downto 9) = "01110" THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00010";
                        cp_wdata <= x"00000002";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "11";
                        next_micro_state_c <= cp_xa;
                    ELSE
                        trap_cp9 <= '1';
                        trap_cppv <= '1';
                        trapmake <= '1';
                    END IF;

                WHEN cp_tsr =>
                    IF cp_prim(15) = '1' THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00000";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_rspw;
                    ELSE
                        setstate <= "01";
                        next_micro_state_c <= cp_done;
                    END IF;

                WHEN cp_eat =>
                    setstate <= "01";
                    IF cp_ss = '1' THEN
                        IF fline_opcode_latch(5 downto 3) = "100" THEN
                            next_micro_state_c <= cp_prea;
                        ELSIF fline_opcode_latch(5 downto 3) = "010" OR fline_opcode_latch(5 downto 3) = "011" THEN
                            next_micro_state_c <= cp_ssea;
                        ELSE
                            next_micro_state_c <= cp_ea1;
                        END IF;
                    ELSIF cp_scc = '1' THEN
                        IF fline_opcode_latch(5 downto 3) = "000" THEN
                            next_micro_state_c <= cp_sccd;
                        ELSIF fline_opcode_latch(5 downto 3) = "010" OR fline_opcode_latch(5 downto 3) = "011" THEN
                            next_micro_state_c <= cp_xfr;
                        ELSIF fline_opcode_latch(5 downto 3) = "100" THEN
                            next_micro_state_c <= cp_prea;
                        ELSE
                            setstate <= "00";
                            next_micro_state_c <= cp_extw;
                        END IF;
                    ELSIF cp_ea_ok = '0' THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00010";
                        cp_wdata <= x"00000001";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "11";
                        next_micro_state_c <= cp_abf;
                    ELSIF cp_pv = '1' THEN
                        trap_cp9 <= '1';
                        trap_cppv <= '1';
                        trapmake <= '1';
                    ELSIF fline_opcode_latch(5 downto 4) = "00" THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "10000";
                        cp_wdata <= regfile(conv_integer(fline_opcode_latch(3 downto 0)));
                        datatype <= cp_psize0;
                        set_datatype <= cp_psize0;
                        IF cp_prim(13) = '0' THEN
                            setstate <= "11";
                            next_micro_state_c <= cp_oww;
                        ELSE
                            setstate <= "10";
                            next_micro_state_c <= cp_rdreg;
                        END IF;
                    ELSIF fline_opcode_latch(5 downto 3) = "010" OR fline_opcode_latch(5 downto 3) = "011" THEN
                        IF cp_prim(12 downto 8) = "00001" THEN
                            next_micro_state_c <= cp_rsel;
                        ELSE
                            next_micro_state_c <= cp_xfr;
                        END IF;
                    ELSIF fline_opcode_latch(5 downto 3) = "100" THEN
                        IF cp_prim(12 downto 8) = "00001" THEN
                            next_micro_state_c <= cp_rsel;
                        ELSE
                            next_micro_state_c <= cp_prea;
                        END IF;
                    ELSIF fline_opcode_latch(5 downto 0) = "111100" THEN
                        next_micro_state_c <= cp_xfr;
                    ELSE
                        setstate <= "00";
                        next_micro_state_c <= cp_extw;
                    END IF;

                WHEN cp_abf =>
                    trap_1111 <= '1';
                    trapmake <= '1';

                WHEN cp_prea =>
                    setstate <= "01";
                    IF cp_ss = '1' THEN
                        next_micro_state_c <= cp_ssea;
                    ELSE
                        next_micro_state_c <= cp_xfr;
                    END IF;

                WHEN cp_extw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_ea1;

                WHEN cp_ea1 =>
                    setstate <= "01";
                    IF fline_opcode_latch(5 downto 0) = "111001" THEN
                        setstate <= "00";
                        next_micro_state_c <= cp_extw2;
                    ELSIF (fline_opcode_latch(5 downto 3) = "110" OR fline_opcode_latch(5 downto 0) = "111011") AND
                          cp_w(8) = '1' THEN
                        IF cp_ss = '1' AND fline_opcode_latch(6) = '0' THEN
                            cp_cir_next <= '1';
                            cp_cir_off <= "00010";
                            cp_wdata <= x"00000001";
                            datatype <= "01";
                            set_datatype <= "01";
                            setstate <= "11";
                            next_micro_state_c <= cp_abf;
                        ELSE
                            trap_1111 <= '1';
                            trapmake <= '1';
                        END IF;
                    ELSIF cp_ss = '1' THEN
                        next_micro_state_c <= cp_ssea;
                    ELSIF cp_prim(12 downto 8) = "00001" THEN
                        next_micro_state_c <= cp_rsel;
                    ELSE
                        next_micro_state_c <= cp_xfr;
                    END IF;

                WHEN cp_extw2 =>
                    setstate <= "01";
                    IF cp_ss = '1' THEN
                        next_micro_state_c <= cp_ssea;
                    ELSIF cp_prim(12 downto 8) = "00001" THEN
                        next_micro_state_c <= cp_rsel;
                    ELSE
                        next_micro_state_c <= cp_xfr;
                    END IF;

                WHEN cp_xfr =>
                    setstate <= "01";
                    IF cp_len = x"00" THEN
                        next_micro_state_c <= cp_fin;
                    ELSIF fline_opcode_latch(5 downto 0) = "111100" THEN
                        setstate <= "00";
                        next_micro_state_c <= cp_imw;
                    ELSIF cp_scc = '1' THEN
                        cp_mem_next <= '1';
                        cp_wdata <= (others => cp_prim(0));
                        datatype <= "00";
                        set_datatype <= "00";
                        setstate <= "11";
                        next_micro_state_c <= cp_mww;
                    ELSIF cp_frcp = '0' THEN
                        cp_mem_next <= '1';
                        datatype <= cp_psize;
                        set_datatype <= cp_psize;
                        setstate <= "10";
                        next_micro_state_c <= cp_mrdw;
                    ELSE
                        cp_cir_next <= '1';
                        cp_cir_off <= "10000";
                        datatype <= cp_psize;
                        set_datatype <= cp_psize;
                        setstate <= "10";
                        next_micro_state_c <= cp_ordw;
                    END IF;

                WHEN cp_mrdw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_ow;

                WHEN cp_ow =>
                    cp_cir_next <= '1';
                    cp_cir_off <= "10000";
                    cp_wdata <= cp_data;
                    datatype <= cp_psize;
                    set_datatype <= cp_psize;
                    setstate <= "11";
                    next_micro_state_c <= cp_oww;

                WHEN cp_oww =>
                    setstate <= "01";
                    next_micro_state_c <= cp_xfr;

                WHEN cp_ordw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_mw;

                WHEN cp_mw =>
                    cp_mem_next <= '1';
                    cp_wdata <= cp_data;
                    datatype <= cp_psize;
                    set_datatype <= cp_psize;
                    setstate <= "11";
                    next_micro_state_c <= cp_mww;

                WHEN cp_mww =>
                    setstate <= "01";
                    next_micro_state_c <= cp_xfr;

                WHEN cp_rdreg =>
                    setstate <= "01";
                    next_micro_state_c <= cp_fin;

                WHEN cp_imw =>
                    setstate <= "01";
                    IF cp_part = "100" AND cp_half = '0' THEN
                        setstate <= "00";
                        next_micro_state_c <= cp_imw;
                    ELSE
                        next_micro_state_c <= cp_ow;
                    END IF;

                WHEN cp_rsel =>
                    cp_cir_next <= '1';
                    cp_cir_off <= "10100";
                    datatype <= "01";
                    set_datatype <= "01";
                    setstate <= "10";
                    next_micro_state_c <= cp_rselw;

                WHEN cp_rselw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_mmreg;

                WHEN cp_mmreg =>
                    setstate <= "01";
                    IF cp_mmcnt = "0000" THEN
                        next_micro_state_c <= cp_fin;
                    ELSE
                        next_micro_state_c <= cp_xfr;
                    END IF;

                WHEN cp_fin =>
                    setstate <= "01";
                    IF cp_mm = '1' AND cp_mmcnt /= "0000" THEN
                        next_micro_state_c <= cp_mmreg;
                    ELSIF cp_ss = '1' AND (fline_opcode_latch(5 downto 4) = "01" OR
                                           fline_opcode_latch(5 downto 3) = "100") THEN
                        next_micro_state_c <= cp_bcc;
                    ELSIF cp_ss = '1' THEN
                        next_micro_state_c <= cp_done;
                    ELSIF cp_prim(15) = '1' THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00000";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_rspw;
                    ELSE
                        next_micro_state_c <= cp_done;
                    END IF;

                WHEN cp_pcw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_dsp;

                WHEN cp_xa =>
                    trap_cp <= '1';
                    IF cp_prim(8) = '1' THEN
                        trap_cp9 <= '1';
                    END IF;
                    trapmake <= '1';

                WHEN cp_bcc =>
                    cp_br_sel <= '1';
                    IF cp_ss = '1' THEN
                        NULL;
                    ELSIF fline_opcode_latch(8 downto 6) = "011" THEN
                        cp_br_disp <= pmmu_brief & cp_w;
                    ELSIF fline_opcode_latch(8 downto 6) = "001" THEN
                        cp_br_disp <= ((31 downto 16 => cp_w(15)) & cp_w) + 2;
                    ELSE
                        cp_br_disp(31 downto 16) <= (others => pmmu_brief(15));
                        cp_br_disp(15 downto 0) <= pmmu_brief;
                    END IF;
                    skipFetch <= '1';
                    TG68_PC_brw <= '1';
                    setstate <= "00";
                    next_micro_state_c <= nop;

                WHEN cp_done =>
                    setstate <= "00";
                    next_micro_state_c <= nop;

                WHEN cp_fmtw =>
                    setstate <= "01";
                    IF cp_nocp = '1' THEN
                        trap_1111 <= '1';
                        trapmake <= '1';
                    ELSE
                        next_micro_state_c <= cp_fmt;
                    END IF;

                WHEN cp_fmt =>
                    setstate <= "01";
                    IF cp_irq_take = '1' THEN
                        next_micro_state_c <= cp_irq;
                    ELSIF cp_prim(15 downto 8) = x"01" THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "001" & fline_opcode_latch(6) & '0';
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_fmtw;
                    ELSIF (cp_prim(15 downto 12) = "0000" AND cp_prim(11 downto 8) /= "0000") OR cp_badlen = '1' THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00010";
                        cp_wdata <= x"00000001";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "11";
                        next_micro_state_c <= cp_ferr;
                    ELSIF fline_opcode_latch(6) = '0' THEN
                        next_micro_state_c <= cp_eat;
                    ELSIF cp_prim(15 downto 8) = x"00" THEN
                        next_micro_state_c <= cp_fin;
                    ELSE
                        next_micro_state_c <= cp_xfr;
                    END IF;

                WHEN cp_ferr =>
                    trap_cp <= '1';
                    trap_cpfmt <= '1';
                    trapmake <= '1';

                WHEN cp_ssea =>
                    cp_mem_next <= '1';
                    datatype <= "10";
                    set_datatype <= "10";
                    IF fline_opcode_latch(6) = '0' THEN
                        cp_wdata <= cp_prim & x"0000";
                        setstate <= "11";
                        next_micro_state_c <= cp_sfw;
                    ELSE
                        setstate <= "10";
                        next_micro_state_c <= cp_rfr;
                    END IF;

                WHEN cp_sfw =>
                    setstate <= "01";
                    next_micro_state_c <= cp_xfr;

                WHEN cp_rfr =>
                    setstate <= "01";
                    next_micro_state_c <= cp_rfw;

                WHEN cp_rfw =>
                    cp_cir_next <= '1';
                    cp_cir_off <= "00110";
                    cp_wdata <= x"0000" & cp_data(31 downto 16);
                    datatype <= "01";
                    set_datatype <= "01";
                    setstate <= "11";
                    next_micro_state_c <= cp_rfww;

                WHEN cp_rfww =>
                    IF cp_nocp = '1' THEN
                        setstate <= "01";
                        trap_1111 <= '1';
                        trapmake <= '1';
                    ELSE
                        cp_cir_next <= '1';
                        cp_cir_off <= "00110";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_fmtw;
                    END IF;

                WHEN cp_cond =>
                    setstate <= "01";
                    IF fline_opcode_latch(8 downto 6) = "010" THEN
                        IF cp_prim(0) = '1' THEN
                            next_micro_state_c <= cp_bcc;
                        ELSE
                            next_micro_state_c <= cp_done;
                        END IF;
                    ELSIF fline_opcode_latch(8 downto 6) = "011" OR fline_opcode_latch(5 downto 3) = "001" THEN
                        setstate <= "00";
                        next_micro_state_c <= cp_dlw;
                    ELSIF cp_scc = '1' THEN
                        next_micro_state_c <= cp_eat;
                    ELSIF fline_opcode_latch(2 downto 0) = "100" THEN
                        next_micro_state_c <= cp_trp;
                    ELSE
                        setstate <= "00";
                        next_micro_state_c <= cp_tsk;
                    END IF;

                WHEN cp_dlw =>
                    setstate <= "01";
                    IF fline_opcode_latch(8 downto 6) = "011" THEN
                        IF cp_prim(0) = '1' THEN
                            next_micro_state_c <= cp_bcc;
                        ELSE
                            next_micro_state_c <= cp_done;
                        END IF;
                    ELSIF cp_prim(0) = '1' THEN
                        next_micro_state_c <= cp_done;
                    ELSE
                        next_micro_state_c <= cp_db;
                    END IF;

                WHEN cp_db =>
                    setstate <= "01";
                    IF regfile(conv_integer('0' & fline_opcode_latch(2 downto 0)))(15 downto 0) = x"0000" THEN
                        next_micro_state_c <= cp_done;
                    ELSE
                        next_micro_state_c <= cp_bcc;
                    END IF;

                WHEN cp_tsk =>
                    setstate <= "01";
                    IF fline_opcode_latch(2 downto 0) = "011" AND cp_half = '0' THEN
                        setstate <= "00";
                        next_micro_state_c <= cp_tsk;
                    ELSE
                        next_micro_state_c <= cp_trp;
                    END IF;

                WHEN cp_trp =>
                    setstate <= "01";
                    IF cp_prim(0) = '1' THEN
                        trap_cptrap <= '1';
                        trapmake <= '1';
                    ELSE
                        next_micro_state_c <= cp_done;
                    END IF;

                WHEN cp_sccd =>
                    setstate <= "01";
                    next_micro_state_c <= cp_done;

                WHEN cp9a =>
                    IF exec(changeMode) = '1' THEN
                        next_micro_state_c <= cp9a;
                        setstackaddr <= '1';
                        setstate <= "01";
                    ELSE
                        set(presub) <= '1';
                        setstackaddr <= '1';
                        setstate <= "11";
                        datatype <= "10";
                        next_micro_state_c <= cp9b;
                    END IF;

                WHEN cp9b =>
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    setstate <= "11";
                    datatype <= "10";
                    next_micro_state_c <= cp9c;

                WHEN cp9c =>
                    set(presub) <= '1';
                    setstackaddr <= '1';
                    setstate <= "11";
                    datatype <= "10";
                    next_micro_state_c <= trap0;

                WHEN cp_rte =>
                    setstate <= "01";
                    next_micro_state_c <= cp_rtef;

                WHEN cp_rtef =>
                    IF fline_opcode_latch(8 downto 7) = "01" THEN
                        setstate <= "00";
                    ELSE
                        setstate <= "01";
                    END IF;
                    next_micro_state_c <= cp_rsp;

                WHEN cp_irq =>
                    IF interrupt = '1' AND trap_interrupt = '1' THEN
                        NULL;
                    ELSIF fline_opcode_latch(8 downto 6) = "100" THEN
                        cp_cir_next <= '1';
                        cp_cir_off <= "00100";
                        datatype <= "01";
                        set_datatype <= "01";
                        setstate <= "10";
                        next_micro_state_c <= cp_fmtw;
                    ELSE
                        setstate <= "01";
                        next_micro_state_c <= cp_rsp;
                    END IF;

                WHEN cp_bf =>
                    IF interrupt = '1' AND (trap_berr = '1' OR trap_mmu_berr = '1') THEN
                        NULL;
                    ELSE
                        setstate <= "01";
                        next_micro_state_c <= cp_bf;
                    END IF;

                WHEN cp_rsm =>
                    setstate <= "01";
                    next_micro_state_c <= cp_rsm2;

                WHEN cp_rsm2 =>
                    cp_cir_next <= cp_bk_cir;
                    cp_mem_next <= cp_bk_mem;
                    cp_cir_off <= cp_bk_off;
                    cp_wdata <= cp_bk_wd;
                    datatype <= cp_bk_dt;
                    set_datatype <= cp_bk_dt;
                    setstate <= cp_bk_ss;
                    next_micro_state_c <= cp_st_dec(cp_bk_st);

                WHEN pmove_decode =>
                    setstate <= "01";
                    set(update_FC) <= '1';

                    IF fline_context_valid = '0' THEN
                        next_micro_state_c <= pmove_decode;
                    ELSIF (pmmu_brief(15 downto 13) = "000" AND (pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011")) OR
                        (pmmu_brief(15 downto 13) = "010" AND (pmmu_brief(14 downto 10) = "10000" OR pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011")) OR
                        (pmmu_brief(15 downto 13) = "011" AND pmmu_brief(14 downto 10) = "11000" ) THEN

                        IF pmmu_brief(7 downto 0) /= "00000000" OR
                           (pmmu_brief(9) = '1' AND pmmu_brief(8) = '1') OR
                           (pmmu_brief(14 downto 10) = "11000" AND pmmu_brief(8) = '1') THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
		                        ELSIF (pmmu_opcode(5 downto 3)="000") OR
		                              (pmmu_opcode(5 downto 3)="001") OR
		                              (pmmu_opcode(5 downto 3)="011") OR
		                              (pmmu_opcode(5 downto 3)="100") OR
		                              (pmmu_opcode(5 downto 3)="111" and pmmu_opcode(2)='1') OR
		                              (pmmu_opcode(5 downto 3)="111" and pmmu_opcode(2 downto 1)="01") THEN
		                             trap_1111 <= '1';
		                             trapmake <= '1';
		                        ELSE
	                             set(ea_build) <= '1';
                             IF pmmu_brief(14 downto 10) = "11000" THEN
                                 datatype <= "01";
                             ELSE
                                 datatype <= "10";
                             END IF;

                             CASE pmmu_opcode(5 downto 3) IS
	                                    WHEN "000" =>
	                                        set(ea_build) <= '0';
	                                        IF pmmu_brief(14 downto 10) = "11000" THEN
	                                            datatype <= "01";
	                                            set_datatype <= "01";
	                                        ELSE
	                                            datatype <= "10";
	                                            set_datatype <= "10";
	                                        END IF;
	                                        IF pmmu_brief(9)='1' THEN
	                                            set(pmmu_rd) <= '1';
	                                            set(Regwrena) <= '1';
	                                            setstate <= "01";
	                                            next_micro_state_c <= pmmu_dn_read_wait;
	                                        ELSE
	                                            set_exec(pmmu_wr) <= '1';
	                                            setstate <= "01";
	                                            next_micro_state_c <= idle;
	                                        END IF;
	                                    WHEN "010" =>
                                        set(ea_build) <= '0';
                                        IF pmmu_brief(9)='1' THEN
                                            set_exec(pmmu_rd) <= '1';
                                            set(OP1addr) <= '1';
                                            IF pmmu_opcode(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
                                                    set(pmmu_dbl) <= '1';
                                                END IF;
                                            END IF;
                                            IF pmmu_opcode(2 downto 0)="111" THEN set(use_SP)<='1'; END IF;
                                            setstate <= "01";
                                            next_micro_state_c <= pmove_mmu_to_mem_hi;
                                        ELSE
                                            set(ea_data_OP1) <= '1';
                                            IF pmmu_opcode(5 downto 3)="100" THEN
                                                set(presub) <= '1';
                                                IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
                                                    set(pmmu_dbl) <= '1';
                                                END IF;
                                            END IF;
                                            IF pmmu_opcode(2 downto 0)="111" THEN set(use_SP)<='1'; END IF;
                                            IF pmmu_brief(14 downto 10) /= "11000" THEN
                                                set(longaktion) <= '1';
                                            END IF;
                                            setstate <= "10";
                                            next_micro_state_c <= pmove_mem_to_mmu_hi;
                                        END IF;
                                    WHEN "101" =>
                                        setstate <= "01";
                                        next_micro_state_c <= pmmu_ld_dAn1;
                                    WHEN "110" =>
                                        setstate <= "01";
                                        next_micro_state_c <= pmmu_ld_AnXn1;
                                    WHEN "111" =>
                                        set(ea_build) <= '0';
                                        IF pmmu_opcode(2 downto 0) = "000" THEN
                                            setstate <= "01";
                                            next_micro_state_c <= pmmu_ld_nn;
                                        ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                            setstate <= "00";
                                            next_micro_state_c <= pmmu_ld_nn;
                                        ELSE
                                            trap_1111 <= '1';
                                            trapmake <= '1';
                                        END IF;
                                    WHEN OTHERS =>
                                        trap_1111 <= '1';
                                        trapmake <= '1';
                                END CASE;
	                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "001" AND pmmu_brief(12 downto 10) = "000" THEN
                        IF pmmu_brief(8 downto 5) /= "0000" THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSIF pmmu_brief(4 downto 3) = "11" THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSIF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                           pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2 downto 1)="01") THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSE
                             set_exec(pmmu_pload) <= '1';
                             datatype <= "10";
                             CASE pmmu_opcode(5 downto 3) IS
                                 WHEN "010" =>
                                     setstate <= "01";
                                     next_micro_state_c <= pload1;
                                 WHEN "101" =>
                                     setstate <= "01";
                                     next_micro_state_c <= pmmu_ld_dAn1;
                                 WHEN "110" =>
                                     setstate <= "01";
                                     next_micro_state_c <= pmmu_ld_AnXn1;
                                 WHEN "111" =>
                                     IF pmmu_opcode(2 downto 0) = "000" THEN
                                         setstate <= "01";
                                         next_micro_state_c <= pmmu_ld_nn;
                                     ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                         setstate <= "00";
                                         next_micro_state_c <= pmmu_ld_nn;
                                     ELSE
                                         trap_1111 <= '1';
                                         trapmake <= '1';
                                     END IF;
                                 WHEN OTHERS =>
                                     trap_1111 <= '1';
                                     trapmake <= '1';
                             END CASE;
                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "001" AND (pmmu_brief(12 downto 10) = "001" OR pmmu_brief(12 downto 10) = "100" OR pmmu_brief(12 downto 10) = "110") THEN
	                        IF (pmmu_brief(12 downto 10) = "001" AND pmmu_brief(9 downto 0) /= "0000000000") OR
	                           pmmu_brief(9 downto 8) /= "00" THEN
	                             trap_1111 <= '1';
	                             trapmake <= '1';
                        ELSIF pmmu_brief(12 downto 10) /= "001" AND pmmu_brief(4 downto 3) = "11" THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSE
                             set_exec(pmmu_pflush) <= '1';
                             IF pmmu_brief(12 downto 10) = "110" THEN
                             IF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                                pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                                (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2 downto 0)>"001") THEN
                                 trap_1111 <= '1';
                                 trapmake <= '1';
                             ELSE
                                 datatype <= "10";
                                 CASE pmmu_opcode(5 downto 3) IS
                                     WHEN "010" =>
                                         setstate <= "01";
                                         next_micro_state_c <= pflush1;
                                     WHEN "101" =>
                                         setstate <= "01";
                                         next_micro_state_c <= pmmu_ld_dAn1;
                                     WHEN "110" =>
                                         setstate <= "01";
                                         next_micro_state_c <= pmmu_ld_AnXn1;
                                     WHEN "111" =>
                                         IF pmmu_opcode(2 downto 0) = "000" THEN
                                             setstate <= "01";
                                             next_micro_state_c <= pmmu_ld_nn;
                                         ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                             setstate <= "00";
                                             next_micro_state_c <= pmmu_ld_nn;
                                         ELSE
                                             trap_1111 <= '1';
                                             trapmake <= '1';
                                         END IF;
                                     WHEN OTHERS =>
                                         trap_1111 <= '1';
                                         trapmake <= '1';
                                 END CASE;
                             END IF;
                         ELSE
                             setstate <= "01";
                             next_micro_state_c <= pflush1;
                         END IF;
                        END IF;
                    ELSIF pmmu_brief(15 downto 13) = "100" THEN
                        IF pmmu_opcode(5 downto 3)="000" OR pmmu_opcode(5 downto 3)="001" OR
                           pmmu_opcode(5 downto 3)="011" OR pmmu_opcode(5 downto 3)="100" OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2)='1') OR
                           (pmmu_opcode(5 downto 3)="111" AND pmmu_opcode(2 downto 1)="01") THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSIF pmmu_brief(12 downto 10) = "000" AND pmmu_brief(8) = '1' THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSIF pmmu_brief(4 downto 3) = "11" THEN
                             trap_1111 <= '1';
                             trapmake <= '1';
                        ELSE
                             set_exec(pmmu_ptest) <= '1';
                             datatype <= "10";
                             CASE pmmu_opcode(5 downto 3) IS
                                 WHEN "010" =>
                                     setstate <= "01";
                                     next_micro_state_c <= ptest1;
                                 WHEN "101" =>
                                     setstate <= "01";
                                     next_micro_state_c <= pmmu_ld_dAn1;
                                 WHEN "110" =>
                                     setstate <= "01";
                                     next_micro_state_c <= pmmu_ld_AnXn1;
                                 WHEN "111" =>
                                     IF pmmu_opcode(2 downto 0) = "000" THEN
                                         setstate <= "01";
                                         next_micro_state_c <= pmmu_ld_nn;
                                     ELSIF pmmu_opcode(2 downto 0) = "001" THEN
                                         setstate <= "00";
                                         next_micro_state_c <= pmmu_ld_nn;
                                     ELSE
                                         trap_1111 <= '1';
                                         trapmake <= '1';
                                     END IF;
                                 WHEN OTHERS =>
                                     trap_1111 <= '1';
                                     trapmake <= '1';
                             END CASE;
                        END IF;
                    ELSE
                        trap_1111 <= '1';
                        trapmake <= '1';
                    END IF;

                WHEN pmove_mem_to_mmu_hi =>

                    set_exec(pmmu_wr) <= '1';
                    IF fline_opcode_latch(5 downto 3)="011" THEN
                        IF (pmmu_brief(14 downto 10) /= "10010" AND pmmu_brief(14 downto 10) /= "10011") THEN
                            set(postadd) <= '1';
                            IF fline_opcode_latch(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        END IF;
                    END IF;
	                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
	                        set_exec(mem_addsub) <= '1';
                        IF pmmu_ea_mode_latched(5 downto 3) /= "011" THEN
                            set(pmmu_addr_inc) <= '1';
                            set(OP1addr) <= '1';
                        END IF;
                        datatype <= "10";
                        set(longaktion) <= '1';
                        setstate <= "10";
                        next_micro_state_c <= pmove_mem_to_mmu_lo;
                    ELSE
                        setstate <= "00";

                        IF pmmu_brief(14 downto 10) = "11000" THEN
                            datatype <= "01";
                        ELSE
                            datatype <= "10";
                        END IF;
                        setstate <= "00";
                        next_micro_state_c <= idle;
                    END IF;

                WHEN pmove_mmu_to_mem_hi =>
                    IF (pmmu_brief(14 downto 10)="10010" OR pmmu_brief(14 downto 10)="10011") THEN
                        set_exec(mem_addsub) <= '1';
                        set(pmmu_addr_inc) <= '1';
                        set(OP1addr) <= '1';
                        datatype <= "10";
                        set(longaktion) <= '1';
                        set(hold_dwr) <= '1';
                        setstate <= "11";
                        set_exec(pmmu_rd) <= '1';
                        next_micro_state_c <= pmove_mmu_to_mem_lo;
                    ELSE
                        set(OP1addr) <= '1';
                        IF pmmu_brief(14 downto 10) = "11000" THEN
                            datatype <= "01";
                        ELSE
                            datatype <= "10";
                            set(longaktion) <= '1';
                        END IF;
                        IF fline_opcode_latch(5 downto 3)="011" THEN
                            set(postadd) <= '1';
                            IF fline_opcode_latch(2 downto 0)="111" THEN
                                set(use_SP) <= '1';
                            END IF;
                        END IF;
                        set(hold_dwr) <= '1';
                        setstate <= "11";
                        next_micro_state_c <= pmmu_dn_read_wait;
                    END IF;
                WHEN pmove_mmu_to_mem_lo =>
                    set(mem_addsub) <= '1';
                    set(OP1addr) <= '1';
                    set(pmmu_addr_inc) <= '1';
                    datatype <= "10";
                    set_datatype <= "10";
                    set(longaktion) <= '1';
                    IF fline_opcode_latch(5 downto 3)="011" THEN
                        set(postadd) <= '1';
                        set(pmmu_dbl) <= '1';
                        IF fline_opcode_latch(2 downto 0)="111" THEN
                            set(use_SP) <= '1';
                        END IF;
                    END IF;
                    set(hold_dwr) <= '1';
                    set_exec(pmmu_rd) <= '1';
                    setstate <= "11";
                    next_micro_state_c <= pmmu_dn_read_wait;
	                WHEN pmove_mem_to_mmu_lo =>
                    set_exec(pmmu_wr) <= '1';
                    IF pmmu_ea_mode_latched(5 downto 3) /= "011" THEN
                        set(OP1addr) <= '1';
                        set(pmmu_addr_inc) <= '1';
                    ELSE
                        set(postadd) <= '1';
                        set(pmmu_dbl) <= '1';
                        IF pmmu_ea_mode_latched(2 downto 0) = "111" THEN
                            set(use_SP) <= '1';
                        END IF;
                    END IF;
                    datatype <= "10";
                    set_datatype <= "10";
                    setstate <= "00";
                    next_micro_state_c <= idle;

                WHEN ptest1 =>
                    set(pmmu_ptest) <= '1';
                    set(OP1addr) <= '1';
                    setstate <= "01";
                    IF exec(pmmu_ptest) = '0' OR pmmu_busy = '1' THEN
                        next_micro_state_c <= ptest1;
                    ELSE
                        IF pmmu_brief(8)='1' THEN
                            set(Regwrena) <= '1';
                            datatype <= "10";
                            set_datatype <= "10";
                        END IF;
                        setstate <= "01";
                        next_micro_state_c <= pmmu_dn_read_wait;
                    END IF;

                WHEN pflush1 =>
                    set(pmmu_pflush) <= '1';
                    set(OP1addr) <= '1';
                    setstate <= "01";
                    IF exec(pmmu_pflush) = '0' OR pmmu_busy = '1' THEN
                        next_micro_state_c <= pflush1;
                    ELSE
                        setstate <= "01";
                        next_micro_state_c <= pmmu_dn_read_wait;
                    END IF;

                WHEN pload1 =>
                    set(pmmu_pload) <= '1';
                    set(OP1addr) <= '1';
                    setstate <= "01";
                    IF exec(pmmu_pload) = '0' OR pmmu_busy = '1' THEN
                        next_micro_state_c <= pload1;
                    ELSE
                        setstate <= "01";
                        next_micro_state_c <= pmmu_dn_read_wait;
                    END IF;

                WHEN pmove_dn_hi =>
                    IF pmmu_brief(9)='1' THEN
                        set(pmmu_rd) <= '1';
                        set(Regwrena) <= '1';
                    ELSE
                        set_exec(pmmu_wr) <= '1';
                    END IF;
                    datatype <= "10";
                    next_micro_state_c <= pmove_dn_lo;

                WHEN pmove_dn_lo =>
                    IF pmmu_brief(9)='0' THEN
                        set_exec(pmmu_wr) <= '1';
                    ELSE
                        datatype <= "10";
                    END IF;
                    setstate <= "00";
                    next_micro_state_c <= idle;

                WHEN pmmu_dn_read_wait =>
	                    IF exec(pmmu_rd)='1' OR set(pmmu_rd)='1' OR pmmu_rd_carry='1' THEN
	                        set_exec(pmmu_rd) <= '1';
	                        IF pmmu_opcode(5 downto 3) = "000" THEN
	                            set_exec(Regwrena) <= '1';
	                        END IF;
	                        IF pmmu_brief(14 downto 10) = "11000" THEN
	                            datatype <= "01";
                            set_datatype <= "01";
                        ELSE
                            datatype <= "10";
                            set_datatype <= "10";
	                        END IF;
                    END IF;
                    setstate <= "00";
                    IF exec(pmmu_rd)='1' OR set(pmmu_rd)='1' OR pmmu_rd_carry='1' THEN
                        next_micro_state_c <= idle;
                    ELSE
                        next_micro_state_c <= idle;
                    END IF;

				WHEN movep1 =>
					setdisp <= '1';
					set(mem_addsub) <= '1';
					set(mem_byte) <= '1';
					set(OP1addr) <= '1';
					IF opcode(6)='1' THEN
						set(movepl) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state_c <= movep2;
				WHEN movep2 =>
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';
					    set(OP1addr) <= '1';
					END IF;
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state_c <= movep3;
				WHEN movep3 =>
					IF opcode(6)='1' THEN
						set(mem_addsub) <= '1';
					    set(OP1addr) <= '1';
						set(mem_byte) <= '1';
						IF opcode(7)='0' THEN
							setstate <= "10";
						ELSE
							setstate <= "11";
						END IF;
						next_micro_state_c <= movep4;
					ELSE
						datatype <= "01";
					END IF;
				WHEN movep4 =>
					IF opcode(7)='0' THEN
						setstate <= "10";
					ELSE
						setstate <= "11";
					END IF;
					next_micro_state_c <= movep5;
				WHEN movep5 =>
					datatype <= "10";

				WHEN mul1	=>
					IF opcode(15)='1' OR MUL_Mode=0 THEN
						set_rot_cnt <= "001110";
					ELSE
						set_rot_cnt <= "011110";
					END IF;
					setstate <="01";
					next_micro_state_c <= mul2;
				WHEN mul2	=>
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state_c <= mul_end1;

					ELSE
						next_micro_state_c <= mul2;
					END IF;
				WHEN mul_end1	=>
					IF opcode(15)='0' THEN
						set(hold_OP2) <= '1';
					END IF;
					datatype <= "10";
					set(opcMULU) <= '1';
					IF opcode(15)='0' AND (MUL_Mode=1 OR MUL_Mode=2) THEN
						dest_2ndHbits <= '1';
						set(write_lowlong) <= '1';
						IF sndOPC(10)='1' THEN
							setstate <="01";
							next_micro_state_c <= mul_end2;
						END IF;
						set(Regwrena) <= '1';
					END IF;
					datatype <= "10";
				WHEN mul_end2	=>
					dest_2ndLbits <= '1';
					set(write_reminder) <= '1';
					set(Regwrena) <= '1';
					set(opcMULU) <= '1';

				WHEN div1	=>
					setstate <="01";
					next_micro_state_c <= div2;
				WHEN div2	=>
					IF (OP2out(31 downto 16)=x"0000" OR opcode(15)='1' OR DIV_Mode=0) AND OP2out(15 downto 0)=x"0000" THEN
						set_Z_error <= '1';
					ELSE
						next_micro_state_c <= div3;
					END IF;
					set(ld_rot_cnt) <= '1';
					setstate <="01";
				WHEN div3	=>
					IF opcode(15)='1' OR DIV_Mode=0 THEN
						set_rot_cnt <= "001101";
					ELSE
						set_rot_cnt <= "011101";
					END IF;
					setstate <="01";
					next_micro_state_c <= div4;
				WHEN div4	=>
					setstate <="01";
					IF rot_cnt="00001" THEN
						next_micro_state_c <= div_end1;
					ELSE
						next_micro_state_c <= div4;
					END IF;
				WHEN div_end1	=>
					IF z_error='0' AND set_V_Flag='0' THEN
						set(Regwrena) <= '1';
					END IF;
					IF opcode(15)='0' AND (DIV_Mode=1 OR DIV_Mode=2) THEN
						dest_2ndLbits <= '1';
						set(write_reminder) <= '1';
						next_micro_state_c <= div_end2;
						setstate <="01";
					END IF;
					set(opcDIVU) <= '1';
					datatype <= "10";
				WHEN div_end2	=>
					IF exec(Regwrena)='1' THEN
						set(Regwrena) <= '1';
					ELSE
						set(no_Flags) <= '1';
					END IF;
					dest_2ndHbits <= '1';
					set(opcDIVU) <= '1';

				WHEN rota1	=>
					IF OP2out(5 downto 0)/="000000" THEN
						set_rot_cnt <= OP2out(5 downto 0);
					ELSE
						set_exec(rot_nop) <= '1';
					END IF;

				WHEN bf1 =>
					setstate <="10";

				WHEN OTHERS => NULL;
			END CASE;
			IF moves_active = '1' AND (micro_state = moves0 OR micro_state = moves1 OR moves_writeback_pending = '1') THEN
				set(no_Flags) <= '1';
			END IF;
			IF cp_bf_now = '1' THEN
				setstate <= "01";
				cp_cir_next <= '0';
				cp_mem_next <= '0';
				trapmake <= '0';
				trap_1111 <= '0';
				trap_cp <= '0';
				trap_cp9 <= '0';
				trap_cppv <= '0';
				trap_cpfmt <= '0';
				trap_cptrap <= '0';
				cp_br_sel <= '0';
				TG68_PC_brw <= '0';
			END IF;
		END PROCESS;

  process (clk, SFC, DFC, VBR, CACR, CAAR, USP, SSP, MSP, ISP, brief, pmmu_reg_rdat,
           regfile, FlagsSR, interrupt_mode)
  begin
		if rising_edge(clk) then
		  if Reset = '1' then
			VBR <= (others => '0');
			CACR <= (others => '0');
			CAAR <= (others => '0');
			USP <= (others => '0');
			SSP <= (others => '0');
			MSP <= (others => '0');
			ISP <= (others => '0');
		  elsif clkena_lw = '1' and exec(movec_wr) = '1' then
		case movec_regsel is
		  when X"000" => SFC <= reg_QA(2 downto 0);
		  when X"001" => DFC <= reg_QA(2 downto 0);
		  when X"002" =>
		    CACR(4 downto 0) <= reg_QA(4 downto 0);
		    CACR(7 downto 5) <= (others => '0');
		    CACR(13 downto 8) <= reg_QA(13 downto 8);
		    CACR(31 downto 14) <= (others => '0');
		  when X"800" => USP <= reg_QA;
		  when X"801" => VBR <= reg_QA;
		  when X"802" => CAAR <= reg_QA;
		  when X"803" => MSP <= reg_QA;
		  when X"804" => ISP <= reg_QA;
		  when others => NULL;
		end case;
  elsif clkena_lw = '1' then
    if exec(to_USP) = '1' then
      USP <= reg_QA;
    end if;
    if exec(to_SSP) = '1' then
      SSP <= reg_QA;
    end if;
    if exec(to_MSP) = '1' then
      MSP <= reg_QA;
    end if;
    if exec(to_ISP) = '1' then
      ISP <= reg_QA;
    end if;
    if cpu(1)='1' and preSVmode='1' and exec(to_SR)='1' and SRin(5)='1' and SRin(4) /= FlagsSR(4) then
      if SRin(4) = '1' then
        ISP <= regfile(15);
      else
        MSP <= regfile(15);
      end if;
    end if;
    if cpu(1)='1' and preSVmode='1' and set_stop='1' and data_read(13)='1' and data_read(12) /= FlagsSR(4) then
      if data_read(12) = '1' then
        ISP <= regfile(15);
      else
        MSP <= regfile(15);
      end if;
    end if;
    if CACR(3) = '1' then
      CACR(3) <= '0';
    elsif CACR(11) = '1' then
      CACR(11) <= '0';
    elsif CACR(2) = '1' then
      CACR(2) <= '0';
    elsif CACR(10) = '1' then
      CACR(10) <= '0';
    end if;
	  end if;
	end if;

	movec_data <= (others => '0');
	case movec_regsel is
		when X"000" => movec_data <= "00000000000000000000000000000" & SFC;
		when X"001" => movec_data <= "00000000000000000000000000000" & DFC;
		  when X"002" => movec_data <= CACR and x"00003313";
	  when X"800" => movec_data <= USP;
	  when X"801" => movec_data <= VBR;
	  when X"802" => movec_data <= CAAR;
	  when X"803" =>
	    if FlagsSR(4)='1' and interrupt_mode='0' then
	      movec_data <= regfile(15);
	    else
	      movec_data <= MSP;
	    end if;
	  when X"804" =>
	    if FlagsSR(4)='0' or interrupt_mode='1' then
	      movec_data <= regfile(15);
	    else
	      movec_data <= ISP;
	    end if;
	  when others => NULL;
	end case;
  end process;

  CACR_out <= CACR;
  VBR_out <= VBR;

  process(clk)
  begin
    if rising_edge(clk) then
      if Reset = '1' then
        pmmu_rd_carry <= '0';
      else
        pmmu_rd_carry <= set_exec(pmmu_rd);
      end if;
    end if;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if Reset = '1' then
        pmmu_reg_sel_d  <= (others => '0');
        pmmu_reg_wdat_d <= (others => '0');
        pmmu_reg_part_d <= '0';
        pmmu_reg_fd_d   <= '0';
        pmove_ea_latched <= (others => '0');
      elsif clkena_core='1' then

        if ((next_micro_state = pmove_mmu_to_mem_lo and micro_state = pmove_mmu_to_mem_hi) or
            (next_micro_state = pmove_mem_to_mmu_lo and micro_state = pmove_mem_to_mmu_hi)) and
            pmove_ea_captured = '0' then
	            pmove_ea_latched <= addr + 4;
            pmove_ea_captured <= '1';
        end if;
        if setendOPC = '1' or trapmake = '1' then
            pmove_ea_captured <= '0';
        end if;

        if CPU(1)='1' AND (set_exec(pmmu_wr)='1' OR set_exec(pmmu_rd)='1' OR set(pmmu_wr)='1' OR set(pmmu_rd)='1' OR exec(pmmu_wr)='1' OR exec(pmmu_rd)='1') then
          pmmu_reg_wdat_d <= pmmu_src_data;

          if set_exec(pmmu_wr) = '1' OR set(pmmu_wr) = '1' OR exec(pmmu_wr) = '1' then
            if pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011" OR pmmu_brief(14 downto 10) = "10000" OR
               pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" OR pmmu_brief(14 downto 10) = "11000" then
              pmmu_reg_sel_d  <= pmmu_brief(14 downto 10);
              if (pmmu_brief(14 downto 10) = "10010") or (pmmu_brief(14 downto 10) = "10011") then
                if clkena_lw='1' then
                if micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';
                elsif micro_state = pmove_dn_lo OR next_micro_state = pmove_dn_lo then
                  pmmu_reg_part_d <= '0';
                elsif micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';
                else
                  pmmu_reg_part_d <= '0';
                end if;
                end if;
              end if;
              if (pmmu_brief(15 downto 13) = "000" or pmmu_brief(15 downto 13) = "010") and pmmu_brief(8) = '1' then
                pmmu_reg_fd_d <= '1';
              else
                pmmu_reg_fd_d <= '0';
              end if;
            end if;
          end if;

          if set(pmmu_rd) = '1' OR exec(pmmu_rd) = '1' OR set_exec(pmmu_rd) = '1' then
            if pmmu_brief(14 downto 10) = "00010" OR pmmu_brief(14 downto 10) = "00011" OR pmmu_brief(14 downto 10) = "10000" OR
               pmmu_brief(14 downto 10) = "10010" OR pmmu_brief(14 downto 10) = "10011" OR pmmu_brief(14 downto 10) = "11000" then
              pmmu_reg_sel_d <= pmmu_brief(14 downto 10);
              if (pmmu_brief(14 downto 10) = "10010") or (pmmu_brief(14 downto 10) = "10011") then
                if clkena_lw='1' then
                if micro_state = pmove_mmu_to_mem_lo OR next_micro_state = pmove_mmu_to_mem_lo then
                  pmmu_reg_part_d <= '0';
                elsif micro_state = pmove_mem_to_mmu_lo OR next_micro_state = pmove_mem_to_mmu_lo then
                  pmmu_reg_part_d <= '0';
                elsif micro_state = pmove_dn_lo OR next_micro_state = pmove_dn_lo then
                  pmmu_reg_part_d <= '0';
                elsif micro_state = pmove_mmu_to_mem_hi OR micro_state = pmove_mem_to_mmu_hi OR micro_state = pmove_decode OR micro_state = pmove_dn_hi OR
                      next_micro_state = pmove_mmu_to_mem_hi OR next_micro_state = pmove_mem_to_mmu_hi then
                  pmmu_reg_part_d <= '1';
                else
                  pmmu_reg_part_d <= '0';
                end if;
                end if;
              end if;
              pmmu_reg_fd_d <= '1';
            end if;
          end if;

        end if;

        if clkena_lw='1' then
        if CPU(1)='1' and (pmmu_brief(14 downto 10) = "10010" or pmmu_brief(14 downto 10) = "10011") then
            if next_micro_state = pmove_mem_to_mmu_hi or next_micro_state = pmove_mmu_to_mem_hi then
                pmmu_reg_part_d <= '1';
            elsif next_micro_state = pmove_mem_to_mmu_lo or next_micro_state = pmove_mmu_to_mem_lo then
                pmmu_reg_part_d <= '0';
            end if;
        end if;
        end if;
      end if;
    end if;
  end process;
PROCESS (exe_opcode, Flags)
	BEGIN
		CASE exe_opcode(11 downto 8) IS
			WHEN X"0" => exe_condition <= '1';
			WHEN X"1" => exe_condition <= '0';
			WHEN X"2" => exe_condition <=  NOT Flags(0) AND NOT Flags(2);
			WHEN X"3" => exe_condition <= Flags(0) OR Flags(2);
			WHEN X"4" => exe_condition <= NOT Flags(0);
			WHEN X"5" => exe_condition <= Flags(0);
			WHEN X"6" => exe_condition <= NOT Flags(2);
			WHEN X"7" => exe_condition <= Flags(2);
			WHEN X"8" => exe_condition <= NOT Flags(1);
			WHEN X"9" => exe_condition <= Flags(1);
			WHEN X"a" => exe_condition <= NOT Flags(3);
			WHEN X"b" => exe_condition <= Flags(3);
			WHEN X"c" => exe_condition <= (Flags(3) AND Flags(1)) OR (NOT Flags(3) AND NOT Flags(1));
			WHEN X"d" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1));
			WHEN X"e" => exe_condition <= (Flags(3) AND Flags(1) AND NOT Flags(2)) OR (NOT Flags(3) AND NOT Flags(1) AND NOT Flags(2));
			WHEN X"f" => exe_condition <= (Flags(3) AND NOT Flags(1)) OR (NOT Flags(3) AND Flags(1)) OR Flags(2);
			WHEN OTHERS => NULL;
		END CASE;
	END PROCESS;

PROCESS (clk)
	BEGIN
		IF rising_edge(clk) THEN
			IF clkena_lw='1' THEN
				movem_actiond <= exec(movem_action);
				IF decodeOPC='1' THEN
					sndOPC <= data_read(15 downto 0);
				ELSIF exec(movem_action)='1' OR set(movem_action) ='1' THEN
					CASE movem_regaddr IS
						WHEN "0000" => sndOPC(0)  <= '0';
						WHEN "0001" => sndOPC(1)  <= '0';
						WHEN "0010" => sndOPC(2)  <= '0';
						WHEN "0011" => sndOPC(3)  <= '0';
						WHEN "0100" => sndOPC(4)  <= '0';
						WHEN "0101" => sndOPC(5)  <= '0';
						WHEN "0110" => sndOPC(6)  <= '0';
						WHEN "0111" => sndOPC(7)  <= '0';
						WHEN "1000" => sndOPC(8)  <= '0';
						WHEN "1001" => sndOPC(9)  <= '0';
						WHEN "1010" => sndOPC(10) <= '0';
						WHEN "1011" => sndOPC(11) <= '0';
						WHEN "1100" => sndOPC(12) <= '0';
						WHEN "1101" => sndOPC(13) <= '0';
						WHEN "1110" => sndOPC(14) <= '0';
						WHEN "1111" => sndOPC(15) <= '0';
						WHEN OTHERS => NULL;
					END CASE;
				END IF;
			END IF;
		END IF;
	END PROCESS;

PROCESS (sndOPC, movem_mux)
	BEGIN
		movem_regaddr <="0000";
		movem_run <= '1';
		IF sndOPC(3 downto 0)="0000" THEN
			IF sndOPC(7 downto 4)="0000" THEN
				movem_regaddr(3) <= '1';
				IF sndOPC(11 downto 8)="0000" THEN
					IF sndOPC(15 downto 12)="0000" THEN
						movem_run <= '0';
					END IF;
					movem_regaddr(2) <= '1';
					movem_mux <= sndOPC(15 downto 12);
				ELSE
					movem_mux <= sndOPC(11 downto 8);
				END IF;
			ELSE
				movem_mux <= sndOPC(7 downto 4);
				movem_regaddr(2) <= '1';
			END IF;
		ELSE
			movem_mux <= sndOPC(3 downto 0);
		END IF;
		IF movem_mux(1 downto 0)="00" THEN
			movem_regaddr(1) <= '1';
			IF movem_mux(2)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;
		ELSE
			IF movem_mux(0)='0' THEN
				movem_regaddr(0) <= '1';
			END IF;
		END  IF;
	END PROCESS;

addr_xlat <= pmmu_addr_log_int when pmmu_tc_en = '0' else pmmu_addr_phys_int;
addr_out <= addr_xlat(31 downto 2) & fetch_a10 when fetch_bus = '1' else addr_xlat;
addr_log_out <= pmmu_addr_log_int(31 downto 2) & fetch_a10 when fetch_bus = '1' else pmmu_addr_log_int;

process(clk)
begin
	if rising_edge(clk) then
		if Reset='1' then
			fmt_err_latched <= '0';
			fmt_err_rte_word <= (others => '0');
			fmt_err_pc <= (others => '0');
			fmt_err_addr <= (others => '0');
			fmt_err_sr <= (others => '0');
		elsif trap_format_error='1' and fmt_err_latched='0' then
			fmt_err_latched <= '1';
			fmt_err_rte_word <= rte_format_word;
			fmt_err_pc <= TG68_PC;
			fmt_err_addr <= memaddr_reg;
			fmt_err_sr <= FlagsSR;
		end if;
	end if;
end process;

debug_trap_format_error <= fmt_err_latched;
debug_format_error_rte_word <= fmt_err_rte_word;
debug_format_error_pc <= fmt_err_pc;
debug_format_error_addr <= fmt_err_addr;
debug_format_error_sr <= fmt_err_sr;

debug_SVmode <= '1' when SVmode='1' else '0';
debug_preSVmode <= '1' when preSVmode='1' else '0';
debug_FlagsSR_S <= FlagsSR(5);
debug_changeMode <= '1' when set(changeMode)='1' else '0';
debug_setopcode <= '1' when setopcode='1' else '0';
debug_exec_directSR <= '1' when exec(directSR)='1' else '0';
debug_exec_to_SR <= '1' when exec(to_SR)='1' else '0';

debug_pmove_dn_mode <= pmove_dn_mode;
debug_pmove_dn_regnum <= pmove_dn_regnum;

debug_opcode <= opcode;

debug_state <= state;
debug_setstate <= setstate;
debug_last_opc_read <= last_opc_read;
debug_data_read <= data_read;
debug_direct_data <= '1' when direct_data='1' else '0';
debug_setnextpass <= '1' when setnextpass='1' else '0';

debug_TG68_PC <= TG68_PC;
debug_memaddr_reg <= memaddr_reg;
debug_memaddr_delta <= memaddr_delta;
debug_oddout <= oddout;
debug_decodeOPC <= '1' when decodeOPC='1' else '0';

debug_brief <= brief;
debug_moves_bus_pending <= moves_bus_pending;
debug_moves_writeback_pending <= moves_writeback_pending;
debug_clkena_lw <= clkena_lw;
debug_regfile_d0 <= regfile(0);
debug_regfile_a0 <= regfile(8);

debug_fline_context_valid <= fline_context_valid;
debug_trap_1111 <= '1' when trap_1111='1' else '0';
debug_trapmake <= '1' when trapmake='1' else '0';
debug_exc_take <= '1' when micro_state = trap3 and clkena_lw = '1' else '0';
debug_opcode_pc <= opcode_pc;
debug_pmmu_brief <= pmmu_brief;

debug_use_base <= '1' when use_base='1' else '0';
debug_rf_source_addr <= rf_source_addr;
debug_pmove_ea_latched <= pmove_ea_latched;
debug_reg_QA <= reg_QA;

debug_last_data_read <= last_data_read;
debug_last_opc_pc <= last_opc_pc;
debug_getbrief <= '1' when getbrief='1' else '0';
debug_get_2ndopc <= '0';
debug_fline_brief_pending <= '0';
debug_fline_opcode_pc <= fline_opcode_pc;
debug_exe_PC <= exe_pc;
debug_memaddr_delta_rega <= memaddr_delta_rega;
debug_memaddr_delta_regb <= memaddr_delta_regb;
debug_addsub_q <= addsub_q;
debug_memmaskmux <= memmaskmux;
debug_fline_opcode_latch <= fline_opcode_latch;
debug_pmmu_ea_mode_latched <= pmmu_ea_mode_latched;
debug_exec_direct_delta <= '1' when exec(direct_delta)='1' else '0';
debug_exec_directPC <= '1' when exec(directPC)='1' else '0';
debug_bus_beat_poisoned <= '1' when bus_beat_poisoned='1' else '0';
debug_exec_mem_addsub <= '1' when exec(mem_addsub)='1' else '0';
debug_set_addrlong <= '1' when set(addrlong)='1' else '0';
debug_mdelta_src <= x"00";
debug_pc_brw <= '1' when TG68_PC_brw='1' else '0';
debug_pc_word <= '1' when TG68_PC_word='1' else '0';
debug_regfile_d1 <= regfile(1);
debug_regfile_d2 <= regfile(2);
debug_regfile_d3 <= regfile(3);
debug_regfile_d4 <= regfile(4);
debug_regfile_d5 <= regfile(5);
debug_regfile_d6 <= regfile(6);
debug_regfile_d7 <= regfile(7);
debug_regfile_a1 <= regfile(9);
debug_regfile_a2 <= regfile(10);
debug_regfile_a3 <= regfile(11);
debug_regfile_a4 <= regfile(12);
debug_regfile_a5 <= regfile(13);
debug_regfile_a6 <= regfile(14);
debug_regfile_a7 <= regfile(15);
debug_regfile_we <= '1' when (Lwrena='1' or Wwrena='1' or Bwrena='1') else '0';
debug_regfile_waddr <= rf_dest_addr;
debug_regfile_wdata <= regin;
debug_trap_illegal <= '1' when trap_illegal='1' else '0';
debug_trap_priv <= '1' when trap_priv='1' else '0';
debug_trap_addr_error <= '1' when trap_addr_error='1' else '0';
debug_trap_berr <= '1' when trap_berr='1' else '0';
debug_trap_mmu_berr <= '1' when trap_mmu_berr='1' else '0';
debug_trap_vector <= trap_vector;
debug_pc_add <= TG68_PC_add;
debug_pc_dataa <= PC_dataa;
debug_pc_datab <= PC_datab;
debug_pmmu_busy <= pmmu_busy;
debug_cpu_halted <= cpu_halted;
debug_stop <= '1' WHEN stop='1' ELSE '0';
debug_interrupt <= '1' WHEN interrupt='1' ELSE '0';
debug_setendOPC <= '1' WHEN setendOPC='1' ELSE '0';
debug_IPL_nr <= IPL_nr;
debug_micro_state <= micro_states'pos(micro_state);
debug_next_micro_state <= micro_states'pos(next_micro_state);
debug_memmask <= memmask;
debug_sndOPC <= sndOPC;
debug_pmmu_reg_we <= pmmu_reg_we_d;
debug_pmmu_reg_re <= pmmu_reg_re_d;
debug_pmmu_reg_sel <= pmmu_reg_sel_int;
debug_pmmu_reg_wdat <= pmmu_src_data;
debug_pmmu_reg_part <= pmmu_reg_part_int;
debug_pmmu_reg_rdat <= x"0000" & pmmu_debug_mmusr;
debug_make_berr <= make_berr;
debug_pmmu_fault <= pmmu_fault;
debug_berr_exception_active <= berr_exception_active;
debug_pmmu_fault_dispatched <= pmmu_fault_dispatched;
debug_pmmu_fault_was_cleared <= pmmu_fault_was_cleared;
debug_pmmu_fault_rw <= pmmu_fault_rw_out;
debug_pmmu_fault_is_insn <= pmmu_fault_is_insn_out;
debug_pmmu_fault_fc <= pmmu_fault_fc_out;
debug_pmmu_fault_addr  <= pmmu_fault_addr_out;
debug_pmmu_fault_mmusr <= pmmu_fault_stat(15 downto 0);

debug_make_trace         <= make_trace;
debug_trace_pending_grp2 <= trace_pending_group2;
debug_useStackframe2     <= useStackframe2;
debug_exec_trap_chk      <= '1' WHEN exec(trap_chk)='1' ELSE '0';
debug_set_trap_chk       <= '1' WHEN set(trap_chk)='1' ELSE '0';
debug_data_write_tmp     <= data_write_tmp;
debug_FlagsSR            <= FlagsSR;
debug_USP                <= USP;
debug_MSP                <= MSP;
debug_ISP                <= ISP;
debug_a7_is_msp          <= a7_is_msp;
debug_interrupt_mode     <= interrupt_mode;
debug_rte_saved_mbit     <= rte_saved_mbit;
debug_rte_format_word    <= rte_format_word;
debug_rte_mmu_fix_ssw    <= rte_mmu_fix_ssw;
debug_rte_mmu_fix_opcode <= rte_mmu_fix_opcode;
debug_rte_mmu_fix_write  <= rte_mmu_fix_commit;
debug_rte_fmt_a_state1 <= rte_fmt_a_state1;
debug_rte_fmt_a_ssw <= rte_fmt_a_ssw;
debug_rte_fmt_a_fault_addr <= rte_fmt_a_fault_addr;
debug_rte_fmt_a_data_out <= rte_fmt_a_data_out;
debug_rte_fmt_a_replay_needed <= rte_fmt_a_replay_needed;
debug_rte_format_b_version_error <= rte_format_b_version_error;

diag_rte_events : PROCESS (clk)
BEGIN
	IF rising_edge(clk) THEN
			IF clkena_lw = '1' THEN
				IF rte_mmu_fix_commit = '1' THEN
				report "FIX_COMMIT: tg68_pc=" & integer'image(conv_integer(TG68_PC(15 downto 0))) &
				       " fix_opcode=" & integer'image(conv_integer(rte_mmu_fix_opcode)) severity note;
			END IF;
			IF exec(directPC) = '1' AND clkena_lw = '1' THEN
				report "RTE_RESUME: target=" & integer'image(conv_integer(data_read(15 downto 0))) &
				       " bv=" & std_logic'image(beat_valid) &
				       " poison=" & std_logic'image(bus_beat_poisoned) &
				       " dirty=" & std_logic'image(bus_datum_dirty) &
				       " retry=" & std_logic'image(directpc_retry_hold) &
				       " make=" & std_logic'image(make_berr) &
				       " meta=" & std_logic'image(berr_pmmu_fault_valid) &
				       " insn=" & std_logic'image(berr_pmmu_fault_is_insn) &
				       " trapmake=" & bit'image(trapmake) &
				       " pf=" & std_logic'image(pmmu_fault) &
				       " pf_insn=" & std_logic'image(pmmu_fault_is_insn_out) &
				       " state=" & integer'image(conv_integer(state))
				       severity note;
			END IF;
		END IF;
		IF clkena_core = '1' AND (micro_state = berr_fill OR micro_state = berr1 OR micro_state = berr2 OR
		                        micro_state = berr3 OR micro_state = berr4 OR micro_state = berr5 OR
		                        micro_state = berr6 OR micro_state = berr7 OR micro_state = berr8) THEN
			report "BERRPUSH: addr=" & integer'image(conv_integer(memaddr(15 downto 0))) &
			       " state=" & integer'image(conv_integer(state)) &
			       " pf=" & std_logic'image(pmmu_fault) &
			       " pb=" & std_logic'image(pmmu_busy) &
			       " mm5=" & std_logic'image(memmaskmux(5)) &
			       " pend=" & std_logic'image(mmu_restart_pending) &
			       " soft=" & std_logic'image(mmu_restart_soft) severity note;
		END IF;
	END IF;
END PROCESS;

END;
