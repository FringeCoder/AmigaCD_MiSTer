// tb_fmv_chain.sv -- the FMV front end behind the real DDR3 path: fmv_arb
// (a2065_ddram_arbiter, as in AmigaCD.sv) into ddram_ctrl's mem2 port, its
// q2 skid, its own arbiter and ddr_cmd_pipe, to a DDR3 slave model.
//
// tb_fmv.sv drives fmv straight from a DDR3 model, so the path in between is
// not tested there. On hardware (gate 1 rerun, 2026-11-02) Main had queued
// 260 updates and the core never wrote UQ_RDPTR. This bench asks the same
// question of the whole path in simulation: does fmv take the queue?
`timescale 1ns/1ps

module tb_fmv_chain;
	reg sysclk = 0, clk_sys = 0;
	always #4.39 sysclk = ~sysclk;      // clk_114
	always #17.6 clk_sys = ~clk_sys;    // the 68k bus clock

	reg reset_n = 0;
	reg fmv_on = 0;

	// ---- ddram_ctrl and its DDR3 pins
	wire        DDRAM_CLK;
	reg         DDRAM_BUSY = 0;
	wire  [7:0] DDRAM_BURSTCNT;
	wire [28:0] DDRAM_ADDR;
	reg  [63:0] DDRAM_DOUT = 0;
	reg         DDRAM_DOUT_READY = 0;
	wire        DDRAM_RD, DDRAM_WE;
	wire [63:0] DDRAM_DIN;
	wire  [7:0] DDRAM_BE;

	wire [28:0] mem2_address;
	wire  [7:0] mem2_burstcount, mem2_byteenable;
	wire        mem2_read, mem2_write, mem2_readdatavalid, mem2_waitrequest;
	wire [63:0] mem2_readdata, mem2_writedata;

	wire [15:0] cpuRD, dmaRD;
	wire        ramready, dmaACK;
	wire [63:0] ss_readdata;
	wire        ss_readdatavalid, ss_waitrequest, ss_ram_idle;

	ddram_ctrl ram2 (
		.sysclk(sysclk), .reset_n(reset_n), .cache_rst(~reset_n),
		.cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0000), .dcache_sw_en(1'b0),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),
		.mem2_address(mem2_address), .mem2_burstcount(mem2_burstcount),
		.mem2_read(mem2_read), .mem2_readdata(mem2_readdata),
		.mem2_readdatavalid(mem2_readdatavalid), .mem2_writedata(mem2_writedata),
		.mem2_byteenable(mem2_byteenable), .mem2_write(mem2_write),
		.mem2_waitrequest(mem2_waitrequest),
		.ss_freeze(1'b0), .ss_load_busy(1'b0), .ss_address(29'd0),
		.ss_writedata(64'd0), .ss_byteenable(8'hFF), .ss_write(1'b0),
		.ss_read(1'b0), .ss_readdata(ss_readdata),
		.ss_readdatavalid(ss_readdatavalid),
		.ss_waitrequest(ss_waitrequest), .ss_ram_idle(ss_ram_idle),
		.ss_cpu_parked(1'b1),
		.cpuAddr(28'd0), .cpuCS(1'b0), .cpustate(2'b10),
		.cpuL(1'b0), .cpuU(1'b0), .cpuWR(16'd0), .cpuRD(cpuRD),
		.ramshared(1'b0), .ramready(ramready),
		.cpuLong(1'b0), .cpuLong1(1'b0), .cpuWR_lo(16'd0), .cpuRD_hi(),
		.ramready_l(),
		.dmaAddr(28'd0), .dmaCS(1'b0), .dmaWE(1'b0),
		.dmaL(1'b0), .dmaU(1'b0), .dmaWR(16'd0), .dmaRD(dmaRD),
		.dmaACK(dmaACK), .dbg(ram2_dbg), .dbg_hps(hps_dbg)
	);

	// ---- fmv_arb, m0 (the mirror/A2065/drive sounds side) idle
	wire [28:0] f_address;
	wire  [7:0] f_burstcount, f_byteenable;
	wire        f_read, f_write, f_readdatavalid, f_waitrequest;
	wire [63:0] f_readdata, f_writedata;

	wire [31:0] arb_dbg;
	wire [39:0] ram2_dbg;
	wire [127:0] hps_dbg;
	integer     hps_cmds_seen = 0, hps_beats_seen = 0;
	reg  [28:0] hps_last_seen = 0;
	always @(posedge sysclk) begin
		if ((DDRAM_RD | DDRAM_WE) & ~DDRAM_BUSY) begin
			hps_cmds_seen = hps_cmds_seen + 1; hps_last_seen = DDRAM_ADDR;
		end
		if (DDRAM_DOUT_READY) hps_beats_seen = hps_beats_seen + 1;
	end
	reg         q2_seen = 0, busy_seen = 0;
	always @(posedge sysclk) begin
		if (ram2_dbg[7]) q2_seen <= 1;        // q2_v
		if (arb_dbg[15]) busy_seen <= 1;      // fmv_arb busy
	end
	a2065_ddram_arbiter fmv_arb (
		.clk(sysclk), .rst(~reset_n),
		.m0_address(29'd0), .m0_burstcount(8'd1), .m0_read(1'b0), .m0_readdata(),
		.m0_readdatavalid(), .m0_writedata(64'd0), .m0_byteenable(8'd0),
		.m0_write(1'b0), .m0_waitrequest(),
		.m1_address(f_address), .m1_burstcount(f_burstcount), .m1_read(f_read),
		.m1_readdata(f_readdata), .m1_readdatavalid(f_readdatavalid),
		.m1_writedata(f_writedata), .m1_byteenable(f_byteenable),
		.m1_write(f_write), .m1_waitrequest(f_waitrequest),
		.s_address(mem2_address), .s_burstcount(mem2_burstcount), .s_read(mem2_read),
		.s_readdata(mem2_readdata), .s_readdatavalid(mem2_readdatavalid),
		.s_writedata(mem2_writedata), .s_byteenable(mem2_byteenable),
		.s_write(mem2_write), .s_waitrequest(mem2_waitrequest),
		.dbg(arb_dbg)
	);

	wire [15:0] cpu_din;
	wire        nrdy, int2, ac_present;
	wire  [3:0] ac_nib;
	fmv dut (
		.clk_sys(clk_sys), .amiga_reset(1'b0), .fmv_on(fmv_on),
		.cpu_addr(23'd0), .cpu_data_in(16'd0), .cpu_data_out(cpu_din),
		.cpu_rw(1'b1), .cpu_as_n(1'b1), .cpu_uds_n(1'b1), .cpu_lds_n(1'b1),
		.sel(1'b0), .nrdy(nrdy), .int2(int2),
		.ac_present(ac_present), .ac_nib_addr(6'd0), .ac_nib(ac_nib),
		.clk_ddr(DDRAM_CLK),
		.mem_address(f_address), .mem_burstcount(f_burstcount), .mem_read(f_read),
		.mem_readdata(f_readdata), .mem_readdatavalid(f_readdatavalid),
		.mem_writedata(f_writedata), .mem_byteenable(f_byteenable),
		.mem_write(f_write), .mem_waitrequest(f_waitrequest)
	,
		.hsync_n(1'b1), .vsync_n(1'b1)
	);

	// ---- DDR3 slave: the 2 MB window, pipelined bursts, fixed latency
	localparam [28:0] BASE = 29'h04E00000;
	reg [63:0] mem [0:262143];
	integer ii;
	initial for (ii = 0; ii < 262144; ii = ii + 1) mem[ii] = 64'd0;
	reg [28:0] q_addr [0:15]; reg [7:0] q_beats [0:15]; integer q_due [0:15];
	integer q_h = 0, q_t = 0, q_n = 0, cyc = 0, beat = 0;
	integer out_of_window = 0;
	integer busy_seed = 11, busy_max = 0, busy_run = 0;
	always @(posedge sysclk) begin
		// The HPS port's waitrequest: high one cycle in three, in runs
		DDRAM_BUSY <= (($random(busy_seed) % 3) == 0);
		busy_run = DDRAM_BUSY ? busy_run + 1 : 0;
		if (busy_run > busy_max) busy_max = busy_run;
	end
	always @(posedge sysclk) begin
		DDRAM_DOUT_READY <= 1'b0;
		cyc = cyc + 1;
		if (!DDRAM_BUSY && (DDRAM_WE || DDRAM_RD) &&
		    (DDRAM_ADDR < BASE || DDRAM_ADDR >= BASE + 29'd262144))
			out_of_window = out_of_window + 1;
		if (!DDRAM_BUSY && DDRAM_WE)
			for (ii = 0; ii < 8; ii = ii + 1)
				if (DDRAM_BE[ii]) mem[(DDRAM_ADDR - BASE) & 18'h3FFFF][8*ii +: 8] <= DDRAM_DIN[8*ii +: 8];
		if (!DDRAM_BUSY && DDRAM_RD) begin
			q_addr[q_t] = DDRAM_ADDR; q_beats[q_t] = DDRAM_BURSTCNT; q_due[q_t] = cyc + 8;
			q_t = (q_t + 1) % 16; q_n = q_n + 1;
		end
		if (q_n != 0 && cyc >= q_due[q_h]) begin
			DDRAM_DOUT <= mem[(q_addr[q_h] + beat - BASE) & 18'h3FFFF];
			DDRAM_DOUT_READY <= 1'b1;
			if (beat + 1 >= q_beats[q_h]) begin beat = 0; q_h = (q_h + 1) % 16; q_n = q_n - 1; end
			else beat = beat + 1;
		end
	end

	// ---- Main
	localparam integer UQ_RDPTR = 21'h100008, UQ_WPTR = 21'h100040, UQ = 21'h101000;
	integer fails = 0, uq_wr = 0, t;
	task check(input ok, input [8*72-1:0] what);
		if (!ok) begin fails = fails + 1; $display("FAIL %0s", what); end
	endtask
	task upd(input [7:0] index, input [15:0] value, input [15:0] mask);
		reg [20:0] o;
		begin
			o = UQ + 16 * (uq_wr & 1023);
			mem[(o >> 3) + 1] = {32'd0, mask, value};
			mem[o >> 3] = {uq_wr[15:0], 38'd0, 1'b0, 1'b0, index};
			uq_wr = uq_wr + 1;
			mem[UQ_WPTR >> 3] = uq_wr;
		end
	endtask

	initial begin
		repeat (20) @(posedge sysclk);
		reset_n = 1;
		repeat (200) @(posedge sysclk);
		for (t = 0; t < 259; t = t + 1) upd(8'h00 + (t & 8'h7F), t, 16'hFFFF);
		upd(8'hC0, 1, 1);
		fmv_on = 1;
		t = 0;
		while (mem[UQ_RDPTR >> 3][31:0] != uq_wr && t < 400000) begin @(posedge sysclk); t = t + 1; end
		$display("UQ_RDPTR %0d of %0d after %0d clocks; DDRAM reads seen %0d",
		         mem[UQ_RDPTR >> 3][31:0], uq_wr, t, q_t);
		check(mem[UQ_RDPTR >> 3][31:0] == uq_wr, "chain: fmv takes the whole queue through ddram_ctrl");
		repeat (20) @(posedge clk_sys);
		check(ac_present, "chain: ALIVE lands");
		check(out_of_window == 0, "chain: every access stays in the window");
		// The diag window Main reads over SPI (fmv.v's layout)
		check(dut.diag[15:0] == 16'hF402, "diag: version word");
		check(dut.diag[16] && dut.diag[17] && dut.diag[27], "diag: status[64], ALIVE and the synchronised on");
		check(dut.diag[31:28] == 4'd0, "diag: fmv_ddr back in S_IDLE");
		check(dut.diag[47:32] != 0, "diag: UQ_WPTR polls counted");
		check(dut.diag[63:48] >= 16'd520, "diag: every queue beat counted");
		check(dut.diag[95:80] == uq_wr[15:0], "diag: uq_rd");
		check(dut.diag[107:96] == uq_wr[11:0], "diag: UQ_WPTR as last read, 12 bits");
		check(dut.diag[111:109] == 3'b000, "diag: no interrupt line up yet");
		// Raise the CL450 INT (HOST_control Int = 0) through the queue
		upd(8'h48, 16'h0000, 16'h0080);
		t = 0;
		while (mem[UQ_RDPTR >> 3][31:0] != uq_wr && t < 400000) begin @(posedge sysclk); t = t + 1; end
		repeat (40) @(posedge clk_sys);
		check(dut.int2 && dut.bus.cl_int && !dut.bus.l64_int, "the CL450 INT is up, the L64111 latch is not");
		check(dut.diag[111:109] == 3'b101, "diag: INT2 and the CL450 INT, not the L64111 latch");
		// The arbiters' debug words (AmigaCD.sv's fmv_diag_x)
		check(arb_dbg[15] == 0 && arb_dbg[11] == 0, "arb dbg: fmv_arb idle, no m1 request");
		check(arb_dbg[23:16] != 0 && arb_dbg[31:24] == 0, "arb dbg: m1 grants counted, m0 none");
		check(ram2_dbg[7] == 0 && q2_seen, "arb dbg: q2 held a request, and is empty now");
		check(busy_seen, "arb dbg: fmv_arb busy seen during the reads");
		check(ram2_dbg[31:24] != 0, "arb dbg: ddram_ctrl's arbiter granted q2");
		// The HPS port counters (ddram_ctrl dbg_hps), against the pins
		check(hps_dbg[15:0] == hps_cmds_seen[15:0] && hps_cmds_seen > 0, "hps dbg: commands accepted");
		check(hps_dbg[31:16] == hps_beats_seen[15:0], "hps dbg: read beats returned");
		check({hps_dbg[44:32], hps_dbg[63:48]} == hps_last_seen, "hps dbg: last accepted address");
		check(hps_dbg[111:96] <= busy_max && busy_max > 0, "hps dbg: BUSY run bounded by the longest seen");
		if (fails == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
		$finish;
	end
endmodule
