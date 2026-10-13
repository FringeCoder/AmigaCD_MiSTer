// OCS/ECS dual playfield colour and opacity, every 6-plane pixel under every
// BPLCON2 value, dumped for check_dpf_priority.py to compare against vAmiga's
// translateDPF.
//
// vAmigaTS Denise/Registers/BPLCON2/dualpf1-12 sweep the priority codes. A
// playfield whose code is invalid (PFxP > 4) is drawn in COLOR00 on an A500
// but still hides the other playfield; the core drew it in its own colours.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../denise_playfields.v tb_dpf_priority.sv
//   vvp tb > dpf.txt && python3 check_dpf_priority.py dpf.txt

`timescale 1ns/1ps

module tb_dpf_priority;
	reg  [8:1] bpldata;
	reg  [6:0] bplcon2;
	reg        aga = 0;
	wire [2:1] nplayfield;
	wire [7:0] plfdata;
	integer d, c;

	denise_playfields dut (
		.aga(aga), .bpldata(bpldata), .dblpf(1'b1), .pf2of(3'd3),
		.bplcon2(bplcon2), .nplayfield(nplayfield), .plfdata(plfdata)
	);

	initial begin
		for (c = 0; c < 128; c = c + 1)
			for (d = 0; d < 64; d = d + 1) begin
				bplcon2 = c; bpldata = {2'b00, d[5:0]}; #1;
				$display("P %0d %0d %0d %0d", c, d, nplayfield, plfdata);
			end
		$finish;
	end
endmodule
