/*
 * tb_visprobe.v -- checks visprobe_ddr3 (MEASUREMENT ONLY, see its header).
 *
 * The DDR3 model has a random waitrequest, a random read latency, and a
 * write-visibility delay for the "ARM" side: a word the bench writes as the
 * ARM only reads back new once VIS cycles have passed. Checked:
 *
 *   - A: a word written long before A_GO is found by the first read (no
 *     misses); a word written VIS cycles late is found no sooner than that,
 *     with misses counted, and a_cycles covers the delay; a word never
 *     written times out;
 *   - B: B_GO writes {0, V} to word B exactly once, b_issue is the cycles
 *     from B_GO to the write being accepted, and b_cycles is exactly the
 *     cycles from that accept to B_SEEN; B_SEEN before the write lands is
 *     ignored;
 *   - the probe never touches DDR3 unless the bridge starts it.
 */
`timescale 1ns/1ps

module tb_visprobe;

reg clk = 0, rst_n = 0;
always #4.4 clk = ~clk;   // ~113.5 MHz

reg         lw_wr = 0;
reg  [1:0]  lw_waddr = 0;
reg  [31:0] lw_wdata = 0;
wire [127:0] st;

wire [28:0] avl_address;
wire [7:0]  avl_burstcount, avl_byteenable;
wire        avl_read, avl_write;
reg  [63:0] avl_readdata = 0;
reg         avl_readdatavalid = 0;
wire [63:0] avl_writedata;
reg         avl_waitrequest = 1;

visprobe_ddr3 #(.TIMEOUT(32'd3000)) dut (
	.clk(clk), .rst_n(rst_n),
	.lw_wr(lw_wr), .lw_waddr(lw_waddr), .lw_wdata(lw_wdata), .lw_status(st),
	.avl_address(avl_address), .avl_burstcount(avl_burstcount), .avl_read(avl_read),
	.avl_readdata(avl_readdata), .avl_readdatavalid(avl_readdatavalid),
	.avl_writedata(avl_writedata), .avl_byteenable(avl_byteenable),
	.avl_write(avl_write), .avl_waitrequest(avl_waitrequest)
);

localparam [28:0] AV_A = 29'h03FE1012, AV_B = 29'h03FE1013;

integer seed = 32'h1E1E;
integer errors = 0, checks = 0;
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

task automatic fail(input [8*64-1:0] what);
	begin errors = errors + 1; $display("FAIL: %0s at %0t", what, $time); end
endtask

// ---- DDR3 model ------------------------------------------------------------
// word A: old value until arm_vis_at, then the new one (the ARM's write)
reg  [31:0] a_old = 0, a_new = 0;
integer     arm_vis_at = 0;
reg  [63:0] b_word = 0;
integer     n_b_writes = 0, n_reads = 0, n_cmds = 0, b_accept_cyc = 0;
integer     rd_due = -1;
integer     go_cyc = 0, seen_cyc = 0;
reg  [63:0] rd_val;
reg         block_writes = 0;

always @(posedge clk) begin
	avl_waitrequest <= block_writes ? 1'b1 : (($random(seed) & 3) == 0);
	avl_readdatavalid <= 0;
	if (avl_read && !avl_waitrequest) begin
		n_cmds = n_cmds + 1;
		n_reads = n_reads + 1;
		if (avl_address != AV_A) fail("read of the wrong word");
		rd_val = {32'd0, (cyc >= arm_vis_at) ? a_new : a_old};
		rd_due = cyc + 10 + ($random(seed) & 15);
	end
	if (rd_due >= 0 && cyc >= rd_due) begin
		avl_readdatavalid <= 1;
		avl_readdata      <= rd_val;
		rd_due = -1;
	end
	// the edge the probe takes each bridge write on, by its own cycle count
	if (lw_wr && lw_waddr == 2'd1) go_cyc = cyc;
	if (lw_wr && lw_waddr == 2'd2) seen_cyc = cyc;
	if (avl_write && !avl_waitrequest) begin
		n_cmds = n_cmds + 1;
		if (avl_address != AV_B) fail("write to the wrong word");
		if (avl_byteenable != 8'hFF || avl_burstcount != 1) fail("write not a single full word");
		b_word = avl_writedata;
		n_b_writes = n_b_writes + 1;
		b_accept_cyc = cyc;
	end
end

// ---- the bridge -------------------------------------------------------------
task automatic bridge(input [1:0] r, input [31:0] d);
	begin
		@(posedge clk);
		lw_wr <= 1; lw_waddr <= r; lw_wdata <= d;
		@(posedge clk);
		lw_wr <= 0;
	end
endtask

task automatic wait_a;
	integer t;
	begin
		t = 0;
		while (st[29] && t < 10000) begin @(posedge clk); t = t + 1; end
		@(posedge clk);
	end
endtask

integer i, vis, k, idle_cmds;
reg [31:0] v;

initial begin
	repeat (5) @(posedge clk);
	rst_n <= 1;

	// idle: nothing touches DDR3
	repeat (2000) @(posedge clk);
	checks = checks + 1;
	if (n_cmds != 0) fail("DDR3 touched while idle");

	// ---- A, baseline: word written long ago ---------------------------------
	for (i = 0; i < 50; i = i + 1) begin
		v = $random(seed);
		a_old = a_new; a_new = v; arm_vis_at = 0;
		bridge(0, v);
		repeat (2) @(posedge clk);
		wait_a;
		checks = checks + 1;
		if (!st[31] || st[30]) fail("A baseline not done");
		if (st[15:0] != 0) fail("A baseline missed");
		if (st[63:32] > 40) fail("A baseline too slow");
	end

	// ---- A, late: the word becomes visible VIS cycles after A_GO -----------
	for (i = 0; i < 200; i = i + 1) begin
		v = $random(seed);
		vis = 30 + ($random(seed) & 511);
		a_old = a_new; a_new = v;
		@(posedge clk);
		arm_vis_at = cyc + 1 + vis;
		bridge(0, v);
		repeat (2) @(posedge clk);
		wait_a;
		checks = checks + 2;
		if (!st[31] || st[30]) fail("A late not done");
		if (st[63:32] < vis) begin fail("A found before visible"); $display("  a_cycles %0d vis %0d", st[63:32], vis); end
		if (st[63:32] > vis + 80) begin fail("A found much later than visible"); $display("  a_cycles %0d vis %0d", st[63:32], vis); end
		if (st[15:0] == 0) fail("A late counted no misses");
	end

	// ---- A, never written: timeout -----------------------------------------
	a_old = a_new; a_new = a_new; arm_vis_at = 0;
	bridge(0, ~a_new);
	repeat (2) @(posedge clk);
	wait_a;
	checks = checks + 1;
	if (st[31] || !st[30]) fail("A did not time out");
	if (st[63:32] < 3000) fail("A timed out early");

	// ---- B ------------------------------------------------------------------
	for (i = 0; i < 200; i = i + 1) begin
		v = $random(seed);
		k = 5 + ($random(seed) & 1023);
		k = n_b_writes;
		bridge(1, v);
		repeat (2) @(posedge clk);
		while (!st[94]) @(posedge clk);
		checks = checks + 3;
		if (n_b_writes != k + 1) fail("B_GO did not write exactly once");
		if (b_word != {32'd0, v}) fail("B wrote the wrong value");
		if (st[79:64] != b_accept_cyc - go_cyc) begin
			fail("b_issue wrong"); $display("  got %0d want %0d", st[79:64], b_accept_cyc - go_cyc);
		end
		k = 5 + ($random(seed) & 1023);
		repeat (k) @(posedge clk);
		bridge(2, 0);
		repeat (2) @(posedge clk);
		checks = checks + 2;
		if (!st[95]) fail("B not done after B_SEEN");
		if (st[127:96] != seen_cyc - b_accept_cyc) begin
			fail("b_cycles wrong"); $display("  got %0d want %0d", st[127:96], seen_cyc - b_accept_cyc);
		end
	end

	// ---- B_SEEN before the write lands is ignored ---------------------------
	block_writes = 1;
	bridge(1, 32'h5EE05EE0);
	repeat (20) @(posedge clk);
	bridge(2, 0);
	repeat (5) @(posedge clk);
	checks = checks + 1;
	if (st[95] || st[94] || !st[93]) fail("B_SEEN before the write was not ignored");
	block_writes = 0;
	repeat (2) @(posedge clk);
	while (!st[94]) @(posedge clk);
	checks = checks + 1;
	if (b_word != {32'd0, 32'h5EE05EE0}) fail("held B write lost");

	// ---- and idle again -----------------------------------------------------
	idle_cmds = n_cmds;
	repeat (2000) @(posedge clk);
	checks = checks + 1;
	if (n_cmds != idle_cmds) fail("DDR3 touched after the probes finished");

	$display("%0d checks, %0d errors", checks, errors);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

initial begin
	#50_000_000;
	$display("RUN: FAIL (timeout)");
	$finish;
end

endmodule
