`timescale 1ns/1ps
`default_nettype none
module von_neumann (
    input  wire clk,
    input  wire rst_n,
    input  wire enable,
    input  wire raw_bit,
    output reg  valid_bit,
    output reg  clean_bit
);
    reg state;
    reg first_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= 1'b0;
            valid_bit <= 1'b0;
            clean_bit <= 1'b0;
            first_bit <= 1'b0;
        end else if (!enable) begin
            state     <= 1'b0;
            first_bit <= 1'b0;
            valid_bit <= 1'b0;
            clean_bit <= 1'b0;
        end else begin
            valid_bit <= 1'b0; // Default pulsa 1 siklus
            if (!state) begin
                first_bit <= raw_bit;
                state     <= 1'b1;
            end else begin
                state <= 1'b0;
                if ({first_bit, raw_bit} == 2'b01) begin
                    clean_bit <= 1'b0;
                    valid_bit <= 1'b1;
                end else if ({first_bit, raw_bit} == 2'b10) begin
                    clean_bit <= 1'b1;
                    valid_bit <= 1'b1;
                end
                // Pasangan 2'b00 dan 2'b11 diabaikan
            end
        end
    end
endmodule
`default_nettype wire
