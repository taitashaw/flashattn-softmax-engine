// ==========================================================================
// Hardened Softmax Pipeline — Testbench
// ==========================================================================
// Uses @(posedge clk); #1; idiom: drive signals 1ns after clock edge
// so DUT always sees new values at the NEXT posedge. Standard for Verilator.
// ==========================================================================

`timescale 1ns / 1ps

module tb_top;

    logic clk = 0;
    logic rst_n = 0;
    /* verilator lint_off BLKSEQ */
    always #2.5 clk = ~clk;
    /* verilator lint_on BLKSEQ */

    logic [7:0]  awaddr;  logic awvalid; logic awready;
    logic [31:0] wdata;   logic [3:0] wstrb; logic wvalid; logic wready;
    logic [1:0]  bresp;   logic bvalid; logic bready;
    logic [7:0]  araddr;  logic arvalid; logic arready;
    logic [31:0] rdata;   logic [1:0] rresp; logic rvalid; logic rready;
    logic irq_done;

    flashattn_softmax_top #(
        .MAX_SEQ_LEN(4096), .HEAD_DIM(128), .TILE_BR(128), .TILE_BC(128)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
        .s_axil_wdata(wdata), .s_axil_wstrb(wstrb),
        .s_axil_wvalid(wvalid), .s_axil_wready(wready),
        .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
        .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
        .s_axil_rdata(rdata), .s_axil_rresp(rresp),
        .s_axil_rvalid(rvalid), .s_axil_rready(rready),
        .irq_done(irq_done)
    );

    // ================================================================
    // AXI Write: drive #1 after posedge, check on posedge
    // ================================================================
    task automatic axi_write(input [7:0] addr, input [31:0] d);
        // Setup: drive aw+w together
        @(posedge clk); #1;
        awaddr  = addr;
        awvalid = 1;
        wdata   = d;
        wstrb   = 4'hF;
        wvalid  = 1;
        bready  = 0;

        // Cycle 1: DUT sees awvalid=1, awready=1 → captures addr
        //          DUT sees wvalid=1, wready=1  → captures data
        @(posedge clk); #1;
        // DUT has now set aw_recv=1, w_recv=1, awready=0, wready=0
        awvalid = 0;
        wvalid  = 0;

        // Cycle 2: DUT sees aw_recv && w_recv → writes csr, sets bvalid=1
        @(posedge clk); #1;
        bready = 1;

        // Cycle 3: DUT sees bvalid=1 && bready=1 → clears bvalid, re-arms ready
        @(posedge clk); #1;
        bready = 0;

        // Cycle 4: Settle
        @(posedge clk); #1;
    endtask

    // ================================================================
    // AXI Read: drive #1 after posedge, check on posedge
    // ================================================================
    logic [31:0] read_result;

    task automatic axi_read(input [7:0] addr);
        // Setup: drive ar
        @(posedge clk); #1;
        araddr  = addr;
        arvalid = 1;
        rready  = 1;

        // Cycle 1: DUT sees arvalid=1, arready=1 → captures addr, drives rdata
        @(posedge clk); #1;
        arvalid = 0;

        // Cycle 2: DUT has rvalid=1, rdata=value
        @(posedge clk); #1;
        read_result = rdata;
        rready = 0;

        // Cycle 3: Settle
        @(posedge clk); #1;
    endtask

    // ---- Test helpers ----
    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check(input string name, input [31:0] got, input [31:0] expected);
        if (got == expected) begin
            $display("  [PASS] %s = 0x%08h", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s = 0x%08h (expected 0x%08h)", name, got, expected);
            fail_count = fail_count + 1;
        end
    endtask

    task automatic check_nonzero(input string name, input [31:0] got);
        if (got != 0) begin
            $display("  [PASS] %s = %0d", name, got);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] %s = 0 (expected non-zero)", name);
            fail_count = fail_count + 1;
        end
    endtask

    // ---- Main ----
    integer timeout;

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0; bready = 0;
        araddr = 0; arvalid = 0; rready = 0;

        $display("");
        $display("==========================================================");
        $display("  Hardened Softmax Pipeline — RTL Testbench");
        $display("  Target: PERF_STALL_CYCLES = 0");
        $display("==========================================================");

        // Reset
        rst_n = 0;
        repeat (20) @(posedge clk);
        #1;
        rst_n = 1;
        repeat (10) @(posedge clk);
        #1;
        $display("\n[Phase 1] Reset complete");

        // ==== TEST 1: CSR Write/Read ====
        $display("\n[TEST 1] CSR Register Write/Read");

        axi_write(8'h08, 32'd256);    axi_read(8'h08);
        check("SEQ_LEN", read_result, 32'd256);

        axi_write(8'h0C, 32'd128);    axi_read(8'h0C);
        check("HEAD_DIM", read_result, 32'd128);

        axi_write(8'h10, 32'd128);    axi_read(8'h10);
        check("TILE_BR", read_result, 32'd128);

        axi_write(8'h14, 32'd128);    axi_read(8'h14);
        check("TILE_BC", read_result, 32'd128);

        axi_write(8'h18, 32'h10000000); axi_read(8'h18);
        check("Q_BASE", read_result, 32'h10000000);

        axi_write(8'h1C, 32'h20000000); axi_read(8'h1C);
        check("K_BASE", read_result, 32'h20000000);

        axi_write(8'h20, 32'h30000000); axi_read(8'h20);
        check("V_BASE", read_result, 32'h30000000);

        axi_write(8'h24, 32'h40000000); axi_read(8'h24);
        check("O_BASE", read_result, 32'h40000000);

        // ==== TEST 2: Start ====
        $display("\n[TEST 2] Start Attention Computation");
        axi_write(8'h00, 32'h00000001);

        repeat (15) @(posedge clk); #1;
        axi_read(8'h04);
        check("STATUS (busy)", read_result, 32'h00000001);

        // ==== TEST 3: Wait for completion ====
        $display("\n[TEST 3] Waiting for completion...");
        timeout = 0;
        read_result = 0;
        while (read_result != 32'h00000002 && timeout < 200000) begin
            repeat (10) @(posedge clk); #1;
            axi_read(8'h04);  // Poll STATUS
            timeout = timeout + 10;
        end

        if (read_result == 32'h00000002) begin
            $display("  [PASS] Completed in ~%0d cycles", timeout);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] TIMEOUT after %0d cycles (STATUS=0x%08h)", timeout, read_result);
            fail_count = fail_count + 1;
        end

        axi_read(8'h04);
        check("STATUS (done)", read_result, 32'h00000002);

        // ==== TEST 4: Performance Counters ====
        $display("\n[TEST 4] Performance Counters");

        axi_read(8'h30); $display("  PERF_CYCLES         = %0d", read_result);
        check_nonzero("PERF_CYCLES", read_result);

        axi_read(8'h34); $display("  PERF_GEMM_CYCLES    = %0d", read_result);
        check_nonzero("PERF_GEMM_CYCLES", read_result);

        axi_read(8'h38); $display("  PERF_SOFTMAX_CYCLES = %0d", read_result);

        axi_read(8'h3C);
        $display("  PERF_STALL_CYCLES   = %0d  *** THE METRIC ***", read_result);
        check("PERF_STALL_CYCLES", read_result, 32'd0);

        axi_read(8'h40); $display("  PERF_MEM_STALLS     = %0d", read_result);
        axi_read(8'h44); $display("  PERF_TILES          = %0d", read_result);
        axi_read(8'h48); $display("  PERF_EXP_OPS        = %0d", read_result);

        // ==== TEST 5: Re-start ====
        $display("\n[TEST 5] Re-start (seq_len=128)");
        axi_write(8'h08, 32'd128);
        axi_write(8'h00, 32'h00000001);

        timeout = 0;
        read_result = 0;
        while (read_result != 32'h00000002 && timeout < 200000) begin
            repeat (10) @(posedge clk); #1;
            axi_read(8'h04);
            timeout = timeout + 10;
        end

        if (read_result == 32'h00000002) begin
            $display("  [PASS] Second run in ~%0d cycles", timeout);
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Second run TIMEOUT");
            fail_count = fail_count + 1;
        end

        axi_read(8'h44);
        check("PERF_TILES (expect 1)", read_result, 32'd1);

        // ==== SUMMARY ====
        $display("\n==========================================================");
        $display("  RESULTS: %0d PASS, %0d FAIL", pass_count, fail_count);
        $display("==========================================================");
        if (fail_count == 0) $display("  >>> ALL TESTS PASSED <<<");
        else                 $display("  >>> %0d TESTS FAILED <<<", fail_count);
        $display("");
        #100;
        $finish;
    end

    initial begin
        #5000000;
        $display("ERROR: Global timeout");
        $finish;
    end

    initial begin
        $dumpfile("flashattn_softmax.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
