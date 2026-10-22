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
// data does not move. ready_q is ack one clk_114 later. g = ack & ready_q is
// therefore high only when the data has been stable since at least the edge
// before last, and:
//
//   - the read ready the CPU sees is g, so it takes the word one clk_114
//     later than ack, which is a clk_sys later only when ack rose on the
//     clk_114 edge just before a clk_sys edge -- one read in four;
//   - the read data the CPU sees is ANDed with g, so on the clock where it is
//     younger than that the CPU's input is a constant zero and no register in
//     the TG68K can depend on it, whatever that register's enable.
//
// Together they make the path from the data registers into the TG68K a true
// two-clk_114 path, which AmigaCD.sdc says with a -start multicycle.
// rtl/sim/rdgate proves the data stable under g against the real controllers.
//
// Writes are not delayed: the CPU takes no data from a write. en is low when
// fx68k runs (cpucfg[1:0] == 0), and then every output is its input: the
// 68000's timing does not move, and the multicycle names only the TG68K.
module cpu_rdgate
(
	input             clk,         // clk_114
	input             en,          // the TG68K is the running CPU
	input             wr,          // the access is a write (clk_sys domain, held)

	input             ready_in,    // ram1/ram2 ready, as muxed by zram_sel
	input             ready_l_in,  // ddram's long-word ready
	input      [15:0] dout_in,
	input      [15:0] dout_hi_in,

	output            ready,
	output            ready_l,
	output     [15:0] dout,
	output     [15:0] dout_hi
);

reg ready_q   = 1'b0;
reg ready_l_q = 1'b0;
always @(posedge clk) begin
	ready_q   <= ready_in;
	ready_l_q <= ready_l_in;
end

wire g = ~en | (ready_in & ready_q);

assign ready   = ready_in   & (~en | wr | ready_q);
assign ready_l = ready_l_in & (~en | wr | ready_l_q);
assign dout    = dout_in    & {16{g}};
assign dout_hi = dout_hi_in & {16{g}};

endmodule
