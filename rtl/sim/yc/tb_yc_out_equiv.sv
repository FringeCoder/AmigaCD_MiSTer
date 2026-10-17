// sys/yc_out.sv carries a local retiming (see the comment above its
// chroma_*_val registers): the sine ROM moved in front of the register that
// fed the U/V multipliers, to close the 114 MHz fit. This bench runs it against
// the upstream module unchanged (yc_out_ref.sv, MiSTer-devel sys/yc_out.sv with
// the module renamed) and requires every output to match on every clock.
//
// Stimulus is line-shaped, not just random: hsync resets the colour-burst
// counter and the burst window is a band of cycles after it, so purely random
// syncs would almost never reach the burst branch. Each configuration runs
// whole lines with random pixels, NTSC and PAL (PAL_FLIP alternates per line),
// CVBS on and off, and a random subcarrier increment and burst window.
//
// The checks are only meaningful if both branches ran, so the bench also
// counts burst and active-chroma cycles in the reference and fails on zero.
//
// It reads dut.chroma_SIN_val by name. If a sys/ resync reverts the retiming,
// that name is gone and this bench stops building -- the point at which the
// fit would start missing setup again.
//
// Built with Verilator rather than Icarus: yc_out uses an unpacked struct array and an array
// localparam, which Icarus 12 does not support.
`timescale 1ns/1ps
module tb_yc_out_equiv;

reg         clk = 0;
reg  [39:0] PHASE_INC = 0;
reg         PAL_EN = 0;
reg         CVBS = 0;
reg  [16:0] COLORBURST_RANGE = 0;
reg         hsync = 0, vsync = 0, csync = 0, de = 0;
reg  [23:0] din = 0;

wire [23:0] dout_d, dout_r;
wire hs_d, vs_d, cs_d, de_d, hs_r, vs_r, cs_r, de_r;

yc_out dut (
	.clk(clk), .PHASE_INC(PHASE_INC), .PAL_EN(PAL_EN), .CVBS(CVBS),
	.COLORBURST_RANGE(COLORBURST_RANGE),
	.hsync(hsync), .vsync(vsync), .csync(csync), .de(de), .din(din),
	.dout(dout_d), .hsync_o(hs_d), .vsync_o(vs_d), .csync_o(cs_d), .de_o(de_d)
);

yc_out_ref ref_i (
	.clk(clk), .PHASE_INC(PHASE_INC), .PAL_EN(PAL_EN), .CVBS(CVBS),
	.COLORBURST_RANGE(COLORBURST_RANGE),
	.hsync(hsync), .vsync(vsync), .csync(csync), .de(de), .din(din),
	.dout(dout_r), .hsync_o(hs_r), .vsync_o(vs_r), .csync_o(cs_r), .de_o(de_r)
);

integer cycles = 0, mism = 0, burst_cycles = 0, chroma_cycles = 0;
integer line, x, cfg;
localparam integer LINE  = 1200;   // clocks per line
localparam integer HSW   = 80;     // hsync width
localparam integer DE_LO = 260, DE_HI = 1150;
localparam integer LINES = 24;     // per configuration
localparam integer CFGS  = 8;

// A revert of the retiming removes this register and the bench stops building.
wire signed [10:0] retimed_sin = dut.chroma_SIN_val;

always #4.37 clk = ~clk;

always @(negedge clk) begin
	cycles = cycles + 1;
	if (ref_i.phase[2].burst) burst_cycles = burst_cycles + 1;
	if (ref_i.phase[2].chroma_en) chroma_cycles = chroma_cycles + 1;
	if ({dout_d, hs_d, vs_d, cs_d, de_d} !== {dout_r, hs_r, vs_r, cs_r, de_r}) begin
		if (mism < 10)
			$display("MISMATCH cfg %0d line %0d x %0d: dout %h vs ref %h, syncs %b%b%b%b vs %b%b%b%b",
				cfg, line, x, dout_d, dout_r, hs_d, vs_d, cs_d, de_d, hs_r, vs_r, cs_r, de_r);
		mism = mism + 1;
	end
end

initial begin
	for (cfg = 0; cfg < CFGS; cfg = cfg + 1) begin
		PAL_EN = cfg[0];
		CVBS   = cfg[1];
		// Subcarrier around 3.58 / 4.43 MHz at 114 MHz, jittered so the LUT
		// index walks through every quadrant at different rates.
		PHASE_INC = (PAL_EN ? 40'd42577353048 : 40'd34387094183) + {$random} % 40'd1000000000;
		// Burst window start [16:10], end [9:0].
		COLORBURST_RANGE = {7'd20 + 7'($urandom % 40), 10'd160 + 10'($urandom % 120)};
		for (line = 0; line < LINES; line = line + 1) begin
			for (x = 0; x < LINE; x = x + 1) begin
				@(posedge clk);
				#1;
				hsync = (x < HSW);
				csync = hsync ^ vsync;
				vsync = (line < 2);
				de    = (x >= DE_LO) && (x < DE_HI) && !vsync;
				din   = $urandom;
			end
		end
	end
	repeat (20) @(posedge clk);

	$display("cycles %0d, burst %0d, active chroma %0d, mismatches %0d, retimed_sin now %0d",
		cycles, burst_cycles, chroma_cycles, mism, retimed_sin);
	if (burst_cycles == 0)  $display("FAIL: the burst branch never ran");
	if (chroma_cycles == 0) $display("FAIL: active chroma never ran");
	if (mism == 0 && burst_cycles > 0 && chroma_cycles > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end

endmodule
