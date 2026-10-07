`timescale 1ns/1ps
`default_nettype none
module trng_core #(
    parameter integer NUM_RO = 8,
    parameter integer WARMUP_CYCLES = 8
) (
    input wire clk,
    input wire rst_n,
    input wire trng_en,
    output wire done,
    output wire [255:0] seed_out
);
    wire [NUM_RO-1:0] ro_outputs;
    wire ro_enable = rst_n && trng_en && !done;
    genvar i;
    generate
        for (i=0; i<NUM_RO; i=i+1) begin : gen_ro
            ring_osc #(.SEED(i+1), .STAGES(5+2*i)) inst_ro (
                .ena(ro_enable), .osc_out(ro_outputs[i])
            );
        end
    endgenerate
    trng_conditioner #(.NUM_RO(NUM_RO), .WARMUP_CYCLES(WARMUP_CYCLES)) conditioner (
        .clk(clk), .rst_n(rst_n), .trng_en(trng_en),
        .ro_outputs(ro_outputs), .done(done), .seed_out(seed_out)
    );
endmodule
`default_nettype wire
