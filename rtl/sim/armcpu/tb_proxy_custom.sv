/*
 * tb_proxy_custom.sv -- proxy68k writing a set/clear custom register through
 * the real chipset bus logic (MEASUREMENT ONLY, ARM-CPU plan step 4).
 *
 * Written for a symptom on the MiSTer: proxy writes to INTENA or DMACON set
 * all of the register's bits (INTENA <- $8001 read back $7FFF) while clear
 * writes were exact. It turned out not to be the proxy -- the test wrote with
 * Python ctypes, which reads before it writes, and armuae's Amiberry core
 * wrote words a byte at a time -- and this bench is what cleared the proxy. Paula's INTENA has no write strobe -- it takes
 * the custom data bus on every 7 MHz clock the register address bus names it
 * -- and Gary drives that data bus with $FFFF whenever the CPU reads. So a
 * single clock of "read" with $DFF09A on the address is a write of $FFFF.
 *
 * This puts the real pieces of that path together, on the core's clocks:
 * amiga_clk on clk_sys, cpu_ph1/cpu_ph2 from AmigaCD.sv's divider on
 * clk_114, proxy68k, minimig_m68k_bridge, Gary's custom data bus mux and
 * Agnus's CPU register address as they are written in gary.v and agnus.v, and
 * paula_intcontroller. It plays the MiSTer's failing sequence and checks
 * INTENA after each write; and it records every clock on which the register
 * address bus names INTENA, with what the data bus held.
 */
`timescale 1ns/1ps

module tb_proxy_custom;

// ---- clocks: clk_114 at four times clk_sys, in phase -------------------------
reg clk_114 = 0;
always #4.4 clk_114 = ~clk_114;
reg clk_sys = 0;
reg [1:0] q = 0;
always @(posedge clk_114) begin q <= q + 1'd1; if (q == 2'd1) clk_sys <= 1; if (q == 2'd3) clk_sys <= 0; end

reg reset_n = 0;

wire       clk7_en, clk7n_en, c1, c3, cck;
wire [9:0] eclk, eclk_n;
amiga_clk aclk (
	.clk_28(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3), .cck(cck),
	.eclk(eclk), .eclk_n(eclk_n), .ce(1'b1), .reset_n(reset_n)
);

// AmigaCD.sv's phase enables, as written there
reg cpu_ph1 = 0, cpu_ph2 = 0;
reg [3:0] div = 0;
reg       c1d = 0;
always @(posedge clk_114) begin
	div <= div + 1'd1;
	c1d <= c1;
	if (~c1d & c1) div <= 3;
	if (~reset_n) begin
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

// ---- the proxy -----------------------------------------------------------------
reg         req_tgl = 0, req_rw = 1, req_uds_n = 1, req_lds_n = 1;
reg  [23:1] req_addr = 0;
reg  [15:0] req_wdata = 0;
wire        ack_tgl;
wire [15:0] rdata;
wire        as_n, rw, uds_n, lds_n;
wire [23:1] addr;
wire [15:0] dout;
wire        chip_dtack;
wire [15:0] chip_rdata;

proxy68k proxy (
	.clk(clk_sys), .reset_n(reset_n), .ph1(cpu_ph1), .ph2(cpu_ph2),
	.own(1'b1), .fast_en(1'b0), .fast_cand(1'b0), .fastw_en(1'b0), .fastw_cand(1'b0),
	.req_tgl(req_tgl), .req_rw(req_rw), .req_addr(req_addr),
	.req_uds_n(req_uds_n), .req_lds_n(req_lds_n), .req_wdata(req_wdata),
	.ack_tgl(ack_tgl), .rdata(rdata),
	.as_n(as_n), .rw(rw), .uds_n(uds_n), .lds_n(lds_n), .addr(addr), .dout(dout),
	.dtack_n(chip_dtack), .din(chip_rdata)
);

// ---- the chipset's CPU side --------------------------------------------------------
wire        cpu_rd, cpu_hwr, cpu_lwr, rd_cyc, long_en, bls, host_ack;
wire [23:1] cpu_address_out;
wire [15:0] cpu_data, cpu_data_out, host_rdat;
wire [15:0] cpu_data_in;          // the custom chips' read data, to the CPU
// gary.v: registers at $DFxxxx (and the $C0-$D7 range without slow RAM)
wire        sel_reg = cpu_address_out[23:16] == 8'hDF;
wire        dbs     = cpu_address_out[23:16] == 8'hDF;

minimig_m68k_bridge bridge (
	.clk(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3), .eclk(eclk),
	.vpa(1'b0), .dbr(1'b0), .dbs(dbs), .xbs(1'b1), .nrdy(1'b0), .bls(bls), .blit_nasty(1'b0), .cck(cck),
	.memory_config(4'd0), ._as(as_n), ._lds(lds_n), ._uds(uds_n), .r_w(rw),
	.cpu_long(1'b0), .long_en(long_en), ._dtack(chip_dtack),
	.rd(cpu_rd), .hwr(cpu_hwr), .lwr(cpu_lwr), .address(addr), .address_out(cpu_address_out),
	.data(cpu_data), .cpudatain(dout), .data_out(cpu_data_out), .data_in(cpu_data_in),
	.rd_cyc(rd_cyc), ._cpu_reset(1'b1), .cpu_halt(1'b0),
	.host_cs(1'b0), .host_adr(23'd0), .host_we(1'b0), .host_bs(2'b00), .host_wdat(16'd0),
	.host_rdat(host_rdat), .host_ack(host_ack)
);
assign chip_rdata = cpu_data;

// gary.v: custom_data_in = dbr ? ram_data_out : cpu_rd ? 16'hFFFF : cpu_data_out
wire [15:0] custom_data_in = cpu_rd ? 16'hFFFF : cpu_data_out;
// agnus.v: with the bus not allocated by Agnus, the CPU's register address
wire  [8:1] reg_address = (sel_reg & (cpu_rd | cpu_hwr | cpu_lwr)) ? cpu_address_out[8:1] : 8'hFF;

wire [15:0] paula_data_out;
wire  [2:0] ipl_n;
wire [14:0] ss_intreq, ss_intena;
wire  [3:0] audpen;
wire        rbfmirror;
paula_intcontroller pint (
	.clk(clk_sys), .clk7_en(clk7_en), .reset(~reset_n),
	.reg_address_in(reg_address), .data_in(custom_data_in), .data_out(paula_data_out),
	.rxint(1'b0), .txint(1'b0), .vblint(1'b0), .int2(1'b0), .int3(1'b0), .int6(1'b0),
	.blckint(1'b0), .syncint(1'b0), .audint(4'd0), .audpen(audpen), .rbfmirror(rbfmirror),
	._ipl(ipl_n), .ss_intreq(ss_intreq), .ss_intena(ss_intena)
);
assign cpu_data_in = paula_data_out;

// ---- what the register bus does --------------------------------------------------
integer n_intena_clocks = 0;
always @(posedge clk_sys) if (clk7_en && reg_address == 8'h4D) begin   // $09A >> 1
	n_intena_clocks = n_intena_clocks + 1;
	$display("  %0t: reg bus names INTENA, data %04x (rd %b hwr %b lwr %b, as %b rw %b uds %b lds %b) -> intena %04x",
	         $time, custom_data_in, cpu_rd, cpu_hwr, cpu_lwr, as_n, rw, uds_n, lds_n, ss_intena);
end

// ---- a clock-by-clock trace while tracing is on --------------------------------------
reg tracing = 0;
always @(posedge clk_sys) if (tracing)
	$display("  %8.1f ph1 %b ph2 %b c7 %b cck %b | st %0d as %b rw %b uds %b dout %04x | dtack %b l_as %b l_dt %b lr_w %b | rd %b hwr %b reg %02x data %04x",
	         $realtime, cpu_ph1, cpu_ph2, clk7_en, cck, proxy.st, as_n, rw, uds_n, dout,
	         chip_dtack, bridge.l_as, bridge.l_dtack, bridge.lr_w, cpu_rd, cpu_hwr, reg_address, custom_data_in);

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
			@(posedge clk_sys); t = t + 1;
			if (t > 100000) begin $display("FAIL: no ack"); errors = errors + 1; disable cycle; end
		end
		repeat ($urandom % 8) @(posedge clk_sys);
	end
endtask

task automatic intena_w(input [15:0] v, input [14:0] expect_);
	begin
		$display("INTENA <- %04x", v);
		cycle(1'b0, 24'hDFF09A, v);
		repeat (8) @(posedge clk_sys);
		if (ss_intena !== expect_) begin
			$display("FAIL: INTENA %04x, want %04x", ss_intena, expect_);
			errors = errors + 1;
		end
	end
endtask

initial begin
	repeat (40) @(posedge clk_sys);
	reset_n = 1;
	repeat (40) @(posedge clk_sys);
	// the MiSTer's sequence
	intena_w(16'h7FFF, 15'h0000);
	tracing = 1;
	intena_w(16'h8001, 15'h0001);
	tracing = 0;
	cycle(1'b1, 24'hDFF01C, 0);
	intena_w(16'h0001, 15'h0000);
	intena_w(16'h8002, 15'h0002);
	intena_w(16'h8004, 15'h0006);
	intena_w(16'h0006, 15'h0000);
	intena_w(16'hC020, 15'h4020);
	cycle(1'b1, 24'hDFF01C, 0);
	$display("%0d clocks named INTENA, %0d errors", n_intena_clocks, errors);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

initial begin #5_000_000; $display("RUN: FAIL (timeout)"); $finish; end

endmodule
