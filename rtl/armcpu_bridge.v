/*
 * armcpu_bridge.v
 *
 * MEASUREMENT ONLY -- step 2 of the ARM-CPU plan (AmigaCD docs/arm-cpu-plan.md):
 * a 68k that runs on the ARM needs the FPGA to make its bus cycles for it.
 * This takes the accesses sys/lw_echo.sv forwards from the lightweight
 * HPS-to-FPGA bridge and turns them into 68000 word cycles, which
 * proxy68k.v (inside cpu_wrapper) plays on the pins the fx68k normally
 * drives. Nothing here runs unless the ARM sets OWN, and OWN only takes
 * effect with the CPU set to 68000.
 *
 * Bridge offsets (ARM physical 0xFF200000 + offset):
 *
 *   0x100000-0x1FFFFF  the 68k's address space, 1 MB at a time:
 *                      68k address = {BANK[3:0], offset[19:0]}. Bytes are
 *                      in the 68k's memory order -- the byte at 68k address
 *                      A is the bridge byte at A -- so the ARM reads a byte
 *                      directly and byte-swaps a halfword or word (REV16 /
 *                      REV). A word access is two 68k word cycles, a
 *                      halfword one, a byte one with only its data strobe.
 *                      Writes are posted: the bridge answers as soon as the
 *                      cycle starts, and the next access waits for it.
 *   0x080000 + 4*n     control:
 *     0 MAGIC   0x41435055 ("ACPU")
 *     1 CTRL    bit 0 OWN: hold the fx68k in reset and give the bus to the
 *               ARM. Reads back the effective value, 0 unless the CPU is 68000.
 *               bit 1 FAST: reads of chip RAM, Kickstart and fast RAM go
 *               through the SDRAM CPU port and its snooped cache, as the
 *               68020 turbo chip/kick does, instead of a 68000-timed chip-bus
 *               cycle. Writes and register reads keep the 68000 timing.
 *               bit 2 FASTW: writes to chip RAM and fast RAM go through the
 *               SDRAM CPU port's write buffer the same way (sdram_ctrl
 *               forwards a buffered write into any chipset read of the same
 *               block). Writes to the custom chips and CIAs keep 68000 timing.
 *               bit 3 RESET: while set (and OWN), the CPU's reset output is
 *               driven low, as the 68000's RESET instruction does: it resets
 *               the chipset, the CIAs and the cards, never the CPU side. The
 *               ARM holds it for the instruction's 124 clocks (~17 us).
 *     2 BANK    [3:0]
 *     3 STATUS  [2:0] the interrupt level Paula is asking for (0 none),
 *               [4] OWN in effect, [8] CPU set to 68000
 *     4 CYCLES  free-running count of clk
 *     5 LAST    clk cycles the last 68k-window access took, from the
 *               request to its last word cycle ending
 *     6 WORDS   68k word cycles made since reset
 *
 * With OWN clear, a 68k-window access is answered at once (reads return
 * 0xFFFFFFFF) so the ARM can never hang on it.
 *
 * clk is the bridge's clock, the HPS's clk_100m; the proxy runs on clk_sys,
 * and the two are asynchronous. Each word cycle is handed over by toggle:
 * the fields are set and held, px_tgl flips, and the proxy, having passed
 * px_tgl through two flops, flips px_ack_tgl when the cycle has ended, with
 * px_rdata already valid and held. px_ack_tgl, the CPU setting and the
 * interrupt level come in through two flops here; px_own goes out as a level
 * that changes only between requests.
 */

module armcpu_bridge (
	input  wire        clk,
	input  wire        reset,

	// from sys/lw_echo.sv
	input  wire        bus_req,
	input  wire        bus_we,
	input  wire [20:0] bus_addr,
	input  wire  [1:0] bus_size,
	input  wire  [3:0] bus_wstrb,
	input  wire [31:0] bus_wdata,
	output reg         bus_ack,
	output reg  [31:0] bus_rdata,

	// machine state
	input  wire        cpu_is_68000,
	input  wire  [2:0] ipl_n,          // chip_ipl, active low

	// to proxy68k (clk_sys)
	output reg         px_own,
	output reg         px_fast,
	output reg         px_fastw,
	output reg         px_reset,
	output reg         px_tgl,
	output reg         px_rw,          // 1 = read
	output reg  [23:1] px_addr,
	output reg         px_uds_n,
	output reg         px_lds_n,
	output reg  [15:0] px_wdata,
	input  wire        px_ack_tgl,
	input  wire [15:0] px_rdata
);

	localparam [31:0] MAGIC = 32'h41435055;   // "ACPU"

	// from clk_sys
	reg [1:0] ack_s, is68k_s;
	reg [2:0] ipl_s1, ipl_s2;
	always @(posedge clk) begin
		ack_s   <= {ack_s[0], px_ack_tgl};
		is68k_s <= {is68k_s[0], cpu_is_68000};
		ipl_s1  <= ipl_n;
		ipl_s2  <= ipl_s1;
	end
	wire ack_now   = ack_s[1];
	wire is68k_now = is68k_s[1];

	reg        own_req, fast_req, fastw_req;
	reg  [3:0] bank;
	reg [31:0] cyc, last, words;


	// ---- one request: up to two word cycles ---------------------------------
	reg        busy;          // a 68k-window request is running
	reg        c_we;
	reg [23:2] c_a;           // the aligned word the request is in
	reg  [1:0] c_halves;      // which halves still to do, [0] first
	reg  [3:0] c_strb;        // per byte lane: its data strobe
	reg [31:0] c_wdata;
	reg [31:0] c_rdata;
	reg [31:0] c_t0;
	reg        in_cycle;      // a word cycle is out to the proxy
	reg        ack_seen;      // px_ack_tgl as last accounted for
	reg        c_h;           // the half that cycle is for

	// a request that came in while a posted write was still running
	reg        p_valid, p_we;
	reg [20:0] p_addr;
	reg  [1:0] p_size;
	reg  [3:0] p_wstrb;
	reg [31:0] p_wdata;

	// byte lanes a read of this size at this address wants
	function [3:0] read_lanes(input [1:0] size, input [1:0] a);
		case (size)
			2'd0:    read_lanes = 4'b0001 << a;
			2'd1:    read_lanes = a[1] ? 4'b1100 : 4'b0011;
			default: read_lanes = 4'b1111;
		endcase
	endfunction

	wire        r_we    = p_valid ? p_we    : bus_we;
	wire [20:0] r_addr  = p_valid ? p_addr  : bus_addr;
	wire  [1:0] r_size  = p_valid ? p_size  : bus_size;
	wire  [3:0] r_wstrb = p_valid ? p_wstrb : bus_wstrb;
	wire [31:0] r_wdata = p_valid ? p_wdata : bus_wdata;
	wire        r_go    = (bus_req | p_valid) & ~busy;

	wire  [3:0] r_lanes = r_we ? r_wstrb : read_lanes(r_size, r_addr[1:0]);

	function [31:0] ctl(input [2:0] n);
		case (n)
			3'd0: ctl = MAGIC;
			3'd1: ctl = {28'd0, px_reset, px_fastw, px_fast, px_own};
			3'd2: ctl = {28'd0, bank};
			3'd3: ctl = {23'd0, is68k_now, 3'd0, px_own, 1'b0, ~ipl_s2};
			3'd4: ctl = cyc;
			3'd5: ctl = last;
			3'd6: ctl = words;
			default: ctl = 32'd0;
		endcase
	endfunction

	always @(posedge clk) begin
		bus_ack <= 1'b0;
		cyc     <= cyc + 32'd1;

		if (reset) begin
			own_req  <= 1'b0;
			fast_req <= 1'b0;
			px_fast  <= 1'b0;
			fastw_req <= 1'b0;
			px_fastw <= 1'b0;
			px_reset <= 1'b0;
			bank     <= 4'd0;
			busy     <= 1'b0;
			in_cycle <= 1'b0;
			p_valid  <= 1'b0;
			words    <= 32'd0;
			last     <= 32'd0;
			px_tgl   <= 1'b0;
			ack_seen <= ack_now;
			px_rw    <= 1'b1;
			px_uds_n <= 1'b1;
			px_lds_n <= 1'b1;
			px_own   <= 1'b0;
		end
		else begin
			// OWN changes only between requests, so a cycle the proxy has
			// started is always finished on the pins it started on
			if (~busy) begin
				px_own  <= own_req & is68k_now;
				px_fast <= fast_req;
				px_fastw <= fastw_req;
			end

			// a request arriving while busy can only follow a posted write
			if (bus_req & busy) begin
				p_valid <= 1'b1;
				p_we    <= bus_we;
				p_addr  <= bus_addr;
				p_size  <= bus_size;
				p_wstrb <= bus_wstrb;
				p_wdata <= bus_wdata;
			end

			if (r_go) begin
				p_valid <= 1'b0;
				if (~r_addr[20]) begin
					// control
					bus_ack <= 1'b1;
					bus_rdata <= ctl(r_addr[4:2]);
					if (r_we) case (r_addr[4:2])
						3'd1: if (r_wstrb[0]) begin
							{fastw_req, fast_req, own_req} <= r_wdata[2:0];
							px_reset <= r_wdata[3] & r_wdata[0];
						end
						3'd2: if (r_wstrb[0]) bank    <= r_wdata[3:0];
						default: ;
					endcase
				end
				else if (~px_own | ~|r_lanes) begin
					// nobody to answer, or nothing to do
					bus_ack   <= 1'b1;
					bus_rdata <= 32'hFFFFFFFF;
				end
				else begin
					busy     <= 1'b1;
					c_we     <= r_we;
					c_a      <= {bank, r_addr[19:2]};
					c_halves <= {|r_lanes[3:2], |r_lanes[1:0]};
					c_strb   <= r_lanes;
					c_wdata  <= r_wdata;
					c_rdata  <= 32'hFFFFFFFF;
					c_t0     <= cyc;
					if (r_we) bus_ack <= 1'b1;     // posted
				end
			end

			// issue the next word cycle of the running request
			if (busy & ~in_cycle) begin
				if (c_halves == 2'b00) begin
					busy <= 1'b0;
					last <= cyc - c_t0;
					if (~c_we) begin
						bus_ack   <= 1'b1;
						bus_rdata <= c_rdata;
					end
				end
				else begin
					c_h      <= ~c_halves[0];
					px_addr  <= {c_a, ~c_halves[0]};
					px_rw    <= ~c_we;
					if (c_halves[0]) begin
						px_uds_n <= ~c_strb[0];
						px_lds_n <= ~c_strb[1];
						px_wdata <= {c_wdata[7:0], c_wdata[15:8]};
					end
					else begin
						px_uds_n <= ~c_strb[2];
						px_lds_n <= ~c_strb[3];
						px_wdata <= {c_wdata[23:16], c_wdata[31:24]};
					end
					px_tgl   <= ~px_tgl;
					in_cycle <= 1'b1;
				end
			end

			// the proxy finished one
			if (in_cycle & (ack_now != ack_seen)) begin
				ack_seen <= ack_now;
				in_cycle <= 1'b0;
				words    <= words + 32'd1;
				if (c_h) begin
					c_halves[1] <= 1'b0;
					c_rdata[31:16] <= {px_rdata[7:0], px_rdata[15:8]};
				end
				else begin
					c_halves[0] <= 1'b0;
					c_rdata[15:0] <= {px_rdata[7:0], px_rdata[15:8]};
				end
			end
		end
	end

endmodule
