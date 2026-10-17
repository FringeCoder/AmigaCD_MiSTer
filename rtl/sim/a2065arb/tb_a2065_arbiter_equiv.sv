// a2065_ddram_arbiter's busy-clear compare was restructured to take the late
// f2sdram signal (beat_done) out of the adder in front of it: busy now clears on
// beat_done ? (beats_left + m0_more == 1) : (... == 0), where it cleared on
// beats_left + m0_more - beat_done == 0. This runs it against the previous
// version (a2065_ddram_arbiter_ref.v, frozen copy, module renamed) and requires
// every output and both state registers that matter to match on every clock.
//
// The slave side is driven at random, protocol or not: waitrequest and
// readdatavalid toggle freely, so beats_left also walks through the values a
// well-behaved slave would never produce, including the wrap at zero. Masters
// request reads and writes with random burst lengths, including 1 (the write
// case that never goes busy) and the full 8-bit range.
//
// The bench counts busy falls and starts by each master, and fails on zero, so
// a run that never cleared busy -- the only thing that changed -- cannot pass.
`timescale 1ns/1ns
module tb_a2065_arbiter_equiv;

reg clk = 0, rst = 1;
reg  [28:0] m0_address = 0, m1_address = 0;
reg  [7:0]  m0_burstcount = 1, m1_burstcount = 1;
reg         m0_read = 0, m0_write = 0, m1_read = 0, m1_write = 0;
reg  [63:0] m0_writedata = 0, m1_writedata = 0, s_readdata = 0;
reg  [7:0]  m0_byteenable = 0, m1_byteenable = 0;
reg         s_readdatavalid = 0, s_waitrequest = 0;

`define OUTS(p) \
	wire [63:0] p``m0_rd, p``m1_rd, p``s_wd; \
	wire p``m0_rdv, p``m1_rdv, p``m0_wait, p``m1_wait, p``s_rd, p``s_wr; \
	wire [28:0] p``s_addr; wire [7:0] p``s_bc, p``s_be;

`OUTS(d_)
`OUTS(r_)

`define PORTS(p) \
	.clk(clk), .rst(rst), \
	.m0_address(m0_address), .m0_burstcount(m0_burstcount), .m0_read(m0_read), \
	.m0_readdata(p``m0_rd), .m0_readdatavalid(p``m0_rdv), .m0_writedata(m0_writedata), \
	.m0_byteenable(m0_byteenable), .m0_write(m0_write), .m0_waitrequest(p``m0_wait), \
	.m1_address(m1_address), .m1_burstcount(m1_burstcount), .m1_read(m1_read), \
	.m1_readdata(p``m1_rd), .m1_readdatavalid(p``m1_rdv), .m1_writedata(m1_writedata), \
	.m1_byteenable(m1_byteenable), .m1_write(m1_write), .m1_waitrequest(p``m1_wait), \
	.s_address(p``s_addr), .s_burstcount(p``s_bc), .s_read(p``s_rd), \
	.s_readdata(s_readdata), .s_readdatavalid(s_readdatavalid), .s_writedata(p``s_wd), \
	.s_byteenable(p``s_be), .s_write(p``s_wr), .s_waitrequest(s_waitrequest)

a2065_ddram_arbiter     dut   (`PORTS(d_));
a2065_ddram_arbiter_ref ref_i (`PORTS(r_));

integer cyc = 0, mism = 0, falls = 0, st0 = 0, st1 = 0, i;
reg busy_q = 0;

always #5 clk = ~clk;

always @(negedge clk) if (!rst) begin
	cyc = cyc + 1;
	if (busy_q && !ref_i.busy) falls = falls + 1;
	busy_q = ref_i.busy;
	if (!ref_i.busy && ref_i.starting && !s_waitrequest) begin
		if (ref_i.sel) st1 = st1 + 1; else st0 = st0 + 1;
	end
	if ({d_m0_rd, d_m1_rd, d_s_wd, d_m0_rdv, d_m1_rdv, d_m0_wait, d_m1_wait, d_s_rd, d_s_wr,
	     d_s_addr, d_s_bc, d_s_be, dut.busy, dut.beats_left, dut.owner, dut.owner_is_read} !==
	    {r_m0_rd, r_m1_rd, r_s_wd, r_m0_rdv, r_m1_rdv, r_m0_wait, r_m1_wait, r_s_rd, r_s_wr,
	     r_s_addr, r_s_bc, r_s_be, ref_i.busy, ref_i.beats_left, ref_i.owner, ref_i.owner_is_read}) begin
		if (mism < 10)
			$display("MISMATCH cyc %0d: busy %b/%b beats %0d/%0d wait0 %b/%b wait1 %b/%b",
				cyc, dut.busy, ref_i.busy, dut.beats_left, ref_i.beats_left,
				d_m0_wait, r_m0_wait, d_m1_wait, r_m1_wait);
		mism = mism + 1;
	end
end

function [7:0] rand_bc;
	input dummy;
	case ($urandom % 4)
		0: rand_bc = 8'd1;
		1: rand_bc = 8'd2;
		2: rand_bc = 1 + ($urandom % 8);
		default: rand_bc = $urandom;     // full range, 0 included
	endcase
endfunction

initial begin
	repeat (3) @(posedge clk);
	#1 rst = 0;
	for (i = 0; i < 200000; i = i + 1) begin
		@(posedge clk); #1;
		if ($urandom % 6 == 0) begin
			m0_read  = ($urandom % 3 == 0);
			m0_write = !m0_read && ($urandom % 3 == 0);
			m0_burstcount = rand_bc(0);
		end
		if ($urandom % 6 == 0) begin
			m1_read  = ($urandom % 3 == 0);
			m1_write = !m1_read && ($urandom % 3 == 0);
			m1_burstcount = rand_bc(0);
		end
		m0_address = $urandom; m1_address = $urandom;
		m0_writedata = {$urandom, $urandom}; m1_writedata = {$urandom, $urandom};
		m0_byteenable = $urandom; m1_byteenable = $urandom;
		s_readdata = {$urandom, $urandom};
		s_waitrequest   = ($urandom % 4 == 0);
		s_readdatavalid = ($urandom % 2 == 0);
	end
	repeat (5) @(posedge clk);
	$display("cycles %0d, busy falls %0d, starts m0 %0d m1 %0d, mismatches %0d", cyc, falls, st0, st1, mism);
	if (falls == 0) $display("FAIL: busy never cleared");
	if (st0 == 0 || st1 == 0) $display("FAIL: a master never started");
	if (mism == 0 && falls > 0 && st0 > 0 && st1 > 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
