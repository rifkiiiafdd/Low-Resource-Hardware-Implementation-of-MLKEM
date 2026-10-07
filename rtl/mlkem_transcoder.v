`timescale 1ns/1ps
`default_nettype none
// Repair of Sarah's interface: synchronous RAM and standard ready/valid.
// ByteDecode_12 reduces 12-bit integers modulo q (FIPS 203 Algorithm 6).
module mlkem_transcoder (
 input wire clk,rst_n,start, input wire [1:0] mode,
 input wire [10:0] ram_base_addr, output wire busy, output reg done,
 output wire ram_we, output wire [10:0] ram_addr, output wire [23:0] ram_din,
 input wire [23:0] ram_dout,
 input wire byte_in_valid, input wire [7:0] byte_in, output wire byte_in_ready,
 output wire byte_out_valid, output wire [7:0] byte_out, input wire byte_out_ready
);
 localparam IDLE=0,READ=1,CAPTURE=2,SEND=3,RECV=4,WRITE=5;
 reg [2:0] state;
 reg [10:0] base;
 reg [6:0] word_idx;
 reg [1:0] byte_idx;
 reg [23:0] word_reg;
 reg [7:0] b0,b1;
 reg start_d;
 function [11:0] canonical;
  input [11:0] x;
  begin canonical=x>=12'd3329 ? x-12'd3329 : x; end
 endfunction
 assign busy=state!=IDLE;
 assign ram_addr=base+{4'd0,word_idx};
 assign ram_din=word_reg;
 assign ram_we=rst_n && state==WRITE;
 assign byte_in_ready=rst_n && state==RECV;
 assign byte_out_valid=rst_n && state==SEND;
 assign byte_out=word_reg >> (8*byte_idx);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE; base<=0;word_idx<=0;byte_idx<=0;word_reg<=0;b0<=0;b1<=0;done<=0;start_d<=0;
  end else begin
   done<=0;start_d<=start;
   case(state)
    IDLE: if(start && !start_d) begin
     base<=ram_base_addr;word_idx<=0;byte_idx<=0;
     state<=mode==0 ? READ : RECV;
    end
    READ: state<=CAPTURE;
    CAPTURE: begin word_reg<=ram_dout;byte_idx<=0;state<=SEND;end
    SEND: if(byte_out_ready) begin
     if(byte_idx==2) begin
      byte_idx<=0;
      if(word_idx==127) begin state<=IDLE;done<=1;end
      else begin word_idx<=word_idx+1'b1;state<=READ;end
     end else byte_idx<=byte_idx+1'b1;
    end
    RECV: if(byte_in_valid) begin
     if(byte_idx==0) b0<=byte_in;
     else if(byte_idx==1) b1<=byte_in;
     else begin
      word_reg<={canonical({byte_in,b1[7:4]}),canonical({b1[3:0],b0})};state<=WRITE;
     end
     byte_idx<=byte_idx==2 ? 0 : byte_idx+1'b1;
    end
    WRITE: begin
     if(word_idx==127) begin state<=IDLE;done<=1;end
     else begin word_idx<=word_idx+1'b1;state<=RECV;end
    end
    default: state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
