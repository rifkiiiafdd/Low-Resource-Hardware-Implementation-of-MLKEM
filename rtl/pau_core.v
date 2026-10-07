`timescale 1ns/1ps
`default_nettype none
// Transaction datapath matching the four-coefficient boundary in the design PDF.
// 00 CT: word A=(a0,a1), word B=(b0,b1), two even/odd butterflies.
// 01 GS: inverse butterflies, each output divided by two modulo q.
// 10 PWM: one degree-one base product, using four Karatsuba multiplies.
// 11 ADD: one word A+B. PWM/ADD only write address A (mask 01).
// Addresses are INPUT tags here; the full-poly scheduler generates them.
module pau_core (
    input wire clk, input wire rst_n, input wire enable,
    input wire start, input wire [1:0] mode,
    input wire [6:0] ram_rd_addr_a, input wire [6:0] ram_rd_addr_b,
    input wire [11:0] coeff_in_1, coeff_in_2, coeff_in_3, coeff_in_4,
    input wire [11:0] twiddle_factor,
    output wire busy, output wire done, output wire error,
    output wire [6:0] ram_wr_addr_a, ram_wr_addr_b,
    output wire ram_wr_en, output wire [1:0] ram_wr_mask,
    output reg [11:0] coeff_out_1, coeff_out_2, coeff_out_3, coeff_out_4
);
    localparam IDLE=3'd0, ISSUE0=3'd1, WAIT0=3'd2,
        ISSUE1=3'd3, WAIT1=3'd4, WRITE=3'd5, BAD=3'd6;
    reg [2:0] state;
    reg start_seen;
    reg [1:0] op;
    reg [6:0] addr_a, addr_b;
    reg [11:0] a0,a1,b0,b1,z,t0,t1;
    reg [11:0] mul_a0,mul_b0,mul_a1,mul_b1;
    wire [11:0] m0,m1;
    wire mv0,mv1;
    wire issue=(state==ISSUE0 || state==ISSUE1);
    function [11:0] addq;
        input [11:0] a,b;
        reg [12:0] s;
        begin s={1'b0,a}+{1'b0,b}; if(s>=13'd3329) s=s-13'd3329; addq=s[11:0]; end
    endfunction
    function [11:0] subq;
        input [11:0] a,b;
        reg [12:0] s;
        begin s={1'b0,a}+13'd3329-{1'b0,b}; if(s>=13'd3329) s=s-13'd3329; subq=s[11:0]; end
    endfunction
    function [11:0] halfq;
        input [11:0] a;
        reg [12:0] s;
        begin s={1'b0,a}+(a[0] ? 13'd3329 : 13'd0); halfq=s[12:1]; end
    endfunction
    always @* begin
        mul_a0=b0; mul_b0=z; mul_a1=b1; mul_b1=z;
        if(op==2'b01) begin mul_a0=subq(b0,a0); mul_a1=subq(b1,a1); end
        if(op==2'b10) begin
            if(state==ISSUE1) begin
                mul_a0=t1; mul_b0=z; mul_a1=addq(a0,a1); mul_b1=addq(b0,b1);
            end else begin mul_a0=a0; mul_b0=b0; mul_a1=a1; mul_b1=b1; end
        end
    end
    pau_modmul u_mul0(clk,rst_n,enable,issue,mul_a0,mul_b0,mv0,m0);
    pau_modmul u_mul1(clk,rst_n,enable,issue,mul_a1,mul_b1,mv1,m1);
    assign busy=(state!=IDLE);
    assign done=rst_n && enable && (state==WRITE || state==BAD);
    assign error=rst_n && enable && state==BAD;
    assign ram_wr_en=rst_n && enable && state==WRITE;
    assign ram_wr_mask=ram_wr_en ? ((op==2'b00 || op==2'b01) ? 2'b11 : 2'b01) : 2'b00;
    assign ram_wr_addr_a=addr_a;
    assign ram_wr_addr_b=addr_b;
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE; start_seen<=1'b0; op<=0; addr_a<=0; addr_b<=0;
            a0<=0; a1<=0; b0<=0; b1<=0; z<=0; t0<=0; t1<=0;
            coeff_out_1<=0; coeff_out_2<=0; coeff_out_3<=0; coeff_out_4<=0;
        end else if(enable) begin
            start_seen<=start;
            case(state)
                IDLE: if(start && !start_seen) begin
                    op<=mode; addr_a<=ram_rd_addr_a; addr_b<=ram_rd_addr_b;
                    a0<=coeff_in_1; a1<=coeff_in_2; b0<=coeff_in_3; b1<=coeff_in_4; z<=twiddle_factor;
                    if(coeff_in_1>=3329 || coeff_in_2>=3329 || coeff_in_3>=3329 || coeff_in_4>=3329 ||
                        (mode!=2'b11 && twiddle_factor>=3329)) state<=BAD;
                    else if(mode==2'b11) begin
                        coeff_out_1<=addq(coeff_in_1,coeff_in_3); coeff_out_2<=addq(coeff_in_2,coeff_in_4);
                        coeff_out_3<=0; coeff_out_4<=0; state<=WRITE;
                    end else state<=ISSUE0;
                end
                ISSUE0: state<=WAIT0;
                WAIT0: if(mv0 && mv1) begin
                    if(op==2'b10) begin t0<=m0; t1<=m1; state<=ISSUE1; end
                    else begin
                        if(op==2'b00) begin
                            coeff_out_1<=addq(a0,m0); coeff_out_2<=addq(a1,m1);
                            coeff_out_3<=subq(a0,m0); coeff_out_4<=subq(a1,m1);
                        end else begin
                            coeff_out_1<=halfq(addq(a0,b0)); coeff_out_2<=halfq(addq(a1,b1));
                            coeff_out_3<=halfq(m0); coeff_out_4<=halfq(m1);
                        end
                        state<=WRITE;
                    end
                end
                ISSUE1: state<=WAIT1;
                WAIT1: if(mv0 && mv1) begin
                    coeff_out_1<=addq(t0,m0); coeff_out_2<=subq(subq(m1,t0),t1);
                    coeff_out_3<=0; coeff_out_4<=0; state<=WRITE;
                end
                WRITE, BAD: state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
