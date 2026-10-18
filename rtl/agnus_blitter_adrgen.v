// Blitter address generator
// It can increment or decrement selected pointer register or add or substract any selected modulo register

module agnus_blitter_adrgen
(
	input	clk,					// bus clock
	input clk7_en,
	input	reset,					// reset
	input	[1:0] ptrsel,			// pointer register selection
	input	[1:0] modsel,			// modulo register selection
	input	enaptr,					// enable pointer selection and update
	input	incptr,					// increase selected pointer register
	input	decptr,					// decrease selected pointer register
	input	addmod,					// add selected modulo register to selected pointer register
	input	submod,					// substract selected modulo register from selected pointer register
	output	sign_out,				// sign output (used for line mode)
	input	[15:0] data_in,			// bus data in
	input	[8:1] reg_address_in,	// register address input
	output	[20:1] address_out		// generated address out
);

//register names and addresses
parameter BLTAMOD = 9'h064;
parameter BLTBMOD = 9'h062;
parameter BLTCMOD = 9'h060;
parameter BLTDMOD = 9'h066;
parameter BLTAPTH = 9'h050;
parameter BLTAPTL = 9'h052;
parameter BLTBPTH = 9'h04c;
parameter BLTBPTL = 9'h04e;
parameter BLTCPTH = 9'h048;
parameter BLTCPTL = 9'h04a;
parameter BLTDPTH = 9'h054;
parameter BLTDPTL = 9'h056;

//channel select codes
parameter CHA = 2'b10;			// channel A
parameter CHB = 2'b01;			// channel B
parameter CHC = 2'b00;			// channel C
parameter CHD = 2'b11;			// channel D

//local signals
wire 	[1:0]	bltptr_sel;		// blitter pointer select
wire 	[20:1]	bltptr_in;		// blitter pointer registers input
reg		[20:16] bltpth [3:0];	// blitter pointer register bank (high)
wire	[20:16] bltpth_out;		// blitter pointer register bank output (high)
reg		[15:1]  bltptl [3:0];	// blitter pointer register bank (low)
wire	[15:1]  bltptl_out;		// blitter pointer register bank output (low)
wire	[20:1]	bltptr_out;		// blitter pointer register bank output

wire 	[1:0]	bltmod_sel;		// blitter modulo register select
reg		[15:1]  bltmod [3:0];	// blitter modulo register bank
wire	[15:1]  bltmod_out;		// blitter modulo register bank output

reg		[20:1]  newptr;			// new pointer value
reg 	[20:1]	t_newptr; 		// temporary pointer value

//--------------------------------------------------------------------------------------

//pointer register bank

assign bltptr_in[20:1] = enaptr ? newptr[20:1] : {data_in[4:0], data_in[15:1]};

assign bltptr_sel = enaptr ? ptrsel : {reg_address_in[4],reg_address_in[2]};

always @(posedge clk)
  if (clk7_en) begin
  	if (enaptr || reg_address_in[8:1]==BLTAPTH[8:1] || reg_address_in[8:1]==BLTBPTH[8:1] || reg_address_in[8:1]==BLTCPTH[8:1] || reg_address_in[8:1]==BLTDPTH[8:1])
  		bltpth[bltptr_sel] <= bltptr_in[20:16];
  end

// The bank is read at ptrsel, not at the write select. The read value is used
// in three places, and in each of them the two selects agree:
//  - address_out, only in a cycle Agnus grants to the blitter. The blitter asks
//    for the bus only in states A-D, F, LB, L2 and L4, and enaptr there is
//    dma_ack or enable, both 1 in a granted cycle.
//  - newptr, written back only when enaptr is 1.
//  - sign_out, latched only in L1 with enable, where enaptr = enable = 1.
// Reading at the write select put Agnus's register bus -- the output of its
// DMA priority mux -- and dma_ack/enable, which are arbitration too, in front
// of the bank's read port. Every arbitration input (floppy select, beam
// compares, BPLCON0, the CPU address) then reached sdram_ctrl's sd_addr
// through address_out, Gary and row_new (docs/seed-lottery.md, family A).
// rtl/sim/bltrd proves agnus identical to the previous version on every clock.
assign bltpth_out = bltpth[ptrsel];		
		
always @(posedge clk)
  if (clk7_en) begin
  	if (enaptr || reg_address_in[8:1]==BLTAPTL[8:1] || reg_address_in[8:1]==BLTBPTL[8:1] || reg_address_in[8:1]==BLTCPTL[8:1] || reg_address_in[8:1]==BLTDPTL[8:1])
  		bltptl[bltptr_sel] <= bltptr_in[15:1];
  end

assign bltptl_out = bltptl[ptrsel];

assign bltptr_out = {bltpth_out, bltptl_out};	
	
assign address_out = bltptr_out;
    
//--------------------------------------------------------------------------------------

//modulo register bank

assign bltmod_sel = enaptr ? modsel : reg_address_in[2:1];

always @(posedge clk)
  if (clk7_en) begin
  	if (reg_address_in[8:3]==BLTAMOD[8:3])
  		bltmod[bltmod_sel] <= data_in[15:1];
  end
assign bltmod_out = bltmod[modsel];

//--------------------------------------------------------------------------------------

// pointer arithmetic unit

// increment or decrement selected pointer
always @(*)
	if (incptr && !decptr)
		t_newptr = bltptr_out + 20'h1; // increment selected pointer
	else if (!incptr && decptr)
		t_newptr = bltptr_out - 20'h1; // decrement selected pointer
	else
		t_newptr = bltptr_out;

// add or substract modulo
always @(*)
	if (addmod && !submod)
		newptr = t_newptr + {{5{bltmod_out[15]}},bltmod_out[15:1]}; // add modulo (sign extended)
	else if (!addmod && submod)
		newptr = t_newptr - {{5{bltmod_out[15]}},bltmod_out[15:1]}; // substract modulo (sign extended)
	else
		newptr = t_newptr;

//sign output
assign sign_out = newptr[15]; // used in line mode as the sign of Bresenham's error accumulator (channel A pointer acts as an accumulator)


endmodule

