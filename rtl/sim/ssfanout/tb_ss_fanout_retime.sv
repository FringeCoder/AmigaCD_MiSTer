/*
 * tb_ss_fanout_retime.sv -- the clk_sys retiming in front of ss_state_fanout.
 *
 * AmigaCD.sv hands the restore state vector to ss_state_fanout through a
 * clk_sys register bank, so that the ~2000 clk_114-to-clk_sys crossings the
 * fan-out used to make are replaced by one. The bank is three lines of code in
 * a file no bench compiles, and what it changes -- which vector the fan-out
 * acts on -- is invisible to a timing report.
 *
 * state_out and state_we go valid TOGETHER, so a retimed vector arrives one
 * clk_sys cycle after the request that announces it. Whether that matters is a
 * property of the sequencer, not of the retiming: on the cycle it first sees
 * req it only enters `running` and clears `step`, and it does not read `state`
 * until a cycle later. One cycle of skew is therefore absorbed.
 *
 * That is worth a bench rather than a comment, because it is the thing that
 * makes the retiming safe, it lives in a different file from the retiming, and
 * nothing else states it. Three wirings run the same restores:
 *
 *   raw         what AmigaCD.sv did before -- the reference answer
 *   aligned     state and req both retimed one clk_sys cycle -- the change
 *   misaligned  state retimed, req not -- one cycle of deliberate skew
 *
 * All three must agree. aligned agreeing is the change being correct;
 * misaligned agreeing is the sequencer's entry cycle doing its job. If a
 * future change makes the sequencer read `state` on the cycle it accepts req,
 * the misaligned arm fails here -- and that is the signal that retiming req
 * alongside the data has stopped being belt-and-braces and become load-bearing.
 *
 * An earlier version of this bench asserted the opposite, that misaligned MUST
 * diverge, on the assumption that the skew was a live hazard. It is not, and
 * the arm had to be inverted rather than deleted: the assumption was wrong and
 * the thing it was guessing at is worth pinning down.
 */
`timescale 1ns/1ps

module tb_ss_fanout_retime;

	localparam integer STATE_W = 1041 + 1052;   // SS_STATE_W, Akiko included

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

	// clk_114 and clk_sys, 4:1 and edge-aligned, which is the relationship on
	// the device and what makes the hold check on the raw crossing a
	// coincident-edge one. Both start low at t=0, so every fourth clk_114
	// posedge coincides with a clk_sys posedge.
	reg clk_114 = 0;
	reg clk_sys = 0;
	always #4  clk_114 = ~clk_114;
	always #16 clk_sys = ~clk_sys;

	reg rst_n = 0;

	// ---- two vectors, every field distinct between them --------------------
	function [STATE_W-1:0] mkvec(input [7:0] tag);
		reg [31:0] r [0:15];
		integer j;
		begin
			for (j = 0; j < 16; j = j + 1) r[j] = {tag, 4'd0, j[3:0], 16'hBEEF};
			mkvec = { r[0],  r[1],  r[2],  r[3],  r[4],  r[5],  r[6],  r[7],
			          r[8],  r[9],  r[10], r[11], r[12], r[13], r[14], r[15],
			          {tag, 24'h00_00D2},            // PC
			          {tag, 24'h07_FFF0},            // USP
			          {tag, 24'h00_0400},            // VBR
			          {8'h27, tag},                  // SR
			          4'b1010,                       // CACR
			          1'b1, 1'b0, 1'b1, 1'b1,        // OVL, ROM_RO, K1MB, K256
			          {7'h28, tag},                  // INTREQ, 15 bits
			          {{183{1'b0}}, tag},            // CIA A, 191
			          {{195{1'b0}}, tag},            // CIA B, 203
			          {{1044{1'b0}}, tag} };         // Akiko, 1052
		end
	endfunction

	reg [STATE_W-1:0] vec1, vec2;

	// The vector as ss_ctrl presents it, and the single clk_114 pulse beside it.
	reg [STATE_W-1:0] state_out = 0;
	reg               state_we  = 0;

	// ---- three wirings -----------------------------------------------------
	//
	// Each arm gets its own copy of AmigaCD.sv's clk_114 request latch, because
	// each has its own ack to clear it.
	reg req_raw = 0, req_ali = 0, req_mis = 0;
	wire ack_raw, ack_ali, ack_mis;

	always @(posedge clk_114) begin
		if (!rst_n)        req_raw <= 1'b0;
		else if (ack_raw)  req_raw <= 1'b0;
		else if (state_we) req_raw <= 1'b1;
	end
	always @(posedge clk_114) begin
		if (!rst_n)        req_ali <= 1'b0;
		else if (ack_ali)  req_ali <= 1'b0;
		else if (state_we) req_ali <= 1'b1;
	end
	always @(posedge clk_114) begin
		if (!rst_n)        req_mis <= 1'b0;
		else if (ack_mis)  req_mis <= 1'b0;
		else if (state_we) req_mis <= 1'b1;
	end

	// The retiming bank, exactly as AmigaCD.sv has it.
	reg [STATE_W-1:0] state_q;
	reg               req_ali_q;
	always @(posedge clk_sys) begin
		state_q   <= state_out;
		req_ali_q <= req_ali;
	end

	// ---- the three fan-outs ------------------------------------------------
	wire  [3:0] wi_raw, wi_ali, wi_mis;
	wire [31:0] wd_raw, wd_ali, wd_mis;
	wire        we_raw, we_ali, we_mis;
	wire        pc_raw, pc_ali, pc_mis;

	ss_state_fanout #(.STATE_W(STATE_W)) f_raw (
		.clk(clk_sys), .rst_n(rst_n), .req(req_raw), .ack(ack_raw),
		.state(state_out),
		.cpu_wr_index(wi_raw), .cpu_wr_data(wd_raw), .cpu_wr_en(we_raw),
		.cpu_pc_wr(pc_raw), .cpu_sr_wr(), .cpu_usp_wr(), .cpu_vbr_wr(),
		.cpu_cacr_wr(), .cpu_resume(), .map_in(), .map_we(), .intreq_out(),
		.cia_a_out(), .cia_b_out(), .cia_we(), .akiko_out(), .akiko_we(),
		.busy());

	ss_state_fanout #(.STATE_W(STATE_W)) f_ali (
		.clk(clk_sys), .rst_n(rst_n), .req(req_ali_q), .ack(ack_ali),
		.state(state_q),
		.cpu_wr_index(wi_ali), .cpu_wr_data(wd_ali), .cpu_wr_en(we_ali),
		.cpu_pc_wr(pc_ali), .cpu_sr_wr(), .cpu_usp_wr(), .cpu_vbr_wr(),
		.cpu_cacr_wr(), .cpu_resume(), .map_in(), .map_we(), .intreq_out(),
		.cia_a_out(), .cia_b_out(), .cia_we(), .akiko_out(), .akiko_we(),
		.busy());

	ss_state_fanout #(.STATE_W(STATE_W)) f_mis (
		.clk(clk_sys), .rst_n(rst_n), .req(req_mis), .ack(ack_mis),
		.state(state_q),
		.cpu_wr_index(wi_mis), .cpu_wr_data(wd_mis), .cpu_wr_en(we_mis),
		.cpu_pc_wr(pc_mis), .cpu_sr_wr(), .cpu_usp_wr(), .cpu_vbr_wr(),
		.cpu_cacr_wr(), .cpu_resume(), .map_in(), .map_we(), .intreq_out(),
		.cia_a_out(), .cia_b_out(), .cia_we(), .akiko_out(), .akiko_we(),
		.busy());

	// ---- observers ---------------------------------------------------------
	reg [31:0] reg_raw [0:15];
	reg [31:0] reg_ali [0:15];
	reg [31:0] reg_mis [0:15];
	reg [31:0] pcv_raw, pcv_ali, pcv_mis;
	integer n_raw = 0, n_ali = 0, n_mis = 0;

	always @(posedge clk_sys) if (rst_n) begin
		if (we_raw) begin reg_raw[wi_raw] = wd_raw; n_raw = n_raw + 1; end
		if (we_ali) begin reg_ali[wi_ali] = wd_ali; n_ali = n_ali + 1; end
		if (we_mis) begin reg_mis[wi_mis] = wd_mis; n_mis = n_mis + 1; end
		if (pc_raw) pcv_raw = wd_raw;
		if (pc_ali) pcv_ali = wd_ali;
		if (pc_mis) pcv_mis = wd_mis;
	end

	task clear_capture;
		integer j;
		begin
			for (j = 0; j < 16; j = j + 1) begin
				reg_raw[j] = 32'hDEADBEEF;
				reg_ali[j] = 32'hDEADBEEF;
				reg_mis[j] = 32'hDEADBEEF;
			end
			pcv_raw = 32'hDEADBEEF;
			pcv_ali = 32'hDEADBEEF;
			pcv_mis = 32'hDEADBEEF;
			n_raw = 0; n_ali = 0; n_mis = 0;
		end
	endtask

	// Each arm acknowledges at its own moment -- the retimed ones a cycle or
	// two behind -- and ack is dropped as soon as req clears, so the three are
	// never simultaneously high. Waiting on the live signals deadlocks; these
	// sticky flags are what makes "all three have finished" a thing that can
	// be waited for.
	reg seen_raw = 0, seen_ali = 0, seen_mis = 0;
	always @(posedge clk_sys) begin
		if (ack_raw) seen_raw <= 1'b1;
		if (ack_ali) seen_ali <= 1'b1;
		if (ack_mis) seen_mis <= 1'b1;
	end

	task run_restore;
		begin
			wait (seen_raw && seen_ali && seen_mis);
			repeat (12) @(posedge clk_sys);
			seen_raw = 0; seen_ali = 0; seen_mis = 0;
		end
	endtask

	integer i, ph, diff_ali, diff_mis;
	integer ali_bad = 0, mis_caught = 0, ref_wrong = 0, count_bad = 0;
	reg [31:0] want;

	// Load a vector and run one restore through all three arms, with the
	// vector CHANGING at a chosen phase of clk_sys.
	//
	// Every phase, because clk_sys is a quarter of clk_114 and the window in
	// which req has arrived and the retimed vector has not is one clk_sys
	// cycle wide: only one of the four phases of a state_we pulse lands in it,
	// and a bench that pulsed at a single fixed phase would never enter it.
	task restore_at_phase(input integer phase, input [8:0] tag);
		begin
			clear_capture();
			@(posedge clk_sys);
			repeat (phase + 1) @(negedge clk_114);
			state_out = mkvec(tag[7:0]);
			state_we  = 1;
			@(negedge clk_114);
			state_we  = 0;
			run_restore();
		end
	endtask

	initial begin
		$display("tb_ss_fanout_retime");
		vec1 = mkvec(8'h11);
		vec2 = mkvec(8'h22);
		clear_capture();

		repeat (8) @(posedge clk_sys);
		rst_n = 1;
		repeat (2) @(posedge clk_sys);

		// ---- restore 1. Nothing unusual: the vector has been sitting there.
		@(negedge clk_114);
		state_out = vec1;
		repeat (8) @(posedge clk_sys);
		@(negedge clk_114);
		state_we = 1;
		@(negedge clk_114);
		state_we = 0;
		run_restore();

		ok(n_raw == 16, "settled vector: reference wrote sixteen registers");
		ok(n_ali == 16, "settled vector: aligned wrote sixteen registers");
		diff_ali = 0;
		for (i = 0; i < 16; i = i + 1)
			if (reg_ali[i] !== reg_raw[i]) diff_ali = diff_ali + 1;
		ok(diff_ali == 0, "settled vector: aligned agrees with the reference");
		ok(pcv_ali === pcv_raw, "settled vector: aligned PC agrees");

		// ---- the hazard, at every phase. The vector changes on the same
		//      clk_114 edge that pulses state_we, which is what a restore
		//      following straight on from another one looks like.
		for (ph = 0; ph < 4; ph = ph + 1) begin
			restore_at_phase(ph, {1'b0, 8'h20} + ph[8:0]);

			if (n_raw != 16 || n_ali != 16 || n_mis != 16)
				count_bad = count_bad + 1;

			// The reference is the answer, and it has to be the NEW vector or
			// this iteration proves nothing about either retimed arm.
			want = {8'h20 + ph[7:0], 4'd0, 4'd0, 16'hBEEF};
			if (reg_raw[0] !== want) ref_wrong = ref_wrong + 1;

			diff_ali = 0;
			diff_mis = 0;
			for (i = 0; i < 16; i = i + 1) begin
				if (reg_ali[i] !== reg_raw[i]) diff_ali = diff_ali + 1;
				if (reg_mis[i] !== reg_raw[i]) diff_mis = diff_mis + 1;
			end
			if (diff_ali != 0 || pcv_ali !== pcv_raw) ali_bad = ali_bad + 1;
			if (diff_mis != 0 || pcv_mis !== pcv_raw) mis_caught = mis_caught + 1;
			$display("info: phase %0d -- aligned differs in %0d of 16, misaligned in %0d",
			         ph, diff_ali, diff_mis);
		end

		ok(count_bad == 0, "every phase: all three arms wrote sixteen registers");
		ok(ref_wrong == 0, "every phase: the reference took the new vector");
		ok(ali_bad == 0,   "every phase: aligned agrees with the reference");

		// The sequencer's entry cycle. This is what makes retiming req
		// alongside the data belt-and-braces rather than load-bearing, and it
		// is a property of ss_state_fanout, so it is asserted here and not
		// assumed in AmigaCD.sv. A failure means the sequencer now reads
		// `state` on the cycle it accepts req, and the req flop in AmigaCD.sv
		// has become the only thing keeping a restore off the previous
		// vector -- which is worth being told about rather than discovering.
		ok(mis_caught == 0,
		   "every phase: one cycle of skew absorbed by the entry cycle");

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#500000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
