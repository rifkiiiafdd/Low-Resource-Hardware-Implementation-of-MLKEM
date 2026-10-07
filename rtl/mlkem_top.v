`timescale 1ns/1ps
`default_nettype none
// Shared-memory component TOP. Algorithm sampling/KEM orchestration is external.
// Commands: 0 NTT,1 INTT,2 PWM,3 MAC,4 ADD,5 Encode12,6 Decode12,
// 7 hash host stream,8 hash ByteEncode12(slot),9 TRNG -> G(d||02).
module mlkem_top #(
 parameter integer USE_EXTERNAL_ENTROPY=0
)(
 input wire clk,rst_n,start, input wire [3:0] cmd,
 input wire [3:0] src_a_slot,src_b_slot,dst_slot,
 input wire [1:0] hash_mode, input wire [15:0] hash_input_bytes,hash_output_bytes,
 output wire busy, output reg done,error, output reg [3:0] error_code,
 input wire host_we,host_re, input wire [10:0] host_addr, input wire [23:0] host_wdata,
 output wire host_ready, output reg host_rvalid, output wire [23:0] host_rdata,
 output wire [15:0] slots_valid,
 input wire byte_in_valid, input wire [7:0] byte_in, output wire byte_in_ready,
 output wire byte_out_valid, output wire [7:0] byte_out, input wire byte_out_ready,
 input wire hash_in_valid, input wire [63:0] hash_in_data, output wire hash_in_ready,
 output wire hash_out_valid, output wire [63:0] hash_out_data,
 output wire [7:0] hash_out_keep, output wire hash_out_last, input wire hash_out_ready,
 input wire [7:0] entropy_raw, output wire [255:0] seed_d,
 output reg [255:0] rho,sigma, output reg seed_context_valid,
 output wire trace_we_a,trace_we_b, output wire [10:0] trace_addr_a,trace_addr_b,
 output wire [23:0] trace_data_a,trace_data_b,
 output wire [3:0] debug_state, output wire [2:0] trace_stage
);
 localparam IDLE=0,PAU_START=1,PAU_RUN=2,TC_START=3,TC_RUN=4,
  HASH_START=5,HASH_INPUT=6,HASH_CAPTURE=7,HASH_DRAIN=8,XOF_NEXT=9,
  POLY_START=10,POLY_RUN=11,RNG_START=12,RNG_RUN=13;
 reg [3:0] state,op,sa,sb,sd;
 reg [1:0] hm;
 reg [15:0] input_left,output_left;
 reg start_d;
 reg [2047:0] word_valid;
 genvar sl;
 generate for(sl=0;sl<16;sl=sl+1) begin:gen_slot_valid
  assign slots_valid[sl]=&word_valid[sl*128 +:128];
 end endgenerate
 wire request=start && !start_d;
 wire hash_length_ok=(hash_mode==0 && hash_output_bytes==64) ||
  (hash_mode==3 && hash_output_bytes==32) ||
  ((hash_mode==1 || hash_mode==2) && hash_output_bytes!=0);
 wire sources_ok=(cmd==6 || cmd==7 || cmd==9) ||
  (slots_valid[src_a_slot] &&
   (cmd<2 || cmd==5 || cmd==8 || (slots_valid[src_b_slot] && (cmd!=3 || slots_valid[dst_slot]))));
 assign busy=rst_n && state!=IDLE;
 assign debug_state=state;
 assign host_ready=rst_n && state==IDLE && !start;
 wire host_canonical=host_wdata[11:0]<12'd3329 && host_wdata[23:12]<12'd3329;
 wire host_load=host_ready && host_we && host_canonical;

 wire p_busy,p_done,p_error,p_we_a,p_we_b;
 wire [10:0] p_addr_a,p_addr_b;
 wire [23:0] p_data_a,p_data_b,ram_out_a,ram_out_b;
 mlkem_pau_engine u_pau(
  .clk(clk),.rst_n(rst_n),.start(state==PAU_START),.cmd(op[2:0]),
  .src_a(sa),.src_b(sb),.dst(sd),.busy(p_busy),.done(p_done),.error(p_error),
  .we_a(p_we_a),.we_b(p_we_b),.addr_a(p_addr_a),.addr_b(p_addr_b),
  .din_a(p_data_a),.din_b(p_data_b),.dout_a(ram_out_a),.dout_b(ram_out_b),.trace_stage(trace_stage)
 );
 wire tc_busy,tc_done,tc_we,tc_in_ready,tc_out_valid;
 wire [10:0] tc_addr;
 wire [23:0] tc_data;
 wire [7:0] tc_byte;
 wire poly_owner=state==POLY_START || state==POLY_RUN;
 wire tc_owner=state==TC_START || state==TC_RUN || poly_owner;
 reg [63:0] pack_word;
 reg [2:0] pack_idx;
 reg pack_valid;
 reg [5:0] poly_word_idx;
 wire pack_ready=!pack_valid;
 mlkem_transcoder u_transcoder(
  .clk(clk),.rst_n(rst_n),.start(state==TC_START || state==POLY_START),
  .mode(op==6 ? 2'b01 : 2'b00),.ram_base_addr({op==6 ? sd : sa,7'd0}),
  .busy(tc_busy),.done(tc_done),.ram_we(tc_we),.ram_addr(tc_addr),.ram_din(tc_data),.ram_dout(ram_out_a),
  .byte_in_valid(byte_in_valid && state==TC_RUN && op==6),.byte_in(byte_in),.byte_in_ready(tc_in_ready),
  .byte_out_valid(tc_out_valid),.byte_out(tc_byte),.byte_out_ready(poly_owner ? pack_ready : byte_out_ready)
 );
 assign byte_in_ready=state==TC_RUN && op==6 && tc_in_ready;
 assign byte_out_valid=state==TC_RUN && op==5 && tc_out_valid;
 assign byte_out=tc_byte;

 wire trng_en,trng_done;
 generate if(USE_EXTERNAL_ENTROPY!=0) begin:gen_external_entropy
  trng_conditioner u_trng(.clk(clk),.rst_n(rst_n),.trng_en(trng_en),.ro_outputs(entropy_raw),.done(trng_done),.seed_out(seed_d));
 end else begin:gen_ring_entropy
  trng_core u_trng(.clk(clk),.rst_n(rst_n),.trng_en(trng_en),.done(trng_done),.seed_out(seed_d));
 end endgenerate
 wire rng_owner=state==RNG_START || state==RNG_RUN;
 wire bridge_busy,bridge_sent,bridge_start,bridge_valid,bridge_last;
 wire [1:0] bridge_mode;
 wire [63:0] bridge_data;
 wire [2:0] bridge_bytes;
 wire sha_ready,sha_perm,sha_valid;
 wire [63:0] sha_word;
 wire [4:0] sha_idx;
 trng_sha3_bridge #(.APPEND_K(1)) u_seed_bridge(
  .clk(clk),.rst_n(rst_n),.request(state==RNG_START),.busy(bridge_busy),.seed_sent(bridge_sent),
  .trng_en(trng_en),.trng_done(trng_done),.seed_out(seed_d),
  .sha3_ready_in(sha_ready),.sha3_perm_busy(sha_perm),.mode_sel(bridge_mode),.start_absorb(bridge_start),
  .in_valid(bridge_valid),.in_data(bridge_data),.in_bytes_vld(bridge_bytes),.in_last(bridge_last)
 );
 wire sha_start=state==HASH_START || state==POLY_START || (rng_owner && bridge_start);
 wire [63:0] sha_input=rng_owner ? bridge_data : (poly_owner ? pack_word : hash_in_data);
 wire sha_in_valid=rng_owner ? bridge_valid : (poly_owner ? pack_valid : (state==HASH_INPUT && hash_in_valid));
 wire sha_last=rng_owner ? bridge_last :
  (poly_owner ? poly_word_idx==47 : (state==HASH_START ? input_left==0 : input_left<=8));
 wire [2:0] sha_bytes=rng_owner ? bridge_bytes : (poly_owner ? 3'd0 : (input_left<8 ? input_left[2:0] : 3'd0));
 sha3_keccak_core u_sha3(
  .clk(clk),.rst_n(rst_n),.mode_sel(rng_owner ? bridge_mode : hm),.start_absorb(sha_start),
  .squeeze_next(state==XOF_NEXT),.ready_in(sha_ready),.perm_busy(sha_perm),.squeeze_valid(sha_valid),
  .in_valid(sha_in_valid),.in_data(sha_input),.in_bytes_vld(sha_bytes),.in_last(sha_last),
  .out_word(sha_word),.out_word_idx(sha_idx)
 );
 assign hash_in_ready=rst_n && state==HASH_INPUT && sha_ready;
 reg [63:0] hash_buffer[0:20];
 reg [4:0] drain_idx,burst_count;
 wire hash_owner=state==HASH_INPUT || state==HASH_CAPTURE || state==POLY_RUN || state==RNG_RUN;
 wire [4:0] last_sha_idx=(op==9 || hm==0) ? 5'd7 : (hm==3 ? 5'd3 : (hm==1 ? 5'd20 : 5'd16));
 wire [3:0] output_bytes=output_left>=8 ? 4'd8 : {1'b0,output_left[2:0]};
 assign hash_out_valid=rst_n && state==HASH_DRAIN;
 assign hash_out_data=hash_out_valid ? hash_buffer[drain_idx] : 64'd0;
 assign hash_out_keep=hash_out_valid ? (8'hff >> (4'd8-output_bytes)) : 8'd0;
 assign hash_out_last=hash_out_valid && output_left<=8;

 wire pau_owner=state==PAU_START || state==PAU_RUN;
 wire ram_we_a=rst_n && (pau_owner ? p_we_a : (tc_owner ? tc_we : host_load));
 wire ram_we_b=rst_n && pau_owner && p_we_b;
 wire [10:0] ram_addr_a=pau_owner ? p_addr_a : (tc_owner ? tc_addr : host_addr);
 wire [10:0] ram_addr_b=pau_owner ? p_addr_b : 11'd0;
 wire [23:0] ram_data_a=pau_owner ? p_data_a : (tc_owner ? tc_data : host_wdata);
 ram_poly u_ram(
  .clk(clk),.we_a(ram_we_a),.addr_a(ram_addr_a),.din_a(ram_data_a),.dout_a(ram_out_a),
  .we_b(ram_we_b),.addr_b(ram_addr_b),.din_b(p_data_b),.dout_b(ram_out_b)
 );
 assign host_rdata=ram_out_a;
 assign trace_we_a=ram_we_a;assign trace_we_b=ram_we_b;
 assign trace_addr_a=ram_addr_a;assign trace_addr_b=ram_addr_b;
 assign trace_data_a=ram_data_a;assign trace_data_b=p_data_b;

 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;op<=0;sa<=0;sb<=0;sd<=0;hm<=0;input_left<=0;output_left<=0;
   start_d<=0;word_valid<=0;done<=0;error<=0;error_code<=0;host_rvalid<=0;
   pack_word<=0;pack_idx<=0;pack_valid<=0;poly_word_idx<=0;drain_idx<=0;burst_count<=0;
   rho<=0;sigma<=0;seed_context_valid<=0;
  end else begin
   done<=0;error<=0;error_code<=0;host_rvalid<=0;start_d<=start;
   if(ram_we_a) word_valid[ram_addr_a]<=1;
   if(ram_we_b) word_valid[ram_addr_b]<=1;
   if(host_ready && (host_we || host_re)) begin
    if(host_we && !host_canonical) begin error<=1;error_code<=3;end
    else if(host_re && !word_valid[host_addr]) begin error<=1;error_code<=4;end
    else if(host_re) host_rvalid<=1;
   end
   if(poly_owner) begin
    if(tc_out_valid && pack_ready) begin
     pack_word[pack_idx*8 +:8]<=tc_byte;
     if(pack_idx==7) begin pack_valid<=1;pack_idx<=0;end else pack_idx<=pack_idx+1'b1;
    end
    if(pack_valid && sha_ready) begin pack_valid<=0;poly_word_idx<=poly_word_idx+1'b1;end
   end
   case(state)
    IDLE: if(request) begin
     if(cmd>9 || ((cmd==7 || cmd==8) && !hash_length_ok)) begin done<=1;error<=1;error_code<=1;end
     else if(!sources_ok) begin done<=1;error<=1;error_code<=2;end
     else begin
      op<=cmd;sa<=src_a_slot;sb<=src_b_slot;sd<=dst_slot;hm<=hash_mode;
      input_left<=hash_input_bytes;output_left<=cmd==9 ? 16'd64 : hash_output_bytes;
      drain_idx<=0;burst_count<=0;
      if(cmd<5) begin
       word_valid[(cmd<2 ? src_a_slot : dst_slot)*128 +:128]<=0;state<=PAU_START;
      end else if(cmd==5 || cmd==6) begin
       if(cmd==6) word_valid[dst_slot*128 +:128]<=0;
       state<=TC_START;
      end else if(cmd==7) state<=HASH_START;
      else if(cmd==8) begin pack_word<=0;pack_idx<=0;pack_valid<=0;poly_word_idx<=0;state<=POLY_START;end
      else begin seed_context_valid<=0;state<=RNG_START;end
     end
    end
    PAU_START:state<=PAU_RUN;
    PAU_RUN:if(p_done) begin
     state<=IDLE;done<=1;
     if(p_error) begin error<=1;error_code<=5;word_valid[(op<2 ? sa : sd)*128 +:128]<=0;end
    end
    TC_START:state<=TC_RUN;
    TC_RUN:if(tc_done) begin state<=IDLE;done<=1;end
    HASH_START:state<=input_left==0 ? HASH_CAPTURE : HASH_INPUT;
    HASH_INPUT:if(hash_in_valid && sha_ready) begin
     if(input_left<=8) begin input_left<=0;state<=HASH_CAPTURE;end else input_left<=input_left-16'd8;
    end
    POLY_START:state<=POLY_RUN;
    RNG_START:state<=RNG_RUN;
    HASH_DRAIN:if(hash_out_ready) begin
     if(output_left<=8) begin output_left<=0;state<=IDLE;done<=1;end
     else begin
      output_left<=output_left-16'd8;
      if(drain_idx+1'b1==burst_count) begin drain_idx<=0;state<=XOF_NEXT;end
      else drain_idx<=drain_idx+1'b1;
     end
    end
    XOF_NEXT:state<=HASH_CAPTURE;
    default:begin end
   endcase
   // Capture every word of the unthrottled SHA burst before exposing it to host.
   if(hash_owner && sha_valid) begin
    hash_buffer[sha_idx]<=sha_word;
    if(op==9) begin
     if(sha_idx<4) rho[sha_idx*64 +:64]<=sha_word;
     else sigma[(sha_idx-5'd4)*64 +:64]<=sha_word;
    end
    if(sha_idx==last_sha_idx) begin
     burst_count<=sha_idx+1'b1;drain_idx<=0;state<=HASH_DRAIN;
     if(op==9) seed_context_valid<=1;
    end
   end
  end
 end
endmodule
`default_nettype wire
