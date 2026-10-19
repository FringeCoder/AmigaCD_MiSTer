// The CPU's read return from the two RAM ports, registered at clk_114 with the
// port select already applied.
//
// AmigaCD.sv used to mux ram1 and ram2 (zram_sel) in front of cpu_wrapper, and
// cpu_wrapper muxed the result again on its way into the CPU. The cache data
// is launched at clk_114 and the CPU takes it at the next clk_sys edge, one
// clk_114 period later, so that mux was a level spent inside the tightest
// relationship in the design (8.8 ns, the D/G families in docs/seed-lottery.md).
//
// Here the mux is done before the register instead of after it. Each port hands
// over the value its own registers take at the next clock (the *_n outputs,
// which those registers themselves load from), so on every clk_114 edge these
// registers take exactly what zram_sel would select from the ports' registers
// after that edge.
//
// The one thing that differs is zram_sel's timing: it is taken at the edge
// rather than after it. zram_sel is a clk_sys signal (the CPU address through
// memory_router), so it only moves on a clk_sys edge, and the clk_114 edge in
// front of each clk_sys edge is never one of those. On that edge, which is the
// one whose value the CPU takes, the registers here equal the mux they
// replace. Between clk_sys edges they can lag a zram_sel change by one clk_114
// clock, which is why only cpu_wrapper (clk_sys) takes them: the clk_114 users
// of ram_ready (ram_cs, ss_ctrl) keep the live mux.
//
// rtl/sim/rdq/tb_cpu_rdq_equiv.sv checks it against the old wiring, with
// the real caches and controllers on clk_114 and the select moving at clk_sys.
module cpu_rdq
(
	input             clk,          // clk_114

	input             zram_sel,     // 1: ram2 (DDR3), 0: ram1 (SDRAM)

	input      [15:0] ram1_dout_n,
	input             ram1_ready_n,
	input      [15:0] ram2_dout_n,
	input             ram2_ready_n,
	input             ram2_ready_l_n,

	output reg [15:0] dout,
	output reg        ready,
	output reg        ready_l
);

always @(posedge clk) begin
	dout    <= zram_sel ? ram2_dout_n  : ram1_dout_n;
	ready   <= zram_sel ? ram2_ready_n : ram1_ready_n;
	ready_l <= zram_sel & ram2_ready_l_n;
end

endmodule
