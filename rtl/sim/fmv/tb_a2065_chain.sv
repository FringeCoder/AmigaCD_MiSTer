// tb_a2065_chain.sv -- the A2065 mailbox behind the core's real DDR3 path:
// a2065_ddr3_mailbox -> dsnd_arb -> mirror_arb -> fmv_arb (the three
// a2065_ddram_arbiter stages of AmigaCD.sv, their other masters idle) ->
// ddram_ctrl's mem2 port, q2 skid and arbiter -> ddr_cmd_pipe -> a DDR3 model.
//
// Gate 1 runs, 2026-11-02 night: on hardware the HPS takes one of the first
// few A2065 reads and its beat never comes back, even after a clean core and
// port reset (the first read after the pointer publish). This asks whether
// the core's own path loses it: every read the mailbox issues must come back
// to it, and the arbiters must never sit busy for long.
`timescale 1ns/1ps

module tb_a2065_chain;
	reg sysclk = 0;
	always #4.39 sysclk = ~sysclk;      // clk_114 = DDRAM_CLK
	reg reset_n = 0;
	reg rst_n = 0;                      // the mailbox's (minimig) reset

	// ---- the 68k side (clk_sys, 28 MHz): board RAM reads and RMW writes and
	// register commands, level handshakes as a2065_regfile/a2065_ddram drive
	// them -- hold the request until answered, then drop it.
	reg clk_sys = 0;
	always #17.6 clk_sys = ~clk_sys;
	reg        h_on = 0;
	reg        br_v = 0, br_rw = 0; reg [13:0] br_a = 0; reg [15:0] br_wd = 0; reg [1:0] br_be = 2'b11;
	reg        cmd_p = 0; reg [6:0] cmd_r = 0; reg [15:0] cmd_d = 0;
	integer    h_seed = 3, br_done = 0, cmd_done = 0;
	wire [28:0] a_addr; wire [7:0] a_bc, a_be; wire a_rd, a_wr, a_rv, a_wait;
	wire [63:0] a_rdata, a_wdata;
	wire cmd_clear, int2, bram_ack, bram_rv; wire [15:0] c0, c1, c2, c3, bram_d;
	a2065_ddr3_mailbox mbox (
		.clk(sysclk), .rst_n(rst_n),
		.cmd_pending(cmd_p), .cmd_rap(cmd_r), .cmd_data(cmd_d), .cmd_clear(cmd_clear),
		.csr0_out(c0), .csr1_out(c1), .csr2_out(c2), .csr3_out(c3), .a2065_int2(int2),
		.bram_req_valid(br_v), .bram_req_addr(br_a), .bram_req_wdata(br_wd),
		.bram_req_rw(br_rw), .bram_req_be(br_be), .bram_req_ack(bram_ack),
		.bram_resp_valid(bram_rv), .bram_resp_data(bram_d),
		.avl_address(a_addr), .avl_burstcount(a_bc), .avl_read(a_rd),
		.avl_readdata(a_rdata), .avl_readdatavalid(a_rv),
		.avl_writedata(a_wdata), .avl_byteenable(a_be), .avl_write(a_wr),
		.avl_waitrequest(a_wait)
	);

	reg ack_s1 = 0, ack_s2 = 0, rv_s1 = 0, rv_s2 = 0, clr_s1 = 0, clr_s2 = 0;
	always @(posedge clk_sys) begin
		ack_s1 <= bram_ack; ack_s2 <= ack_s1; rv_s1 <= bram_rv; rv_s2 <= rv_s1;
		clr_s1 <= cmd_clear; clr_s2 <= clr_s1;
		if (br_v && ack_s2 && rv_s2) begin br_v <= 0; br_done = br_done + 1; end
		if (cmd_p && clr_s2) begin cmd_p <= 0; cmd_done = cmd_done + 1; end
		if (h_on && !br_v && !ack_s2 && !rv_s2 && !cmd_p && !clr_s2) begin
			case ($random(h_seed) & 7)
			0, 1: begin br_v <= 1; br_rw <= 0; br_a <= $random(h_seed); end           // read
			2:    begin br_v <= 1; br_rw <= 1; br_a <= $random(h_seed);                // RMW write
			            br_wd <= $random(h_seed); br_be <= 1 + ($random(h_seed) % 3); end
			3:    begin cmd_p <= 1; cmd_r <= 1 + ($random(h_seed) & 63); cmd_d <= $random(h_seed); end
			default: ;
			endcase
		end
	end

	// ---- the three outer stages, as in AmigaCD.sv
	`define ARB_S(p) wire [28:0] p``_address; wire [7:0] p``_burstcount, p``_byteenable; \
	                 wire p``_read, p``_write, p``_readdatavalid, p``_waitrequest; \
	                 wire [63:0] p``_readdata, p``_writedata;
	`ARB_S(dm) `ARB_S(mf) `ARB_S(mem2)
	wire [31:0] dbg_d, dbg_m, dbg_f;

	a2065_ddram_arbiter dsnd_arb (.clk(sysclk), .rst(~reset_n),
		.m0_address(a_addr), .m0_burstcount(a_bc), .m0_read(a_rd), .m0_readdata(a_rdata),
		.m0_readdatavalid(a_rv), .m0_writedata(a_wdata), .m0_byteenable(a_be),
		.m0_write(a_wr), .m0_waitrequest(a_wait),
		.m1_address(29'd0), .m1_burstcount(8'd1), .m1_read(1'b0), .m1_readdata(),
		.m1_readdatavalid(), .m1_writedata(64'd0), .m1_byteenable(8'hFF),
		.m1_write(1'b0), .m1_waitrequest(),
		.s_address(dm_address), .s_burstcount(dm_burstcount), .s_read(dm_read),
		.s_readdata(dm_readdata), .s_readdatavalid(dm_readdatavalid),
		.s_writedata(dm_writedata), .s_byteenable(dm_byteenable), .s_write(dm_write),
		.s_waitrequest(dm_waitrequest), .dbg(dbg_d));
	a2065_ddram_arbiter mirror_arb (.clk(sysclk), .rst(~reset_n),
		.m0_address(dm_address), .m0_burstcount(dm_burstcount), .m0_read(dm_read),
		.m0_readdata(dm_readdata), .m0_readdatavalid(dm_readdatavalid),
		.m0_writedata(dm_writedata), .m0_byteenable(dm_byteenable), .m0_write(dm_write),
		.m0_waitrequest(dm_waitrequest),
		.m1_address(29'd0), .m1_burstcount(8'd1), .m1_read(1'b0), .m1_readdata(),
		.m1_readdatavalid(), .m1_writedata(64'd0), .m1_byteenable(8'hFF),
		.m1_write(1'b0), .m1_waitrequest(),
		.s_address(mf_address), .s_burstcount(mf_burstcount), .s_read(mf_read),
		.s_readdata(mf_readdata), .s_readdatavalid(mf_readdatavalid),
		.s_writedata(mf_writedata), .s_byteenable(mf_byteenable), .s_write(mf_write),
		.s_waitrequest(mf_waitrequest), .dbg(dbg_m));
	a2065_ddram_arbiter fmv_arb (.clk(sysclk), .rst(~reset_n),
		.m0_address(mf_address), .m0_burstcount(mf_burstcount), .m0_read(mf_read),
		.m0_readdata(mf_readdata), .m0_readdatavalid(mf_readdatavalid),
		.m0_writedata(mf_writedata), .m0_byteenable(mf_byteenable), .m0_write(mf_write),
		.m0_waitrequest(mf_waitrequest),
		.m1_address(29'd0), .m1_burstcount(8'd1), .m1_read(1'b0), .m1_readdata(),
		.m1_readdatavalid(), .m1_writedata(64'd0), .m1_byteenable(8'd0),
		.m1_write(1'b0), .m1_waitrequest(),
		.s_address(mem2_address), .s_burstcount(mem2_burstcount), .s_read(mem2_read),
		.s_readdata(mem2_readdata), .s_readdatavalid(mem2_readdatavalid),
		.s_writedata(mem2_writedata), .s_byteenable(mem2_byteenable), .s_write(mem2_write),
		.s_waitrequest(mem2_waitrequest), .dbg(dbg_f));

	// ---- ddram_ctrl, CPU and save state idle
	wire DDRAM_CLK; reg DDRAM_BUSY = 0; wire [7:0] DDRAM_BURSTCNT; wire [28:0] DDRAM_ADDR;
	reg [63:0] DDRAM_DOUT = 0; reg DDRAM_DOUT_READY = 0; wire DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN; wire [7:0] DDRAM_BE;
	wire [15:0] cpuRD, dmaRD; wire ramready, dmaACK; wire [63:0] ss_readdata;
	wire ss_readdatavalid, ss_waitrequest, ss_ram_idle; wire [39:0] rdbg; wire [127:0] hdbg;
	ddram_ctrl ram2 (
		.sysclk(sysclk), .reset_n(reset_n), .cache_rst(~reset_n),
		.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0000), .dcache_sw_en(1'b0),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.mem2_address(mem2_address), .mem2_burstcount(mem2_burstcount), .mem2_read(mem2_read),
		.mem2_readdata(mem2_readdata), .mem2_readdatavalid(mem2_readdatavalid),
		.mem2_writedata(mem2_writedata), .mem2_byteenable(mem2_byteenable),
		.mem2_write(mem2_write), .mem2_waitrequest(mem2_waitrequest),
		.ss_freeze(1'b0), .ss_load_busy(1'b0), .ss_address(29'd0), .ss_writedata(64'd0),
		.ss_byteenable(8'hFF), .ss_write(1'b0), .ss_read(1'b0), .ss_readdata(ss_readdata),
		.ss_readdatavalid(ss_readdatavalid), .ss_waitrequest(ss_waitrequest),
		.ss_ram_idle(ss_ram_idle), .ss_cpu_parked(1'b1),
		.cpuAddr(28'd0), .cpuCS(1'b0), .cpustate(2'b10), .cpuL(1'b0), .cpuU(1'b0),
		.cpuWR(16'd0), .cpuRD(cpuRD), .ramshared(1'b0), .ramready(ramready),
		.cpuLong(1'b0), .cpuLong1(1'b0), .cpuWR_lo(16'd0), .cpuRD_hi(), .ramready_l(),
		.dmaAddr(28'd0), .dmaCS(1'b0), .dmaWE(1'b0), .dmaL(1'b0), .dmaU(1'b0),
		.dmaWR(16'd0), .dmaRD(dmaRD), .dmaACK(dmaACK), .dbg(rdbg), .dbg_hps(hdbg));

	// ---- DDR3 slave: pipelined, variable latency, BUSY random in runs
	parameter integer BUSY_MODE = 1;     // 0 never, 1 random
	reg [63:0] mem [0:65535];
	integer ii; initial for (ii = 0; ii < 65536; ii = ii + 1) mem[ii] = {32'd0, 32'h1};
	reg [28:0] q_addr [0:15]; reg [7:0] q_beats [0:15]; integer q_due [0:15];
	integer q_h = 0, q_t = 0, q_n = 0, cyc = 0, beat = 0, seed = 5;
	integer hps_rd = 0, hps_beats = 0, hps_wr = 0, bc0 = 0;
	always @(posedge sysclk) begin
		DDRAM_DOUT_READY <= 1'b0;
		cyc = cyc + 1;
		DDRAM_BUSY <= BUSY_MODE ? (($random(seed) % 3) == 0) : 1'b0;
		if (!DDRAM_BUSY && DDRAM_WE) begin
			hps_wr = hps_wr + 1;
			for (ii = 0; ii < 8; ii = ii + 1)
				if (DDRAM_BE[ii]) mem[DDRAM_ADDR[15:0]][8*ii +: 8] <= DDRAM_DIN[8*ii +: 8];
		end
		if (!DDRAM_BUSY && DDRAM_RD) begin
			hps_rd = hps_rd + 1;
			if (DDRAM_BURSTCNT == 0) bc0 = bc0 + 1;
			q_addr[q_t] = DDRAM_ADDR; q_beats[q_t] = DDRAM_BURSTCNT;
			q_due[q_t] = cyc + 6 + ($random(seed) & 15);
			q_t = (q_t + 1) % 16; q_n = q_n + 1;
		end
		if (q_n != 0 && cyc >= q_due[q_h]) begin
			DDRAM_DOUT <= mem[(q_addr[q_h] + beat) & 16'hFFFF];
			DDRAM_DOUT_READY <= 1'b1;
			hps_beats = hps_beats + 1;
			if (beat + 1 >= q_beats[q_h]) begin beat = 0; q_h = (q_h + 1) % 16; q_n = q_n - 1; end
			else beat = beat + 1;
		end
	end

	// ---- what the mailbox sees
	integer mb_rd = 0, mb_rv = 0, mb_wr = 0, stuck = 0, stuck_max = 0;
	always @(posedge sysclk) if (rst_n) begin
		if (a_rd & ~a_wait) mb_rd = mb_rd + 1;
		if (a_wr & ~a_wait) mb_wr = mb_wr + 1;
		if (a_rv) mb_rv = mb_rv + 1;
		// any of the four arbiters busy without a beat at the pins, for how long
		stuck = ((rdbg[23] | dbg_f[15] | dbg_m[15] | dbg_d[15]) && !DDRAM_DOUT_READY) ? stuck + 1 : 0;
		if (stuck > stuck_max) stuck_max = stuck;
	end

	integer fails = 0;
	task check(input ok, input [8*72-1:0] what);
		if (!ok) begin fails = fails + 1; $display("FAIL %0s", what); end
	endtask
	integer rd_before;
	task run(input integer cycles, input [8*24-1:0] tag);
		begin
			rd_before = mb_rd;
			repeat (cycles) @(posedge sysclk);
			repeat (200) @(posedge sysclk);
			$display("%0s: 68k board RAM accesses %0d, commands %0d", tag, br_done, cmd_done);
			$display("%0s: mailbox reads %0d, beats back %0d, writes %0d; HPS reads %0d beats %0d writes %0d; burstcount 0 reads %0d; longest busy without a beat %0d",
			         tag, mb_rd, mb_rv, mb_wr, hps_rd, hps_beats, hps_wr, bc0, stuck_max);
			check(mb_rd - rd_before > cycles / 200, "the mailbox keeps polling through the phase");
		end
	endtask

	initial begin
		repeat (20) @(posedge sysclk);
		reset_n = 1;
		repeat (50) @(posedge sysclk);
		rst_n = 1;                       // the mailbox starts: publish, then polls
		run(50000, "polls only");
		h_on = 1;                        // the 68k starts using the card
		run(150000, "with 68k traffic");
		check(br_done > 100 && cmd_done > 30, "the 68k side was served");
		check(mb_rd > 500, "the mailbox keeps polling");
		check(mb_rv == mb_rd || mb_rv == mb_rd - 1, "every mailbox read gets its beat back");
		check(hps_beats >= hps_rd - 1, "the DDR3 model returned a beat for every read it took (one may be in flight)");
		check(bc0 == 0, "no read with burstcount 0 reaches the pins");
		check(stuck_max < 200, "no arbiter is left waiting for a beat");
		// FMV=4 on hardware: core reset and mailbox reset together, then again
		h_on = 0; repeat (2000) @(posedge sysclk);
		reset_n = 0; rst_n = 0;
		repeat (20) @(posedge sysclk);
		reset_n = 1; repeat (50) @(posedge sysclk); rst_n = 1;
		run(20000, "after a core reset");
		check(mb_rv >= mb_rd - 2, "reads after a core reset come back too");
		if (fails == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
		$finish;
	end
endmodule
