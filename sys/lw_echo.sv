/*
 * lw_echo.sv
 *
 * MEASUREMENT ONLY -- steps 1d, 1e and 2 of the ARM-CPU plan. Step 1 timed a
 * request from the ARM through DDR3 to the FPGA and back at ~2.5 us, almost
 * none of it spent in anything the ARM or the FPGA executes. This answers the
 * same question for the Cyclone V's lightweight HPS-to-FPGA bridge, which
 * maps FPGA registers straight into the ARM's address space (physical
 * 0xFF200000) with no DDR3 in between.
 *
 * Main_MiSTer already releases all three HPS bridges from reset and makes the
 * lightweight one visible (fpga_io.cpp do_bridge: brg_mod_reset = 0, NIC-301
 * remap = 0x19); the framework simply never instantiated it. sys_top.v now
 * does, with this module as the only slave. AmigaCD tools/latprobe -L times
 * it.
 *
 * Step 1e adds registers 4-7, which belong to the core: a write to one is
 * passed to emu as a one-cycle ext_wr pulse with its index and data (the last
 * beat of a burst wins, strobes ignored), and a read returns that register's
 * word of ext_status. AmigaCD's visprobe_ddr3.v uses them to measure DDR3
 * write visibility. The bridge runs on whatever clock the core gives it
 * (LW_CLK); latprobe measures that clock against its own.
 *
 * Step 2 adds the bus: every access at offset 0x080000 or above (address bit
 * 19 or 20 set) goes to emu as one bus_req pulse per beat, carrying the byte
 * address, the access size (a read's arsize; a write's strobes say the rest)
 * and the write data, and is answered by a bus_ack pulse with the read data.
 * Nothing is answered on the AXI side until then, so the core decides how long
 * an access takes -- AmigaCD's armcpu_bridge.v turns them into 68000 bus
 * cycles. INCR bursts step the address by the beat size; any other burst
 * repeats it.
 *
 * Registers, 32 bits, at ARM 0xFF200000 + 4*n (address bits [18:5] ignored):
 *   0 ECHO    read/write; a read returns the last value written
 *   1 MAGIC   read-only 0x4C574252 ("LWBR"), so the tool knows the core has it
 *   2 CYCLES  read-only, free-running count of clk cycles
 *   3 COUNT   read-only, {writes[31:16], reads[15:0]} served since reset
 *   4-7       the core's: write to ext_wr, read from ext_status
 * and from offset 0x080000 to 0x1FFFFF, the core's bus.
 *
 * AXI3 slave, one transaction in flight per direction, and one bus access in
 * flight at a time (a write's beats go first). A write waits for its address
 * before taking data, which AXI allows. Responses are always OKAY.
 *
 * Step 4 (the JIT, which needs chip RAM as ordinary memory) instantiates it a
 * second time on the full HPS-to-FPGA bridge with FLAT set: no registers,
 * every access goes to the bus, and AW is that bridge's 30 address bits.
 */

module lw_echo #(
	parameter [31:0] MAGIC = 32'h4C574252,  // "LWBR"
	parameter        AW    = 21,            // address bits
	parameter        FLAT  = 0              // 1: no registers, everything is bus
)(
	input  wire        clk,
	input  wire        reset,

	input  wire [11:0] awid,
	input  wire [AW-1:0] awaddr,
	input  wire  [3:0] awlen,
	input  wire  [2:0] awsize,
	input  wire  [1:0] awburst,
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
	input  wire [AW-1:0] araddr,
	input  wire  [3:0] arlen,
	input  wire  [2:0] arsize,
	input  wire  [1:0] arburst,
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
	input  wire [127:0] ext_status,

	output reg         bus_req,
	output reg         bus_we,
	output reg  [AW-1:0] bus_addr,
	output reg   [1:0] bus_size,     // reads: 0 byte, 1 halfword, 2 word
	output reg   [3:0] bus_wstrb,
	output reg  [31:0] bus_wdata,
	input  wire        bus_ack,
	input  wire [31:0] bus_rdata
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

function is_bus(input [AW-1:0] a);
	is_bus = FLAT ? 1'b1 : (a[20] | a[19]);
endfunction

function [AW-1:0] next_addr(input [AW-1:0] a, input [2:0] size, input [1:0] burst);
	next_addr = (burst == 2'b01) ? a + ({{(AW-1){1'b0}}, 1'b1} << size) : a;
endfunction

// ---- the bus port: one access in flight, a write's beats first --------------

reg bus_busy;      // a bus_req is out and its bus_ack has not come back
reg bus_of_w;      // ... and it belongs to the write channel

// ---- write: address, then data beats, then one response -------------------

reg        aw_held;
reg [11:0] aw_id;
reg [AW-1:0] aw_a;
reg  [2:0] aw_size;
reg  [1:0] aw_burst;
reg        w_last_out;    // the last beat has gone to the bus; bvalid on its ack

wire aw_bus = is_bus(aw_a);

assign awready = ~aw_held & ~bvalid;
assign wready  =  aw_held & ~bvalid & (aw_bus ? ~bus_busy & ~w_last_out : 1'b1);

// ---- read: address, then arlen+1 beats ------------------------------------

reg        r_active;
reg  [3:0] r_left;
reg [AW-1:0] r_a;
reg  [2:0] r_size;
reg  [1:0] r_burst;
reg        r_want;        // a bus read is due for the current beat

wire r_bus = is_bus(r_a);

assign arready = ~r_active;
assign rlast   = (r_left == 0);

always @(posedge clk) begin
	ext_wr  <= 0;
	bus_req <= 0;

	if (reset) begin
		aw_held    <= 0;
		bvalid     <= 0;
		echo       <= 0;
		n_writes   <= 0;
		w_last_out <= 0;
		r_active   <= 0;
		rvalid     <= 0;
		r_want     <= 0;
		n_reads    <= 0;
		bus_busy   <= 0;
	end
	else begin
		// -- write channel
		if (awvalid & awready) begin
			aw_held  <= 1;
			aw_id    <= awid;
			aw_a     <= awaddr;
			aw_size  <= awsize;
			aw_burst <= awburst;
		end

		if (wvalid & wready) begin
			if (aw_bus) begin
				bus_req   <= 1;
				bus_we    <= 1;
				bus_addr  <= aw_a;
				bus_size  <= aw_size[1:0];
				bus_wstrb <= wstrb;
				bus_wdata <= wdata;
				bus_busy  <= 1;
				bus_of_w  <= 1;
				aw_a      <= next_addr(aw_a, aw_size, aw_burst);
				if (wlast) w_last_out <= 1;
			end
			else begin
				if (aw_a[4:2] == 3'd0) begin
					if (wstrb[0]) echo[7:0]   <= wdata[7:0];
					if (wstrb[1]) echo[15:8]  <= wdata[15:8];
					if (wstrb[2]) echo[23:16] <= wdata[23:16];
					if (wstrb[3]) echo[31:24] <= wdata[31:24];
				end
				if (wlast) begin
					ext_wr    <= aw_a[4];
					ext_waddr <= aw_a[3:2];
					ext_wdata <= wdata;
					aw_held   <= 0;
					bvalid    <= 1;
					bid       <= aw_id;
					n_writes  <= n_writes + 1'd1;
				end
			end
		end

		if (bvalid & bready) bvalid <= 0;

		// -- read channel
		if (arvalid & arready) begin
			r_active <= 1;
			rid      <= arid;
			r_left   <= arlen;
			r_a      <= araddr;
			r_size   <= arsize;
			r_burst  <= arburst;
			if (is_bus(araddr)) r_want <= 1;
			else begin
				rvalid <= 1;
				rdata  <= regs(araddr[4:2]);
			end
		end
		else if (rvalid & rready) begin
			rvalid <= 0;
			if (rlast) begin
				r_active <= 0;
				n_reads  <= n_reads + 1'd1;
			end
			else begin
				r_left <= r_left - 1'd1;
				r_a    <= next_addr(r_a, r_size, r_burst);
				if (r_bus) r_want <= 1;
				else begin
					rvalid <= 1;
					rdata  <= regs(r_a[4:2]);
				end
			end
		end

		// -- the bus port: a read goes out only when no write beat is going
		if (r_want & ~bus_busy & ~(wvalid & wready & aw_bus)) begin
			bus_req  <= 1;
			bus_we   <= 0;
			bus_addr <= r_a;
			bus_size <= r_size[1:0];
			bus_busy <= 1;
			bus_of_w <= 0;
			r_want   <= 0;
		end

		if (bus_ack & bus_busy) begin
			bus_busy <= 0;
			if (bus_of_w) begin
				if (w_last_out) begin
					w_last_out <= 0;
					aw_held    <= 0;
					bvalid     <= 1;
					bid        <= aw_id;
					n_writes   <= n_writes + 1'd1;
				end
			end
			else begin
				rvalid <= 1;
				rdata  <= bus_rdata;
			end
		end
	end
end

always @(posedge clk) cycles <= cycles + 1'd1;

endmodule
