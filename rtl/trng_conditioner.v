`timescale 1ns/1ps
`default_nettype none
// Digital sampling/debiasing/collector path, also a standalone GLS test top.
// ro_outputs is asynchronous. Only the first synchronizer stage samples it.
// Von Neumann is a debiaser; this is not a validated cryptographic conditioner.
module trng_conditioner #(
    parameter integer NUM_RO = 8,
    parameter integer WARMUP_CYCLES = 8
) (
    input wire clk,
    input wire rst_n,
    input wire trng_en,
    input wire [NUM_RO-1:0] ro_outputs,
    output reg done,
    output reg [255:0] seed_out
);
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [NUM_RO-1:0] ro_sampled_d1;
    (* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [NUM_RO-1:0] ro_sampled_d2;
    reg [31:0] warmup_count;
    reg [7:0] bit_counter;
    reg session_active;
    wire active = trng_en && !done;
    wire vn_enable = active && (warmup_count >= WARMUP_CYCLES);
    wire vn_valid, vn_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ro_sampled_d1 <= 0;
            ro_sampled_d2 <= 0;
            warmup_count <= 0;
        end else if (!active) begin
            ro_sampled_d1 <= 0;
            ro_sampled_d2 <= 0;
            warmup_count <= 0;
        end else begin
            ro_sampled_d1 <= ro_outputs;
            ro_sampled_d2 <= ro_sampled_d1;
            if (warmup_count < WARMUP_CYCLES) warmup_count <= warmup_count+1'b1;
        end
    end
    von_neumann inst_vn (
        .clk(clk), .rst_n(rst_n), .enable(vn_enable),
        .raw_bit(^ro_sampled_d2), .valid_bit(vn_valid), .clean_bit(vn_bit)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 0;
            seed_out <= 0;
            bit_counter <= 0;
            session_active <= 0;
        end else if (!trng_en) begin
            done <= 0;
            bit_counter <= 0;
            session_active <= 0;
            // Preserve a completed seed while disabled, until a new session.
        end else if (!session_active) begin
            session_active <= 1;
            seed_out <= 0;
            bit_counter <= 0;
            done <= 0;
        end else if (!done && vn_enable && vn_valid) begin
            // First accepted bit is seed_out[0]: byte/word order is explicit.
            seed_out[bit_counter] <= vn_bit;
            if (bit_counter == 255) done <= 1;
            else bit_counter <= bit_counter+1'b1;
        end
    end
    // synthesis translate_off
    initial if (NUM_RO < 1 || WARMUP_CYCLES < 3)
        $fatal(1, "NUM_RO>=1 and WARMUP_CYCLES>=3 required");
    // synthesis translate_on
endmodule
`default_nettype wire
