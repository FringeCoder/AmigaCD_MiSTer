// ddram_ctrl: a read return must be accepted whatever waitrequest is doing.
//
// Avalon splits the two: waitrequest gates COMMAND acceptance, readdatavalid
// marks returned data, and the slave is entitled to hold the first while
// pulsing the second. ddram_ctrl's state 1 used to wait for
// `~ram_busy & ram_dout_ready`, so a return arriving on a busy cycle was
// dropped -- ram_dout is only valid during the pulse -- and the state machine
// waited for a second pulse that never comes.
//
// Both clients of state 1 hang, and neither hangs quietly:
//
//   CPU cache fill   ramready never rises, so the 68k stalls on a fast-RAM
//                    fetch. With Z2 fast RAM decoding to DDR3 (memory_router
//                    :73/:111/:120) that is a stalled machine, which is what
//                    "boots to a black screen" looks like from outside.
//   bridge DMA read  dmaACK never pulses, so the Akiko TX command fetch from
//                    Z2 never returns -- see the dmaWE comment at :131.
//
// The slave model below is deliberately hostile in one specific, legal way:
// mode BUSY_ON_RETURN asserts DDRAM_BUSY exactly on the cycles it returns
// data. Nothing else about it is unusual.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../ddram_ctrl.v ../../cpu_cache_new.v \
//       ../../A2065/a2065_ddram_arbiter.v ../cache/dpram_sim.v \
//       tb_ddram_readreturn.sv && vvp tb

`timescale 1ns/1ps

module tb_ddram_readreturn;

	localparam integer BUSY_NEVER     = 0;
	localparam integer BUSY_ON_RETURN = 1;
	localparam integer BUSY_RANDOM    = 2;

	localparam integer RD_LATENCY = 6;   // slave read latency, sysclk cycles

	reg sysclk = 0;
	always #1 sysclk = ~sysclk;

	reg reset_n = 0;
	reg cache_rst = 1;

	// ---- DUT pins ----------------------------------------------------------
	wire        DDRAM_CLK;
	reg         DDRAM_BUSY = 0;
	wire  [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT = 0;
	reg         DDRAM_DOUT_READY = 0;
	wire        DDRAM_RD;
	wire [63:0] DDRAM_DIN;
	wire  [7:0] DDRAM_BE;
	wire        DDRAM_WE;

	reg  [28:1] cpuAddr = 0;
	reg         cpuCS = 0;
	reg   [1:0] cpustate = 2'b10;   // 2 = data read
	reg         cpuL = 0, cpuU = 0;
	reg  [15:0] cpuWR = 0;
	wire [15:0] cpuRD;
	wire        ramready;

	reg         ss_load_busy = 0;
	reg  [28:0] ss_address = 0;
	reg         ss_read = 0;
	wire [63:0] ss_readdata;
	wire        ss_readdatavalid;
	wire        ss_waitrequest;
	wire        ss_ram_idle;

	reg  [28:1] dmaAddr = 0;
	reg         dmaCS = 0;
	reg         dmaWE = 0;
	reg         dmaL = 0, dmaU = 0;
	reg  [15:0] dmaWR = 0;
	wire [15:0] dmaRD;
	wire        dmaACK;

	ddram_ctrl dut (
		.sysclk(sysclk), .reset_n(reset_n), .cache_rst(cache_rst),
		.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0000), .dcache_sw_en(1'b0),

		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),

		// A2065 port idle throughout: this is about master 0.
		.mem2_address(29'd0), .mem2_burstcount(8'd1), .mem2_read(1'b0),
		.mem2_readdata(), .mem2_readdatavalid(), .mem2_writedata(64'd0),
		.mem2_byteenable(8'd0), .mem2_write(1'b0), .mem2_waitrequest(),

		// Save state port. Idle for the first three checks; check 4 takes
		// the port for real, because that is the one thing this tree has
		// that the upstream of this fix does not.
		.ss_freeze(1'b0), .ss_load_busy(ss_load_busy), .ss_address(ss_address),
		.ss_writedata(64'd0), .ss_byteenable(8'hFF), .ss_write(1'b0),
		.ss_read(ss_read), .ss_readdata(ss_readdata),
		.ss_readdatavalid(ss_readdatavalid),
		.ss_waitrequest(ss_waitrequest), .ss_ram_idle(ss_ram_idle),

		.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate),
		.cpuL(cpuL), .cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(cpuRD),
		.ramshared(1'b0), .ramready(ramready),

		.dmaAddr(dmaAddr), .dmaCS(dmaCS), .dmaWE(dmaWE),
		.dmaL(dmaL), .dmaU(dmaU), .dmaWR(dmaWR), .dmaRD(dmaRD),
		.dmaACK(dmaACK)
	);

	// ---- Avalon slave model ------------------------------------------------
	// One command in flight is all ddram_ctrl ever issues (burstcount is tied
	// to 1 and state 1 waits), so a single scheduled return is enough.
	integer busy_mode = BUSY_NEVER;
	integer rand_seed = 32'h1234_5678;

	reg [63:0] mem [0:1023];
	integer    ret_timer = 0;         // >0 = a return is scheduled
	reg [28:0] ret_addr = 0;

	// Data a given row returns. Distinct per address so a wrong row is visible.
	function [63:0] row_data(input [28:0] a);
		row_data = {~a[15:0], a[15:0], 16'hBEEF, a[15:0] ^ 16'hA5A5};
	endfunction

	// BUSY policy. In BUSY_ON_RETURN it is high exactly when data comes back,
	// which is the case the old gate dropped; the rest of the time the slave
	// takes commands normally so the test still makes progress.
	always @(posedge sysclk) begin
		case (busy_mode)
			BUSY_ON_RETURN: DDRAM_BUSY <= (ret_timer == 1);
			BUSY_RANDOM: begin
				rand_seed <= {rand_seed[30:0], rand_seed[31] ^ rand_seed[21] ^ rand_seed[1] ^ rand_seed[0]};
				DDRAM_BUSY <= rand_seed[3] & rand_seed[7];
			end
			default: DDRAM_BUSY <= 1'b0;
		endcase
	end

	always @(posedge sysclk) begin
		DDRAM_DOUT_READY <= 1'b0;

		if (!reset_n) begin
			ret_timer <= 0;
		end else begin
			// Command acceptance: only when not asserting waitrequest.
			if (!DDRAM_BUSY && DDRAM_WE) begin
				mem[DDRAM_ADDR[9:0]] <= DDRAM_DIN;
			end
			if (!DDRAM_BUSY && DDRAM_RD && ret_timer == 0) begin
				ret_addr  <= DDRAM_ADDR;
				ret_timer <= RD_LATENCY;
			end

			if (ret_timer > 1) ret_timer <= ret_timer - 1;
			else if (ret_timer == 1) begin
				ret_timer        <= 0;
				DDRAM_DOUT       <= row_data(ret_addr);
				DDRAM_DOUT_READY <= 1'b1;
			end
		end
	end

	// ---- checks ------------------------------------------------------------
	integer errors = 0;
	localparam integer TIMEOUT_CYC = 4000;

	task expect_eq(input [511:0] what, input [15:0] got, input [15:0] want);
		begin
			if (got !== want) begin
				$display("FAIL: %0s: got %04x want %04x", what, got, want);
				errors = errors + 1;
			end else begin
				$display("ok:   %0s = %04x", what, got);
			end
		end
	endtask

	// A CPU read of one word through the cache path. Returns 1 on timeout,
	// which is what a dropped return looks like from the 68k's side: ramready
	// never rises and the cycle never terminates.
	task cpu_read(input [28:1] a, output [15:0] data, output timed_out);
		integer n;
		begin
			timed_out = 0;
			@(posedge sysclk);
			cpuAddr  <= a;
			cpustate <= 2'b10;      // data read
			cpuU     <= 0;
			cpuL     <= 0;
			cpuCS    <= 1;
			n = 0;
			while (!ramready && n < TIMEOUT_CYC) begin
				@(posedge sysclk);
				n = n + 1;
			end
			if (!ramready) timed_out = 1;
			data = cpuRD;
			@(posedge sysclk);
			cpuCS <= 0;
			@(posedge sysclk);
		end
	endtask

	// A bridge DMA read. dmaCS is held until dmaACK, one transfer per CS edge.
	task dma_read(input [28:1] a, output [15:0] data, output timed_out);
		integer n;
		begin
			timed_out = 0;
			@(posedge sysclk);
			dmaAddr <= a;
			dmaWE   <= 0;
			dmaU    <= 0;
			dmaL    <= 0;
			dmaCS   <= 1;
			n = 0;
			while (!dmaACK && n < TIMEOUT_CYC) begin
				@(posedge sysclk);
				n = n + 1;
			end
			if (!dmaACK) timed_out = 1;
			data = dmaRD;
			@(posedge sysclk);
			dmaCS <= 0;
			repeat (4) @(posedge sysclk);
		end
	endtask

	// What a 16-bit read of `a` should return, given the slave's row content.
	function [15:0] want_word(input [28:1] a);
		reg [28:0] row;
		reg  [1:0] lane;
		reg [63:0] rd;
		begin
			row  = {3'b001, a[28:3]};
			lane = a[2:1];
			rd   = row_data(row);
			want_word = rd[{lane, 4'b0000} +:16];
		end
	endfunction

	reg [15:0] got;
	reg        to;
	integer    i;
	integer    soak_fail;
	reg        ok_case;

	// Did the test ever actually reach the state it is testing -- a read armed
	// but unaccepted while ss owns master 0? ram_rd is the held strobe, so
	// ram_rd & ss_port_own is exactly "state 1 is waiting for a return it will
	// never be issued". Counted, and required to be non-zero: a construction
	// that never enters the window would pass no matter what the DUT did.
	integer coincide = 0;
	always @(posedge sysclk)
		if (dut.ram_rd && dut.ss_port_own) coincide = coincide + 1;

	// Park a read on the grant edge, then let ss read, and check the parked
	// client never takes ss's answer.
	//
	// Getting there is specific. ss_port_own is registered behind ss_ram_idle,
	// so the grant lands on the first edge after the port goes idle -- and the
	// state machine can arm on that same edge, because both read pre-edge
	// values and ss_port_own is still low. So: a bridge read in flight (port
	// not idle, grant deferred), a CPU miss queued behind it (cache_req high,
	// cannot arm from state 1), ss_load_busy raised mid-flight. When the bridge
	// read returns the state machine drops to state 0 and the port reads idle,
	// so the next edge both grants the port to ss AND arms the CPU fill.
	//
	// The CPU fill is then owed a return that will never be issued to it,
	// while ss's returns come back on the same ram_dout_ready pin.
	task ss_park_case(input integer lead, output ok);
		integer n;
		reg [63:0] ss_want;
		reg [15:0] cpu_want;
		begin
			ok = 1;
			ss_load_busy = 0; ss_read = 0; dmaCS = 0; cpuCS = 0;
			repeat (10) @(posedge sysclk);

			ss_address = 29'h001_0200 + lead;
			ss_want    = row_data(ss_address);
			cpuAddr    = 28'h0050_000 + lead*4;
			cpu_want   = want_word(cpuAddr);

			// bridge read in flight
			dmaAddr = 28'h0060_000 + lead*4;
			dmaWE = 0; dmaU = 0; dmaL = 0;
			dmaCS = 1;
			repeat (lead) @(posedge sysclk);

			// CPU miss queued behind it, and the port claimed mid-flight
			cpustate <= 2'b10; cpuU <= 0; cpuL <= 0; cpuCS <= 1;
			ss_load_busy = 1;

			// let the grant and the arm land
			n = 0;
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end

			// ss reads one word through the port it now owns
			ss_read = 1;
			@(posedge sysclk);
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			ss_read = 0;

			n = 0;
			while (!ss_readdatavalid && n < TIMEOUT_CYC) begin
				// the parked CPU fill must NOT complete off ss's return
				if (ramready && cpuRD !== cpu_want) begin
					$display("FAIL: lead %0d: CPU read completed with %04x during ss ownership, want %04x",
					         lead, cpuRD, cpu_want);
					ok = 0;
				end
				@(posedge sysclk); n = n + 1;
			end
			if (!ss_readdatavalid) begin
				$display("FAIL: lead %0d: the ss read never returned", lead);
				ok = 0;
			end else if (ss_readdata !== ss_want) begin
				$display("FAIL: lead %0d: ss read got %016x want %016x", lead, ss_readdata, ss_want);
				ok = 0;
			end

			repeat (6) @(posedge sysclk);
			if (ramready && cpuRD !== cpu_want) begin
				$display("FAIL: lead %0d: CPU read completed with %04x, want %04x",
				         lead, cpuRD, cpu_want);
				ok = 0;
			end

			// release; the held request is re-issued and must answer correctly
			ss_load_busy = 0;
			n = 0;
			while (!ramready && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			if (!ramready) begin
				$display("FAIL: lead %0d: CPU read never completed after the grant ended", lead);
				ok = 0;
			end else if (cpuRD !== cpu_want) begin
				$display("FAIL: lead %0d: after the grant the CPU read returned %04x want %04x",
				         lead, cpuRD, cpu_want);
				ok = 0;
			end
			cpuCS = 0; dmaCS = 0;
			repeat (8) @(posedge sysclk);
		end
	endtask

	initial begin
		repeat (20) @(posedge sysclk);
		reset_n = 1;
		repeat (20) @(posedge sysclk);

		// ---- 1. baseline: waitrequest low when the data comes back ---------
		busy_mode = BUSY_NEVER;
		cpu_read(28'h0010_020, got, to);
		if (to) begin
			$display("FAIL: CPU read timed out with waitrequest never asserted");
			errors = errors + 1;
		end else expect_eq("CPU read, quiet slave", got, want_word(28'h0010_020));

		dma_read(28'h0010_030, got, to);
		if (to) begin
			$display("FAIL: DMA read timed out with waitrequest never asserted");
			errors = errors + 1;
		end else expect_eq("DMA read, quiet slave", got, want_word(28'h0010_030));

		// ---- 2. the defect: waitrequest high on the return cycle -----------
		busy_mode = BUSY_ON_RETURN;

		cpu_read(28'h0010_040, got, to);
		if (to) begin
			$display("FAIL: CPU read never completed -- return dropped while waitrequest was high");
			errors = errors + 1;
		end else expect_eq("CPU read, busy on the return cycle", got, want_word(28'h0010_040));

		dma_read(28'h0010_050, got, to);
		if (to) begin
			$display("FAIL: DMA read never completed -- return dropped while waitrequest was high");
			errors = errors + 1;
		end else expect_eq("DMA read, busy on the return cycle", got, want_word(28'h0010_050));

		// ---- 3. soak: waitrequest uncorrelated with the returns ------------
		// A real DDR3 bridge asserts BUSY for its own reasons -- refresh, bank
		// conflicts, the other master -- so the overlap is a coincidence that
		// gets likelier with traffic, not a pattern. 32 reads of each kind.
		busy_mode = BUSY_RANDOM;
		soak_fail = 0;
		for (i = 0; i < 32; i = i + 1) begin
			cpu_read(28'h0020_000 + i*4, got, to);
			if (to || got !== want_word(28'h0020_000 + i*4)) soak_fail = soak_fail + 1;
			dma_read(28'h0030_000 + i*4, got, to);
			if (to || got !== want_word(28'h0030_000 + i*4)) soak_fail = soak_fail + 1;
		end
		if (soak_fail) begin
			$display("FAIL: %0d of 64 reads under random waitrequest were lost or wrong", soak_fail);
			errors = errors + 1;
		end else begin
			$display("ok:   64 reads under random waitrequest all returned correctly");
		end

		// ---- 4. the save-state port owns master 0 --------------------------
		// ss_port_own is registered, so it is granted on the edge AFTER
		// ss_ram_idle goes true -- and on that same edge the state machine can
		// still arm a bridge DMA read, because the bridge is not parked for a
		// restore (ddram_ctrl.v:65-84). That read then sits in state 1 while
		// ss owns the port. Without ~ram_busy holding it off, state 1 would
		// take the NEXT return it sees, and the next return belongs to ss.
		//
		// Swept rather than hand-timed: the bridge request crosses a 2-FF sync
		// chain, so the arming cycle is not exactly predictable from here.
		// The slave has to be busy sometimes or the window cannot open: with
		// waitrequest never asserted, a pending bridge read arms the moment it
		// appears, so it is always either in flight before the grant (which
		// ss_ram_idle then defers) or requested after it (which the pinned
		// ram_busy then blocks). Only a deferred arm lands on the grant edge.
		busy_mode = BUSY_NEVER;
		soak_fail = 0;
		for (i = 1; i < 9; i = i + 1) begin
			ss_park_case(i, ok_case);
			if (!ok_case) soak_fail = soak_fail + 1;
		end
		$display("info: %0d cycles with a read parked while ss owned master 0", coincide);
		if (soak_fail) begin
			$display("FAIL: a parked read took the save-state port's data in %0d of 8 constructions",
			         soak_fail);
			errors = errors + 1;
		end else if (coincide == 0) begin
			$display("FAIL: no read was ever parked under ss ownership -- this check proved nothing");
			errors = errors + 1;
		end else begin
			$display("ok:   a read parked under ss ownership never took an ss return");
		end

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#20000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
