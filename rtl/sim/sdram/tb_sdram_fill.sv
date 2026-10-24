// tb_sdram_fill -- the address a read-cache RAS slot opens is the one the CPU
// asked for.
//
// sdram_ctrl loads the read cache's address into sd_addr from cacheAddr, a
// copy of cpuAddr one clock late, so that the CPU/save state address mux in
// AmigaCD.sv is not in the same clk_114 as the slot mux and the route to the
// SDRAM pins. That is only right if cpuAddr has held for a clock before any
// slot can take cache_req. This bench drives the real sdram_ctrl and its
// cpu_cache_new with CPU reads that start on every phase of the 16-clock
// SDRAM cycle, to fresh lines (so each one misses and fills), and checks every
// read-cache slot: the bank and row on its ACTIVATE and the column on its
// READ must be the address the CPU is holding.
//
// It also drops some accesses before their ack and starts the next one at a
// new address on the following clock -- the case where a stale address could
// reach a slot -- and checks the next completed access the same way.
//
// The chipset is kept off the RAS slot (chipDMA=1, chipRW=1) so every slot
// that is not a refresh is the CPU's. sd_data is driven by the bench and its
// value is not checked: the address is.

`timescale 1ns/1ps
module tb_sdram_fill;

  integer errs = 0, slots = 0, done = 0, dropped = 0;

  reg sysclk = 0;
  always #5 sysclk = ~sysclk;

  reg [3:0] clkdiv = 0;
  reg c_7m = 0;
  always @(posedge sysclk) begin
    clkdiv <= clkdiv + 1'b1;
    c_7m   <= clkdiv[3];
  end

  reg reset_n = 0;

  reg  [24:1] chipAddr = 0;
  wire [15:0] chipRD;
  wire [47:0] chip48;

  reg  [24:1] cpuAddr = 0;
  reg         cpuCS = 0;
  reg  [1:0]  cpustate = 2'b01;
  reg         cpuL = 1, cpuU = 1;
  wire [15:0] cpuRD;
  wire        ramready;

  wire [12:0] sd_addr;
  wire [1:0]  sd_ba;
  wire        sd_cs, sd_we, sd_ras, sd_cas, sd_clk, sd_cke;
  wire [1:0]  sd_dqm;
  wire [15:0] sd_data;
  assign sd_data = 16'h5A00 + {12'd0, dut.sdram_state};

  sdram_ctrl dut (
    .sysclk(sysclk), .c_7m(c_7m), .reset_n(reset_n),
    .cache_rst(1'b1), .cache_inhibit(1'b0),
    .cpu_cache_ctrl(4'b0001), .dcache_sw_en(1'b1),
    .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_cs(sd_cs), .sd_we(sd_we),
    .sd_ras(sd_ras), .sd_cas(sd_cas), .sd_dqm(sd_dqm), .sd_data(sd_data),
    .sd_clk(sd_clk), .sd_cke(sd_cke),
    .chipAddr(chipAddr), .chipL(1'b1), .chipU(1'b1), .chipRW(1'b1),
    .chipDMA(1'b1), .chipWR(16'd0), .chipRD(chipRD), .chip48(chip48),
    .cpuAddr(cpuAddr), .cpuCS(cpuCS), .cpustate(cpustate),
    .cpuL(cpuL), .cpuU(cpuU), .cpuWR(16'd0), .cpuRD(cpuRD), .ramready(ramready)
  );

  // The access in flight, as the CPU presents it. live is high only while the
  // CPU is waiting for this address's ack, so a slot opened for an access the
  // bench has already dropped is not held against the next one.
  reg  [24:1] want = 0;
  reg         live = 0;

  // ACTIVATE: RAS low, CAS and WE high, on sd_clk's command edge. The slot
  // type is set on the same edge as the command, so it is read a clock later.
  reg         act_q = 0;
  reg  [14:0] act_rowbank;
  always @(posedge sysclk) begin
    act_q <= 0;
    if (dut.init_done && !sd_ras && sd_cas && sd_we) begin
      act_q       <= 1;
      act_rowbank <= {sd_ba, sd_addr};
    end
    if (act_q && dut.slot_type == 3'd2 && live) begin
      slots = slots + 1;
      if (act_rowbank !== want[24:10]) begin
        $display("FAIL row: slot opened bank/row %h, the CPU wants %h (addr %h)",
                 act_rowbank, want[24:10], want);
        errs = errs + 1;
      end
    end
    // READ: CAS low, RAS and WE high. Column bits 8:0 are the address's 9:1.
    if (dut.init_done && sd_ras && !sd_cas && sd_we && dut.slot_type == 3'd2 && live) begin
      if (sd_addr[8:0] !== want[9:1]) begin
        $display("FAIL col: slot read column %h, the CPU wants %h (addr %h)",
                 sd_addr[8:0], want[9:1], want);
        errs = errs + 1;
      end
    end
  end

  integer seed = 32'h5D1F;
  integer n, k, gap;
  reg [24:1] a;

  // One CPU read to a fresh cache line, held until its ack.
  task cpu_read(input [24:1] addr);
    integer t;
    begin
      @(posedge sysclk);
      cpuAddr  <= addr;
      cpustate <= ($random(seed) & 1) ? 2'b10 : 2'b00;
      cpuU <= 0; cpuL <= 0;
      cpuCS <= 1;
      want  <= addr;
      live  <= 1;
      t = 0;
      @(posedge sysclk);
      while (!ramready && t < 400) begin @(posedge sysclk); t = t + 1; end
      if (!ramready) begin
        $display("FAIL ack: no ack for %h", addr);
        errs = errs + 1;
      end else done = done + 1;
      live  <= 0;
      cpuCS <= 0; cpustate <= 2'b01; cpuU <= 1; cpuL <= 1;
    end
  endtask

  // A read the CPU gives up on after 1-3 clocks, followed on the very next
  // clock by a read elsewhere.
  task cpu_drop(input [24:1] addr);
    begin
      @(posedge sysclk);
      cpuAddr  <= addr;
      cpustate <= 2'b10;
      cpuU <= 0; cpuL <= 0;
      cpuCS <= 1;
      live  <= 0;
      repeat (1 + ($random(seed) & 1) + ($random(seed) & 1)) @(posedge sysclk);
      cpuCS <= 0; cpustate <= 2'b01; cpuU <= 1; cpuL <= 1;
      dropped = dropped + 1;
    end
  endtask

  initial begin
    repeat (20) @(posedge sysclk);
    reset_n = 1;
    wait (dut.init_done == 1'b1);
    wait (dut.cpu_cache.cache_init_done == 1'b1);
    repeat (32) @(posedge sysclk);

    for (n = 0; n < 300; n = n + 1) begin
      // A fresh line every time: the index walks, the tag and bank change.
      a = {$random(seed)} & 24'hFFFFF8;
      a[10:3] = n[7:0];
      if (n % 5 == 4) begin
        cpu_drop(a ^ 24'h5A5BFE);   // row, bank and column all differ
        cpu_read(a);
      end else begin
        cpu_read(a);
      end
      // Start the next access on any phase of the SDRAM cycle.
      gap = $random(seed) & 15;
      for (k = 0; k < gap; k = k + 1) @(posedge sysclk);
    end

    $display("%0d reads acked, %0d read-cache slots checked, %0d accesses dropped", done, slots, dropped);
    if (slots < 200) begin
      $display("FAIL coverage: only %0d slots checked", slots);
      errs = errs + 1;
    end
    if (errs == 0) $display("RUN: PASS");
    else           $display("RUN: FAIL (%0d errors)", errs);
    $finish;
  end

endmodule
