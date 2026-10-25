/*
 * tb_lw_echo.sv -- checks sys/lw_echo.sv (MEASUREMENT ONLY, see its header).
 *
 * The bench plays the lightweight bridge's AXI3 master, the way the HPS
 * drives it: random gaps before each valid, random stalls on bready and
 * rready, and write data sometimes offered before its address. Checked:
 *
 *   - MAGIC reads back, and the ECHO register returns what was written,
 *     byte strobes honoured;
 *   - every response carries the ID of the transaction it answers;
 *   - a burst read returns arlen+1 beats with rlast on the last only, and a
 *     burst write gets exactly one response;
 *   - the read-only registers ignore writes, and COUNT counts both kinds;
 *   - nothing hangs: every transaction completes within a time limit.
 */
`timescale 1ns/1ps

module tb_lw_echo;

reg clk = 0, reset = 1;
always #5 clk = ~clk;   // 100 MHz, as clk_100m

reg  [11:0] awid = 0;  reg [20:0] awaddr = 0; reg [3:0] awlen = 0; reg awvalid = 0; wire awready;
reg  [31:0] wdata = 0; reg [3:0]  wstrb = 0;  reg wlast = 0;       reg wvalid = 0;  wire wready;
wire [11:0] bid;       wire [1:0] bresp;      wire bvalid;         reg bready = 0;
reg  [11:0] arid = 0;  reg [20:0] araddr = 0; reg [3:0] arlen = 0; reg arvalid = 0; wire arready;
wire [11:0] rid;       wire [31:0] rdata;     wire [1:0] rresp;    wire rlast; wire rvalid; reg rready = 0;

lw_echo dut (
	.clk(clk), .reset(reset),
	.awid(awid), .awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
	.wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
	.bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
	.arid(arid), .araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
	.rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
);

integer seed = 32'h1D0E;
integer errors = 0, checks = 0;
integer n_rd = 0, n_wr = 0;

task automatic fail(input [8*64-1:0] what);
	begin errors = errors + 1; $display("FAIL: %0s at %0t", what, $time); end
endtask

task automatic gap;
	repeat ($random(seed) & 3) @(posedge clk);
endtask

// One write burst of len+1 beats to register reg_n, data base d, strobes s.
task automatic axi_write(input [1:0] reg_n, input [3:0] len, input [31:0] d, input [3:0] s, input [11:0] id);
	integer beat, t, nb;
	reg w_first, done;
	begin
		w_first = $random(seed) & 1;   // offer data before the address
		nb = 0;
		fork
			begin
				if (w_first) repeat (3) @(posedge clk); else gap;
				awid <= id; awaddr <= {17'h1ABC, reg_n, 2'b00}; awlen <= len; awvalid <= 1;
				@(posedge clk); while (!awready) @(posedge clk);
				awvalid <= 0;
			end
			begin
				if (!w_first) gap;
				for (beat = 0; beat <= len; beat = beat + 1) begin
					wdata <= d + beat; wstrb <= s; wlast <= (beat == len); wvalid <= 1;
					@(posedge clk); t = 0;
					while (!wready) begin
						@(posedge clk); t = t + 1;
						if (t > 200) begin fail("write data never accepted"); disable axi_write; end
					end
					wvalid <= 0; gap;
				end
			end
		join
		t = 0; done = 0;
		while (!done) begin
			bready <= ($random(seed) & 1);
			@(posedge clk);
			if (bvalid && bready) begin
				nb = nb + 1;
				checks = checks + 1;
				if (bid != id) fail("bid is not the write's awid");
				if (bresp != 0) fail("bresp not OKAY");
				done = 1;
			end
			t = t + 1;
			if (!done && t > 200) begin fail("no write response"); done = 1; end
		end
		bready <= 0;
		// a burst write must get exactly one response
		repeat (4) @(posedge clk);
		checks = checks + 1;
		if (bvalid) fail("second write response for one burst");
		n_wr = n_wr + 1;
	end
endtask

// One read burst; returns the first beat, checks every beat is the same register.
task automatic axi_read(input [1:0] reg_n, input [3:0] len, input [11:0] id, output [31:0] first);
	integer beat, t;
	reg done;
	begin
		gap;
		arid <= id; araddr <= {17'h0F00, reg_n, 2'b00}; arlen <= len; arvalid <= 1;
		@(posedge clk); while (!arready) @(posedge clk);
		arvalid <= 0;
		beat = 0; t = 0; done = 0;
		while (!done) begin
			rready <= ($random(seed) & 1);
			@(posedge clk);
			if (rvalid && rready) begin
				checks = checks + 1;
				if (rid != id) fail("rid is not the read's arid");
				if (rresp != 0) fail("rresp not OKAY");
				if (rlast != (beat == len)) fail("rlast on the wrong beat");
				if (beat == 0) first = rdata;
				else if (reg_n != 2 && rdata != first) fail("burst beats disagree");
				if (rlast) done = 1;
				else beat = beat + 1;
			end
			t = t + 1;
			if (!done && t > 400) begin fail("read never completed"); done = 1; end
		end
		rready <= 0;
		checks = checks + 1;
		if (beat != len) fail("wrong number of read beats");
		n_rd = n_rd + 1;
	end
endtask

reg [31:0] v, expect_echo, c0, c1;
integer i;

initial begin
	repeat (5) @(posedge clk);
	reset <= 0;
	repeat (2) @(posedge clk);

	axi_read(1, 0, 12'h123, v);
	checks = checks + 1;
	if (v != 32'h4C574252) fail("MAGIC wrong");

	axi_read(0, 0, 12'h001, v);
	checks = checks + 1;
	if (v != 0) fail("ECHO not zero after reset");

	expect_echo = 0;
	for (i = 0; i < 2000; i = i + 1) begin : loop
		reg [31:0] d; reg [3:0] s; reg [3:0] len;
		d   = $random(seed);
		s   = ((i % 5) == 0) ? ($random(seed) & 4'hF) : 4'hF;
		len = ((i % 7) == 0) ? ($random(seed) & 3) : 0;
		axi_write(0, len, d, s, i[11:0]);
		// the last beat wins
		d = d + len;
		if (s[0]) expect_echo[7:0]   = d[7:0];
		if (s[1]) expect_echo[15:8]  = d[15:8];
		if (s[2]) expect_echo[23:16] = d[23:16];
		if (s[3]) expect_echo[31:24] = d[31:24];
		axi_read(0, ((i % 11) == 0) ? 4'd3 : 4'd0, ~i[11:0], v);
		checks = checks + 1;
		if (v != expect_echo) begin fail("ECHO read-back mismatch"); $display("  got %h want %h", v, expect_echo); end
	end

	// read-only registers ignore writes
	axi_write(1, 0, 32'hDEADBEEF, 4'hF, 12'h7);
	axi_read(1, 0, 12'h8, v);
	checks = checks + 1;
	if (v != 32'h4C574252) fail("MAGIC changed by a write");
	axi_read(0, 0, 12'hC, v);
	checks = checks + 1;
	if (v != expect_echo) fail("a write to MAGIC landed in ECHO");

	axi_read(2, 0, 12'h9, c0);
	repeat (50) @(posedge clk);
	axi_read(2, 0, 12'hA, c1);
	checks = checks + 1;
	if (c1 - c0 < 50) fail("CYCLES not counting");

	axi_read(3, 0, 12'hB, v);
	checks = checks + 1;
	// this read is counted after its last beat, so it is not in v yet
	if (v[15:0] != n_rd - 1 || v[31:16] != n_wr) begin
		fail("COUNT wrong"); $display("  got r=%0d w=%0d want r=%0d w=%0d", v[15:0], v[31:16], n_rd - 1, n_wr);
	end

	$display("%0d checks, %0d errors", checks, errors);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

initial begin
	#20_000_000;
	$display("RUN: FAIL (timeout)");
	$finish;
end

endmodule
