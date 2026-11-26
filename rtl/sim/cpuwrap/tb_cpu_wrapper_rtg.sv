// cpu_wrapper: the RTG board as a Zorro III autoconfig board (upstream
// Minimig-AGA 3ea7f0e).
//
// The board is one 16 MB Zorro III board, manufacturer $139C product $30, as
// the Maximig core presents it: the framebuffer is its lower 8 MB and the
// registers are a 64 KB window at board+$800000. The fixed $B80100/$02000000
// decode stays beside it for MiSTer.card 0.1.
//
//   A. the board's autoconfig nibbles, read at $E80000 over the chip bus
//   B. nothing decodes at the board's addresses before its base is written
//   C. writing $40 to register $44 configures it and ends its turn in the chain
//   D. board+offset in the lower 8 MB is RTG memory, on the same DDR3 address
//      as $02000000+offset
//   E. board+$800000.. is the register window: fastchip with rtg_reg_sel,
//      not RAM; outside the 64 KB window, and above the board, nothing is
//   F. the fixed $02000000 window still decodes
//   G. a save state restore (ss_resume) keeps the board configured. The
//      restore parks the CPU and does not reset the wrapper, so the base KS
//      assigned at power-on stays, as with the other boards
//   H. a reset clears it again
//   I. the board is offered only to a 68020 or 68030 with a 32-bit bus, and
//      not on a stock CD32 (no_zorro: one more ConfigDev moves ExecBase)
//   J. a shut-up write at $4C ends its turn without configuring it
//
// The CPU is the stub in cpu_core_stubs.v, driven through its regs. The chip
// bus answers every cycle, the RAM port and fastchip answer whatever selects
// them, and the bench records what each access selected.
//
//   iverilog -g2012 -I ../.. -o tbr ../../cpu_wrapper.v ../../proxy68k.v \
//       ../../memory_router.v ../../cpu_cycles.v cpu_core_stubs.v tb_cpu_wrapper_rtg.sv
//   vvp tbr

`timescale 1ns/1ps

module tb_cpu_wrapper_rtg;

	reg         clk = 0;
	reg         reset = 0;          // active low
	reg         ph1 = 0, ph2 = 0;
	reg  [4:0]  cpucfg = 5'b00011;  // 68020, CPU Turbo On
	reg         no_zorro = 1'b0;
	reg         ss_resume = 1'b0;
	reg         chip_dtack = 1'b1;

	wire [23:1] chip_addr;
	wire        chip_as;
	wire [15:0] chip_dout = 16'h0FFF;   // low 12 bits; the nibble comes from autoconfig
	wire        ramsel, fastchip_sel, rtg_reg_sel;
	wire [28:1] ramaddr;
	reg         ramready = 1'b0, fastchip_ready = 1'b0;

	integer errors = 0;
	always #5 clk = ~clk;

	integer ph = 0;
	always @(posedge clk) begin
		ph  <= (ph + 1) % 4;
		ph1 <= (ph == 3);
		ph2 <= (ph == 1);
	end

	always @(posedge clk) chip_dtack     <= chip_as;
	always @(posedge clk) ramready       <= ramsel & ~ramready;
	// fastchip raises sel_ack only for its own devices; of those this bench
	// models the RTG block alone: the board window, or $B80100-$B80FFF.
	wire        fc_ack = fastchip_sel & (rtg_reg_sel | ((dut.cpu_addr_m[31:12] == 20'h00B80) & |dut.cpu_addr_m[11:8]));
	always @(posedge clk) fastchip_ready <= fc_ack & ~fastchip_ready;

	cpu_wrapper dut (
		.reset(reset), .reset_out(),
		.clk(clk), .ph1(ph1), .ph2(ph2),
		.cpucfg(cpucfg), .fastramcfg(3'd0), .cachecfg(3'd0),
		.bootrom(1'b0),
		.chip32_en(1'b0), .chip_long(), .chip_din2(), .chip_dout2(16'd0),
		.ramlong1(), .ramdin_lo(), .ramdout_hi(16'd0), .ramready_l(1'b0),

		.ss_arm(1'b0),
		.ss_reg_index(4'd0), .ss_reg_data(),
		.ss_pc(), .ss_exe_pc(), .ss_at_boundary(),
		.ss_trap_vector(), .ss_trap_active(),
		.ss_bus_settled(),
		.ss_sr(), .ss_usp(), .ss_vbr(), .ss_cacr(),
		.ss_wr_index(4'd0), .ss_wr_data(32'd0), .ss_wr_en(1'b0),
		.ss_pc_wr(1'b0), .ss_sr_wr(1'b0), .ss_usp_wr(1'b0),
		.ss_vbr_wr(1'b0), .ss_cacr_wr(1'b0), .ss_resume(ss_resume),

		.chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(),
		.chip_as(chip_as), .chip_uds(), .chip_lds(), .chip_rw(),
		.chip_dtack(chip_dtack), .chip_ipl(3'b111),

		.fastchip_dout(16'h5001), .fastchip_sel(fastchip_sel),
		.fastchip_lds(), .fastchip_uds(), .fastchip_rnw(), .fastchip_lw(),
		.fastchip_selack(fc_ack), .fastchip_ready(fastchip_ready),

		.ramsel(ramsel), .ramaddr(ramaddr), .ramdin(), .ramdout(16'd0),
		.ramready(ramready), .ramready_fx(ramready), .ramlds(), .ramuds(), .ramshared(),

		.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),

		.cdtv_mode(1'b0), .no_zorro(no_zorro), .cdtv_din(16'd0), .cdtv_selack(1'b0),
		.ar_on(1'b0), .ar_fetch(),
		.cdtv_base(),

		.cpustate(), .cacr(), .nmi_addr(),
		.z2ram_ena_out(), .z3ram_base0_out(), .z3ram_ena0_out(),
		.z3ram_base1_out(), .z3ram_ena1_out(), .rtg_reg_sel(rtg_reg_sel),
		.dcache_sw_en(),
		.px_own(1'b0), .px_fast(1'b0), .px_fastw(1'b0), .px_reset(1'b0), .px_tgl(1'b0), .px_rw(1'b1), .px_addr(23'd0), .px_uds_n(1'b1), .px_lds_n(1'b1),
		.px_wdata(16'd0), .px_ack_tgl(), .px_rdata()
	);

	task check(input [511:0] what, input integer got, input integer want);
		begin
			if (got !== want) begin
				$display("FAIL: %0s: got %0h, want %0h", what, got, want);
				errors = errors + 1;
			end else begin
				$display("ok:   %0s = %0h", what, got);
			end
		end
	endtask

	// What the access in flight selected.
	reg         mon = 1'b0;
	integer     saw_ram, saw_fc, saw_reg, saw_chip, saw_ac;
	reg  [28:1] saw_ra;
	reg         as_d = 1'b1;
	always @(posedge clk) begin
		as_d <= chip_as;
		if (mon) begin
			if (ramsel)       begin saw_ram = 1; saw_ra = ramaddr; end
			if (fc_ack)       saw_fc  = 1;
			if (rtg_reg_sel)  saw_reg = 1;
			if (dut.sel_autoconfig) saw_ac = 1;
			if (as_d && !chip_as) saw_chip = 1;
		end
	end

	// One CPU access: a word read, or a word write with UDS and LDS.
	task automatic access(input wr, input [31:0] a, input [15:0] wd, output [15:0] d);
		integer d0, t;
		begin
			saw_ram = 0; saw_fc = 0; saw_reg = 0; saw_chip = 0; saw_ac = 0; saw_ra = 0;
			d0 = dut.cpu_inst_p.done;
			@(posedge clk); #1;
			mon = 1'b1;
			dut.cpu_inst_p.r_addr     = a;
			dut.cpu_inst_p.r_fc       = 3'd5;
			dut.cpu_inst_p.r_nwr      = ~wr;
			dut.cpu_inst_p.r_nuds     = ~wr;
			dut.cpu_inst_p.r_nlds     = ~wr;
			dut.cpu_inst_p.r_wdata    = wd;
			dut.cpu_inst_p.r_busstate = wr ? 2'd3 : 2'd2;
			t = 0;
			while (dut.cpu_inst_p.done == d0 && t < 4000) begin @(posedge clk); #1; t = t + 1; end
			if (t >= 4000) begin
				$display("FAIL access %h never completed", a);
				errors = errors + 1;
			end
			d = dut.cpu_inst_p.r_rdata;
			dut.cpu_inst_p.r_busstate = 2'd1;
			dut.cpu_inst_p.r_nwr      = 1'b1;
			dut.cpu_inst_p.r_nuds     = 1'b1;
			dut.cpu_inst_p.r_nlds     = 1'b1;
			repeat (8) @(posedge clk);
			mon = 1'b0;
		end
	endtask

	// Out of reset with only the RTG board left in the chain: Toccata and the
	// A2065 come first and are taken out of the way by hand.
	task automatic power_on;
		begin
			reset = 1'b0;
			repeat (4) @(posedge clk);
			reset = 1'b1;
			repeat (4) @(posedge clk);
			dut.ac_toccata = 1'b0;
			dut.ac_a2065   = 1'b0;
			dut.cpu_inst_p.r_busstate = 2'd1;
			repeat (4) @(posedge clk);
		end
	endtask

	reg  [15:0] d;
	reg  [28:1] ra_fixed;
	integer i;
	// Offsets 0,2,4,8,10,12,14,16 and the nibble the CPU reads at each
	reg  [6:0]  ac_off [0:7];
	reg  [3:0]  ac_nib [0:7];

	initial begin
		ac_off[0] = 7'h00; ac_nib[0] = 4'b1000;  // Zorro III, not memory, no ROM
		ac_off[1] = 7'h02; ac_nib[1] = 4'b0000;  // size 16 MB (with extended size)
		ac_off[2] = 7'h04; ac_nib[2] = 4'b1100;  // product $3x, inverted
		ac_off[3] = 7'h08; ac_nib[3] = 4'b0000;  // flags: extended size
		ac_off[4] = 7'h10; ac_nib[4] = 4'b1110;  // manufacturer $139C, inverted
		ac_off[5] = 7'h12; ac_nib[5] = 4'b1100;
		ac_off[6] = 7'h14; ac_nib[6] = 4'b0110;
		ac_off[7] = 7'h16; ac_nib[7] = 4'b0011;

		power_on;
		check("I. 68020: the board is in the chain", dut.ac_rtg, 1);

		// ---- A. autoconfig nibbles ----
		for (i = 0; i < 8; i = i + 1) begin
			access(1'b0, 32'h00E80000 + ac_off[i], 16'h0, d);
			check("A. autoconfig nibble", {ac_off[i], 4'h0, d[15:12]}, {ac_off[i], 4'h0, ac_nib[i]});
		end

		// ---- B. unconfigured: no decode at the board's addresses ----
		access(1'b0, 32'h40800000 + 32'h10E, 16'h0, d);
		check("B. unconfigured register window: not fastchip", saw_fc, 0);
		check("B. unconfigured register window: no rtg_reg_sel", saw_reg, 0);
		access(1'b0, 32'h40000000, 16'h0, d);
		check("B. unconfigured framebuffer: not RAM", saw_ram, 0);

		// ---- C. KS writes the base, A31:A24 = $40 ----
		access(1'b1, 32'h00E80044, 16'h4000, d);
		check("C. base write: enabled", dut.rtg_ena, 1);
		check("C. base write: base", dut.rtg_base, 8'h40);
		check("C. base write: the board leaves the chain", dut.ac_rtg, 0);
		access(1'b0, 32'h00E80000, 16'h0, d);
		check("C. the autoconfig page answers nothing after it", saw_ac, 0);

		// ---- D. framebuffer through the board ----
		access(1'b0, 32'h02123456, 16'h0, d);
		ra_fixed = saw_ra;
		check("F. fixed $02000000 window: RAM", saw_ram, 1);
		check("F. fixed window: the RTG DDR3 bank", ra_fixed[26:23], 4'b1110);
		access(1'b0, 32'h40123456, 16'h0, d);
		check("D. board framebuffer: RAM", saw_ram, 1);
		check("D. board framebuffer: same DDR3 address as the fixed window", saw_ra, ra_fixed);
		check("D. board framebuffer: not fastchip", saw_fc, 0);
		access(1'b0, 32'h407FFFFE, 16'h0, d);
		check("D. last framebuffer word: RAM", saw_ram, 1);

		// ---- E. register window ----
		access(1'b0, 32'h40800000 + 32'h10E, 16'h0, d);
		check("E. register window: fastchip", saw_fc, 1);
		check("E. register window: rtg_reg_sel", saw_reg, 1);
		check("E. register window: not RAM", saw_ram, 0);
		check("E. register window: the fastchip word", d, 16'h5001);
		access(1'b0, 32'h4080FFFE, 16'h0, d);
		check("E. last word of the window: rtg_reg_sel", saw_reg, 1);
		access(1'b0, 32'h40810000, 16'h0, d);
		check("E. past the 64 KB window: no rtg_reg_sel", saw_reg, 0);
		check("E. past the 64 KB window: not fastchip", saw_fc, 0);
		check("E. past the 64 KB window: not RAM", saw_ram, 0);
		access(1'b0, 32'h41000000, 16'h0, d);
		check("E. above the board: not RAM", saw_ram, 0);
		check("E. above the board: not fastchip", saw_fc, 0);

		// ---- G. a restore keeps the board ----
		@(posedge clk); #1 ss_resume = 1'b1;
		@(posedge clk); #1 ss_resume = 1'b0;
		repeat (8) @(posedge clk);
		check("G. after ss_resume: still enabled", dut.rtg_ena, 1);
		check("G. after ss_resume: same base", dut.rtg_base, 8'h40);
		access(1'b0, 32'h40123456, 16'h0, d);
		check("G. after ss_resume: framebuffer still decodes", saw_ram, 1);

		// ---- H. reset ----
		power_on;
		check("H. after reset: not enabled", dut.rtg_ena, 0);
		check("H. after reset: back in the chain", dut.ac_rtg, 1);
		access(1'b0, 32'h40123456, 16'h0, d);
		check("H. after reset: framebuffer gone", saw_ram, 0);

		// ---- J. shut up ----
		access(1'b1, 32'h00E8004C, 16'h0000, d);
		check("J. shut up: out of the chain", dut.ac_rtg, 0);
		check("J. shut up: not enabled", dut.rtg_ena, 0);

		// ---- I. which machines get it ----
		cpucfg = 5'b00111;  // 68EC020
		power_on;
		check("I. 68EC020: not offered", dut.ac_rtg, 0);
		cpucfg = 5'b00010;  // 68030
		power_on;
		check("I. 68030: offered", dut.ac_rtg, 1);
		cpucfg = 5'b00001;  // 68010
		power_on;
		check("I. 68010: not offered", dut.ac_rtg, 0);
		cpucfg = 5'b00011; no_zorro = 1'b1;
		power_on;
		check("I. stock CD32 (no_zorro): not offered", dut.ac_rtg, 0);
		no_zorro = 1'b0;

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
