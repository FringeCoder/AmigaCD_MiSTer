/*
 * tb_video_ce.sv -- video_ce against the inline version it replaces.
 *
 * CLK_VIDEO moved from clk_114 to clk_sys to get the video front end off the
 * core's critical clock. The pixel-rate enable had to be re-derived for the new
 * clock, and the failure mode of getting that wrong is a picture of the right
 * shape at the wrong rate: no fit report shows it, no timing exception causes
 * it, and on hardware it looks like a scaler or a monitor problem rather than
 * like arithmetic.
 *
 * So the old divider is carried here verbatim as a reference arm, clocked at
 * 113.5 MHz, and the new module runs beside it at 28.375 MHz off the same frame
 * stimulus. Over identical wall-clock windows the two must produce the same
 * number of pixel enables, for every one of the three Amiga rates and for the
 * force-28 override. Counting enables per frame rather than comparing waveforms
 * is the point: the two arms cannot be cycle-identical -- they are on different
 * clocks -- but the RATE is the thing that has to be preserved.
 */
`timescale 1ps/1ps

module tb_video_ce;

	// 113.500640 MHz and 28.375160 MHz, 4:1, edge aligned at t=0. In ps so the
	// 4:1 is exact rather than rounded: 8810 / 4 = 2202.5 would not be.
	localparam integer P114 = 8812;          // ps, clk_114 period
	localparam integer P_SYS = P114 * 4;     // ps, clk_sys period

	reg clk_114 = 0;
	reg clk_sys = 0;
	always #(P114 / 2)  clk_114 = ~clk_114;
	always #(P_SYS / 2) clk_sys = ~clk_sys;

	integer errors = 0;

	task ok(input cond, input [511:0] name);
		begin
			if (cond) $display("ok:   %0s", name);
			else begin
				$display("FAIL: %0s", name);
				errors = errors + 1;
			end
		end
	endtask

	// ---- frame stimulus, driven off clk_sys so both arms see the same edges --
	reg        vs      = 1;
	reg        hblank  = 1;
	reg        vblank  = 1;
	reg  [1:0] res     = 2'b00;
	reg        force_28 = 0;

	// ---- the new module -----------------------------------------------------
	wire ce_new;
	video_ce dut (
		.clk(clk_sys), .vs(vs), .hblank(hblank), .vblank(vblank),
		.res(res), .force_28(force_28), .ce_pix(ce_new)
	);

	// ---- the reference: the inline version, verbatim, on clk_114 ------------
	//
	// Copied from AmigaCD.sv as it stood before the move. Do not tidy it: its
	// value here is being the thing that shipped.
	reg ce_ref = 0;
	always @(posedge clk_114) begin
		reg [3:0] div;
		reg [3:0] add;
		reg [1:0] fs_res;
		reg old_vs;

		div <= div + add;
		if(~hblank & ~vblank) fs_res <= fs_res | res;

		old_vs <= vs;
		if(old_vs & ~vs) begin
			fs_res <= 0;
			div <= 0;
			add <= 1; // 7MHz
			if(fs_res[0]) add <= 2; // 14MHz
			if(fs_res[1] | force_28) add <= 4; // 28MHz
		end

		ce_ref <= div[3] & !div[2:0];
	end

	// ---- counters -----------------------------------------------------------
	//
	// Each enable is counted on its own clock, which is what makes the
	// comparison a rate comparison: one high cycle of a 28.375 MHz enable and
	// one high cycle of a 113.5 MHz enable are both one pixel.
	integer n_new = 0, n_ref = 0;
	reg     counting = 0;
	always @(posedge clk_sys) if (counting && ce_new) n_new = n_new + 1;
	always @(posedge clk_114) if (counting && ce_ref) n_ref = n_ref + 1;

	// ---- a frame ------------------------------------------------------------
	//
	// vs idles high and pulses low; the arming edge both arms look for is its
	// FALL. The active part of the frame is where res is accumulated.
	task frame(input integer active_sys_cycles);
		begin
			// vertical sync pulse
			@(negedge clk_sys); vs = 0; vblank = 1; hblank = 1;
			repeat (4) @(negedge clk_sys);
			@(negedge clk_sys); vs = 1;
			// active: res is sampled here
			@(negedge clk_sys); vblank = 0; hblank = 0;
			repeat (active_sys_cycles) @(negedge clk_sys);
			@(negedge clk_sys); vblank = 1; hblank = 1;
		end
	endtask

	// Run one rate: two frames to arm (the first sets fs_res, the second's vs
	// edge applies it), then a counted frame.
	task measure(input [1:0] r, input f28, input integer active, input [511:0] name);
		begin
			res = r; force_28 = f28;
			frame(active);
			frame(active);
			n_new = 0; n_ref = 0;
			counting = 1;
			frame(active);
			counting = 0;
			$display("info: %0s -- new %0d enables, reference %0d", name, n_new, n_ref);
			ok(n_new == n_ref, name);
			ok(n_new != 0, {name, " produced any pixels at all"});
		end
	endtask

	initial begin
		$display("tb_video_ce");

		// Let both arms see a vs edge before anything is measured.
		frame(64);

		//                res  f28  active  name
		measure(2'b00, 1'b0, 400, "lores: one pixel in four");
		measure(2'b01, 1'b0, 400, "hires: one pixel in two");
		measure(2'b10, 1'b0, 400, "superhires: every cycle");
		measure(2'b00, 1'b1, 400, "force_28 overrides lores");
		measure(2'b01, 1'b1, 400, "force_28 overrides hires");

		// The rates must be in the ratio the Amiga uses, not merely equal
		// between the arms -- two arms that were both wrong by the same factor
		// would pass everything above.
		begin : ratios
			integer lo, hi, su;
			res = 2'b00; force_28 = 0;
			frame(400); frame(400);
			n_new = 0; counting = 1; frame(400); counting = 0; lo = n_new;
			res = 2'b01;
			frame(400); frame(400);
			n_new = 0; counting = 1; frame(400); counting = 0; hi = n_new;
			res = 2'b10;
			frame(400); frame(400);
			n_new = 0; counting = 1; frame(400); counting = 0; su = n_new;
			$display("info: enables per frame -- lores %0d, hires %0d, superhires %0d",
			         lo, hi, su);
			ok(hi == 2 * lo, "hires is twice lores");
			ok(su == 2 * hi, "superhires is twice hires");
		end

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#2000000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
