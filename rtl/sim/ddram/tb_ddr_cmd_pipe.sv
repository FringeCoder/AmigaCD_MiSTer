/*
 * tb_ddr_cmd_pipe.sv -- checks ddr_cmd_pipe.
 *
 * The stage exists for timing, so what has to be proved is that it is
 * invisible to the protocol: every command the upstream master issues reaches
 * the downstream slave exactly once, in order, with its payload intact, under
 * arbitrary back-pressure from either side.
 *
 * Those are the two ways a one-deep holding register goes wrong -- dropping a
 * command when a load and an acceptance land in the same cycle, and repeating
 * one because a strobe outlived its acceptance. Neither would look like a
 * timing change on hardware. A dropped fast-RAM command is a 68k stalled
 * forever on a fetch; a repeated save-state write is a file with a word in it
 * twice. So the bench logs what was issued and what arrived and compares the
 * two sequences, rather than checking cycle shapes it could get wrong in the
 * same direction as the code it is checking.
 */
`timescale 1ns/1ps

module tb_ddr_cmd_pipe;

	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg  [28:0] u_address    = 0;
	reg   [7:0] u_burstcount = 0;
	reg         u_read       = 0;
	reg  [63:0] u_writedata  = 0;
	reg   [7:0] u_byteenable = 0;
	reg         u_write      = 0;
	wire        u_waitrequest;

	wire [28:0] d_address;
	wire  [7:0] d_burstcount;
	wire        d_read;
	wire [63:0] d_writedata;
	wire  [7:0] d_byteenable;
	wire        d_write;
	reg         d_waitrequest = 0;

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

	ddr_cmd_pipe dut
	(
		.clk(clk), .rst(rst),
		.u_address(u_address), .u_burstcount(u_burstcount), .u_read(u_read),
		.u_writedata(u_writedata), .u_byteenable(u_byteenable),
		.u_write(u_write), .u_waitrequest(u_waitrequest),
		.d_address(d_address), .d_burstcount(d_burstcount), .d_read(d_read),
		.d_writedata(d_writedata), .d_byteenable(d_byteenable),
		.d_write(d_write), .d_waitrequest(d_waitrequest)
	);

	// ---- the two logs -------------------------------------------------------
	localparam MAXC = 512;
	reg [28:0] iss_addr [0:MAXC-1];
	reg [63:0] iss_data [0:MAXC-1];
	reg  [7:0] iss_be   [0:MAXC-1];
	reg        iss_wr   [0:MAXC-1];
	integer    n_iss = 0;

	reg [28:0] got_addr [0:MAXC-1];
	reg [63:0] got_data [0:MAXC-1];
	reg  [7:0] got_be   [0:MAXC-1];
	reg        got_wr   [0:MAXC-1];
	integer    n_got = 0;

	// Downstream acceptance: a strobe up on a rising edge with waitrequest low.
	always @(posedge clk) begin
		if (!rst && (d_read || d_write) && !d_waitrequest) begin
			got_addr[n_got] = d_address;
			got_data[n_got] = d_writedata;
			got_be  [n_got] = d_byteenable;
			got_wr  [n_got] = d_write;
			n_got = n_got + 1;
		end
	end

	// ---- continuous assertions ---------------------------------------------
	//
	// Stability of a pending command. Avalon lets the slave take as long as it
	// likes, but only while nothing moves underneath it.
	reg        pend     = 0;
	reg [28:0] pend_a;
	reg [63:0] pend_d;
	reg  [7:0] pend_be;
	reg        pend_rd, pend_wr;
	integer    stab_err = 0;
	integer    both_err = 0;

	always @(posedge clk) begin
		if (rst) pend <= 0;
		else begin
			if (d_read && d_write) both_err = both_err + 1;

			if (pend && (d_read || d_write)) begin
				if (d_address !== pend_a || d_byteenable !== pend_be
				    || d_read !== pend_rd || d_write !== pend_wr
				    || (pend_wr && d_writedata !== pend_d))
					stab_err = stab_err + 1;
			end

			// Still pending into the next cycle only if it was not taken.
			if ((d_read || d_write) && d_waitrequest) begin
				pend    <= 1;
				pend_a  <= d_address;
				pend_d  <= d_writedata;
				pend_be <= d_byteenable;
				pend_rd <= d_read;
				pend_wr <= d_write;
			end
			else pend <= 0;
		end
	end

	// ---- upstream driver ----------------------------------------------------
	//
	// Holds the command up until the cycle in which waitrequest is low, which
	// is what a real Avalon master does, and logs it on that cycle.
	//
	// Everything the bench drives changes on a FALLING edge and is sampled on
	// the rising one. Driving on the rising edge instead -- the first version
	// of this did -- races the module under test: the command was cleared in
	// the same delta as the flops that were supposed to latch it, and the
	// bench reported 203 commands issued and none accepted. A bench that loses
	// that race in the other direction would pass while proving nothing.
	//
	// The strobe is NOT dropped after acceptance. The next issue() overwrites
	// it on the following falling edge, so a sequence of calls presents
	// commands with no idle cycle between them -- which is the case that
	// exercises a load and an acceptance landing together. idle() ends a
	// sequence.
	task issue(input [28:0] a, input [63:0] d, input [7:0] be, input wr);
		begin : body
			@(negedge clk);
			u_address    = a;
			u_writedata  = d;
			u_byteenable = be;
			u_burstcount = 8'd1;
			u_write      = wr;
			u_read       = ~wr;
			forever begin
				@(posedge clk);
				if (!u_waitrequest) begin
					iss_addr[n_iss] = a;
					iss_data[n_iss] = d;
					iss_be  [n_iss] = be;
					iss_wr  [n_iss] = wr;
					n_iss   = n_iss + 1;
					disable body;
				end
			end
		end
	endtask

	task idle;
		begin
			@(negedge clk);
			u_read  = 0;
			u_write = 0;
		end
	endtask

	task slave_ready(input rdy);
		begin
			@(negedge clk);
			d_waitrequest = ~rdy;
		end
	endtask

	integer i, mismatch;
	reg [31:0] seed = 32'h1234_5678;
	reg [31:0] k;

	// Random downstream back-pressure, ready roughly one cycle in four.
	reg randomise_wait = 0;
	always @(posedge clk)
		if (randomise_wait) d_waitrequest <= (($random(seed) & 3) != 0);

	initial begin
		$display("tb_ddr_cmd_pipe");
		repeat (3) @(posedge clk);
		rst = 0;
		@(posedge clk);

		ok(d_read === 1'b0 && d_write === 1'b0, "reset leaves no strobe asserted");
		ok(u_waitrequest === 1'b0, "reset leaves upstream free to issue");

		// One write with the slave always ready.
		issue(29'h0000010, 64'hDEAD_BEEF_0000_0001, 8'h0F, 1'b1);
		idle();
		repeat (4) @(posedge clk);
		ok(n_got == 1, "one write issued, one accepted");
		ok(got_addr[0] === 29'h0000010, "write address intact");
		ok(got_data[0] === 64'hDEAD_BEEF_0000_0001, "write data intact");
		ok(got_be[0]   === 8'h0F,  "byteenable intact");
		ok(got_wr[0]   === 1'b1,   "arrived as a write");

		// One read.
		issue(29'h0000020, 64'd0, 8'hFF, 1'b0);
		idle();
		repeat (4) @(posedge clk);
		ok(n_got == 2, "one read issued, one accepted");
		ok(got_addr[1] === 29'h0000020, "read address intact");
		ok(got_wr[1]   === 1'b0, "arrived as a read");

		// A stalling slave. The command is held, and when the stall lifts it
		// is taken once and not again.
		slave_ready(1'b0);
		issue(29'h0000030, 64'hA5A5_A5A5_5A5A_5A5A, 8'hFF, 1'b1);
		idle();
		repeat (10) @(posedge clk);
		ok(n_got == 2,                  "stalled slave: nothing accepted");
		ok(d_write === 1'b1,            "stalled slave: strobe still up");
		ok(d_address === 29'h0000030,   "stalled slave: address held");
		ok(u_waitrequest === 1'b1,      "stalled slave: upstream held off");
		slave_ready(1'b1);
		repeat (2) @(posedge clk);
		ok(n_got == 3, "stall lifted: accepted exactly once");
		repeat (8) @(posedge clk);
		ok(n_got == 3, "stall lifted: and not again");

		// 200 commands back to back under random back-pressure, every payload
		// distinct so a reorder or a repeat cannot pass.
		@(negedge clk);
		randomise_wait = 1;
		for (i = 0; i < 200; i = i + 1) begin
			k = i;
			issue(29'h1000000 + k[28:0], {32'hC0DE_0000, k}, k[7:0], k[0]);
		end
		idle();
		@(negedge clk);
		randomise_wait = 0;
		slave_ready(1'b1);
		repeat (20) @(posedge clk);

		ok(n_got == n_iss, "every command accepted exactly once");
		$display("info: %0d commands issued, %0d accepted", n_iss, n_got);
		mismatch = 0;
		for (i = 0; i < n_iss; i = i + 1)
			if (got_addr[i] !== iss_addr[i] || got_wr[i] !== iss_wr[i]
			    || got_be[i] !== iss_be[i]
			    || (iss_wr[i] && got_data[i] !== iss_data[i]))
				mismatch = mismatch + 1;
		ok(mismatch == 0, "accepted in order with payloads intact");
		ok(both_err == 0, "read and write never asserted together");
		ok(stab_err == 0, "a pending command never changed under the slave");

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#2000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
