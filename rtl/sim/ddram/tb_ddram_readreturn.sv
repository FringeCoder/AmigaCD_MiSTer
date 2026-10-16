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
	localparam integer BUSY_ALWAYS    = 3;   // the bridge taking nothing, for check 5

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
	reg         ss_freeze = 0;
	reg         ss_cpu_parked = 1;   // check 7 holds it low
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
		.ss_freeze(ss_freeze), .ss_load_busy(ss_load_busy), .ss_address(ss_address),
		.ss_writedata(64'd0), .ss_byteenable(8'hFF), .ss_write(1'b0),
		.ss_read(ss_read), .ss_readdata(ss_readdata),
		.ss_readdatavalid(ss_readdatavalid),
		.ss_waitrequest(ss_waitrequest), .ss_ram_idle(ss_ram_idle),
		.ss_cpu_parked(ss_cpu_parked),

		.cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate),
		.cpuL(cpuL), .cpuU(cpuU), .cpuWR(cpuWR), .cpuRD(cpuRD),
		.ramshared(1'b0), .ramready(ramready),
		// Long-word fast RAM cycles (upstream 26eb46a): the 68030's, not
		// exercised here.
		.cpuLong(1'b0), .cpuLong1(1'b0), .cpuWR_lo(16'd0), .cpuRD_hi(),
		.ramready_l(),

		.dmaAddr(dmaAddr), .dmaCS(dmaCS), .dmaWE(dmaWE),
		.dmaL(dmaL), .dmaU(dmaU), .dmaWR(dmaWR), .dmaRD(dmaRD),
		.dmaACK(dmaACK),

		// SDRAM fast RAM (upstream 26eb46a). Nothing here decodes to it, and
		// sdr_hi is held low so the 3'b011 window does not either.
		.sdr_hi(1'b0), .sdr_req(), .sdr_we(), .sdr_addr(), .sdr_dqm(),
		.sdr_wdat(), .sdr_w2(), .sdr_dqm2(), .sdr_wdat2(),
		.sdr_ack(1'b0), .sdr_rvalid(1'b0), .sdr_rdat(16'd0)
	);

	// ---- Avalon slave model ------------------------------------------------
	// Pipelined reads with bursts. Since upstream 26eb46a ddram_ctrl issues
	// two-beat reads (ram_bcnt = 2) and its stream buffer can have a read
	// accepted while an earlier one is still to return, both of which Avalon
	// allows; this model used to take one single-beat read at a time, which
	// left the second beat of every cache miss owed forever. Accepted reads go
	// in a queue; each returns RD_LATENCY cycles after acceptance at the
	// earliest, one beat per cycle, beats in order, rows a, a+1, ...
	integer busy_mode = BUSY_NEVER;
	integer rand_seed = 32'h1234_5678;

	reg [63:0] mem [0:1023];
	localparam integer QN = 16;
	reg [28:0] q_addr [0:QN-1];
	reg  [7:0] q_beats[0:QN-1];
	integer    q_due  [0:QN-1];
	integer    q_h = 0, q_t = 0, q_n = 0;
	integer    cyc = 0;
	reg  [7:0] beat = 0;              // beats of the head already returned
	// "a return is coming within a cycle", for BUSY_ON_RETURN below
	wire       ret_next = (q_n != 0) && (cyc + 1 >= q_due[q_h]);

	// Data a given row returns. Distinct per address so a wrong row is visible.
	function [63:0] row_data(input [28:0] a);
		row_data = {~a[15:0], a[15:0], 16'hBEEF, a[15:0] ^ 16'hA5A5};
	endfunction

	// BUSY policy. In BUSY_ON_RETURN it is high exactly when data comes back,
	// which is the case the old gate dropped; the rest of the time the slave
	// takes commands normally so the test still makes progress.
	always @(posedge sysclk) begin
		case (busy_mode)
			BUSY_ON_RETURN: DDRAM_BUSY <= ret_next;
			BUSY_RANDOM: begin
				rand_seed <= {rand_seed[30:0], rand_seed[31] ^ rand_seed[21] ^ rand_seed[1] ^ rand_seed[0]};
				DDRAM_BUSY <= rand_seed[3] & rand_seed[7];
			end
			BUSY_ALWAYS: DDRAM_BUSY <= 1'b1;
			default: DDRAM_BUSY <= 1'b0;
		endcase
	end

	always @(posedge sysclk) begin
		DDRAM_DOUT_READY <= 1'b0;
		cyc = cyc + 1;

		if (!reset_n) begin
			q_h = 0; q_t = 0; q_n = 0; beat = 0;
		end else begin
			// Command acceptance: only when not asserting waitrequest.
			if (!DDRAM_BUSY && DDRAM_WE) begin
				mem[DDRAM_ADDR[9:0]] <= DDRAM_DIN;
			end
			if (!DDRAM_BUSY && DDRAM_RD) begin
				if (q_n == QN) $fatal(1, "slave model: more than %0d reads outstanding", QN);
				q_addr[q_t]  = DDRAM_ADDR;
				q_beats[q_t] = DDRAM_BURSTCNT;
				q_due[q_t]   = cyc + RD_LATENCY;
				q_t = (q_t + 1) % QN;
				q_n = q_n + 1;
			end

			if (q_n != 0 && cyc >= q_due[q_h]) begin
				DDRAM_DOUT       <= row_data(q_addr[q_h] + beat);
				DDRAM_DOUT_READY <= 1'b1;
				if (beat + 1 >= q_beats[q_h]) begin
					beat = 0;
					q_h = (q_h + 1) % QN;
					q_n = q_n - 1;
				end
				else beat = beat + 1;
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

	// A read armed but unaccepted while ss owns master 0. ram_rd is the held
	// strobe, so ram_rd & ss_port_own is "something of ours is parked under
	// ss". It used to be expected here -- the grant edge could arm one -- and
	// it held ss_ram_idle low for the whole ownership, which in the core keeps
	// cpu_boundary low and times a restore's quiesce out. Since the grant edge
	// is gated (ss_grant in ss_hold) it must never happen, and ss_ram_idle must
	// stay high for as long as ss owns the port.
	//
	// grant_pending counts grants that landed with a request waiting to arm,
	// which is the construction this check exists for: required non-zero, or
	// the zero above proves nothing.
	integer coincide = 0, idle_lost = 0, grant_pending = 0;
	always @(posedge sysclk) begin
		if (dut.ram_rd && dut.ss_port_own) coincide = coincide + 1;
		if (dut.ss_port_own && !ss_ram_idle) idle_lost = idle_lost + 1;
		if (dut.ss_grant && (dut.cache_req || (dut.dma_read_req && !dut.dma_read_ack)))
			grant_pending = grant_pending + 1;
	end

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

	// ---- 5. a posted CPU write is in DDR3 before the port is granted -----
	// Since upstream 26eb46a a CPU write to fast RAM is acknowledged into a
	// four-deep queue and reaches DDR3 later. A write still queued when the
	// grant fires would miss a save state's snapshot, and with ram_busy pinned
	// it would land after the dump instead. ss_ram_idle waits for the queue to
	// be empty (~wq_any); this checks that it does.
	//
	// The queue has to be HELD for that to be tested: unhindered it drains in
	// a cycle, faster than the grant can follow, and the check passes with or
	// without ~wq_any. So the bridge takes nothing for a while: write A goes
	// into ddr_cmd_pipe and sits there, which keeps master 0 waiting, so write
	// B stays in the queue -- and the port is asked for then. Words at
	// [2:1] = 0, the low lane of the beat (ram_din = {dl, dh, dl, dh}).
	task cpu_write(input [28:1] a, input [15:0] d);
		integer n;
		begin
			@(posedge sysclk);
			cpuAddr  <= a;
			cpuWR    <= d;
			cpustate <= 2'b11;      // data write
			cpuU     <= 0;
			cpuL     <= 0;
			cpuCS    <= 1;
			n = 0;
			while (!ramready && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			if (!ramready) $display("FAIL: write to %07x was never acknowledged", {a, 1'b0});
			cpuCS <= 0;
			@(posedge sysclk);
		end
	endtask

	task ss_after_write(input integer k, output ok);
		integer n;
		reg [28:1] a, b;
		begin
			ok = 1;
			a = 28'h0070_000 + k*16;
			b = a + 8;              // next 64-bit row
			mem[a[12:3]] = 64'd0;
			mem[b[12:3]] = 64'd0;
			busy_mode = BUSY_ALWAYS;
			repeat (2) @(posedge sysclk);
			cpu_write(a, 16'hA500 + k);
			cpu_write(b, 16'h5A00 + k);
			ss_load_busy = 1;
			repeat (12) @(posedge sysclk);
			busy_mode = BUSY_NEVER;
			n = 0;
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			if (ss_waitrequest) begin
				$display("FAIL: write %0d: the port was never granted", k);
				ok = 0;
			end else if (mem[b[12:3]][15:0] !== 16'h5A00 + k) begin
				$display("FAIL: write %0d: granted with a posted write not yet in DDR3 (row holds %016x)",
				         k, mem[b[12:3]]);
				ok = 0;
			end
			ss_load_busy = 0;
			repeat (8) @(posedge sysclk);
		end
	endtask

	integer ddr_we_n = 0;
	always @(posedge sysclk) if (!DDRAM_BUSY && DDRAM_WE) ddr_we_n = ddr_we_n + 1;   // check 6's write is the only one in flight

	task ss_freeze_edge(output ok);
		integer n;
		begin
			ok = 1;
			busy_mode = BUSY_NEVER;
			ddr_we_n = 0;
			repeat (10) @(posedge sysclk);
			dmaAddr = 28'h0001_E00;
			dmaWE = 1; dmaU = 0; dmaL = 0; dmaWR = 16'hD00D;
			dmaCS = 1;
			n = 0;
			// raise the freeze on the edge the write arms, with idle true before it
			while (n < TIMEOUT_CYC) begin
				@(negedge sysclk);
				if (ss_ram_idle && dut.dw_sel && !dut.ram_busy) begin
					@(posedge sysclk); #0.1 ss_freeze = 1;
					n = TIMEOUT_CYC;
				end
				n = n + 1;
			end
			if (!ss_freeze) begin
				$display("FAIL: freeze edge: the arming edge was never reached");
				ok = 0;
			end
			n = 0;
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			if (ss_waitrequest) begin
				$display("FAIL: freeze edge: frozen with a write armed, and the port was never granted");
				ok = 0;
			end
			repeat (20) @(posedge sysclk);
			if (ddr_we_n != 1) begin
				$display("FAIL: freeze edge: the write reached DDR3 %0d times, want 1", ddr_we_n);
				ok = 0;
			end
			if (ok) $display("ok:   a write armed on the freeze edge completed once and the grant followed");
			ss_freeze = 0;
			dmaCS = 0; dmaWE = 0;
			repeat (20) @(posedge sysclk);
		end
	endtask

	task ss_parked_gate(output ok);
		integer n;
		reg [15:0] got;
		reg to;
		begin
			ok = 1;
			busy_mode = BUSY_NEVER;
			ss_cpu_parked = 0;
			ss_load_busy = 1;
			repeat (40) @(posedge sysclk);
			if (!ss_waitrequest) begin
				$display("FAIL: restore granted before the CPU parked");
				ok = 0;
			end
			// the CPU, not yet parked, still gets its fast RAM read
			cpu_read(28'h0080_000, got, to);
			if (to) begin
				$display("FAIL: an unparked CPU's read was not served during a restore request");
				ok = 0;
			end
			ss_cpu_parked = 1;
			n = 0;
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			if (ss_waitrequest) begin
				$display("FAIL: restore never granted after the CPU parked");
				ok = 0;
			end
			if (ok) $display("ok:   the restore's grant waited for the park, and the CPU was served until then");
			ss_load_busy = 0;
			repeat (20) @(posedge sysclk);
		end
	endtask

	// ---- 8. the stream buffer does not take ss's return ----------------
	// Defence in depth, and white-box because it has to be: since the grant
	// waits for ~sb_wait & ~sc_wait and nothing can arm on the grant edge or
	// under ownership, no input sequence leaves a buffer read owed while ss
	// owns master 0. The ~ss_port_own on the buffer's return is there for the
	// day that stops being true, so the owed read is planted directly: sb_wait
	// set while ss owns the port, then an ss read. The beat is ss's and must
	// go to ss only -- sb_wait still set afterwards, nothing filled from it.
	task ss_buffer_guard(output ok);
		integer n;
		begin
			ok = 1;
			busy_mode = BUSY_NEVER;
			ss_cpu_parked = 1;
			ss_load_busy = 1;
			n = 0;
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			@(negedge sysclk);
			dut.sb_wait = 1'b1;          // a buffer read "owed" under ss
			dut.sb_kill = 1'b0;
			ss_address = 29'h001_0400;
			ss_read = 1;
			@(posedge sysclk);
			while (ss_waitrequest && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			ss_read = 0;
			n = 0;
			while (!ss_readdatavalid && n < TIMEOUT_CYC) begin @(posedge sysclk); n = n + 1; end
			@(posedge sysclk); #0.1;
			if (!dut.sb_wait) begin
				$display("FAIL: the stream buffer took the save-state port's beat (sb_wait cleared by it)");
				ok = 0;
			end
			if (dut.sb_d === row_data(29'h001_0400)) begin
				$display("FAIL: the stream buffer holds the save-state port's data");
				ok = 0;
			end
			if (ok) $display("ok:   a buffer read owed under ss did not take ss's beat");
			@(negedge sysclk);
			dut.sb_wait = 1'b0;
			ss_load_busy = 0;
			repeat (20) @(posedge sysclk);
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
		// ss_ram_idle goes true -- and on that same edge the state machine
		// could still arm a bridge DMA read, because the bridge is not parked
		// for a restore (ddram_ctrl.v:65-84). It used to: the read then sat in
		// state 1 under ss, and ~ss_port_own there kept it off ss's returns,
		// but it also kept ss_ram_idle low for the whole ownership. Now the
		// grant edge is gated, so nothing arms on it; this checks that, and
		// that ss's own read is right and the CPU's is served after.
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
		$display("info: %0d grants landed with a request waiting to arm", grant_pending);
		if (soak_fail) begin
			$display("FAIL: the save-state port's read went wrong in %0d of 8 constructions", soak_fail);
			errors = errors + 1;
		end else if (grant_pending == 0) begin
			$display("FAIL: no grant ever landed with a request waiting -- this check proved nothing");
			errors = errors + 1;
		end else if (coincide != 0 || idle_lost != 0) begin
			$display("FAIL: a request was armed on the grant edge: %0d cycles parked under ss, %0d owned cycles with ss_ram_idle low",
			         coincide, idle_lost);
			errors = errors + 1;
		end else begin
			$display("ok:   nothing armed on the grant edge; ss_ram_idle stayed high through every ownership");
		end

		// ---- 5. posted writes drain before the grant ------------------------
		soak_fail = 0;
		for (i = 0; i < 16; i = i + 1) begin
			ss_after_write(i, ok_case);
			if (!ok_case) soak_fail = soak_fail + 1;
		end
		if (soak_fail) begin
			$display("FAIL: %0d of 16 grants came with a posted write still queued", soak_fail);
			errors = errors + 1;
		end else begin
			$display("ok:   16 grants, each after its posted write reached DDR3");
		end

		// ---- 6. a request armed on the freeze edge does not hang the save --
		// ss_quiesce raises the freeze on an edge where ss_ram_idle was true
		// before it, and the state machine can arm on that same edge. With
		// ram_busy pinned by the freeze that strobe was never accepted, idle
		// never came back and the grant never fired. Freeze raised on exactly
		// such an edge (a bridge DMA write arming): the grant must follow, and
		// the write must reach DDR3 once, not be re-issued.
		ss_freeze_edge(ok_case);
		if (!ok_case) errors = errors + 1;

		// ---- 7. a restore's grant waits for the CPU to park ---------------
		ss_parked_gate(ok_case);
		if (!ok_case) errors = errors + 1;

		// ---- 8. the stream buffer's guard ----------------------------------
		ss_buffer_guard(ok_case);
		if (!ok_case) errors = errors + 1;

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
