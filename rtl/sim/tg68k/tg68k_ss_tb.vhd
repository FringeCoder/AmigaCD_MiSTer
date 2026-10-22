-------------------------------------------------------------------------------
-- TG68KdotC_Kernel savestate restore testbench.
--
-- Why this exists: the savestate restore write ports (ss_wr_*, ss_pc_wr,
-- ss_sr_wr, ss_usp_wr, ss_vbr_wr, ss_cacr_wr) were added to the kernel with no
-- simulation behind them at all, and on hardware a restore garbles the screen
-- and then resets the core. This bench runs the real kernel against a flat
-- one-cycle memory so a restore can be watched instruction by instruction.
--
-- Three phases:
--
--   SANITY   the CPU boots from the reset vectors and runs the test program.
--            Nothing below is worth anything if this does not pass.
--
--   RED      restore every architectural register at FREEZE_N successive
--            freeze points across one pass of the main loop, without pulsing
--            ss_resume, and count how many of them resume correctly. This is
--            a scan rather than a single case on purpose: whether a restore
--            survives depends entirely on where inside an instruction the CPU
--            happened to be parked, which is why the hardware symptom is
--            "garbage, then a reset" rather than a clean, repeatable hang.
--            The bench asserts that at least one freeze point fails, so a
--            resume implementation that quietly does nothing cannot pass.
--
--   GREEN    the same scan with ss_resume pulsed. Every freeze point must
--            resume at the restored PC, execute the instruction the assembler
--            put there, and write the restored register values to memory.
--
-- On the freeze points: cpu_wrapper computes ss_cpu_hold as (ss_arm &
-- ~cpu_req). "No bus request pending" is not "at an instruction boundary" --
-- a multi-word instruction has gaps between its bus cycles. So freezing at
-- arbitrary cycles, as this bench does, is a faithful model of the hardware
-- and not a pessimistic one.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use std.textio.all;

entity tg68k_ss_tb is
	generic (
		-- Relative to the directory ghdl -r is run from (the repo root).
		PROG      : string  := "rtl/sim/tg68k/tg68k_ss_prog.hex";
		-- Number of successive freeze points to scan. One pass of the main
		-- loop is about 70 clocks, so 80 covers all of it and then some.
		FREEZE_N  : integer := 80;
		-- Clocks spent in the main loop before the first freeze point.
		FREEZE_LO : integer := 200;
		-- 1 runs the kernel as cpu_wrapper does for "68030 no MMU": CPU030
		-- high, MMU030 low. CI runs the bench both ways, since the 68030 is
		-- allowed save states without its MMU since 2026-10-19.
		CPU030_G  : integer := 0;
		-- 1, with CPU030_G, is the 68030 with its MMU (MMU030 high), which
		-- PHASE 8 needs; save states carry the MMU registers since format 1.5.
		MMU_G     : integer := 0
	);
end entity;

architecture sim of tg68k_ss_tb is

	function to_sl(b : boolean) return std_logic is
	begin
		if b then return '1'; else return '0'; end if;
	end function;
	constant C030 : std_logic := to_sl(CPU030_G /= 0);
	constant CMMU : std_logic := to_sl(CPU030_G /= 0 and MMU_G /= 0);

	constant MEMW : integer := 16384;			-- words, i.e. 32 KB
	-- Words put back between scan iterations: the program plus the sentinels.
	constant RELOADW : integer := 1024;

	type mem_t is array (0 to MEMW-1) of std_logic_vector(15 downto 0);

	-- Program layout, from tg68k_ss_prog.s.
	type reg_array is array (0 to 15) of std_logic_vector(31 downto 0);
	constant ADDR_MAIN     : std_logic_vector(31 downto 0) := X"00000400";
	constant ADDR_RESTORED : std_logic_vector(31 downto 0) := X"00000500";
	constant OPC_MAIN      : std_logic_vector(15 downto 0) := X"203C";	-- move.l #imm,d0
	constant OPC_RESTORED  : std_logic_vector(15 downto 0) := X"21C3";	-- move.l d3,$0604
	constant MAIN_MARK     : integer := 16#600#;
	constant RES_D3        : integer := 16#604#;
	constant RES_A2        : integer := 16#608#;
	constant RES_TAG       : integer := 16#60C#;
	constant SCRATCH       : integer := 16#610#;

	-- Values pushed in through the savestate write ports.
	constant SS_PC_VAL  : std_logic_vector(31 downto 0) := ADDR_RESTORED;
	constant SS_SR_VAL  : std_logic_vector(15 downto 0) := X"2700";	-- supervisor, IPL 7
	constant SS_USP_VAL : std_logic_vector(31 downto 0) := X"00006000";
	constant SS_A7_VAL  : std_logic_vector(31 downto 0) := X"00007FF0";
	constant EXP_D3     : std_logic_vector(31 downto 0) := X"5EED0003";
	constant EXP_A2     : std_logic_vector(31 downto 0) := X"5EED000A";
	constant EXP_TAG    : std_logic_vector(31 downto 0) := X"DEADBEEF";

	function nib(c : character) return std_logic_vector is
	begin
		case c is
			when '0'       => return x"0";
			when '1'       => return x"1";
			when '2'       => return x"2";
			when '3'       => return x"3";
			when '4'       => return x"4";
			when '5'       => return x"5";
			when '6'       => return x"6";
			when '7'       => return x"7";
			when '8'       => return x"8";
			when '9'       => return x"9";
			when 'a' | 'A' => return x"A";
			when 'b' | 'B' => return x"B";
			when 'c' | 'C' => return x"C";
			when 'd' | 'D' => return x"D";
			when 'e' | 'E' => return x"E";
			when 'f' | 'F' => return x"F";
			when others    => return "XXXX";
		end case;
	end function;

	-- One 16-bit word per line, most significant nibble first. Anything that is
	-- not a hex digit ends the line, so a CRLF file loads unchanged.
	impure function load_hex(fname : string) return mem_t is
		file     f   : text;
		variable st  : file_open_status;
		variable l   : line;
		variable m   : mem_t := (others => (others => '0'));
		variable idx : integer := 0;
		variable w   : std_logic_vector(15 downto 0);
		variable n   : std_logic_vector(3 downto 0);
		variable k   : integer;
	begin
		file_open(st, f, fname, read_mode);
		assert st = open_ok
			report "tg68k_ss_tb: cannot open " & fname severity failure;
		while not endfile(f) loop
			readline(f, l);
			w := (others => '0');
			k := 0;
			for i in l.all'range loop
				n := nib(l.all(i));
				exit when n(0) = 'X';
				w := w(11 downto 0) & n;
				k := k + 1;
			end loop;
			if k > 0 and idx < MEMW then
				m(idx) := w;
				idx    := idx + 1;
			end if;
		end loop;
		file_close(f);
		assert idx > 0 report "tg68k_ss_tb: " & fname & " is empty" severity failure;
		return m;
	end function;

	constant IMAGE : mem_t := load_hex(PROG);

	signal mem : mem_t := IMAGE;

	signal clk         : std_logic := '0';
	signal nReset      : std_logic := '0';
	signal clkena_in   : std_logic := '1';
	signal data_in     : std_logic_vector(15 downto 0) := (others => '0');
	signal addr_out    : std_logic_vector(31 downto 0);
	signal data_write  : std_logic_vector(15 downto 0);
	signal nWr         : std_logic;
	signal nUDS        : std_logic;
	signal nLDS        : std_logic;
	signal busstate    : std_logic_vector(1 downto 0);
	signal longword    : std_logic;
	signal nResetOut   : std_logic;
	signal FC          : std_logic_vector(2 downto 0);
	signal clr_berr    : std_logic;
	signal skipFetch   : std_logic;
	signal regin_out   : std_logic_vector(31 downto 0);
	signal CACR_out    : std_logic_vector(3 downto 0);
	signal D_CACHE_out : std_logic;
	signal VBR_out     : std_logic_vector(31 downto 0);

	signal ss_reg_index : std_logic_vector(3 downto 0) := (others => '0');
	signal ss_reg_data  : std_logic_vector(31 downto 0);
	signal ss_pc        : std_logic_vector(31 downto 0);
	signal ss_at_boundary : std_logic;
	signal ss_exe_pc    : std_logic_vector(31 downto 0);
	signal ss_sr        : std_logic_vector(15 downto 0);
	signal ss_usp       : std_logic_vector(31 downto 0);

	signal ss_wr_index : std_logic_vector(3 downto 0)  := (others => '0');
	signal ss_wr_data  : std_logic_vector(31 downto 0) := (others => '0');
	signal ss_wr_en    : std_logic := '0';
	signal ss_pc_wr    : std_logic := '0';
	signal ss_sr_wr    : std_logic := '0';
	signal ss_usp_wr   : std_logic := '0';
	signal ss_vbr_wr   : std_logic := '0';
	signal ss_cacr_wr  : std_logic := '0';
	signal ss_resume   : std_logic := '0';
	signal ss_mstack_used : std_logic;
	signal ss_halted      : std_logic;
	signal ss_sfc         : std_logic_vector(2 downto 0);
	signal ss_dfc         : std_logic_vector(2 downto 0);
	signal ss_cacr_hi     : std_logic_vector(6 downto 0);
	signal ss_mmu_wr      : std_logic := '0';
	signal ss_mmu_tc, ss_mmu_tt0, ss_mmu_tt1 : std_logic_vector(31 downto 0);
	signal ss_mmu_crp, ss_mmu_srp            : std_logic_vector(63 downto 0);
	signal ss_mmu_sr                         : std_logic_vector(15 downto 0);

	-- Testbench back door into the memory model, so a scan iteration can undo
	-- whatever the previous one's runaway CPU scribbled.
	signal poke_en   : std_logic := '0';
	signal poke_idx  : integer := 0;
	signal poke_data : std_logic_vector(15 downto 0) := (others => '0');

	signal running : boolean := true;
	signal errors  : integer := 0;

begin

	clk <= (not clk) after 5 ns when running else '0';

	dut : entity work.TG68KdotC_Kernel
		generic map (
			SR_Read        => 2,
			VBR_Stackframe => 2,
			extAddr_Mode   => 2,
			MUL_Mode       => 2,
			DIV_Mode       => 2,
			BitField       => 2,
			BarrelShifter  => 1,
			MUL_Hardware   => 1
		)
		port map (
			clk            => clk,
			nReset         => nReset,
			clkena_in      => clkena_in,
			data_in        => data_in,
			IPL            => "111",			-- active low: no interrupt pending
			IPL_autovector => '0',
			berr           => '0',
			CPU            => "11",				-- as cpu_wrapper instantiates it
			CPU030         => C030,
			MMU030         => CMMU,
			addr_out       => addr_out,
			data_write     => data_write,
			nWr            => nWr,
			nUDS           => nUDS,
			nLDS           => nLDS,
			busstate       => busstate,
			longword       => longword,
			nResetOut      => nResetOut,
			FC             => FC,
			clr_berr       => clr_berr,
			skipFetch      => skipFetch,
			regin_out      => regin_out,
			CACR_out       => CACR_out,
			D_CACHE_out    => D_CACHE_out,
			VBR_out        => VBR_out,
			ss_reg_index   => ss_reg_index,
			ss_reg_data    => ss_reg_data,
			ss_pc          => ss_pc,
			ss_at_boundary => ss_at_boundary,
			ss_exe_pc      => ss_exe_pc,
			ss_sr          => ss_sr,
			ss_usp         => ss_usp,
			ss_mstack_used => ss_mstack_used,
			ss_halted      => ss_halted,
			ss_sfc         => ss_sfc,
			ss_dfc         => ss_dfc,
			ss_cacr_hi     => ss_cacr_hi,
			ss_mmu_tc      => ss_mmu_tc,
			ss_mmu_tt0     => ss_mmu_tt0,
			ss_mmu_tt1     => ss_mmu_tt1,
			ss_mmu_crp     => ss_mmu_crp,
			ss_mmu_srp     => ss_mmu_srp,
			ss_mmu_sr      => ss_mmu_sr,
			ss_mmu_wr      => ss_mmu_wr,
			ss_wr_index    => ss_wr_index,
			ss_wr_data     => ss_wr_data,
			ss_wr_en       => ss_wr_en,
			ss_pc_wr       => ss_pc_wr,
			ss_sr_wr       => ss_sr_wr,
			ss_usp_wr      => ss_usp_wr,
			ss_vbr_wr      => ss_vbr_wr,
			ss_cacr_wr     => ss_cacr_wr,
			ss_resume      => ss_resume
		);

	-- Flat, one-cycle, zero-wait-state memory. That is exactly how the kernel
	-- behaves inside the core whenever clkena_in is high, so no wait-state
	-- modelling is needed to make the instruction stream realistic.
	mem_read : process (addr_out, mem)
	begin
		if is_x(addr_out(14 downto 1)) then
			data_in <= (others => '0');
		else
			data_in <= mem(conv_integer(addr_out(14 downto 1)));
		end if;
	end process;

	mem_write : process (clk)
		variable a : integer;
	begin
		if rising_edge(clk) then
			if poke_en = '1' then
				mem(poke_idx) <= poke_data;
			elsif clkena_in = '1' and busstate = "11"
			      and not is_x(addr_out(14 downto 1)) then
				a := conv_integer(addr_out(14 downto 1));
				if nUDS = '0' then
					mem(a)(15 downto 8) <= data_write(15 downto 8);
				end if;
				if nLDS = '0' then
					mem(a)(7 downto 0) <= data_write(7 downto 0);
				end if;
			end if;
		end if;
	end process;

	stim : process

		variable ok       : boolean;
		variable ok2      : boolean;
		variable f_pc     : std_logic_vector(31 downto 0);
		variable f_opc    : std_logic_vector(15 downto 0);
		variable w_opc    : std_logic_vector(15 downto 0);
		variable red_pass : integer := 0;
		variable grn_pass : integer := 0;
		-- PHASE 4 bookkeeping.
		variable rt_ok    : boolean;
		variable rt_n     : integer;
		variable rt_stray : std_logic_vector(31 downto 0);
		variable rt_good  : integer := 0;
		variable rt_line  : string(1 to 80) := (others => ' ');
		variable rt_first : std_logic_vector(31 downto 0) := (others => '0');
		variable rt_pc    : std_logic_vector(31 downto 0);
		variable rt_ff    : std_logic_vector(31 downto 0);
		variable rt_shown : integer := 0;
		variable bcount, bidle, bgap, gap : integer := 0;
		variable summary  : string(1 to 256) := (others => ' ');

		function hex(v : std_logic_vector) return string is
			constant digits : string(1 to 16) := "0123456789ABCDEF";
			variable nvec   : std_logic_vector(v'length-1 downto 0) := v;
			variable s      : string(1 to (v'length+3)/4);
			variable d      : integer;
			variable bad    : boolean;
		begin
			for i in s'range loop
				d   := 0;
				bad := false;
				for b in 3 downto 0 loop
					d := d * 2;
					case nvec(nvec'left - (i-1)*4 - (3-b)) is
						when '1' | 'H' => d := d + 1;
						when '0' | 'L' => null;
						when others    => bad := true;
					end case;
				end loop;
				if bad then
					s(i) := 'x';
				else
					s(i) := digits(d + 1);
				end if;
			end loop;
			return s;
		end function;

		impure function meml(byteaddr : integer) return std_logic_vector is
			variable r : std_logic_vector(31 downto 0);
		begin
			r(31 downto 16) := mem(byteaddr/2);
			r(15 downto 0)  := mem(byteaddr/2 + 1);
			return r;
		end function;

		procedure note(s : string) is
			variable ln : line;
		begin
			write(ln, s);
			writeline(output, ln);
		end procedure;

		procedure step(n : integer) is
		begin
			for i in 1 to n loop
				wait until rising_edge(clk);
			end loop;
		end procedure;

		procedure check(cond : boolean; what : string) is
		begin
			if cond then
				note("  ok   : " & what);
			else
				note("  FAIL : " & what);
				errors <= errors + 1;
				wait for 0 ns;
			end if;
		end procedure;

		-- Put the program and the sentinels back the way the assembler left
		-- them. A restore that goes wrong writes wherever it likes.
		procedure reload_image is
		begin
			for i in 0 to RELOADW-1 loop
				poke_idx  <= i;
				poke_data <= IMAGE(i);
				poke_en   <= '1';
				wait until rising_edge(clk);
			end loop;
			poke_en <= '0';
		end procedure;

		-- Drive the savestate write ports the way ss_ctrl does: the CPU clock
		-- enable is already low, one port strobed at a time.
		procedure ss_write_regs is
			variable v : std_logic_vector(31 downto 0);
		begin
			for i in 0 to 15 loop
				if i = 15 then
					v := SS_A7_VAL;					-- A7 has to stay a usable stack
				else
					v := X"5EED00" & conv_std_logic_vector(i, 8);
				end if;
				ss_wr_index <= conv_std_logic_vector(i, 4);
				ss_wr_data  <= v;
				ss_wr_en    <= '1';
				wait until rising_edge(clk);
				ss_wr_en    <= '0';
				wait until rising_edge(clk);
			end loop;

			ss_wr_data <= SS_USP_VAL;
			ss_usp_wr  <= '1';
			wait until rising_edge(clk);
			ss_usp_wr  <= '0';

			ss_wr_data <= X"0000" & SS_SR_VAL;
			ss_sr_wr   <= '1';
			wait until rising_edge(clk);
			ss_sr_wr   <= '0';

			ss_wr_data <= X"00000000";
			ss_vbr_wr  <= '1';
			wait until rising_edge(clk);
			ss_vbr_wr  <= '0';

			ss_wr_data <= X"00000000";
			ss_cacr_wr <= '1';
			wait until rising_edge(clk);
			ss_cacr_wr <= '0';

			ss_wr_data <= SS_PC_VAL;
			ss_pc_wr   <= '1';
			wait until rising_edge(clk);
			ss_pc_wr   <= '0';
			wait until rising_edge(clk);
		end procedure;

		-- CAPTURE the architectural state the way ss_ctrl's save does: read the
		-- register file through the export port and take ss_exe_pc as the PC.
		-- NOT ss_pc: TG68_PC is a fetch pointer that has already run into the
		-- current instruction's extension words.
		procedure ss_capture(regs : out reg_array;
		                     pc   : out std_logic_vector(31 downto 0)) is
		begin
			for i in 0 to 15 loop
				ss_reg_index <= conv_std_logic_vector(i, 4);
				wait until rising_edge(clk);
				wait until rising_edge(clk);
				regs(i) := ss_reg_data;
			end loop;
			pc := ss_exe_pc;
		end procedure;

		-- Write back exactly what was captured. Same ports, same order as
		-- ss_write_regs; only the values differ.
		procedure ss_restore(regs : in reg_array;
		                     pc   : in std_logic_vector(31 downto 0)) is
		begin
			for i in 0 to 15 loop
				ss_wr_index <= conv_std_logic_vector(i, 4);
				ss_wr_data  <= regs(i);
				ss_wr_en    <= '1';
				wait until rising_edge(clk);
				ss_wr_en    <= '0';
				wait until rising_edge(clk);
			end loop;

			ss_wr_data <= pc;
			ss_pc_wr   <= '1';
			wait until rising_edge(clk);
			ss_pc_wr   <= '0';
			wait until rising_edge(clk);
		end procedure;

		-- Step the clock, printing the first `n` code-fetch cycles seen, and
		-- hand back the very first one. busstate="00" is the kernel's code
		-- space; the address is whatever the fetch pipeline put on the bus.
		-- `want` is watched over the whole window, not just the printed part,
		-- so a caller can dump the trace and assert on an address inside it
		-- without the dump swallowing the fetch it wanted to check.
		procedure trace_fetches(n         : integer;
		                        timeout   : integer;
		                        want      : std_logic_vector(31 downto 0);
		                        pc        : out std_logic_vector(31 downto 0);
		                        opc       : out std_logic_vector(15 downto 0);
		                        found     : out boolean;
		                        want_opc  : out std_logic_vector(15 downto 0);
		                        want_seen : out boolean) is
			variable seen : integer := 0;
			variable ws   : boolean := false;
			variable wo   : std_logic_vector(15 downto 0) := (others => '0');
		begin
			found := false;
			pc    := (others => '0');
			opc   := (others => '0');
			for i in 1 to timeout loop
				wait until rising_edge(clk);
				if clkena_in = '1' and busstate = "00" then
					if seen = 0 then
						pc    := addr_out;
						opc   := data_in;
						found := true;
					end if;
					if seen < n then
						note("       fetch[" & integer'image(seen) & "] $" &
						     hex(addr_out) & " -> $" & hex(data_in));
					end if;
					if addr_out = want and not ws then
						wo := data_in;
						ws := true;
					end if;
					seen := seen + 1;
					exit when seen >= n and ws;
				end if;
			end loop;
			want_opc  := wo;
			want_seen := ws;
		end procedure;

		-- Wait for a code fetch at a specific address, and stop there.
		procedure wait_fetch_at(want    : std_logic_vector(31 downto 0);
		                        timeout : integer;
		                        opc     : out std_logic_vector(15 downto 0);
		                        found   : out boolean) is
		begin
			found := false;
			opc   := (others => '0');
			for i in 1 to timeout loop
				wait until rising_edge(clk);
				if clkena_in = '1' and busstate = "00" and addr_out = want then
					opc   := data_in;
					found := true;
					exit;
				end if;
			end loop;
		end procedure;

		-- Write one word of memory through the back door, by byte address.
		procedure poke_w(byteaddr : integer; w : std_logic_vector(15 downto 0)) is
		begin
			poke_idx  <= byteaddr / 2;
			poke_data <= w;
			poke_en   <= '1';
			wait until rising_edge(clk);
			poke_en   <= '0';
		end procedure;

		-- Hold reset, put the image back, point the reset PC at $780 and leave
		-- the caller to poke a program there, then release with boot_go.
		procedure boot_prep is
		begin
			nReset    <= '0';
			clkena_in <= '1';
			ss_resume <= '0';
			step(6);
			reload_image;
			poke_w(16#04#, X"0000");
			poke_w(16#06#, X"0780");
		end procedure;

		procedure boot_go is
		begin
			step(4);
			nReset <= '1';
		end procedure;

		-- One complete experiment: boot, run into the main loop, freeze
		-- `freeze` clocks later, push the whole architectural state in,
		-- optionally pulse ss_resume, let go, and decide whether the machine
		-- came back.
		procedure do_restore(freeze     : integer;
		                     use_resume : boolean;
		                     verbose    : integer;
		                     pass       : out boolean;
		                     fpc        : out std_logic_vector(31 downto 0);
		                     fopc       : out std_logic_vector(15 downto 0)) is
			variable lpc  : std_logic_vector(31 downto 0);
			variable lopc : std_logic_vector(15 downto 0);
			variable wo   : std_logic_vector(15 downto 0);
			variable f    : boolean;
			variable w    : boolean;
		begin
			nReset    <= '0';
			clkena_in <= '1';
			ss_resume <= '0';
			step(6);
			reload_image;
			step(4);
			nReset <= '1';
			wait_fetch_at(ADDR_MAIN, 400, lopc, f);
			assert f report "tg68k_ss_tb: the CPU never reached $400"
				severity failure;
			step(60 + freeze);

			clkena_in <= '0';
			step(4);
			ss_write_regs;

			if use_resume then
				ss_resume <= '1';
				wait until rising_edge(clk);
				ss_resume <= '0';
			end if;
			step(2);
			clkena_in <= '1';

			trace_fetches(verbose, 400, ADDR_RESTORED, lpc, lopc, f, wo, w);
			step(800);

			fpc  := lpc;
			fopc := lopc;
			pass := f and (lpc = ADDR_RESTORED) and (lopc = OPC_RESTORED)
			        and (meml(RES_D3) = EXP_D3) and (meml(RES_A2) = EXP_A2)
			        and (meml(RES_TAG) = EXP_TAG);
		end procedure;

		-- ROUND TRIP: freeze, capture the state the way a save does, write the
		-- SAME state back, resume, and require the program to carry on.
		--
		-- Capturing and restoring an unchanged machine has to be a no-op. If it
		-- is not, a savestate cannot work however correct everything around it
		-- is -- and the existing scan above cannot see it, because it restores
		-- a PC the test chose rather than the one the CPU was at.
		--
		-- "Carried on" is judged by where the CPU fetches: the main loop lives
		-- in $400..$4FF, so every code fetch after the restore must land there.
		-- A CPU resumed mid-instruction decodes an operand as an opcode and
		-- wanders out of that range almost immediately.
		procedure do_roundtrip(freeze  : integer;
		                       pass    : out boolean;
		                       fetches : out integer;
		                       strayp  : out std_logic_vector(31 downto 0);
		                       pcap    : out std_logic_vector(31 downto 0);
		                       firstf  : out std_logic_vector(31 downto 0);
		                       verbose : boolean := false) is
			variable regs  : reg_array;
			variable pc    : std_logic_vector(31 downto 0);
			variable lopc  : std_logic_vector(15 downto 0);
			variable f     : boolean;
			variable n     : integer := 0;
			variable stray : std_logic_vector(31 downto 0) := (others => '0');
			variable ok    : boolean := true;
			variable ff    : std_logic_vector(31 downto 0) := (others => '0');
			variable mk0   : std_logic_vector(31 downto 0);
			variable sc0   : std_logic_vector(31 downto 0);
		begin
			nReset    <= '0';
			clkena_in <= '1';
			ss_resume <= '0';
			step(6);
			reload_image;
			step(4);
			nReset <= '1';
			wait_fetch_at(ADDR_MAIN, 400, lopc, f);
			assert f report "tg68k_ss_tb: the CPU never reached $400"
				severity failure;
			step(60 + freeze);

			-- Freeze only where the CPU says it is between instructions. Without
			-- this the freeze lands mid-instruction and TG68_PC is an operand
			-- address, which is the whole bug this phase exists to catch.
			for i in 1 to 200 loop
				exit when ss_at_boundary = '1';
				wait until rising_edge(clk);
			end loop;

			clkena_in <= '0';
			step(4);
			ss_capture(regs, pc);
			if verbose then
				note("       captured PC $" & hex(pc) &
				     "  A7 $" & hex(regs(15)) &
				     "  D0 $" & hex(regs(0)) &
				     "  D1 $" & hex(regs(1)) &
				     "  D2 $" & hex(regs(2)) &
				     "  A0 $" & hex(regs(8)));
				note("       stack: [A7] $" & hex(meml(conv_integer(regs(15)(15 downto 0)))) &
				     "  [A7+4] $" & hex(meml(conv_integer(regs(15)(15 downto 0)) + 4)));
			end if;
			ss_restore(regs, pc);
			mk0 := meml(MAIN_MARK);
			sc0 := meml(SCRATCH);
			ss_resume <= '1';
			wait until rising_edge(clk);
			ss_resume <= '0';
			step(2);
			clkena_in <= '1';

			for i in 1 to 600 loop
				wait until rising_edge(clk);
				if clkena_in = '1' and busstate = "00" then
					n := n + 1;
					if n = 1 then ff := addr_out; end if;
					if verbose and n <= 24 then
						note("       fetch[" & integer'image(n) & "] $" &
						     hex(addr_out) & " -> $" & hex(data_in) &
						     "  A7 $" & hex(ss_reg_data));
					end if;
					if addr_out(31 downto 8) /= X"000004" then
						if ok then stray := addr_out; end if;
						ok := false;
					end if;
				end if;
			end loop;

			-- Staying inside $4xx only says the CPU is fetching somewhere
			-- plausible. The loop also has to RETIRE instructions: both of its
			-- memory side effects must move, or a CPU spinning on a bad branch
			-- inside the loop would pass.
			if verbose then
				note("       MAIN_MARK $" & hex(mk0) & " -> $" & hex(meml(MAIN_MARK)) &
				     "   SCRATCH $" & hex(sc0) & " -> $" & hex(meml(SCRATCH)));
			end if;
			pass    := ok and (n > 8)
			           and (meml(MAIN_MARK) /= mk0)
			           and (meml(SCRATCH) /= sc0);
			fetches := n;
			strayp  := stray;
			pcap    := pc;
			firstf  := ff;
		end procedure;

	begin
		note("");
		note("=== tg68k_ss_tb ===");

		----------------------------------------------------------------------
		note("");
		note("PHASE 1 -- sanity: does the bench run the CPU at all?");
		----------------------------------------------------------------------
		nReset <= '0';
		step(10);
		nReset <= '1';

		-- The kernel's reset seeds a synthesised "movea.l (0).l,a7 / jmp nn.l"
		-- with PC=4, so the reset vectors are read first and the entry point
		-- held at address 4 is the first real instruction fetch.
		trace_fetches(6, 400, ADDR_MAIN, f_pc, f_opc, ok, w_opc, ok2);
		check(ok, "the CPU produces code fetches after reset");
		check(f_pc = X"00000004",
		      "the first code fetch is address 4 -- reset's synthesised jmp " &
		      "reading its target");
		check(ok2, "a code fetch lands on the reset vector target $00000400");
		check(w_opc = OPC_MAIN,
		      "the word fetched there is move.l #imm,d0 ($203C)");

		step(80);
		note("       MAIN_MARK = $" & hex(meml(MAIN_MARK)));
		check(meml(MAIN_MARK)(31 downto 8) = X"111111",
		      "the main loop writes its heartbeat to $600");
		check(meml(MAIN_MARK) /= X"11111111",
		      "the heartbeat has been incremented, so the instructions at " &
		      "$400 really executed");

		----------------------------------------------------------------------
		note("");
		----------------------------------------------------------------------
		note("");
		note("PHASE 1b -- where can the hardware park?");
		----------------------------------------------------------------------
		-- cpu_wrapper used to park the CPU at busstate="01" -- its cpu_req
		-- low, no bus cycle outstanding. That is NOT an instruction boundary,
		-- and the round trip below scores 66/80 from there.
		--
		-- The two conditions cannot simply be ANDed: measured here, an
		-- instruction boundary NEVER coincides with an idle bus, so a park
		-- waiting for both would spin until ss_ctrl timed out. The park has to
		-- be the boundary alone, letting the outstanding fetch settle
		-- unconsumed -- which is safe because ss_resume re-fetches from the
		-- restored PC anyway. What this phase has to guarantee is that a
		-- boundary always comes along soon enough for the park to terminate.
		nReset <= '0';
		step(6);
		reload_image;
		step(4);
		nReset <= '1';
		wait_fetch_at(ADDR_MAIN, 400, f_opc, ok);
		bcount := 0;
		bidle  := 0;
		bgap   := 0;
		gap    := 0;
		for i in 1 to 4000 loop
			wait until rising_edge(clk);
			gap := gap + 1;
			if clkena_in = '1' and ss_at_boundary = '1' then
				bcount := bcount + 1;
				if busstate = "01" then
					bidle := bidle + 1;
				end if;
				if gap > bgap then bgap := gap; end if;
				gap := 0;
			end if;
		end loop;
		note("       boundaries: " & integer'image(bcount) &
		     "   of which with an idle bus: " & integer'image(bidle) &
		     "   longest wait for one: " & integer'image(bgap) & " clocks");
		check(bcount > 0, "instruction boundaries occur while the CPU runs");
		check(bgap > 0 and bgap < 600,
		      "one is never more than 600 clocks away, so a park terminates");
		check(bidle = 0,
		      "and none of them has an idle bus -- so the park condition " &
		      "cannot also wait for cpu_req to drop");

		note("PHASE 2 -- RED: restore at " & integer'image(FREEZE_N) &
		     " freeze points, ss_resume never pulsed");
		----------------------------------------------------------------------
		-- One verbose case first, so there is a readable trace of the failure.
		note("       freeze point 0, first code fetches after the release:");
		do_restore(FREEZE_LO, false, 10, ok, f_pc, f_opc);
		note("       RES_D3 = $" & hex(meml(RES_D3)) &
		     "  RES_A2 = $" & hex(meml(RES_A2)) &
		     "  RES_TAG = $" & hex(meml(RES_TAG)));
		note("       PC now = $" & hex(ss_pc));

		for i in 0 to FREEZE_N-1 loop
			do_restore(FREEZE_LO + i, false, 0, ok, f_pc, f_opc);
			if ok then
				red_pass     := red_pass + 1;
				summary(i+1) := '.';
			else
				summary(i+1) := 'X';
			end if;
		end loop;
		note("       per freeze point (. = restored, X = did not): " &
		     summary(1 to FREEZE_N));
		note("       " & integer'image(red_pass) & " of " &
		     integer'image(FREEZE_N) &
		     " freeze points restored correctly without ss_resume");
		check(red_pass < FREEZE_N,
		      "at least one freeze point fails without ss_resume " &
		      "(a failure here means ss_resume is not load-bearing)");

		----------------------------------------------------------------------
		note("");
		note("PHASE 3 -- GREEN: the same scan with ss_resume pulsed");
		----------------------------------------------------------------------
		note("       freeze point 0, first code fetches after the resume:");
		do_restore(FREEZE_LO, true, 10, ok, f_pc, f_opc);
		note("       RES_D3 = $" & hex(meml(RES_D3)) &
		     "  RES_A2 = $" & hex(meml(RES_A2)) &
		     "  RES_TAG = $" & hex(meml(RES_TAG)));
		note("       PC now = $" & hex(ss_pc));
		check(f_pc = ADDR_RESTORED,
		      "the first code fetch is the restored PC $00000500");
		check(f_opc = OPC_RESTORED,
		      "the first opcode word is move.l d3,$0604 ($21C3)");
		check(meml(RES_D3) = EXP_D3, "the restored D3 reached memory intact");
		check(meml(RES_A2) = EXP_A2, "the restored A2 reached memory intact");
		check(meml(RES_TAG) = EXP_TAG,
		      "the third instruction ran (the fixed tag was written)");

		summary := (others => ' ');
		for i in 0 to FREEZE_N-1 loop
			do_restore(FREEZE_LO + i, true, 0, ok, f_pc, f_opc);
			if ok then
				grn_pass     := grn_pass + 1;
				summary(i+1) := '.';
			else
				summary(i+1) := 'X';
				note("       freeze point " & integer'image(i) &
				     " did not resume: first fetch $" & hex(f_pc) &
				     " -> $" & hex(f_opc));
			end if;
		end loop;
		note("       per freeze point (. = restored, X = did not): " &
		     summary(1 to FREEZE_N));
		check(grn_pass = FREEZE_N,
		      "every freeze point resumes correctly with ss_resume (" &
		      integer'image(grn_pass) & "/" & integer'image(FREEZE_N) & ")");

		----------------------------------------------------------------------
		note("");
		----------------------------------------------------------------------
		note("");
		note("PHASE 3b -- ss_resume clears the boundary, so a park must latch");
		----------------------------------------------------------------------
		-- cpu_wrapper holds the CPU with ss_arm & ss_at_boundary. That signal
		-- is decodeOPC, and the ss_resume re-seed clears decodeOPC -- so the
		-- boundary goes false exactly when a restore re-seeds the sequencer.
		-- A hold gated on it live would release the CPU right there, with
		-- chip RAM still being written (the state vector is restored first).
		-- The hold is latched for this reason; this phase is what says so.
		nReset    <= '0';
		clkena_in <= '1';
		ss_resume <= '0';
		step(6);
		reload_image;
		step(4);
		nReset <= '1';
		wait_fetch_at(ADDR_MAIN, 400, f_opc, ok);
		step(60);
		-- ss_at_boundary is a concurrent assignment off decodeOPC, so reading
		-- it the instant the process wakes at a clock edge returns the value
		-- from BEFORE that edge. Settle first, or the bench tests a signal one
		-- clock stale and reports a design fault that is its own race.
		for i in 1 to 200 loop
			wait until rising_edge(clk);
			wait for 1 ns;
			exit when ss_at_boundary = '1';
		end loop;
		check(ss_at_boundary = '1', "the CPU reaches an instruction boundary");
		clkena_in <= '0';
		step(4);
		wait for 1 ns;
		check(ss_at_boundary = '1',
		      "the boundary holds while the CPU clock enable is low");
		ss_resume <= '1';
		wait until rising_edge(clk);
		ss_resume <= '0';
		wait until rising_edge(clk);
		wait for 1 ns;
		check(ss_at_boundary = '0',
		      "ss_resume CLEARS it -- a live-gated park would let the CPU go " &
		      "here, mid-restore");

		note("PHASE 4 -- round trip: capture the state and put it straight back");
		----------------------------------------------------------------------
		for k in 0 to 79 loop
			do_roundtrip(k, rt_ok, rt_n, rt_stray, rt_pc, rt_ff);
			if not rt_ok and rt_shown < 4 then
				note("       point " & integer'image(k) &
				     ": captured PC $" & hex(rt_pc) &
				     "  first fetch $" & hex(rt_ff) &
				     "  stray $" & hex(rt_stray));
				rt_shown := rt_shown + 1;
			end if;
			if rt_ok then
				rt_good := rt_good + 1;
				rt_line(k+1) := '.';
			else
				rt_line(k+1) := 'X';
				if rt_first = X"00000000" then rt_first := rt_stray; end if;
			end if;
		end loop;
		note("       per freeze point (. = kept running, X = derailed): " & rt_line);
		if rt_good < 80 then
			note("       first stray fetch was at $" & hex(rt_first));
		end if;
		check(rt_good = 80,
		      "capture and restore in place is a no-op (" &
		      integer'image(rt_good) & "/80)");

		if rt_good < 80 then
			for k in 0 to 79 loop
				if rt_line(k+1) = 'X' then
					note("");
					note("       -- replaying freeze point " & integer'image(k) &
					     " with the fetch trace --");
					do_roundtrip(k, rt_ok, rt_n, rt_stray, rt_pc, rt_ff, true);
					exit;
				end if;
			end loop;
		end if;

		-----------------------------------------------------------------------
		note("PHASE 5 -- the master stack flag, and a restore out of a halted CPU");
		-- ss_mstack_used is what AmigaCD.sv refuses a save on: MSP and ISP are
		-- not in the state vector. It must stay low on a program that does not
		-- touch the master stack, rise on MOVEC to MSP and on setting M, and
		-- clear on reset.
		nReset    <= '0';
		clkena_in <= '1';
		step(6);
		reload_image;
		step(4);
		nReset <= '1';
		wait_fetch_at(ADDR_MAIN, 400, f_opc, ok);
		step(2000);
		check(ok and ss_mstack_used = '0',
		      "the test program does not raise the master stack flag");

		boot_prep;
		poke_w(16#780#, X"4E7B");		-- movec d0,msp
		poke_w(16#782#, X"0803");
		poke_w(16#784#, X"60FE");		-- bra.s *
		boot_go;
		step(300);
		check(ss_mstack_used = '1', "MOVEC to MSP raises the master stack flag");

		boot_prep;
		poke_w(16#780#, X"007C");		-- ori.w #$1000,sr (M)
		poke_w(16#782#, X"1000");
		poke_w(16#784#, X"60FE");		-- bra.s *
		boot_go;
		step(300);
		check(ss_mstack_used = '1', "setting M raises the master stack flag");
		nReset <= '0';
		step(4);
		check(ss_mstack_used = '0', "reset clears the master stack flag");

		-- A double address error halts the 68020 until reset: JMP to an odd
		-- address, with the address error vector odd as well. A restore must
		-- still bring the machine back -- it is the way out of a halted
		-- machine short of a reset -- so the ss_resume re-seed clears the halt.
		boot_prep;
		poke_w(16#0C#, X"0000");		-- vector 3, address error -> $0781
		poke_w(16#0E#, X"0781");
		poke_w(16#780#, X"4EF9");		-- jmp $0901.l
		poke_w(16#782#, X"0000");
		poke_w(16#784#, X"0901");
		boot_go;
		step(400);
		check(ss_halted = '1', "a double address error halts the CPU");
		bcount := 0;
		for i in 1 to 200 loop
			wait until rising_edge(clk);
			if clkena_in = '1' and busstate /= "01" then bcount := bcount + 1; end if;
		end loop;
		check(bcount = 0, "the halted CPU makes no bus cycles");

		clkena_in <= '0';
		step(4);
		ss_write_regs;
		ss_resume <= '1';
		wait until rising_edge(clk);
		ss_resume <= '0';
		step(2);
		clkena_in <= '1';
		check(ss_halted = '0', "the restore re-seed clears the halt");
		wait_fetch_at(ADDR_RESTORED, 400, f_opc, ok);
		step(800);
		check(ok and f_opc = OPC_RESTORED and meml(RES_D3) = EXP_D3 and
		      meml(RES_A2) = EXP_A2 and meml(RES_TAG) = EXP_TAG,
		      "a restore out of the halted CPU runs the restored program");
		-----------------------------------------------------------------------
		note("PHASE 6 -- SFC and DFC in the state vector");
		-- MOVES takes its alternate-space function code from these; before
		-- 2026-10-18 the vector did not carry them, so a restore left the
		-- running machine's values in place. Capture is the ss_sfc/ss_dfc
		-- export; restore rides on the CACR strobe, bits 6:4 and 9:7.
		boot_prep;
		poke_w(16#780#, X"7005");		-- moveq #5,d0
		poke_w(16#782#, X"4E7B");		-- movec d0,sfc
		poke_w(16#784#, X"0000");
		poke_w(16#786#, X"7003");		-- moveq #3,d0
		poke_w(16#788#, X"4E7B");		-- movec d0,dfc
		poke_w(16#78A#, X"0001");
		poke_w(16#78C#, X"60FE");		-- bra.s *
		boot_go;
		step(400);
		check(ss_sfc = "101" and ss_dfc = "011",
		      "MOVEC to SFC/DFC shows on the capture export");
		clkena_in <= '0';
		step(4);
		ss_wr_data <= X"00000" & "00" & "110" & "010" & "0001";	-- DFC 6, SFC 2, CACR 1
		ss_cacr_wr <= '1';
		wait until rising_edge(clk);
		ss_cacr_wr <= '0';
		step(2);
		check(ss_sfc = "010" and ss_dfc = "110",
		      "the restore's CACR write puts SFC and DFC back");
		clkena_in <= '1';
		-----------------------------------------------------------------------
		note("PHASE 7 -- the rest of CACR in the state vector");
		-- ss_cacr_hi is {CACR_DC_owned, CACR_DC, CACR 13, 12, 9, 8, 4}, restored
		-- from bits 16:10 of the CACR strobe. On the 68030 the restore masks
		-- CACR as MOVEC does, so bits 3:2 (clear strobes there) do not land;
		-- on the 68020 bits 13:4 do not exist. The D-cache heuristic pair is
		-- restored on both. Before 2026-10-19 none of this was in the vector.
		boot_prep;
		poke_w(16#780#, X"70FF");		-- moveq #-1,d0
		poke_w(16#782#, X"4E7B");		-- movec d0,cacr
		poke_w(16#784#, X"0002");
		poke_w(16#786#, X"60FE");		-- bra.s *
		boot_go;
		step(400);
		if C030 = '1' then
			check(ss_cacr_hi = "1111111",
			      "MOVEC to CACR shows the 68030's upper bits on the capture export");
		else
			check(ss_cacr_hi = "1100000",
			      "MOVEC to CACR shows only the heuristic pair on the 68020");
		end if;
		clkena_in <= '0';
		step(4);
		-- owned 0, DC 1, C13 0, C12 1, C9 0, C8 1, C4 1; CACR 3:0 all set
		ss_wr_data <= X"000" & "000" & "0101011" & "000" & "000" & "1111";
		ss_cacr_wr <= '1';
		wait until rising_edge(clk);
		ss_cacr_wr <= '0';
		step(2);
		if C030 = '1' then
			check(ss_cacr_hi = "0101011" and CACR_out = "0011",
			      "the 68030 restore puts the upper bits back and masks 3:2");
		else
			check(ss_cacr_hi = "0100000" and CACR_out = "1111",
			      "the 68020 restore keeps CACR 3:0 and drops 13:4");
		end if;
		check(D_CACHE_out = '1', "not owned restores the D-cache on");
		-- owned 1, DC 0, C13 1, C12 1, C9 0, C8 1, C4 0
		ss_wr_data <= X"000" & "000" & "1011010" & "000" & "000" & "0000";
		ss_cacr_wr <= '1';
		wait until rising_edge(clk);
		ss_cacr_wr <= '0';
		step(2);
		if C030 = '1' then
			check(ss_cacr_hi = "1011010", "a second pattern, 68030");
		else
			check(ss_cacr_hi = "1000000", "a second pattern, 68020");
		end if;
		check(D_CACHE_out = '0', "owned with DC clear restores the D-cache off");
		clkena_in <= '1';
		-----------------------------------------------------------------------
		note("PHASE 8 -- the 68030's MMU registers in the state vector");
		-- Format 1.5. Two page tables, 4 KB pages, one level (TC $80CC8000:
		-- PS 12, IS 12, TIA 8), identity everywhere except logical page 5:
		--   table A at $6000 maps page 5 to physical page 4 ($4000, CAFEF00D)
		--   table B at $6400 maps page 5 to itself      ($5000, 0BADBEEF)
		-- Machine A loads CRP_A and TC and reads $5000: CAFEF00D, and the
		-- capture export shows its TC and CRP. Machine B does the same through
		-- table B, which leaves page 5 -> 5 in its ATC, and is frozen. A's MMU
		-- registers are then restored into B through the stage and ss_resume,
		-- and the restored program reads $5000 again: CAFEF00D only if the
		-- registers landed AND the ATC was flushed -- the stale entry would
		-- give 0BADBEEF, since the ATC is not keyed by the root pointer.
		if CMMU = '1' then
			boot_prep;
			for i in 0 to 255 loop
				if i mod 8 = 5 then
					poke_w(16#6000# + i*4, X"0000"); poke_w(16#6002# + i*4, X"4001");
				else
					poke_w(16#6000# + i*4, conv_std_logic_vector((i*16#1000#) / 16#10000#, 16));
					poke_w(16#6002# + i*4, conv_std_logic_vector((i*16#1000#) mod 16#10000# + 1, 16));
				end if;
				poke_w(16#6400# + i*4, conv_std_logic_vector((i*16#1000#) / 16#10000#, 16));
				poke_w(16#6402# + i*4, conv_std_logic_vector((i*16#1000#) mod 16#10000# + 1, 16));
			end loop;
			poke_w(16#4000#, X"CAFE"); poke_w(16#4002#, X"F00D");
			poke_w(16#5000#, X"0BAD"); poke_w(16#5002#, X"BEEF");
			poke_w(16#700#, X"7FFF"); poke_w(16#702#, X"0002");	-- CRP A: limit $7FFF, 4-byte table
			poke_w(16#704#, X"0000"); poke_w(16#706#, X"6000");
			poke_w(16#708#, X"80CC"); poke_w(16#70A#, X"8000");	-- TC
			poke_w(16#710#, X"7FFF"); poke_w(16#712#, X"0002");	-- CRP B
			poke_w(16#714#, X"0000"); poke_w(16#716#, X"6400");
			poke_w(16#780#, X"41F8"); poke_w(16#782#, X"0700");	-- lea $0700.w,a0
			poke_w(16#784#, X"F010"); poke_w(16#786#, X"4C00");	-- pmove (a0),crp
			poke_w(16#788#, X"41F8"); poke_w(16#78A#, X"0708");	-- lea $0708.w,a0
			poke_w(16#78C#, X"F010"); poke_w(16#78E#, X"4000");	-- pmove (a0),tc
			poke_w(16#790#, X"2038"); poke_w(16#792#, X"5000");	-- move.l $5000.w,d0
			poke_w(16#794#, X"21C0"); poke_w(16#796#, X"0610");	-- move.l d0,$0610.w
			poke_w(16#798#, X"60FE");						-- bra.s *
			-- The restored program, identity-mapped page 0 in both tables.
			poke_w(16#7E0#, X"2238"); poke_w(16#7E2#, X"5000");	-- move.l $5000.w,d1
			poke_w(16#7E4#, X"21C1"); poke_w(16#7E6#, X"0614");	-- move.l d1,$0614.w
			poke_w(16#7E8#, X"60FE");						-- bra.s *
			poke_w(16#610#, X"0000"); poke_w(16#612#, X"0000");
			boot_go;
			step(800);
			check(meml(16#610#) = X"CAFEF00D", "machine A reads $5000 through table A");
			check(ss_mmu_tc = X"80CC8000" and ss_mmu_crp = X"7FFF000200006000",
			      "the capture export shows TC and CRP");
			-- Machine B: the same program on table B.
			poke_w(16#784#, X"F010");
			poke_w(16#780#, X"41F8"); poke_w(16#782#, X"0710");	-- lea $0710.w,a0
			poke_w(16#610#, X"0000"); poke_w(16#612#, X"0000");
			poke_w(16#614#, X"0000"); poke_w(16#616#, X"0000");
			nReset <= '0';
			step(6);
			nReset <= '1';
			step(800);
			check(meml(16#610#) = X"0BADBEEF", "machine B reads $5000 through table B");
			-- Freeze B and restore A's MMU registers, a PC at $7E0 and a
			-- supervisor SR, then re-seed.
			clkena_in <= '0';
			step(4);
			ss_wr_data <= X"000007E0"; ss_pc_wr <= '1';
			wait until rising_edge(clk);
			ss_pc_wr <= '0';
			ss_wr_data <= X"00002700"; ss_sr_wr <= '1';
			wait until rising_edge(clk);
			ss_sr_wr <= '0';
			for i in 0 to 7 loop
				ss_wr_index <= conv_std_logic_vector(i, 4);
				case i is
					when 0 => ss_wr_data <= X"80CC8000";
					when 1 => ss_wr_data <= X"00000000";
					when 2 => ss_wr_data <= X"00000000";
					when 3 => ss_wr_data <= X"7FFF0002";
					when 4 => ss_wr_data <= X"00006000";
					when 5 => ss_wr_data <= X"00000000";
					when 6 => ss_wr_data <= X"00000000";
					when others => ss_wr_data <= X"00000000";
				end case;
				ss_mmu_wr <= '1';
				wait until rising_edge(clk);
				ss_mmu_wr <= '0';
			end loop;
			step(2);
			check(ss_mmu_crp = X"7FFF000200006400",
			      "the MMU writes are staged: CRP is B's until the re-seed");
			ss_resume <= '1';
			wait until rising_edge(clk);
			ss_resume <= '0';
			step(2);
			check(ss_mmu_crp = X"7FFF000200006000" and ss_mmu_tc = X"80CC8000",
			      "the re-seed applies the staged MMU registers");
			clkena_in <= '1';
			step(800);
			check(meml(16#614#) = X"CAFEF00D",
			      "the restored machine translates through A's table, not B's ATC");
		else
			note("  (skipped: needs CPU030_G=1 MMU_G=1)");
		end if;

		if errors = 0 then
			note("RUN: PASS");
		else
			note("RUN: FAIL (" & integer'image(errors) & " checks failed)");
		end if;
		running <= false;
		wait for 100 ns;
		assert errors = 0
			report "tg68k_ss_tb: " & integer'image(errors) & " checks failed"
			severity failure;
		wait;
	end process;

end architecture;
