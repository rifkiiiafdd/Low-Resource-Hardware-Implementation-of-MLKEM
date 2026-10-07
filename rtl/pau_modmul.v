`timescale 1ns/1ps
`default_nettype none
// Canonical inputs 0..3328. Three registered stages, one input per CE clock.
// Barrett mu=floor(2^24/3329)=5039. No division or modulo in hardware.
module pau_modmul (
    input wire clk, input wire rst_n, input wire ce,
    input wire in_valid, input wire [11:0] a, input wire [11:0] b,
    output reg out_valid, output reg [11:0] result
);
    reg [23:0] product;
    reg [24:0] remainder;
    reg v1, v2;
    wire [36:0] x = {13'b0,product};
    // 5039 = 4096 + 1024 - 64 - 16 - 1.
    wire [36:0] scaled = (x << 12) + (x << 10) - (x << 6) - (x << 4) - x;
    wire [12:0] quotient = scaled[36:24];
    wire [24:0] qt = {12'b0,quotient};
    wire [24:0] q_multiple = (qt << 11) + (qt << 10) + (qt << 8) + qt;
    wire [24:0] corrected = (remainder >= 25'd3329) ? remainder-25'd3329 : remainder;
    always @(posedge clk) begin
        if (!rst_n) begin
            v1<=1'b0; v2<=1'b0; out_valid<=1'b0;
            product<=24'd0; remainder<=25'd0; result<=12'd0;
        end else if (ce) begin
            v1<=in_valid; v2<=v1; out_valid<=v2;
            if (in_valid) product<=a*b;
            if (v1) remainder<={1'b0,product}-q_multiple;
            if (v2) result<=corrected[11:0];
        end
    end
endmodule
`default_nettype wire
