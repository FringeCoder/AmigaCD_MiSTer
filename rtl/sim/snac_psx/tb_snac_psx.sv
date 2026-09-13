// SPDX-License-Identifier: GPL-3.0-or-later
//
// snac_psx: the PSX pad reader's flow control, glitch filter and axes gate.
//
// Why this bench exists: rtl/snac_psx.v's own header opens by saying "the
// testbench declares `timescale 1ns/1ns", and no such testbench was ever
// committed -- to this repository or to the core repositories that take a copy
// of the module. Three of the four commits that built the module are fixes to
// behaviour that only appears against a device with real timing:
//
//   e9999dc  read PSX pads on the SNAC user port
//   a6cfaeb  sync the ACK-aware reader, CLK_MHZ -> CLK_KHZ
//   fd54527  sync the ACK glitch filter
//   797d1c3  let a GunCon's coordinates through the axes gate
//
// Each of the last three is a regression this bench pins. The pad model below
// is the point: it answers on the real schedule (ACK arrives ~10 us after a
// byte's last clock edge and lasts ~2 us) rather than instantly, because a
// model that answers instantly is exactly what the free-running reader in
// e9999dc passed against and real hardware did not.

`timescale 1ns / 1ns

// ---------------------------------------------------------------------------
// A PSX device. Drives DAT on each falling bus-clock edge (the master samples
// on the rising edge) and pulses ACK after every byte except the last one of
// its frame -- which is how the master learns the frame is over.
// ---------------------------------------------------------------------------
module psx_pad (
	input            present,     // 0 = nothing plugged into this port
	input      [7:0] id,          // 0x41 digital, 0x73 DualShock, 0x63 GunCon
	input      [3:0] nbytes,      // bytes this device sends (5 digital, 9 analog)
	input      [7:0] d3, d4,      // button bytes, active low
	input      [7:0] d5, d6, d7, d8,  // axis bytes
	input            glitch_only, // emit a 20 ns spike instead of a real ACK
	input            att_n,
	input            sclk,
	output           dat,
	output           ack_n
);

integer byteidx, bitidx;
reg     datr, ackr;
reg [7:0] cur;
event   byte_done;

// Idle bus is pulled high; an absent device never drives either line.
assign dat   = (present && !att_n) ? datr : 1'b1;
assign ack_n = present ? ackr : 1'b1;

function [7:0] respbyte(input integer k);
	case (k)
		0: respbyte = 8'hFF;   // answered while the master sends 0x01
		1: respbyte = id;
		2: respbyte = 8'h5A;
		3: respbyte = d3;
		4: respbyte = d4;
		5: respbyte = d5;
		6: respbyte = d6;
		7: respbyte = d7;
		8: respbyte = d8;
		default: respbyte = 8'hFF;
	endcase
endfunction

initial begin
	datr = 1'b1; ackr = 1'b1; byteidx = 0; bitidx = 0; cur = 8'hFF;
end

always @(negedge att_n) begin
	byteidx = 0;
	bitidx  = 0;
	datr    = 1'b1;
end

// LSB first, presented on the falling edge so it is stable well before the
// master samples it on the rising edge.
always @(negedge sclk) if (!att_n && present) begin
	cur  = respbyte(byteidx);
	datr = cur[bitidx];
end

always @(posedge sclk) if (!att_n && present) begin
	if (bitidx == 7) begin
		bitidx  = 0;
		byteidx = byteidx + 1;
		// Ack every byte except the final one of the frame.
		if (byteidx < nbytes) -> byte_done;
	end
	else bitidx = bitidx + 1;
end

always @(byte_done) begin
	if (glitch_only) begin
		#10000 ackr = 1'b0;   // 20 ns spike: under ACK_FILTER_CYCLES (200 ns),
		#20    ackr = 1'b1;   // so the reader must not treat it as an ack
	end
	else begin
		#10000 ackr = 1'b0;   // real pads ack 10-20 us after the last edge
		#2000  ackr = 1'b1;   // for at least 2 us
	end
end

endmodule

// ---------------------------------------------------------------------------
module tb_snac_psx;

localparam integer CLK_KHZ = 50000;   // 50 MHz, 20 ns period

reg clk = 0;
always #10 clk = ~clk;

reg reset  = 1;
reg enable = 1;

wire [6:0] user_out;
wire [15:0] pad0, pad1;
wire [31:0] axes0, axes1;
wire [7:0]  id0, id1;

// Pad 0 and pad 1 controls, driven by the tests.
reg        p0_present = 0, p1_present = 0;
reg  [7:0] p0_id = 8'h41, p1_id = 8'h41;
reg  [3:0] p0_n  = 4'd5,  p1_n  = 4'd5;
reg  [7:0] p0_d3 = 8'hFF, p0_d4 = 8'hFF, p1_d3 = 8'hFF, p1_d4 = 8'hFF;
reg  [7:0] p0_d5 = 8'h80, p0_d6 = 8'h80, p0_d7 = 8'h80, p0_d8 = 8'h80;
reg        p0_glitch = 0;

// Pin map, from snac_psx.v's user_out assign: [5] CLK, [4] DAT, [3] ACK,
// [2] CMD, [1] ~ATT port 1, [0] ~ATT port 2.
wire sclk   = user_out[5];
wire att0_n = user_out[1];
wire att1_n = user_out[0];

wire dat0, ack0_n, dat1, ack1_n;

psx_pad pad_a (
	.present(p0_present), .id(p0_id), .nbytes(p0_n),
	.d3(p0_d3), .d4(p0_d4), .d5(p0_d5), .d6(p0_d6), .d7(p0_d7), .d8(p0_d8),
	.glitch_only(p0_glitch),
	.att_n(att0_n), .sclk(sclk), .dat(dat0), .ack_n(ack0_n)
);

psx_pad pad_b (
	.present(p1_present), .id(p1_id), .nbytes(p1_n),
	.d3(p1_d3), .d4(p1_d4), .d5(8'h80), .d6(8'h80), .d7(8'h80), .d8(8'h80),
	.glitch_only(1'b0),
	.att_n(att1_n), .sclk(sclk), .dat(dat1), .ack_n(ack1_n)
);

// Both devices share DAT and ACK; the unselected one is not driving, so a
// wired AND is the bus.
wire [6:0] user_in = { 2'b11, dat0 & dat1, ack0_n & ack1_n, 3'b111 };

snac_psx #(.CLK_KHZ(CLK_KHZ), .BAUD_KHZ(250)) dut (
	.clk(clk), .reset(reset), .enable(enable),
	.user_in(user_in), .user_out(user_out),
	.pad0(pad0), .pad1(pad1), .axes0(axes0), .axes1(axes1),
	.id0(id0), .id1(id1)
);

integer errors = 0;

task check8(input string what, input [7:0] got, input [7:0] want);
	begin
		if (got !== want) begin
			$display("FAIL %0s: got %02h want %02h", what, got, want);
			errors = errors + 1;
		end
	end
endtask

task check16(input string what, input [15:0] got, input [15:0] want);
	begin
		if (got !== want) begin
			$display("FAIL %0s: got %04h want %04h", what, got, want);
			errors = errors + 1;
		end
	end
endtask

task check32(input string what, input [31:0] got, input [31:0] want);
	begin
		if (got !== want) begin
			$display("FAIL %0s: got %08h want %08h", what, got, want);
			errors = errors + 1;
		end
	end
endtask

// Wait until the reader finishes a poll of the given port. ST_DONE is 3'd5.
task wait_poll(input integer which);
	integer guard;
	begin
		guard = 0;
		@(posedge clk);
		while (!(dut.state == 3'd5 && dut.port == which[0])) begin
			@(posedge clk);
			guard = guard + 1;
			if (guard > 2000000) begin
				$display("FAIL wait_poll(%0d): no poll completed", which);
				errors = errors + 1;
				disable wait_poll;
			end
		end
		@(posedge clk);
	end
endtask

// A poll is ATT setup + up to nine byte times + a ~1.3 ms inter-poll gap, so
// one port cycle is on the order of 1.6 ms and the eight tests below need tens
// of milliseconds. 200 ms is a stuck-simulation guard, not a tight bound.
initial begin
	#200000000 $fatal(1, "tb_snac_psx: watchdog timeout");
end

initial begin
	repeat (10) @(posedge clk);
	reset = 0;

	// --- 1. ATT setup time -------------------------------------------------
	// Real consoles allow 10-20 us between ATT falling and the first clock
	// edge. ATT_SETUP_US is 20; the 2 us that fell out of reusing HALF is what
	// this guards against coming back.
	begin : att_timing
		time t_att, t_edge;
		@(negedge att0_n);
		t_att = $time;
		@(negedge sclk);
		t_edge = $time;
		if ((t_edge - t_att) < 19000 || (t_edge - t_att) > 21000) begin
			$display("FAIL ATT setup: %0t ns from ATT low to first clock edge, want ~20000",
			         t_edge - t_att);
			errors = errors + 1;
		end
	end

	// --- 2. Nothing plugged in --------------------------------------------
	// An idle bus reads all ones, and 0xFF must report as absent rather than
	// as a device, with the sticks at centre rather than hard over.
	wait_poll(0);
	check8 ("absent id0",   id0,   8'h00);
	check16("absent pad0",  pad0,  16'h0000);
	check32("absent axes0", axes0, 32'h80808080);

	// --- 3. Digital pad, five-byte frame ----------------------------------
	// Buttons are active low. X is byte1 bit 6, so clearing it presses X.
	p0_present = 1; p0_id = 8'h41; p0_n = 4'd5;
	p0_d3 = 8'hFF; p0_d4 = 8'hBF;          // X pressed
	wait_poll(0);
	check8 ("digital id0",  id0,  8'h41);
	check16("digital pad0", pad0, 16'h0010);   // bit 4 = X
	// The gate that keeps a digital pad from reading as a stick held hard
	// over: only 0x73 and 0x63 carry axes, everything else stays centred.
	check32("digital axes0 centred", axes0, 32'h80808080);

	// --- 4. Port alternation ----------------------------------------------
	// Both ports share the bus and are selected by their own ATT, polled in
	// sequence. A pad on port 2 must not appear on port 1 or vice versa.
	p1_present = 1; p1_id = 8'h41; p1_n = 4'd5;
	p1_d3 = 8'hFE; p1_d4 = 8'hFF;          // SELECT pressed
	wait_poll(1);
	check8 ("port1 id1",  id1,  8'h41);
	check16("port1 pad1", pad1, 16'h0800);   // bit 11 = SELECT
	check16("port0 pad0 unchanged", pad0, 16'h0010);

	// --- 5. DualShock analog, nine-byte frame ------------------------------
	p0_id = 8'h73; p0_n = 4'd9;
	p0_d3 = 8'hFF; p0_d4 = 8'hFF;
	p0_d5 = 8'h12; p0_d6 = 8'h34; p0_d7 = 8'h56; p0_d8 = 8'h78;
	wait_poll(0);
	check8 ("analog id0",   id0,   8'h73);
	check32("analog axes0", axes0, 32'h78563412);   // {d8,d7,d6,d5}

	// --- 6. GunCon axes gate ----------------------------------------------
	// 797d1c3. A GunCon reports 0x63 and carries its X/Y coordinates in the
	// same four bytes a DualShock uses for sticks. Before that fix the gate
	// admitted only 0x73, so a GunCon's coordinates were replaced by centre
	// and the gun could not aim.
	p0_id = 8'h63;
	p0_d5 = 8'hAA; p0_d6 = 8'hBB; p0_d7 = 8'hCC; p0_d8 = 8'hDD;
	wait_poll(0);
	check8 ("guncon id0",   id0,   8'h63);
	check32("guncon axes0", axes0, 32'hDDCCBBAA);

	// --- 7. ACK glitch filter ---------------------------------------------
	// fd54527. A 20 ns spike on ACK is under the 200 ns filter window and must
	// not advance the frame. With only spikes and no real ack, the reader has
	// to time out after the first byte, so the tail stays at the 0xFF prefill
	// and the device reports absent -- not a half-read frame.
	p0_glitch = 1;
	p0_id = 8'h41; p0_n = 4'd5; p0_d3 = 8'hFF; p0_d4 = 8'hBF;
	wait_poll(0);
	check8 ("glitch rejected: id0 absent",  id0,  8'h00);
	check16("glitch rejected: pad0 clear",  pad0, 16'h0000);

	// --- 8. Unplug clears a held button ------------------------------------
	// Every branch of ST_DONE assigns a fresh value, so a button held at the
	// moment a pad is removed cannot stay latched.
	p0_glitch = 0;
	wait_poll(0);
	check16("replugged pad0", pad0, 16'h0010);
	p0_present = 0;
	wait_poll(0);
	check8 ("unplugged id0",  id0,  8'h00);
	check16("unplugged pad0", pad0, 16'h0000);

	if (errors == 0) $display("RUN: PASS");
	else             $display("RUN: FAIL (%0d)", errors);
	$finish;
end

endmodule
