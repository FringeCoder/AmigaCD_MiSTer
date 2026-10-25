/*
 * a2065.v — Commodore A2065 ZorroII Ethernet card.
 *
 * Everything the card needs on the FPGA side lives in here: the LANCE chip
 * registers, the boardram window, and the mailbox that carries both to the
 * host over DDR3. The rest of the core sees only the 68k bus, an interrupt,
 * and one memory port.
 *
 * The host half — the Am7990 controller itself, the descriptor rings and the
 * network socket — runs on the HPS, in Main under support/minimig/.
 *
 *   68k side (clk_sys)          this module                host (via DDR3)
 *   ------------------          ----------                 ---------------
 *   $EAxxxx chip regs   ---->   a2065_regfile     ---->     CMD ring
 *                               (CSR reads answered from a shadow the host
 *                                keeps current, so reads never stall)
 *   $EA8000 boardram    <-->    a2065_ddram       <-->      flat DDR3 window
 *                               (DTACK stretched for the DDR3 round trip)
 *   INT2                <----   a2065_ddr3_mailbox <----    interrupt state
 *
 * Register writes are posted to a ring and the bus released as soon as the
 * entry lands, so the Amiga never waits on host scheduling. Only the boardram
 * path stretches DTACK, and only for FPGA-side work.
 */

module a2065 (
    // ── 68k bus, Amiga clock domain ──────────────────────────────────────
    input  wire        clk_sys,
    input  wire        rst_n_sys,

    input  wire [23:1] cpu_addr,
    input  wire [15:0] cpu_data_in,
    output wire [15:0] cpu_data_out,   // zero unless this card is addressed
    input  wire        cpu_rw,         // 1 = read
    input  wire        cpu_as_n,
    input  wire        cpu_uds_n,
    input  wire        cpu_lds_n,
    input  wire        sel,            // $EAxxxx decode from gary
    output wire        nrdy,           // stretch DTACK
    output wire        int2,           // to Paula, already synchronised here

    input  wire [7:0]  card_base,      // autoconfig base address
    input  wire        card_configured,

    // ── DDR3, memory clock domain ────────────────────────────────────────
    input  wire        clk_ddr,
    output wire [28:0] mem_address,
    output wire [7:0]  mem_burstcount,
    output wire        mem_read,
    input  wire [63:0] mem_readdata,
    input  wire        mem_readdatavalid,
    output wire [63:0] mem_writedata,
    output wire [7:0]  mem_byteenable,
    output wire        mem_write,
    input  wire        mem_waitrequest,

    // ── lightweight HPS bridge, memory clock domain (MEASUREMENT ONLY,
    //    see visprobe_ddr3.v) ─────────────────────────────────────────────
    input  wire          lw_wr,
    input  wire  [1:0]   lw_waddr,
    input  wire  [31:0]  lw_wdata,
    output wire [127:0]  lw_status
);

    // ── chip registers ↔ mailbox ─────────────────────────────────────────
    wire        cmd_pending, cmd_clear;
    wire [6:0]  cmd_rap;
    wire [15:0] cmd_data;
    wire [15:0] csr0, csr1, csr2, csr3;

    // ── boardram window ↔ mailbox ────────────────────────────────────────
    wire        bram_req_valid, bram_req_rw, bram_req_ack, bram_resp_valid;
    wire [13:0] bram_req_addr;
    wire [15:0] bram_req_wdata, bram_resp_data;
    wire [1:0]  bram_req_be;

    wire [15:0] regs_dout, bram_dout;
    wire        regs_nrdy, bram_nrdy;

    // Both halves drive zero unless addressed, so the card presents a single
    // value to the core's read mux.
    assign cpu_data_out = regs_dout | bram_dout;
    assign nrdy         = regs_nrdy | bram_nrdy;

    a2065_regfile regfile (
        .clk            (clk_sys),
        .rst_n          (rst_n_sys),
        .cpu_addr       ({cpu_addr, 1'b0}),
        .cpu_rw         (cpu_rw),
        .cpu_as_n       (cpu_as_n),
        .cpu_ds_n       (cpu_uds_n & cpu_lds_n),
        .cpu_data_in    (cpu_data_in),
        .cpu_data_out   (regs_dout),
        .regs_nrdy      (regs_nrdy),
        .card_base      (card_base),
        .card_configured(card_configured),
        .cmd_pending    (cmd_pending),
        .cmd_rap        (cmd_rap),
        .cmd_data       (cmd_data),
        .cmd_clear      (cmd_clear),
        .csr0_in        (csr0),
        .csr1_in        (csr1),
        .csr2_in        (csr2),
        .csr3_in        (csr3)
    );

    a2065_ddram boardram (
        .clk_sys              (clk_sys),
        .rst_n_sys            (rst_n_sys),
        .cpu_addr             (cpu_addr),
        .cpu_data_in          (cpu_data_in),
        .cpu_data_out         (bram_dout),
        .cpu_rw               (cpu_rw),
        .cpu_as_n             (cpu_as_n),
        .cpu_uds_n            (cpu_uds_n),
        .cpu_lds_n            (cpu_lds_n),
        .sel                  (sel),
        .nrdy                 (bram_nrdy),
        .bram_req_valid       (bram_req_valid),
        .bram_req_addr        (bram_req_addr),
        .bram_req_wdata       (bram_req_wdata),
        .bram_req_rw          (bram_req_rw),
        .bram_req_be          (bram_req_be),
        .bram_req_ack_audio   (bram_req_ack),
        .bram_resp_valid_audio(bram_resp_valid),
        .bram_resp_data_audio (bram_resp_data)
    );

    wire int2_ddr;

    // The mailbox and the two probes share the A2065's DDR3 port; the
    // mailbox wins, then the latency probe (MEASUREMENT ONLY, see
    // latprobe_ddr3.v and visprobe_ddr3.v).
    wire [28:0] mb_address,   pr_address;
    wire [7:0]  mb_burstcount, pr_burstcount;
    wire        mb_read,      pr_read;
    wire [63:0] mb_readdata,  pr_readdata;
    wire        mb_readdatavalid, pr_readdatavalid;
    wire [63:0] mb_writedata, pr_writedata;
    wire [7:0]  mb_byteenable, pr_byteenable;
    wire        mb_write,     pr_write;
    wire        mb_waitrequest, pr_waitrequest;

    wire [28:0] lp_address,   vp_address;
    wire [7:0]  lp_burstcount, vp_burstcount;
    wire        lp_read,      vp_read;
    wire [63:0] lp_readdata,  vp_readdata;
    wire        lp_readdatavalid, vp_readdatavalid;
    wire [63:0] lp_writedata, vp_writedata;
    wire [7:0]  lp_byteenable, vp_byteenable;
    wire        lp_write,     vp_write;
    wire        lp_waitrequest, vp_waitrequest;

    latprobe_ddr3 latprobe (
        .clk              (clk_ddr),
        .rst_n            (rst_n_sys),
        .avl_address      (lp_address),
        .avl_burstcount   (lp_burstcount),
        .avl_read         (lp_read),
        .avl_readdata     (lp_readdata),
        .avl_readdatavalid(lp_readdatavalid),
        .avl_writedata    (lp_writedata),
        .avl_byteenable   (lp_byteenable),
        .avl_write        (lp_write),
        .avl_waitrequest  (lp_waitrequest)
    );

    visprobe_ddr3 visprobe (
        .clk              (clk_ddr),
        .rst_n            (rst_n_sys),
        .lw_wr            (lw_wr),
        .lw_waddr         (lw_waddr),
        .lw_wdata         (lw_wdata),
        .lw_status        (lw_status),
        .avl_address      (vp_address),
        .avl_burstcount   (vp_burstcount),
        .avl_read         (vp_read),
        .avl_readdata     (vp_readdata),
        .avl_readdatavalid(vp_readdatavalid),
        .avl_writedata    (vp_writedata),
        .avl_byteenable   (vp_byteenable),
        .avl_write        (vp_write),
        .avl_waitrequest  (vp_waitrequest)
    );

    a2065_ddram_arbiter probe_pair_arb (
        .clk              (clk_ddr),
        .rst              (!rst_n_sys),
        .m0_address       (lp_address),
        .m0_burstcount    (lp_burstcount),
        .m0_read          (lp_read),
        .m0_readdata      (lp_readdata),
        .m0_readdatavalid (lp_readdatavalid),
        .m0_writedata     (lp_writedata),
        .m0_byteenable    (lp_byteenable),
        .m0_write         (lp_write),
        .m0_waitrequest   (lp_waitrequest),
        .m1_address       (vp_address),
        .m1_burstcount    (vp_burstcount),
        .m1_read          (vp_read),
        .m1_readdata      (vp_readdata),
        .m1_readdatavalid (vp_readdatavalid),
        .m1_writedata     (vp_writedata),
        .m1_byteenable    (vp_byteenable),
        .m1_write         (vp_write),
        .m1_waitrequest   (vp_waitrequest),
        .s_address        (pr_address),
        .s_burstcount     (pr_burstcount),
        .s_read           (pr_read),
        .s_readdata       (pr_readdata),
        .s_readdatavalid  (pr_readdatavalid),
        .s_writedata      (pr_writedata),
        .s_byteenable     (pr_byteenable),
        .s_write          (pr_write),
        .s_waitrequest    (pr_waitrequest)
    );

    a2065_ddram_arbiter probe_arb (
        .clk              (clk_ddr),
        .rst              (!rst_n_sys),
        .m0_address       (mb_address),
        .m0_burstcount    (mb_burstcount),
        .m0_read          (mb_read),
        .m0_readdata      (mb_readdata),
        .m0_readdatavalid (mb_readdatavalid),
        .m0_writedata     (mb_writedata),
        .m0_byteenable    (mb_byteenable),
        .m0_write         (mb_write),
        .m0_waitrequest   (mb_waitrequest),
        .m1_address       (pr_address),
        .m1_burstcount    (pr_burstcount),
        .m1_read          (pr_read),
        .m1_readdata      (pr_readdata),
        .m1_readdatavalid (pr_readdatavalid),
        .m1_writedata     (pr_writedata),
        .m1_byteenable    (pr_byteenable),
        .m1_write         (pr_write),
        .m1_waitrequest   (pr_waitrequest),
        .s_address        (mem_address),
        .s_burstcount     (mem_burstcount),
        .s_read           (mem_read),
        .s_readdata       (mem_readdata),
        .s_readdatavalid  (mem_readdatavalid),
        .s_writedata      (mem_writedata),
        .s_byteenable     (mem_byteenable),
        .s_write          (mem_write),
        .s_waitrequest    (mem_waitrequest)
    );

    a2065_ddr3_mailbox mailbox (
        .clk              (clk_ddr),
        .rst_n            (rst_n_sys),

        .cmd_pending      (cmd_pending),
        .cmd_rap          (cmd_rap),
        .cmd_data         (cmd_data),
        .cmd_clear        (cmd_clear),

        .csr0_out         (csr0),
        .csr1_out         (csr1),
        .csr2_out         (csr2),
        .csr3_out         (csr3),
        .a2065_int2       (int2_ddr),

        .bram_req_valid   (bram_req_valid),
        .bram_req_addr    (bram_req_addr),
        .bram_req_wdata   (bram_req_wdata),
        .bram_req_rw      (bram_req_rw),
        .bram_req_be      (bram_req_be),
        .bram_req_ack     (bram_req_ack),
        .bram_resp_valid  (bram_resp_valid),
        .bram_resp_data   (bram_resp_data),

        .avl_address      (mb_address),
        .avl_burstcount   (mb_burstcount),
        .avl_read         (mb_read),
        .avl_readdata     (mb_readdata),
        .avl_readdatavalid(mb_readdatavalid),
        .avl_writedata    (mb_writedata),
        .avl_byteenable   (mb_byteenable),
        .avl_write        (mb_write),
        .avl_waitrequest  (mb_waitrequest)
    );

    // The interrupt is raised in the memory clock domain and consumed in the
    // Amiga's, so synchronise it here rather than leaving that to the caller.
    reg int2_s1, int2_s2;
    always @(posedge clk_sys) begin
        int2_s1 <= int2_ddr;
        int2_s2 <= int2_s1;
    end
    assign int2 = int2_s2;

endmodule
