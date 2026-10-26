`timescale 1ns/1ps

// proxy68k driving the real minimig.v (MEASUREMENT ONLY, ARM-CPU plan step 4).
//
// On the MiSTer every proxy write to INTENA or DMACON set all of the
// register's bits, while clear writes were exact. tb_proxy_custom.sv, with
// only the bus bridge, Gary's data mux, Agnus's CPU register address and
// Paula's interrupt controller, writes them correctly -- so the cause is in
// the part of the chipset it leaves out. This runs the proxy against the
// whole minimig (rtl/sim/ssmux's pin file and file list), on the core's
// clocks: amiga_clk on clk_sys and AmigaCD.sv's phase enables from clk_114.
// It plays the MiSTer's failing sequence, checks INTENA and DMACON after each
// write, and logs every clock on which the register bus names INTENA.

module tb_proxy_minimig;

// ---- clocks: clk_114 at four times clk_sys, in phase -------------------------
reg clk_114 = 0;
always #4.405 clk_114 = ~clk_114;
reg clk_r = 0;
reg [1:0] q = 0;
always @(posedge clk_114) begin q <= q + 1'd1; if (q == 2'd1) clk_r <= 1; if (q == 2'd3) clk_r <= 0; end

reg rst_n = 1'b0;

amiga_clk amiga_clock
(
	.clk_28(clk_r), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3), .cck(cck),
	.eclk(eclk), .eclk_n(eclk_n), .ce(1'b1), .reset_n(rst_n)
);

assign clk = clk_r;
assign ss_replay_we   = 1'b0;
assign ss_replay_addr = 8'd0;
assign ss_replay_data = 16'd0;
assign ss_replay_tick = 1'b0;

`include "minimig_pins.vh"

// AmigaCD.sv's phase enables, as written there
reg cpu_ph1 = 0, cpu_ph2 = 0;
reg [3:0] div = 0;
reg       c1d = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	c1d <= c1;
	if (~c1d & c1) div <= 3;
	if (~rst_n) begin
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
	end
	else if (div[1] & ~div[0]) begin
		cpu_ph1 <= 0;
		cpu_ph2 <= 0;
		case (div[3:2])
			0: cpu_ph2 <= 1;
			2: cpu_ph1 <= 1;
		endcase
	end
end

// ---- the proxy, on minimig's CPU pins ------------------------------------------
reg         req_tgl = 0, req_rw = 1, req_uds_n = 1, req_lds_n = 1;
reg  [23:1] req_addr = 0;
reg  [15:0] req_wdata = 0;
reg         px_on = 0;
wire        ack_tgl;
wire [15:0] px_rdata;
wire        px_as, px_rw, px_uds, px_lds;
wire [23:1] px_addr;
wire [15:0] px_dout;

proxy68k proxy (
	.clk(clk_r), .reset_n(rst_n), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.own(px_on), .fast_en(1'b0), .fast_cand(1'b0), .fastw_en(1'b0), .fastw_cand(1'b0),
	.req_tgl(req_tgl), .req_rw(req_rw), .req_addr(req_addr),
	.req_uds_n(req_uds_n), .req_lds_n(req_lds_n), .req_wdata(req_wdata),
	.ack_tgl(ack_tgl), .rdata(px_rdata),
	.as_n(px_as), .rw(px_rw), .uds_n(px_uds), .lds_n(px_lds), .addr(px_addr), .dout(px_dout),
	.dtack_n(_cpu_dtack), .din(cpu_data)
);

always @* begin
	drv__cpu_as     = px_as;
	drv__cpu_uds    = px_uds;
	drv__cpu_lds    = px_lds;
	drv_cpu_r_w     = px_rw;
	drv_cpu_address = px_addr;
	drv_cpudata_in  = px_dout;
end

// ---- what the register bus does --------------------------------------------------
reg log_bus = 0;
always @(posedge clk_r) if (log_bus && clk7_en && dut.reg_address == 8'h4D)
	$display("  %0t: reg bus names INTENA, data %04x (rd %b hwr %b lwr %b dbr %b, as %b rw %b) -> intena %04x",
	         $time, dut.custom_data_in, dut.cpu_rd, dut.cpu_hwr, dut.cpu_lwr, dut.dbr, px_as, px_rw,
	         dut.PAULA1.pi1.intena);

// ---- driving the proxy ------------------------------------------------------------
integer errors = 0;
task automatic cycle(input rd_n, input [23:0] a, input [15:0] d);
	integer t;
	begin
		req_rw = rd_n; req_addr = a[23:1]; req_wdata = d; req_uds_n = 0; req_lds_n = 0;
		@(posedge clk_114);
		req_tgl = ~req_tgl;
		t = 0;
		while (ack_tgl != req_tgl) begin
			@(posedge clk_r); t = t + 1;
			if (t > 200000) begin $display("FAIL: no ack for %06x", a); errors = errors + 1; disable cycle; end
		end
		repeat ($urandom % 8) @(posedge clk_r);
	end
endtask

task automatic w16(input [23:0] a, input [15:0] v); cycle(1'b0, a, v); endtask

task automatic check(input [8*20-1:0] what, input [15:0] got, input [15:0] want);
	begin
		if (got !== want) begin $display("FAIL %0s: %04x, want %04x", what, got, want); errors = errors + 1; end
		else $display("ok   %0s = %04x", what, got);
	end
endtask

initial begin
	pins_reset_inputs();
	drv__cpu_reset_in = 1'b1;
	drv_rst_ext       = 1'b1;
	dut.USERIO1.usrrst = 1'b0;
	dut.USERIO1.cpurst = 1'b0;
	dut.USERIO1.cpuhlt = 1'b0;

	repeat (40) @(posedge clk_r);
	rst_n = 1'b1;
	repeat (40) @(posedge clk_r);
	drv_rst_ext = 1'b0;
	repeat (20) @(posedge clk_r);
	dut.CONTROL1.rst_cnt = 3'b100;          // as rtl/sim/ssmux: skip four frames of reset
	while (dut.sys_reset) @(posedge clk_r);
	repeat (20) @(posedge clk_r);
	px_on = 1;
	repeat (20) @(posedge clk_r);
	log_bus = 1;

	// the MiSTer's sequence
	w16(24'hDFF09A, 16'h7FFF); repeat (20) @(posedge clk_r); check("INTENA <- 7fff", {1'b0, dut.PAULA1.pi1.intena}, 16'h0000);
	w16(24'hDFF09A, 16'h8001); repeat (20) @(posedge clk_r); check("INTENA <- 8001", {1'b0, dut.PAULA1.pi1.intena}, 16'h0001);
	cycle(1'b1, 24'hDFF01C, 0); check("INTENAR read", px_rdata, 16'h0001);
	w16(24'hDFF09A, 16'h0001); repeat (20) @(posedge clk_r); check("INTENA <- 0001", {1'b0, dut.PAULA1.pi1.intena}, 16'h0000);
	w16(24'hDFF09A, 16'hC020); repeat (20) @(posedge clk_r); check("INTENA <- c020", {1'b0, dut.PAULA1.pi1.intena}, 16'h4020);
	w16(24'hDFF096, 16'h7FFF); repeat (20) @(posedge clk_r); check("DMACON <- 7fff", {3'b000, dut.AGNUS1.dmacon}, 16'h0000);
	w16(24'hDFF096, 16'h8001); repeat (20) @(posedge clk_r); check("DMACON <- 8001", {3'b000, dut.AGNUS1.dmacon}, 16'h0001);
	log_bus = 0;

	$display("%0d errors", errors);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

initial begin
	#20_000_000;
	$display("RUN: FAIL (timeout) sys_reset=%b", dut.sys_reset);
	$finish;
end

endmodule
