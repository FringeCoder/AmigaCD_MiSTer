// fmv.v -- the CD32 FMV cartridge's front end (FringeCoder/AmigaCD
// docs/fmv-plan.md, phase 2). Everything the board needs on the FPGA side;
// the chips themselves are modelled in Main (support/minimig/fmv_model.cpp).
//
//   68k side (clk_sys)        this module                    Main (via DDR3)
//   $2x0000 registers  <-->   fmv_bus: register file  --->   event ring
//                             (Main writes it back     <---   update queue)
//   $200000 ROM, $280000 RAM  fmv_ddr: board image    <-->   window, 0x27000000
//   INT2               <----  ~HOST_control[7] | L64111 latch
//
// The contract is FringeCoder/AmigaCD docs/fmv-contract.md (v4). Off
// (status[64] clear) the board never joins the autoconfig chain, its DDR3
// master stays idle, and its ring and queue counters stand at zero.

module fmv (
	input  wire        clk_sys,
	input  wire        amiga_reset,
	input  wire        fmv_on,

	input  wire [23:1] cpu_addr,
	input  wire [15:0] cpu_data_in,
	output wire [15:0] cpu_data_out,
	input  wire        cpu_rw,
	input  wire        cpu_as_n,
	input  wire        cpu_uds_n,
	input  wire        cpu_lds_n,
	input  wire        sel,
	output wire        nrdy,
	output wire        int2,

	output wire        ac_present,
	input  wire  [5:0] ac_nib_addr,
	output wire  [3:0] ac_nib,

	input  wire        clk_ddr,
	output wire [28:0] mem_address,
	output wire  [7:0] mem_burstcount,
	output wire        mem_read,
	input  wire [63:0] mem_readdata,
	input  wire        mem_readdatavalid,
	output wire [63:0] mem_writedata,
	output wire  [7:0] mem_byteenable,
	output wire        mem_write,
	input  wire        mem_waitrequest,

	// The diag window (hps_ext 0xFA00), read by Main over SPI so it works
	// when the DDR3 path is what has failed (gate 1 rerun, 2026-11-02). In
	// clk_sys; the DDR3-side fields are sampled through two flops, so a
	// read can catch a multi-bit field mid-change. Fine for a debug window.
	output reg [127:0] diag
);
	wire        ev_wr, ev_full, ev_empty, ev_rd;
	wire [47:0] ev_wdata, ev_rdata;
	wire        up_wr, up_full, up_empty, up_rd;
	wire [74:0] up_wdata, up_rdata;
	wire        mreq_t, mrw, mack_t;
	wire [19:1] maddr;
	wire  [1:0] mbe;
	wire [15:0] mwdata, mrdata;

	wire  [3:0] bus_dbg;
	wire [15:0] d_flags, d_polls, d_rvalid, d_dwell, d_uq_rd, d_uq_w, d_n;

	fmv_bus bus (
		.clk(clk_sys), .amiga_reset(amiga_reset), .fmv_on(fmv_on),
		.cpu_addr(cpu_addr), .cpu_data_in(cpu_data_in), .cpu_data_out(cpu_data_out),
		.cpu_rw(cpu_rw), .cpu_as_n(cpu_as_n), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
		.sel(sel), .nrdy(nrdy), .int2(int2),
		.ac_present(ac_present), .ac_nib_addr(ac_nib_addr), .ac_nib(ac_nib),
		.ev_wr(ev_wr), .ev_data(ev_wdata), .ev_full(ev_full),
		.up_empty(up_empty), .up_data(up_rdata), .up_rd(up_rd),
		.mreq_t(mreq_t), .maddr(maddr), .mrw(mrw), .mbe(mbe), .mwdata(mwdata),
		.mack_t(mack_t), .mrdata(mrdata), .dbg(bus_dbg)
	);

	fmv_afifo #(.W(48), .AW(4)) ev_fifo (
		.wclk(clk_sys), .wr(ev_wr), .wdata(ev_wdata), .full(ev_full),
		.rclk(clk_ddr), .rd(ev_rd), .rdata(ev_rdata), .empty(ev_empty)
	);

	fmv_afifo #(.W(75), .AW(4)) up_fifo (
		.wclk(clk_ddr), .wr(up_wr), .wdata(up_wdata), .full(up_full),
		.rclk(clk_sys), .rd(up_rd), .rdata(up_rdata), .empty(up_empty)
	);

	fmv_ddr ddr (
		.clk(clk_ddr), .on(fmv_on),
		.ev_empty(ev_empty), .ev_data(ev_rdata), .ev_rd(ev_rd),
		.up_wr(up_wr), .up_data(up_wdata), .up_full(up_full),
		.mreq_t(mreq_t), .maddr(maddr), .mrw(mrw), .mbe(mbe), .mwdata(mwdata),
		.mack_t(mack_t), .mrdata(mrdata),
		.avl_address(mem_address), .avl_burstcount(mem_burstcount),
		.avl_read(mem_read), .avl_write(mem_write), .avl_writedata(mem_writedata),
		.avl_byteenable(mem_byteenable), .avl_readdata(mem_readdata),
		.avl_readdatavalid(mem_readdatavalid), .avl_waitrequest(mem_waitrequest),
		.dbg_flags(d_flags), .dbg_polls(d_polls), .dbg_rvalid(d_rvalid),
		.dbg_dwell(d_dwell), .dbg_uq_rd(d_uq_rd), .dbg_uq_w(d_uq_w), .dbg_n(d_n)
	);

	// Layout, word 0 first (FringeCoder/AmigaCD support/minimig/fmv.cpp
	// decodes it; bump the version word if it changes):
	//   w0 0xF401   w1 flags: [15:12] fmv_ddr state, [11] on (synchronised),
	//   [10] up_full, [9] ev_empty, [8] poll timer at 0, [7] avl_read,
	//   [6] avl_write, [5] waitrequest, [4:2] fmv_bus state, [1] ALIVE,
	//   [0] status[64]   w2 UQ_WPTR polls accepted   w3 readdatavalid beats
	//   w4 clocks in the fmv_ddr state   w5 uq_rd   w6 UQ_WPTR as last read
	//   w7 events written
	reg [111:0] dd1, dd2;
	always @(posedge clk_ddr)
		dd1 <= {d_n, d_uq_w, d_uq_rd, d_dwell, d_rvalid, d_polls, d_flags};
	always @(posedge clk_sys) begin
		dd2  <= dd1;
		diag <= {dd2[111:16],
		         dd2[11:4], dd2[3:1], bus_dbg, fmv_on,   // flags word, see above
		         16'hF401};
	end
endmodule
