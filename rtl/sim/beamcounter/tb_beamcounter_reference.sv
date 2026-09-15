// agnus_beamcounter's VPOSR/VHPOSR against an independent implementation.
//
// docs/core-accuracy-todo.md opens by saying we cannot measure against real
// hardware, and T7 -- "characterise what the beam counter still gets wrong" --
// has sat at [SUITE] ever since, meaning it needs a MiSTer, a screen, and a
// person reading it. This bench is the other half of a way round that: the
// table it reads, rtl/sim/beamcounter/beam-reference.tsv, is generated from
// Copperline (tools/copperline-beamtable.sh), a separately written cycle-driven
// Amiga emulator. Copperline is not silicon, so this is a second opinion and
// not ground truth -- see WHAT THIS DOES NOT CLAIM.
//
// WHAT IS COMPARABLE, AND WHAT IS NOT
//
// Not comparable: the absolute horizontal readback. Our VHPOSR reports
// hpos[8:1]-1 (the 06f30af decrement); Copperline's reports its own hpos+3.
// Neither internal counter's zero point is a shared reference, so the four
// clocks between those are not a defect in either -- they are two different
// origins. Asserting on the absolute value would be asserting that the two
// implementations chose the same arbitrary zero.
//
// Comparable, and what this bench checks:
//
//   1. dhpos is CONSTANT, with one documented exception. Whatever the offset
//      is, it must be the same at every beam position: a per-position wobble is
//      a real defect in a counter that should be linear. Ours is -1, except at
//      hpos[8:1]==0 where agnus_beamcounter.v:212 deliberately reports
//      htotal_cck instead of wrapping to -1. That exception is in the RTL on
//      purpose, so the bench encodes it rather than flagging it -- the first
//      version of this check did not, and reported sixteen false defects.
//
//   2. The two readbacks DESCRIBE ONE vpos. This is where the table earned its
//      keep, and it is the only vertical check worth making: vposr[0] alone is
//      nearly always right by luck, because vpos[8] changes twice a frame and
//      is stable everywhere else. So instead of scoring the halves separately,
//      reassemble them -- {vposr[0], vhposr[15:8]} is a 9-bit vpos -- and ask
//      how far behind the live counter that lands. A readback pair taken from
//      one instant lags by a few colour clocks. A pair whose halves come from
//      DIFFERENT instants jumps by 256 at the frame wrap, which no amount of
//      pipeline delay explains.
//
//      Copperline does exactly that: at (vpos 0, hpos 0) its VHPOSR has already
//      wrapped to line 0 while its VPOSR still carries vpos[8] from line 312,
//      reassembling to 256 against a live vpos of 0. Ours reads both halves
//      from the same vpos_rb, so ours should lag together and never split.
//      That difference is the finding; this bench pins it so a future sync
//      cannot quietly introduce a split here.
//
// WHAT THIS DOES NOT CLAIM
//
// A mismatch is a question, not a verdict. Copperline is a third
// implementation, not a reference machine; where it and this core disagree,
// either may be wrong. The bench therefore reports counts and fails when they
// MOVE from the baselines below -- in either direction. A drop is a regression.
// A rise is progress, and should be banked by updating the baseline in the same
// commit that earns it, with the reason written down.
//
// The table's resolution is ~5 colour clocks, because Copperline's run_until
// stops at instruction resolution. A lag narrower than that is bounded by the
// table, not pinned by it. Pinning it needs a guest polling loop -- what the
// vAmigaTS VPOS suite does -- not a debugger.
//
// Runs standalone under Icarus, from this directory so the relative path to the
// table resolves:
//   iverilog -g2012 -o tb_ref ../../agnus_beamcounter.v tb_beamcounter_reference.sv
//   vvp tb_ref

`timescale 1ns/1ps

module tb_beamcounter_reference;

	localparam [8:1] A_VPOSR  = 8'h02;   // 9'h004 >> 1
	localparam [8:1] A_VHPOSR = 8'h03;   // 9'h006 >> 1

	// Baselines. See WHAT THIS DOES NOT CLAIM before changing one.
	localparam integer EXPECT_DHPOS    = -1;   // ours, away from the line wrap
	localparam integer EXPECT_HTOTAL   = 226;  // PAL: what VHPOSR reports at hpos 0
	localparam integer VTOTAL = 312;           // PAL: vpos runs 0..312
	localparam integer EXPECT_SPLIT_ROWS = 0;  // samples whose two readback
	                                           // halves do not describe one line

	reg         clk = 0;
	reg         clk7_en = 0;
	reg         reset = 1;
	reg         cck = 0;
	reg  [15:0] data_in = 0;
	reg  [8:1]  reg_address_in = A_VHPOSR;

	wire [15:0] data_out;
	wire [8:0]  hpos;
	wire [10:0] vpos;

	integer errors = 0;

	always #1 clk = ~clk;

	reg [1:0] phase = 0;
	always @(posedge clk) begin
		phase   <= phase + 2'd1;
		clk7_en <= (phase == 2'd0);
	end
	always @(posedge clk) if (clk7_en) cck <= ~cck;

	agnus_beamcounter dut (
		.clk(clk), .clk7_en(clk7_en), .reset(reset), .cck(cck),
		.ntsc(1'b0), .aga(1'b1), .ecs(1'b1), .a1k(1'b0),
		.data_in(data_in), .data_out(data_out), .reg_address_in(reg_address_in),
		.lpen_vpos(11'h7FF), .lpen_hpos(9'd0),
		.hpos(hpos), .vpos(vpos),
		._hsync(), ._vsync(), .field1(), .lace(), ._csync(),
		.hblank(), .vblank(), .vbl(), .vblend(),
		.eol(), .eof(), .vbl_int(),
		.htotal_out(), .harddis_out(), .varbeamen_out()
	);

	// ---- the reference table -------------------------------------------
	// Indexed by beam position so a row can be found from the free-running
	// counter without searching. 320 lines x 240 colour clocks covers PAL with
	// room; a position outside it simply has no reference row.
	localparam integer MAXV = 320;
	localparam integer MAXH = 240;

	reg        ref_present [0:MAXV*MAXH-1];
	reg [15:0] ref_vposr   [0:MAXV*MAXH-1];
	reg [15:0] ref_vhposr  [0:MAXV*MAXH-1];
	integer    ref_rows = 0;

	// Ours, sampled when the counter reaches a position the table covers.
	reg        got       [0:MAXV*MAXH-1];
	reg [15:0] our_vposr [0:MAXV*MAXH-1];
	reg [15:0] our_vhposr[0:MAXV*MAXH-1];
	reg [10:0] our_vpos  [0:MAXV*MAXH-1];

	integer fd, code, i;
	reg [1023:0] line;
	integer t_vpos, t_hpos, t_vposr, t_vhposr, t_dhpos, t_vok, t_pok;

	task load_table;
		begin
			fd = $fopen("beam-reference.tsv", "r");
			if (fd == 0) begin
				$display("FAIL: cannot open beam-reference.tsv -- run this bench");
				$display("      from rtl/sim/beamcounter/, or regenerate it with");
				$display("      tools/copperline-beamtable.sh");
				errors = errors + 1;
				disable load_table;
			end
			while (!$feof(fd)) begin
				code = $fgets(line, fd);
				if (code != 0) begin
					// Comments and the column header are skipped by requiring
					// seven integers; %x on a 0x-prefixed field reads the hex.
					code = $sscanf(line, "%d\t%d\t0x%x\t0x%x\t%d\t%d\t%d",
					               t_vpos, t_hpos, t_vposr, t_vhposr,
					               t_dhpos, t_vok, t_pok);
					if (code == 7 && t_vpos < MAXV && t_hpos < MAXH) begin
						i = t_vpos * MAXH + t_hpos;
						ref_present[i] = 1'b1;
						ref_vposr[i]   = t_vposr[15:0];
						ref_vhposr[i]  = t_vhposr[15:0];
						ref_rows = ref_rows + 1;
					end
				end
			end
			$fclose(fd);
		end
	endtask

	// ---- sampling -------------------------------------------------------
	// VPOSR and VHPOSR are combinational on reg_address_in, so both are read by
	// driving the address and waiting a delta. Done in a task rather than with
	// two always blocks so the pair is taken at ONE instant -- reading them a
	// cycle apart would manufacture exactly the split this bench is looking for.
	// The invariants are checked at EVERY colour clock, not only where the table
	// has a row. That distinction is the whole reason this task looks the way it
	// does: the first version evaluated them only at the 175 reference
	// positions, and none of those lands where the one-colour-clock lag is
	// observable -- so the bench PASSED against a DUT deliberately mutated to
	// read VPOSR from the live counter and VHPOSR from vpos_rb, which is the
	// exact split it exists to catch. The table supplies comparison points; it
	// must not gate the checking.
	integer n_dense, n_off_bad, n_lag_bad, n_max_lag;
	integer dd, rb, lag;

	task sample_here;
		integer idx;
		reg [15:0] p, h;
		begin
			reg_address_in = A_VPOSR;  #0; p = data_out;
			reg_address_in = A_VHPOSR; #0; h = data_out;

			n_dense = n_dense + 1;

			// 1. The horizontal offset, with the documented hpos 0 case.
			if (hpos[8:1] == 0) begin
				if ((h & 16'h00FF) != EXPECT_HTOTAL) begin
					if (n_off_bad < 5)
						$display("  hpos 0 at vpos %0d reports %0d, want htotal_cck %0d",
						         vpos, h & 16'h00FF, EXPECT_HTOTAL);
					n_off_bad = n_off_bad + 1;
				end
			end
			else begin
				dd = ((h & 16'h00FF) - hpos[8:1] + 128) % 256 - 128;
				if (dd != EXPECT_DHPOS) begin
					if (n_off_bad < 5)
						$display("  dhpos %0d at vpos %0d hpos %0d (want %0d)",
						         dd, vpos, hpos[8:1], EXPECT_DHPOS);
					n_off_bad = n_off_bad + 1;
				end
			end

			// 2. Reassemble the vpos the two halves jointly describe, and require
			//    it to be a line the beam was ACTUALLY recently on: the current
			//    one, or the one immediately before it. vpos_rb is two clk7_en
			//    stages behind, so at a line boundary the readback legitimately
			//    still reports the previous line -- including across the frame
			//    wrap, where the previous line is VTOTAL and not -1.
			//
			//    Measuring a numeric distance instead does not work, and the
			//    first version of this check did: (vpos - rb) mod 512 is a
			//    difference in LINE NUMBERS, so a one-line lag over the wrap
			//    (312 against 0) reads as 200 and looks like a catastrophe.
			//
			//    Stated this way the two implementations separate cleanly. Ours
			//    reassembles to 312 at (vpos 0) -- the previous line, consistent.
			//    Copperline reassembles to 256, which is not the current line,
			//    not the previous one, and not a line the beam had been on at
			//    all: its VHPOSR had wrapped to 0 while its VPOSR still carried
			//    vpos[8] from line 312. That is two halves from two instants.
			rb  = {p[0], h[15:8]};
			lag = (vpos == 0) ? VTOTAL : (vpos - 1);
			if (rb != vpos && rb != lag) begin
				if (n_lag_bad < 5)
					$display("  readback describes line %0d at vpos %0d hpos %0d (want %0d or %0d): VPOSR=%04x VHPOSR=%04x",
					         rb, vpos, hpos[8:1], vpos, lag, p, h);
				n_lag_bad = n_lag_bad + 1;
			end
			if (rb != vpos) n_max_lag = n_max_lag + 1;

			// The table's rows are recorded for the comparison count only.
			idx = vpos * MAXH + hpos[8:1];
			if (vpos < MAXV && hpos[8:1] < MAXH && ref_present[idx] && !got[idx]) begin
				got[idx]        = 1'b1;
				our_vposr[idx]  = p;
				our_vhposr[idx] = h;
				our_vpos[idx]   = vpos;
			end
		end
	endtask

	integer n_compared, n_missing;

	initial begin
		for (i = 0; i < MAXV*MAXH; i = i + 1) begin
			ref_present[i] = 1'b0;
			got[i]         = 1'b0;
		end
		n_dense = 0; n_off_bad = 0; n_lag_bad = 0; n_max_lag = 0;
		load_table;
		if (errors != 0) begin
			$display("RUN: FAIL (%0d errors)", errors);
			$finish;
		end
		$display("reference rows loaded: %0d", ref_rows);

		dut.vpos        = 11'd0;
		dut.hpos        = 9'd0;
		dut.end_of_line = 1'b0;
		dut.vpos_inc    = 1'b0;
		dut.long_line   = 1'b0;
		dut.long_frame  = 1'b0;
		dut.extra_line  = 1'b0;
		dut.vser        = 1'b0;

		repeat (4) @(posedge clk);
		reset = 0;

		// Two frames: one to settle the pipeline, one to sample. A PAL frame is
		// 313 lines of 227 colour clocks and the counter advances on cck, so a
		// frame is ~142k clk edges at this bench's 4:1 clk:clk7_en ratio.
		for (i = 0; i < 2*313*227*8; i = i + 1) begin
			@(posedge clk);
			if (clk7_en) sample_here;
		end

		// ---- compare ---------------------------------------------------
		n_compared = 0; n_missing = 0;

		for (i = 0; i < MAXV*MAXH; i = i + 1) begin
			if (ref_present[i]) begin
				if (!got[i]) n_missing = n_missing + 1;
				else          n_compared = n_compared + 1;
			end
		end

		$display("positions checked     : %0d (every colour clock, two frames)", n_dense);
		$display("compared              : %0d of %0d reference rows", n_compared, ref_rows);
		$display("positions not reached : %0d", n_missing);
		$display("horizontal offset bad : %0d", n_off_bad);
		$display("samples reading the previous line: %0d (legitimate: vpos_rb lag)", n_max_lag);
		$display("samples describing NO recent line: %0d (baseline %0d)", n_lag_bad, EXPECT_SPLIT_ROWS);
		$display("reference, same metric: Copperline reassembles to 256 at (vpos 0,");
		$display("                        hpos 0) -- neither the current line nor the");
		$display("                        previous one. Ours reassembles to 312 there.");

		if (n_compared == 0) begin
			$display("FAIL: no reference row was reached -- nothing was compared");
			errors = errors + 1;
		end
		if (n_dense < 100000) begin
			$display("FAIL: only %0d positions checked -- the sweep did not run", n_dense);
			errors = errors + 1;
		end
		if (n_off_bad != 0) begin
			$display("FAIL: the horizontal readback offset is not as documented");
			errors = errors + 1;
		end
		if (n_lag_bad != EXPECT_SPLIT_ROWS) begin
			$display("FAIL: readback consistency count moved from its baseline.");
			$display("      UP means a sync introduced a split. DOWN means progress:");
			$display("      say why and update EXPECT_SPLIT_ROWS in the same commit.");
			errors = errors + 1;
		end

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d errors)", errors);
		$finish;
	end

	initial begin
		#400000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
