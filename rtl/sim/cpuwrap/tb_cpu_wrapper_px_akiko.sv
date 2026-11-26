// cpu_wrapper: the ARM CPU's proxy reaches Akiko.
//
// Akiko ($B800xx) lives in fastchip, which only the 68020 path selected; on
// the 68000 path fastchip_sel was tied to 0. The ARM CPU runs the core on its
// 68000 path (the proxy sits on the 68000's pins), so its cd.device found no
// Akiko and a CD32 never read its disc (hardware, 2026-11-26).
//
// Akiko acts on its chip select every clk_sys cycle -- the C2P buffer steps
// its pointer on each one -- while a 68000 cycle holds AS for many. So the
// proxy's access must reach fastchip as exactly ONE clock of fastchip_sel,
// with the strobes, R/W and write data valid in it; the read word must reach
// the bridge; and the cycle must stay off the chip bus. A chip-bus access is
// the control: it must still go to the chip bus and never select fastchip.
// And the fx68k's own cycles (px_own low) never select fastchip.
//
// fastchip is modelled as fastchip.v answers Akiko: sel_ack and the data are
// combinational on sel. The two CPU cores are stubbed (cpu_core_stubs.v).
//
//   iverilog -g2012 -I ../.. -o tbpa ../../cpu_wrapper.v ../../proxy68k.v \
//       ../../memory_router.v ../../cpu_cycles.v cpu_core_stubs.v \
//       tb_cpu_wrapper_px_akiko.sv
//   vvp tbpa

`timescale 1ns/1ps

module tb_cpu_wrapper_px_akiko;

	reg         clk = 0;
	reg         reset = 0;          // active low
	reg         ph1 = 0, ph2 = 0;
	reg         px_own = 0;
	reg         px_tgl = 0;
	reg         px_rw = 1;
	reg  [23:1] px_addr = 0;
	reg         px_uds_n = 1, px_lds_n = 1;
	reg  [15:0] px_wdata = 0;
	wire        px_ack_tgl;
	wire [15:0] px_rdata;

	wire        fastchip_sel, fastchip_lds, fastchip_uds, fastchip_rnw;
	wire [23:1] chip_addr;
	wire [15:0] chip_din;
	wire        chip_as;
	reg         chip_dtack = 1;

	// fastchip, as it answers Akiko: sel_ack and dout combinational on sel
	wire        fc_hit    = fastchip_sel && chip_addr[23:8] == 16'hB800;
	wire        fastchip_selack = fc_hit;
	wire [15:0] fastchip_dout   = fc_hit ? (16'hA000 | {8'd0, chip_addr[7:1], 1'b0}) : 16'h0000;

	integer errors = 0;

	always #5 clk = ~clk;

	// enPhi1 and enPhi2, one each per four clocks, as the 68000's 7 MHz
	integer pc = 0;
	always @(posedge clk) begin
		pc  <= (pc + 1) % 4;
		ph1 <= (pc == 3);
		ph2 <= (pc == 1);
	end

	// the chip bus: DTACK a few clocks after AS, gone with it
	integer as_clocks = 0;
	always @(posedge clk) begin
		as_clocks  <= chip_as ? 0 : as_clocks + 1;
		chip_dtack <= !(!chip_as && as_clocks > 6);
	end

	// what fastchip saw in the access under test
	integer     sel_clocks = 0, chip_as_clocks = 0;
	reg         sel_rnw, sel_uds, sel_lds;
	reg  [15:0] sel_din;
	reg  [23:1] sel_addr;
	always @(posedge clk) begin
		if (fastchip_sel) begin
			sel_clocks <= sel_clocks + 1;
			sel_rnw  <= fastchip_rnw;
			sel_uds  <= ~fastchip_uds;   // fastchip_uds is active low out of cpu_wrapper
			sel_lds  <= ~fastchip_lds;
			sel_din  <= chip_din;
			sel_addr <= chip_addr;
		end
		if (!chip_as) chip_as_clocks <= chip_as_clocks + 1;
	end

	cpu_wrapper dut (
		.reset(reset), .reset_out(),
		.clk(clk), .ph1(ph1), .ph2(ph2),
		.cpucfg(5'b00000), .fastramcfg(3'd0), .cachecfg(3'd0),
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
		.ss_vbr_wr(1'b0), .ss_cacr_wr(1'b0), .ss_resume(1'b0),

		.chip_addr(chip_addr), .chip_dout(16'h5A5A), .chip_din(chip_din),
		.chip_as(chip_as), .chip_uds(), .chip_lds(), .chip_rw(),
		.chip_dtack(chip_dtack), .chip_ipl(3'b111),

		.fastchip_dout(fastchip_dout), .fastchip_sel(fastchip_sel),
		.fastchip_lds(fastchip_lds), .fastchip_uds(fastchip_uds), .fastchip_rnw(fastchip_rnw), .fastchip_lw(),
		.fastchip_selack(fastchip_selack), .fastchip_ready(fastchip_selack),

		.ramsel(), .ramaddr(), .ramdin(), .ramdout(16'd0),
		.ramready(1'b0), .ramready_fx(1'b0), .ramlds(), .ramuds(), .ramshared(),

		.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),

		.cdtv_mode(1'b0), .no_zorro(1'b0), .cdtv_din(16'd0), .cdtv_selack(1'b0),
		.ar_on(1'b0), .ar_fetch(),
		.cdtv_base(),

		.cpustate(), .cacr(), .nmi_addr(),
		.z2ram_ena_out(), .z3ram_base0_out(), .z3ram_ena0_out(),
		.z3ram_base1_out(), .z3ram_ena1_out(), .dcache_sw_en(),
		.px_own(px_own), .px_fast(1'b0), .px_fastw(1'b0), .px_reset(1'b0), .px_tgl(px_tgl), .px_rw(px_rw), .px_addr(px_addr),
		.px_uds_n(px_uds_n), .px_lds_n(px_lds_n),
		.px_wdata(px_wdata), .px_ack_tgl(px_ack_tgl), .px_rdata(px_rdata)
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

	// One proxy word cycle, as armcpu_bridge hands it over. Returns the word
	// read (or 0 for a write).
	task automatic cycle(input rd, input [23:0] a, input uds, input lds, input [15:0] d, output [15:0] q);
		integer t;
		reg     ack0;
		begin
			sel_clocks = 0;
			chip_as_clocks = 0;
			ack0 = px_ack_tgl;
			@(posedge clk);
			px_rw    <= rd;
			px_addr  <= a[23:1];
			px_uds_n <= ~uds;
			px_lds_n <= ~lds;
			px_wdata <= d;
			@(posedge clk);
			px_tgl   <= ~px_tgl;
			t = 0;
			while (px_ack_tgl == ack0) begin
				@(posedge clk);
				t = t + 1;
				if (t > 5000) begin
					$display("FAIL: no ack for %06h", a);
					errors = errors + 1;
					disable cycle;
				end
			end
			q = px_rdata;
			repeat (8) @(posedge clk);
		end
	endtask

	reg [15:0] q;

	initial begin
		repeat (4) @(posedge clk);
		reset = 1'b1;
		repeat (8) @(posedge clk);

		// ---- 0. the fx68k's own cycles never select fastchip -----------------
		// Nothing drives the stubbed fx68k's bus here, but its AS sits high:
		// what is checked is that with px_own low nothing selects fastchip.
		sel_clocks = 0;
		repeat (40) @(posedge clk);
		check("px_own low: no fastchip select", sel_clocks, 0);

		px_own = 1'b1;
		repeat (8) @(posedge clk);

		// ---- 1. a read of Akiko's ID ------------------------------------------
		cycle(1'b1, 24'hB80002, 1'b1, 1'b1, 16'h0000, q);
		check("read $B80002: fastchip selected for exactly one clock", sel_clocks, 1);
		check("read $B80002: the word reaches the bridge", q, 16'hA002);
		check("read $B80002: R/W high in the select", sel_rnw, 1);
		check("read $B80002: the address in the select", {sel_addr, 1'b0}, 24'hB80002);
		check("read $B80002: kept off the chip bus", chip_as_clocks, 0);

		// ---- 2. a word write, the strobes come a phase after AS ---------------
		cycle(1'b0, 24'hB80038, 1'b1, 1'b1, 16'h1234, q);
		check("write $B80038: fastchip selected for exactly one clock", sel_clocks, 1);
		check("write $B80038: R/W low in the select", sel_rnw, 0);
		check("write $B80038: the data in the select", sel_din, 16'h1234);
		check("write $B80038: both strobes in the select", {sel_uds, sel_lds}, 2'b11);
		check("write $B80038: kept off the chip bus", chip_as_clocks, 0);

		// ---- 3. a byte write: only its strobe --------------------------------
		cycle(1'b0, 24'hB80029, 1'b0, 1'b1, 16'h0077, q);
		check("byte write $B80029: one clock", sel_clocks, 1);
		check("byte write $B80029: lower strobe only", {sel_uds, sel_lds}, 2'b01);

		// ---- 4. back to back, each one clock ---------------------------------
		cycle(1'b1, 24'hB80038, 1'b1, 1'b1, 16'h0000, q);
		check("C2P read 1: one clock", sel_clocks, 1);
		cycle(1'b1, 24'hB80038, 1'b1, 1'b1, 16'h0000, q);
		check("C2P read 2: one clock", sel_clocks, 1);

		// ---- 5. the control: a chip-bus access still goes to the chip bus -----
		cycle(1'b1, 24'hDFF006, 1'b1, 1'b1, 16'h0000, q);
		check("read $DFF006: no fastchip select", sel_clocks, 0);
		check("read $DFF006: on the chip bus", chip_as_clocks > 0, 1);
		check("read $DFF006: the chip bus's word", q, 16'h5A5A);

		// and Akiko again after it, so a stale done flag would show
		cycle(1'b1, 24'hB80000, 1'b1, 1'b1, 16'h0000, q);
		check("read $B80000 after a chip cycle: one clock", sel_clocks, 1);
		check("read $B80000 after a chip cycle: its word", q, 16'hA000);

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
