/*
 * latprobe_ddr3.v
 *
 * MEASUREMENT ONLY -- step 1 of the ARM-CPU plan: how long does one request
 * take to go from the ARM, through DDR3, to the FPGA and back? Everything an
 * ARM-hosted 68k would do on the chipset bus pays this round trip, so it
 * decides whether that design is worth building at all.
 *
 * An echo, nothing more. The ARM (AmigaCD tools/latprobe) writes a request
 * word to DDR3; this module polls that word, and when it sees a new sequence
 * number writes a response word that echoes it. The ARM times the whole round
 * trip with its own clock. The response also carries what only the FPGA can
 * see: how long its DDR3 read of the request took, and how many polls found
 * nothing new since the last request (so the ARM can tell transport time from
 * time spent waiting for the next poll).
 *
 * Words, in the A2065 mailbox's DDR3 window (Avalon base 0x03FE0000, ARM
 * physical 0x1FF00000; minimig_a2065_ddr3.h lists the slots that are taken):
 *
 *   REQ  Avalon +0x1010, ARM +0x8080   ARM writes  {MAGIC[63:32], seq[31:0]}
 *   RESP Avalon +0x1011, ARM +0x8088   FPGA writes {seq[63:32], rd_lat[31:16],
 *                                                   polls[15:0]}
 *
 * Idle unless armed: with no MAGIC in REQ it reads REQ once every
 * GAP_SLOW+1 cycles (~144 us at 114 MHz) and never writes. Armed, it polls
 * back to back, so the measured time is DDR3 and arbitration, not a poll
 * interval of this module's choosing. It sits behind the A2065 mailbox in a
 * fixed-priority arbiter (a2065.v), which itself sits behind fast RAM.
 */

module latprobe_ddr3 #(
    parameter [31:0] MAGIC    = 32'h4C415450,   // "LATP"
    parameter [15:0] GAP_SLOW = 16'd16383
)(
    input  wire         clk,
    input  wire         rst_n,

    output reg  [28:0]  avl_address,
    output wire [7:0]   avl_burstcount,
    output reg          avl_read,
    input  wire [63:0]  avl_readdata,
    input  wire         avl_readdatavalid,
    output reg  [63:0]  avl_writedata,
    output wire [7:0]   avl_byteenable,
    output reg          avl_write,
    input  wire         avl_waitrequest
);

    localparam [28:0] DDR3_BASE = 29'h03FE0000;
    localparam [28:0] AV_REQ    = DDR3_BASE + 29'h1010;
    localparam [28:0] AV_RESP   = DDR3_BASE + 29'h1011;

    localparam S_GAP = 2'd0;
    localparam S_RD  = 2'd1;
    localparam S_RDD = 2'd2;
    localparam S_WR  = 2'd3;

    assign avl_burstcount = 8'd1;
    assign avl_byteenable = 8'hFF;

    reg [1:0]  state;
    reg [15:0] gap;
    reg [31:0] cyc;
    reg [31:0] t_issue;
    reg [31:0] last_seq;
    reg [15:0] polls;

    wire [31:0] rd_lat   = cyc - t_issue;
    wire        armed    = (avl_readdata[63:32] == MAGIC);
    wire        fresh    = armed && (avl_readdata[31:0] != last_seq);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_GAP;
            gap           <= GAP_SLOW;
            cyc           <= 32'd0;
            t_issue       <= 32'd0;
            last_seq      <= 32'd0;
            polls         <= 16'd0;
            avl_address   <= AV_REQ;
            avl_read      <= 1'b0;
            avl_write     <= 1'b0;
            avl_writedata <= 64'd0;
        end
        else begin
            cyc <= cyc + 32'd1;

            case (state)
            S_GAP: begin
                if (gap == 16'd0) begin
                    avl_address <= AV_REQ;
                    avl_read    <= 1'b1;
                    state       <= S_RD;
                end
                else gap <= gap - 16'd1;
            end

            S_RD: begin
                if (!avl_waitrequest) begin
                    avl_read <= 1'b0;
                    t_issue  <= cyc;
                    state    <= S_RDD;
                end
            end

            S_RDD: begin
                if (avl_readdatavalid) begin
                    if (fresh) begin
                        last_seq      <= avl_readdata[31:0];
                        avl_address   <= AV_RESP;
                        avl_writedata <= {avl_readdata[31:0],
                                          (|rd_lat[31:16]) ? 16'hFFFF : rd_lat[15:0],
                                          polls};
                        avl_write     <= 1'b1;
                        polls         <= 16'd0;
                        state         <= S_WR;
                    end
                    else begin
                        if (armed && polls != 16'hFFFF) polls <= polls + 16'd1;
                        gap   <= armed ? 16'd0 : GAP_SLOW;
                        state <= S_GAP;
                    end
                end
            end

            S_WR: begin
                if (!avl_waitrequest) begin
                    avl_write <= 1'b0;
                    gap       <= 16'd0;
                    state     <= S_GAP;
                end
            end
            endcase
        end
    end

endmodule
