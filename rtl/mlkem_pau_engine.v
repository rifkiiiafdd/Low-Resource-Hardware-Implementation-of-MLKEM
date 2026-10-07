`timescale 1ns/1ps
`default_nettype none
// Scheduler adapted from pau_top; storage is Sarah's shared ram_poly.
// Word = {odd,even}; slot base = slot*128. NTT/INTT are in place in src_a.
module mlkem_pau_engine (
 input wire clk,rst_n,start, input wire [2:0] cmd,
 input wire [3:0] src_a,src_b,dst,
 output wire busy, output reg done,error,
 output wire we_a,we_b, output wire [10:0] addr_a,addr_b,
 output wire [23:0] din_a,din_b, input wire [23:0] dout_a,dout_b,
 output wire [2:0] trace_stage
);
 localparam IDLE=0,READ=1,LAUNCH=2,WAIT=3,READ_ACC=4,LAUNCH_ACC=5,WAIT_ACC=6;
 reg [2:0] state,op,stage;
 reg [3:0] sa,sb,sd;
 reg [6:0] span,offset,cursor,zidx;
 reg [7:0] base;
 reg start_d;
 reg [23:0] product;
 wire transform=op<2;
 wire accum=state==READ_ACC || state==LAUNCH_ACC || state==WAIT_ACC;
 wire [7:0] addr_sum=base+{1'b0,offset};
 wire [6:0] ra=transform ? addr_sum[6:0] : cursor;
 wire [6:0] rb=transform ? ra+span : cursor;
 wire [8:0] next_block={1'b0,base}+({2'b0,span}<<1);
 wire [6:0] rom_idx=transform ? zidx : 7'd64+{1'b0,cursor[6:1]};
 wire [11:0] zeta;
 pau_zeta_rom u_zeta(rom_idx,zeta);
 wire [11:0] twiddle=transform ? zeta : (cursor[0] ? 12'd3329-zeta : zeta);
 wire core_start=state==LAUNCH || state==LAUNCH_ACC;
 wire core_done,core_error,core_we,core_busy;
 wire [1:0] mask;
 wire [6:0] wa,wb;
 wire [11:0] o1,o2,o3,o4;
 wire [23:0] word0={o2,o1},word1={o4,o3};
 wire [23:0] input_a=accum ? product : dout_a;
 wire [23:0] input_b=accum ? dout_a : dout_b;
 wire [1:0] core_mode=accum || op==4 ? 2'b11 : (op==0 ? 2'b00 : (op==1 ? 2'b01 : 2'b10));
 pau_core u_core(
  .clk(clk),.rst_n(rst_n),.enable(1'b1),.start(core_start),.mode(core_mode),
  .ram_rd_addr_a(ra),.ram_rd_addr_b(rb),
  .coeff_in_1(input_a[11:0]),.coeff_in_2(input_a[23:12]),
  .coeff_in_3(input_b[11:0]),.coeff_in_4(input_b[23:12]),.twiddle_factor(twiddle),
  .busy(core_busy),.done(core_done),.error(core_error),.ram_wr_addr_a(wa),.ram_wr_addr_b(wb),
  .ram_wr_en(core_we),.ram_wr_mask(mask),
  .coeff_out_1(o1),.coeff_out_2(o2),.coeff_out_3(o3),.coeff_out_4(o4)
 );
 wire store=core_we && ((state==WAIT && op!=3) || state==WAIT_ACC);
 assign busy=state!=IDLE;
 assign we_a=rst_n && store && mask[0];
 assign we_b=rst_n && store && mask[1];
 assign addr_a=store ? {transform ? sa : sd,wa} : {accum ? sd : sa,ra};
 assign addr_b=store ? {sa,wb} : {transform ? sa : sb,rb};
 assign din_a=word0;assign din_b=word1;assign trace_stage=stage;
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=IDLE;op<=0;stage<=0;sa<=0;sb<=0;sd<=0;
   span<=0;offset<=0;cursor<=0;zidx<=0;base<=0;product<=0;start_d<=0;done<=0;error<=0;
  end else begin
   done<=0;error<=0;start_d<=start;
   case(state)
    IDLE: if(start && !start_d) begin
     op<=cmd;sa<=src_a;sb<=src_b;sd<=dst;stage<=0;offset<=0;cursor<=0;base<=0;
     span<=cmd==1 ? 7'd1 : 7'd64;zidx<=cmd==1 ? 7'd127 : 7'd1;
     if(cmd>4) begin done<=1;error<=1;end else state<=READ;
    end
    READ:state<=LAUNCH;
    LAUNCH:state<=WAIT;
    READ_ACC:state<=LAUNCH_ACC;
    LAUNCH_ACC:state<=WAIT_ACC;
    WAIT,WAIT_ACC: if(core_done) begin
     if(core_error) begin state<=IDLE;done<=1;error<=1;end
     else if(state==WAIT && op==3) begin product<=word0;state<=READ_ACC;end
     else if(transform) begin
      if(offset+7'd1<span) begin offset<=offset+1'b1;state<=READ;end
      else begin
       offset<=0;
       if(next_block<128) begin base<=next_block[7:0];zidx<=op==0 ? zidx+1'b1 : zidx-1'b1;state<=READ;end
       else if((op==0 && span==1) || (op==1 && span==64)) begin state<=IDLE;done<=1;end
       else begin
        base<=0;span<=op==0 ? span>>1 : span<<1;zidx<=op==0 ? zidx+1'b1 : zidx-1'b1;
        stage<=stage+1'b1;state<=READ;
       end
      end
     end else if(cursor==127) begin state<=IDLE;done<=1;end
     else begin cursor<=cursor+1'b1;state<=READ;end
    end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
`default_nettype wire
