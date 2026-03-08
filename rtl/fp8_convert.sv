// ==========================================================================
// FP8 E4M3 Conversion Units — Fully Synthesizable
// ==========================================================================

`timescale 1ns / 1ps

/* verilator lint_off DECLFILENAME */

// ---- FP8 E4M3 -> FP32 (dequantize) ----
module fp8_e4m3_to_fp32 (
    input  logic [7:0]  fp8_in,
    output logic [31:0] fp32_out
);
    logic        e4_sign;
    logic [3:0]  e4_exp;
    logic [2:0]  e4_man;
    logic [7:0]  fp32_exp;

    always_comb begin
        e4_sign  = fp8_in[7];
        e4_exp   = fp8_in[6:3];
        e4_man   = fp8_in[2:0];
        fp32_exp = 8'd0;
        fp32_out = 32'd0;

        if (e4_exp == 4'd0 && e4_man == 3'd0) begin
            fp32_out = {e4_sign, 31'b0};
        end else if (e4_exp == 4'd0) begin
            // Denormal
            fp32_out = {e4_sign, 8'd117, e4_man, 20'b0};
        end else if (e4_exp == 4'hF && e4_man == 3'b111) begin
            // NaN
            fp32_out = {e4_sign, 8'hFF, 23'h400000};
        end else begin
            // Normal: FP32 exp = e4_exp + 120
            fp32_exp = {4'b0, e4_exp} + 8'd120;
            fp32_out = {e4_sign, fp32_exp, e4_man, 20'b0};
        end
    end
endmodule


// ---- FP32 -> FP8 E4M3 (quantize) ----
module fp32_to_fp8_e4m3 (
    input  logic [31:0] fp32_in,
    output logic [7:0]  fp8_out
);
    logic        fp_sign;
    logic [7:0]  fp_exp;
    logic [22:0] fp_man;
    logic signed [8:0] e4_exp_unbiased;
    logic [3:0]  e4_exp_biased;
    logic [2:0]  e4_mantissa;

    always_comb begin
        fp_sign         = fp32_in[31];
        fp_exp          = fp32_in[30:23];
        fp_man          = fp32_in[22:0];
        e4_exp_unbiased = 9'sd0;
        e4_exp_biased   = 4'd0;
        e4_mantissa     = 3'd0;
        fp8_out         = 8'd0;

        if (fp_exp == 8'd0) begin
            // Zero or FP32 denormal
            fp8_out = {fp_sign, 7'b0};
        end else begin
            e4_exp_unbiased = {1'b0, fp_exp} - 9'd120;

            if (e4_exp_unbiased <= 9'sd0) begin
                // Underflow
                fp8_out = {fp_sign, 7'b0};
            end else if (e4_exp_unbiased >= 9'sd15) begin
                // Overflow: clamp to max normal (exp=14, man=110 -> 448)
                fp8_out = {fp_sign, 4'd14, 3'b110};
            end else begin
                e4_exp_biased = e4_exp_unbiased[3:0];
                e4_mantissa   = fp_man[22:20];

                // Round to nearest (check bit 19)
                if (fp_man[19]) begin
                    if (e4_mantissa == 3'b111) begin
                        e4_mantissa   = 3'b000;
                        e4_exp_biased = e4_exp_biased + 4'd1;
                        if (e4_exp_biased >= 4'd15)
                            fp8_out = {fp_sign, 4'd14, 3'b110};
                        else
                            fp8_out = {fp_sign, e4_exp_biased, e4_mantissa};
                    end else begin
                        fp8_out = {fp_sign, e4_exp_biased, e4_mantissa + 3'd1};
                    end
                end else begin
                    fp8_out = {fp_sign, e4_exp_biased, e4_mantissa};
                end
            end
        end
    end
endmodule


// ---- Block Scale Factor: find max absolute value in a stream ----
module block_scale_finder #(
    parameter TILE_ELEMS = 16384
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [31:0] elem_in,
    input  logic        elem_valid,
    output logic [30:0] absmax_out,
    output logic        absmax_valid,
    output logic [31:0] count
);
    logic [30:0] running_max;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running_max  <= 31'h0;
            absmax_valid <= 0;
            absmax_out   <= 31'h0;
            count        <= 32'd0;
        end else begin
            absmax_valid <= 0;
            if (start) begin
                running_max <= 31'h0;
                count       <= 32'd0;
            end
            if (elem_valid) begin
                if (elem_in[30:0] > running_max)
                    running_max <= elem_in[30:0];
                count <= count + 32'd1;
                if (count == TILE_ELEMS[31:0] - 32'd1) begin
                    absmax_out   <= (elem_in[30:0] > running_max) ? elem_in[30:0] : running_max;
                    absmax_valid <= 1;
                end
            end
        end
    end

endmodule

/* verilator lint_on DECLFILENAME */
