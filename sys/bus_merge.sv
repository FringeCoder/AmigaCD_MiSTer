/*
 * bus_merge.sv
 *
 * MEASUREMENT ONLY -- step 4 of the ARM-CPU plan (AmigaCD docs/arm-cpu-plan.md).
 * The core's bus port (LW_BUS_*) has two masters now: lw_echo on the
 * lightweight bridge (armcpu_bridge's control registers and its 1 MB banked
 * window) and a second lw_echo on the full HPS-to-FPGA bridge, which maps the
 * 68k's whole 24-bit space flat at ARM physical 0xC0000000. A JIT fetches
 * opcodes through host pointers, so chip RAM has to be ordinary memory to it;
 * a window that moves with a BANK register cannot be.
 *
 * Both masters keep one access in flight (a pulse on req, then wait for ack).
 * This holds one pending request per master, issues them to the core one at a
 * time -- alternating when both wait -- and sends each ack back to the master
 * it belongs to. The core sees one stream, as before, with bit 24 of the
 * address saying which: 0 is the lightweight bridge's offset in [20:0], 1 is a
 * flat access with the 68k address in [23:0].
 *
 * A flat access at 16 MB or above has nothing behind it and is answered here
 * at once: reads with all ones, writes dropped.
 */

module bus_merge
(
	input  wire        clk,
	input  wire        reset,

	// the lightweight bridge (lw_echo)
	input  wire        a_req,
	input  wire        a_we,
	input  wire [20:0] a_addr,
	input  wire  [1:0] a_size,
	input  wire  [3:0] a_wstrb,
	input  wire [31:0] a_wdata,
	output reg         a_ack,
	output reg  [31:0] a_rdata,

	// the full bridge, flat (lw_echo with FLAT)
	input  wire        b_req,
	input  wire        b_we,
	input  wire [29:0] b_addr,
	input  wire  [1:0] b_size,
	input  wire  [3:0] b_wstrb,
	input  wire [31:0] b_wdata,
	output reg         b_ack,
	output reg  [31:0] b_rdata,

	// to the core
	output reg         o_req,
	output reg         o_we,
	output reg  [24:0] o_addr,
	output reg   [1:0] o_size,
	output reg   [3:0] o_wstrb,
	output reg  [31:0] o_wdata,
	input  wire        o_ack,
	input  wire [31:0] o_rdata
);

	// one pending request per master
	reg        pa, pa_we, pb, pb_we;
	reg [20:0] pa_addr;
	reg [23:0] pb_addr;
	reg  [1:0] pa_size, pb_size;
	reg  [3:0] pa_wstrb, pb_wstrb;
	reg [31:0] pa_wdata, pb_wdata;

	reg        busy;      // a request is out to the core
	reg        owner;     // ... and it is b's
	reg        last_b;    // b was served last: a goes first next time

	always @(posedge clk) begin
		o_req <= 1'b0;
		a_ack <= 1'b0;
		b_ack <= 1'b0;

		if (reset) begin
			pa     <= 1'b0;
			pb     <= 1'b0;
			busy   <= 1'b0;
			last_b <= 1'b0;
		end
		else begin
			if (a_req) begin
				pa       <= 1'b1;
				pa_we    <= a_we;
				pa_addr  <= a_addr;
				pa_size  <= a_size;
				pa_wstrb <= a_wstrb;
				pa_wdata <= a_wdata;
			end

			if (b_req) begin
				if (|b_addr[29:24]) begin
					// nothing above 16 MB
					b_ack   <= 1'b1;
					b_rdata <= 32'hFFFFFFFF;
				end
				else begin
					pb       <= 1'b1;
					pb_we    <= b_we;
					pb_addr  <= b_addr[23:0];
					pb_size  <= b_size;
					pb_wstrb <= b_wstrb;
					pb_wdata <= b_wdata;
				end
			end

			if (~busy) begin
				if (pb & (~pa | ~last_b)) begin
					o_req   <= 1'b1;
					o_we    <= pb_we;
					o_addr  <= {1'b1, pb_addr};
					o_size  <= pb_size;
					o_wstrb <= pb_wstrb;
					o_wdata <= pb_wdata;
					pb      <= 1'b0;
					busy    <= 1'b1;
					owner   <= 1'b1;
					last_b  <= 1'b1;
				end
				else if (pa) begin
					o_req   <= 1'b1;
					o_we    <= pa_we;
					o_addr  <= {4'd0, pa_addr};
					o_size  <= pa_size;
					o_wstrb <= pa_wstrb;
					o_wdata <= pa_wdata;
					pa      <= 1'b0;
					busy    <= 1'b1;
					owner   <= 1'b0;
					last_b  <= 1'b0;
				end
			end

			if (busy & o_ack) begin
				busy <= 1'b0;
				if (owner) begin
					b_ack   <= 1'b1;
					b_rdata <= o_rdata;
				end
				else begin
					a_ack   <= 1'b1;
					a_rdata <= o_rdata;
				end
			end
		end
	end

endmodule
