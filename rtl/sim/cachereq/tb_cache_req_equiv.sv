// tb_cache_req_equiv.sv
//
// cpu_cache_new against a frozen copy of itself (cpu_cache_new_ref.v), clock
// for clock. sdr_read_req moved out of the cpu-side state machine into an
// expression of its own; every output must stay identical on every clock.
//
// Both caches see the same random stimulus: CPU reads, instruction fetches
// and writes, long reads, cache enable and D-cache toggles, inhibit, cache
// clears, snoop writes, the line buffer offer (LINE_TAKE=1 only) and a
// memory that acks fills after a random delay. Addresses come from a small
// set of lines in two tags per index, so hits on both ways, misses,
// evictions and line-buffer takes all happen. The memory answers from
// whichever request is live and the DUT's own address, so a divergence in
// sdr_read_req diverges everything after it as well.
//
// Fails on X on a control output at any time, or on read data while it is
// acked; cpu_dat_r is X in both copies until the first read loads it.
//
// Run with LINE_TAKE=0 (ram1, sdram_ctrl) and LINE_TAKE=1 (ram2, ddram_ctrl).
// Fails on any output mismatch, on X on any output after reset, and on zero
// count of: miss requests, held requests (FILL1 waiting for its ack), hits
// on each of the four ways, and (LINE_TAKE=1) line-buffer takes and misses
// where a snoop refused the line buffer.

`timescale 1ns/1ps

module tb_cache_req_equiv;

`ifndef LT
`define LT 1
`endif
`ifndef SEED
`define SEED 1
`endif
`ifndef NCLK
`define NCLK 400000
`endif

localparam LT = `LT;

reg clk = 0;
always #5 clk = ~clk;

reg         rst = 1;
reg   [3:0] cpu_cache_ctrl = 4'b0001;
reg         dcache_sw_en = 1;
reg         cache_inhibit = 0;
reg         cpu_cs = 0;
reg  [28:1] cpu_adr = 0;
reg   [1:0] cpu_bs = 2'b11;
reg         cpu_we = 0, cpu_ir = 0, cpu_dr = 0;
reg  [15:0] cpu_dat_w = 0;
reg  [15:0] sdr_dat_r = 0;
reg         sdr_read_ack = 0;
reg         snoop_act = 0;
reg  [28:1] snoop_adr = 0;
reg  [15:0] snoop_dat_w = 0;
reg   [1:0] snoop_bs = 2'b11;
reg         buf_ok = 0;
reg  [63:0] buf_dat = 0;
reg         cpu_long = 0;
reg  [15:0] cpu_dat_w_lo = 0;

wire [15:0] d_dat_r, r_dat_r, d_dat_hi, r_dat_hi;
wire        d_ack, r_ack, d_wb, r_wb, d_idle, r_idle, d_req, r_req, d_take, r_take, d_ackl, r_ackl;

cpu_cache_new #(.LINE_TAKE(LT)) dut (
	.clk(clk), .rst(rst), .cpu_cache_ctrl(cpu_cache_ctrl), .dcache_sw_en(dcache_sw_en),
	.cache_inhibit(cache_inhibit), .cpu_cs(cpu_cs), .cpu_adr(cpu_adr), .cpu_bs(cpu_bs),
	.cpu_we(cpu_we), .cpu_ir(cpu_ir), .cpu_dr(cpu_dr), .cpu_dat_w(cpu_dat_w),
	.cpu_dat_r(d_dat_r), .cpu_ack(d_ack), .wb_en(d_wb), .cpu_idle(d_idle),
	.sdr_dat_r(sdr_dat_r), .sdr_read_req(d_req), .sdr_read_ack(sdr_read_ack),
	.snoop_act(snoop_act), .snoop_adr(snoop_adr), .snoop_dat_w(snoop_dat_w), .snoop_bs(snoop_bs),
	.buf_ok(buf_ok), .buf_dat(buf_dat), .buf_take(d_take),
	.cpu_long(cpu_long), .cpu_dat_w_lo(cpu_dat_w_lo), .cpu_dat_hi(d_dat_hi), .cpu_ack_l(d_ackl));

cpu_cache_new_ref #(.LINE_TAKE(LT)) ref_i (
	.clk(clk), .rst(rst), .cpu_cache_ctrl(cpu_cache_ctrl), .dcache_sw_en(dcache_sw_en),
	.cache_inhibit(cache_inhibit), .cpu_cs(cpu_cs), .cpu_adr(cpu_adr), .cpu_bs(cpu_bs),
	.cpu_we(cpu_we), .cpu_ir(cpu_ir), .cpu_dr(cpu_dr), .cpu_dat_w(cpu_dat_w),
	.cpu_dat_r(r_dat_r), .cpu_ack(r_ack), .wb_en(r_wb), .cpu_idle(r_idle),
	.sdr_dat_r(sdr_dat_r), .sdr_read_req(r_req), .sdr_read_ack(sdr_read_ack),
	.snoop_act(snoop_act), .snoop_adr(snoop_adr), .snoop_dat_w(snoop_dat_w), .snoop_bs(snoop_bs),
	.buf_ok(buf_ok), .buf_dat(buf_dat), .buf_take(r_take),
	.cpu_long(cpu_long), .cpu_dat_w_lo(cpu_dat_w_lo), .cpu_dat_hi(r_dat_hi), .cpu_ack_l(r_ackl));

wire [37:0] d_out = {d_dat_r, d_dat_hi, d_ack, d_wb, d_idle, d_req, d_take, d_ackl};
wire [37:0] r_out = {r_dat_r, r_dat_hi, r_ack, r_wb, r_idle, r_req, r_take, r_ackl};

integer seed = `SEED;
integer cyc = 0, mism = 0, xs = 0;
integer n_tmo = 0, n_bufsnoop = 0;
integer n_miss = 0, n_hold = 0, n_take = 0, n_i0 = 0, n_i1 = 0, n_d0 = 0, n_d1 = 0, n_acc = 0;

// A small address set: 4 indexes x 3 tags x 4 words. Three tags per index
// against two ways forces evictions; same index, different tag.
function [28:1] pick_adr(input integer r);
	reg [17:0] tag;
	reg  [7:0] idx;
	reg  [1:0] blk;
	begin
		tag = 18'h00400 + (r % 3);
		idx = 8'h10 + ((r / 3) % 4);
		blk = (r / 12) % 4;
		pick_adr = {tag, idx, blk, 1'b0};
	end
endfunction

function [15:0] mem_word(input [28:1] a);
	mem_word = a[16:1] ^ 16'h5A3C ^ {a[28:21], 8'h00};
endfunction

// Memory: acks a live request after 1-6 clocks, then streams the fill's
// other three words on the next three clocks, as both controllers do (the
// cache's FILLW leaves on the first clock without an ack, so a gap inside a
// burst would hand its tail to the next miss).
integer      ack_wait = 0;
integer      burst = 0;
reg   [1:0]  bw = 0;
reg  [28:3]  line = 0;

// CPU: one access at a time, held until the cache acks or (writes) wb_en,
// then dropped for a random number of clocks.
integer hold = 0;
integer gap = 0;

always @(posedge clk) begin
	cyc <= cyc + 1;
	// ---------------- memory ----------------
	sdr_read_ack <= 0;
	if (burst != 0) begin
		sdr_read_ack <= 1;
		bw = bw + 1;
		sdr_dat_r <= mem_word({line, bw, 1'b0});
		burst = burst - 1;
	end else if (d_req) begin
		if (ack_wait == 0) ack_wait = 1 + $urandom(seed) % 6;
		else begin
			ack_wait = ack_wait - 1;
			if (ack_wait == 0) begin
				sdr_read_ack <= 1;
				bw = cpu_adr[2:1];
				line = cpu_adr[28:3];
				sdr_dat_r <= mem_word(cpu_adr);
				burst = 3;
			end
		end
	end

	// ---------------- cpu ----------------
	if (!rst) begin
		if (cpu_cs) begin
			hold = hold + 1;
			if (hold > 2000) n_tmo = n_tmo + 1;
			if (d_ack || (cpu_we && d_wb) || hold > 2000) begin
				cpu_cs <= 0;
				gap = $urandom(seed) % 4;
			end
		end else if (gap != 0) gap = gap - 1;
		else if ($urandom(seed) % 3 != 0) begin
			cpu_cs   <= 1;
			hold     = 0;
			cpu_adr  <= pick_adr($urandom(seed) % 48);
			cpu_we   <= ($urandom(seed) % 6 == 0);
			cpu_ir   <= ($urandom(seed) % 3 == 0);
			cpu_dr   <= 1;
			cpu_bs   <= ($urandom(seed) % 4 == 0) ? 2'b01 : 2'b11;
			cpu_long <= ($urandom(seed) % 3 == 0);
			cpu_dat_w    <= $urandom(seed);
			cache_inhibit <= ($urandom(seed) % 8 == 0);
			cpu_dat_w_lo <= $urandom(seed);
			n_acc = n_acc + 1;
		end

		// occasional mode changes, only between accesses
		if (!cpu_cs && $urandom(seed) % 4000 == 0) cpu_cache_ctrl[0] <= ~cpu_cache_ctrl[0];
		if (!cpu_cs && $urandom(seed) % 3000 == 0) dcache_sw_en <= ~dcache_sw_en;
		if ($urandom(seed) % 5000 == 0) cpu_cache_ctrl[3] <= 1;
		else if ($urandom(seed) % 50 == 0) cpu_cache_ctrl[3] <= 0;

		// snoop writes: often, but four in five to lines the CPU does not use,
		// so fills are not invalidated all the time and a snoop still lands
		// on a miss with the line buffer offered (rd_buf's snoop_act term)
		snoop_act <= ($urandom(seed) % 30 == 0);
		snoop_adr <= ($urandom(seed) % 5 == 0) ? pick_adr($urandom(seed) % 48) : {18'h00777, 8'h80, 2'd0, 1'b0};
		snoop_dat_w <= $urandom(seed);
		snoop_bs <= ($urandom(seed) % 3 == 0) ? 2'b10 : 2'b11;

		// line buffer offers
		buf_ok  <= ($urandom(seed) % 2 == 0);
		buf_dat <= {$urandom(seed), $urandom(seed)};
	end
end

// ---------------- checks ----------------
always @(negedge clk) if (!rst) begin
	if (^d_out[5:0] === 1'bx || ^r_out[5:0] === 1'bx ||
	    (d_ack && (^d_dat_r === 1'bx || (d_ackl && ^d_dat_hi === 1'bx)))) begin
		xs = xs + 1;
		if (xs < 5) $display("X at %0d: dut %h ref %h", cyc, d_out, r_out);
	end
	if (d_out !== r_out) begin
		mism = mism + 1;
		if (mism < 10) $display("MISMATCH at %0d: dut %h ref %h (req %b/%b)", cyc, d_out, r_out, d_req, r_req);
	end
	if (r_req && ref_i.cpu_sm_state == 4'd6) n_hold = n_hold + 1;
	if (ref_i.cpu_sm_state == 4'd4) begin
		if (!ref_i.rd_i0 && !ref_i.rd_i1 && !ref_i.rd_d0 && !ref_i.rd_d1 &&
		    !(LT && ref_i.buf_ok_r && !snoop_act && !cpu_ir && ref_i.cc_den && !cache_inhibit)) n_miss = n_miss + 1;
		if (ref_i.rd_i0) n_i0 = n_i0 + 1;
		else if (ref_i.rd_i1) n_i1 = n_i1 + 1;
		else if (ref_i.rd_d0) n_d0 = n_d0 + 1;
		else if (ref_i.rd_d1) n_d1 = n_d1 + 1;
	end
	if (r_take) n_take = n_take + 1;
	if (ref_i.cpu_sm_state == 4'd4 && LT && ref_i.buf_ok_r && snoop_act && !cpu_ir && ref_i.cc_den && !cache_inhibit &&
	    !ref_i.rd_i0 && !ref_i.rd_i1 && !ref_i.rd_d0 && !ref_i.rd_d1) n_bufsnoop = n_bufsnoop + 1;
end

initial begin
	repeat (20) @(posedge clk);
	rst <= 0;
	repeat (`NCLK) @(posedge clk);
	$display("LINE_TAKE=%0d seed %0d: %0d clocks, %0d accesses, %0d misses, %0d held-request clocks, hits i0 %0d i1 %0d d0 %0d d1 %0d, %0d buffer takes, %0d buffer offers refused for a snoop, %0d mismatches, %0d X, %0d timeouts",
		LT, `SEED, cyc, n_acc, n_miss, n_hold, n_i0, n_i1, n_d0, n_d1, n_take, n_bufsnoop, mism, xs, n_tmo);
	if (mism == 0 && xs == 0 && n_miss > 0 && n_hold > 0 && n_i0 > 0 && n_i1 > 0 && n_d0 > 0 && n_d1 > 0 &&
	    (LT == 0 || (n_take > 0 && n_bufsnoop > 0)))
		$display("RUN: PASS");
	else
		$display("RUN: FAIL");
	$finish;
end

endmodule
