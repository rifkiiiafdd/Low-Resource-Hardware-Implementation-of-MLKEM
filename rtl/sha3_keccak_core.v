`timescale 1ns/1ps
`default_nettype none

// Iterative Keccak-f[1600]: one complete round per clock (24 clocks).
// Byte order: first message byte is in_data[7:0]. Lane index = x + 5*y.
// Input is accepted only at a rising edge with ready_in && in_valid.
// All non-final input words contain 8 bytes. On the final word, 0 means 8.
// start_absorb is a separate command; data on its edge is not accepted.
// Empty message command: start_absorb=1, in_last=1, in_valid=0.
// Output streams one word each clock while squeeze_valid=1; no backpressure.
// SHA3 outputs 8/4 words, SHAKE outputs the whole rate (21/17 words).
// Request another SHAKE block with squeeze_next after the current burst ends,
// or on the edge consuming its last word. Earlier requests are ignored.
module sha3_keccak_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  mode_sel,
    input  wire        start_absorb,
    input  wire        squeeze_next,
    output reg         ready_in,
    output reg         perm_busy,
    output reg         squeeze_valid,
    input  wire        in_valid,
    input  wire [63:0] in_data,
    input  wire [2:0]  in_bytes_vld,
    input  wire        in_last,
    output wire [63:0] out_word,
    output wire [4:0]  out_word_idx
);
    localparam [2:0] IDLE=0, ABSORB=1, PAD=2, PERMUTE=3, OUTPUT=4, WAIT_XOF=5;
    localparam [1:0] AFTER_ABSORB=0, AFTER_PAD=1, AFTER_OUTPUT=2;

    reg [2:0] phase;
    reg [1:0] after_perm;
    reg [1:0] mode_reg;
    reg [4:0] rate_words;
    reg [4:0] output_words;
    reg [7:0] suffix;
    reg [7:0] absorb_bytes;
    reg [4:0] round_idx;
    reg [4:0] output_idx;
    reg [63:0] a [0:24];

    reg [63:0] c [0:4];
    reg [63:0] d [0:4];
    reg [63:0] theta [0:24];
    reg [63:0] b [0:24];
    reg [63:0] round_result [0:24];
    reg [63:0] input_mask;
    reg [63:0] suffix_word;
    reg [3:0] valid_bytes;
    integer x, y, j, n;

    function [63:0] rol64;
        input [63:0] value;
        input integer amount;
        begin
            if (amount == 0) rol64 = value;
            else rol64 = (value << amount) | (value >> (64-amount));
        end
    endfunction

    function integer rho;
        input integer lane;
        begin
            case (lane)
                 0: rho=0;   1: rho=1;   2: rho=62;  3: rho=28;  4: rho=27;
                 5: rho=36;  6: rho=44;  7: rho=6;   8: rho=55;  9: rho=20;
                10: rho=3;  11: rho=10; 12: rho=43; 13: rho=25; 14: rho=39;
                15: rho=41; 16: rho=45; 17: rho=15; 18: rho=21; 19: rho=8;
                20: rho=18; 21: rho=2;  22: rho=61; 23: rho=56; 24: rho=14;
                default: rho=0;
            endcase
        end
    endfunction

    function [63:0] round_constant;
        input [4:0] index;
        begin
            case (index)
                 0: round_constant=64'h0000000000000001;
                 1: round_constant=64'h0000000000008082;
                 2: round_constant=64'h800000000000808a;
                 3: round_constant=64'h8000000080008000;
                 4: round_constant=64'h000000000000808b;
                 5: round_constant=64'h0000000080000001;
                 6: round_constant=64'h8000000080008081;
                 7: round_constant=64'h8000000000008009;
                 8: round_constant=64'h000000000000008a;
                 9: round_constant=64'h0000000000000088;
                10: round_constant=64'h0000000080008009;
                11: round_constant=64'h000000008000000a;
                12: round_constant=64'h000000008000808b;
                13: round_constant=64'h800000000000008b;
                14: round_constant=64'h8000000000008089;
                15: round_constant=64'h8000000000008003;
                16: round_constant=64'h8000000000008002;
                17: round_constant=64'h8000000000000080;
                18: round_constant=64'h000000000000800a;
                19: round_constant=64'h800000008000000a;
                20: round_constant=64'h8000000080008081;
                21: round_constant=64'h8000000000008080;
                22: round_constant=64'h0000000080000001;
                23: round_constant=64'h8000000080008008;
                default: round_constant=64'b0;
            endcase
        end
    endfunction

    // Theta -> Rho/Pi -> Chi -> Iota. All loop bounds are static.
    always @* begin
        for (x=0; x<5; x=x+1)
            c[x] = a[x] ^ a[x+5] ^ a[x+10] ^ a[x+15] ^ a[x+20];
        for (x=0; x<5; x=x+1)
            d[x] = c[(x+4)%5] ^ rol64(c[(x+1)%5], 1);
        for (y=0; y<5; y=y+1)
            for (x=0; x<5; x=x+1) begin
                theta[x+5*y] = a[x+5*y] ^ d[x];
                b[y+5*((2*x+3*y)%5)] = rol64(theta[x+5*y], rho(x+5*y));
            end
        for (y=0; y<5; y=y+1)
            for (x=0; x<5; x=x+1)
                round_result[x+5*y] = b[x+5*y] ^
                    ((~b[(x+1)%5+5*y]) & b[(x+2)%5+5*y]);
        round_result[0] = round_result[0] ^ round_constant(round_idx);
    end

    always @* begin
        valid_bytes = 4'd8;
        if (in_last && in_bytes_vld != 0)
            valid_bytes = {1'b0, in_bytes_vld};
        input_mask = 64'b0;
        for (j=0; j<8; j=j+1)
            if (j < valid_bytes) input_mask[j*8 +: 8] = 8'hff;
        suffix_word = {56'b0, suffix} << (8*absorb_bytes[2:0]);
        ready_in = rst_n && (phase == ABSORB) && !start_absorb;
        perm_busy = rst_n && (phase == PERMUTE);
        squeeze_valid = rst_n && (phase == OUTPUT) && !start_absorb;
    end

    assign out_word_idx = output_idx;
    // Capacity lanes are never exposed by the output index.
    assign out_word = squeeze_valid ? a[output_idx] : 64'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= IDLE;
            after_perm <= AFTER_ABSORB;
            mode_reg <= 0;
            rate_words <= 9;
            output_words <= 8;
            suffix <= 8'h06;
            absorb_bytes <= 0;
            round_idx <= 0;
            output_idx <= 0;
            for (n=0; n<25; n=n+1) a[n] <= 64'b0;
        end else if (start_absorb && phase != PERMUTE && phase != PAD) begin
            // Restart also permits dropping unused SHAKE output words.
            for (n=0; n<25; n=n+1) a[n] <= 64'b0;
            mode_reg <= mode_sel;
            absorb_bytes <= 0;
            round_idx <= 0;
            output_idx <= 0;
            after_perm <= AFTER_ABSORB;
            phase <= (in_last && !in_valid) ? PAD : ABSORB;
            case (mode_sel)
                2'b00: begin rate_words<=9;  output_words<=8;  suffix<=8'h06; end
                2'b01: begin rate_words<=21; output_words<=21; suffix<=8'h1f; end
                2'b10: begin rate_words<=17; output_words<=17; suffix<=8'h1f; end
                2'b11: begin rate_words<=17; output_words<=4;  suffix<=8'h06; end
            endcase
        end else begin
            case (phase)
                ABSORB: if (in_valid && ready_in) begin
                    a[absorb_bytes[7:3]] <= a[absorb_bytes[7:3]] ^ (in_data & input_mask);
                    if (absorb_bytes + {4'b0,valid_bytes} == {rate_words,3'b0}) begin
                        // A full final block still needs a separate padding block.
                        absorb_bytes <= 0;
                        round_idx <= 0;
                        after_perm <= in_last ? AFTER_PAD : AFTER_ABSORB;
                        phase <= PERMUTE;
                    end else begin
                        absorb_bytes <= absorb_bytes + {4'b0,valid_bytes};
                        if (in_last) phase <= PAD;
                    end
                end
                PAD: begin
                    // Combine both XORs if suffix and final bit share a lane.
                    // Thus rate-1 byte messages use suffix ^ 8'h80 in one byte.
                    if (absorb_bytes[7:3] == rate_words-1'b1)
                        a[absorb_bytes[7:3]] <= a[absorb_bytes[7:3]] ^
                            suffix_word ^ 64'h8000000000000000;
                    else begin
                        a[absorb_bytes[7:3]] <= a[absorb_bytes[7:3]] ^ suffix_word;
                        a[rate_words-1'b1] <= a[rate_words-1'b1] ^ 64'h8000000000000000;
                    end
                    after_perm <= AFTER_OUTPUT;
                    round_idx <= 0;
                    phase <= PERMUTE;
                end
                PERMUTE: begin
                    for (n=0; n<25; n=n+1) a[n] <= round_result[n];
                    if (round_idx == 23) begin
                        round_idx <= 0;
                        case (after_perm)
                            AFTER_ABSORB: phase <= ABSORB;
                            AFTER_PAD: phase <= PAD;
                            default: begin phase <= OUTPUT; output_idx <= 0; end
                        endcase
                    end else round_idx <= round_idx + 1'b1;
                end
                OUTPUT: begin
                    if (output_idx == output_words-1'b1) begin
                        output_idx <= 0;
                        if (mode_reg == 2'b01 || mode_reg == 2'b10) begin
                            if (squeeze_next) begin
                                phase <= PERMUTE;
                                round_idx <= 0;
                                after_perm <= AFTER_OUTPUT;
                            end else phase <= WAIT_XOF;
                        end else phase <= IDLE;
                    end else output_idx <= output_idx + 1'b1;
                end
                WAIT_XOF: if (squeeze_next) begin
                    phase <= PERMUTE;
                    round_idx <= 0;
                    after_perm <= AFTER_OUTPUT;
                end
                default: phase <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
