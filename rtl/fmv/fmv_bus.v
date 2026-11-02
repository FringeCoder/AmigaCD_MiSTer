// fmv_bus.v -- the CD32 FMV module, 68k side (clk_sys).
//
// Implements the FPGA half of FringeCoder/AmigaCD docs/fmv-contract.md (v3)
// as seen from the 68k bus: the register file both sides write, the 68k write
// masks, CL450 HMEM indirection, the INT line, the L64111 read acknowledge,
// the event stream to Main, back-pressure, autoconfig nibbles, and ROM/RAM
// requests to the DDR3 half. The DDR3 half (fmv_ddr.v) carries events out and
// updates in; fmv.v ties the two together.
//
// The reference this must match is FringeCoder/AmigaCD
// tests/fmv_fpga_ref.h; the bench is rtl/sim/fmv/tb_fmv.sv.
//
// Board offsets (cpu_addr[19:1], the board decodes 1 MB):
//   0x00000-0x3FFFF ROM      DDR3 image, read only
//   0x40000-0x4FFFF IO word  register file 0xA0
//   0x50000-0x5FFFF L64111   register file 0x80 + A[5:1]
//   0x60000-0x6FFFF CL450 data port (CMEM), write only: events
//   0x70000-0x7FFFF CL450    register file A[7:1]
//   0x80000-0xFFFFF RAM      DDR3 image
//
// The register file does NOT reset with the Amiga: ALIVE, the masks and the
// autoconfig nibbles must outlive it. An Amiga reset posts a RESET event and
// Main pushes the chips' reset values again.

module fmv_bus (
	input  wire        clk,
	input  wire        amiga_reset,     // active high
	input  wire        fmv_on,          // status[64]

	// 68k bus, as minimig hands it to the A2065
	input  wire [23:1] cpu_addr,
	input  wire [15:0] cpu_data_in,
	output wire [15:0] cpu_data_out,    // 0 unless this board is read
	input  wire        cpu_rw,          // 1 = read
	input  wire        cpu_as_n,
	input  wire        cpu_uds_n,
	input  wire        cpu_lds_n,
	input  wire        sel,             // the board's 1 MB, decoded by gary
	output wire        nrdy,
	output wire        int2,

	// autoconfig (cpu_wrapper)
	output wire        ac_present,      // join the chain at the next reset
	input  wire  [5:0] ac_nib_addr,     // chip_addr[6:1]
	output wire  [3:0] ac_nib,

	// events to the DDR3 half: {data, haddr, offset, reset, lds, uds, rw}
	output reg         ev_wr = 1'b0,
	output reg  [47:0] ev_data,
	input  wire        ev_full,

	// updates from the DDR3 half: {rdidx, mask, value, guard, maskfile, index}
	input  wire        up_empty,
	input  wire [74:0] up_data,
	output reg         up_rd = 1'b0,

	// ROM/RAM requests to the DDR3 half (toggle handshake)
	output reg         mreq_t = 1'b0,
	output reg  [19:1] maddr,
	output reg         mrw,             // 1 = read
	output reg   [1:0] mbe,             // {UDS, LDS}
	output reg  [15:0] mwdata,
	input  wire        mack_t,          // toggles when the access is done
	input  wire [15:0] mrdata
);

	// ---------------------------------------------------------------- state

	// The register file proper: CL450 0x00-0x7F, L64111 0x80-0x9F, IO 0xA0,
	// HMEM 0xB0-0xBF, as {mask, value}. 0x44 HOST_raddr and 0x48
	// HOST_control live in flops (rf_44, rf_48), as do 0xC0-0xDF.
	reg [31:0] rf [0:191];
	integer i;
	initial for (i = 0; i < 192; i = i + 1) rf[i] = 32'd0;

	reg [15:0] r44 = 16'h0000, m44 = 16'h0000;    // HOST_raddr
	reg [15:0] r48 = 16'h0080, m48 = 16'h0000;    // HOST_control: Int=1, INT inactive
	reg        alive     = 1'b0;                   // 0xC0[0]
	reg        l64_int   = 1'b0;                   // 0xC1[0]
	reg [15:0] rdidx_lo  = 16'h0000;               // 0xC2
	reg [15:0] rdidx_hi  = 16'h0000;               // 0xC3
	reg [15:0] io_map_cl = 16'h0000;               // 0xC4
	reg [15:0] io_map_l64 = 16'h0000;              // 0xC5
	reg [15:0] io_pol    = 16'h0000;               // 0xC6
	// 0xD0-0xDF as one vector, not an array: register r is bits 16r+15:16r,
	// so nibble n is bits 4n+3:4n. Quartus 17 infers an array as RAM and then
	// fails to map the random reads below to a read port (an internal error in
	// its Verilog frontend), so this stays plain flops.
	reg [255:0] autocfg = 256'd0;

	reg [31:0] ev_count    = 32'd0;   // events posted, ever
	reg [31:0] l64_ack_idx = 32'd0;
	reg        l64_acked   = 1'b0;

	wire cl_int = ~r48[7];                         // [CL 8-12]
	assign int2       = fmv_on & alive & (cl_int | l64_int);
	assign ac_present = fmv_on & alive;
	assign ac_nib = autocfg[{ac_nib_addr, 2'b00} +: 4];

	// ---------------------------------------------------------- the access

	wire        ds      = ~cpu_uds_n | ~cpu_lds_n;
	wire        access  = sel & ~cpu_as_n & ds & fmv_on;
	wire [19:0] off     = {cpu_addr[19:1], 1'b0};
	wire        is_rom  = (off[19:18] == 2'b00);
	wire        is_ram  =  off[19];
	wire        is_l64  = (off[19:16] == 4'h5);
	wire        is_cmem = (off[19:16] == 4'h6);
	wire        is_cl   = (off[19:16] == 4'h7);
	wire  [6:0] cl_r    = cpu_addr[7:1];           // CL450 register, byte offset / 2
	wire  [4:0] l64_r   = cpu_addr[5:1];
	wire [15:0] lanes   = {{8{~cpu_uds_n}}, {8{~cpu_lds_n}}};

	wire [15:0] backlog    = ev_count[15:0] - rdidx_lo;
	wire        ring_full  = (backlog >= 16'd4095);   // contract: low half, mod 2^16

	localparam S_IDLE = 3'd0, S_RD1 = 3'd1, S_RD2 = 3'd2, S_MEM = 3'd3,
	           S_POST = 3'd4, S_DONE = 3'd5, S_UP1 = 3'd6, S_UP2 = 3'd7;
	reg  [2:0] st = S_IDLE;

	reg  [7:0] idx;           // register-file index of the access or update
	reg        use_ff;        // the index lives in a flop, not the RAM
	reg [31:0] rf_q;          // registered RAM read
	reg [15:0] rd_val;        // what a read returns
	reg  [3:0] ev_haddr;
	reg [74:0] upd;
	reg        rst_d = 1'b0, rst_pend = 1'b0;
	reg        mack_s1 = 1'b0, mack_s2 = 1'b0, mack_s3 = 1'b0;

	// nrdy from the moment the access is seen until it is served, so an
	// access that arrives while an update is being applied cannot slip by.
	assign nrdy = access & (st != S_DONE);
	assign cpu_data_out = (sel & fmv_on & cpu_rw & (st == S_DONE)) ? rd_val : 16'h0000;

	wire [7:0] acc_idx = is_cl  ? {1'b0, cl_r} :
	                     is_l64 ? {3'b100, l64_r} :
	                              8'hA0;
	wire       is_rdata = is_cl & (cl_r == 7'h46);
	wire [7:0] hm_idx   = {4'hB, r44[3:0]};

	// The IO word with the interrupt mirrors applied (contract, register file)
	function [15:0] io_view(input [15:0] v);
		reg [15:0] a;
		begin
			a = (v & ~io_map_cl)  | ((cl_int  ? io_pol : ~io_pol) & io_map_cl);
			io_view = (a & ~io_map_l64) | ((l64_int ? io_pol : ~io_pol) & io_map_l64);
		end
	endfunction

	// The flop registers a 68k access can reach: HOST_raddr and HOST_control.
	// (0xC0-0xDF have no 68k address.)
	wire [15:0] ff_q = (idx == 8'h44) ? r44 : r48;

	// The register file RAM: one read port, one registered write port, so
	// Quartus maps it to block RAM. The read address is the access's index,
	// or the update's while one is being applied (S_UP1); the data is in
	// rf_q a clock later. A write is issued from S_RD2 or S_UP2 and lands on
	// the next clock, before anything can read that entry again.
	wire [7:0] rf_ra = (st == S_UP1) ? upd[7:0] : idx;
	reg        rf_we = 1'b0;
	reg  [7:0] rf_wa;
	reg [31:0] rf_wd;
	always @(posedge clk) begin
		rf_q <= rf[rf_ra];
		if (rf_we)
			rf[rf_wa] <= rf_wd;
	end

	// update fields
	wire  [7:0] u_index    = upd[7:0];
	wire        u_maskfile = upd[8];
	wire        u_guard    = upd[9];
	wire [15:0] u_value    = upd[25:10];
	wire [15:0] u_mask     = upd[41:26];
	wire [31:0] u_rdidx    = upd[73:42];
	wire        u_drop     = u_guard & l64_acked & ($signed(u_rdidx - l64_ack_idx) <= 0);
	wire        u_ff       = (u_index == 8'h44) | (u_index == 8'h48) | (u_index >= 8'hC0);

	always @(posedge clk) begin
		ev_wr <= 1'b0;
		up_rd <= 1'b0;
		rf_we <= 1'b0;

		mack_s1 <= mack_t;
		mack_s2 <= mack_s1;
		mack_s3 <= mack_s2;

		// An Amiga reset while the board is on is an event (contract: RESET)
		rst_d <= amiga_reset;
		if (amiga_reset & ~rst_d & fmv_on & alive)
			rst_pend <= 1'b1;

		case (st)
		S_IDLE: begin
			if (access) begin
				ev_haddr <= 4'd0;
				if (is_rom & cpu_rw | is_ram) begin
					// ROM and RAM: a DDR3 access, not an event
					maddr  <= cpu_addr[19:1];
					mrw    <= cpu_rw;
					mbe    <= {~cpu_uds_n, ~cpu_lds_n};
					mwdata <= cpu_data_in;
					mreq_t <= ~mreq_t;
					st     <= S_MEM;
				end else if (!ev_full && !ring_full) begin
					if (is_rom | is_cmem) begin
						// A write into the ROM is dropped; the data port is
						// write-only and reads return 0xFFFF. Both are posted.
						rd_val <= 16'hFFFF;
						st     <= S_POST;
					end else begin
						idx    <= is_rdata ? hm_idx : acc_idx;
						use_ff <= ~is_rdata & ((acc_idx == 8'h44) | (acc_idx == 8'h48));
						if (is_rdata)
							ev_haddr <= r44[3:0];
						st <= S_RD1;
					end
				end
				// else: the ring or the crossing is full; hold the 68k
			end else if (rst_pend && !ev_full) begin
				ev_data  <= 48'h8;          // RESET, every other field 0
				ev_wr    <= 1'b1;
				ev_count <= ev_count + 1'd1;
				rst_pend <= 1'b0;
			end else if (!up_empty) begin
				upd   <= up_data;
				up_rd <= 1'b1;
				st    <= S_UP1;
			end
		end

		S_RD1: begin                          // RAM read in flight (rf_ra = idx)
			st   <= S_RD2;
		end

		S_RD2: begin
			// A read returns the register; a write merges under the mask.
			if (cpu_rw) begin
				if (use_ff)
					rd_val <= ff_q;
				else if (idx == 8'hA0)
					rd_val <= io_view(rf_q[15:0]);
				else
					rd_val <= rf_q[15:0];
				if (idx == 8'h84 || idx == 8'h85) begin
					// Reading either L64111 status register deasserts INTR
					// [L64 4-9]; the ack index is this event's index.
					l64_int     <= 1'b0;
					l64_ack_idx <= ev_count;
					l64_acked   <= 1'b1;
				end
			end else begin
				if (idx == 8'h44)
					r44 <= (r44 & ~(m44 & lanes)) | (cpu_data_in & m44 & lanes);
				else if (idx == 8'h48)
					r48 <= (r48 & ~(m48 & lanes)) | (cpu_data_in & m48 & lanes);
				else begin
					rf_we <= 1'b1;
					rf_wa <= idx;
					rf_wd <= {rf_q[31:16],
					          (rf_q[15:0] & ~(rf_q[31:16] & lanes)) |
					          (cpu_data_in & rf_q[31:16] & lanes)};
				end
				// HOST_rdata: HAddr steps on after a write [CL 8-13]
				if (idx[7:4] == 4'hB)
					r44[3:0] <= r44[3:0] + 1'd1;
				rd_val <= 16'h0000;
			end
			st <= S_POST;
		end

		S_POST: begin
			// The event carries what the read returned, or the write data.
			ev_data <= {cpu_rw ? rd_val : cpu_data_in, 4'd0, ev_haddr, off, 1'b0,
			            ~cpu_lds_n, ~cpu_uds_n, cpu_rw};
			ev_wr    <= 1'b1;
			ev_count <= ev_count + 1'd1;
			st       <= S_DONE;
		end

		S_MEM: begin
			if (mack_s2 != mack_s3)
				st <= S_DONE;
		end

		S_DONE: begin
			if (!access)
				st <= S_IDLE;
		end

		S_UP1: begin                          // RAM read in flight (rf_ra = u_index)
			st   <= S_UP2;
		end

		S_UP2: begin
			if (u_maskfile) begin
				if (u_index == 8'h44)      m44 <= u_value;
				else if (u_index == 8'h48) m48 <= u_value;
				else if (!u_ff) begin
					rf_we <= 1'b1;
					rf_wa <= u_index;
					rf_wd <= {u_value, rf_q[15:0]};
				end
			end else if (!u_drop) begin
				case (u_index)
				8'h44: r44 <= (r44 & ~u_mask) | (u_value & u_mask);
				8'h48: r48 <= (r48 & ~u_mask) | (u_value & u_mask);
				8'hC0: alive   <= (alive   & ~u_mask[0]) | (u_value[0] & u_mask[0]);
				8'hC1: l64_int <= (l64_int & ~u_mask[0]) | (u_value[0] & u_mask[0]);
				8'hC2: rdidx_lo   <= (rdidx_lo   & ~u_mask) | (u_value & u_mask);
				8'hC3: rdidx_hi   <= (rdidx_hi   & ~u_mask) | (u_value & u_mask);
				8'hC4: io_map_cl  <= (io_map_cl  & ~u_mask) | (u_value & u_mask);
				8'hC5: io_map_l64 <= (io_map_l64 & ~u_mask) | (u_value & u_mask);
				8'hC6: io_pol     <= (io_pol     & ~u_mask) | (u_value & u_mask);
				default:
					if (u_index[7:4] == 4'hD)
						autocfg[{u_index[3:0], 4'd0} +: 16] <=
							(autocfg[{u_index[3:0], 4'd0} +: 16] & ~u_mask) | (u_value & u_mask);
					else if (u_index < 8'hC0) begin
						rf_we <= 1'b1;
						rf_wa <= u_index;
						rf_wd <= {rf_q[31:16], (rf_q[15:0] & ~u_mask) | (u_value & u_mask)};
					end
				endcase
			end
			st <= S_IDLE;
		end
		endcase

		// A ROM/RAM read's data is taken as the access completes. fmv_ddr
		// holds mrdata from before it toggles mack_t, so it has been stable
		// for the two synchroniser stages by the time the edge is seen here.
		if (st == S_MEM && (mack_s2 != mack_s3) && mrw)
			rd_val <= mrdata;
	end

endmodule
