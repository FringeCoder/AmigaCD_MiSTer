// SPDX-License-Identifier: GPL-3.0-or-later
//
// tb_chipdma_read_stale -- does chipdma_arb capture THIS slot's chip RAM read,
// or one from an earlier slot?
//
// sdram_ctrl latches chipRD_dma at sdram_state 9, and only when the slot it is
// serving is both a CHIP slot and a DMA slot:
//
//     if(slot_type == CHIP) if(slot_is_dma)
//         if(sdram_state == 9) chipRD_dma <= ...
//
// chipdma_arb samples chipRD_dma unconditionally, four clk_sys cycles after its
// own arming edge:
//
//     if (slot_cnt == 3'd3) ak_rbyte_r <= ak_baddr0 ? chip_in_rd_dma[7:0] : ...
//
// There is no handshake between the two. The arb assumes the slot it armed is
// the slot sdram_ctrl served, and that state 9 has already happened by the time
// it looks. If that assumption ever fails, chipRD_dma still holds whatever the
// previous DMA slot left in it, and the arb hands that stale byte to Akiko
// along with an ack.
//
// Such a fault would be invisible on the sector path, which is writes, and
// would show only on the command path, which is the one read Akiko does -- as a
// byte from the wrong address, or as zero before any DMA read has happened at
// all. That is the shape of the Chuck Rock boot hang (a phantom two-zero-byte
// command frame), so whether this sampling point is sound is worth knowing
// either way.
//
// Method. Every SDRAM frame puts a different value on sd_data, so any byte the
// arb returns names the frame it came from. The bench separately records which
// frame sdram_ticket actually served as a DMA slot, and compares. A stale
// capture shows up as a byte from frame N-1 while the access was served in
// frame N.

`timescale 1ns / 1ps

module tb_chipdma_read_stale;

integer errs   = 0;
integer checks = 0;

// ---------------------------------------------------------------- clocks
//
// The real ratios: sysclk (clk_114) is four times clk_sys, and c_7m is a
// quarter of clk_sys, so one c_7m period is sixteen sysclk cycles -- exactly
// the 0..15 sdram_state frame. All three come off one PLL on hardware, so they
// are generated here from one counter rather than from independent always
// blocks, which is also what AmigaCD.sv warns about at its sdram_ctrl
// instance: a permanent one-cycle skew here is a permanent slot corruption.
reg sysclk = 0;
always #5 sysclk = ~sysclk;

reg [3:0] ckdiv = 0;
always @(posedge sysclk) ckdiv <= ckdiv + 4'd1;

wire clk_sys = ckdiv[1];
wire c_7m    = ckdiv[3];

reg reset_n = 0;
wire reset  = ~reset_n;

// ------------------------------------------------------- minimig chip port
//
// Idle means chip_in_dma and chip_in_rw both high (the arb's minimig_idle).
// Held idle except where a test deliberately takes the slot away.
reg [24:1] chip_in_addr = 0;
reg        chip_in_l    = 1;
reg        chip_in_u    = 1;
reg        chip_in_rw   = 1;
reg        chip_in_dma  = 1;
reg [15:0] chip_in_wr   = 0;

// -------------------------------------------------------- akiko DMA master
reg        ak_req   = 0;
reg        ak_we    = 0;
reg [23:0] ak_baddr = 0;
reg  [7:0] ak_wbyte = 0;
wire [7:0] ak_rbyte;
wire       ak_ack;
wire       ak_arm;

// ----------------------------------------------------------- arb -> sdram
wire [24:1] arb_chip_addr;
wire        arb_chip_l, arb_chip_u, arb_chip_rw, arb_chip_dma;
wire [15:0] arb_chip_wr;
wire        arb_chip_dma_slot;

wire [15:0] chipRD;
wire [15:0] chipRD_dma;
wire        sdram_ready;
wire [47:0] chip48;

// --------------------------------------------------------------- sdram bus
wire [12:0] sd_addr;
wire  [1:0] sd_ba;
wire        sd_cs, sd_we, sd_ras, sd_cas, sd_clk, sd_cke;
wire  [1:0] sd_dqm;
wire [15:0] sd_data;

// One value per frame, so a returned byte names its frame. frame_id advances
// on the first cycle of every frame, which is also the cycle sdram_ctrl's
// state-0 arbitration picks that frame's slot -- so the value on the bus for
// the whole of frame N is the value belonging to frame N.
reg [7:0] frame_id = 0;
always @(posedge sysclk) if (dut.sdram_state == 4'd0) frame_id <= frame_id + 8'd1;

function [15:0] frame_word(input [7:0] id);
	frame_word = {8'hC0 + id, 8'h0F + id};
endfunction

assign sd_data = frame_word(frame_id);

sdram_ctrl dut (
	.sysclk(sysclk), .c_7m(c_7m), .reset_n(reset_n),
	.cache_rst(1'b1), .cache_inhibit(1'b0),
	.cpu_cache_ctrl(4'b1111), .dcache_sw_en(1'b1),
	.sd_addr(sd_addr), .sd_ba(sd_ba), .sd_cs(sd_cs), .sd_we(sd_we),
	.sd_ras(sd_ras), .sd_cas(sd_cas), .sd_dqm(sd_dqm), .sd_data(sd_data),
	.sd_clk(sd_clk), .sd_cke(sd_cke),
	.chipAddr(arb_chip_addr), .chipL(arb_chip_l), .chipU(arb_chip_u),
	.chipRW(arb_chip_rw), .chipDMA(arb_chip_dma),
	.chip_dma_slot(arb_chip_dma_slot), .chipWR(arb_chip_wr),
	.chipRD(chipRD), .chipRD_dma(chipRD_dma), .chip48(chip48),
	.sdram_ready(sdram_ready),
	.cpuAddr(24'd0), .cpuCS(1'b0), .cpustate(2'b01),
	.cpuL(1'b1), .cpuU(1'b1), .cpuWR(16'h0), .cpuRD(), .ramready()
);

chipdma_arb arb (
	.clk(clk_sys), .reset(reset), .c_7m(c_7m),
	.chip_in_addr(chip_in_addr), .chip_in_l(chip_in_l), .chip_in_u(chip_in_u),
	.chip_in_rw(chip_in_rw), .chip_in_dma(chip_in_dma), .chip_in_wr(chip_in_wr),
	.akiko_dma_req(ak_req), .akiko_dma_we(ak_we),
	.akiko_dma_baddr(ak_baddr), .akiko_dma_wbyte(ak_wbyte),
	.akiko_dma_rbyte(ak_rbyte), .akiko_dma_ack(ak_ack), .akiko_arm(ak_arm),
	.cdtv_dma_req(1'b0), .cdtv_dma_we(1'b0),
	.cdtv_dma_baddr(32'd0), .cdtv_dma_wbyte(8'h00),
	.cdtv_dma_rbyte(), .cdtv_dma_ack(),
	.chip_out_addr(arb_chip_addr), .chip_out_l(arb_chip_l),
	.chip_out_u(arb_chip_u), .chip_out_rw(arb_chip_rw),
	.chip_out_dma(arb_chip_dma), .chip_out_wr(arb_chip_wr),
	.chip_in_rd(chipRD), .chip_dma_slot(arb_chip_dma_slot),
	.chip_in_rd_dma(chipRD_dma), .sdram_ready(sdram_ready),
	.cpu_chip_slot_req(1'b0),
	// No Zorro RAM, so memory_router always sends the slot to chip_out_*.
	.z2ram_ena(1'b0), .z3ram_base0(5'd0), .z3ram_ena0(1'b0),
	.z3ram_base1(4'd0), .z3ram_ena1(1'b0),
	.ddr_out_addr(), .ddr_out_l(), .ddr_out_u(), .ddr_out_we(),
	.ddr_out_cs(), .ddr_out_wr(), .ddr_in_ack(1'b0),
	.dma_hold(1'b0), .dma_busy(), .ddr_in_rd(16'h0)
);

// Which frame sdram_ctrl actually served as a DMA slot. Read one cycle into
// the frame, when slot_type and slot_is_dma have been registered.
localparam [2:0] SLOT_CHIP = 3'd1;

reg [7:0] dma_frame      = 8'hFF;   // last frame served as a chip DMA read
integer   dma_frame_seen = 0;

always @(posedge sysclk) begin
	if (dut.sdram_state == 4'd1 && dut.slot_type == SLOT_CHIP && dut.slot_is_dma
	    && arb_chip_rw) begin
		dma_frame      <= frame_id;
		dma_frame_seen <= dma_frame_seen + 1;
	end
end

// ------------------------------------------------------------------ helpers
task automatic check8(input [255:0] name, input [7:0] got, input [7:0] exp);
begin
	checks = checks + 1;
	if (got !== exp) begin
		errs = errs + 1;
		$display("FAIL %0s: got %02h exp %02h", name, got, exp);
	end else $display("ok   %0s = %02h", name, got);
end
endtask

// One Akiko byte read. Holds req until ack, as the real protocol does, then
// reports the byte and which frame sdram_ctrl served it from.
task automatic akiko_read(input [23:0] a, output [7:0] got, output [7:0] from_frame);
	integer guard;
begin
	@(posedge clk_sys);
	ak_baddr <= a;
	ak_we    <= 1'b0;
	ak_req   <= 1'b1;
	guard = 0;
	while (!ak_ack && guard < 400) begin
		@(posedge clk_sys);
		guard = guard + 1;
	end
	if (guard >= 400) begin
		errs = errs + 1;
		$display("FAIL akiko_read(%06h): no ack in 400 clk_sys", a);
	end
	got        = ak_rbyte;
	from_frame = dma_frame;
	ak_req     <= 1'b0;
	@(posedge clk_sys);
	@(posedge clk_sys);
end
endtask

// Wait up to `cycles` clk_sys for an ack without treating its absence as an
// error -- test E wants to assert that the ack does NOT come.
task automatic wait_ack(input int cycles, output logic acked);
	integer g;
begin
	acked = 1'b0;
	for (g = 0; g < cycles; g = g + 1) begin
		if (ak_ack) begin
			acked = 1'b1;
			g = cycles;
		end else @(posedge clk_sys);
	end
end
endtask

function [7:0] expect_byte(input [23:0] a, input [7:0] id);
	// The arb takes the low byte for an odd address, the high byte for an even
	// one: ak_baddr0 ? chip_in_rd_dma[7:0] : chip_in_rd_dma[15:8].
	// Through a temporary, because Icarus will not bit-select a call inline.
	reg [15:0] w;
	begin
		w = frame_word(id);
		expect_byte = a[0] ? w[7:0] : w[15:8];
	end
endfunction

// ------------------------------------------------------------------- tests
reg [7:0]  b, f, b2, f2;
logic      acked;
reg [23:0] ca;
integer   i;
integer   before_seen;

initial begin
	$display("tb_chipdma_read_stale starting");
	repeat (8) @(posedge sysclk);
	reset_n = 1;

	// sdram_ctrl runs its own power-up sequence and serves nothing until
	// init_done. Nothing gates the arb on it, which is a hole of its own --
	// see test E -- but every other test wants a working controller.
	wait (dut.init_done);
	repeat (32) @(posedge sysclk);

	// --- A: a single read, each byte lane -------------------------------
	$display("--- A: one read, both byte lanes");
	akiko_read(24'h001000, b, f);
	check8("A.even", b, expect_byte(24'h001000, f));
	akiko_read(24'h001001, b, f);
	check8("A.odd",  b, expect_byte(24'h001001, f));

	// --- B: back to back, different addresses ---------------------------
	//
	// The one that would catch a one-frame-stale capture: if the arb sampled
	// chipRD_dma before sdram_ctrl had updated it, the second read would
	// return the first read's frame.
	$display("--- B: back-to-back reads");
	akiko_read(24'h002000, b,  f);
	akiko_read(24'h003000, b2, f2);
	check8("B.first",  b,  expect_byte(24'h002000, f));
	check8("B.second", b2, expect_byte(24'h003000, f2));
	if (f == f2) begin
		errs = errs + 1;
		$display("FAIL B.frames: both reads served in frame %02h", f);
	end else $display("ok   B.frames = %02h then %02h", f, f2);

	// --- C: every arrival phase in the frame ----------------------------
	//
	// arm_now fires at a c_7m rising edge, and sdram_ctrl picks the slot at
	// its own state 0. Those are the same edge seen on two different clocks,
	// so if the two ever disagree it will depend on where in the frame the
	// request turned up. Sixteen sysclk offsets covers every position.
	$display("--- C: request arriving at each of 16 sysclk offsets");
	for (i = 0; i < 16; i = i + 1) begin
		@(posedge sysclk);
		wait (dut.sdram_state == 4'd0);
		repeat (i) @(posedge sysclk);
		ca = 24'h004000 + i;
		akiko_read(ca, b, f);
		if (b !== expect_byte(ca, f)) begin
			errs = errs + 1;
			$display("FAIL C.offset%0d: got %02h exp %02h (frame %02h)",
			         i, b, expect_byte(ca, f), f);
		end
		checks = checks + 1;
	end
	$display("ok   C: 16 offsets");

	// --- D: minimig taking the slot in between --------------------------
	//
	// When minimig uses the chip slot, sdram_ctrl serves a CHIP slot with
	// slot_is_dma low and leaves chipRD_dma alone. The arb must not be
	// holding a sample from across that gap: the Akiko read after it has to
	// come from its own frame, not from the last one before minimig cut in.
	$display("--- D: minimig slots in between");
	akiko_read(24'h005000, b, f);
	chip_in_addr <= 24'h006000 >> 1;
	chip_in_l    <= 0;
	chip_in_u    <= 0;
	chip_in_dma  <= 0;          // minimig claims the slot (active low)
	repeat (6) @(posedge c_7m);
	chip_in_dma  <= 1;
	chip_in_l    <= 1;
	chip_in_u    <= 1;
	repeat (2) @(posedge c_7m);
	akiko_read(24'h007000, b2, f2);
	check8("D.after_minimig", b2, expect_byte(24'h007000, f2));

	// --- E: a read issued before init_done ------------------------------
	//
	// sdram_ctrl serves no slots at all until its power-up sequence
	// finishes, so chipRD_dma is never written and a read armed in that
	// window used to be acked with whatever the register happened to hold --
	// with no slot served at all. Measured here before the fix: it returned
	// the previous test's byte.
	//
	// Two things to hold: no ack while the controller is not ready, and the
	// read still completes correctly once it is. The second half is the
	// point -- the master holds req until ack, so the transfer must be
	// deferred, not dropped.
	$display("--- E: a read issued before init_done");
	reset_n = 0;
	repeat (8) @(posedge sysclk);
	reset_n = 1;
	repeat (4) @(posedge sysclk);

	if (dut.init_done) begin
		errs = errs + 1;
		$display("FAIL E.setup: init_done already high, nothing to test");
	end else begin
		before_seen = dma_frame_seen;
		@(posedge clk_sys);
		ak_baddr <= 24'h008001;
		ak_we    <= 1'b0;
		ak_req   <= 1'b1;

		// Long enough to have armed several c_7m slots had it been willing.
		wait_ack(40, acked);
		checks = checks + 1;
		if (acked) begin
			errs = errs + 1;
			$display("FAIL E.no_early_ack: acked after %0d DMA slots served",
			         dma_frame_seen - before_seen);
		end else $display("ok   E.no_early_ack (still waiting, as it should)");

		// Now let the controller come up. The request is still asserted.
		wait (dut.init_done);
		repeat (4) @(posedge sysclk);
		wait_ack(400, acked);
		checks = checks + 1;
		if (!acked) begin
			errs = errs + 1;
			$display("FAIL E.deferred_ack: never acked after init_done");
		end else begin
			$display("ok   E.deferred_ack");
			check8("E.deferred_byte", ak_rbyte,
			       expect_byte(24'h008001, dma_frame));
		end
		ak_req <= 1'b0;
		@(posedge clk_sys);
	end

	$display("------------------------------------");
	$display("checks=%0d errors=%0d", checks, errs);
	if (errs == 0) $display("tb_chipdma_read_stale PASS");
	else           $display("tb_chipdma_read_stale FAIL");
	$finish(errs == 0 ? 0 : 1);
end

initial begin
	#40000000 $fatal(1, "tb_chipdma_read_stale: watchdog timeout");
end

endmodule
