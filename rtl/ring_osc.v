`timescale 1ns/1ps
`default_nettype none
// Hardware is the default. Define TRNG_SIM ONLY for RTL simulations.
// The simulation model is deterministic pseudojitter, not physical entropy.
module ring_osc #(
    parameter integer SEED = 1,
    parameter integer STAGES = 5 + 2*(SEED-1)
) (
    input wire ena,
    output wire osc_out
);
`ifdef TRNG_SIM
    reg osc_reg;
    reg [31:0] jitter_state;
    integer delay_ps;
    initial begin
        osc_reg = 1'b1;
        jitter_state = 32'h9e3779b9 ^ (SEED * 32'h10203);
        forever begin
            wait (ena === 1'b1);
            while (ena === 1'b1) begin
                jitter_state = {jitter_state[30:0],
                    jitter_state[31]^jitter_state[21]^jitter_state[1]^jitter_state[0]};
                delay_ps = 1100 + SEED*137 + (jitter_state[7:0] % 97);
                #(delay_ps * 0.001);
                if (ena === 1'b1) osc_reg = ~osc_reg;
            end
            osc_reg = 1'b1;
        end
    end
    assign osc_out = ena ? osc_reg : 1'b1;
`else
    // Explicit LCELL boundaries plus keep prevent collapsing an inverter chain.
    // Odd STAGES includes the NAND enable gate. Disabled output settles to 1.
    (* keep = 1, syn_keep = 1 *) wire [STAGES-1:0] node;
    lcell gate_cell (.in(~(ena & node[STAGES-1])), .out(node[0]));
    genvar k;
    generate
        for (k=1; k<STAGES; k=k+1) begin : gen_stage
            lcell inverter_cell (.in(~node[k-1]), .out(node[k]));
        end
    endgenerate
    assign osc_out = node[STAGES-1];
`endif
    // synthesis translate_off
    initial if (STAGES < 3 || STAGES%2 == 0 || SEED < 1)
        $fatal(1, "ring_osc requires odd STAGES>=3 and SEED>=1");
    // synthesis translate_on
endmodule
`default_nettype wire
