/*
 * tb_armcpu.sv -- the ARM's 68k bus, end to end (MEASUREMENT ONLY, step 2 of
 * the ARM-CPU plan): sys/lw_echo.sv's AXI3 slave and rtl/armcpu_bridge.v on
 * the HPS's 100 MHz clock, rtl/proxy68k.v on clk_sys, the two asynchronous
 * as in the core (the bench's clocks drift past each other), with a 68000
 * bus slave behind the pins.
 *
 * The bench plays the HPS side with single accesses of every size and with
 * INCR bursts, and checks from both ends:
 *
 *   - the bytes land in the 68k's memory order: the byte at 68k address
 *     {BANK, offset} is the bridge byte at offset, for reads and writes;
 *   - a word access is two 68k word cycles, a halfword one, a byte one with
 *     only its own data strobe (a word read of a CIA would clear both ICRs);
 *   - the pins keep fx68k's timing (busControl in fx68k.sv): every edge on a
 *     phase enable; AS and a read's strobes fall together on enPhi1, a
 *     write's R/W with AS and its strobes one enPhi1 later; AS and the
 *     strobes rise together on enPhi2, and only after DTACK was sampled low
 *     on an enPhi2 and an enPhi1 has passed; R/W rises on the next enPhi1;
 *     address and write data hold while AS is low; a read takes the data on
 *     the edge AS rises;
 *   - a write is answered before its cycle ends (posted), and a read right
 *     after it sees the new value; a read and a write issued together on
 *     the two AXI channels both complete, each with its own data;
 *   - with OWN clear, or the CPU not a 68000, nothing reaches the pins and a
 *     read answers 0xFFFFFFFF at once;
 *   - a cycle with no DTACK ends after its timeout, and a reset in the
 *     middle of a cycle still answers the ARM;
 *   - step 4's flat view: a second AXI master through lw_echo with FLAT and
 *     sys/bus_merge.sv, as sys_top wires the full HPS-to-FPGA bridge. Its
 *     address is the 68k address, whatever BANK says; at 16 MB and above it
 *     is answered at once with all ones and no cycle; both masters at once
 *     each get their own answers; and the two views agree on memory;
 *   - a cycle the proxy never ends (the CPU halted: no enPhi at all) is
 *     given up by the bridge's own watchdog: the read answers all ones,
 *     OWN drops, STATUS[9] is set and later reads answer at once; setting
 *     OWN again clears it and the bus works;
 *   - the control registers: MAGIC, BANK, STATUS (interrupt level, OWN,
 *     68000), LAST, WORDS;
 *   - with FAST, reads of the SDRAM port's addresses (chip RAM here: banks 0
 *     and 1) skip the 68000 phases -- AS and the strobes fall together on
 *     any edge, rise on the edge the port's ready is seen -- and take less
 *     time by LAST; every write, and every read elsewhere, keeps all of the
 *     68000 rules above;
 *   - with FASTW as well, writes to those addresses do the same -- AS, R/W,
 *     the strobes and the data together, held to the ready -- and land in
 *     memory; writes elsewhere keep the 68000 rules.
 */
`timescale 1ns/1ps

module tb_armcpu;

// ---- clk_sys, 28.4 MHz, and the bridge side's clk_100m, unrelated --------
reg clk_sys = 0;
always #17.6 clk_sys = ~clk_sys;
reg clk114 = 0;          // the bus side's clock: 100 MHz, not a multiple
initial begin #3.3; forever #5.003 clk114 = ~clk114; end

// ph1 / ph2: one clk_sys cycle each, 7 MHz, half a 68k clock apart
reg [1:0] phc = 0;
always @(posedge clk_sys) phc <= phc + 2'd1;
reg halt = 0;            // the core's CPU halt: no phase enables at all
wire ph1 = (phc == 2'd0) & ~halt;
wire ph2 = (phc == 2'd2) & ~halt;

reg reset114 = 1, cpu_reset_n = 0;

// ---- AXI side ----------------------------------------------------------------
reg  [11:0] awid = 0;  reg [20:0] awaddr = 0; reg [3:0] awlen = 0; reg [2:0] awsize = 2; reg [1:0] awburst = 1;
reg         awvalid = 0; wire awready;
reg  [31:0] wdata = 0; reg [3:0] wstrb = 0; reg wlast = 0; reg wvalid = 0; wire wready;
wire [11:0] bid; wire [1:0] bresp; wire bvalid; reg bready = 0;
reg  [11:0] arid = 0;  reg [20:0] araddr = 0; reg [3:0] arlen = 0; reg [2:0] arsize = 2; reg [1:0] arburst = 1;
reg         arvalid = 0; wire arready;
wire [11:0] rid; wire [31:0] rdata; wire [1:0] rresp; wire rlast; wire rvalid; reg rready = 0;

// the full bridge's master, flat
reg  [11:0] hf_awid = 0;  reg [29:0] hf_awaddr = 0; reg [3:0] hf_awlen = 0; reg [2:0] hf_awsize = 2; reg [1:0] hf_awburst = 1;
reg         hf_awvalid = 0; wire hf_awready;
reg  [31:0] hf_wdata = 0; reg [3:0] hf_wstrb = 0; reg hf_wlast = 0; reg hf_wvalid = 0; wire hf_wready;
wire [11:0] hf_bid; wire [1:0] hf_bresp; wire hf_bvalid; reg hf_bready = 0;
reg  [11:0] hf_arid = 0;  reg [29:0] hf_araddr = 0; reg [3:0] hf_arlen = 0; reg [2:0] hf_arsize = 2; reg [1:0] hf_arburst = 1;
reg         hf_arvalid = 0; wire hf_arready;
wire [11:0] hf_rid; wire [31:0] hf_rdata; wire [1:0] hf_rresp; wire hf_rlast; wire hf_rvalid; reg hf_rready = 0;

wire        lw_req, lw_we, lw_ack, hf_req, hf_we, hf_ack;
wire [20:0] lw_addr;
wire [29:0] hf_addr;
wire  [1:0] lw_size, hf_size;
wire  [3:0] lw_wstrb, hf_wstrb_b;
wire [31:0] lw_wdata, lw_rdata, hf_wdata_b, hf_rdata_b;

wire        bus_req, bus_we, bus_ack;
wire [24:0] bus_addr;
wire  [1:0] bus_size;
wire  [3:0] bus_wstrb;
wire [31:0] bus_wdata, bus_rdata;

lw_echo lw (
	.clk(clk114), .reset(reset114),
	.awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
	.awvalid(awvalid), .awready(awready),
	.wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
	.bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
	.arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
	.arvalid(arvalid), .arready(arready),
	.rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
	.ext_wr(), .ext_waddr(), .ext_wdata(), .ext_status(128'd0),
	.bus_req(lw_req), .bus_we(lw_we), .bus_addr(lw_addr), .bus_size(lw_size),
	.bus_wstrb(lw_wstrb), .bus_wdata(lw_wdata), .bus_ack(lw_ack), .bus_rdata(lw_rdata)
);

lw_echo #(.AW(30), .FLAT(1)) hf (
	.clk(clk114), .reset(reset114),
	.awid(hf_awid), .awaddr(hf_awaddr), .awlen(hf_awlen), .awsize(hf_awsize), .awburst(hf_awburst),
	.awvalid(hf_awvalid), .awready(hf_awready),
	.wdata(hf_wdata), .wstrb(hf_wstrb), .wlast(hf_wlast), .wvalid(hf_wvalid), .wready(hf_wready),
	.bid(hf_bid), .bresp(hf_bresp), .bvalid(hf_bvalid), .bready(hf_bready),
	.arid(hf_arid), .araddr(hf_araddr), .arlen(hf_arlen), .arsize(hf_arsize), .arburst(hf_arburst),
	.arvalid(hf_arvalid), .arready(hf_arready),
	.rid(hf_rid), .rdata(hf_rdata), .rresp(hf_rresp), .rlast(hf_rlast), .rvalid(hf_rvalid), .rready(hf_rready),
	.ext_wr(), .ext_waddr(), .ext_wdata(), .ext_status(128'd0),
	.bus_req(hf_req), .bus_we(hf_we), .bus_addr(hf_addr), .bus_size(hf_size),
	.bus_wstrb(hf_wstrb_b), .bus_wdata(hf_wdata_b), .bus_ack(hf_ack), .bus_rdata(hf_rdata_b)
);

bus_merge merge (
	.clk(clk114), .reset(reset114),
	.a_req(lw_req), .a_we(lw_we), .a_addr(lw_addr), .a_size(lw_size),
	.a_wstrb(lw_wstrb), .a_wdata(lw_wdata), .a_ack(lw_ack), .a_rdata(lw_rdata),
	.b_req(hf_req), .b_we(hf_we), .b_addr(hf_addr), .b_size(hf_size),
	.b_wstrb(hf_wstrb_b), .b_wdata(hf_wdata_b), .b_ack(hf_ack), .b_rdata(hf_rdata_b),
	.o_req(bus_req), .o_we(bus_we), .o_addr(bus_addr), .o_size(bus_size),
	.o_wstrb(bus_wstrb), .o_wdata(bus_wdata), .o_ack(bus_ack), .o_rdata(bus_rdata)
);

reg        cpu_is_68000 = 1;
reg  [2:0] ipl_n = 3'b111;

wire        px_own, px_fast, px_fastw, px_reset, px_tgl, px_rw, px_uds_n, px_lds_n, px_ack_tgl;
wire [23:1] px_addr;
wire [15:0] px_wdata, px_rdata;

armcpu_bridge #(.WD_BITS(14)) br (
	.clk(clk114), .reset(reset114),
	.bus_req(bus_req), .bus_we(bus_we), .bus_addr(bus_addr), .bus_size(bus_size),
	.bus_wstrb(bus_wstrb), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.cpu_is_68000(cpu_is_68000), .ipl_n(ipl_n),
	.px_own(px_own), .px_fast(px_fast), .px_fastw(px_fastw), .px_reset(px_reset), .px_tgl(px_tgl), .px_rw(px_rw), .px_addr(px_addr),
	.px_uds_n(px_uds_n), .px_lds_n(px_lds_n), .px_wdata(px_wdata),
	.px_ack_tgl(px_ack_tgl), .px_rdata(px_rdata)
);

// cpu_wrapper brings px_own and px_fast into clk_sys through two flops
reg px_own_m = 0, px_own_s = 0, px_fast_m = 0, px_fast_s = 0, px_fastw_m = 0, px_fastw_s = 0;
always @(posedge clk_sys) begin
	{px_own_s, px_own_m}     <= {px_own_m, px_own};
	{px_fast_s, px_fast_m}   <= {px_fast_m, px_fast};
	{px_fastw_s, px_fastw_m} <= {px_fastw_m, px_fastw};
end
// the SDRAM port's addresses, as cpu_wrapper's u_px_router decodes them:
// here, chip RAM only (below 2 MB)
wire fast_cand = (px_addr[23:21] == 3'd0);

wire        as_n, rw, uds_n, lds_n;
wire [23:1] addr;
wire [15:0] dout;
reg         dtack_n = 1;
reg  [15:0] din;

proxy68k #(.WAIT_BITS(8)) px (
	.clk(clk_sys), .reset_n(cpu_reset_n), .ph1(ph1), .ph2(ph2),
	.own(px_own_s), .fast_en(px_fast_s), .fast_cand(fast_cand),
	.fastw_en(px_fastw_s), .fastw_cand(fast_cand), .req_tgl(px_tgl), .req_rw(px_rw), .req_addr(px_addr),
	.req_uds_n(px_uds_n), .req_lds_n(px_lds_n), .req_wdata(px_wdata),
	.ack_tgl(px_ack_tgl), .rdata(px_rdata),
	.as_n(as_n), .rw(rw), .uds_n(uds_n), .lds_n(lds_n), .addr(addr), .dout(dout),
	.dtack_n(dtack_n), .din(din)
);

integer seed = 32'h68000;
integer errors = 0, checks = 0;

task automatic fail(input [8*72-1:0] what);
	begin errors = errors + 1; if (errors < 40) $display("FAIL: %0s at %0t", what, $time); end
endtask

// ---- the 68k side: memory, DTACK, and fx68k's rules --------------------------
// 68k memory as bytes, {addr[23:20], addr[15:0]} -- the bench keeps its
// addresses inside that
reg [7:0] mem [0:(1<<20)-1];
function [19:0] mi(input [23:0] a); mi = {a[23:20], a[15:0]}; endfunction

integer dt_wait = 0, dt_count = 0;
reg     no_dtack = 0;           // bank F: never answers
integer n_cycles = 0, n_uds = 0, n_lds = 0;
reg     last_uds, last_lds, last_rw;
reg [23:1] last_addr;

// DTACK: some enPhi2 samples after AS falls, held until AS rises; a fast
// cycle is the SDRAM port's ready instead, a few edges after AS on any edge
reg     cyc_fast = 0;               // the cycle in progress is a fast read
integer dt_fast = 2;
always @(posedge clk_sys) begin
	if (as_n) begin dtack_n <= 1; dt_count <= 0; end
	else if (cyc_fast) begin
		if (dt_count >= dt_fast) dtack_n <= 0;
		dt_count <= dt_count + 1;
	end
	else if (ph2 && !no_dtack && addr[23:20] != 4'hF) begin
		if (dt_count >= dt_wait) dtack_n <= 0;
		dt_count <= dt_count + 1;
	end
end
// the data bus, set between edges (an @* over the whole memory would make
// Icarus elaborate forever)
always @(negedge clk_sys) din <= (~as_n & rw & ~dtack_n) ? {mem[mi({addr, 1'b0})], mem[mi({addr, 1'b1})]} : 16'hxxxx;

// pin history: the value before this edge, and the enables of the edge before
reg p_as = 1, p_rw = 1, p_uds = 1, p_lds = 1, p_ph1 = 0, p_ph2 = 0, p_rstn = 0;
reg [23:1] p_addr; reg [15:0] p_dout;
reg        dtack_seen;         // DTACK sampled low on an enPhi2 in this cycle
integer    ph1_since_dtack;
reg        rw_due;             // AS has risen, R/W (if low) rises on the next enPhi1
reg        wr_strobe_due;      // a write's AS fell; its strobes follow on the next enPhi1
reg        ds_seen;
reg        fdt_seen;           // fast cycle: the ready seen on an edge
reg        fast_ended = 0;     // a fast cycle ended on this edge
integer    n_fast = 0, n_fast_writes = 0, n_fastw = 0;
wire       fast_start = (px_fast_s & rw | px_fastw_s & ~rw) & (addr[23:21] == 3'd0);

always @(posedge clk_sys) begin
	// what changed since the last edge happened on that edge
	// (a reset ends a cycle on whatever edge it lands on)
	// (a fast read is not a 68000 cycle: its edges are checked below)
	if ((as_n !== p_as || uds_n !== p_uds || lds_n !== p_lds || rw !== p_rw) && !(p_ph1 || p_ph2) && p_rstn
	    && !cyc_fast && !(p_as && !as_n && fast_start))
		fail("a pin moved on an edge with no phase enable");

	// a fast cycle: AS with its strobes (and a write's R/W and data) on any
	// edge, ending on the edge after its ready
	if (p_as && !as_n && fast_start) begin
		checks = checks + 1;
		cyc_fast = 1; fdt_seen = 0;
		dt_fast = $unsigned($random(seed)) % 6;
		if (uds_n && lds_n) fail("fast cycle: AS fell without its strobes");
		if (!rw && p_rw !== 1'b1) fail("fast write: R/W low before AS");
		last_rw = rw; last_addr = addr; last_uds = uds_n; last_lds = lds_n;
		if (rw) n_fast = n_fast + 1; else n_fastw = n_fastw + 1;
	end
	else if (cyc_fast && !as_n) begin
		if (addr !== p_addr || rw !== last_rw) fail("fast cycle: address or R/W moved");
		if (!last_rw && dout !== p_dout) fail("fast write: data moved");
		if (!dtack_n) fdt_seen = 1;
	end
	else if (cyc_fast && as_n) begin
		fast_ended = 1;
		checks = checks + 2;
		if (!(uds_n && lds_n) || rw !== 1'b1) fail("fast cycle: strobes or R/W did not rise with AS");
		if (!fdt_seen && last_addr[23:20] != 4'hF && p_rstn) fail("fast cycle: AS rose before the ready");
		if (!last_rw) begin
			if (!last_uds) mem[mi({last_addr, 1'b0})] = p_dout[15:8];
			if (!last_lds) mem[mi({last_addr, 1'b1})] = p_dout[7:0];
		end
		n_cycles = n_cycles + 1;
		if (!last_uds) n_uds = n_uds + 1;
		if (!last_lds) n_lds = n_lds + 1;
		cyc_fast = 0;
	end
	// AS falls: on enPhi1, with a read's strobes or a write's R/W
	else if (p_as && !as_n) begin
		checks = checks + 1;
		if (!rw && px_fast_s) n_fast_writes = n_fast_writes + 1;
		if (!p_ph1) fail("AS fell off enPhi1");
		if (rw && (uds_n && lds_n)) fail("read: AS fell without its strobes");
		if (!rw && !(uds_n && lds_n)) fail("write: strobes fell with AS");
		if (!rw && p_rw !== 1'b1) fail("write: R/W low before AS");
		wr_strobe_due = !rw;
		dtack_seen = 0; ph1_since_dtack = 0; ds_seen = !(uds_n && lds_n);
		last_rw = rw; last_addr = addr;
		last_uds = uds_n; last_lds = lds_n;
	end
	else if (!as_n && !cyc_fast) begin
		if (addr !== p_addr) fail("address moved while AS low");
		if (!rw && dout !== p_dout) fail("write data moved while AS low");
		if (rw !== p_rw && p_rw !== 1'bx) fail("R/W moved while AS low");
		if (wr_strobe_due && p_ph1 && !p_as) begin
			// the enPhi1 after AS fell: a write's strobes now
			checks = checks + 1;
			if (uds_n && lds_n) fail("write: strobes not one enPhi1 after AS");
			wr_strobe_due = 0;
			last_uds = uds_n; last_lds = lds_n; ds_seen = 1;
		end
		if (p_ph2 && !dtack_n) dtack_seen = 1;
		if (dtack_seen && p_ph1) ph1_since_dtack = ph1_since_dtack + 1;
	end

	// AS rises: on enPhi2, with the strobes, after DTACK and an enPhi1
	if (!p_as && as_n && !cyc_fast && !fast_ended) begin
		checks = checks + 3;
		// (a cycle with no DTACK is the proxy's timeout, which ends on enPhi1)
		if (!p_ph2 && last_addr[23:20] != 4'hF && p_rstn) fail("AS rose off enPhi2");
		if (!(uds_n && lds_n)) fail("strobes did not rise with AS");
		if (!(dtack_seen && ph1_since_dtack >= 1) && !no_dtack && last_addr[23:20] != 4'hF && p_rstn)
			fail("AS rose before DTACK had been seen and an enPhi1 passed");
		n_cycles = n_cycles + 1;
		if (!last_uds) n_uds = n_uds + 1;
		if (!last_lds) n_lds = n_lds + 1;
		// a write lands on the edge AS rises
		if (!last_rw) begin
			if (!last_uds) mem[mi({last_addr, 1'b0})] = p_dout[15:8];
			if (!last_lds) mem[mi({last_addr, 1'b1})] = p_dout[7:0];
		end
		rw_due = !last_rw && last_addr[23:20] != 4'hF;
	end
	else if (rw_due && p_ph1) begin
		checks = checks + 1;
		if (rw !== 1'b1) fail("R/W did not rise on the enPhi1 after AS");
		rw_due = 0;
	end
	else if (rw_due && rw && p_as && !p_ph1) fail("R/W rose before the enPhi1 after AS");

	fast_ended = 0;
	p_rstn = cpu_reset_n;
	p_as = as_n; p_rw = rw; p_uds = uds_n; p_lds = lds_n; p_ph1 = ph1; p_ph2 = ph2;
	p_addr = addr; p_dout = dout;
end

// ---- AXI tasks ---------------------------------------------------------------
reg [31:0] beat_data [0:15];
reg [31:0] got [0:15];
integer    w_resp_t, w_start_t;

task automatic gap; repeat ($random(seed) & 3) @(posedge clk114); endtask

task automatic axi_write(input [20:0] a, input [3:0] len, input [2:0] size, input [3:0] strb);
	integer beat, t;
	begin
		gap;
		w_start_t = $time;
		awaddr <= a; awlen <= len; awsize <= size; awburst <= 2'b01; awid <= $random(seed); awvalid <= 1;
		@(posedge clk114); while (!awready) @(posedge clk114);
		awvalid <= 0;
		for (beat = 0; beat <= len; beat = beat + 1) begin
			wdata <= beat_data[beat]; wstrb <= strb; wlast <= (beat == len); wvalid <= 1;
			@(posedge clk114); t = 0;
			while (!wready) begin
				@(posedge clk114); t = t + 1;
				if (t > 2000000) begin fail("write beat never accepted"); disable axi_write; end
			end
			wvalid <= 0;
		end
		bready <= 1; t = 0;
		@(posedge clk114);
		while (!bvalid) begin
			@(posedge clk114); t = t + 1;
			if (t > 2000000) begin fail("no write response"); disable axi_write; end
		end
		w_resp_t = $time;
		bready <= 0;
	end
endtask

task automatic axi_read(input [20:0] a, input [3:0] len, input [2:0] size);
	integer beat, t;
	begin
		gap;
		araddr <= a; arlen <= len; arsize <= size; arburst <= 2'b01; arid <= $random(seed); arvalid <= 1;
		@(posedge clk114); while (!arready) @(posedge clk114);
		arvalid <= 0;
		beat = 0; t = 0;
		while (beat <= len) begin
			rready <= 1;
			@(posedge clk114);
			if (rvalid && rready) begin
				got[beat] = rdata;
				if (rlast != (beat == len)) fail("rlast on the wrong beat");
				beat = beat + 1;
			end
			t = t + 1;
			if (t > 4000000) begin fail("read never completed"); disable axi_read; end
		end
		rready <= 0;
	end
endtask

reg [31:0] hbeat_data [0:15];
reg [31:0] hgot [0:15];

task automatic hf_write(input [29:0] a, input [3:0] len, input [2:0] size, input [3:0] strb);
	integer beat, t;
	begin
		gap;
		w_start_t = $time;
		hf_awaddr <= a; hf_awlen <= len; hf_awsize <= size; hf_awburst <= 2'b01; hf_awid <= $random(seed); hf_awvalid <= 1;
		@(posedge clk114); while (!hf_awready) @(posedge clk114);
		hf_awvalid <= 0;
		for (beat = 0; beat <= len; beat = beat + 1) begin
			hf_wdata <= hbeat_data[beat]; hf_wstrb <= strb; hf_wlast <= (beat == len); hf_wvalid <= 1;
			@(posedge clk114); t = 0;
			while (!hf_wready) begin
				@(posedge clk114); t = t + 1;
				if (t > 2000000) begin fail("write beat never accepted"); disable hf_write; end
			end
			hf_wvalid <= 0;
		end
		hf_bready <= 1; t = 0;
		@(posedge clk114);
		while (!hf_bvalid) begin
			@(posedge clk114); t = t + 1;
			if (t > 2000000) begin fail("no write response"); disable hf_write; end
		end
		w_resp_t = $time;
		hf_bready <= 0;
	end
endtask

task automatic hf_read(input [29:0] a, input [3:0] len, input [2:0] size);
	integer beat, t;
	begin
		gap;
		hf_araddr <= a; hf_arlen <= len; hf_arsize <= size; hf_arburst <= 2'b01; hf_arid <= $random(seed); hf_arvalid <= 1;
		@(posedge clk114); while (!hf_arready) @(posedge clk114);
		hf_arvalid <= 0;
		beat = 0; t = 0;
		while (beat <= len) begin
			hf_rready <= 1;
			@(posedge clk114);
			if (hf_rvalid && hf_rready) begin
				hgot[beat] = hf_rdata;
				if (hf_rlast != (beat == len)) fail("hf_rlast on the wrong beat");
				beat = beat + 1;
			end
			t = t + 1;
			if (t > 4000000) begin fail("read never completed"); disable hf_read; end
		end
		hf_rready <= 0;
	end
endtask

// bridge offsets
localparam [20:0] CTL = 21'h080000, WIN = 21'h100000;
function [20:0] creg(input integer n); creg = CTL + 4 * n; endfunction

task automatic ctl_write(input integer n, input [31:0] v);
	begin beat_data[0] = v; axi_write(creg(n), 0, 2, 4'hF); end
endtask
task automatic ctl_read(input integer n, output [31:0] v);
	begin axi_read(creg(n), 0, 2); v = got[0]; end
endtask

// expected bytes for an ARM view of 68k memory
function [7:0] mb(input [3:0] bank, input [19:0] off);
	mb = mem[mi({bank, off})];
endfunction

// ---- the run -----------------------------------------------------------------
integer i, k, c0, u0, l0, lanes, size_sel;
reg [31:0] v, w, exp_v;
reg  [3:0] bank;
reg [19:0] off;
reg  [3:0] strb;

initial begin
	for (i = 0; i < (1 << 20); i = i + 1) mem[i] = $random(seed);
	repeat (8) @(posedge clk114);
	reset114 <= 0;
	repeat (8) @(posedge clk_sys);
	cpu_reset_n <= 1;
	repeat (4) @(posedge clk114);

	// control registers
	ctl_read(0, v); checks = checks + 1;
	if (v !== 32'h41435055) fail("MAGIC wrong");
	ctl_write(2, 32'h5); ctl_read(2, v); checks = checks + 1;
	if (v !== 32'h5) fail("BANK does not read back");
	ipl_n = 3'b010;  // level 5
	ctl_read(3, v); checks = checks + 2;
	if (v[2:0] !== 3'd5) fail("STATUS interrupt level wrong");
	if (v[8] !== 1'b1 || v[4] !== 1'b0) fail("STATUS 68000 / OWN wrong before OWN");
	ipl_n = 3'b111;

	// OWN clear: nothing reaches the pins, reads answer all ones
	c0 = n_cycles;
	axi_read(WIN + 21'h1230, 0, 2);
	checks = checks + 2;
	if (got[0] !== 32'hFFFFFFFF) fail("read without OWN not all ones");
	if (n_cycles != c0) fail("a cycle ran without OWN");

	// not a 68000: OWN does not take
	cpu_is_68000 = 0;
	ctl_write(1, 1); ctl_read(1, v); checks = checks + 1;
	if (v[0] !== 1'b0) fail("OWN took effect with the CPU not a 68000");
	cpu_is_68000 = 1;
	ctl_write(1, 0); ctl_write(1, 1); ctl_read(1, v); checks = checks + 1;
	if (v[0] !== 1'b1) fail("OWN did not take effect");
	repeat (8) @(posedge clk_sys);

	// random single accesses of every size, both directions: FAST off, then on
	for (i = 0; i < 900; i = i + 1) begin
		if (i == 300) ctl_write(1, 3);
		if (i == 600) ctl_write(1, 7);
		bank = $unsigned($random(seed)) % 15;   // not F: F never answers
		off  = $random(seed) & 20'h0FFFC;       // inside the bench's memory map
		dt_wait = $random(seed) & 3;
		ctl_write(2, bank);
		size_sel = $unsigned($random(seed)) % 3;
		k = $random(seed) & 3;                  // byte lane / half for narrow accesses
		c0 = n_cycles; u0 = n_uds; l0 = n_lds;
		if ($random(seed) & 1) begin
			// read
			case (size_sel)
				0: begin off = off + k; axi_read(WIN + off, 0, 0); end
				1: begin off = off + (k & 2); axi_read(WIN + off, 0, 1); end
				default: axi_read(WIN + off, 0, 2);
			endcase
			checks = checks + 2;
			case (size_sel)
				0: begin
					if (got[0][8*(off & 3) +: 8] !== mb(bank, off)) fail("byte read: wrong byte");
					if (n_cycles != c0 + 1) fail("byte read: not one cycle");
					if ((n_uds - u0) + (n_lds - l0) != 1) fail("byte read: not exactly one strobe");
					else if (off[0] ? (n_lds == l0) : (n_uds == u0)) fail("byte read: wrong strobe");
				end
				1: begin
					if (got[0][16*off[1] +: 16] !== {mb(bank, off + 1), mb(bank, off)}) fail("halfword read: wrong bytes");
					if (n_cycles != c0 + 1) fail("halfword read: not one cycle");
				end
				default: begin
					if (got[0] !== {mb(bank, off + 3), mb(bank, off + 2), mb(bank, off + 1), mb(bank, off)})
						begin fail("word read: wrong bytes"); $display("  got %h", got[0]); end
					if (n_cycles != c0 + 2) fail("word read: not two cycles");
				end
			endcase
		end
		else begin
			// write, then read it back through the bridge
			beat_data[0] = $random(seed);
			case (size_sel)
				0: begin off = off + k; strb = 4'b0001 << k; end
				1: begin off = off + (k & 2); strb = (k & 2) ? 4'b1100 : 4'b0011; end
				default: strb = 4'b1111;
			endcase
			axi_write(WIN + off, 0, size_sel, strb);
			axi_read(WIN + (off & 20'hFFFFC), 0, 2);
			checks = checks + 2;
			for (lanes = 0; lanes < 4; lanes = lanes + 1)
				if (strb[lanes] && got[0][8*lanes +: 8] !== beat_data[0][8*lanes +: 8])
					fail("write then read: written byte not back");
			for (lanes = 0; lanes < 4; lanes = lanes + 1)
				if (strb[lanes] && mb(bank, (off & 20'hFFFFC) + lanes) !== beat_data[0][8*lanes +: 8])
					fail("write: wrong byte in 68k memory");
			if (n_cycles != c0 + ((size_sel == 2) ? 2 : 1) + 2) fail("write: wrong number of cycles");
		end
	end

	// FAST: reads in chip RAM went fast, nothing else did; a fast halfword
	// read takes less time by LAST than the same read with FAST off
	checks = checks + 2;
	if (n_fast < 50) begin fail("FAST: too few fast reads"); $display("  %0d", n_fast); end
	if (n_fast_writes == 0) fail("FAST: no writes ran with FAST on (bench)");
	checks = checks + 1;
	if (n_fastw < 10) begin fail("FASTW: too few fast writes"); $display("  %0d", n_fastw); end
	// a fast write takes less time by LAST than a 68000-timed one
	ctl_write(1, 7);
	ctl_write(2, 0);
	beat_data[0] = 32'h12345678;
	axi_write(WIN + 21'h00060, 0, 1, 4'b0011);
	ctl_read(5, w);
	ctl_write(1, 1);
	axi_write(WIN + 21'h00060, 0, 1, 4'b0011);
	ctl_read(5, v);
	checks = checks + 1;
	if (!(w < v)) begin fail("FASTW write not quicker by LAST"); $display("  fast %0d slow %0d", w, v); end
	ctl_write(1, 3);
	ctl_write(2, 0);
	axi_read(WIN + 21'h00040, 0, 1);
	ctl_read(5, w);
	ctl_write(1, 1);
	axi_read(WIN + 21'h00040, 0, 1);
	ctl_read(5, v);
	checks = checks + 1;
	if (!(w < v)) begin fail("FAST read not quicker by LAST"); $display("  fast %0d slow %0d", w, v); end
	ctl_read(1, v);
	checks = checks + 1;
	if (v[2:0] !== 3'b001) fail("CTRL does not read back OWN without FAST");
	// RESET: the CPU's reset output follows CTRL bit 3, only with OWN
	ctl_write(1, 9); ctl_read(1, v);
	checks = checks + 2;
	if (v[3] !== 1'b1 || px_reset !== 1'b1) fail("RESET with OWN did not take");
	ctl_write(1, 8); ctl_read(1, v);
	if (v[3] !== 1'b0 || px_reset !== 1'b0) fail("RESET without OWN took");
	ctl_write(1, 1);

	// a posted write: answered before its cycle can have ended
	ctl_write(2, 0);
	dt_wait = 3;
	beat_data[0] = 32'hA5A55A5A;
	c0 = n_cycles;
	axi_write(WIN + 21'h00100, 0, 2, 4'hF);
	checks = checks + 1;
	if (n_cycles != c0) fail("write not posted: its cycles had ended before the answer");
	axi_read(WIN + 21'h00100, 0, 2);
	checks = checks + 1;
	if (got[0] !== 32'hA5A55A5A) fail("read after a posted write missed it");

	// the two channels at once: a burst write and a read of other words
	for (k = 0; k < 20; k = k + 1) begin
		for (i = 0; i < 4; i = i + 1) beat_data[i] = $random(seed);
		exp_v = {mb(0, 20'h00404 + 3), mb(0, 20'h00404 + 2), mb(0, 20'h00404 + 1), mb(0, 20'h00404)};
		fork
			axi_write(WIN + 21'h00500, 3, 2, 4'hF);
			axi_read(WIN + 21'h00404, 0, 2);
		join
		checks = checks + 2;
		if (got[0] !== exp_v) fail("read beside a write came back wrong");
		axi_read(WIN + 21'h00500, 3, 2);
		for (i = 0; i < 4; i = i + 1)
			if (got[i] !== beat_data[i]) fail("write beside a read landed wrong");
	end

	// INCR bursts: four words in, four out
	for (i = 0; i < 4; i = i + 1) beat_data[i] = $random(seed);
	axi_write(WIN + 21'h00200, 3, 2, 4'hF);
	axi_read(WIN + 21'h00200, 3, 2);
	checks = checks + 1;
	for (i = 0; i < 4; i = i + 1)
		if (got[i] !== beat_data[i]) fail("burst: beat came back wrong");

	// LAST and WORDS
	ctl_read(6, w);
	axi_read(WIN + 21'h00300, 0, 2);
	ctl_read(5, v);
	ctl_read(6, exp_v);
	checks = checks + 2;
	if (exp_v - w != 2) fail("WORDS did not count two word cycles");
	if (v < 32'd60 || v > 32'd500) begin fail("LAST out of range for two word cycles"); $display("  LAST %0d", v); end

	// no DTACK: the cycle ends after the timeout and reads all ones
	ctl_write(2, 4'hF);
	axi_read(WIN + 21'h00010, 0, 1);
	checks = checks + 1;
	if (got[0][15:0] !== 16'hFFFF) fail("no-DTACK read not all ones");

	// a reset in the middle of a cycle still answers
	ctl_write(2, 0);
	dt_wait = 40;
	fork
		axi_read(WIN + 21'h00020, 0, 1);
		begin
			@(negedge as_n);
			repeat (6) @(posedge clk_sys);
			cpu_reset_n <= 0;
			repeat (20) @(posedge clk_sys);
			cpu_reset_n <= 1;
		end
	join
	checks = checks + 1;
	if (got[0][15:0] !== 16'hFFFF) fail("cycle cut by reset did not answer all ones");
	dt_wait = 1;
	axi_read(WIN + 21'h00020, 0, 1);
	checks = checks + 1;
	if (got[0][15:0] !== {mem[mi(24'h21)], mem[mi(24'h20)]}) fail("first read after the reset wrong");

	// the CPU halted mid-cycle: the proxy never ends it, the bridge gives up
	dt_wait = 1;
	fork
		axi_read(WIN + 21'h00040, 0, 2);
		begin
			@(negedge as_n);
			halt = 1;
		end
	join
	checks = checks + 1;
	if (got[0] !== 32'hFFFFFFFF) fail("halted read not all ones");
	ctl_read(3, v); checks = checks + 2;
	if (v[9] !== 1'b1) fail("STATUS timed-out bit not set");
	if (v[4] !== 1'b0) fail("OWN still in effect after the watchdog");
	c0 = n_cycles;
	axi_read(WIN + 21'h00040, 0, 2);
	checks = checks + 1;
	if (got[0] !== 32'hFFFFFFFF) fail("read after the watchdog not all ones");
	halt = 0;
	repeat (400) @(posedge clk_sys);
	ctl_write(1, 1);
	repeat (8) @(posedge clk_sys);
	ctl_read(3, v); checks = checks + 1;
	if (v[9] !== 1'b0) fail("STATUS timed-out bit not cleared by OWN");
	axi_read(WIN + 21'h00040, 0, 2);
	checks = checks + 1;
	if (got[0] !== {mem[mi(24'h43)], mem[mi(24'h42)], mem[mi(24'h41)], mem[mi(24'h40)]}) begin
		fail("first read after the watchdog wrong"); $display("  got %08x", got[0]); end

	// ---- step 4: the flat view ------------------------------------------------
	// random accesses of every size at their 68k address, BANK set elsewhere
	ctl_write(2, 4'h3);
	dt_wait = 1;
	for (i = 0; i < 300; i = i + 1) begin
		bank = $unsigned($random(seed)) % 15;
		off  = $random(seed) & 20'h0FFFC;
		size_sel = $unsigned($random(seed)) % 3;
		k = $random(seed) & 3;
		c0 = n_cycles;
		if ($random(seed) & 1) begin
			case (size_sel)
				0: begin off = off + k; hf_read({bank, off}, 0, 0); end
				1: begin off = off + (k & 2); hf_read({bank, off}, 0, 1); end
				default: hf_read({bank, off}, 0, 2);
			endcase
			checks = checks + 2;
			case (size_sel)
				0: if (hgot[0][8*(off & 3) +: 8] !== mb(bank, off)) fail("flat byte read: wrong byte");
				1: if (hgot[0][8*(off & 3) +: 16] !== {mb(bank, off + 1), mb(bank, off)}) fail("flat halfword read wrong");
				default: if (hgot[0] !== {mb(bank, off + 3), mb(bank, off + 2), mb(bank, off + 1), mb(bank, off)})
					fail("flat word read wrong");
			endcase
			if (n_cycles != c0 + (size_sel == 2 ? 2 : 1)) fail("flat read: wrong number of word cycles");
		end
		else begin
			w = $random(seed);
			hbeat_data[0] = w;
			case (size_sel)
				0: begin off = off + k; strb = 4'b0001 << k; end
				1: begin off = off + (k & 2); strb = (k & 2) ? 4'b1100 : 4'b0011; end
				default: strb = 4'b1111;
			endcase
			hf_write({bank, off & 20'hFFFFC}, 0, size_sel, strb);
			hf_read({bank, off & 20'hFFFFC}, 0, 2);
			checks = checks + 1;
			for (lanes = 0; lanes < 4; lanes = lanes + 1)
				if (strb[lanes] && hgot[0][8*lanes +: 8] !== w[8*lanes +: 8]) fail("flat write did not land");
		end
	end
	ctl_read(2, v); checks = checks + 1;
	if (v !== 32'h3) fail("a flat access moved BANK");

	// the two views agree: written flat at $000100, read through bank 0
	hbeat_data[0] = 32'hA5C31E7F;
	hf_write(30'h0000100, 0, 2, 4'hF);
	ctl_write(2, 4'h0);
	axi_read(WIN + 21'h00100, 0, 2);
	checks = checks + 1;
	if (got[0] !== 32'hA5C31E7F) fail("banked read does not see the flat write");

	// nothing at 16 MB and above: all ones, no cycle
	c0 = n_cycles;
	hf_read(30'h1000000, 0, 2);
	checks = checks + 2;
	if (hgot[0] !== 32'hFFFFFFFF) fail("flat read above 16 MB not all ones");
	if (n_cycles != c0) fail("a cycle ran for an address above 16 MB");

	// both masters at once: control reads on one, flat reads on the other
	fork
		begin : lwside
			integer q;
			reg [31:0] mv;
			for (q = 0; q < 30; q = q + 1) begin
				ctl_read(0, mv); checks = checks + 1;
				if (mv !== 32'h41435055) fail("MAGIC wrong while the flat master runs");
			end
		end
		begin : hfside
			integer q;
			for (q = 0; q < 30; q = q + 1) begin
				hf_read(30'h0000200 + 4 * q, 0, 2); checks = checks + 1;
				if (hgot[0] !== {mem[mi(24'h203 + 4 * q)], mem[mi(24'h202 + 4 * q)],
				                 mem[mi(24'h201 + 4 * q)], mem[mi(24'h200 + 4 * q)]})
					fail("flat read wrong while the lightweight master runs");
			end
		end
	join

	// OWN off again: back to all ones and no cycles
	ctl_write(1, 0);
	c0 = n_cycles;
	axi_read(WIN, 0, 2);
	checks = checks + 2;
	if (got[0] !== 32'hFFFFFFFF) fail("read after OWN cleared not all ones");
	if (n_cycles != c0) fail("a cycle ran after OWN cleared");

	$display("%0d checks, %0d errors, %0d 68k cycles", checks, errors, n_cycles);
	if (errors == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end

initial begin
	#400_000_000;
	$display("RUN: FAIL (timeout)");
	$finish;
end

endmodule
