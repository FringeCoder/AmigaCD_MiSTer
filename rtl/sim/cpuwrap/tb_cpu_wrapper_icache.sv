// cpu_wrapper: the 68020 instruction cache (Minimig-AGA 09226f7) and the CD32
// FMV board's ROM.
//
// Run v31 (FringeCoder/AmigaCD docs/fmv-plan.md) found the FMV driver's copy
// loop at 0x203b5a -- move.w (a1)+,(a3) / dbf d0 -- taking about 5 us a word,
// 32 % of the 68k's time. The board sits behind the chip bus bridge, and the
// cache took only chip RAM fetches ($000000-$1FFFFF): every fetch from the
// cartridge ROM was a chip bus cycle, where a real 68EC020 runs that loop out
// of its cache. This bench checks that ROM fetches are now cached and that
// nothing else changed:
//
//   A. an FMV ROM fetch misses once, as two 16-bit reads even with the AGA
//      32-bit chip bus on (fmv_bus answers 16 bits), then hits with no cycle
//   A2. a hit leaves its line as it was (no nf_v rewrite)
//   B. the other word of the same long word hits too
//   C. a data read of a cached ROM word still goes to the bus
//   D. the board's registers (offset 0x40000 up) are never cached
//   E. chip RAM fetches as before: one 32-bit read, then hits
//   F. CACR's enable bit off: every ROM fetch goes to the bus
//   G. the unthrottled 68020 (CPU Turbo On) caches ROM fetches too
//   H. an unconfigured board's range is not cached
//
// The CPU is the stub in cpu_core_stubs.v, driven through its regs; the chip
// bus answers every cycle with a word that is a function of its address.
//
//   iverilog -g2012 -I ../.. -o tbi ../../cpu_wrapper.v ../../proxy68k.v \
//       ../../memory_router.v ../../cpu_cycles.v cpu_core_stubs.v tb_cpu_wrapper_icache.sv
//   vvp tbi

`timescale 1ns/1ps

module tb_cpu_wrapper_icache;

	reg         clk = 0;
	reg         reset = 0;          // active low
	reg         ph1 = 0, ph2 = 0;
	reg  [4:0]  cpucfg = 5'b00111;  // 68EC020 (cpucfg[2]), CPU Turbo Off
	reg  [2:0]  cachecfg = 3'b001;  // cachecfg[0]: the 68EC020's cache on chip RAM
	reg         chip32_en = 1'b1;   // AGA: long chip reads
	reg         chip_dtack = 1'b1;

	wire [23:1] chip_addr;
	wire        chip_as, chip_long;
	wire [15:0] chip_dout, chip_dout2;

	integer errors = 0;
	always #5 clk = ~clk;

	// The chip bus clock phases: a 7 MHz cycle of four clocks, ph1 then ph2
	integer ph = 0;
	always @(posedge clk) begin
		ph  <= (ph + 1) % 4;
		ph1 <= (ph == 3);
		ph2 <= (ph == 1);
	end

	// The bus: DTACK while AS is low, and a word per address.
	//
	// The FMV board's range answers as the real path does (run v32): the
	// bridge registers the address a clock (minimig_m68k_bridge address_r)
	// but passes AS through, and fmv_bus takes its address on the first
	// clock it sees AS low (maddr <= cpu_addr). So it answers for the
	// address of the clock before AS fell. An address that changes with AS
	// is read wrongly there; f22e156 did exactly that on a fill's first
	// read, and the bench, answering from chip_addr, passed it. Chip RAM is
	// answered from the live address, as the SRAM bridge samples later.
	function [15:0] word_at(input [23:1] a);
		word_at = {a[8:1], ~a[16:9]};
	endfunction
	reg  [23:1] addr_r = 23'd0, fmv_lat = 23'd0;
	reg         as_p = 1'b1;
	always @(posedge clk) begin
		if (as_p && !chip_as)
			fmv_lat <= addr_r;          // the address register before this edge
		as_p   <= chip_as;
		addr_r <= chip_addr;
	end
	wire        in_fmv  = chip_addr[23:20] == 4'h2;
	wire [23:1] ans_a   = (in_fmv && !(as_p && !chip_as)) ? fmv_lat : chip_addr;
	assign chip_dout  = word_at(ans_a);
	assign chip_dout2 = word_at(ans_a + 23'd1);
	always @(posedge clk) chip_dtack <= chip_as;

	integer cycles = 0, long_cycles = 0;
	reg as_d = 1'b1;
	always @(posedge clk) begin
		as_d <= chip_as;
		if (as_d && !chip_as) begin
			cycles = cycles + 1;
			if (chip_long) long_cycles = long_cycles + 1;
		end
	end

	cpu_wrapper dut (
		.reset(reset), .reset_out(),
		.clk(clk), .ph1(ph1), .ph2(ph2),
		.cpucfg(cpucfg), .fastramcfg(3'd0), .cachecfg(cachecfg),
		.bootrom(1'b0),
		.chip32_en(chip32_en), .chip_long(chip_long), .chip_din2(), .chip_dout2(chip_dout2),
		.ramlong1(), .ramdin_lo(), .ramdout_hi(16'd0), .ramready_l(1'b0),

		.ss_arm(1'b0),
		.ss_reg_index(4'd0), .ss_reg_data(),
		.ss_pc(), .ss_exe_pc(), .ss_at_boundary(),
		.ss_trap_vector(), .ss_trap_active(),
		.ss_bus_settled(),
		.ss_sr(), .ss_usp(), .ss_vbr(), .ss_cacr(),
		.ss_wr_index(4'd0), .ss_wr_data(32'd0), .ss_wr_en(1'b0),
		.ss_pc_wr(1'b0), .ss_sr_wr(1'b0), .ss_usp_wr(1'b0),
		.ss_vbr_wr(1'b0), .ss_cacr_wr(1'b0), .ss_resume(1'b0),

		.chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(),
		.chip_as(chip_as), .chip_uds(), .chip_lds(), .chip_rw(),
		.chip_dtack(chip_dtack), .chip_ipl(3'b111),

		.fastchip_dout(16'd0), .fastchip_sel(),
		.fastchip_lds(), .fastchip_uds(), .fastchip_rnw(), .fastchip_lw(),
		.fastchip_selack(1'b0), .fastchip_ready(1'b0),

		.ramsel(), .ramaddr(), .ramdin(), .ramdout(16'd0),
		.ramready(1'b0), .ramready_fx(1'b0), .ramlds(), .ramuds(), .ramshared(),

		.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),

		.cdtv_mode(1'b0), .cdtv_din(16'd0), .cdtv_selack(1'b0),
		.ar_on(1'b0), .ar_fetch(),
		.cdtv_base(),

		.cpustate(), .cacr(), .nmi_addr(),
		.z2ram_ena_out(), .z3ram_base0_out(), .z3ram_ena0_out(),
		.z3ram_base1_out(), .z3ram_ena1_out(), .dcache_sw_en(),
		.px_own(1'b0), .px_fast(1'b0), .px_fastw(1'b0), .px_reset(1'b0), .px_tgl(1'b0), .px_rw(1'b1), .px_addr(23'd0), .px_uds_n(1'b1), .px_lds_n(1'b1),
		.px_wdata(16'd0), .px_ack_tgl(), .px_rdata()
	);

	task check(input [511:0] what, input integer got, input integer want);
		begin
			if (got !== want) begin
				$display("FAIL %0s: got %0d, want %0d", what, got, want);
				errors = errors + 1;
			end else
				$display("ok   %0s = %0d", what, got);
		end
	endtask

	// One access by the CPU: busstate 0 a fetch, 2 a data read. Returns the
	// word it got and how many chip bus cycles it took.
	task automatic access(input [1:0] kind, input [31:0] a, output [15:0] d, output integer n);
		integer c0, d0, t;
		begin
			c0 = cycles;
			d0 = dut.cpu_inst_p.done;
			@(posedge clk); #1;
			dut.cpu_inst_p.r_addr     = a;
			dut.cpu_inst_p.r_fc       = (kind == 2'd0) ? 3'd6 : 3'd5;
			dut.cpu_inst_p.r_busstate = kind;
			t = 0;
			while (dut.cpu_inst_p.done == d0 && t < 4000) begin @(posedge clk); #1; t = t + 1; end
			if (t >= 4000) begin
				$display("FAIL access %h never completed", a);
				errors = errors + 1;
			end
			d = dut.cpu_inst_p.r_rdata;
			dut.cpu_inst_p.r_busstate = 2'd1;
			repeat (12) @(posedge clk);
			n = cycles - c0;
		end
	endtask

	function [15:0] want(input [31:0] a);
		want = word_at(a[23:1]);
	endfunction

	reg [15:0] d;
	integer n, l0;

	initial begin
		repeat (4) @(posedge clk);
		reset = 1'b1;
		repeat (8) @(posedge clk);
		dut.cpu_inst_p.r_busstate = 2'd1;
		dut.cpu_inst_p.r_cacr     = 14'd1;          // CACR E
		// The board configured at $200000, as autoconfig leaves it on a CD32
		dut.fmv_base = 8'h20;
		dut.fmv_cfgd = 1'b1;
		repeat (8) @(posedge clk);

		// ---- A. an FMV ROM fetch: a miss of two 16-bit reads, then a hit ----
		l0 = long_cycles;
		access(2'd0, 32'h00203b5a, d, n);
		check("A. ROM fetch: the word", d, want(32'h00203b5a));
		check("A. ROM fetch miss: two 16-bit chip cycles", n, 2);
		check("A. ROM fetch miss: no long cycle (fmv_bus is 16 bits)", long_cycles - l0, 0);
		access(2'd0, 32'h00203b5a, d, n);
		check("A. ROM fetch again: the word", d, want(32'h00203b5a));
		check("A. ROM fetch again: a hit, no chip cycle", n, 0);

		// ---- B. the long word's other half -------------------------------------
		access(2'd0, 32'h00203b58, d, n);
		check("B. the other word: right", d, want(32'h00203b58));
		check("B. the other word: a hit", n, 0);

		// ---- A2. a hit leaves its line intact ---------------------------------
		// A fetch outside chip RAM (nf_v) rewrites its line, as on a real
		// direct-mapped cache; an FMV ROM hit must not. Another long word in
		// between (another line) so the wrapper's held long word cannot
		// answer, then the first again: from the line, with its own word.
		// The rewrite would carry the last fill's data, so the line to look
		// at again is a hit made after a fill of another line.
		access(2'd0, 32'h00203b20, d, n);           // line 8, a miss: the last fill
		access(2'd0, 32'h00203b5a, d, n);           // line 22, a hit
		access(2'd0, 32'h00203b20, d, n);           // line 8, a hit
		access(2'd0, 32'h00203b5a, d, n);           // line 22 again
		check("A2. a hit line, after another line: no chip cycle", n, 0);
		check("A2. a hit line, after another line: its own word", d, want(32'h00203b5a));

		// ---- C. data reads are not served from it ------------------------------
		access(2'd2, 32'h00203b5a, d, n);
		check("C. data read of a cached ROM word: the word", d, want(32'h00203b5a));
		check("C. data read of a cached ROM word: on the bus", n, 1);

		// ---- D. the board's registers are never cached ---------------------------
		access(2'd0, 32'h00240000, d, n);
		check("D. register fetch: on the bus", n > 0, 1);
		access(2'd0, 32'h00240040, d, n);
		access(2'd0, 32'h00240000, d, n);
		check("D. register fetch again: still on the bus", n > 0, 1);

		// ---- E. chip RAM, as before: one long read, then hits --------------------
		l0 = long_cycles;
		access(2'd0, 32'h00001000, d, n);
		check("E. chip fetch: the word", d, want(32'h00001000));
		check("E. chip fetch miss: one long chip cycle", n, 1);
		check("E. chip fetch miss: it was long", long_cycles - l0, 1);
		access(2'd0, 32'h00001002, d, n);
		check("E. chip fetch, other word: right", d, want(32'h00001002));
		check("E. chip fetch, other word: a hit", n, 0);

		// ---- F. CACR E off: every ROM fetch on the bus -----------------------------
		// (another long word between: the wrapper holds the last one fetched,
		// the 020's prefetch, whatever CACR says, as upstream does on chip RAM)
		dut.cpu_inst_p.r_cacr = 14'd0;
		access(2'd0, 32'h00203c00, d, n);
		access(2'd0, 32'h00203c40, d, n);
		access(2'd0, 32'h00203c00, d, n);
		check("F. cache off: ROM fetch again on the bus", n > 0, 1);
		check("F. cache off: the word", d, want(32'h00203c00));
		dut.cpu_inst_p.r_cacr = 14'd1;

		// ---- H. no board configured: its range is not cached -----------------------
		dut.fmv_cfgd = 1'b0;
		access(2'd0, 32'h00203d00, d, n);
		access(2'd0, 32'h00203d40, d, n);
		access(2'd0, 32'h00203d00, d, n);
		check("H. board not configured: fetch again on the bus", n > 0, 1);
		dut.fmv_cfgd = 1'b1;

		// ---- G. the unthrottled 68020 (CPU Turbo On) --------------------------------
		cpucfg   = 5'b00011;                         // 68020, not EC
		cachecfg = 3'b000;
		dut.cpu_inst_p.r_busstate = 2'd1;
		repeat (16) @(posedge clk);                  // ic_ena/ic_fmv switch while idle
		access(2'd0, 32'h00203e40, d, n);
		check("G. 68020: ROM fetch miss on the bus", n, 2);
		check("G. 68020: the word", d, want(32'h00203e40));
		access(2'd0, 32'h00203e40, d, n);
		check("G. 68020: ROM fetch again: a hit", n, 0);
		check("G. 68020: the word from the cache", d, want(32'h00203e40));
		access(2'd0, 32'h00001100, d, n);
		access(2'd0, 32'h00001140, d, n);
		access(2'd0, 32'h00001100, d, n);
		check("G. 68020: chip fetches are not cached (upstream's rule)", n > 0, 1);

		$display("%0d errors", errors);
		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL");
		$finish;
	end

	initial begin
		#5000000;
		$display("RUN: FAIL (timeout)");
		$finish;
	end
endmodule
