// cpu_wrapper: the save state park, the stock-speed throttle, and the
// chip-slot guard.
//
// cpu_wrapper had no simulation coverage at all, and it is not a quiet corner.
// Three things live in it that a future upstream merge can plausibly remove
// without anyone noticing, and all three came close already:
//
//   1. The save state CPU park -- ss_bus_settled & ~ss_cpu_hold. During the
//      74d6ce0 merge, upstream's side of the conflict carried a plainer
//      clkena_p_base and taking theirs would have deleted the park silently.
//   2. The CPU speed. This used to be the stock-speed cooldown constant
//      (upstream 148931d had it at 9, half A1200 speed); upstream 26eb46a
//      replaced the cooldown with a cycle model (cpu_cycles.v), whose tables
//      Icarus cannot load from their .mif files, so its rates are not checked
//      here. What is: the unthrottled 68020 -- CPU Turbo On, this fork's
//      default -- runs free, and the park holds in every CPU mode.
//   3. The chip-slot guard from 114ab43: chipreq must stay low while the
//      fastchip or CDTV bridge is serving the access.
//
// The park is the part most worth pinning down. Its own comment explains that
// reading ss_at_boundary live rather than latched releases the CPU while
// ss_ctrl is still writing chip RAM -- ss_resume clears decodeOPC, so the
// boundary goes false the instant the sequencer is re-seeded. A restore that
// lands on half-rewritten memory is indistinguishable from the mid-instruction
// restore the park exists to prevent, which is why test 2 below is the one that
// matters: it drops the boundary while the arm is still held and requires the
// hold to survive.
//
// The two CPU cores are stubbed -- see cpu_core_stubs.v. None of the logic
// under test needs a working 68000, only control over busstate and
// ss_at_boundary.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -I ../.. -o tb ../../cpu_wrapper.v ../../memory_router.v \
//       ../../cpu_cycles.v cpu_core_stubs.v tb_cpu_wrapper_park.sv
//   vvp tb

`timescale 1ns/1ps

module tb_cpu_wrapper_park;

	reg         clk = 0;
	reg         reset = 0;          // active low
	reg         ph1 = 0, ph2 = 0;
	reg  [4:0]  cpucfg = 5'b00001;    // [1:0] non-zero selects TG68K; see check 4 for the rest
	reg  [2:0]  fastramcfg = 3'd0;
	reg  [2:0]  cachecfg = 3'd0;
	reg         bootrom = 1'b0;
	reg         ss_arm = 1'b0;
	reg         ramready = 1'b0;
	reg         fastchip_selack = 1'b0;
	reg         fastchip_ready = 1'b0;
	reg         cdtv_selack = 1'b0;
	reg         cdtv_mode = 1'b0;
	reg         chip_dtack = 1'b1;

	wire        ss_bus_settled;
	wire  [1:0] cpustate;
	wire        ramsel;

	integer errors = 0;

	always #5 clk = ~clk;

	cpu_wrapper dut (
		.reset(reset), .reset_out(),
		.clk(clk), .ph1(ph1), .ph2(ph2),
		.cpucfg(cpucfg), .fastramcfg(fastramcfg), .cachecfg(cachecfg),
		.bootrom(bootrom),
		.chip32_en(1'b0), .chip_long(), .chip_din2(), .chip_dout2(16'd0),
		.ramlong1(), .ramdin_lo(), .ramdout_hi(16'd0), .ramready_l(1'b0),

		.ss_arm(ss_arm),
		.ss_reg_index(4'd0), .ss_reg_data(),
		.ss_pc(), .ss_exe_pc(), .ss_at_boundary(),
		.ss_trap_vector(), .ss_trap_active(),
		.ss_bus_settled(ss_bus_settled),
		.ss_sr(), .ss_usp(), .ss_vbr(), .ss_cacr(),
		.ss_wr_index(4'd0), .ss_wr_data(32'd0), .ss_wr_en(1'b0),
		.ss_pc_wr(1'b0), .ss_sr_wr(1'b0), .ss_usp_wr(1'b0),
		.ss_vbr_wr(1'b0), .ss_cacr_wr(1'b0), .ss_resume(1'b0),

		.chip_addr(), .chip_dout(16'd0), .chip_din(),
		.chip_as(), .chip_uds(), .chip_lds(), .chip_rw(),
		.chip_dtack(chip_dtack), .chip_ipl(3'b111),

		.fastchip_dout(16'd0), .fastchip_sel(),
		.fastchip_lds(), .fastchip_uds(), .fastchip_rnw(), .fastchip_lw(),
		.fastchip_selack(fastchip_selack), .fastchip_ready(fastchip_ready),

		.ramsel(ramsel), .ramaddr(), .ramdin(), .ramdout(16'd0),
		.ramready(ramready), .ramlds(), .ramuds(), .ramshared(),

		.toccata_ena(), .toccata_base(), .a2065_ena(), .a2065_base(),

		.cdtv_mode(cdtv_mode), .cdtv_din(16'd0), .cdtv_selack(cdtv_selack),
		.cdtv_base(),

		.cpustate(cpustate), .cacr(), .nmi_addr(),
		.z2ram_ena_out(), .z3ram_base0_out(), .z3ram_ena0_out(),
		.z3ram_base1_out(), .z3ram_ena1_out(), .dcache_sw_en()
	);

	// Shorthands for what is being asserted about.
	wire clkena = dut.clkena_p_throttled;

	task check(input [511:0] what, input integer got, input integer want);
		begin
			if (got !== want) begin
				$display("FAIL: %0s: got %0d, want %0d", what, got, want);
				errors = errors + 1;
			end else begin
				$display("ok:   %0s = %0d", what, got);
			end
		end
	endtask

	// Count clkena ticks over a window, which is how the throttle is measured.
	task automatic count_ticks(input integer cycles, output integer n);
		integer i;
		begin
			n = 0;
			for (i = 0; i < cycles; i = i + 1) begin
				@(posedge clk);
				#1;
				if (clkena) n = n + 1;
			end
		end
	endtask

	// Longest run of consecutive cycles with clkena low, over a window.
	task automatic max_gap(input integer cycles, output integer worst);
		integer i, run;
		begin
			worst = 0;
			run   = 0;
			for (i = 0; i < cycles; i = i + 1) begin
				@(posedge clk);
				#1;
				if (clkena) begin
					if (run > worst) worst = run;
					run = 0;
				end else run = run + 1;
			end
		end
	endtask

	integer n, gap;

	initial begin
		repeat (4) @(posedge clk);
		reset = 1'b1;                     // out of reset
		repeat (4) @(posedge clk);

		// Bus idle: busstate 1 means no memory access, so cpu_req is low and
		// ss_bus_settled is true without anything having to answer.
		dut.cpu_inst_p.r_busstate    = 2'd1;
		dut.cpu_inst_p.r_at_boundary = 1'b0;
		repeat (4) @(posedge clk);

		// ---- 1. free running -------------------------------------------------
		check("bus settled with no request", ss_bus_settled, 1);
		count_ticks(20, n);
		check("clkena ticks every cycle when free", n, 20);

		// ---- 2. the park, and that it is LATCHED ----------------------------
		// Arm while sitting on a boundary: the CPU must stop.
		dut.cpu_inst_p.r_at_boundary = 1'b1;
		ss_arm = 1'b1;
		repeat (2) @(posedge clk);
		count_ticks(20, n);
		check("parked on a boundary", n, 0);

		// Now take the boundary away with the arm still held. This is what
		// ss_resume does when it re-seeds the sequencer: decodeOPC clears and
		// ss_at_boundary goes false. A live-gated hold releases the CPU here,
		// which is the bug -- ss_ctrl is still writing chip RAM at this point.
		dut.cpu_inst_p.r_at_boundary = 1'b0;
		repeat (2) @(posedge clk);
		count_ticks(40, n);
		check("still parked after the boundary goes away", n, 0);

		// Releasing the arm releases the CPU.
		ss_arm = 1'b0;
		repeat (2) @(posedge clk);
		count_ticks(20, n);
		check("released when ss_arm drops", n, 20);

		// The latch must not carry over into the next arm-and-release, so a
		// second park behaves like the first.
		dut.cpu_inst_p.r_at_boundary = 1'b1;
		ss_arm = 1'b1;
		repeat (2) @(posedge clk);
		dut.cpu_inst_p.r_at_boundary = 1'b0;
		count_ticks(20, n);
		check("second park holds too", n, 0);
		ss_arm = 1'b0;
		dut.cpu_inst_p.r_at_boundary = 1'b0;
		repeat (2) @(posedge clk);

		// Arming while NOT on a boundary must not stop the CPU dead: it has to
		// be allowed to reach one. Nothing here ever reaches a boundary, so the
		// CPU keeps running -- which is the behaviour that lets a save request
		// wait rather than deadlock.
		ss_arm = 1'b1;
		count_ticks(20, n);
		check("armed but never at a boundary keeps running", n, 20);
		ss_arm = 1'b0;
		repeat (2) @(posedge clk);

		// ---- 3. an outstanding bus cycle holds clkena low -------------------
		// busstate 2 is a data read, so cpu_req goes high and nothing has
		// answered. The freeze must not be taken with a fill half done.
		dut.cpu_inst_p.r_busstate = 2'd2;
		repeat (2) @(posedge clk);
		check("bus not settled with a request outstanding", ss_bus_settled, 0);
		count_ticks(20, n);
		check("clkena held while the bus is outstanding", n, 0);

		// Any one of the four ready sources settles it.
		ramready = 1'b1;
		repeat (2) @(posedge clk);
		check("ramready settles the bus", ss_bus_settled, 1);
		ramready = 1'b0;
		cdtv_selack = 1'b1;
		repeat (2) @(posedge clk);
		check("cdtv_selack settles the bus", ss_bus_settled, 1);
		cdtv_selack = 1'b0;
		fastchip_ready = 1'b1;
		repeat (2) @(posedge clk);
		check("fastchip_ready settles the bus", ss_bus_settled, 1);
		fastchip_ready = 1'b0;
		dut.cpu_inst_p.r_busstate = 2'd1;
		repeat (2) @(posedge clk);

		// ---- 4. the CPU modes ------------------------------------------------
		// cpucfg[1:0] 11 with [2] clear is the unthrottled 68020, CPU Turbo
		// On: the cycle model must leave it alone. Upstream 26eb46a dropped it
		// from its menu; this fork keeps it as the default, so it is pinned.
		//
		// Measured under bus traffic, because the cycle model charges for bus
		// cycles as well as opcodes and this stub never starts an opcode: data
		// reads of the stub's address (chip-bus space) answered every cycle.
		// The 68EC020 must then be held -- which is what shows the model is
		// live in this bench at all -- and the 68020 must not.
		dut.cpu_inst_p.r_busstate = 2'd2;
		ramready = 1'b1;
		cpucfg = 5'b00111;
		repeat (8) @(posedge clk);
		max_gap(60, gap);
		if (gap > 0) $display("ok:   68EC020 at A1200 speed: held for up to %0d cycles", gap);
		else begin
			$display("FAIL: 68EC020 at A1200 speed was never held -- the cycle model is not live here");
			errors = errors + 1;
		end
		cpucfg = 5'b00011;
		repeat (8) @(posedge clk);
		max_gap(60, gap);
		check("68020, Turbo On: runs free", gap, 0);
		ramready = 1'b0;
		dut.cpu_inst_p.r_busstate = 2'd1;
		repeat (4) @(posedge clk);

		// The park has to hold whatever the cycle model is doing: 68010,
		// 68020, 68EC020 at A1200 speed, and the 68030 Fast, at 40MHz and at
		// 50MHz (cpucfg[4:3], upstream ec1353dc; every 68030 has its MMU).
		begin : modes
			reg [4:0] m [0:5];
			integer k;
			m[0] = 5'b00001; m[1] = 5'b00011; m[2] = 5'b00111;
			m[3] = 5'b00010; m[4] = 5'b01010; m[5] = 5'b10010;
			for (k = 0; k < 6; k = k + 1) begin
				cpucfg = m[k];
				repeat (8) @(posedge clk);
				dut.cpu_inst_p.r_at_boundary = 1'b1;
				ss_arm = 1'b1;
				repeat (4) @(posedge clk);
				dut.cpu_inst_p.r_at_boundary = 1'b0;
				count_ticks(40, n);
				check("parked in this CPU mode", n, 0);
				ss_arm = 1'b0;
				repeat (4) @(posedge clk);
			end
		end
		cpucfg = 5'b00001;
		repeat (8) @(posedge clk);

		// ---- 5. the chip-slot guard -----------------------------------------
		// chipreq must not assert while another bridge is serving the access.
		// The stub's address is CIA space, which is not RAM -- assert that,
		// because with ramsel high chipreq would be low anyway and every check
		// below would pass without testing anything.
		dut.cpu_inst_p.r_busstate = 2'd2;
		repeat (3) @(posedge clk);
		check("precondition: the test address is not RAM", ramsel, 0);
		check("chipreq asserts for a plain chip access", dut.chipreq, 1);

		cdtv_selack = 1'b1;
		repeat (2) @(posedge clk);
		check("chipreq suppressed by cdtv_selack", dut.chipreq, 0);
		cdtv_selack = 1'b0;

		fastchip_selack = 1'b1;
		repeat (2) @(posedge clk);
		check("chipreq suppressed by fastchip_selack", dut.chipreq, 0);
		fastchip_selack = 1'b0;
		repeat (2) @(posedge clk);
		check("chipreq back after the bridges let go", dut.chipreq, 1);

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
