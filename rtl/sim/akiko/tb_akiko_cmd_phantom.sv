// SPDX-License-Identifier: GPL-3.0-or-later
//
// The command channel, and what a read burst does when no command is ready.
//
// AKIKO_STATUS_REQ is a level. The host samples it into a status word and acts
// on it later, so it can start a read burst for a command that has already
// been drained -- a phantom. The burst pulses cmd_pop and cmd_done all the
// same.
//
// If the engine honours either one while cmd_pending is low it throws away a
// command the Amiga is in the middle of writing: the bytes already delivered
// are dropped, the rest land at offset 0, and the host's next read returns a
// frame that begins in the middle of the old one. That stray leading byte is
// what desynchronised the CD32 BIOS on hardware -- its INFO command ("27 d8")
// arrived behind one, was swallowed by the frame in front of it, never got an
// answer, and the BIOS stopped talking. The game then ran on without ever
// loading its data file and hung in its own loader.
//
// The rule this bench holds the engine to: consume a command only when there
// is a whole one to consume.

`timescale 1ns / 1ps

module tb_akiko_cmd_phantom;

initial begin
	#5000000 $fatal(1, "tb_akiko_cmd_phantom: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic reset = 1;

logic        uio_cs  = 0;
logic        uio_wr  = 0;
logic        uio_rd  = 0;
logic [15:0] uio_din = 0;

// CPU-side register bus, for CONFIG and the tx completion index.
logic        cs   = 0;
logic        wr   = 0;
logic        lds  = 0;
logic        uds  = 0;
logic [5:1]  addr = 0;
logic [15:0] din  = 0;
logic        rd   = 0;

wire        cmd_pending_w;
wire [7:0]  cmd_byte_w;
wire        cmd_pop_w;
wire        cmd_done_w;
wire [7:0]  uio_dout_w;
wire        req_w;

wire        dma_req_w;
wire        dma_we_w;
wire [23:0] dma_baddr_w;
wire [7:0]  dma_wbyte_w;
logic [7:0] dma_rbyte = 8'h00;
logic       dma_ack   = 0;
logic       dma_arm   = 0;

akiko #(.NATIVE_CD32(1)) u_dut (
	.clk(clk), .reset(reset),
	.cs(cs), .rd(rd), .wr(wr),
	.lds(lds), .uds(uds),
	.addr(addr), .din(din), .dout(),
	.akiko_irq(),
	.dma_req(dma_req_w), .dma_we(dma_we_w),
	.dma_baddr(dma_baddr_w), .dma_wbyte(dma_wbyte_w),
	.dma_rbyte(dma_rbyte), .dma_ack(dma_ack), .dma_arm(dma_arm),
	.hps_cmd_pending(cmd_pending_w), .hps_cmd_byte(cmd_byte_w),
	.hps_cmd_pop(cmd_pop_w), .hps_cmd_done(cmd_done_w),
	.hps_result_push(1'b0), .hps_result_byte(8'h00), .hps_result_done(1'b0),
	.hps_sec_req(), .hps_sec_status(),
	.hps_sec_push(1'b0), .hps_sec_word(16'h0), .hps_sec_done(1'b0),
	.hps_rx_busy(),
	.hps_nvr_addr(10'd0),
	.hps_nvr_dout(), .hps_nvr_clear_dirty(1'b0), .hps_nvr_dirty(),
	.nvr_load_addr(10'd0), .nvr_load_din(8'h00), .nvr_load_we(1'b0),
	.hps_subcode_push(1'b0), .hps_subcode_byte(8'h00), .hps_subcode_done(1'b0)
);

akiko_hps_bridge u_bridge (
	.clk(clk), .reset(reset),
	.uio_cs(uio_cs), .uio_cs_sec(1'b0),
	.uio_cs_nvr(1'b0), .uio_cs_subcode(1'b0),
	.uio_wr(uio_wr), .uio_rd(uio_rd),
	.uio_din(uio_din), .uio_dout(uio_dout_w),
	.cmd_pending(cmd_pending_w), .cmd_byte(cmd_byte_w),
	.cmd_pop(cmd_pop_w), .cmd_done(cmd_done_w),
	.result_push(), .result_byte(), .result_done(),
	.sec_req(1'b0), .sec_status(8'h00),
	.sec_push(), .sec_word(), .sec_done(),
	.subcode_push(), .subcode_byte(), .subcode_done(),
	.nvr_addr(), .nvr_dout(8'h00),
	.nvr_load_din(), .nvr_load_we(),
	.nvr_clear_dirty(), .nvr_done(),
	.nvr_dirty(1'b0), .nvr_dirty_out(),
	.rx_busy(1'b0),
	.req(req_w), .sec_req_out(), .rx_busy_out()
);

int checks = 0;
int errs   = 0;

task automatic check8(string name, logic [7:0] expected, logic [7:0] actual);
begin
	checks++;
	if (expected !== actual) begin
		errs++;
		$display("FAIL %s: expected 0x%02x got 0x%02x", name, expected, actual);
	end else $display("ok   %s = 0x%02x", name, actual);
end
endtask

task automatic check_bit(string name, logic expected, logic actual);
begin
	checks++;
	if (expected !== actual) begin
		errs++;
		$display("FAIL %s: expected %0b got %0b", name, expected, actual);
	end else $display("ok   %s = %0b", name, actual);
end
endtask

// Chip RAM the command stream is DMAed out of.
logic [7:0] mem [65536];
logic       in_xfer = 1'b0;

initial for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

always @(posedge clk) begin
	dma_ack <= 0;
	dma_arm <= 0;
	if (in_xfer) begin
		if (!dma_we_w) dma_rbyte <= mem[dma_baddr_w[15:0]];
		dma_ack <= 1'b1;
		in_xfer <= 1'b0;
	end else if (dma_req_w && !dma_ack) begin
		in_xfer <= 1'b1;
		dma_arm <= 1'b1;
	end
end

task automatic bus_write_word(input [5:1] a, input [15:0] data);
	@(posedge clk);
	cs <= 1; wr <= 1; rd <= 0; addr <= a; din <= data; lds <= 1; uds <= 1;
	@(posedge clk);
	cs <= 0; wr <= 0; addr <= 0; din <= 0; lds <= 0; uds <= 0;
endtask

task automatic bus_write_long(input [5:1] a_hi, input [31:0] data);
	bus_write_word(a_hi,        data[31:16]);
	bus_write_word(a_hi + 5'd1, data[15:0]);
endtask

task automatic set_misc_base(input [23:0] base);
	bus_write_long(5'b01010, {8'h00, base});
endtask

task automatic set_config(input [31:0] flags);
	bus_write_long(5'b10010, flags);
endtask

// cdcomtxcmp, low byte.
task automatic write_txcmp(input [7:0] v);
	@(posedge clk);
	cs <= 1; wr <= 1; rd <= 0; addr <= 5'b01110; din <= {8'h0, v}; lds <= 1; uds <= 0;
	@(posedge clk);
	cs <= 0; wr <= 0; addr <= 0; din <= 0; lds <= 0; uds <= 0;
endtask

// One host read burst: what the poll loop issues when it believes a command
// is waiting.
task automatic host_read_burst(input int bytes);
	logic [7:0] b;
begin
	@(posedge clk);
	uio_cs <= 1'b1;
	@(posedge clk);
	for (int i = 0; i < bytes; i++) begin
		b = uio_dout_w;
		uio_rd <= 1'b1;
		@(posedge clk);
		uio_rd <= 1'b0;
		@(posedge clk);
	end
	uio_cs <= 1'b0;
	@(posedge clk);
	@(posedge clk);
end
endtask

localparam [31:0] CFG_TXD = 32'h40000000;

int cyc;

initial begin
	$display("tb_akiko_cmd_phantom starting");
	repeat (4) @(posedge clk);
	reset = 0;
	repeat (4) @(posedge clk);

	bus_write_long(5'b00100, 32'hFF000000);   // interrupt enables
	set_misc_base(24'h030000);                // stream at base|0x200

	// A thirteen-byte MULTI, the longest command the BIOS sends.
	mem[16'h0200] = 8'h04;
	for (int i = 1; i <= 11; i++) mem[16'h0200 + i] = 8'hC0 + i[7:0];
	mem[16'h020C] = 8'hAA;

	set_config(CFG_TXD);

	// Six bytes in. Not a whole command, so nothing is pending.
	write_txcmp(8'd6);
	cyc = 0;
	while (u_dut.g_cd.cdrom_command_length != 6'd6 && cyc < 3000) begin
		@(posedge clk); cyc = cyc + 1;
	end
	check8   ("partial_len", 8'd6, {2'h0, u_dut.g_cd.cdrom_command_length});
	check_bit("not_pending", 1'b0, cmd_pending_w);
	check_bit("req_low",     1'b0, req_w);

	// The host drains anyway, on a REQ that is no longer true.
	host_read_burst(2);

	// Nothing may have been consumed.
	check8("len_survives_phantom", 8'd6, {2'h0, u_dut.g_cd.cdrom_command_length});

	// The rest arrives.
	write_txcmp(8'd13);
	cyc = 0;
	while (!cmd_pending_w && cyc < 6000) begin
		@(posedge clk); cyc = cyc + 1;
	end
	check_bit("pending_after_rest", 1'b1, cmd_pending_w);
	check8   ("full_len", 8'd13, {2'h0, u_dut.g_cd.cdrom_command_length});

	// Whole and in order, starting at its first byte -- not wherever the
	// phantom left the write pointer.
	check8("buf[0]",  8'h04, u_dut.g_cd.cdrom_command_buffer[0]);
	check8("buf[1]",  8'hC1, u_dut.g_cd.cdrom_command_buffer[1]);
	check8("buf[6]",  8'hC6, u_dut.g_cd.cdrom_command_buffer[6]);
	check8("buf[12]", 8'hAA, u_dut.g_cd.cdrom_command_buffer[12]);

	$display("------------------------------------");
	$display("checks=%0d errors=%0d", checks, errs);
	if (errs == 0) $display("tb_akiko_cmd_phantom PASS");
	else           $display("tb_akiko_cmd_phantom FAIL");
	$finish(errs == 0 ? 0 : 1);
end

endmodule
