// ==========================================================================
// Hardened Softmax Pipeline — Pipelined Exponential Unit
// ==========================================================================
// exp(x) for x <= 0. Range reduction + degree-4 polynomial (Horner).
// 1 result/cycle, 5-cycle latency, 4 DSP48E2, ~300 LUT.
// ==========================================================================

`timescale 1ns / 1ps

module pipelined_exp #(
    parameter DATA_WIDTH = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic [DATA_WIDTH-1:0]    x_in,
    input  logic                     x_valid,
    output logic [DATA_WIDTH-1:0]    y_out,
    output logic                     y_valid
);

    // Q8.24 fixed-point constants
    localparam signed [31:0] Q_LN2     = 32'sh00B17218;
    localparam signed [31:0] Q_INV_LN2 = 32'sh01715476;
    localparam signed [31:0] Q_ONE     = 32'sh01000000;
    localparam signed [31:0] Q_HALF    = 32'sh00800000;
    localparam signed [31:0] Q_INV6    = 32'sh002AAAAB;
    localparam signed [31:0] Q_INV24   = 32'sh000AAAAB;

    // ---- FP32 to Q8.24 (combinational) ----
    logic signed [31:0] x_fixed;
    logic               cv_sign;
    logic [7:0]         cv_exp_biased;
    logic [23:0]        cv_mantissa;
    logic signed [8:0]  cv_exp_unbiased;
    logic signed [8:0]  cv_shift;
    logic [31:0]        cv_abs_fixed;

    always_comb begin
        cv_sign         = x_in[31];
        cv_exp_biased   = x_in[30:23];
        cv_mantissa     = {1'b1, x_in[22:0]};
        cv_exp_unbiased = {1'b0, cv_exp_biased} - 9'd127;
        cv_shift        = cv_exp_unbiased + 9'sd1;
        cv_abs_fixed    = 32'd0;
        x_fixed         = 32'sd0;

        if (cv_exp_biased != 8'd0) begin
            if (cv_shift >= 0 && cv_shift < 9'sd24)
                cv_abs_fixed = {8'b0, cv_mantissa} << cv_shift;
            else if (cv_shift < 0 && cv_shift > -9'sd24)
                cv_abs_fixed = {8'b0, cv_mantissa} >> (-cv_shift);

            x_fixed = cv_sign ? -$signed({1'b0, cv_abs_fixed}) : $signed({1'b0, cv_abs_fixed});
        end
    end

    // ---- Stage 1: Range reduction ----
    logic signed [31:0] s1_n, s1_r;
    logic               s1_valid, s1_underflow;

    // Stage 1 combinational intermediates
    logic signed [63:0] s1_prod_c, s1_nln2_c;
    logic signed [31:0] s1_n_tmp_c;
    logic signed [31:0] s1_r_c;
    logic               s1_uf_c;

    always_comb begin
        s1_prod_c  = $signed(x_fixed) * $signed(Q_INV_LN2);
        s1_n_tmp_c = s1_prod_c[55:24];
        s1_nln2_c  = s1_n_tmp_c * $signed(Q_LN2);
        s1_r_c     = x_fixed - s1_nln2_c[55:24];
        s1_uf_c    = (x_fixed < -32'sh574CCCCD);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 0; s1_underflow <= 0; s1_n <= 0; s1_r <= 0;
        end else begin
            s1_valid     <= x_valid;
            s1_n         <= s1_n_tmp_c;
            s1_r         <= s1_r_c;
            s1_underflow <= s1_uf_c;
        end
    end

    // ---- Stage 2: r squared ----
    logic signed [31:0] s2_r, s2_r2, s2_n;
    logic               s2_valid, s2_underflow;

    logic signed [63:0] s2_sq_c;

    always_comb begin
        s2_sq_c = $signed(s1_r) * $signed(s1_r);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 0; s2_r <= 0; s2_r2 <= 0; s2_n <= 0; s2_underflow <= 0;
        end else begin
            s2_valid     <= s1_valid;
            s2_n         <= s1_n;
            s2_r         <= s1_r;
            s2_underflow <= s1_underflow;
            s2_r2        <= s2_sq_c[55:24];
        end
    end

    // ---- Stage 3: Horner step 1 ----
    logic signed [31:0] s3_p, s3_r, s3_r2, s3_n;
    logic               s3_valid, s3_underflow;

    logic signed [63:0] s3_t1_c, s3_t2_c;
    logic signed [31:0] s3_inner_c, s3_p_c;

    always_comb begin
        s3_t1_c    = $signed(s2_r) * $signed(Q_INV24);
        s3_inner_c = Q_INV6 + s3_t1_c[55:24];
        s3_t2_c    = $signed(s2_r) * $signed(s3_inner_c);
        s3_p_c     = Q_HALF + s3_t2_c[55:24];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 0; s3_p <= 0; s3_r <= 0; s3_r2 <= 0; s3_n <= 0; s3_underflow <= 0;
        end else begin
            s3_valid     <= s2_valid;
            s3_n         <= s2_n;
            s3_r         <= s2_r;
            s3_r2        <= s2_r2;
            s3_underflow <= s2_underflow;
            s3_p         <= s3_p_c;
        end
    end

    // ---- Stage 4: Horner step 2 ----
    logic signed [31:0] s4_exp_r, s4_n;
    logic               s4_valid, s4_underflow;

    logic signed [63:0] s4_t_c;
    logic signed [31:0] s4_exp_r_c;

    always_comb begin
        s4_t_c     = $signed(s3_r2) * $signed(s3_p);
        s4_exp_r_c = Q_ONE + s3_r + s4_t_c[55:24];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_valid <= 0; s4_exp_r <= 0; s4_n <= 0; s4_underflow <= 0;
        end else begin
            s4_valid     <= s3_valid;
            s4_n         <= s3_n;
            s4_underflow <= s3_underflow;
            s4_exp_r     <= s4_exp_r_c;
        end
    end

    // ---- Stage 5: Reconstruction (combinational + output register) ----
    logic [31:0]       s5_pos;
    logic [4:0]        s5_lz;
    logic              s5_found;
    logic [31:0]       s5_shifted;
    logic signed [8:0] s5_exp_calc;
    integer            s5_i;

    always_comb begin
        s5_pos   = (s4_exp_r[31]) ? 32'h0 : s4_exp_r[31:0];
        s5_lz    = 5'd31;
        s5_found = 1'b0;
        for (s5_i = 31; s5_i >= 0; s5_i = s5_i - 1) begin
            if (s5_pos[s5_i] && !s5_found) begin
                s5_lz    = 5'd31 - s5_i[4:0];
                s5_found = 1'b1;
            end
        end
        s5_shifted  = s5_pos << (s5_lz + 5'd1);
        s5_exp_calc = 9'sd134 - {4'b0, s5_lz} + s4_n[8:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_valid <= 0; y_out <= 32'h0;
        end else begin
            y_valid <= s4_valid;
            if (s4_valid) begin
                if (s4_underflow || s5_pos == 32'h0)
                    y_out <= 32'h00000000;
                else if (s5_exp_calc <= 9'sd0)
                    y_out <= 32'h00000000;
                else if (s5_exp_calc >= 9'sd255)
                    y_out <= 32'h7F800000;
                else
                    y_out <= {1'b0, s5_exp_calc[7:0], s5_shifted[30:8]};
            end
        end
    end

endmodule
