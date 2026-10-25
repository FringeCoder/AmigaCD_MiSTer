/*
 * tb_latprobe.v -- checks latprobe_ddr3 (MEASUREMENT ONLY, see its header).
 *
 * The probe is only useful if three things hold, and each is checked here
 * against a DDR3 model with random waitrequest and random read latency:
 *
 *   - disarmed, it never writes, and it polls slowly (it shares the A2065's
 *     DDR3 port with the mailbox and, upstream, with fast RAM);
 *   - armed, every new sequence number is echoed exactly once, with the
 *     model's read latency in rd_lat;
 *   - a request it has already answered is not answered again.
 *
 * The bench plays the ARM: it writes REQ straight into the model's memory,
 * as the ARM writes it into DDR3, and watches RESP there.
 */
`timescale 1ns/1ps

module tb_latprobe;

    reg clk = 0, rst_n = 0;
    always #4.4 clk = ~clk;          // ~114 MHz

    wire [28:0] avl_address;
    wire [7:0]  avl_burstcount, avl_byteenable;
    wire        avl_read, avl_write;
    wire [63:0] avl_writedata;
    reg  [63:0] avl_readdata = 0;
    reg         avl_readdatavalid = 0;
    reg         avl_waitrequest = 0;

    latprobe_ddr3 #(.GAP_SLOW(16'd200)) dut (
        .clk(clk), .rst_n(rst_n),
        .avl_address(avl_address), .avl_burstcount(avl_burstcount),
        .avl_read(avl_read), .avl_readdata(avl_readdata),
        .avl_readdatavalid(avl_readdatavalid), .avl_writedata(avl_writedata),
        .avl_byteenable(avl_byteenable), .avl_write(avl_write),
        .avl_waitrequest(avl_waitrequest)
    );

    localparam [28:0] AV_REQ  = 29'h03FE0000 + 29'h1010;
    localparam [28:0] AV_RESP = 29'h03FE0000 + 29'h1011;
    localparam [31:0] MAGIC   = 32'h4C415450;

    // ---- DDR3 model: two words, random waitrequest, random read latency ----
    reg [63:0] req_word  = 64'd0;
    reg [63:0] resp_word = 64'd0;
    integer    seed      = 32'h1A7E;
    integer    rd_pending = 0, rd_wait = 0;
    integer    lat_now   = 0;        // the latency the model gave the last read
    integer    writes    = 0, reads = 0, bad_addr = 0;

    always @(posedge clk) begin
        avl_readdatavalid <= 1'b0;
        avl_waitrequest   <= (($random(seed) & 3) == 0);   // busy one cycle in four
        if (avl_read && !avl_waitrequest) begin
            reads      = reads + 1;
            if (avl_address != AV_REQ) bad_addr = bad_addr + 1;
            rd_pending = 1;
            rd_wait    = 6 + ($random(seed) & 15);         // 7..22 cycles to data
            lat_now    = rd_wait + 1;
        end
        else if (rd_pending) begin
            rd_wait = rd_wait - 1;
            if (rd_wait == 0) begin
                avl_readdata      <= req_word;
                avl_readdatavalid <= 1'b1;
                rd_pending         = 0;
            end
        end
        if (avl_write && !avl_waitrequest) begin
            writes = writes + 1;
            if (avl_address != AV_RESP) bad_addr = bad_addr + 1;
            else resp_word <= avl_writedata;
        end
    end

    integer pass = 0, fail = 0;
    task check(input cond, input [511:0] name);
        begin
            if (cond) begin pass = pass + 1; $display("  PASS  %0s", name); end
            else      begin fail = fail + 1; $display("  FAIL  %0s", name); end
        end
    endtask

    integer i, t, w0, r0, lat_ok, echo_ok;
    reg [31:0] seq;

    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;

        // ---- disarmed: no writes, slow polls --------------------------------
        req_word = {32'h0, 32'd5};              // no MAGIC
        w0 = writes; r0 = reads;
        repeat (5000) @(posedge clk);
        check(writes == w0, "disarmed: no response is ever written");
        // 5000 cycles at one poll per >= 201 cycles is at most 25 polls.
        check(reads - r0 <= 25 && reads - r0 >= 10, "disarmed: polls at the slow rate");

        // ---- armed: every new seq is echoed once, with the read latency ------
        echo_ok = 0; lat_ok = 0;
        seq = 32'hA5A50000;
        for (i = 0; i < 200; i = i + 1) begin
            seq = seq + 1 + ($random(seed) & 7);
            w0  = writes;
            req_word = {MAGIC, seq};
            t = 0;
            while (resp_word[63:32] !== seq && t < 400) begin @(posedge clk); t = t + 1; end
            if (resp_word[63:32] === seq && writes == w0 + 1) echo_ok = echo_ok + 1;
            // rd_lat counts from the cycle the read was accepted to the data,
            // which the model sets to lat_now; allow one cycle of skew.
            if (resp_word[31:16] >= lat_now - 1 && resp_word[31:16] <= lat_now + 1) lat_ok = lat_ok + 1;
            repeat ($random(seed) & 31) @(posedge clk);
        end
        check(echo_ok == 200, "armed: 200 of 200 sequence numbers echoed exactly once");
        check(lat_ok  == 200, "armed: rd_lat matches the model's read latency");

        // ---- a request already answered is not answered again ---------------
        w0 = writes;
        resp_word = 64'd0;
        repeat (2000) @(posedge clk);
        check(writes == w0 && resp_word == 64'd0, "an answered request is not echoed again");

        // ---- polls since the last answer are counted ------------------------
        seq = seq + 1;
        req_word = {MAGIC, seq};
        t = 0;
        while (resp_word[63:32] !== seq && t < 400) begin @(posedge clk); t = t + 1; end
        check(resp_word[15:0] > 16'd20, "polls since the last answer are counted");

        check(bad_addr == 0, "only REQ is read and only RESP is written");

        $display("%0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("RUN: PASS");
        else           $display("RUN: FAIL");
        $finish;
    end

    initial begin
        #20000000;
        $display("RUN: FAIL (timeout)");
        $finish;
    end

endmodule
