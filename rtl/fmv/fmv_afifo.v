// fmv_afifo.v -- a small dual-clock FIFO for the FMV front end.
//
// Gray-coded pointers, two-flop synchronisers, show-ahead read (rdata is the
// head whenever !empty). Depth 2^AW. Used for the two crossings between the
// 68k bus clock and the DDR3 clock (fmv.v).

module fmv_afifo #(
	parameter W  = 48,
	parameter AW = 4
) (
	input  wire         wclk,
	input  wire         wr,
	input  wire [W-1:0] wdata,
	output wire         full,

	input  wire         rclk,
	input  wire         rd,
	output wire [W-1:0] rdata,
	output wire         empty
);
	reg [W-1:0] mem [0:(1<<AW)-1];

	reg [AW:0] wbin = 0, wgray = 0, rbin = 0, rgray = 0;
	reg [AW:0] rgray_w1 = 0, rgray_w2 = 0;   // read pointer in the write domain
	reg [AW:0] wgray_r1 = 0, wgray_r2 = 0;   // write pointer in the read domain

	wire [AW:0] wbin_n  = wbin + 1'd1;
	wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
	wire [AW:0] rbin_n  = rbin + 1'd1;
	wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

	assign full  = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});
	assign empty = (rgray == wgray_r2);
	assign rdata = mem[rbin[AW-1:0]];

	always @(posedge wclk) begin
		rgray_w1 <= rgray;
		rgray_w2 <= rgray_w1;
		if (wr && !full) begin
			mem[wbin[AW-1:0]] <= wdata;
			wbin  <= wbin_n;
			wgray <= wgray_n;
		end
	end

	always @(posedge rclk) begin
		wgray_r1 <= wgray;
		wgray_r2 <= wgray_r1;
		if (rd && !empty) begin
			rbin  <= rbin_n;
			rgray <= rgray_n;
		end
	end
endmodule
