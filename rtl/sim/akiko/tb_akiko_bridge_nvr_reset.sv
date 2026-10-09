// SPDX-License-Identifier: GPL-3.0-or-later
//
// akiko_hps_bridge: an NVRAM load must land where it is addressed while the
// CD32 is held in reset.
//
// The HPS loads the per-disc save on its first poll, which with the disc in
// the config at power-on is while the core is still in reset. The bridge's
// NVRAM address counter used to be cleared by that reset, so every byte of the
// load was written to address 0 and the BRAM kept its power-on image. This
// drives a full 1024-byte load, as akiko_ext_block_write sends it (512 16-bit
// words, low byte first), once with reset held and once without, and records
// every load_we the bridge produces into a model of the NVRAM.

`timescale 1ns / 1ps

module tb_akiko_bridge_nvr_reset;

initial begin
	#2000000 $fatal(1, "tb_akiko_bridge_nvr_reset: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic        reset      = 1;
logic        uio_cs     = 0;
logic        uio_cs_nvr = 0;
logic        uio_wr     = 0;
logic        uio_rd     = 0;
logic [15:0] uio_din    = 16'h0000;

wire  [9:0] nvr_addr;
wire  [7:0] nvr_load_din;
wire        nvr_load_we;

akiko_hps_bridge dut (
	.clk(clk), .reset(reset),
	.uio_cs(uio_cs), .uio_cs_sec(1'b0), .uio_cs_nvr(uio_cs_nvr), .uio_cs_subcode(1'b0),
	.uio_wr(uio_wr), .uio_rd(uio_rd), .uio_din(uio_din), .uio_dout(),
	.cmd_pending(1'b0), .cmd_byte(8'h00), .cmd_pop(), .cmd_done(),
	.result_push(), .result_byte(), .result_done(),
	.sec_req(1'b0), .sec_status(8'h00), .sec_push(), .sec_word(), .sec_done(),
	.subcode_push(), .subcode_byte(), .subcode_done(),
	.nvr_addr(nvr_addr), .nvr_dout(8'h00),
	.nvr_load_din(nvr_load_din), .nvr_load_we(nvr_load_we),
	.nvr_clear_dirty(), .nvr_done(), .nvr_dirty(1'b0), .nvr_dirty_out(),
	.rx_busy(1'b0),
	.req(), .sec_req_out(), .rx_busy_out()
);

// What akiko_nvram would hold: every load_we, at the address the bridge gives.
logic [7:0] mem [0:1023];
always @(posedge clk) if (nvr_load_we) mem[nvr_addr] <= nvr_load_din;

int checks = 0;
int errs   = 0;

function automatic [7:0] pattern(input int i, input int salt);
	pattern = 8'(i * 7 + salt) ^ 8'(i >> 3);
endfunction

// One UIO write transaction of the whole save, as hps_ext delivers it: cs and
// the sub-channel select rise together, then one strobe per 16-bit word with
// the data held for the following cycle (hi_nvr takes the high byte then).
task automatic load_all(input int salt);
	int w;
	@(posedge clk);
	uio_cs     <= 1;
	uio_cs_nvr <= 1;
	@(posedge clk);
	@(posedge clk);
	for (w = 0; w < 512; w++) begin
		uio_din <= {pattern(2*w + 1, salt), pattern(2*w, salt)};
		uio_wr  <= 1;
		@(posedge clk);
		uio_wr  <= 0;
		@(posedge clk);
		@(posedge clk);
	end
	uio_cs     <= 0;
	uio_cs_nvr <= 0;
	@(posedge clk);
	@(posedge clk);
endtask

task automatic check_all(input string what, input int salt);
	int i, bad;
	bad = 0;
	for (i = 0; i < 1024; i++) begin
		checks++;
		if (mem[i] !== pattern(i, salt)) begin
			if (bad < 4)
				$display("FAIL %s: mem[0x%03h] = %02h, want %02h", what, i, mem[i], pattern(i, salt));
			bad++;
			errs++;
		end
	end
	if (!bad) $display("PASS %s: all 1024 bytes where addressed", what);
endtask

initial begin
	int i;
	for (i = 0; i < 1024; i++) mem[i] = 8'h00;

	// Reset held throughout, which is the case that failed on hardware.
	reset = 1;
	repeat (4) @(posedge clk);
	load_all(3);
	check_all("load during reset", 3);

	// And the ordinary case, out of reset, with different data.
	reset = 0;
	repeat (4) @(posedge clk);
	load_all(11);
	check_all("load out of reset", 11);

	$display("==== tb_akiko_bridge_nvr_reset end: checks=%0d errs=%0d ====", checks, errs);
	if (errs == 0) $display("tb_akiko_bridge_nvr_reset PASS");
	$finish;
end

endmodule
