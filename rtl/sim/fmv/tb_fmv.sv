// tb_fmv.sv -- the FMV front end (rtl/fmv) against the FPGA side of
// FringeCoder/AmigaCD docs/fmv-contract.md (v4), whose executable statement
// is tests/fmv_fpga_ref.h in that repository. Each check here is one rule of
// it; the labels name the rule.
//
// The DDR3 model takes requests with random waitrequest and returns reads
// after a random latency. The 68k and DDR3 clocks are unrelated. The host
// half of the bench plays Main: it writes update-queue entries (word 1, then
// word 0 with SEQ, then UQ_WPTR) and reads the event ring.
//
// Run: iverilog -g2012 -o tb ../../fmv/fmv_afifo.v ../../fmv/fmv_bus.v
//      ../../fmv/fmv_ddr.v ../../fmv/fmv_video.v ../../fmv/fmv.v tb_fmv.sv && vvp -n tb
`timescale 1ns/1ps

module tb_fmv;
	// ------------------------------------------------------------ clocks
	reg clk_sys = 0, clk_ddr = 0;
	always #17.6 clk_sys = ~clk_sys;    // ~28.4 MHz
	always #4.39 clk_ddr = ~clk_ddr;    // ~114 MHz

	// ------------------------------------------------------------ the DUT
	reg         amiga_reset = 0, fmv_on = 1;
	reg  [23:1] cpu_addr = 0;
	reg  [15:0] cpu_dout = 0;
	wire [15:0] cpu_din;
	reg         cpu_rw = 1, as_n = 1, uds_n = 1, lds_n = 1;
	// gary's decode keeps answering for a board configured before FMV was
	// switched off at runtime, so the board itself must gate on fmv_on (L).
	wire        sel = (cpu_addr[23:20] == 4'h2);
	wire        nrdy, int2, ac_present;
	reg   [5:0] ac_nib_addr = 0;
	wire  [3:0] ac_nib;

	wire [28:0] m_address;
	wire  [7:0] m_burstcount, m_byteenable;
	wire        m_read, m_write;
	wire [63:0] m_writedata;
	reg  [63:0] m_readdata = 0;
	reg         m_readdatavalid = 0;
	reg         m_waitrequest = 1;
	integer     off_xfers = 0;          // DDR3 transfers accepted while off (M)
	reg         count_off = 0;

	fmv #(.PERF_WINDOW(6000), .PERF_SHIFT(0)) dut (
		.clk_sys(clk_sys), .amiga_reset(amiga_reset), .fmv_on(fmv_on),
		.cpu_addr(cpu_addr), .cpu_data_in(cpu_dout), .cpu_data_out(cpu_din),
		.cpu_rw(cpu_rw), .cpu_as_n(as_n), .cpu_uds_n(uds_n), .cpu_lds_n(lds_n),
		.sel(sel), .nrdy(nrdy), .int2(int2),
		.ac_present(ac_present), .ac_nib_addr(ac_nib_addr), .ac_nib(ac_nib),
		.clk_ddr(clk_ddr),
		.mem_address(m_address), .mem_burstcount(m_burstcount), .mem_read(m_read),
		.mem_readdata(m_readdata), .mem_readdatavalid(m_readdatavalid),
		.mem_writedata(m_writedata), .mem_byteenable(m_byteenable),
		.mem_write(m_write), .mem_waitrequest(m_waitrequest)
	,
		.hsync_n(1'b1), .vsync_n(1'b1)
	);

	// ------------------------------------------------------- DDR3 model
	localparam [28:0] BASE = 29'h04E00000;
	reg [63:0] mem [0:262143];          // the 2 MB window, 64-bit words
	integer ii;
	initial for (ii = 0; ii < 262144; ii = ii + 1) mem[ii] = 64'd0;

	// Byte-level access for the host half and the checks
	function [7:0] mbyte(input [20:0] o);
		mbyte = mem[o >> 3][8 * (o & 7) +: 8];
	endfunction
	task set_mbyte(input [20:0] o, input [7:0] v);
		mem[o >> 3][8 * (o & 7) +: 8] = v;
	endtask

	integer seed = 1;
	reg [28:0] rd_addr; reg [7:0] rd_left; integer rd_wait;
	reg        rd_busy = 0;
	always @(posedge clk_ddr) begin
		m_waitrequest <= ($random(seed) & 3) == 0;     // 1 cycle in 4 busy
		m_readdatavalid <= 0;
		if (count_off && !m_waitrequest && (m_read || m_write))
			off_xfers = off_xfers + 1;
		if (!m_waitrequest && m_write)
			for (ii = 0; ii < 8; ii = ii + 1)
				if (m_byteenable[ii]) mem[m_address - BASE][8 * ii +: 8] <= m_writedata[8 * ii +: 8];
		if (!m_waitrequest && m_read && !rd_busy) begin
			rd_busy <= 1; rd_addr <= m_address; rd_left <= m_burstcount;
			rd_wait <= 2 + ($random(seed) & 7);
		end
		if (rd_busy) begin
			if (rd_wait > 0) rd_wait <= rd_wait - 1;
			else begin
				m_readdatavalid <= 1;
				m_readdata <= mem[rd_addr - BASE];
				rd_addr <= rd_addr + 1;
				rd_left <= rd_left - 1;
				if (rd_left == 1) rd_busy <= 0;
				rd_wait <= $random(seed) & 1;
			end
		end
	end

	// ------------------------------------------------------------ checks
	integer fails = 0, checks = 0;
	task check(input ok, input [8*80-1:0] what);
		begin
			checks = checks + 1;
			if (!ok) begin fails = fails + 1; $display("FAIL %0s", what); end
		end
	endtask

	// ------------------------------------------------------- the host (Main)
	localparam integer EV_WPTR = 21'h100000, UQ_RDPTR = 21'h100008, UQ_WPTR = 21'h100040,
	                   UQ = 21'h101000, EV = 21'h110000;
	reg [31:0] uq_wr = 0, ev_rd = 0;

	task uq_entry(input [7:0] index, input maskfile, input guard, input [15:0] value,
	              input [15:0] mask, input [31:0] rdidx, input bad_seq);
		reg [20:0] o;
		begin
			o = UQ + 16 * (uq_wr & 1023);
			mem[(o >> 3) + 1] = {rdidx, mask, value};
			mem[o >> 3] = {bad_seq ? ~uq_wr[15:0] : uq_wr[15:0], 38'd0, guard, maskfile, index};
			uq_wr = uq_wr + 1;
			mem[UQ_WPTR >> 3] = {32'd0, uq_wr};
		end
	endtask
	task upd(input [7:0] index, input [15:0] value, input [15:0] mask);
		uq_entry(index, 0, 0, value, mask, ev_count_seen(0), 0);
	endtask
	task updm(input [7:0] index, input [15:0] m);
		uq_entry(index, 1, 0, m, 16'hFFFF, 0, 0);
	endtask
	function [31:0] ev_count_seen(input dummy);
		ev_count_seen = mem[EV_WPTR >> 3][31:0];
	endfunction
	// Wait until the FPGA has applied everything queued.
	task uq_sync;
		integer t;
		begin
			t = 0;
			while (mem[UQ_RDPTR >> 3][31:0] != uq_wr && t < 100000) begin
				@(posedge clk_sys); t = t + 1;
			end
			repeat (6) @(posedge clk_sys);   // through the crossing into fmv_bus
			check(t < 100000, "uq_sync: the FPGA reads the update queue");
		end
	endtask
	// The next event, once it has landed (SEQ), and its index.
	task ev_next(output [63:0] e);
		integer t;
		begin
			t = 0;
			while ((mem[EV_WPTR >> 3][31:0] == ev_rd ||
			        mem[(EV >> 3) + (ev_rd & 4095)][63:48] != ev_rd[15:0]) && t < 100000) begin
				@(posedge clk_ddr); t = t + 1;
			end
			check(t < 100000, "ev_next: an event arrives");
			e = mem[(EV >> 3) + (ev_rd & 4095)];
			ev_rd = ev_rd + 1;
		end
	endtask
	task ev_drain;
		reg [63:0] e;
		begin
			repeat (40) @(posedge clk_ddr);
			while (mem[EV_WPTR >> 3][31:0] != ev_rd) ev_next(e);
		end
	endtask

	// ------------------------------------------------------- the 68k bus
	integer bus_cycles;
	task bus(input [23:1] a, input rw, input [15:0] d, input u, input l, output [15:0] q);
		integer t;
		begin
			@(posedge clk_sys);
			cpu_addr <= a; cpu_rw <= rw; cpu_dout <= d;
			@(posedge clk_sys);
			as_n <= 0; uds_n <= ~u; lds_n <= ~l;
			@(posedge clk_sys);
			t = 0;
			while (nrdy && t < 200000) begin @(posedge clk_sys); t = t + 1; end
			bus_cycles = t;
			@(posedge clk_sys);
			q = cpu_din;
			as_n <= 1; uds_n <= 1; lds_n <= 1;
			@(posedge clk_sys);
		end
	endtask
	reg [15:0] q;
	task wr(input [23:1] a, input [15:0] d); bus(a, 0, d, 1, 1, q); endtask
	task rd(input [23:1] a, output [15:0] v); bus(a, 1, 0, 1, 1, v); endtask

	function [23:1] B(input [19:0] off); B = {4'h2, off[19:1]}; endfunction

	// ------------------------------------------------------------ tests
	reg [63:0] e;
	reg [15:0] v;
	integer n0, k;

	initial begin
		repeat (20) @(posedge clk_sys);

		// --- A: ALIVE, masks and autoconfig through the update queue
		check(!ac_present, "A.not present before ALIVE");
		for (k = 0; k < 16; k = k + 1)
			upd(8'hD0 + k, 16'h1234 + k * 16'h1111, 16'hFFFF);
		upd(8'hC0, 1, 1);
		uq_sync;
		check(ac_present, "A.ALIVE: present in the chain");
		ac_nib_addr = 6'd1;  #1 check(ac_nib == 4'h3, "A.autocfg nibble 1 = bits 7:4 of 0xD0");
		ac_nib_addr = 6'd6;  #1 check(ac_nib == 4'h3, "A.autocfg nibble 6 = bits 11:8 of 0xD1 (0x2345)");

		// --- B: the 68k writes only the bits its mask gives it
		updm(8'h11, 16'hFFFF);                   // CPU_pc (0x22) writable
		updm(8'h41, 16'h0000);                   // CMEM_status (0x82) read-only
		upd(8'h41, 16'h1234, 16'hFFFF);          // Main sets it
		uq_sync;
		wr(B(20'h70022), 16'hBEEF);
		rd(B(20'h70022), v); check(v == 16'hBEEF, "B.masked write: writable register reads back");
		wr(B(20'h70082), 16'h5A5A);     // bits set and clear against 0x1234
		rd(B(20'h70082), v); check(v == 16'h1234, "B.masked write: read-only register unchanged");
		ev_drain;

		// --- C: HMEM through HOST_raddr / HOST_rdata [CL 8-13]
		updm(8'h44, 16'h000F);
		for (k = 0; k < 16; k = k + 1) updm(8'hB0 + k, 16'hFFFF);
		uq_sync;
		n0 = ev_rd;
		wr(B(20'h70088), 16'h0002);
		wr(B(20'h7008C), 16'hAAAA);
		wr(B(20'h7008C), 16'hBBBB);
		wr(B(20'h70088), 16'h0003);
		rd(B(20'h7008C), v); check(v == 16'hBBBB, "C.HMEM: rdata writes auto-increment HAddr");
		wr(B(20'h70088), 16'h0002);
		rd(B(20'h7008C), v); check(v == 16'hAAAA, "C.HMEM: read returns HMEM[HAddr]");
		ev_next(e);   // raddr write
		ev_next(e);   check(e[27:24] == 4'd2 && e[47:32] == 16'hAAAA && e[0] == 0,
		                    "C.event: rdata write carries HADDR 2 and its data");
		ev_next(e);   check(e[27:24] == 4'd3, "C.event: the next rdata write carries HADDR 3");
		ev_drain;

		// --- D: event entries: fields, SEQ and EV_WPTR
		n0 = ev_rd;
		bus(B(20'h50004), 0, 16'h00A5, 0, 1, q);     // L64111 reg 2, LDS only
		ev_next(e);
		check(e[63:48] == n0[15:0], "D.event SEQ is the entry's index");
		check(e[23:4] == 20'h50004, "D.event board offset");
		check(e[0] == 0 && e[1] == 0 && e[2] == 1, "D.event RW, UDS, LDS");
		check(e[47:32] == 16'h00A5, "D.event write data");
		check(mem[EV_WPTR >> 3][31:0] == ev_rd, "D.EV_WPTR counts the entries written");
		wr(B(20'h60000), 16'h1234);                   // CMEM: write-only, posted
		ev_next(e); check(e[23:4] == 20'h60000 && e[47:32] == 16'h1234, "D.data port write posted");
		rd(B(20'h60000), v); check(v == 16'hFFFF, "D.data port reads 0xFFFF");
		ev_drain;

		// --- E: the CL450 INT is ~HOST_control[7]; the host's ack is immediate
		updm(8'h48, 16'hC080);
		upd(8'h48, 16'h0080, 16'hFFFF);
		uq_sync;
		check(!int2, "E.INT inactive while Int = 1");
		upd(8'h48, 16'h0000, 16'h0080);              // the chip asserts INT
		uq_sync;
		check(int2, "E.INT asserted when Main clears Int");
		wr(B(20'h70090), 16'h0080);                  // the host acknowledges
		check(!int2, "E.the 68k's Int write drops INT without Main");
		ev_drain;

		// --- F: the L64111 latch, its read acknowledge and the guard
		uq_entry(8'hC1, 0, 1, 1, 1, ev_rd, 0);       // guarded raise, made now
		uq_sync;
		check(int2, "F.guarded raise applied");
		rd(B(20'h5000A), v);                         // status 2: the acknowledge
		check(!int2, "F.reading status 2 deasserts INTR at once");
		ev_drain;
		n0 = ev_rd - 1;                              // the acknowledging read
		uq_entry(8'hC1, 0, 1, 1, 1, n0, 0);          // made before Main saw it
		uq_sync;
		check(!int2, "F.guard drops a raise made before the ack");
		uq_entry(8'hC1, 0, 1, 1, 1, n0 + 1, 0);      // made after
		uq_sync;
		check(int2, "F.guard applies a raise made after the ack");
		rd(B(20'h50008), v);                         // status 1 acks too
		check(!int2, "F.reading status 1 deasserts INTR");
		ev_drain;

		// --- G: the IO word mirrors the interrupt lines
		upd(8'hC4, 16'h8000, 16'hFFFF);
		upd(8'hC5, 16'h4000, 16'hFFFF);
		upd(8'hC6, 16'h0000, 16'hFFFF);              // active low
		upd(8'hA0, 16'h0400, 16'hFFFF);
		upd(8'h48, 16'h0000, 16'h0080);              // CL450 INT asserted
		uq_sync;
		rd(B(20'h40000), v);
		check(v == 16'h4400, "G.IO: CL450 bit low while asserted, L64111 bit high");
		wr(B(20'h70090), 16'h0080);
		rd(B(20'h47FFE), v);
		check(v == 16'hC400, "G.IO: both high once acknowledged (and mirrored)");
		ev_drain;

		// --- H: ROM and RAM from the DDR3 image, in 68k byte order
		set_mbyte(21'h00010, 8'h12); set_mbyte(21'h00011, 8'h34);
		set_mbyte(21'h00016, 8'hAB); set_mbyte(21'h00017, 8'hCD);
		rd(B(20'h00010), v); check(v == 16'h1234, "H.ROM: word = {byte o, byte o+1}");
		rd(B(20'h00016), v); check(v == 16'hABCD, "H.ROM: lane 3 of the DDR3 word");
		n0 = ev_rd;
		wr(B(20'h00010), 16'h5555);
		check(mbyte(21'h00010) == 8'h12, "H.ROM: a write is dropped");
		ev_next(e); check(e[23:4] == 20'h00010 && e[0] == 0, "H.ROM: the dropped write is posted");
		wr(B(20'h80100), 16'h1122);
		check(mbyte(21'h80100) == 8'h11 && mbyte(21'h80101) == 8'h22, "H.RAM: word write in 68k order");
		bus(B(20'h80100), 0, 16'h9900, 1, 0, q);     // UDS only
		check(mbyte(21'h80100) == 8'h99 && mbyte(21'h80101) == 8'h22, "H.RAM: UDS writes byte o only");
		bus(B(20'h80100), 0, 16'h0077, 0, 1, q);     // LDS only
		check(mbyte(21'h80100) == 8'h99 && mbyte(21'h80101) == 8'h77, "H.RAM: LDS writes byte o+1 only");
		rd(B(20'h80100), v); check(v == 16'h9977, "H.RAM: read back");
		check(mem[EV_WPTR >> 3][31:0] == ev_rd, "H.RAM and ROM reads post no events");

		// --- J: an update whose SEQ has not landed is waited for
		ev_drain;
		uq_entry(8'h80 + 8'd1, 0, 0, 16'h00AA, 16'h00FF, ev_rd, 1);   // bad SEQ
		updm(8'h81, 16'h00FF);
		repeat (2000) @(posedge clk_sys);
		check(mem[UQ_RDPTR >> 3][31:0] == uq_wr - 2, "J.not applied while its SEQ lags");
		mem[(UQ >> 3) + 2 * ((uq_wr - 2) & 1023)][63:48] = uq_wr[15:0] - 16'd2;  // now it lands
		uq_sync;
		rd(B(20'h50002), v); check(v == 16'h00AA, "J.applied once it lands, in order");
		ev_drain;

		// --- I: back-pressure on HOST_RDIDX's low half
		upd(8'hC2, ev_rd[15:0], 16'hFFFF);
		upd(8'hC3, ev_rd[31:16], 16'hFFFF);
		uq_sync;
		n0 = ev_rd;
		for (k = 0; k < 4095; k = k + 1)
			wr(B(20'h60000), k);
		check(bus_cycles < 1000, "I.4095 accesses fit the ring");
		fork
			begin
				wr(B(20'h60000), 16'hFFFF);           // the 4096th must wait
			end
			begin
				repeat (3000) @(posedge clk_sys);
				check(nrdy, "I.the 68k is held while the ring is full");
				upd(8'hC2, n0[15:0] + 16'd100, 16'hFFFF);   // Main drained 100
			end
		join
		check(bus_cycles >= 3000, "I.released only once HOST_RDIDX moved");
		// ...and by that update, not by the bus task giving up (200000
		// cycles). The update that releases the hold arrives through the
		// update queue; the first version applied updates only while no
		// access was pending, so a held access blocked its own release and
		// the 68k hung for good (gate 1 run v20, 2026-11-04: PC 203cfe, the
		// read of HOST_newcmd, fmv_bus IDLE, up_full 1). This check passed
		// then because the bus task timed out and dropped AS.
		check(bus_cycles < 20000, "I.released by the HOST_RDIDX update while the access is held");
		ev_rd = mem[EV_WPTR >> 3][31:0];             // the host skips ahead

		// --- K: an Amiga reset is an event, and the register file survives it
		n0 = ev_rd;
		amiga_reset = 1; repeat (10) @(posedge clk_sys); amiga_reset = 0;
		ev_next(e);
		check(e[3] && e[23:4] == 0, "K.RESET event posted");
		rd(B(20'h70022), v); check(v == 16'hBEEF, "K.register file kept across the reset");
		check(ac_present, "K.ALIVE kept across the reset");

		// --- L: off means off
		fmv_on = 0;
		@(posedge clk_sys);
		check(!ac_present, "L.off: not in the chain");
		cpu_addr = B(20'h70022); cpu_rw = 1; as_n = 0; uds_n = 0; lds_n = 0;
		repeat (4) @(posedge clk_sys);
		check(!nrdy && cpu_din == 16'h0000, "L.off: accesses are not answered");
		as_n = 1; uds_n = 1; lds_n = 1;

		// --- M: a session starts from zero (contract v4). The hardware
		// failure of 2026-11-02: the window held another session's
		// pointers, Main and the core disagreed on where the queue was, and
		// ALIVE never landed. Off, the core leaves DDR3 alone and its
		// counters fall to 0; Main zeroes the pointers and queues from 0.
		repeat (40) @(posedge clk_ddr);          // in-flight transfers finish
		count_off = 1;
		repeat (3000) @(posedge clk_ddr);
		count_off = 0;
		check(off_xfers == 0, "M.off: no DDR3 traffic (no queue polls)");
		uq_wr = 0; ev_rd = 0;
		mem[EV_WPTR >> 3] = 0; mem[UQ_RDPTR >> 3] = 0; mem[UQ_WPTR >> 3] = 0;
		upd(8'hC0, 1, 1);                        // ALIVE, entry 0, SEQ 0
		fmv_on = 1;
		repeat (4) @(posedge clk_sys);
		check(!ac_present, "M.on: ALIVE does not survive an off");
		uq_sync;
		check(mem[UQ_RDPTR >> 3][31:0] == 1, "M.on: the queue is read from entry 0");
		check(ac_present, "M.on: the new session's ALIVE lands");
		wr(B(20'h70022), 16'h4321);
		check(bus_cycles < 1000, "M.on: back-pressure counts from 0 again");
		ev_next(e);
		check(e[63:48] == 16'd0 && e[23:4] == 20'h70022, "M.on: the first event is entry 0, SEQ 0");
		check(mem[EV_WPTR >> 3][31:0] == 1, "M.on: EV_WPTR counts from 0");

		// --- N: the display registers (contract v5) through the queue, with
		// the mask, and nothing past 0xE6
		upd(8'hE0, 16'h0015, 16'hFFFF);
		upd(8'hE1, 16'h00AA, 16'hFFFF);
		upd(8'hE2, 16'h0033, 16'hFFFF);
		upd(8'hE3, 16'h0160, 16'hFFFF);
		upd(8'hE4, 16'h0120, 16'hFFFF);
		upd(8'hE5, 16'h1234, 16'hFFFF);
		upd(8'hE6, 16'h0056, 16'hFFFF);
		upd(8'hE5, 16'hFF00, 16'h0F00);          // masked: only bits 11:8
		upd(8'hE7, 16'hFFFF, 16'hFFFF);          // reserved: lands nowhere
		uq_sync;
		check(dut.disp == {16'h0056, 16'h1F34, 16'h0120, 16'h0160, 16'h0033, 16'h00AA, 16'h0015},
		      "N.display registers 0xE0-0xE6 through the queue, masked");

		// --- P: the perf window (fmv_bus perf, the diag word from 0xF403):
		// accesses counted exactly, and each hold in its own counter
		while (dut.bus.pw_t != 0) @(posedge clk_sys);
		repeat (5) @(posedge clk_sys);
		for (k = 0; k < 6; k = k + 1) wr(B(20'h70022), 16'h1111);
		rd(B(20'h00010), v);                     // ROM: a DDR3 trip
		fork
			wr(B(20'h70022), 16'h2222);          // held for the ring ...
			begin
				@(posedge clk_sys); @(posedge clk_sys);
				force dut.bus.ring_full = 1'b1;
				repeat (300) @(posedge clk_sys);
				release dut.bus.ring_full;
			end
		join
		fork
			wr(B(20'h70022), 16'h3333);          // ... and for the FIFO
			begin
				@(posedge clk_sys); @(posedge clk_sys);
				force dut.bus.ev_full = 1'b1;
				repeat (200) @(posedge clk_sys);
				release dut.bus.ev_full;
			end
		join
		while (dut.bus.pw_t != 2) @(posedge clk_sys);
		check(dut.bus.perf[16:0] == 9, "P.accesses in the window, exactly");
		// {mem, ring, fifo, held, accesses} from bit 0 up, 17 bits each
		check(dut.bus.perf[67:51] >= 290 && dut.bus.perf[67:51] <= 300, "P.held for the ring: its own counter");
		check(dut.bus.perf[50:34] >= 190 && dut.bus.perf[50:34] <= 200, "P.held for the event FIFO: its own counter");
		check(dut.bus.perf[84:68] > 0, "P.a ROM read's DDR3 trip counted");
		check(dut.bus.perf[33:17] >= dut.bus.perf[50:34] + dut.bus.perf[67:51] + dut.bus.perf[84:68],
		      "P.held covers every hold");
		ev_drain;

		$display("%0d checks, %0d failed", checks, fails);
		if (fails == 0) $display("RUN: PASS"); else $display("RUN: FAIL");
		$finish;
	end

	initial begin
		// The passing run takes about 8.3 ms of simulated time; a mutation that
		// hangs gives up here instead of running for minutes.
		#50_000_000;
		$display("FAIL timeout");
		$display("RUN: FAIL");
		$finish;
	end
endmodule
