`timescale 1ns/1ps
`default_nettype none
// One seed request -> SHA3-512 absorb; optionally append ML-KEM k=2.
// Do not share SHA3 with another master while busy. Read digest at core output.
module trng_sha3_bridge #(
    parameter integer APPEND_K = 1
) (
    input wire clk,
    input wire rst_n,
    input wire request,
    output wire busy,
    output reg seed_sent,
    output wire trng_en,
    input wire trng_done,
    input wire [255:0] seed_out,
    input wire sha3_ready_in,
    input wire sha3_perm_busy,
    output wire [1:0] mode_sel,
    output wire start_absorb,
    output wire in_valid,
    output wire [63:0] in_data,
    output wire [2:0] in_bytes_vld,
    output wire in_last
);
    localparam [2:0] IDLE=0, CLEAR=1, GENERATE=2, START=3, SEND=4;
    reg [2:0] phase;
    reg [2:0] word_idx;
    reg [255:0] seed_latched;
    reg request_d;
    assign busy = (phase != IDLE);
    assign trng_en = (phase == GENERATE);
    assign mode_sel = 2'b00;
    assign start_absorb = (phase == START) && !sha3_perm_busy;
    assign in_valid = (phase == SEND);
    assign in_data = (word_idx == 4) ? 64'h02 : (seed_latched >> (64*word_idx));
    assign in_bytes_vld = (word_idx == 4) ? 3'd1 : 3'd0;
    assign in_last = (phase == SEND) && (word_idx == (APPEND_K ? 4 : 3));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= IDLE;
            word_idx <= 0;
            seed_latched <= 0;
            request_d <= 0;
            seed_sent <= 0;
        end else begin
            request_d <= request;
            seed_sent <= 0;
            case (phase)
                IDLE: if (request && !request_d) phase <= CLEAR;
                CLEAR: phase <= GENERATE;
                GENERATE: if (trng_done) begin
                    seed_latched <= seed_out;
                    word_idx <= 0;
                    phase <= START;
                end
                START: if (!sha3_perm_busy) phase <= SEND;
                SEND: if (sha3_ready_in) begin
                    if (in_last) begin phase <= IDLE; seed_sent <= 1; end
                    else word_idx <= word_idx+1'b1;
                end
                default: phase <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
