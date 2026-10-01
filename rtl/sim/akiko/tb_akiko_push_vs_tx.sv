// A host response push must not corrupt a command fetch that is in flight.
//
// Measured on hardware 2026-10-01: the first boot after a core flash fails,
// deterministically, and what ends it is a corrupted command frame. Every
// corrupted frame in the trace is immediately preceded by a host push --
// clearest instance, the same 13-byte command that appears correctly elsewhere
// as
//
//   CMD op=0x04 n=13 bytes=84 00 00 00 00 00 00 03 00 00 00 00 78
//
// arriving, directly after "media-status push: opcode=0x0a status=0x01", as
//
//   CHECKSUM FAIL n=13 expected=13 sum=47 bytes=44 00 00 00 00 00 00 03 00 00 00 00 00
//
// Userspace already gates its pushes on hps_rx_busy, and that cannot help:
// hps_rx_busy is (cdrom_receive_length != 0), which answers "is a response
// already queued", not "is the guest mid-command". The host cannot see the
// latter at all.
//
// The suspected mechanism is the arbiter. tx_can_start refuses to start while
// rx_busy, and the TX arm in the always block checks !rx_busy && !pbx_busy --
// but rx_can_start checks neither tx_busy nor pbx_busy, so a host push
// (hps_result_done -> cdrom_receive_length != 0) can raise rx_busy while a TX
// byte fetch is outstanding. RX then wins the DMA address mux and the ack,
// and the byte the command buffer stores is whatever RX addressed.
//
// akiko.v says this hazard out loud for the subcode engine -- "chipdma_arb
// latches the live akiko DMA address at arm_now and acks ~5 cycles later, so a
// higher-priority engine asserting inside that window would steal subcode's
// ack (and corrupt its own progress)" -- and runs subcode strictly
// non-overlapping because of it. TX never got the same protection. PBX does not
// need it: the comment at the rx_inflight handshake notes PBX "safely re-runs
// the displaced byte (idempotent write of same data)". A TX fetch is not
// idempotent in effect, because the byte it loses lands in the command buffer.
//
// Test B is the race. It is written to fail on the RTL as it stands.

`timescale 1ns / 1ps

module tb_akiko_push_vs_tx;

initial begin
	#8000000 $fatal(1, "tb_akiko_push_vs_tx: watchdog timeout");
end

logic clk = 0;
initial forever #5 clk = ~clk;

logic        reset = 1;
logic        cs    = 0;
logic        rd    = 0;
logic        wr    = 0;
logic        lds   = 0;
logic        uds   = 0;
logic [5:1]  addr  = 0;
logic [15:0] din   = 0;
wire  [15:0] dout;
wire         irq;

wire        dma_req;
wire        dma_we;
wire [23:0] dma_baddr;
wire  [7:0] dma_wbyte;
logic [7:0] dma_rbyte;
logic       dma_ack;
logic       dma_arm;

// Driven, not tied off: this bench needs a real host push.
logic       hps_result_push = 1'b0;
logic [7:0] hps_result_byte = 8'h00;
logic       hps_result_done = 1'b0;
wire        hps_rx_busy;

akiko #(.NATIVE_CD32(1)) u_dut (
	.clk(clk), .reset(reset),
	.cs(cs), .rd(rd), .wr(wr),
	.lds(lds), .uds(uds),
	.addr(addr), .din(din), .dout(dout),
	.akiko_irq(irq),
	.dma_req(dma_req), .dma_we(dma_we),
	.dma_baddr(dma_baddr), .dma_wbyte(dma_wbyte),
	.dma_rbyte(dma_rbyte), .dma_ack(dma_ack), .dma_arm(dma_arm),
	.hps_cmd_pending(), .hps_cmd_byte(),
	.hps_cmd_pop(1'b0), .hps_cmd_done(1'b0),
	.hps_result_push(hps_result_push),
	.hps_result_byte(hps_result_byte),
	.hps_result_done(hps_result_done),
	.hps_sec_req(), .hps_sec_status(),
	.hps_sec_push(1'b0), .hps_sec_word(16'h0000), .hps_sec_done(1'b0),
	.hps_rx_busy(hps_rx_busy),
	.hps_nvr_addr(10'd0),
	.hps_nvr_dout(), .hps_nvr_clear_dirty(1'b0), .hps_nvr_dirty(),
	.nvr_load_addr(10'd0), .nvr_load_din(8'h00), .nvr_load_we(1'b0),
	.hps_subcode_push(1'b0), .hps_subcode_byte(8'h00), .hps_subcode_done(1'b0),
	.ss_state(), .ss_ld(1'b0), .ss_ld_data(1052'd0), .ss_idle()
);

localparam [31:0] CFG_TXD = 32'h40000000;
localparam [31:0] CFG_RXD = 32'h20000000;

// The frame under test. Six bytes, all distinct and none 0x00, so a byte that
// arrives from the wrong address is named by its value rather than guessed at.
localparam [7:0] F0 = 8'h84;
localparam [7:0] F1 = 8'h11;
localparam [7:0] F2 = 8'h22;
localparam [7:0] F3 = 8'h33;
localparam [7:0] F4 = 8'h44;
localparam [7:0] F5 = 8'h78;

int checks = 0;
int errs   = 0;

// Ground truth for the whole run, not a sample at the end: the two engines must
// never both own the bus. Checking only the frame bytes would let a future
// change pass because the displaced byte happened to carry the right value,
// which is exactly how a check goes quietly vacuous.
int overlap_cycles = 0;
always @(posedge clk) begin
	if (!reset && u_dut.g_cd.tx_busy && u_dut.g_cd.rx_busy)
		overlap_cycles <= overlap_cycles + 1;
end

task automatic check8(string name, logic [7:0] expected, logic [7:0] actual);
	checks++;
	if (expected !== actual) begin
		$display("FAIL %s: expected 0x%02h got 0x%02h (t=%0t)", name, expected, actual, $time);
		errs++;
	end
endtask

task automatic check_bit(string name, logic expected, logic actual);
	checks++;
	if (expected !== actual) begin
		$display("FAIL %s: expected %0b got %0b (t=%0t)", name, expected, actual, $time);
		errs++;
	end
endtask

task automatic bus_write_word(input [5:1] a, input [15:0] data);
	@(posedge clk);
	cs <= 1; wr <= 1; rd <= 0; addr <= a; din <= data; lds <= 1; uds <= 1;
	@(posedge clk);
	cs <= 0; wr <= 0; addr <= 0; din <= 0; lds <= 0; uds <= 0;
endtask

task automatic bus_write_byte_lo(input [5:1] a, input [7:0] data);
	@(posedge clk);
	cs <= 1; wr <= 1; rd <= 0; addr <= a; din <= {8'h0, data}; lds <= 1; uds <= 0;
	@(posedge clk);
	cs <= 0; wr <= 0; addr <= 0; din <= 0; lds <= 0; uds <= 0;
endtask

task automatic bus_write_long(input [5:1] a_hi, input [31:0] data);
	bus_write_word(a_hi,        data[31:16]);
	bus_write_word(a_hi + 5'd1, data[15:0]);
endtask

logic [7:0] mem [65536];

int    bfm_extra_delay = 0;
int    bfm_delay_cnt   = 0;
logic  bfm_in_xfer     = 1'b0;

initial begin
	dma_ack   = 0;
	dma_arm   = 0;
	dma_rbyte = 8'h00;
	for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
end

// Same BFM as tb_akiko_txrx_dma: arm on the request edge, ack after the
// configured delay, which is what chipdma_arb does.
always @(posedge clk) begin
	dma_ack <= 0;
	dma_arm <= 0;
	if (bfm_in_xfer) begin
		if (bfm_delay_cnt != 0) begin
			bfm_delay_cnt <= bfm_delay_cnt - 1;
		end else begin
			if (dma_we) begin
				mem[dma_baddr[15:0]] <= dma_wbyte;
			end else begin
				dma_rbyte <= mem[dma_baddr[15:0]];
			end
			dma_ack     <= 1'b1;
			bfm_in_xfer <= 1'b0;
		end
	end else if (dma_req && !dma_ack) begin
		bfm_in_xfer   <= 1'b1;
		bfm_delay_cnt <= bfm_extra_delay;
		dma_arm       <= 1'b1;
	end
end

task automatic do_reset;
begin
	reset <= 1;
	@(posedge clk); @(posedge clk); @(posedge clk);
	reset <= 0;
	@(posedge clk);
end
endtask

task automatic set_misc_base(input [23:0] base);
	bus_write_long(5'b01010, {8'h00, base});
endtask

task automatic set_config(input [31:0] flags);
	bus_write_long(5'b10010, flags);
endtask

task automatic write_txcmp(input [7:0] v);
	bus_write_byte_lo(5'b01110, v);
endtask

task automatic write_rxcmp(input [7:0] v);
	bus_write_byte_lo(5'b01111, v);
endtask

task automatic wait_tx_done(input int max_cycles, output int cycles);
	int n;
begin
	n = 0;
	@(posedge clk);
	while ((u_dut.g_cd.tx_busy || u_dut.g_cd.cdcomtxinx != u_dut.g_cd.cdcomtxcmp)
	       && n < max_cycles) begin
		@(posedge clk);
		n = n + 1;
	end
	cycles = n;
end
endtask

// Put the six bytes where a TX fetch will find them and arm the engine.
task automatic stage_frame;
begin
	set_misc_base(24'h010000);
	mem[16'h0200] = F0;
	mem[16'h0201] = F1;
	mem[16'h0202] = F2;
	mem[16'h0203] = F3;
	mem[16'h0204] = F4;
	mem[16'h0205] = F5;
	u_dut.g_cd.cdrom_command_length = 6'd0;
	u_dut.g_cd.cdcomtxinx           = 8'd0;
	for (int i = 0; i < 8; i++) u_dut.g_cd.cdrom_command_buffer[i] = 8'h00;
end
endtask

task automatic check_frame(string tag);
begin
	check8({tag, ".cmd[0]"}, F0, u_dut.g_cd.cdrom_command_buffer[0]);
	check8({tag, ".cmd[1]"}, F1, u_dut.g_cd.cdrom_command_buffer[1]);
	check8({tag, ".cmd[2]"}, F2, u_dut.g_cd.cdrom_command_buffer[2]);
	check8({tag, ".cmd[3]"}, F3, u_dut.g_cd.cdrom_command_buffer[3]);
	check8({tag, ".cmd[4]"}, F4, u_dut.g_cd.cdrom_command_buffer[4]);
	check8({tag, ".cmd[5]"}, F5, u_dut.g_cd.cdrom_command_buffer[5]);
	check8({tag, ".txinx"},  8'd6, u_dut.g_cd.cdcomtxinx);
end
endtask

// Wait for a TX byte fetch to be genuinely outstanding: the engine owns the
// bus, has a request up, and the ack has not come back yet. Waiting on a
// condition rather than counting cycles, per rtl/sim/README.md -- a fixed
// repeat() here would drift with the BFM delay and silently stop testing the
// race.
task automatic wait_tx_fetch_inflight(input int max_cycles, output bit got);
	int n;
begin
	n = 0;
	got = 0;
	while (n < max_cycles && !got) begin
		@(posedge clk);
		n = n + 1;
		if (u_dut.g_cd.tx_busy && dma_req && !dma_we && !dma_ack) got = 1;
	end
end
endtask

// What userspace does when it commits a response: two bytes, then done.
task automatic host_push_response(input [7:0] b0, input [7:0] b1);
begin
	@(posedge clk);
	hps_result_push <= 1'b1; hps_result_byte <= b0;
	@(posedge clk);
	hps_result_byte <= b1;
	@(posedge clk);
	hps_result_push <= 1'b0; hps_result_byte <= 8'h00;
	hps_result_done <= 1'b1;
	@(posedge clk);
	hps_result_done <= 1'b0;
end
endtask

initial begin
	int  cyc;
	bit  inflight;

	$display("tb_akiko_push_vs_tx starting");
	@(posedge clk);
	do_reset();
	bus_write_long(5'b00100, 32'hFF000000);

	// ------------------------------------------------------------------
	// Test A: the control. The same fetch with no push anywhere near it.
	// If this ever fails the bench is broken, not the arbiter.
	// ------------------------------------------------------------------
	$display("--- A: command fetch, no host push ---");
	bfm_extra_delay = 6;
	stage_frame();
	set_config(CFG_TXD);
	write_txcmp(8'd6);
	wait_tx_done(8000, cyc);
	check_frame("A");
	$display("    A: fetch took %0d cycles, frame intact", cyc);

	// ------------------------------------------------------------------
	// Test B: the race. Identical fetch; a host response is committed
	// while one byte of it is outstanding on the DMA bus.
	//
	// RXD is enabled and rxcmp armed up front so the RX engine has
	// somewhere to go the moment it is kicked. It stays quiescent until
	// the push regardless, because rx_can_start also needs
	// cdrom_receive_length != 0 and only the commit sets that.
	// ------------------------------------------------------------------
	$display("--- B: host push lands mid command fetch ---");
	do_reset();
	bus_write_long(5'b00100, 32'hFF000000);
	bfm_extra_delay = 6;
	stage_frame();
	u_dut.g_cd.cdcomrxinx = 8'd0;
	set_config(CFG_TXD | CFG_RXD);
	write_rxcmp(8'd2);
	write_txcmp(8'd6);

	wait_tx_fetch_inflight(8000, inflight);
	check_bit("B.saw_inflight_fetch", 1'b1, inflight);
	host_push_response(8'h0a, 8'h01);

	wait_tx_done(8000, cyc);
	check_frame("B");
	$display("    B: fetch took %0d cycles", cyc);

	// ------------------------------------------------------------------
	// Test C: the response is deferred, not dropped. A fix that protects
	// the fetch by discarding the host's push would trade one bug for a
	// worse one -- the BIOS waits on that response forever.
	// ------------------------------------------------------------------
	$display("--- C: the pushed response still gets delivered ---");
	begin
		int n;
		n = 0;
		while (u_dut.g_cd.cdcomrxinx != 8'd2 && n < 8000) begin
			@(posedge clk);
			n = n + 1;
		end
		check8("C.rxinx", 8'd2, u_dut.g_cd.cdcomrxinx);
		check8("C.rx[0]", 8'h0a, mem[16'h0000]);
		check8("C.rx[1]", 8'h01, mem[16'h0001]);
		$display("    C: response delivered after %0d cycles", n);
	end

	// ------------------------------------------------------------------
	// Test D: the invariant, over every cycle of all three tests.
	// ------------------------------------------------------------------
	$display("--- D: TX and RX never both own the bus ---");
	checks++;
	if (overlap_cycles != 0) begin
		$display("FAIL D.tx_rx_overlap: both engines busy for %0d cycles", overlap_cycles);
		errs++;
	end else begin
		$display("    D: no overlap in any cycle of A, B or C");
	end

	$display("------------------------------------");
	$display("checks=%0d errors=%0d", checks, errs);
	if (errs == 0) $display("tb_akiko_push_vs_tx PASS");
	else           $display("tb_akiko_push_vs_tx FAIL");
	$finish;
end

endmodule
