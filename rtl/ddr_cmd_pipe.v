// DDR3 command pipeline stage.
//
// TIMING, NOT FUNCTION. This holds one Avalon-MM command for one cycle on its
// way from the arbiter to the HPS f2sdram bridge, and it exists because that
// journey crosses the die.
//
// The bridge is a hard block in a fixed corner of the Cyclone V; ddram_ctrl,
// ss_ctrl and the arbiter are soft logic the fitter places wherever it likes.
// Before this stage the two ends talked combinationally in both directions,
// and report_timing on three separate netlists of 2026-10-01 put the worst
// setup path of the entire design on that boundary every time, in one
// direction or the other:
//
//   seed 1  -0.067  ddram_ctrl|ss_port_own~DUPLICATE  -> f2sdram~FF_1338
//   seed 2  -0.308  ddram_ctrl|ss_port_own            -> f2sdram~FF_1331
//   seed 2  -0.277  ss_ctrl|ddr_write                 -> f2sdram~FF_1331
//   seed 2  -0.089  ddram_ctrl|ram_we                 -> f2sdram~FF_1331
//   seed 4  -0.169  f2sdram~FF_3780 -> ss_ctrl|state.S_PEEK_FREEZE
//   seed 4  -0.141  f2sdram~FF_3777 -> ss_ctrl|state.S_PEEK_FREEZE
//
// Neither direction is a logic-depth problem. The seed 2 path spends 1.019 ns
// in cells and 6.938 ns in interconnect over three hops, against a period of
// 8.808 ns and roughly 0.8 ns of adverse clock-network skew -- the bridge's
// clock arrives later than the core's, because it is over there. Whether seven
// nanoseconds of routing closes is a placement outcome, which is why the same
// source fitted at different seeds swung about 0.9 ns of setup and why the
// decision to ship a build was being made by the seed rather than by the
// design.
//
// Two properties do the work here, and both matter:
//
//   * d_* are register outputs with NO logic between them and the bridge, so
//     the fitter can migrate this stage towards the HPS corner and split one
//     long hop into two short ones. Before, the last thing before the bridge
//     was the arbiter's 64-bit writedata mux, whose select is a three-deep
//     chain off ss_port_own / ram_we / ddr_write -- logic that has to sit
//     somewhere between all of those and the bridge, and so sits in the
//     middle of the longest route in the design.
//
//   * u_waitrequest is `held`, a register. d_waitrequest therefore does NOT
//     reach the arbiter's masters, and so does not reach ss_ctrl's state
//     machine. That is the other direction of the same boundary: the f2sdram
//     cmd_ready pin used to arrive at ss_ctrl's next-state logic through two
//     muxes and four LUT levels, 6.33 ns of it interconnect.
//
// The capture enable is `held` and nothing else -- a register local to this
// module. A stage whose enable came from the far end of the die would simply
// move the problem into the enable.
//
// COST. One cycle of command latency, and a command issue rate of one every
// two cycles rather than one per cycle. Both masters on this arbiter issue
// single-beat transfers only (ddram_ctrl hardwires m0_burstcount to 1, and
// a2065_ddr3_mailbox sets avl_burstcount to 1 at every assignment), so there
// is no burst whose beats this could throttle, and a single DDR3 access
// through the HPS bridge costs tens of cycles of latency before this stage
// adds one. If a future master ever wants real bursts, this becomes a
// two-entry skid -- `u_waitrequest = held & d_waitrequest` would restore full
// rate, at the price of putting d_waitrequest back on the upstream path, which
// is the thing this module exists to prevent.

module ddr_cmd_pipe
(
	input             clk,
	input             rst,

	// Upstream: the arbiter's slave-facing side.
	input      [28:0] u_address,
	input       [7:0] u_burstcount,
	input             u_read,
	input      [63:0] u_writedata,
	input       [7:0] u_byteenable,
	input             u_write,
	output            u_waitrequest,

	// Downstream: the HPS f2sdram bridge.
	output reg [28:0] d_address,
	output reg  [7:0] d_burstcount,
	output reg        d_read,
	output reg [63:0] d_writedata,
	output reg  [7:0] d_byteenable,
	output reg        d_write,
	input             d_waitrequest
);

// "A command is held here and the bridge has not taken it yet." The only
// thing upstream can see, and a register, which is the point.
reg held;
assign u_waitrequest = held;

always @(posedge clk) begin
	if (rst) begin
		held    <= 1'b0;
		d_read  <= 1'b0;
		d_write <= 1'b0;
	end
	else if (!held) begin
		// Capture while empty. The payload is latched unconditionally
		// alongside the strobes: when upstream is offering nothing the
		// strobes latch zero and whatever came in with them is never looked
		// at. Upstream saw u_waitrequest low this cycle, so Avalon says the
		// command is accepted now, and it is -- it is in these flops.
		d_address    <= u_address;
		d_burstcount <= u_burstcount;
		d_writedata  <= u_writedata;
		d_byteenable <= u_byteenable;
		d_read       <= u_read;
		d_write      <= u_write;
		held         <= u_read | u_write;
	end
	else if (!d_waitrequest) begin
		// Taken. Avalon accepts on the first cycle waitrequest is low, so the
		// strobes drop here and nowhere else. held and the strobes clear
		// together, which is what lets the branch above assume the strobes
		// are already zero when it latches a cycle with no command in it.
		d_read  <= 1'b0;
		d_write <= 1'b0;
		held    <= 1'b0;
	end
end

endmodule
