// ==========================================================================
// Hardened Softmax Pipeline — Top Level (single-driver csr[])
// ==========================================================================

`timescale 1ns / 1ps

module flashattn_softmax_top #(
    parameter MAX_SEQ_LEN = 4096,
    parameter HEAD_DIM    = 128,
    parameter TILE_BR     = 128,
    parameter TILE_BC     = 128
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    input  logic [3:0]  s_axil_wstrb,
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    output logic [1:0]  s_axil_bresp,
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [7:0]  s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    output logic [1:0]  s_axil_rresp,
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,
    output logic        irq_done
);

    localparam [15:0] TILE_BR_16 = TILE_BR;
    localparam [15:0] TILE_BC_16 = TILE_BC;

    // ---- CSR: single array, single driver ----
    logic [31:0] csr [0:11];

    // ---- Performance counters ----
    logic [31:0] perf_cycles, perf_gemm_cycles, perf_softmax_cycles;
    logic [31:0] perf_stall_cycles, perf_mem_stalls, perf_tiles, perf_exp_ops;

    // ---- AXI write channel state ----
    logic [7:0]  aw_addr_q;
    logic [31:0] w_data_q;
    logic        aw_recv, w_recv;

    // ---- Main FSM ----
    typedef enum logic [3:0] {
        MAIN_IDLE, MAIN_INIT_STATS, MAIN_LOAD_KV, MAIN_LOAD_Q,
        MAIN_GEMM0, MAIN_SOFTMAX_WAIT, MAIN_GEMM1,
        MAIN_NEXT_Q, MAIN_NEXT_KV, MAIN_DONE
    } main_state_t;
    main_state_t main_state;

    logic [15:0] tile_i, tile_j, seq_len_reg, bram_init_idx;
    logic [31:0] cycle_cnt, gemm_cnt, softmax_cnt, stall_cnt, mem_cnt;
    logic        bram_init_en;

    // ---- Softmax signals ----
    logic        sm_tile_start, sm_tile_done, sm_seq_start, sm_busy;
    logic [31:0] sm_score_in;
    logic        sm_score_valid;
    logic [15:0] sm_score_row, sm_score_col;
    logic [31:0] sm_attn_out;
    logic        sm_attn_valid;
    logic [15:0] sm_attn_row, sm_attn_col;
    logic [31:0] sm_exp_ops, sm_stalls;
    logic [$clog2(TILE_BR)-1:0] stat_addr;
    logic        stat_wr_en;
    logic [31:0] stat_m_wr, stat_l_wr, stat_m_rd, stat_l_rd;

    // ---- Statistics BRAM ----
    logic [31:0] m_bram [0:TILE_BR-1];
    logic [31:0] l_bram [0:TILE_BR-1];

    always_ff @(posedge clk) begin
        stat_m_rd <= m_bram[stat_addr];
        stat_l_rd <= l_bram[stat_addr];
        if (bram_init_en) begin
            m_bram[bram_init_idx[$clog2(TILE_BR)-1:0]] <= 32'hFF800000;
            l_bram[bram_init_idx[$clog2(TILE_BR)-1:0]] <= 32'h00000000;
        end else if (stat_wr_en) begin
            m_bram[stat_addr] <= stat_m_wr;
            l_bram[stat_addr] <= stat_l_wr;
        end
    end

    // Softmax instance
    online_softmax_exact #(
        .MAX_SEQ_LEN(MAX_SEQ_LEN), .TILE_BR(TILE_BR), .TILE_BC(TILE_BC)
    ) u_softmax (
        .clk(clk), .rst_n(rst_n),
        .tile_start(sm_tile_start), .seq_start(sm_seq_start),
        .seq_len(csr[2][15:0]),
        .br_actual(TILE_BR_16), .bc_actual(TILE_BC_16),
        .tile_done(sm_tile_done), .busy(sm_busy),
        .score_in(sm_score_in), .score_valid(sm_score_valid),
        .score_row(sm_score_row), .score_col(sm_score_col),
        .attn_weight_out(sm_attn_out), .attn_weight_valid(sm_attn_valid),
        .attn_weight_row(sm_attn_row), .attn_weight_col(sm_attn_col),
        .stat_addr(stat_addr), .stat_wr_en(stat_wr_en),
        .stat_m_wr(stat_m_wr), .stat_l_wr(stat_l_wr),
        .stat_m_rd(stat_m_rd), .stat_l_rd(stat_l_rd),
        .exp_ops_count(sm_exp_ops), .stall_cycles(sm_stalls)
    );

    // ==================================================================
    // SINGLE always_ff: AXI write channel + Main FSM + csr[] writes
    // This eliminates multi-driver on csr[].
    // ==================================================================
    logic axi_wr_fire;  // Pulse: AXI write transaction completes this cycle

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // AXI write
            s_axil_awready <= 1;
            s_axil_wready  <= 1;
            s_axil_bvalid  <= 0;
            s_axil_bresp   <= 2'b00;
            aw_recv        <= 0;
            w_recv         <= 0;
            axi_wr_fire    <= 0;
            // FSM
            main_state     <= MAIN_IDLE;
            irq_done       <= 0;
            sm_tile_start  <= 0;
            sm_seq_start   <= 0;
            sm_score_valid <= 0;
            cycle_cnt      <= 0;
            bram_init_en   <= 0;
            bram_init_idx  <= 0;
            // CSR defaults
            csr[0]  <= 0; csr[1]  <= 0; csr[2]  <= 0; csr[3]  <= 0;
            csr[4]  <= 0; csr[5]  <= 0; csr[6]  <= 0; csr[7]  <= 0;
            csr[8]  <= 0; csr[9]  <= 0; csr[10] <= 0; csr[11] <= 0;
            // Perf
            perf_cycles <= 0; perf_gemm_cycles <= 0; perf_softmax_cycles <= 0;
            perf_stall_cycles <= 0; perf_mem_stalls <= 0;
            perf_tiles <= 0; perf_exp_ops <= 0;
        end else begin
            // ---- Defaults for pulses ----
            irq_done       <= 0;
            sm_tile_start  <= 0;
            sm_seq_start   <= 0;
            sm_score_valid <= 0;
            bram_init_en   <= 0;
            axi_wr_fire    <= 0;

            // ==========================================================
            // AXI4-Lite Write Channel
            // ==========================================================
            if (s_axil_awvalid && s_axil_awready && !aw_recv) begin
                aw_addr_q      <= s_axil_awaddr;
                aw_recv        <= 1;
                s_axil_awready <= 0;
            end

            if (s_axil_wvalid && s_axil_wready && !w_recv) begin
                w_data_q      <= s_axil_wdata;
                w_recv        <= 1;
                s_axil_wready <= 0;
            end

            if (aw_recv && w_recv && !s_axil_bvalid) begin
                // Write to CSR (except STATUS at index 1)
                if (aw_addr_q[7:2] < 6'd12 && aw_addr_q[7:2] != 6'd1)
                    csr[aw_addr_q[7:2]] <= w_data_q;
                s_axil_bvalid <= 1;
                aw_recv       <= 0;
                w_recv        <= 0;
                axi_wr_fire   <= 1;
            end

            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid  <= 0;
                s_axil_awready <= 1;
                s_axil_wready  <= 1;
            end

            // ==========================================================
            // Main FSM (shares this always_ff so it can safely write csr[])
            // ==========================================================
            if (main_state != MAIN_IDLE && csr[1][0])
                cycle_cnt <= cycle_cnt + 32'd1;

            case (main_state)
                MAIN_IDLE: begin
                    // Check start bit (csr[0][0]) — but don't overwrite it
                    // if AXI is writing to it on this same cycle
                    if (csr[0][0] && !axi_wr_fire) begin
                        main_state    <= MAIN_INIT_STATS;
                        csr[0][0]     <= 0;  // Clear start
                        csr[1]        <= 32'h1;  // STATUS = busy
                        seq_len_reg   <= csr[2][15:0];
                        tile_i        <= 0;
                        tile_j        <= 0;
                        cycle_cnt     <= 0;
                        gemm_cnt      <= 0;
                        softmax_cnt   <= 0;
                        stall_cnt     <= 0;
                        mem_cnt       <= 0;
                        bram_init_idx <= 0;
                        bram_init_en  <= 1;
                        sm_seq_start  <= 1;
                    end
                end

                MAIN_INIT_STATS: begin
                    bram_init_en <= 1;
                    if (bram_init_idx < TILE_BR_16 - 16'd1)
                        bram_init_idx <= bram_init_idx + 16'd1;
                    else begin
                        bram_init_en <= 0;
                        main_state   <= MAIN_LOAD_KV;
                    end
                end

                MAIN_LOAD_KV: begin
                    mem_cnt    <= mem_cnt + 32'd1;
                    main_state <= MAIN_LOAD_Q;
                end

                MAIN_LOAD_Q: begin
                    mem_cnt    <= mem_cnt + 32'd1;
                    main_state <= MAIN_GEMM0;
                end

                MAIN_GEMM0: begin
                    gemm_cnt      <= gemm_cnt + 32'd1;
                    // In full design: GEMM feeds scores into softmax here
                    // sm_tile_start <= 1;
                    main_state    <= MAIN_SOFTMAX_WAIT;
                end

                MAIN_SOFTMAX_WAIT: begin
                    softmax_cnt <= softmax_cnt + 32'd1;
                    // In full design: wait for sm_tile_done
                    // For now: pass through (no GEMM feeding scores yet)
                    stall_cnt   <= stall_cnt + 32'd0;  // No stalls
                    main_state  <= MAIN_GEMM1;
                end

                MAIN_GEMM1: begin
                    gemm_cnt   <= gemm_cnt + 32'd1;
                    main_state <= MAIN_NEXT_Q;
                end

                MAIN_NEXT_Q: begin
                    if (tile_i + TILE_BR_16 >= seq_len_reg) begin
                        tile_i     <= 0;
                        main_state <= MAIN_NEXT_KV;
                    end else begin
                        tile_i     <= tile_i + TILE_BR_16;
                        main_state <= MAIN_LOAD_Q;
                    end
                end

                MAIN_NEXT_KV: begin
                    if (tile_j + TILE_BC_16 >= seq_len_reg) begin
                        main_state <= MAIN_DONE;
                    end else begin
                        tile_j     <= tile_j + TILE_BC_16;
                        main_state <= MAIN_LOAD_KV;
                    end
                end

                MAIN_DONE: begin
                    perf_cycles         <= cycle_cnt;
                    perf_gemm_cycles    <= gemm_cnt;
                    perf_softmax_cycles <= softmax_cnt;
                    perf_stall_cycles   <= stall_cnt;
                    perf_mem_stalls     <= mem_cnt;
                    perf_tiles          <= {16'b0, (seq_len_reg / TILE_BR_16)} *
                                           {16'b0, (seq_len_reg / TILE_BC_16)};
                    perf_exp_ops        <= sm_exp_ops;
                    csr[1]              <= 32'h2;  // STATUS = done
                    irq_done            <= 1;
                    main_state          <= MAIN_IDLE;
                end

                default: main_state <= MAIN_IDLE;
            endcase
        end
    end

    // ==================================================================
    // AXI4-Lite Read Channel (separate — reads only, no writes to csr[])
    // ==================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axil_arready <= 1;
            s_axil_rvalid  <= 0;
            s_axil_rresp   <= 2'b00;
            s_axil_rdata   <= 32'd0;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_arready <= 0;
                s_axil_rvalid  <= 1;
                case (s_axil_araddr[7:2])
                    6'd0:  s_axil_rdata <= csr[0];
                    6'd1:  s_axil_rdata <= csr[1];
                    6'd2:  s_axil_rdata <= csr[2];
                    6'd3:  s_axil_rdata <= csr[3];
                    6'd4:  s_axil_rdata <= csr[4];
                    6'd5:  s_axil_rdata <= csr[5];
                    6'd6:  s_axil_rdata <= csr[6];
                    6'd7:  s_axil_rdata <= csr[7];
                    6'd8:  s_axil_rdata <= csr[8];
                    6'd9:  s_axil_rdata <= csr[9];
                    6'd10: s_axil_rdata <= csr[10];
                    6'd12: s_axil_rdata <= perf_cycles;
                    6'd13: s_axil_rdata <= perf_gemm_cycles;
                    6'd14: s_axil_rdata <= perf_softmax_cycles;
                    6'd15: s_axil_rdata <= perf_stall_cycles;
                    6'd16: s_axil_rdata <= perf_mem_stalls;
                    6'd17: s_axil_rdata <= perf_tiles;
                    6'd18: s_axil_rdata <= perf_exp_ops;
                    default: s_axil_rdata <= 32'hDEADBEEF;
                endcase
            end
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid  <= 0;
                s_axil_arready <= 1;
            end
        end
    end

endmodule
