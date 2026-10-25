/*
 * lw_echo.sv
 *
 * MEASUREMENT ONLY -- step 1d of the ARM-CPU plan. Step 1 timed a request
 * from the ARM through DDR3 to the FPGA and back at ~2.5 us, almost none of it
 * spent in anything the ARM or the FPGA executes. This answers the same
 * question for the Cyclone V's lightweight HPS-to-FPGA bridge, which maps FPGA
 * registers straight into the ARM's address space (physical 0xFF200000) with
 * no DDR3 in between.
 *
 * Main_MiSTer already releases all three HPS bridges from reset and makes the
 * lightweight one visible (fpga_io.cpp do_bridge: brg_mod_reset = 0, NIC-301
 * remap = 0x19); the framework simply never instantiated it. sys_top.v now
 * does, with this register file as the only slave. AmigaCD tools/latprobe -L
 * times it.
 *
 * Step 1e adds registers 4-7, which belong to the core: a write to one is
 * passed to emu as a one-cycle ext_wr pulse with its index and data (the last
 * beat of a burst wins, strobes ignored), and a read returns that register's
 * word of ext_status. AmigaCD's visprobe_ddr3.v uses them to measure DDR3
 * write visibility. The bridge runs on the core's DDRAM_CLK so this needs no
 * clock crossing; latprobe measures the clock against its own.
 *
 * Registers, 32 bits, at ARM 0xFF200000 + 4*n (address bits [20:5] ignored):
 *   0 ECHO    read/write; a read returns the last value written
 *   1 MAGIC   read-only 0x4C574252 ("LWBR"), so the tool knows the core has it
 *   2 CYCLES  read-only, free-running count of clk cycles
 *   3 COUNT   read-only, {writes[31:16], reads[15:0]} served since reset
 *   4-7       the core's: write to ext_wr, read from ext_status
 *
 * AXI3 slave, one transaction in flight per direction. Bursts are honoured
 * (every beat of a read returns the addressed register, every beat of a
 * write lands in it) so an unexpected burst cannot hang the bridge, but the
 * tool only issues single 32-bit accesses. A write waits for its address
 * before taking data, which AXI allows. Responses are always OKAY.
 */

module lw_echo #(
	parameter [31:0] MAGIC = 32'h4C574252   // "LWBR"
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [11:0] awid,
	input  wire [20:0] awaddr,
	input  wire  [3:0] awlen,
	input  wire        awvalid,
	output wire        awready,

	input  wire [31:0] wdata,
	input  wire  [3:0] wstrb,
	input  wire        wlast,
	input  wire        wvalid,
	output wire        wready,

	output reg  [11:0] bid,
	output wire  [1:0] bresp,
	output reg         bvalid,
	input  wire        bready,

	input  wire [11:0] arid,
	input  wire [20:0] araddr,
	input  wire  [3:0] arlen,
	input  wire        arvalid,
	output wire        arready,

	output reg  [11:0] rid,
	output reg  [31:0] rdata,
	output wire  [1:0] rresp,
	output wire        rlast,
	output reg         rvalid,
	input  wire        rready,

	output reg         ext_wr,
	output reg   [1:0] ext_waddr,
	output reg  [31:0] ext_wdata,
	input  wire [127:0] ext_status
);

assign bresp = 2'b00;
assign rresp = 2'b00;

reg [31:0] echo;
reg [31:0] cycles;
reg [15:0] n_reads, n_writes;

function [31:0] regs(input [2:0] n);
	case (n)
		3'd0: regs = echo;
		3'd1: regs = MAGIC;
		3'd2: regs = cycles;
		3'd3: regs = {n_writes, n_reads};
		3'd4: regs = ext_status[31:0];
		3'd5: regs = ext_status[63:32];
		3'd6: regs = ext_status[95:64];
		3'd7: regs = ext_status[127:96];
	endcase
endfunction

// ---- write: address, then data beats, then one response -------------------

reg        aw_held;
reg [11:0] aw_id;
reg  [2:0] aw_reg;

assign awready = ~aw_held & ~bvalid;
assign wready  =  aw_held & ~bvalid;

always @(posedge clk) begin
	ext_wr <= 0;
	if (reset) begin
		aw_held  <= 0;
		bvalid   <= 0;
		echo     <= 0;
		n_writes <= 0;
	end
	else begin
		if (awvalid & awready) begin
			aw_held <= 1;
			aw_id   <= awid;
			aw_reg  <= awaddr[4:2];
		end

		if (wvalid & wready) begin
			if (aw_reg == 3'd0) begin
				if (wstrb[0]) echo[7:0]   <= wdata[7:0];
				if (wstrb[1]) echo[15:8]  <= wdata[15:8];
				if (wstrb[2]) echo[23:16] <= wdata[23:16];
				if (wstrb[3]) echo[31:24] <= wdata[31:24];
			end
			if (wlast) begin
				ext_wr    <= aw_reg[2];
				ext_waddr <= aw_reg[1:0];
				ext_wdata <= wdata;
				aw_held  <= 0;
				bvalid   <= 1;
				bid      <= aw_id;
				n_writes <= n_writes + 1'd1;
			end
		end

		if (bvalid & bready) bvalid <= 0;
	end
end

// ---- read: address, then arlen+1 beats ------------------------------------

reg  [3:0] r_left;
reg  [2:0] r_reg;

assign arready = ~rvalid;
assign rlast   = (r_left == 0);

always @(posedge clk) begin
	if (reset) begin
		rvalid  <= 0;
		n_reads <= 0;
	end
	else begin
		if (arvalid & arready) begin
			rvalid <= 1;
			rid    <= arid;
			r_left <= arlen;
			r_reg  <= araddr[4:2];
			rdata  <= regs(araddr[4:2]);
		end
		else if (rvalid & rready) begin
			if (rlast) begin
				rvalid  <= 0;
				n_reads <= n_reads + 1'd1;
			end
			else begin
				r_left <= r_left - 1'd1;
				rdata  <= regs(r_reg);
			end
		end
	end
end

always @(posedge clk) cycles <= cycles + 1'd1;

endmodule
