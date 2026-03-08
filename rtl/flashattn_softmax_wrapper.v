// ==========================================================================
// Verilog Wrapper for Block Design Module Reference
// ==========================================================================
// Vivado block design requires a .v top file for create_bd_cell -type module.
// This wrapper instantiates the SystemVerilog flashattn_softmax_top module.
// ==========================================================================

`timescale 1ns / 1ps

module flashattn_softmax_wrapper #(
    parameter MAX_SEQ_LEN = 4096,
    parameter HEAD_DIM    = 128,
    parameter TILE_BR     = 128,
    parameter TILE_BC     = 128
)(
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave
    input  wire [7:0]  s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output wire [1:0]  s_axil_bresp,
    output wire        s_axil_bvalid,
    input  wire        s_axil_bready,
    input  wire [7:0]  s_axil_araddr,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output wire [31:0] s_axil_rdata,
    output wire [1:0]  s_axil_rresp,
    output wire        s_axil_rvalid,
    input  wire        s_axil_rready,

    // Interrupt
    output wire        irq_done
);

    flashattn_softmax_top #(
        .MAX_SEQ_LEN (MAX_SEQ_LEN),
        .HEAD_DIM    (HEAD_DIM),
        .TILE_BR     (TILE_BR),
        .TILE_BC     (TILE_BC)
    ) u_core (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_axil_awaddr    (s_axil_awaddr),
        .s_axil_awvalid   (s_axil_awvalid),
        .s_axil_awready   (s_axil_awready),
        .s_axil_wdata     (s_axil_wdata),
        .s_axil_wstrb     (s_axil_wstrb),
        .s_axil_wvalid    (s_axil_wvalid),
        .s_axil_wready    (s_axil_wready),
        .s_axil_bresp     (s_axil_bresp),
        .s_axil_bvalid    (s_axil_bvalid),
        .s_axil_bready    (s_axil_bready),
        .s_axil_araddr    (s_axil_araddr),
        .s_axil_arvalid   (s_axil_arvalid),
        .s_axil_arready   (s_axil_arready),
        .s_axil_rdata     (s_axil_rdata),
        .s_axil_rresp     (s_axil_rresp),
        .s_axil_rvalid    (s_axil_rvalid),
        .s_axil_rready    (s_axil_rready),
        .irq_done         (irq_done)
    );

endmodule
