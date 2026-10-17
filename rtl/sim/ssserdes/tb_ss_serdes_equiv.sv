// ss_serdes went from an addressed shifter (shifter[count*32 +: 32]) to a real
// shift register, to take a word mux and a per-word count decode off two
// clk_114 paths that missed setup. This runs the new module against the old one
// (ss_serdes_ref.v, frozen copy, module renamed) and requires every output to
// match on every clock.
//
// Stimulus is random but shaped like ss_ctrl's use: saves of a vector that keeps
// changing underneath, loads fed with gaps between words, loads restarted part
// way through, saves restarted, and stray word_in_valid while idle. The one
// thing excluded is a save and a load starting on the same idle cycle -- both
// versions then run both directions at once on one shifter, ss_ctrl never does
// it, and the old module's result there is not something worth preserving.
//
// WIDTH is a parameter; CI runs one word (32), a ragged top word (77) and the
// real vector's order of size (1530), because WORDS == 1 takes a different
// generate branch and a ragged top word is where padding would show.
//
// The checks are only meaningful if the interesting events happened, so the
// bench counts completed saves, completed loads and state_we pulses and fails
// on zero.
`timescale 1ns/1ns
module tb_ss_serdes_equiv;
parameter WIDTH = 77;

reg clk = 0, rst_n = 0;
reg save_start = 0, load_start = 0, word_in_valid = 0;
reg [WIDTH-1:0] state_in = 0;
reg [31:0] word_in = 0;

wire wv_d, sd_d, ld_d, we_d, wv_r, sd_r, ld_r, we_r;
wire [31:0] wo_d, wo_r;
wire [WIDTH-1:0] so_d, so_r;

ss_serdes #(.WIDTH(WIDTH)) dut (
	.clk(clk), .rst_n(rst_n),
	.save_start(save_start), .state_in(state_in),
	.word_valid(wv_d), .word_out(wo_d), .save_done(sd_d),
	.load_start(load_start), .word_in_valid(word_in_valid), .word_in(word_in),
	.load_done(ld_d), .state_out(so_d), .state_we(we_d));

ss_serdes_ref #(.WIDTH(WIDTH)) ref_i (
	.clk(clk), .rst_n(rst_n),
	.save_start(save_start), .state_in(state_in),
	.word_valid(wv_r), .word_out(wo_r), .save_done(sd_r),
	.load_start(load_start), .word_in_valid(word_in_valid), .word_in(word_in),
	.load_done(ld_r), .state_out(so_r), .state_we(we_r));

integer cyc = 0, mism = 0, saves = 0, loads = 0, wes = 0, i;

always #5 clk = ~clk;

localparam PADW = ((WIDTH + 31) / 32) * 32;
function [WIDTH-1:0] rand_vec;
	input dummy;
	integer k;
	reg [PADW-1:0] t;
	begin
		for (k = 0; k < PADW; k = k + 32) t[k +: 32] = $urandom;
		rand_vec = t[WIDTH-1:0];
	end
endfunction

always @(negedge clk) if (rst_n) begin
	cyc = cyc + 1;
	if (sd_r) saves = saves + 1;
	if (ld_r) loads = loads + 1;
	if (we_r) wes = wes + 1;
	if ({wv_d, sd_d, ld_d, we_d, wo_d, so_d} !== {wv_r, sd_r, ld_r, we_r, wo_r, so_r}) begin
		if (mism < 10)
			$display("MISMATCH cyc %0d: wv %b/%b sd %b/%b ld %b/%b we %b/%b wo %h/%h so %h/%h",
				cyc, wv_d, wv_r, sd_d, sd_r, ld_d, ld_r, we_d, we_r, wo_d, wo_r, so_d, so_r);
		mism = mism + 1;
	end
end

// The reference's own view of whether a direction is running, to keep the
// stimulus inside what ss_ctrl does without peeking at the DUT.
wire busy_save = ref_i.saving | ref_i.save_finish;
wire busy_load = ref_i.loading;

initial begin
	repeat (3) @(posedge clk);
	#1 rst_n = 1;
	for (i = 0; i < 40000; i = i + 1) begin
		@(posedge clk); #1;
		state_in      = ($urandom % 4 == 0) ? rand_vec(0) : state_in;
		word_in       = $urandom;
		save_start    = 0;
		load_start    = 0;
		word_in_valid = 0;
		case ($urandom % 128)
			0:  if (!busy_load) save_start = 1;          // includes restarting a save
			1:  if (!busy_save) load_start = 1;          // includes restarting a load
			default: word_in_valid = ($urandom % 3 != 0);   // gaps, and strays while idle
		endcase
		// never both starts on one cycle (see header)
		if (save_start && load_start) load_start = 0;
	end
	repeat (10) @(posedge clk);
	$display("WIDTH %0d: cycles %0d, saves %0d, loads %0d, state_we %0d, mismatches %0d",
		WIDTH, cyc, saves, loads, wes, mism);
	if (saves == 0) $display("FAIL: no save completed");
	if (loads == 0) $display("FAIL: no load completed");
	if (wes == 0)   $display("FAIL: state_we never pulsed");
	if (mism == 0 && saves > 0 && loads > 0 && wes > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
