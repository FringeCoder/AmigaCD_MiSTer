// What Gary puts on the custom data bus while the CPU reads.
//
// A CPU read of a custom register strobes the register address, so a read of a
// write-only register (INTREQ, INTENA, DMACON...) writes whatever is on the
// custom data bus. Gary used to drive $FFFF there, which set every bit of INTREQ
// on a TST.W $DFF09C -- including bit 14, a level 6 interrupt. The bus must
// carry the last value it held instead: the last CPU write or DMA transfer.
//
// A. a CPU read after a CPU write carries the written word
// B. a CPU read after a DMA read carries the word the DMA read
// C. a CPU read after a DMA write carries the word the DMA wrote
// D. the value holds for the whole read, whatever ram/custom outputs do
// E. never $FFFF unless $FFFF was the last value
// F. a CPU write still drives cpu_data_out; a DMA cycle still drives ram_data_out
`timescale 1ns/1ps
module tb_gary_strobe;

reg clk = 0;
always #5 clk = ~clk;

reg  [15:0] cpu_data_out = 0, custom_data_out = 0, ram_data_out = 0;
reg         cpu_rd = 0, cpu_hwr = 0, cpu_lwr = 0, dbr = 0, dbwe = 0;
wire [15:0] custom_data_in;

gary dut (
	.cpu_address_in(23'h6FF04E), // $DFF09C
	.dma_address_in(20'h0),
	.cpu_data_out(cpu_data_out),
	.custom_data_out(custom_data_out),
	.custom_data_in(custom_data_in),
	.ram_data_out(ram_data_out),
	.a1k(1'b0), .bootrom(1'b0), .clk(clk), .reset(1'b0),
	.cpu_rd(cpu_rd), .cpu_hwr(cpu_hwr), .cpu_lwr(cpu_lwr), .cpu_hlt(1'b0),
	.ovl(1'b0), .dbr(dbr), .dbwe(dbwe),
	.memory_config(4'h0), .ecs(1'b1), .hdc_ena(1'b0),
	.a2065_ena(1'b0), .a2065_base(8'h0), .toccata_ena(1'b0), .toccata_base(8'h0),
	.cdtv_base(8'h0), .cdtv_mode(1'b0), .ar_on(1'b0),
	.ss_rom_readonly_in(1'b0), .ss_rom_readonly_we(1'b0)
);

integer fails = 0, checks = 0;
task check(input [15:0] got, input [15:0] want, input [8*48-1:0] what);
	begin
		checks = checks + 1;
		if (got !== want) begin
			fails = fails + 1;
			$display("FAIL %0s: got %04x want %04x", what, got, want);
		end
	end
endtask

task idle; begin cpu_rd = 0; cpu_hwr = 0; cpu_lwr = 0; dbr = 0; dbwe = 0; end endtask

// Hold a CPU read for a few clocks while the other buses change, and check the
// strobe data every clock.
task cpu_read_expect(input [15:0] want, input [8*48-1:0] what);
	integer i;
	begin
		idle; cpu_rd = 1;
		for (i = 0; i < 4; i = i + 1) begin
			ram_data_out = $random; custom_data_out = $random; cpu_data_out = $random;
			@(negedge clk);
			check(custom_data_in, want, what);
			if (custom_data_in === 16'hFFFF && want !== 16'hFFFF)
				begin fails = fails + 1; $display("FAIL E: $FFFF on the bus during %0s", what); end
		end
		idle; @(negedge clk);
	end
endtask

initial begin
	@(negedge clk);

	// A
	cpu_data_out = 16'h0000; cpu_hwr = 1; cpu_lwr = 1;
	@(negedge clk);
	check(custom_data_in, 16'h0000, "F: CPU write drives cpu_data_out");
	idle;
	cpu_read_expect(16'h0000, "A: read after write $0000");

	cpu_data_out = 16'h1234; cpu_lwr = 1;
	@(negedge clk);
	idle;
	cpu_read_expect(16'h1234, "A: read after byte write $1234");

	// B
	dbr = 1; dbwe = 0; ram_data_out = 16'hBEEF;
	@(negedge clk);
	check(custom_data_in, 16'hBEEF, "F: DMA read drives ram_data_out");
	idle;
	cpu_read_expect(16'hBEEF, "B: read after DMA read $BEEF");

	// C
	dbr = 1; dbwe = 1; custom_data_out = 16'h4321;
	@(negedge clk);
	idle;
	cpu_read_expect(16'h4321, "C: read after DMA write $4321");

	// E: a genuine last value of $FFFF still goes through
	cpu_data_out = 16'hFFFF; cpu_hwr = 1; cpu_lwr = 1;
	@(negedge clk);
	idle;
	cpu_read_expect(16'hFFFF, "E: read after write $FFFF");

	$display("checks %0d, fails %0d", checks, fails);
	if (checks < 20) $display("RUN: FAIL (too few checks)");
	else if (fails) $display("RUN: FAIL");
	else $display("RUN: PASS");
	$finish;
end
endmodule
