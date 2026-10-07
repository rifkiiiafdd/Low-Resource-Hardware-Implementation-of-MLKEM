// ============================================================================
// File       : ram_poly.v
// Module     : ram_poly
// Description: Dual-Port Block RAM for ML-KEM (Kyber) Polynomials & Parameters
// Width      : 24 bits (Packs two 12-bit coefficients: c0 in [11:0], c1 in [23:12])
// Length     : 128 words per polynomial slot (128 * 2 = 256 coefficients)
// Total Slots: 16 slots (Slots 0..15 for d, z, rho, sigma, A_ij, s, t, e)
// ============================================================================

`timescale 1ns / 1ps

module ram_poly #(
    parameter DATA_WIDTH = 24,   // 2 coefficients * 12 bits
    parameter ADDR_WIDTH = 11,   // 2048 words total (16 slots * 128 words)
    parameter SLOT_WORDS = 128   // 128 words per polynomial
)(
    input  wire                  clk,
    
    // Port A (Used by Transcoder / External Host I/O)
    input  wire                  we_a,
    input  wire [ADDR_WIDTH-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] din_a,
    output reg  [DATA_WIDTH-1:0] dout_a,
    
    // Port B (Used by Polynomial Arithmetic Unit / NTT Core)
    input  wire                  we_b,
    input  wire [ADDR_WIDTH-1:0] addr_b,
    input  wire [DATA_WIDTH-1:0] din_b,
    output reg  [DATA_WIDTH-1:0] dout_b
);

    // BRAM Array inferrable by Intel Quartus / Xilinx Vivado
    (* ramstyle = "M10K, no_rw_check" *) reg [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

    // Port A Read/Write
    always @(posedge clk) begin
        if (we_a) begin
            mem[addr_a] <= din_a;
        end
        dout_a <= mem[addr_a];
    end

    // Port B Read/Write
    always @(posedge clk) begin
        if (we_b) begin
            mem[addr_b] <= din_b;
        end
        dout_b <= mem[addr_b];
    end

endmodule
