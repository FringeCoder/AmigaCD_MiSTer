// cpu_rdgate: the CPU takes a RAM read only when the data under it has been
// stable for two clk_114 periods, and sees zero data otherwise. That is what
// lets AmigaCD.sdc time cpu_dat_r / cpu_dat_hi into the TG68K as a two-clock
// path. The claim rests on a property of the caches -- read data changes only
// on the edge ack rises, and ack falls with the select -- so this runs the
// REAL controllers (sdram_ctrl and ddram_ctrl, with their cpu_cache_new) under
// AmigaCD.sv's handshake, not a model of them:
//
//   A. at every clk_114 edge where g (ack & ack delayed one clk_114) is high,
//      the muxed raw read data, low and high word, equals what it was one
//      clk_114 earlier -- so whatever the TG68K can see was launched at least
//      two clk_114 edges back. This is the multicycle.
//   B. wherever g is low (TG68K running), the data the CPU sees is zero.
//   C. the word the CPU takes is the word that was there when ack rose.
//   D. the ready the CPU sees, read or write, is ack one clk_114 late inside
//      an unbroken select (cs & cs_q): registered terms only (row 30).
//   E. with fx68k running (en low) every output is its input, on every clock.
//   F. no ready without an ack inside the current select -- the previous
//      request's ack never completes the next one.
//
// Plus A on two standalone caches (LINE_TAKE 0 and 1) driven with random
// inputs on every clock, protocol or not, for corners the system never
// reaches. It also counts the reads the gate costs a clk_sys (ack rose on the
// clk_114 edge before a clk_sys edge), which is the performance price.
// Every counter fails the run at zero.
//
// Harness: the system half of rtl/sim/rdq (cpu_rdq, row 20, reverted), on the
// current controllers.
`timescale 1ns/1ps
module tb_cpu_rdgate;

parameter integer CYCLES = 150000;   // clk_sys cycles

reg clk_114 = 0, clk_sys = 0;
always #4 clk_114 = ~clk_114;
initial begin
	#4;
	forever begin clk_sys = 1; #16; clk_sys = 0; #16; end
end

reg reset_n = 0;

// ---- CPU side, clk_sys ------------------------------------------------------
reg  [28:1] ram_addr = 0;
reg         ram_sel  = 0;
reg   [1:0] cpu_state = 1;
reg         ram_uds = 1, ram_lds = 1;
reg  [15:0] ram_din = 0, ram_din_lo = 0;
reg         ram_l1 = 0, fastchip_lw = 0, ramshared = 0;
// mode: 0 fx68k (en 0, 68000 handshake), 1 68010 on TG68K (en 1, 68000
// handshake), 2 68020/030 (en 1, cpu_type)
reg   [1:0] mode = 2;
wire        cpu_type = (mode == 2);
wire        en       = (mode != 0);
wire        zram_sel = |ram_addr[28:26];

// ---- AmigaCD.sv glue, clk_114 -----------------------------------------------
reg        cyc = 0;
reg        ram_cs = 0;
reg  [1:0] phase = 0;
always @(posedge clk_114) phase <= phase + 1'd1;
wire [15:0] ram_dout1, ram_dout2, ram_dout2_hi;
wire        ram_ready1, ram_ready2, ram_ready2_l;
wire [15:0] raw_dout    = zram_sel ? ram_dout2 : ram_dout1;
wire        raw_ready   = zram_sel ? ram_ready2 : ram_ready1;
wire        raw_ready_l = zram_sel & ram_ready2_l;

wire [15:0] cpu_dout, cpu_dout_hi;
wire        cpu_ready, cpu_ready_l;
cpu_rdgate dut (
	.clk(clk_114), .en(en), .cs(ram_cs),
	.ready_in(raw_ready), .ready_l_in(raw_ready_l), .dout_in(raw_dout), .dout_hi_in(ram_dout2_hi),
	.ready(cpu_ready), .ready_l(cpu_ready_l), .dout(cpu_dout), .dout_hi(cpu_dout_hi));

always @(posedge clk_114) begin
	cyc <= (phase == 3);
	// AmigaCD.sv: the select drops on the ready the CPU sees
	ram_cs <= ~(cpu_ready & cyc & cpu_type) & ram_sel;
end

// ---- memories ------------------------------------------------------------------
reg  [3:0] cache_ctrl = 4'b0011;
reg        cache_rst = 1;
reg        c_7m = 0;
reg  [3:0] c7div = 0;
always @(posedge clk_114) begin
	c7div <= c7div + 1'd1;
	if (c7div == 7) c_7m <= ~c_7m;
end

reg  [24:1] chipAddr = 0;
reg         chipL = 1, chipU = 1, chipRW = 1, chipDMA = 1, chip_dma_slot = 0;
reg  [15:0] chipWR = 0;

reg  [15:0] sd_rnd = 0;
wire [15:0] sd_data;
assign (weak0, weak1) sd_data = sd_rnd;
wire [12:0] sd_addr; wire [1:0] sd_ba, sd_dqm; wire sd_cs, sd_we, sd_ras, sd_cas, sd_clk, sd_cke;
wire [15:0] chipRD, chipRD_dma, chipRD2; wire [47:0] chip48; wire sdram_ready;

sdram_ctrl ram1 (
	.sysclk(clk_114), .c_7m(c_7m), .reset_n(reset_n), .cache_rst(cache_rst), `ifdef FAST_HIT .fast_hit(en), `endif .cache_inhibit(1'b0),
	.cpu_cache_ctrl(cache_ctrl), .dcache_sw_en(1'b1),
	.sd_addr(sd_addr), .sd_ba(sd_ba), .sd_cs(sd_cs), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
	.sd_dqm(sd_dqm), .sd_data(sd_data), .sd_clk(sd_clk), .sd_cke(sd_cke),
	.chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipRW(chipRW), .chipDMA(chipDMA),
	.chip_dma_slot(chip_dma_slot), .chipWR(chipWR), .chipRD(chipRD), .chipRD_dma(chipRD_dma),
	.chip48(chip48), .sdram_ready(sdram_ready), .chip32(1'b0), .chipWR2(16'd0), .chipRD2(chipRD2),
	.cpuAddr({2'b00, ram_addr[22:1]}), .cpuCS(~zram_sel & ram_cs), .cpustate(cpu_state),
	.cpuL(ram_lds), .cpuU(ram_uds), .cpuWR(ram_din),
	.cpuRD(ram_dout1), .ramready(ram_ready1));

reg         DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0;
reg  [63:0] DDRAM_DOUT = 0;
wire        DDRAM_CLK, DDRAM_RD, DDRAM_WE;
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN;
reg  [28:0] rd_addr = 0;
reg   [7:0] rd_left = 0;
integer     rd_lat = 0;
reg  [28:0] q_addr [0:15];
reg   [7:0] q_cnt  [0:15];
reg   [3:0] q_h = 0, q_t = 0;
reg         dmaCS = 0, dmaWE = 0;
reg  [28:1] dmaAddr = 0;
reg  [15:0] dmaWR = 0;
wire [15:0] dmaRD; wire dmaACK;
wire [63:0] mem2_readdata, ss_readdata; wire mem2_readdatavalid, mem2_waitrequest;
wire ss_readdatavalid, ss_waitrequest, ss_ram_idle;

ddram_ctrl ram2 (
	.sysclk(clk_114), .reset_n(reset_n), .cache_rst(cache_rst), `ifdef FAST_HIT .fast_hit(en), `endif .cache_inhibit(1'b0),
	.cpu_cache_ctrl(cache_ctrl), .dcache_sw_en(1'b1),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.mem2_address(29'd0), .mem2_burstcount(8'd0), .mem2_read(1'b0), .mem2_readdata(mem2_readdata),
	.mem2_readdatavalid(mem2_readdatavalid), .mem2_writedata(64'd0), .mem2_byteenable(8'd0),
	.mem2_write(1'b0), .mem2_waitrequest(mem2_waitrequest),
	.ss_freeze(1'b0), .ss_load_busy(1'b0), .ss_address(29'd0), .ss_writedata(64'd0),
	.ss_byteenable(8'd0), .ss_write(1'b0), .ss_read(1'b0), .ss_readdata(ss_readdata),
	.ss_readdatavalid(ss_readdatavalid), .ss_waitrequest(ss_waitrequest), .ss_ram_idle(ss_ram_idle),
	.ss_cpu_parked(1'b0),
	.cpuAddr(ram_addr), .cpuCS(zram_sel & ram_cs), .cpustate(cpu_state), .cpuL(ram_lds), .cpuU(ram_uds),
	.cpuWR(ram_din), .cpuRD(ram_dout2), .ramshared(ramshared), .cpuLong(fastchip_lw & ~ram_addr[1]),
	.ramready(ram_ready2), .cpuLong1(ram_l1 & zram_sel), .cpuWR_lo(ram_din_lo), .cpuRD_hi(ram_dout2_hi),
	.ramready_l(ram_ready2_l),
	.dmaAddr(dmaAddr), .dmaCS(dmaCS), .dmaWE(dmaWE), .dmaL(1'b0), .dmaU(1'b0), .dmaWR(dmaWR),
	.dmaRD(dmaRD), .dmaACK(dmaACK));

function [15:0] word;
	input [31:0] a;
	reg   [31:0] h;
	begin
		h = a * 32'h9E3779B1;
		word = h[31:16] ^ h[15:0];
	end
endfunction

always @(posedge clk_114) begin
	sd_rnd     <= $urandom;
	DDRAM_BUSY <= ($urandom % 4 == 0);
	DDRAM_DOUT_READY <= 0;
	DDRAM_DOUT <= {$urandom, $urandom};
	// accepted read commands queue up; the head one is answered after its
	// latency, a beat at a time with gaps
	if (DDRAM_RD & ~DDRAM_BUSY) begin
		q_addr[q_t] = DDRAM_ADDR;
		q_cnt[q_t]  = DDRAM_BURSTCNT;
		q_t = q_t + 1;
	end
	if (rd_left == 0) begin
		if (q_h != q_t) begin
			rd_addr <= q_addr[q_h];
			rd_left <= q_cnt[q_h];
			rd_lat  <= 2 + $urandom % 10;
			q_h = q_h + 1;
		end
	end
	else if (rd_lat != 0) rd_lat <= rd_lat - 1;
	else if ($urandom % 3 != 0) begin
		DDRAM_DOUT_READY <= 1;
		DDRAM_DOUT <= {word({rd_addr, 2'd3}), word({rd_addr, 2'd2}), word({rd_addr, 2'd1}), word({rd_addr, 2'd0})};
		rd_addr <= rd_addr + 1'd1;
		rd_left <= rd_left - 1'd1;
	end
	// chip writes into SDRAM now and then, at addresses the CPU uses
	chipRW   <= ($urandom % 40 != 0);
	chipAddr <= {13'd0, 4'($urandom), 7'($urandom)};
	chipWR   <= $urandom;
	{chipU, chipL} <= $urandom;
	chip_dma_slot <= ($urandom % 2);
	// active low, and a chip slot always wins: kept rare so the CPU gets slots
	chipDMA  <= ($urandom % 20 != 0);
	// bridge DMA into DDR3, for its snoop
	if (!dmaCS) begin
		if ($urandom % 400 == 0) begin
			dmaCS <= 1; dmaWE <= ($urandom % 2);
			dmaAddr <= {3'b010, 14'd0, 4'($urandom), 7'($urandom)};
			dmaWR <= $urandom;
		end
	end
	else if (dmaACK) dmaCS <= 0;
end

// ---- the CPU ----------------------------------------------------------------
// Address pools: 16 lines x 8 words in each memory, two tags apart so the two
// ways and their replacement both get used.
function [28:1] pick_addr;
	input integer mem;
	reg [28:1] a;
	begin
		a = 0;
		a[6:1]  = $urandom;
		a[8:7]  = $urandom;
		a[12:11]= $urandom;   // tag bits
		case (mem)
			0: a[28:26] = 3'b000;                         // SDRAM, chip/slow
			1: begin a[28:26] = 3'b010; end               // DDR3
			2: begin a[28:26] = 3'b001; a[25:24] = 2'b11; end  // DDR3, Z3 region
			default: begin a[28:26] = 3'b001; a[25:24] = 2'b00; end  // DDR3 forwarded to SDRAM
		endcase
		pick_addr = a;
	end
endfunction

integer cyc_n = 0;

task new_access;
	begin
		ram_addr  <= pick_addr($urandom % 4);
		case ($urandom % 8)
			0, 1:    cpu_state <= 2'd0;   // fetch
			2, 3, 4: cpu_state <= 2'd2;   // read
			default: cpu_state <= 2'd3;   // write
		endcase
		// the second word of a long write, usually, after the first
		if (cpu_state == 2'd3 && fastchip_lw && !ram_addr[1] && $urandom % 4 != 0) begin
			ram_addr  <= {ram_addr[28:2], 1'b1};
			cpu_state <= 2'd3;
		end
		// active low; a write always strobes at least one byte
		{ram_uds, ram_lds} <= ($urandom % 4 == 0) ? 2'($urandom % 3) : 2'b00;
		ram_din     <= $urandom;
		ram_din_lo  <= $urandom;
		ram_l1      <= ($urandom % 2);
		fastchip_lw <= ($urandom % 2);
		ramshared   <= ($urandom % 50 == 0);
		ram_sel     <= 1;
	end
endtask

// As in rtl/sim/rdq: not while ddram_ctrl is still taking a forwarded SDRAM
// read, an upstream hazard outside this change.
wire fwd_busy = (ram2.state == 6) || (ram2.state == 7);

integer rd_takes = 0, l_takes = 0, wr_takes = 0, delayed = 0, mode_moves = 0;
reg     raw_seen = 0;   // raw ready was already up at the previous clk_sys edge

always @(posedge clk_sys) if (reset_n) begin
	cyc_n <= cyc_n + 1;
	if (!ram_sel) begin
		if ($urandom % 3 != 0 && !fwd_busy) new_access;
		else if ($urandom % 600 == 0) begin
			mode <= $urandom % 3;
			mode_moves <= mode_moves + 1;
		end
		raw_seen <= 0;
	end
	else if (cpu_ready) begin
		if (cpu_state == 2'd3) wr_takes <= wr_takes + 1;
		else begin
			rd_takes <= rd_takes + 1;
			if (cpu_ready_l) l_takes <= l_takes + 1;
			if (en && raw_seen) delayed <= delayed + 1;
		end
		raw_seen <= 0;
		if (cpu_type && $urandom % 2 && !fwd_busy) new_access;
		else ram_sel <= 0;
	end
	else raw_seen <= raw_ready;
end

// ---- standalone caches on random inputs -----------------------------------------
reg        c_rst = 1, c_cs = 0, c_we = 0, c_ir = 0, c_dr = 0, c_inh = 0, c_sw = 1, c_snoop = 0;
reg        c_rack = 0, c_bufok = 0, c_long = 0, c_fast = 1;
reg  [3:0] c_ctrl = 4'b0011;
reg [28:1] c_adr = 0, c_sadr = 0;
reg  [1:0] c_bs = 0, c_sbs = 0;
reg [15:0] c_dw = 0, c_sdr = 0, c_sdw = 0, c_dwlo = 0;
reg [63:0] c_buf = 0;
wire [15:0] c0_r, c0_hi, c1_r, c1_hi;
wire c0_ack, c0_wb, c0_idle, c0_req, c0_take, c0_ackl;
wire c1_ack, c1_wb, c1_idle, c1_req, c1_take, c1_ackl;

cpu_cache_new #(.LINE_TAKE(0)) cache0 (
	.clk(clk_114), .rst(c_rst), .cpu_cache_ctrl(c_ctrl), .dcache_sw_en(c_sw), `ifdef FAST_HIT .fast_hit(c_fast), `endif .cache_inhibit(c_inh),
	.cpu_cs(c_cs), .cpu_adr(c_adr), .cpu_bs(c_bs), .cpu_we(c_we), .cpu_ir(c_ir), .cpu_dr(c_dr),
	.cpu_dat_w(c_dw), .cpu_dat_r(c0_r), .cpu_ack(c0_ack), .wb_en(c0_wb), .cpu_idle(c0_idle),
	.sdr_dat_r(c_sdr), .sdr_read_req(c0_req), .sdr_read_ack(c_rack),
	.snoop_act(c_snoop), .snoop_adr(c_sadr), .snoop_dat_w(c_sdw), .snoop_bs(c_sbs),
	.buf_ok(c_bufok), .buf_dat(c_buf), .buf_take(c0_take),
	.cpu_long(c_long), .cpu_dat_w_lo(c_dwlo), .cpu_dat_hi(c0_hi), .cpu_ack_l(c0_ackl));

cpu_cache_new #(.LINE_TAKE(1)) cache1 (
	.clk(clk_114), .rst(c_rst), .cpu_cache_ctrl(c_ctrl), .dcache_sw_en(c_sw), `ifdef FAST_HIT .fast_hit(c_fast), `endif .cache_inhibit(c_inh),
	.cpu_cs(c_cs), .cpu_adr(c_adr), .cpu_bs(c_bs), .cpu_we(c_we), .cpu_ir(c_ir), .cpu_dr(c_dr),
	.cpu_dat_w(c_dw), .cpu_dat_r(c1_r), .cpu_ack(c1_ack), .wb_en(c1_wb), .cpu_idle(c1_idle),
	.sdr_dat_r(c_sdr), .sdr_read_req(c1_req), .sdr_read_ack(c_rack),
	.snoop_act(c_snoop), .snoop_adr(c_sadr), .snoop_dat_w(c_sdw), .snoop_bs(c_sbs),
	.buf_ok(c_bufok), .buf_dat(c_buf), .buf_take(c1_take),
	.cpu_long(c_long), .cpu_dat_w_lo(c_dwlo), .cpu_dat_hi(c1_hi), .cpu_ack_l(c1_ackl));

always @(posedge clk_114) begin
	if ($urandom % 30000 == 0) c_rst <= 1;
	else if ($urandom % 20 == 0) c_rst <= 0;
	c_cs    <= ($urandom % 4 != 0) ? c_cs : ~c_cs;
	c_we    <= ($urandom % 3 == 0);
	c_ir    <= ($urandom % 3 == 0);
	c_dr    <= ($urandom % 2);
	c_adr   <= {16'd0, 2'($urandom), 2'd0, 8'($urandom)};
	c_bs    <= $urandom;
	c_dw    <= $urandom;
	c_dwlo  <= $urandom;
	c_sdr   <= $urandom;
	c_rack  <= ($urandom % 3 == 0);
	c_snoop <= ($urandom % 10 == 0);
	c_sadr  <= {16'd0, 2'($urandom), 2'd0, 8'($urandom)};
	c_sdw   <= $urandom;
	c_sbs   <= $urandom;
	c_bufok <= ($urandom % 4 == 0);
	c_buf   <= {$urandom, $urandom};
	c_long  <= ($urandom % 2);
	c_fast  <= ($urandom % 8 != 0);
	c_inh   <= ($urandom % 30 == 0);
	c_sw    <= ($urandom % 30 != 0);
	if ($urandom % 2000 == 0) c_ctrl <= $urandom;
	else if ($urandom % 200 == 0) c_ctrl <= 4'b0011;
end

// ---- checks ----------------------------------------------------------------------
// Sampled at each clk_114 edge, so every value is the one held over the clock
// just ending; *_p are the clock before that.
integer fa = 0, fb = 0, fc = 0, fd = 0, fe = 0, ff = 0, fs = 0;
integer n_g = 0, n_gl = 0, n_off = 0, n_en0 = 0, n_rise = 0, n_s = 0, n_ws = 0;
reg [15:0] raw_p = 0, hi_p = 0, word_at_ack = 0;
reg        rr_p = 0, rq_p = 0, cs_p = 0, acked = 0;
wire       acked_n = acked;
wire       cs_p_n  = cs_p;
reg [15:0] c0_p = 0, c0h_p = 0, c1_p = 0, c1h_p = 0;
reg        c0a_p = 0, c1a_p = 0;
wire       g_now = dut.v;

task fail(inout integer n, input [8*48-1:0] what);
	begin
		if (n < 5) $display("FAIL %0s t=%0t zsel=%b state=%0d", what, $time, zram_sel, cpu_state);
		n = n + 1;
	end
endtask

always @(posedge clk_114) if (reset_n && cyc_n > 4) begin
	if (en) begin
		if (g_now) begin
			n_g = n_g + 1;
			if (raw_dout !== raw_p || ram_dout2_hi !== hi_p) fail(fa, "A: data moved under g");
			if (raw_ready_l) n_gl = n_gl + 1;
		end
		else begin
			n_off = n_off + 1;
			if (cpu_dout !== 16'd0 || cpu_dout_hi !== 16'd0) fail(fb, "B: data visible without g");
		end
		// D: the ready the CPU sees, read or write, is ack one clk_114 late
		// inside an unbroken select -- the registered v and nothing else.
		if (raw_ready && !rr_p && cpu_state != 2'd3 && ram_sel) begin n_rise = n_rise + 1; word_at_ack = raw_dout; end
		if (cpu_ready !== (rr_p && ram_cs && cs_p)) fail(fd, "D: ready is not ack_q & cs & cs_q");
		// F: never a ready the request did not earn. acked is set by an ack
		// seen inside this select and cleared whenever the select drops, so a
		// ready without it is the tail of the previous request's ack.
		if (cpu_ready && !acked) fail(ff, "F: ready without an ack in this select");
		// and v implies the ack is still up: the data under it is the ack's.
		if (g_now && !raw_ready) fail(fa, "A: v up with the ack down");
		if (cpu_state == 2'd3 && raw_ready) n_ws = n_ws + 1;
	end
	else begin
		n_en0 = n_en0 + 1;
		if ({cpu_dout, cpu_dout_hi, cpu_ready, cpu_ready_l} !== {raw_dout, ram_dout2_hi, raw_ready, raw_ready_l})
			fail(fe, "E: fx68k path not transparent");
	end
	// C: at a clk_sys edge the CPU takes a read on, it gets the word from ack
	if (phase == 0 && en && ram_sel && cpu_ready && cpu_state != 2'd3) begin
		n_s = n_s + 1;
		if (cpu_dout !== word_at_ack) fail(fc, "C: taken word is not the ack word");
	end
	// A on the standalone caches
	if (c0_ack && c0a_p && (c0_r !== c0_p || c0_hi !== c0h_p)) fail(fs, "A: cache0 data moved under ack");
	if (c1_ack && c1a_p && (c1_r !== c1_p || c1_hi !== c1h_p)) fail(fs, "A: cache1 data moved under ack");
	raw_p = raw_dout; hi_p = ram_dout2_hi; rr_p = raw_ready;
	acked = ram_cs && (acked_n || (raw_ready && cs_p_n));
	cs_p = ram_cs;
	c0_p = c0_r; c0h_p = c0_hi; c0a_p = c0_ack;
	c1_p = c1_r; c1h_p = c1_hi; c1a_p = c1_ack;
end


// ---- G: a fast hit's word is the word READ would have loaded ---------------------
// On the clock after a fast hit the cache is in WAIT, the RAMs hold what they
// registered on the fast hit's edge (the CPU's address: WAIT writes nothing),
// and rd_dat is exactly what READ would have loaded in the old timing. Skipped
// when a snoop wrote either port's RAM on that edge, the race READ has too.
integer fg = 0, n_fast = 0, n_fast_l = 0, n_gskip = 0;
`define G_CHECK(FH, C, NAME) \
	reg FH = 0; \
	reg [28:1] FH``_a = 0; \
	always @(posedge clk_114) begin \
		if (FH && C.cpu_sm_state == C.CPU_SM_WAIT) begin \
			if (C.sdr_sm_iram0_we | C.sdr_sm_iram1_we | C.sdr_sm_dram0_we | C.sdr_sm_dram1_we | C.sdr_sm_itag_we | C.sdr_sm_dtag_we || \
			    C.cpu_adr !== FH``_a) \
				n_gskip = n_gskip + 1; \
			else begin \
				n_fast = n_fast + 1; \
				if (C.cpu_ack_l) n_fast_l = n_fast_l + 1; \
				if (C.cpu_dat_r !== C.rd_dat || (C.cpu_ack_l && C.cpu_dat_hi !== C.rd_dat_hi) || !C.rd_hit) \
					fail(fg, {"G: fast hit word differs, ", NAME}); \
			end \
		end \
		FH = (C.cpu_sm_state == C.CPU_SM_IDLE) && C.cpu_cs && !C.cpu_we && C.fast_ok && !C.rst; \
		FH``_a = C.cpu_adr; \
	end
`ifdef FAST_HIT
`G_CHECK(fh_r1, ram1.cpu_cache, "ram1")
`G_CHECK(fh_r2, ram2.cpu_cache, "ram2")
`G_CHECK(fh_c0, cache0, "cache0")
`G_CHECK(fh_c1, cache1, "cache1")
`endif

integer i;
initial begin
	repeat (8) @(posedge clk_sys);
	reset_n = 1;
	for (i = 0; i < CYCLES; i = i + 1) begin
		@(posedge clk_sys);
		if ($urandom % 100000 == 0) begin
			cache_rst = 0; repeat (2) @(posedge clk_sys); cache_rst = 1;
		end
		if ($urandom % 50000 == 0) cache_ctrl = $urandom;
		else if ($urandom % 5000 == 0) cache_ctrl = 4'b0011;
	end
	repeat (4) @(posedge clk_sys);
	$display("reads taken %0d (long %0d, a clk_sys later than before %0d), writes %0d; g clocks %0d (long %0d), gated-off %0d, fx68k clocks %0d, ack rises %0d, takes checked %0d, write acks %0d, mode moves %0d",
		rd_takes, l_takes, delayed, wr_takes, n_g, n_gl, n_off, n_en0, n_rise, n_s, n_ws, mode_moves);
	$display("fast hits checked %0d (long %0d, skipped for a same-edge snoop or a moved address %0d)", n_fast, n_fast_l, n_gskip);
	$display("failures: A %0d B %0d C %0d D %0d E %0d F %0d G %0d standalone-A %0d", fa, fb, fc, fd, fe, ff, fg, fs);
	if (rd_takes == 0 || l_takes == 0 || delayed == 0 || wr_takes == 0 || n_g == 0 || n_gl == 0 ||
	    n_off == 0 || n_en0 == 0 || n_rise == 0 || n_s == 0 || n_ws == 0 || mode_moves == 0
`ifdef FAST_HIT
	    || n_fast == 0 || n_fast_l == 0
`endif
	    )
		$display("RUN: FAIL (a counter is zero)");
	else if (fa + fb + fc + fd + fe + ff + fg + fs == 0) $display("RUN: PASS");
	else $display("RUN: FAIL");
	$finish;
end
endmodule
