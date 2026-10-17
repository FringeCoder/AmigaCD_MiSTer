// drive_sounds now registers the DDR3 read data (dd_q) before the sample select,
// which costs one clock per read. The claim is that this is the same module
// behind a DDR3 port one clock slower -- a latency the port never promised to
// keep fixed. This bench checks exactly that: the DUT talks to a random-latency
// DDR3 model, the previous version (drive_sounds_ref.v, frozen copy, module
// renamed) talks to the same model with ready and data delayed by one clock,
// and every output of the two must match on every clock.
//
// Stimulus: random step pulses on both drive sides, motor on/off for both
// motors, volume changes including off, and disk insert/eject. The model's data
// is a hash of the address with the end marker 16'h8000 planted often, so the
// end-of-sample and the snd 3 loop-back branches run.
//
// HOLD (two seconds of ticks before insert/eject is armed) is far beyond a
// bench; both instances get hold cleared by the bench after reset, the same way.
//
// The bench counts reads, nonzero output samples and end markers met, and fails
// on zero, so a run in which the mixer never ran cannot pass.
`timescale 1ns/1ns
module tb_drive_sounds_equiv;

reg clk = 0, rst = 1;
reg  [1:0] volume = 2'd2;
reg  [8:0] drive_snd = 9'h0F0;
reg        ddr_busy = 0;

wire [15:0] l_d, r_d, l_r, r_r;
wire [28:0] a_d, a_r;
wire        rd_d, rd_r;

// DDR3 model, answering the DUT. One request at a time, as the module issues.
reg        ready = 0;
reg [63:0] dout = 0;
reg        pend = 0;
reg [28:0] paddr;
integer    lat = 0;

function [15:0] word;
	input [31:0] a;
	reg   [31:0] h;
	begin
		h = a * 32'h9E3779B1;
		h = h ^ (h >> 15);
		word = (h[4:0] == 0) ? 16'h8000 : h[31:16];
	end
endfunction

// Outside its ready cycle the port carries other masters' data, so the model
// drives garbage there: a module that read the data a clock late would see it.
always @(posedge clk) begin
	ready <= 0;
	dout  <= {$urandom, $urandom};
	ddr_busy <= ($urandom % 4 == 0);
	if (pend) begin
		if (lat == 0) begin
			ready <= 1;
			dout  <= {word({paddr, 2'd3}), word({paddr, 2'd2}), word({paddr, 2'd1}), word({paddr, 2'd0})};
			pend  <= 0;
		end
		else lat <= lat - 1;
	end
	else if (rd_d & ~ddr_busy) begin
		pend  <= 1;
		paddr <= a_d;
		lat   <= $urandom % 12;
	end
end

// The same answers, one clock later, for the reference.
reg        ready_q = 0;
reg [63:0] dout_q  = 0;
always @(posedge clk) begin
	ready_q <= ready;
	dout_q  <= dout;
end

drive_sounds dut (
	.clk(clk), .rst(rst), .volume(volume), .drive_snd(drive_snd),
	.sample_l(l_d), .sample_r(r_d),
	.ddr_addr(a_d), .ddr_rd(rd_d), .ddr_busy(ddr_busy),
	.ddr_dout(dout), .ddr_dout_ready(ready));

drive_sounds_ref ref_i (
	.clk(clk), .rst(rst), .volume(volume), .drive_snd(drive_snd),
	.sample_l(l_r), .sample_r(r_r),
	.ddr_addr(a_r), .ddr_rd(rd_r), .ddr_busy(ddr_busy),
	.ddr_dout(dout_q), .ddr_dout_ready(ready_q));

always #4 clk = ~clk;

integer cyc = 0, mism = 0, reads = 0, nonzero = 0, ends = 0, i;

always @(negedge clk) if (!rst) begin
	cyc = cyc + 1;
	if (rd_d & ~ddr_busy) reads = reads + 1;
	if (l_d != 0 || r_d != 0) nonzero = nonzero + 1;
	if (ref_i.p == 3'd4 && ref_i.smp == 16'h8000) ends = ends + 1;
	if ({l_d, r_d, a_d, rd_d} !== {l_r, r_r, a_r, rd_r}) begin
		if (mism < 10)
			$display("MISMATCH cyc %0d: l %h/%h r %h/%h addr %h/%h rd %b/%b",
				cyc, l_d, l_r, r_d, r_r, a_d, a_r, rd_d, rd_r);
		mism = mism + 1;
	end
end

initial begin
	repeat (4) @(posedge clk);
	#1 rst = 0;
	dut.hold = 0; ref_i.hold = 0;
	for (i = 0; i < 1500000; i = i + 1) begin
		@(posedge clk); #1;
		// a step pulse every few thousand clocks, either side
		if ($urandom % 3000 == 0) drive_snd[0] = ~drive_snd[0];
		if ($urandom % 3000 == 0) drive_snd[1] = $urandom;
		// motors on and off now and then
		if ($urandom % 200000 == 0) drive_snd[2] = ~drive_snd[2];
		if ($urandom % 200000 == 0) drive_snd[3] = ~drive_snd[3];
		// a disk in or out
		if ($urandom % 400000 == 0) drive_snd[4] = ~drive_snd[4];
		// volume, off included
		if ($urandom % 300000 == 0) volume = $urandom;
	end
	repeat (10) @(posedge clk);
	$display("cycles %0d, reads %0d, nonzero samples %0d, end markers %0d, mismatches %0d",
		cyc, reads, nonzero, ends, mism);
	if (reads == 0)   $display("FAIL: no DDR3 read");
	if (nonzero == 0) $display("FAIL: the mixer never produced a sample");
	if (ends == 0)    $display("FAIL: no end marker met");
	if (mism == 0 && reads > 0 && nonzero > 0 && ends > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
