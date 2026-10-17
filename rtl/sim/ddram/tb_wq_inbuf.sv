// ddram_ctrl's write-queue drain picks e_drop from wq_inbuf[wq_h], a per-entry
// precompute of in_buf, instead of in_buf(wh_a[28:3]) on the muxed-out head
// (a timing change: one mux level off wq_a -> sb_kill / sc_kill). The two are
// the same function by construction, but tb_ddram_readreturn never makes in_buf
// true, so it cannot show it. This holds sysclk low, writes random values
// straight into the stream-buffer lines and the write queue -- addresses drawn
// from a small pool so they collide often -- and compares the module's own
// wq_inbuf[wq_h] with the original in_buf(wh_a) formula. Counts the true cases
// and fails on none.
`timescale 1ns/1ns
module tb_wq_inbuf;
ddram_ctrl dut (.sysclk(1'b0));

function [28:3] pick; input d; pick = 26'h1234560 + ($urandom % 3); endfunction

integer i, q, hits = 0, bad = 0;
reg [28:3] ha;
reg want;
initial begin
	for (i = 0; i < 100000; i = i + 1) begin
		dut.sb_v = $urandom; dut.sb_wait = $urandom; dut.sc_v = $urandom; dut.sc_wait = $urandom;
		dut.sb_a = pick(0); dut.sc_a = pick(0);
		for (q = 0; q < 4; q = q + 1) dut.wq_a[q] = {pick(0), 1'b0};
		dut.wq_h = $urandom;
		#1;
		ha   = dut.wq_a[dut.wq_h][28:3];
		want = ((dut.sb_v | dut.sb_wait) && (dut.sb_a == ha)) || ((dut.sc_v | dut.sc_wait) && (dut.sc_a == ha));
		if (want) hits = hits + 1;
		if (dut.wq_inbuf[dut.wq_h] !== want) begin
			if (bad < 5) $display("MISMATCH i=%0d wq_h=%0d want=%b got=%b", i, dut.wq_h, want, dut.wq_inbuf[dut.wq_h]);
			bad = bad + 1;
		end
	end
	$display("states %0d, in_buf true %0d, mismatches %0d", i, hits, bad);
	if (bad == 0 && hits > 0) $display("RUN: PASS"); else $display("RUN: FAIL");
	$finish;
end
endmodule
