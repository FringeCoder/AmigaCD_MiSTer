/*
 * proxy68k.v
 *
 * MEASUREMENT ONLY -- step 2 of the ARM-CPU plan. A 68000's bus pins with no
 * 68000 behind them: armcpu_bridge.v hands it one word cycle at a time (from
 * a 68k running on the ARM) and it plays that cycle on the same pins, with
 * the same timing, as fx68k's busControl. cpu_wrapper puts these outputs in
 * place of the fx68k's while the ARM owns the bus, so everything behind the
 * pins -- gary, the chip bus, autoconfig, the CDTV bridge -- sees a 68000.
 *
 * fx68k's bus phases advance on enPhi1: SIDLE, S0, S2, S4 (repeated while
 * DTACK is not seen), S6. On the enPhi1 that leaves S0 it asserts AS, the
 * data strobes of a read, and R/W low for a write; a write's strobes follow on
 * the enPhi1 that leaves S2. DTACK is registered on every enPhi2 and decides
 * on enPhi1 whether S4 ends. The enPhi2 in S6 negates AS and the strobes and
 * is the edge the read data is taken on; R/W returns high on the enPhi1 that
 * ends the cycle. The address and the write data are set when the cycle
 * starts and held to its end.
 *
 * Handshake with the bridge (on the HPS's clock, asynchronous to this one):
 * a new cycle is wanted when req_tgl, through two flops, differs from the
 * last one taken; the fields have been held since it flipped. ack_tgl flips
 * when the cycle has ended, with rdata already valid. Cycles are only taken
 * while own is high (cpu_wrapper brings it over through two flops).
 *
 * The ARM waits on every access, so nothing here may wait forever: a cycle
 * that sees no DTACK for 65536 enPhi1 (~9 ms) ends anyway and reads
 * 0xFFFF, and a reset in the middle of a cycle still acknowledges it. A
 * reset does not drop a request the proxy has not taken yet; it runs after.
 */

module proxy68k #(
	parameter WAIT_BITS = 16           // no DTACK for 2^WAIT_BITS enPhi1 ends a cycle
)(
	input  wire        clk,
	input  wire        reset_n,
	input  wire        ph1,          // enPhi1
	input  wire        ph2,          // enPhi2

	input  wire        own,
	input  wire        req_tgl,
	input  wire        req_rw,       // 1 = read
	input  wire [23:1] req_addr,
	input  wire        req_uds_n,
	input  wire        req_lds_n,
	input  wire [15:0] req_wdata,
	output reg         ack_tgl = 1'b0,
	output reg  [15:0] rdata,

	// the pins
	output reg         as_n  = 1'b1,
	output reg         rw    = 1'b1,
	output reg         uds_n = 1'b1,
	output reg         lds_n = 1'b1,
	output reg  [23:1] addr,
	output reg  [15:0] dout,
	input  wire        dtack_n,
	input  wire [15:0] din
);

	localparam S_IDLE = 3'd0;
	localparam S0     = 3'd1;
	localparam S2     = 3'd2;
	localparam S4     = 3'd3;
	localparam S6     = 3'd4;

	reg [1:0] req_s = 2'b00;
	always @(posedge clk) req_s <= {req_s[0], req_tgl};

	reg [2:0] st = 3'd0;
	reg       taken = 1'b0;    // req_tgl as last taken
	reg [WAIT_BITS-1:0] wait_n;
	reg       rdtack;
	reg       c_rw, c_uds_n, c_lds_n;

	always @(posedge clk) begin
		if (~reset_n) begin
			if (st != S_IDLE) begin
				ack_tgl <= ~ack_tgl;
				rdata   <= 16'hFFFF;
			end
			st      <= S_IDLE;
			as_n    <= 1'b1;
			rw      <= 1'b1;
			uds_n   <= 1'b1;
			lds_n   <= 1'b1;
			rdtack  <= 1'b1;
		end
		else begin
			if (ph2) rdtack <= dtack_n;

			case (st)
			S_IDLE:
				if (ph1 & own & (req_s[1] != taken)) begin
					taken   <= req_s[1];
					c_rw    <= req_rw;
					c_uds_n <= req_uds_n;
					c_lds_n <= req_lds_n;
					addr    <= req_addr;
					dout    <= req_wdata;
					st      <= S0;
				end
			S0:
				if (ph1) begin
					as_n <= 1'b0;
					if (c_rw) begin
						uds_n <= c_uds_n;
						lds_n <= c_lds_n;
					end
					else rw <= 1'b0;
					wait_n <= 0;
					st <= S2;
				end
			S2:
				if (ph1) begin
					if (~c_rw) begin
						uds_n <= c_uds_n;
						lds_n <= c_lds_n;
					end
					st <= S4;
				end
			S4:
				if (ph1) begin
					wait_n <= wait_n + 1'd1;
					if (~rdtack) st <= S6;
					else if (&wait_n) begin
						// no DTACK: end the cycle as S6 would, reading all ones
						as_n    <= 1'b1;
						uds_n   <= 1'b1;
						lds_n   <= 1'b1;
						rw      <= 1'b1;
						rdata   <= 16'hFFFF;
						ack_tgl <= ~ack_tgl;
						st      <= S_IDLE;
					end
				end
			S6: begin
				if (ph2) begin
					as_n  <= 1'b1;
					uds_n <= 1'b1;
					lds_n <= 1'b1;
					if (c_rw) rdata <= din;
				end
				if (ph1) begin
					rw      <= 1'b1;
					ack_tgl <= ~ack_tgl;
					st      <= S_IDLE;
				end
			end
			default: st <= S_IDLE;
			endcase
		end
	end

endmodule
