// The CPU's read return now comes out of cpu_rdq: the ram1/ram2 mux, registered
// at clk_114 from each port's next-state outputs, in place of the live mux of
// the ports' registers. Two claims, checked separately:
//
//   1. cpu_cache_new, sdram_ctrl and ddram_ctrl behave exactly as before. Their
//      CPU return registers (cpu_dat_r, cpu_ack, cpu_ack_l; write_ena, w_l1)
//      now load from a next-state block instead of being assigned inside the
//      state machine. Each runs beside a frozen copy of the previous version
//      (*_ref.v, wrapped by gen_pairs.py) on the same inputs, and every output
//      must match on every clk_114 clock.
//
//   2. On every clk_sys edge, cpu_rdq's outputs equal the mux they replace.
//      That rests on zram_sel moving only on clk_sys edges, so the bench drives
//      the CPU side from clk_sys and the memories from clk_114, with the two
//      clocks phase-locked 1:4 as the PLL makes them. A clk_114 edge between
//      clk_sys edges is allowed to differ, and the bench counts how often it
//      does: zero there would mean the select never moved while a port held a
//      different word, and claim 2 would not have been exercised.
//
// The system around them is AmigaCD.sv's: ram_cs registered at clk_114 from
// the live ram_ready, cyc one clk_114 clock in four, ddram's SDRAM forwarding
// port wired to sdram_ctrl's fast port. The CPU takes a word when ram_ready is
// high at a clk_sys edge and then drops its select, or goes straight on to the
// next access. Addresses come from a small pool in each memory, so lines are
// filled, hit, written through and filled again. A DDR3 slave answers bursts
// after a random latency with waitrequest at random; the SDRAM pins return
// random data.
//
// Two standalone cache pairs (LINE_TAKE 0 and 1) take random inputs on every
// clock, protocol or not, for the corners the system above never reaches.
//
// Every path into a return register is counted, and a zero count fails the
// run, so a run that never reached one cannot pass.
`timescale 1ns/1ps
module tb_cpu_rdq_equiv;

parameter integer CYCLES = 100000;   // clk_sys cycles

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
reg         cpu_type = 1;
wire        zram_sel = |ram_addr[28:26];

// ---- AmigaCD.sv glue, clk_114 -----------------------------------------------
reg        cyc = 0;
reg        ram_cs = 0;
// Read on a clk_114 edge, the clk_114 edges since the last clk_sys edge:
// 0 on an edge both clocks share. The first clk_114 edge is a clk_sys edge.
reg  [1:0] phase = 0;
always @(posedge clk_114) phase <= phase + 1'd1;
wire [15:0] ram_dout1, ram_dout2, ram_dout2_hi, ram_dout1_n, ram_dout2_n;
wire        ram_ready1, ram_ready2, ram_ready2_l, ram_ready1_n, ram_ready2_n, ram_ready2_l_n;
wire        ram_ready = zram_sel ? ram_ready2 : ram_ready1;
always @(posedge clk_114) begin
	// AmigaCD.sv derives cyc from amiga_clk's c1 so that it is high on the
	// clk_114 edge that is also a clk_sys edge: ram_cs drops on the edge the
	// CPU takes the word, not before
	cyc <= (phase == 3);
	ram_cs <= ~(ram_ready & cyc & cpu_type) & ram_sel;
end

// the wiring this replaces
wire [15:0] old_dout    = zram_sel ? ram_dout2 : ram_dout1;
wire        old_ready   = ram_ready;
wire        old_ready_l = zram_sel & ram_ready2_l;

wire [15:0] cpu_ram_dout;
wire        cpu_ram_ready, cpu_ram_ready_l;
cpu_rdq dut (
	.clk(clk_114), .zram_sel(zram_sel),
	.ram1_dout_n(ram_dout1_n), .ram1_ready_n(ram_ready1_n),
	.ram2_dout_n(ram_dout2_n), .ram2_ready_n(ram_ready2_n), .ram2_ready_l_n(ram_ready2_l_n),
	.dout(cpu_ram_dout), .ready(cpu_ram_ready), .ready_l(cpu_ram_ready_l));

// ---- memories ------------------------------------------------------------------
reg  [3:0] cache_ctrl = 4'b0011;
reg        cache_rst = 1;
reg        c_7m = 0;
reg  [3:0] c7div = 0;
always @(posedge clk_114) begin
	c7div <= c7div + 1'd1;
	if (c7div == 7) c_7m <= ~c_7m;
end

// chip bus: a chip write now and then, for the snoop paths
reg  [24:1] chipAddr = 0;
reg         chipL = 1, chipU = 1, chipRW = 1, chipDMA = 1, chip_dma_slot = 0;
reg  [15:0] chipWR = 0;

// SDRAM pins: random read data whenever the controller is not driving
reg  [15:0] sd_rnd = 0;
wire [15:0] sd_data;
assign (weak0, weak1) sd_data = sd_rnd;
wire [12:0] sd_addr; wire [1:0] sd_ba, sd_dqm; wire sd_cs, sd_we, sd_ras, sd_cas, sd_clk, sd_cke;
wire [15:0] chipRD, chipRD_dma, chipRD2; wire [47:0] chip48; wire sdram_ready;

wire        sdr_req, sdr_we, sdr_w2, sdr_ack, sdr_rvalid;
wire [26:1] sdr_addr; wire [1:0] sdr_dqm, sdr_dqm2; wire [15:0] sdr_wdat, sdr_wdat2, sdr_rdat;
wire        mism_sdr, mism_ddr;

sdram_ctrl_pair ram1 (
	.sysclk(clk_114), .c_7m(c_7m), .reset_n(reset_n), .cache_rst(cache_rst), .cache_inhibit(1'b0),
	.cpu_cache_ctrl(cache_ctrl), .dcache_sw_en(1'b1), .sdram_big(1'b1),
	.sd_addr(sd_addr), .sd_ba(sd_ba), .sd_cs(sd_cs), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
	.sd_dqm(sd_dqm), .sd_data(sd_data), .sd_clk(sd_clk), .sd_cke(sd_cke),
	.chipAddr(chipAddr), .chipL(chipL), .chipU(chipU), .chipRW(chipRW), .chipDMA(chipDMA),
	.chip_dma_slot(chip_dma_slot), .chipWR(chipWR), .chipRD(chipRD), .chipRD_dma(chipRD_dma),
	.chip48(chip48), .sdram_ready(sdram_ready), .chip32(1'b0), .chipWR2(16'd0), .chipRD2(chipRD2),
	.cpuAddr({2'b00, ram_addr[22:1]}), .cpuCS(~zram_sel & ram_cs), .cpustate(cpu_state),
	.cpuL(ram_lds), .cpuU(ram_uds), .cpuWR(ram_din),
	.cpuRD(ram_dout1), .ramready(ram_ready1), .cpuRD_n(ram_dout1_n), .ramready_n(ram_ready1_n),
	.fast_req(sdr_req), .fast_we(sdr_we), .fast_addr(sdr_addr), .fast_dqm(sdr_dqm), .fast_wdat(sdr_wdat),
	.fast_w2(sdr_w2), .fast_dqm2(sdr_dqm2), .fast_wdat2(sdr_wdat2),
	.fast_ack(sdr_ack), .fast_rvalid(sdr_rvalid), .fast_rdat(sdr_rdat),
	.mism(mism_sdr));

// DDR3 slave
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

ddram_ctrl_pair ram2 (
	.sysclk(clk_114), .reset_n(reset_n), .cache_rst(cache_rst), .cache_inhibit(1'b0),
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
	.ramready_l(ram_ready2_l), .cpuRD_n(ram_dout2_n), .ramready_n(ram_ready2_n), .ramready_l_n(ram_ready2_l_n),
	.dmaAddr(dmaAddr), .dmaCS(dmaCS), .dmaWE(dmaWE), .dmaL(1'b0), .dmaU(1'b0), .dmaWR(dmaWR),
	.dmaRD(dmaRD), .dmaACK(dmaACK),
	.sdr_hi(1'b1), .sdr_req(sdr_req), .sdr_we(sdr_we), .sdr_addr(sdr_addr), .sdr_dqm(sdr_dqm),
	.sdr_wdat(sdr_wdat), .sdr_w2(sdr_w2), .sdr_dqm2(sdr_dqm2), .sdr_wdat2(sdr_wdat2),
	.sdr_ack(sdr_ack), .sdr_rvalid(sdr_rvalid), .sdr_rdat(sdr_rdat),
	.mism(mism_ddr));

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

integer cyc_n = 0, words = 0, zsel_moves = 0;

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

// Not while ddram_ctrl is still taking a forwarded SDRAM read (states 6 and
// 7). That is a hazard in upstream's code, outside this change: a read the
// cache bypasses (inhibited, or D-cache off) finishes at the first word, the
// second half of the forwarded burst arrives some 16 clocks later, and a cache
// miss started in between takes those words as its own fill and then waits for
// the rest of it for good. The bench is here to compare the two versions, not
// to hang on that, so the CPU waits it out.
wire fwd_busy = (ram2.r.state == 6) || (ram2.r.state == 7);

always @(posedge clk_sys) if (reset_n) begin
	cyc_n <= cyc_n + 1;
	if (!ram_sel) begin
		if ($urandom % 3 != 0 && !fwd_busy) new_access;
	end
	else if (old_ready) begin
		words <= words + 1;
		// back to back only on the 68020/030 handshake, where ram_cs drops for
		// the edge the word is taken; the 68000 ends its cycle with AS
		if (cpu_type && $urandom % 2 && !fwd_busy) new_access;
		else ram_sel <= 0;
	end
	if ($urandom % 20000 == 0) cpu_type <= ~cpu_type;
end

always @(posedge clk_sys) begin : zmove
	reg zq;
	zq = zram_sel;
	#1 if (zram_sel !== zq) zsel_moves = zsel_moves + 1;
end

// ---- standalone caches on random inputs -----------------------------------------
wire mism_c0, mism_c1;
reg        c_rst = 1, c_cs = 0, c_we = 0, c_ir = 0, c_dr = 0, c_inh = 0, c_sw = 1, c_snoop = 0;
reg        c_rack = 0, c_bufok = 0, c_long = 0;
reg  [3:0] c_ctrl = 4'b0011;
reg [28:1] c_adr = 0, c_sadr = 0;
reg  [1:0] c_bs = 0, c_sbs = 0;
reg [15:0] c_dw = 0, c_sdr = 0, c_sdw = 0, c_dwlo = 0;
reg [63:0] c_buf = 0;
wire [15:0] c0_r, c0_hi, c0_rn, c1_r, c1_hi, c1_rn;
wire c0_ack, c0_wb, c0_idle, c0_req, c0_take, c0_ackl, c0_ackn, c0_ackln;
wire c1_ack, c1_wb, c1_idle, c1_req, c1_take, c1_ackl, c1_ackn, c1_ackln;

cpu_cache_new_pair #(.LINE_TAKE(0)) cache0 (
	.clk(clk_114), .rst(c_rst), .cpu_cache_ctrl(c_ctrl), .dcache_sw_en(c_sw), .cache_inhibit(c_inh),
	.cpu_cs(c_cs), .cpu_adr(c_adr), .cpu_bs(c_bs), .cpu_we(c_we), .cpu_ir(c_ir), .cpu_dr(c_dr),
	.cpu_dat_w(c_dw), .cpu_dat_r(c0_r), .cpu_ack(c0_ack), .wb_en(c0_wb), .cpu_idle(c0_idle),
	.sdr_dat_r(c_sdr), .sdr_read_req(c0_req), .sdr_read_ack(c_rack),
	.snoop_act(c_snoop), .snoop_adr(c_sadr), .snoop_dat_w(c_sdw), .snoop_bs(c_sbs),
	.buf_ok(c_bufok), .buf_dat(c_buf), .buf_take(c0_take),
	.cpu_long(c_long), .cpu_dat_w_lo(c_dwlo), .cpu_dat_hi(c0_hi), .cpu_ack_l(c0_ackl),
	.cpu_dat_r_n(c0_rn), .cpu_ack_n(c0_ackn), .cpu_ack_l_n(c0_ackln), .mism(mism_c0));

cpu_cache_new_pair #(.LINE_TAKE(1)) cache1 (
	.clk(clk_114), .rst(c_rst), .cpu_cache_ctrl(c_ctrl), .dcache_sw_en(c_sw), .cache_inhibit(c_inh),
	.cpu_cs(c_cs), .cpu_adr(c_adr), .cpu_bs(c_bs), .cpu_we(c_we), .cpu_ir(c_ir), .cpu_dr(c_dr),
	.cpu_dat_w(c_dw), .cpu_dat_r(c1_r), .cpu_ack(c1_ack), .wb_en(c1_wb), .cpu_idle(c1_idle),
	.sdr_dat_r(c_sdr), .sdr_read_req(c1_req), .sdr_read_ack(c_rack),
	.snoop_act(c_snoop), .snoop_adr(c_sadr), .snoop_dat_w(c_sdw), .snoop_bs(c_sbs),
	.buf_ok(c_bufok), .buf_dat(c_buf), .buf_take(c1_take),
	.cpu_long(c_long), .cpu_dat_w_lo(c_dwlo), .cpu_dat_hi(c1_hi), .cpu_ack_l(c1_ackl),
	.cpu_dat_r_n(c1_rn), .cpu_ack_n(c1_ackn), .cpu_ack_l_n(c1_ackln), .mism(mism_c1));

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
	c_inh   <= ($urandom % 30 == 0);
	c_sw    <= ($urandom % 30 != 0);
	if ($urandom % 2000 == 0) c_ctrl <= $urandom;
	else if ($urandom % 200 == 0) c_ctrl <= 4'b0011;
end

// ---- checks -------------------------------------------------------------------
integer edges = 0, mism_rdq = 0, mism_mod = 0, between = 0, between_diff = 0;
integer rd_takes = 0, l_takes = 0;
// paths into the return registers, counted on the frozen copies
integer c_ihit = 0, c_dhit = 0, c_line = 0, c_fill = 0, w_lo = 0, w_l1 = 0, w_hi = 0, w_plain = 0, s_we = 0;

always @(posedge clk_114) if (reset_n && cyc_n > 4) begin
	if (mism_sdr | mism_ddr | mism_c0 | mism_c1) begin
		if (mism_mod < 10)
			$display("MODULE MISMATCH t=%0t: sdram %b ddram %b cache0 %b cache1 %b", $time, mism_sdr, mism_ddr, mism_c0, mism_c1);
		mism_mod = mism_mod + 1;
	end
	if (phase == 0) begin
		// a clk_sys edge (both clocks rise here): what the CPU takes now
		edges = edges + 1;
		if ({cpu_ram_dout, cpu_ram_ready, cpu_ram_ready_l} !== {old_dout, old_ready, old_ready_l}) begin
			if (mism_rdq < 10)
				$display("RDQ MISMATCH t=%0t: dout %h/%h ready %b/%b ready_l %b/%b zsel %b",
					$time, cpu_ram_dout, old_dout, cpu_ram_ready, old_ready, cpu_ram_ready_l, old_ready_l, zram_sel);
			mism_rdq = mism_rdq + 1;
		end
		if (old_ready & ram_sel) rd_takes = rd_takes + 1;
		if (old_ready_l & ram_sel) l_takes = l_takes + 1;
	end
	else begin
		between = between + 1;
		if ({cpu_ram_dout, cpu_ram_ready, cpu_ram_ready_l} !== {old_dout, old_ready, old_ready_l})
			between_diff = between_diff + 1;
	end
	// coverage, on the frozen copies' own state
	if (ram2.r.cpu_cache.cpu_sm_state == ram2.r.cpu_cache.CPU_SM_READ && !ram2.r.cpu_cache.rst) begin
		if (ram2.r.cpu_cache.rd_i0 | ram2.r.cpu_cache.rd_i1) c_ihit = c_ihit + 1;
		else if (ram2.r.cpu_cache.rd_d0 | ram2.r.cpu_cache.rd_d1) c_dhit = c_dhit + 1;
		else if (ram2.r.cpu_cache.buf_ok_r) c_line = c_line + 1;
	end
	// the line-take branch: ddram's kept line, or the standalone LINE_TAKE cache
	if (cache1.r.cpu_sm_state == cache1.r.CPU_SM_READ && !cache1.r.rst &&
	    !(cache1.r.rd_i0 | cache1.r.rd_i1 | cache1.r.rd_d0 | cache1.r.rd_d1) && cache1.r.buf_ok_r &&
	    !cache1.r.snoop_act && !cache1.r.cpu_ir && cache1.r.cc_den && !cache1.r.cache_inhibit)
		c_line = c_line + 1;
	if (ram1.r.cpu_cache.cpu_sm_state == ram1.r.cpu_cache.CPU_SM_FILL1 && ram1.r.cpu_cache.sdr_read_ack) c_fill = c_fill + 1;
	if (!ram2.r.write_ena && ram2.r.w_new && !ram2.r.stg_fl && ram2.r.w_room) begin
		if (ram2.r.w_lo) w_lo = w_lo + 1;
		else if (ram2.r.w_l1n) w_l1 = w_l1 + 1;
		else if (ram2.r.w_hi) w_hi = w_hi + 1;
		else if (!ram2.r.stg_v) w_plain = w_plain + 1;
	end
	if (!ram1.r.write_ena && ram1.r.ramsel && ram1.r.cpustate == 3 && ram1.r.cache_wr_ack) s_we = s_we + 1;
end

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
	$display("clk_sys edges %0d (CPU words %0d, long words %0d), clk_114 edges between %0d of which differ %0d, zram_sel moves %0d",
		edges, rd_takes, l_takes, between, between_diff, zsel_moves);
	$display("cache: i-hit %0d d-hit %0d line-take %0d fill %0d; ddram writes: lo %0d l1 %0d hi %0d plain %0d; sdram writes %0d",
		c_ihit, c_dhit, c_line, c_fill, w_lo, w_l1, w_hi, w_plain, s_we);
	$display("mismatches: modules %0d, cpu_rdq at clk_sys edges %0d", mism_mod, mism_rdq);
	if (rd_takes == 0 || l_takes == 0 || between_diff == 0 || c_ihit == 0 || c_dhit == 0 || c_line == 0 ||
	    c_fill == 0 || w_lo == 0 || w_l1 == 0 || w_hi == 0 || w_plain == 0 || s_we == 0)
		$display("FAIL: a counted path was never reached");
	else if (mism_mod == 0 && mism_rdq == 0) $display("RUN: PASS");
	if (mism_mod != 0 || mism_rdq != 0) $display("RUN: FAIL");
	$finish;
end
endmodule
