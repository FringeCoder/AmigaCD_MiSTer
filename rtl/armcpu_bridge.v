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
 *                      Writes are posted: the bridge answers a write as soon
 *                      as it is queued (up to 2^QBITS of them), and runs the
 *                      queue in order behind the ARM. A read waits for every
 *                      write queued before it, so the ARM never sees its own
 *                      accesses out of order.
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
 *               bit 4 MIRROR: copy every chip RAM write the chipset makes --
 *               the blitter, disk DMA, Akiko, a chip-bus CPU cycle; not the
 *               ARM's own FASTW writes -- into the DDR3 shadow at 0x3B000000
 *               (rtl/chip_mirror.v). The ARM reads chip RAM there, uncached,
 *               and writes both. Setting it clears STATUS[10].
 *     2 BANK    [3:0]
 *     3 STATUS  [2:0] the interrupt level Paula is asking for (0 none),
 *               [4] OWN in effect, [8] CPU set to 68000, [9] a word cycle
 *               timed out (sticky until OWN is set again), [10] the mirror
 *               dropped a write (sticky until MIRROR is set again: the shadow
 *               has to be copied afresh)
 *     4 CYCLES  free-running count of clk
 *     5 LAST    clk cycles the last 68k-window access took, from the
 *               request to its last word cycle ending
 *     6 WORDS   68k word cycles made since reset
 *
 * Step 4 adds a flat view: sys/bus_merge.sv sets address bit 24 for an access
 * from the full HPS-to-FPGA bridge (ARM physical 0xC0000000), and [23:0] is
 * then the 68k address itself -- no BANK, no control registers. It is the
 * same window otherwise: OWN, FAST, FASTW, the byte order and the cycles.
 *
 * With OWN clear, a 68k-window access is answered at once (reads return
 * 0xFFFFFFFF) so the ARM can never hang on it. Nor with OWN set: a word
 * cycle the proxy has not ended after 2^20 clocks (~10 ms) is given up, the
 * read answered with 0xFFFFFFFF, OWN cleared and STATUS[9] set. Without it a
 * proxy stopped mid-cycle -- the core halting the CPU for a reset, with
 * armcpu still running -- held the ARM's AXI read forever, and that froze
 * the whole HPS: no Linux, no network, a power cycle (2026-10-26).
 *
 * clk is the bridge's clock, the HPS's clk_100m; the proxy runs on clk_sys,
 * and the two are asynchronous. Each word cycle is handed over by toggle:
 * the fields are set and held, px_tgl flips, and the proxy, having passed
 * px_tgl through two flops, flips px_ack_tgl when the cycle has ended, with
 * px_rdata already valid and held. px_ack_tgl, the CPU setting and the
 * interrupt level come in through two flops here; px_own goes out as a level
 * that changes only between requests.
 *
 * With MIRROR set, the answer to any read -- a 68k-window read or a control
 * register -- is held until the mirror has had nothing to write for a while
 * (mirror_idle, from clk_114). That is what keeps the shadow coherent for the
 * ARM: it learns that the blitter or a disk transfer has finished only by
 * reading something through here (DMACONR, INTREQR, STATUS's interrupt
 * level), and by the time that answer arrives, the words the transfer wrote
 * are in DDR3.
 */

module armcpu_bridge #(
	parameter WD_BITS = 20,            // a word cycle out this many clocks' worth is given up
	parameter QBITS   = 4              // the request queue holds 2^QBITS accesses
) (
	input  wire        clk,
	input  wire        reset,

	// from sys/lw_echo.sv
	input  wire        bus_req,
	input  wire        bus_we,
	input  wire [24:0] bus_addr,       // [24]: flat, [23:0] the 68k address
	input  wire  [1:0] bus_size,
	input  wire  [3:0] bus_wstrb,
	input  wire [31:0] bus_wdata,
	output reg         bus_ack,
	output reg  [31:0] bus_rdata,

	// machine state
	input  wire        cpu_is_68000,
	input  wire  [2:0] ipl_n,          // chip_ipl, active low

	// rtl/chip_mirror.v (clk_114)
	output reg         mirror_en,
	input  wire        mirror_idle,    // nothing queued or being written, for a while
	input  wire        mirror_lost,    // a write was dropped since mirror_en rose

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
	reg [1:0] ack_s, is68k_s, midle_s, mlost_s;
	reg [2:0] ipl_s1, ipl_s2;
	always @(posedge clk) begin
		ack_s   <= {ack_s[0], px_ack_tgl};
		is68k_s <= {is68k_s[0], cpu_is_68000};
		midle_s <= {midle_s[0], mirror_idle};
		mlost_s <= {mlost_s[0], mirror_lost};
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
	reg [WD_BITS-1:0] wd;     // clocks the word cycle has been out
	reg        timed_out;

	// ---- the request queue ----------------------------------------------------
	// Every request goes through it, in order. A write is answered when it is
	// queued, unless that leaves no room for the next request (bus_merge
	// keeps exactly one unanswered access out to here, so one free entry is
	// always enough), in which case the answer is owed and given at the next
	// pop. A read is answered when it has run.
	localparam QN = 1 << QBITS;
	reg        q_we    [0:QN-1];
	reg [24:0] q_addr  [0:QN-1];
	reg  [1:0] q_size  [0:QN-1];
	reg  [3:0] q_wstrb [0:QN-1];
	reg [31:0] q_wdata [0:QN-1];
	reg [QBITS-1:0] q_rd, q_wr;
	reg [QBITS:0]   q_n;
	reg        ack_owed;
	reg        rd_hold;           // a read has run; its answer waits for the mirror
	reg [31:0] rd_data;

	// byte lanes a read of this size at this address wants
	function [3:0] read_lanes(input [1:0] size, input [1:0] a);
		case (size)
			2'd0:    read_lanes = 4'b0001 << a;
			2'd1:    read_lanes = a[1] ? 4'b1100 : 4'b0011;
			default: read_lanes = 4'b1111;
		endcase
	endfunction

	wire        r_we    = q_we[q_rd];
	wire [24:0] r_addr  = q_addr[q_rd];
	wire        r_flat  = r_addr[24];
	wire  [1:0] r_size  = q_size[q_rd];
	wire  [3:0] r_wstrb = q_wstrb[q_rd];
	wire [31:0] r_wdata = q_wdata[q_rd];
	wire        r_go    = (q_n != 0) & ~busy & ~rd_hold;
	wire        mirror_quiet = ~mirror_en | midle_s[1];

	wire  [3:0] r_lanes = r_we ? r_wstrb : read_lanes(r_size, r_addr[1:0]);

	function [31:0] ctl(input [2:0] n);
		case (n)
			3'd0: ctl = MAGIC;
			3'd1: ctl = {27'd0, mirror_en, px_reset, px_fastw, px_fast, px_own};
			3'd2: ctl = {28'd0, bank};
			3'd3: ctl = {21'd0, mlost_s[1], timed_out, is68k_now, 3'd0, px_own, 1'b0, ~ipl_s2};
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
			q_rd     <= {QBITS{1'b0}};
			q_wr     <= {QBITS{1'b0}};
			q_n      <= {(QBITS+1){1'b0}};
			ack_owed <= 1'b0;
			rd_hold  <= 1'b0;
			mirror_en <= 1'b0;
			words    <= 32'd0;
			last     <= 32'd0;
			wd       <= {WD_BITS{1'b0}};
			timed_out <= 1'b0;
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

			// queue a request; answer a write at once if there is room behind it
			if (bus_req) begin
				q_we[q_wr]    <= bus_we;
				q_addr[q_wr]  <= bus_addr;
				q_size[q_wr]  <= bus_size;
				q_wstrb[q_wr] <= bus_wstrb;
				q_wdata[q_wr] <= bus_wdata;
				q_wr          <= q_wr + 1'b1;
				if (bus_we) begin
					if (q_n < QN - 1) bus_ack  <= 1'b1;
					else              ack_owed <= 1'b1;
				end
			end
			q_n <= q_n + bus_req - r_go;

			// a read's answer, once the mirror has caught up
			if (rd_hold & mirror_quiet) begin
				rd_hold   <= 1'b0;
				bus_ack   <= 1'b1;
				bus_rdata <= rd_data;
			end

			if (r_go) begin
				q_rd <= q_rd + 1'b1;
				if (ack_owed) begin
					ack_owed <= 1'b0;
					bus_ack  <= 1'b1;
				end
				if (~r_flat & ~r_addr[20]) begin
					// control
					if (~r_we) begin
						rd_hold <= 1'b1;
						rd_data <= ctl(r_addr[4:2]);
					end
					else case (r_addr[4:2])
						3'd1: if (r_wstrb[0]) begin
							{fastw_req, fast_req, own_req} <= r_wdata[2:0];
							px_reset  <= r_wdata[3] & r_wdata[0];
							if (r_wdata[0]) timed_out <= 1'b0;
							mirror_en <= r_wdata[4];
						end
						3'd2: if (r_wstrb[0]) bank    <= r_wdata[3:0];
						default: ;
					endcase
				end
				else if (~px_own | timed_out | ~|r_lanes) begin
					// nobody to answer, or nothing to do
					if (~r_we) begin
						rd_hold <= 1'b1;
						rd_data <= 32'hFFFFFFFF;
					end
				end
				else begin
					busy     <= 1'b1;
					c_we     <= r_we;
					c_a      <= r_flat ? r_addr[23:2] : {bank, r_addr[19:2]};
					c_halves <= {|r_lanes[3:2], |r_lanes[1:0]};
					c_strb   <= r_lanes;
					c_wdata  <= r_wdata;
					c_rdata  <= 32'hFFFFFFFF;
					c_t0     <= cyc;
				end
			end

			// issue the next word cycle of the running request
			if (busy & ~in_cycle) begin
				if (c_halves == 2'b00) begin
					busy <= 1'b0;
					last <= cyc - c_t0;
					if (~c_we) begin
						rd_hold <= 1'b1;
						rd_data <= c_rdata;
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
					wd       <= {WD_BITS{1'b0}};
				end
			end

			// a word cycle the proxy never ends: give the request up rather
			// than hold the ARM's bus transaction (see the header)
			if (in_cycle) wd <= wd + 1'b1;
			if (in_cycle & (ack_now == ack_seen) & (&wd)) begin
				in_cycle  <= 1'b0;
				busy      <= 1'b0;
				own_req   <= 1'b0;
				px_reset  <= 1'b0;
				timed_out <= 1'b1;
				if (~c_we) begin
					rd_hold <= 1'b1;
					rd_data <= 32'hFFFFFFFF;
				end
			end
			// and the end of that cycle, should it come later, is dropped
			if (~in_cycle & (ack_now != ack_seen)) ack_seen <= ack_now;

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
