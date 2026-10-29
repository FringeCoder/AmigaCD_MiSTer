`timescale 1ns/1ps

// rtl/chip_mirror.v against a model of what the DDR3 shadow must hold.
//
// Random chipset-port writes (words, single bytes, longs; chip RAM and the
// slow RAM and Kickstart areas it must ignore) go in at random spacing, and a
// DDR3 port with random waitrequest takes them out. After each phase the
// shadow model must equal the reference byte for byte. Also checked: idle is
// low while anything is queued and comes back only after IDLE_CLKS quiet
// clocks; nothing is copied while en is low; a write that finds the FIFO full
// sets lost, and lost clears when en rises again.

module tb_chip_mirror;

reg clk = 0;
always #4.4 clk = ~clk;
reg reset = 1;
reg en = 0;

reg        wev = 0;
reg [23:1] wev_addr = 0;
reg [15:0] wev_data = 0, wev_data2 = 0;
reg  [1:0] wev_dqm = 2'b11;
reg        wev_long = 0;

wire [28:0] m_address;
wire [63:0] m_writedata;
wire  [7:0] m_byteenable;
wire        m_write;
reg         m_waitrequest = 0;
wire        idle, lost;

localparam [28:0] BASE = 29'h07600000;

chip_mirror #(.BASE(BASE), .ABITS(5), .IDLE_CLKS(8)) dut (
	.clk(clk), .reset(reset), .en_async(en),
	.wev(wev), .wev_addr(wev_addr), .wev_data(wev_data), .wev_dqm(wev_dqm),
	.wev_long(wev_long), .wev_data2(wev_data2),
	.m_address(m_address), .m_writedata(m_writedata), .m_byteenable(m_byteenable),
	.m_write(m_write), .m_waitrequest(m_waitrequest),
	.idle(idle), .lost(lost)
);

// 64 KB of chip RAM is enough to collide often
localparam SPAN = 16'hFFFF;
reg [7:0] shadow [0:SPAN];   // what DDR3 holds
reg [7:0] ref_m  [0:SPAN];   // what it must hold
integer errors = 0, checks = 0, i, bad_addr = 0;

// the DDR3 port
reg wait_rand = 0;
always @(posedge clk) begin
	m_waitrequest <= wait_rand ? ($urandom % 3 != 0) : 1'b0;
	if (m_write & ~m_waitrequest) begin : take
		integer b;
		if (m_address < BASE || m_address >= BASE + 29'h40000) begin
			bad_addr = bad_addr + 1;
		end
		else for (b = 0; b < 8; b = b + 1)
			if (m_byteenable[b]) shadow[((m_address - BASE) * 8 + b) & SPAN] = m_writedata[8*b +: 8];
	end
end

task automatic event_(input [23:0] a, input [15:0] d, input [1:0] dqm, input lg, input [15:0] d2, input mirror);
	begin
		@(posedge clk);
		wev <= 1; wev_addr <= a[23:1]; wev_data <= d; wev_dqm <= dqm; wev_long <= lg; wev_data2 <= d2;
		@(posedge clk);
		wev <= 0;
		if (mirror && a[23:21] == 0 && a[23:0] <= SPAN) begin
			if (~dqm[1]) ref_m[a[15:0]]     = d[15:8];
			if (~dqm[0]) ref_m[a[15:0] | 1] = d[7:0];
			if (lg) begin
				ref_m[(a[15:0] + 2)]     = d2[15:8];
				ref_m[(a[15:0] + 2) | 1] = d2[7:0];
			end
		end
	end
endtask

task automatic drain;
	integer t;
	begin
		t = 0;
		while (!idle) begin @(posedge clk); t = t + 1; if (t > 100000) begin $display("FAIL: never idle"); errors = errors + 1; disable drain; end end
	end
endtask

task automatic compare(input [8*24-1:0] what);
	integer k, bad;
	begin
		bad = 0;
		for (k = 0; k <= SPAN; k = k + 1) if (shadow[k] !== ref_m[k]) begin
			if (bad < 5) $display("  %0s: byte %04x shadow %02x want %02x", what, k, shadow[k], ref_m[k]);
			bad = bad + 1;
		end
		checks = checks + 1;
		if (bad) begin $display("FAIL %0s: %0d bytes differ", what, bad); errors = errors + 1; end
		else $display("ok   %0s", what);
	end
endtask

task automatic random_writes(input integer n, input integer gap_max, input mirror);
	integer k;
	reg [23:0] a;
	reg [2:0] kind;
	begin
		for (k = 0; k < n; k = k + 1) begin
			kind = $urandom % 8;
			a = {8'd0, 16'($urandom)} & 24'hFFFE;
			if (kind == 0) a = 24'hC00000 | a;           // slow RAM: ignored
			if (kind == 1) a = 24'h7C0000 | a;           // Kickstart: ignored
			if (kind == 2) a[2:1] = 2'd0;                // a long, aligned
			event_(a, $urandom, kind == 3 ? 2'b01 : kind == 4 ? 2'b10 : 2'b00, kind == 2, $urandom, mirror);
			repeat ($urandom % (gap_max + 1)) @(posedge clk);
		end
	end
endtask

initial begin
	for (i = 0; i <= SPAN; i = i + 1) begin shadow[i] = 8'h00; ref_m[i] = 8'h00; end
	repeat (10) @(posedge clk);
	reset = 0;
	repeat (10) @(posedge clk);

	// off: nothing reaches DDR3, and idle stays high
	random_writes(200, 3, 0);
	repeat (20) @(posedge clk);
	checks = checks + 1;
	if (!idle) begin $display("FAIL: not idle while off"); errors = errors + 1; end
	compare("off: nothing copied");

	// on, a port that never waits
	en = 1;
	repeat (10) @(posedge clk);
	random_writes(2000, 6, 1);
	drain;
	compare("on, free port");

	// on, a port that keeps saying wait (the FIFO fills and empties)
	wait_rand = 1;
	random_writes(3000, 4, 1);
	drain;
	compare("on, busy port");

	// idle drops with the first write and needs IDLE_CLKS quiet clocks back
	begin : idle_check
		integer t;
		wait_rand = 0;
		repeat (30) @(posedge clk);
		event_(24'h000100, 16'h1234, 2'b00, 0, 0, 1);
		@(posedge clk);
		checks = checks + 1;
		if (idle) begin $display("FAIL: idle right after a write"); errors = errors + 1; end
		t = 0;
		while (!idle) begin @(posedge clk); t = t + 1; end
		checks = checks + 1;
		if (t < 8) begin $display("FAIL: idle back after %0d clocks", t); errors = errors + 1; end
		else $display("ok   idle back after %0d clocks", t);
	end

	// overflow: hold the port, write more than the FIFO holds
	checks = checks + 1;
	if (lost) begin $display("FAIL: lost before any overflow"); errors = errors + 1; end
	m_waitrequest = 1;
	wait_rand = 0;
	force m_waitrequest = 1;
	random_writes(80, 0, 0);
	release m_waitrequest;
	checks = checks + 1;
	if (!lost) begin $display("FAIL: lost not set after overflow"); errors = errors + 1; end
	else $display("ok   lost after overflow");
	drain;
	en = 0;
	repeat (10) @(posedge clk);
	en = 1;
	repeat (10) @(posedge clk);
	checks = checks + 1;
	if (lost) begin $display("FAIL: lost still set after en rose"); errors = errors + 1; end
	else $display("ok   lost cleared by en");

	checks = checks + 1;
	if (bad_addr) begin $display("FAIL: %0d writes outside the shadow", bad_addr); errors = errors + 1; end

	$display("%0d checks, %0d errors", checks, errors);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

endmodule
