/*
 * visprobe_ddr3.v
 *
 * MEASUREMENT ONLY -- step 1e of the ARM-CPU plan. Step 1 measured a DDR3
 * round trip of ~2.5 us between the ARM and the FPGA, with almost none of it
 * spent in anything either side executes. That points at write visibility
 * between the HPS SDRAM controller's ports: how long after one side writes a
 * word does the other side's read return it? This answers that for each
 * direction separately, using the lightweight HPS-to-FPGA bridge (step 1d,
 * sys/lw_echo.sv registers 4-7) as a signal that does not go through DDR3.
 *
 * ARM to FPGA (A): the ARM writes V to word A in DDR3, then writes V to A_GO
 * over the bridge. From the cycle A_GO arrives, this module reads word A back
 * to back until it returns V, and reports the cycles that took and how many
 * reads returned something older. A word written long before A_GO gives the
 * baseline: one read, no misses.
 *
 * FPGA to ARM (B): the ARM writes V to B_GO over the bridge. This module
 * writes V to word B and notes the cycle the controller accepted it. The ARM
 * polls word B until it reads V, then writes B_SEEN over the bridge; this
 * module reports the cycles from the accepted write to B_SEEN arriving. The
 * ARM writing B_SEEN at once, without polling, gives the fixed cost of the
 * bridge to subtract.
 *
 * Words, in the A2065 mailbox's DDR3 window next to latprobe_ddr3's:
 *
 *   A  Avalon 0x03FE1012, ARM 0x1FF08090   ARM writes, V in bits [31:0]
 *   B  Avalon 0x03FE1013, ARM 0x1FF08098   FPGA writes {32'h0, V}
 *
 * Bridge registers (lw_wr / lw_waddr / lw_wdata, lw_status):
 *
 *   write 0 A_GO    V; starts the A poll
 *   write 1 B_GO    V; writes word B
 *   write 2 B_SEEN  stops the B timer
 *   read  0  {a_done, a_timeout, a_busy, 13'b0, a_misses[15:0]}
 *   read  1  a_cycles: A_GO arriving to the read that returned V
 *   read  2  {b_done, b_wrote, b_pending, 13'b0, b_issue[15:0]}
 *            b_issue: B_GO arriving to the controller accepting the write
 *   read  3  b_cycles: the write accepted to B_SEEN arriving
 *
 * Idle unless the bridge starts it; it never touches DDR3 on its own. An A
 * poll gives up after TIMEOUT cycles.
 */

module visprobe_ddr3 #(
    parameter [31:0] TIMEOUT = 32'd1000000   // ~8.8 ms at 113.5 MHz
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          lw_wr,
    input  wire  [1:0]   lw_waddr,
    input  wire  [31:0]  lw_wdata,
    output wire [127:0]  lw_status,

    output reg  [28:0]   avl_address,
    output wire [7:0]    avl_burstcount,
    output reg           avl_read,
    input  wire [63:0]   avl_readdata,
    input  wire          avl_readdatavalid,
    output reg  [63:0]   avl_writedata,
    output wire [7:0]    avl_byteenable,
    output reg           avl_write,
    input  wire          avl_waitrequest
);

    localparam [28:0] DDR3_BASE = 29'h03FE0000;
    localparam [28:0] AV_A      = DDR3_BASE + 29'h1012;
    localparam [28:0] AV_B      = DDR3_BASE + 29'h1013;

    localparam S_IDLE = 2'd0;
    localparam S_RD   = 2'd1;
    localparam S_RDD  = 2'd2;
    localparam S_WR   = 2'd3;

    assign avl_burstcount = 8'd1;
    assign avl_byteenable = 8'hFF;

    reg [1:0]  state;
    reg [31:0] cyc;

    reg        a_busy, a_done, a_timeout;
    reg [31:0] a_val, a_t0, a_cycles;
    reg [15:0] a_misses;

    reg        b_pending, b_wrote, b_done;
    reg [31:0] b_val, b_t0, b_twr, b_cycles;
    reg [15:0] b_issue;

    wire [31:0] a_age = cyc - a_t0;
    wire [31:0] b_age = cyc - b_t0;

    assign lw_status = {
        b_cycles,
        {b_done, b_wrote, b_pending, 13'd0, b_issue},
        a_cycles,
        {a_done, a_timeout, a_busy, 13'd0, a_misses}
    };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            cyc           <= 32'd0;
            avl_address   <= AV_A;
            avl_read      <= 1'b0;
            avl_write     <= 1'b0;
            avl_writedata <= 64'd0;
            a_busy        <= 1'b0;
            a_done        <= 1'b0;
            a_timeout     <= 1'b0;
            a_val         <= 32'd0;
            a_t0          <= 32'd0;
            a_cycles      <= 32'd0;
            a_misses      <= 16'd0;
            b_pending     <= 1'b0;
            b_wrote       <= 1'b0;
            b_done        <= 1'b0;
            b_val         <= 32'd0;
            b_t0          <= 32'd0;
            b_twr         <= 32'd0;
            b_cycles      <= 32'd0;
            b_issue       <= 16'd0;
        end
        else begin
            cyc <= cyc + 32'd1;

            // ---- the bridge -------------------------------------------------
            if (lw_wr) begin
                case (lw_waddr)
                2'd0: begin
                    a_val     <= lw_wdata;
                    a_t0      <= cyc;
                    a_busy    <= 1'b1;
                    a_done    <= 1'b0;
                    a_timeout <= 1'b0;
                    a_misses  <= 16'd0;
                    a_cycles  <= 32'd0;
                end
                2'd1: begin
                    b_val     <= lw_wdata;
                    b_t0      <= cyc;
                    b_pending <= 1'b1;
                    b_wrote   <= 1'b0;
                    b_done    <= 1'b0;
                    b_cycles  <= 32'd0;
                    b_issue   <= 16'd0;
                end
                2'd2: begin
                    if (b_wrote && !b_done) begin
                        b_cycles <= cyc - b_twr;
                        b_done   <= 1'b1;
                    end
                end
                default: ;
                endcase
            end

            // ---- DDR3 -------------------------------------------------------
            case (state)
            S_IDLE: begin
                if (b_pending) begin
                    avl_address   <= AV_B;
                    avl_writedata <= {32'd0, b_val};
                    avl_write     <= 1'b1;
                    state         <= S_WR;
                end
                else if (a_busy) begin
                    avl_address <= AV_A;
                    avl_read    <= 1'b1;
                    state       <= S_RD;
                end
            end

            S_RD: begin
                if (!avl_waitrequest) begin
                    avl_read <= 1'b0;
                    state    <= S_RDD;
                end
            end

            S_RDD: begin
                if (avl_readdatavalid) begin
                    state <= S_IDLE;
                    // a new A_GO this same cycle wins; this read answers the old one
                    if (a_busy && !(lw_wr && lw_waddr == 2'd0)) begin
                        if (avl_readdata[31:0] == a_val) begin
                            a_cycles <= a_age;
                            a_done   <= 1'b1;
                            a_busy   <= 1'b0;
                        end
                        else if (a_age >= TIMEOUT) begin
                            a_cycles  <= a_age;
                            a_timeout <= 1'b1;
                            a_busy    <= 1'b0;
                        end
                        else if (a_misses != 16'hFFFF)
                            a_misses <= a_misses + 16'd1;
                    end
                end
            end

            S_WR: begin
                if (!avl_waitrequest) begin
                    avl_write <= 1'b0;
                    state     <= S_IDLE;
                    if (!(lw_wr && lw_waddr == 2'd1)) begin
                        b_pending <= 1'b0;
                        b_wrote   <= 1'b1;
                        b_twr     <= cyc;
                        b_issue   <= (|b_age[31:16]) ? 16'hFFFF : b_age[15:0];
                    end
                end
            end
            endcase
        end
    end

endmodule
