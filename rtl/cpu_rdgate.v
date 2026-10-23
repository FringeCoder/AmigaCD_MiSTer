// The CPU's view of the RAM ports' read return, gated so that what the TG68K
// can see of the read data is always at least two clk_114 periods old.
//
// The read data registers (cpu_cache_new's cpu_dat_r and cpu_dat_hi, in both
// sdram_ctrl and ddram_ctrl) are on clk_114 and the TG68K on clk_sys, a
// quarter of it. A word loaded on the clk_114 edge just before a clk_sys edge
// had 8.8 ns to cross the mux, the CPU's input muxes and into its datapath,
// and that was the worst family in the design after the 2026-10-17 sync
// (docs/seed-lottery.md, D and G). Registering the return (cpu_rdq, rows 6 and
// 20) fixed it and cost the caches more than it gained. This changes when the
// CPU may take the word instead of where it comes from.
//
// The cache loads its read data only on the edge its ack rises (CPU_SM_READ,
// CPU_SM_FILL1), and ack falls when the select does, so while ack is high the
// data does not move.
//
// Row 29 (docs/seed-lottery.md) gated with ack itself, g = ack & ack_q. That
// made the DATA a two-clock path, but put the cache's ack register, through
// zram_sel's mux and the gate, in front of the TG68K in one clk_114 period --
// and on the resynced tree that path, not the data, was the worst of D and G.
// So everything the CPU sees here is now decided by registers alone:
//
//   v = ack_q & cs & cs_q
//
// ack_q is ack one clk_114 later; cs is AmigaCD.sv's ram_cs, the registered
// select; cs_q is cs one clk_114 later. cs & cs_q says the select has been up
// over the last two edges without a break, so the ack that ack_q saw was this
// request's, not the tail of the one before; and cs drops on the very edge
// the request ends, which is when ack falls with it. No input of v is
// combinational on anything the cache drives.
//
//   - the ready the CPU sees is v, for writes as well as reads (row 29 left
//     writes undelayed, which kept the live ack in front of clkena). The CPU
//     takes a read or completes a write one clk_114 after ack, which is a
//     clk_sys later only when ack rose on the clk_114 edge just before a
//     clk_sys edge;
//   - the data the CPU sees is ANDed with v, so on the clock where it is
//     younger than that the CPU's input is a constant zero.
//
// The data registers into the TG68K are then a true two-clk_114 path, which
// AmigaCD.sdc says with a -start multicycle; what remains single-cycle starts
// at ack_q, cs and cs_q. rtl/sim/rdgate proves, against the real controllers,
// the data stable under v and v never true without an ack inside the select.
//
// The TG68K's ready and long ready are v and v_l UNCONDITIONALLY. Row 30 gave
// them an en mux for the fx68k's sake (en ? v : ready_in), and timing analysis
// times both inputs of a mux whatever en is: the live ack still reached the
// TG68K through the en = 0 side (seed 41: cpu_ack_l -> long_ack -> data_read
// -> opcode, -1.274). en is static while the machine runs, so the fx68k gets
// the raw ready on an output of its own, ready_fx, which cpu_wrapper wires to
// its DTACK and nothing else: the 68000's timing does not move. When the TG68K
// is not running nothing reads its ready. The data is ANDed with ~en | v, so
// with the fx68k running it passes as it is; en comes from the CPU config,
// whose paths are false (AmigaCD.sdc). Row 31.
module cpu_rdgate
(
	input             clk,         // clk_114
	input             en,          // the TG68K is the running CPU
	input             cs,          // ram_cs, AmigaCD.sv's registered select

	input             ready_in,    // ram1/ram2 ready, as muxed by zram_sel
	input             ready_l_in,  // ddram's long-word ready
	input      [15:0] dout_in,
	input      [15:0] dout_hi_in,

	output            ready,       // TG68K
	output            ready_l,     // TG68K, long word
	output            ready_fx,    // fx68k: the raw ready, for its DTACK only
	output     [15:0] dout,
	output     [15:0] dout_hi
);

reg ready_q   = 1'b0;
reg ready_l_q = 1'b0;
reg cs_q      = 1'b0;
always @(posedge clk) begin
	ready_q   <= ready_in;
	ready_l_q <= ready_l_in;
	cs_q      <= cs;
end

wire v   = ready_q   & cs & cs_q;
wire v_l = ready_l_q & cs & cs_q;
wire g   = ~en | v;

assign ready    = v;
assign ready_l  = v_l;
assign ready_fx = ready_in;
assign dout    = dout_in    & {16{g}};
assign dout_hi = dout_hi_in & {16{g}};

endmodule
