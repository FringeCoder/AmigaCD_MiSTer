`timescale 1ns/1ns

// CRC-32, reflected polynomial 0xEDB88320, init 0xFFFFFFFF, final xor
// 0xFFFFFFFF. Byte at a time: eight XOR stages per clock rather than
// thirty-two, because this core closes timing by 0.177 ns and a wide
// combinational CRC is exactly the kind of cloud that displaces the SDRAM
// address path. Four clocks per 32-bit word is ~18 ms for 2 MB, which is
// nothing against a save the user asked for.
//
// Matches crc32_compute() in support/minimig/minimig_a2065_crc32.cpp.

module ss_crc32
(
	input             clk,
	input             init,
	input             wr,
	input      [7:0]  byte_in,
	output     [31:0] crc_out,
	// crc_out's value after the next clock edge, for a consumer that wants to
	// register a comparison against it without lagging a cycle (ss_ctrl's
	// crc_eq).
	output     [31:0] crc_next
);

reg [31:0] crc = 32'hFFFFFFFF;

assign crc_out = ~crc;

// One bit of the reflected CRC step.
function [31:0] crc_bit;
	input [31:0] c;
begin
	crc_bit = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
end
endfunction

integer b;
reg [31:0] next;

always @(*) begin
	next = crc ^ {24'd0, byte_in};
	for (b = 0; b < 8; b = b + 1) next = crc_bit(next);
end

wire [31:0] crc_d = init ? 32'hFFFFFFFF : wr ? next : crc;
assign crc_next = ~crc_d;

always @(posedge clk) crc <= crc_d;

endmodule
