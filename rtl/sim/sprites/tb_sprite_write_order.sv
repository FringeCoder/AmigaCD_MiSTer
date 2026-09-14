// denise_sprites_shifter: SPRxDATx write vs shift-register load ordering.
//
// Minimig copies SPRxDATA/SPRxDATB into the display shift register one clk7
// after the SPRxPOS horizontal match, and a bus write commits half a clk7 after
// its write cycle -- so a write landing ON the match cycle always reached that
// same line's copy. Real Denise does not behave that way. Per WinUAE 1e47b230
// the ordering depends on SPRxCTL bit 0, the sprite's sub-pixel horizontal bit:
//
//   bit 0 clear  the copy happens first, so the PREVIOUSLY loaded SPRxDATx is
//                displayed and the new value waits for the following match
//   bit 0 set    the new SPRxDATx is stored first and is what gets shifted out
//
// Four write positions x two bit-0 values, on both data registers. Only one of
// the sixteen cells changes with the fix; the other fifteen are the guard that
// it changed nothing else, which is the half that is easy to get wrong.
//
// Runs standalone under Icarus:
//   iverilog -g2012 -o tb ../../denise_sprites_shifter.v tb_sprite_write_order.sv && vvp tb

`timescale 1ns/1ps

module tb_sprite_write_order;

	localparam [1:0] POS  = 2'b00;
	localparam [1:0] CTL  = 2'b01;
	localparam [1:0] DATA = 2'b10;
	localparam [1:0] DATB = 2'b11;

	// POS carries hstart[8:1]; CTL bit 0 carries hstart[0]. With POS = 0x40 the
	// match column is hstart[7:0] = 0x80 | bit0, and hstart[8] = 0.
	localparam [7:0] POS_VAL = 8'h40;

	localparam [15:0] FIRST_A  = 16'hAAAA;
	localparam [15:0] SECOND_A = 16'h5555;
	localparam [15:0] FIRST_B  = 16'hF0F0;
	localparam [15:0] SECOND_B = 16'h0F0F;

	localparam LINE_LEN = 9'd228;

	// where in the line the second write lands, relative to the match
	localparam integer W_NONE   = 0;
	localparam integer W_BEFORE = 1;
	localparam integer W_ON     = 2;
	localparam integer W_AFTER  = 3;

	reg clk = 0;
	reg [1:0] phase = 0;

	always #1 clk = ~clk;
	always @(posedge clk) phase <= phase + 2'd1;

	// clk7_en and clk7n_en are the two halves of the 7 MHz period. The data
	// registers commit on clk7n_en, which is what puts a write half a clk7
	// after its write cycle -- the whole reason this ordering question exists.
	wire clk7_en  = (phase == 2'd0);
	wire clk7n_en = (phase == 2'd2);

	reg  [8:0] hpos = 0;
	always @(posedge clk) if (clk7_en) hpos <= (hpos == LINE_LEN - 1) ? 9'd0 : hpos + 9'd1;

	// Scheduled bus writes: each entry fires on the clk7_en edge where hpos
	// equals its column. Driving off hpos rather than from the test sequence
	// keeps every write on a named cycle, which is what the whole check is
	// about -- "one cycle before" has to mean exactly that.
	localparam integer NSLOT = 6;
	reg        slot_valid [0:NSLOT-1];
	reg  [8:0] slot_col   [0:NSLOT-1];
	reg  [1:0] slot_addr  [0:NSLOT-1];
	reg [15:0] slot_data  [0:NSLOT-1];

	reg         aen;
	reg  [1:0]  address;
	reg [15:0]  data_in;

	integer k;
	always @(*) begin
		aen     = 1'b0;
		address = 2'b00;
		data_in = 16'h0000;
		for (k = 0; k < NSLOT; k = k + 1)
			if (slot_valid[k] && hpos == slot_col[k]) begin
				aen     = 1'b1;
				address = slot_addr[k];
				data_in = slot_data[k];
			end
	end

	reg reset = 1;
	reg shift = 0;

	denise_sprites_shifter dut (
		.clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
		.reset(reset),
		.aen(aen), .address(address),
		.hpos(hpos),
		.fmode(16'h0000),
		.shift(shift),
		.chip48(48'h0),
		.data_in(data_in),
		.sprdata(), .attach()
	);

	integer errors = 0;

	task clear_slots;
		integer j;
		begin
			for (j = 0; j < NSLOT; j = j + 1) slot_valid[j] = 1'b0;
		end
	endtask

	task set_slot(input integer j, input [8:0] col, input [1:0] a, input [15:0] d);
		begin
			slot_valid[j] = 1'b1;
			slot_col[j]   = col;
			slot_addr[j]  = a;
			slot_data[j]  = d;
		end
	endtask

	task goto(input [8:0] col);
		begin
			wait (hpos != col);
			wait (hpos == col);
			@(posedge clk);
		end
	endtask

	// One case: set the sprite up early in the line, put the second write at the
	// named offset from the match, and read back what the shift register loaded.
	// reg_sel 0 = SPRxDATA (checked in shifta), 1 = SPRxDATB (checked in shiftb).
	task run_case(input [511:0] name, input ctl_bit0, input integer wpos,
	              input reg_sel, input [15:0] want);
		reg [8:0] match_col;
		reg [15:0] got;
		reg [1:0] second_addr;
		reg [15:0] first_a, first_b, second_val;
		begin
			match_col  = {1'b0, POS_VAL[6:0], ctl_bit0};  // hstart[7:0] = 0x80 | bit0
			second_addr = reg_sel ? DATB : DATA;
			second_val  = reg_sel ? SECOND_B : SECOND_A;
			first_a     = FIRST_A;
			first_b     = FIRST_B;

			goto(9'd0);
			clear_slots;
			set_slot(0, 9'd10, POS,  {8'h00, POS_VAL});
			set_slot(1, 9'd12, CTL,  {15'h0000, ctl_bit0});
			set_slot(2, 9'd14, DATA, first_a);   // also arms the sprite
			set_slot(3, 9'd16, DATB, first_b);

			case (wpos)
				W_BEFORE: set_slot(4, match_col - 9'd1, second_addr, second_val);
				W_ON:     set_slot(4, match_col,        second_addr, second_val);
				W_AFTER:  set_slot(4, match_col + 9'd1, second_addr, second_val);
				default:  ;   // W_NONE: no second write at all
			endcase

			// load is registered at the match, so the copy happens at match+1.
			goto(match_col + 9'd3);
			got = reg_sel ? dut.shiftb[63:48] : dut.shifta[63:48];

			if (got !== want) begin
				$display("FAIL: %0s: shift register loaded %04x, want %04x", name, got, want);
				errors = errors + 1;
			end else begin
				$display("ok:   %0s = %04x", name, got);
			end
		end
	endtask

	initial begin
		clear_slots;
		repeat (20) @(posedge clk);
		reset = 0;

		// ---- SPRxDATA -------------------------------------------------------
		// No write on the match: the last value written is what loads, whatever
		// bit 0 says. This is the case that must not move.
		run_case("bit0=0, no write at the match",     1'b0, W_NONE,   1'b0, FIRST_A);
		run_case("bit0=1, no write at the match",     1'b1, W_NONE,   1'b0, FIRST_A);

		// A write one cycle early is seen by this line's copy either way.
		run_case("bit0=0, write one cycle before",    1'b0, W_BEFORE, 1'b0, SECOND_A);
		run_case("bit0=1, write one cycle before",    1'b1, W_BEFORE, 1'b0, SECOND_A);

		// The collision. bit 0 clear: copy first, so the OLD value displays.
		// bit 0 set: store first, so the new value displays. Only the first of
		// these two changes with the fix.
		run_case("bit0=0, write ON the match",        1'b0, W_ON,     1'b0, FIRST_A);
		run_case("bit0=1, write ON the match",        1'b1, W_ON,     1'b0, SECOND_A);

		// A write one cycle late lands after the copy and waits for next line.
		run_case("bit0=0, write one cycle after",     1'b0, W_AFTER,  1'b0, FIRST_A);
		run_case("bit0=1, write one cycle after",     1'b1, W_AFTER,  1'b0, FIRST_A);

		// ---- SPRxDATB -------------------------------------------------------
		// The same rule on the other register, because it is a second copy of
		// the same logic and a copy is where a wrong register name hides.
		run_case("DATB bit0=0, no write at the match", 1'b0, W_NONE,   1'b1, FIRST_B);
		run_case("DATB bit0=0, write one cycle before",1'b0, W_BEFORE, 1'b1, SECOND_B);
		run_case("DATB bit0=0, write ON the match",    1'b0, W_ON,     1'b1, FIRST_B);
		run_case("DATB bit0=1, write ON the match",    1'b1, W_ON,     1'b1, SECOND_B);
		run_case("DATB bit0=0, write one cycle after", 1'b0, W_AFTER,  1'b1, FIRST_B);

		if (errors == 0) $display("RUN: PASS");
		else             $display("RUN: FAIL (%0d)", errors);
		$finish;
	end

	initial begin
		#4000000;
		$display("FAIL: timeout");
		$display("RUN: FAIL (timeout)");
		$finish;
	end

endmodule
