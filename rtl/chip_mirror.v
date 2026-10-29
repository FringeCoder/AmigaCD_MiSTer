/*
 * chip_mirror.v
 *
 * ARM-CPU plan, step 5 (AmigaCD docs/arm-cpu-plan.md): a copy of chip RAM in
 * DDR3 that the ARM can read without crossing into the FPGA. A chip RAM read
 * through the HPS-to-FPGA bridge costs the ARM 564-886 ns; an uncached DDR3
 * read costs it ~140 ns. Frontier, on the ARM's JIT, reads chip RAM ~146k
 * times a second.
 *
 * The ARM keeps the copy -- the shadow, 2 MB at DDR3 0x3B000000 -- up to date
 * for its own writes: it writes both the shadow and, through the bridge, chip
 * RAM. This module adds every chip RAM write that does not come from the ARM:
 * whatever the chipset port of sdram_ctrl writes (the blitter, disk DMA,
 * Akiko's and the CDTV's sector DMA through chipdma_arb, and a CPU cycle on
 * the chip bus). The ARM's own writes, with FASTW set, go through the CPU
 * port and its write buffer instead, so they are not seen here; without
 * FASTW they are, and are copied again with the same data, which is harmless.
 *
 * sdram_ctrl reports each chipset write as it issues it (chip_wev). Writes
 * outside the first 2 MB (slow RAM, Kickstart) are ignored. The rest go into
 * a FIFO and out to DDR3 one 64-bit beat each, with the byte enables of the
 * word written, behind fast RAM and the other DDR3 masters. A write that
 * finds the FIFO full is dropped and `lost` set until `en` rises again: the
 * ARM then copies the shadow afresh.
 *
 * `idle` says the FIFO is empty and nothing has been written for IDLE_CLKS
 * clocks. armcpu_bridge holds the answer to every ARM read until it sees it,
 * so a DMA that has ended (which the ARM can only learn by a read through the
 * bridge) has also reached DDR3. The wait after the last write covers its
 * trip from the DDR3 port into the controller.
 *
 * Byte order is the 68k's, as in the bridge window: the byte at 68k address A
 * is shadow byte A, so the ARM byte-swaps words and longs as it does there.
 *
 * Everything here runs on clk_114, the clock of sdram_ctrl and ddram_ctrl;
 * `en` comes from the bridge's clock and is synchronized.
 */

module chip_mirror #(
	parameter [28:0] BASE      = 29'h07600000,  // DDR3 byte 0x3B000000, in 64-bit words
	parameter        ABITS     = 9,             // FIFO of 2^ABITS writes
	parameter        IDLE_CLKS = 8
) (
	input  wire        clk,
	input  wire        reset,
	input  wire        en_async,        // armcpu_bridge's MIRROR bit

	// from sdram_ctrl: a chipset-port write, as it is issued
	input  wire        wev,
	input  wire [23:1] wev_addr,
	input  wire [15:0] wev_data,
	input  wire  [1:0] wev_dqm,         // {U, L}, active low (as chipU/chipL)
	input  wire        wev_long,        // and wev_data2 to the word after
	input  wire [15:0] wev_data2,

	// Avalon master, single beats, writes only
	output reg  [28:0] m_address,
	output reg  [63:0] m_writedata,
	output reg   [7:0] m_byteenable,
	output reg         m_write,
	input  wire        m_waitrequest,

	output reg         idle,
	output reg         lost
);

	reg [1:0] en_s;
	always @(posedge clk) en_s <= {en_s[0], en_async};
	wire en = en_s[1];
	reg  en_d;

	// one entry: word address in the 2 MB, {U,L} enables, data; a long writes
	// two words of the same 64-bit beat (the second word's enables are both on)
	localparam W = 20 + 2 + 16 + 1 + 16;
	reg [W-1:0] mem [0:(1<<ABITS)-1];
	reg [ABITS-1:0] wp, rp;
	reg [ABITS:0]   n;

	wire in_chip  = wev_addr[23:21] == 3'd0;
	wire long_ok  = ~wev_long | (wev_addr[2:1] != 2'd3);
	wire push     = en & wev & in_chip;
	wire full     = n[ABITS];

	reg  [W-1:0] head;
	reg          head_v;

	reg [7:0] quiet;

	always @(posedge clk) begin
		en_d <= en;
		if (reset) begin
			wp     <= {ABITS{1'b0}};
			rp     <= {ABITS{1'b0}};
			n      <= {(ABITS+1){1'b0}};
			head_v <= 1'b0;
			m_write <= 1'b0;
			lost   <= 1'b0;
			idle   <= 1'b1;
			quiet  <= 8'd0;
		end
		else begin
			if (en & ~en_d) lost <= 1'b0;

			// in
			if (push & (full | ~long_ok)) lost <= 1'b1;
			if (push & ~full & long_ok) begin
				mem[wp] <= {wev_addr[20:1], wev_dqm, wev_data, wev_long, wev_data2};
				wp <= wp + 1'b1;
			end

			// FIFO to the head register
			if ((n != 0) & ~head_v) begin
				head   <= mem[rp];
				head_v <= 1'b1;
				rp     <= rp + 1'b1;
			end
			n <= n + (push & ~full & long_ok) - ((n != 0) & ~head_v);

			// head to the Avalon master
			if (m_write & ~m_waitrequest) m_write <= 1'b0;
			if (head_v & (~m_write | ~m_waitrequest)) begin : issue
				reg [19:0] a;
				reg  [1:0] dqm;
				reg [15:0] d, d2;
				reg        lg;
				{a, dqm, d, lg, d2} = head;
				m_address    <= BASE + {11'd0, a[19:2]};
				m_writedata  <= {4{d[7:0], d[15:8]}};
				m_byteenable <= {6'd0, ~dqm[0], ~dqm[1]} << {a[1:0], 1'b0};
				if (lg) begin
					m_writedata[16*(a[1:0]+1) +: 16] <= {d2[7:0], d2[15:8]};
					m_byteenable <= ({6'd0, ~dqm[0], ~dqm[1]} | 8'b1100) << {a[1:0], 1'b0};
				end
				m_write <= 1'b1;
				head_v  <= 1'b0;
			end

			// idle: nothing queued, nothing out, for IDLE_CLKS clocks
			if (push | (n != 0) | head_v | m_write) quiet <= 8'd0;
			else if (quiet != 8'hFF) quiet <= quiet + 1'b1;
			idle <= ~en | ((quiet >= IDLE_CLKS) & ~push & (n == 0) & ~head_v & ~m_write);
		end
	end

endmodule
