`timescale 1ns/1ps
`default_nettype none
// Avalon-MM, byte-addressed, 32-bit, non-bursting, variable-latency reads.
// A read is accepted on read && !waitrequest and completes at readdatavalid.
// RAM window 0x1000..0x2fff: 2048 logical words (24 bits) at 4-byte strides.
module mlkem_avalon_wrapper #(
 parameter integer USE_EXTERNAL_ENTROPY=0
)(
 input wire clk,rst_n,
 input wire [13:0] avs_address,
 input wire avs_read,avs_write,
 input wire [31:0] avs_writedata,
 input wire [3:0] avs_byteenable,
 output reg [31:0] avs_readdata,
 output reg avs_readdatavalid,
 output wire avs_waitrequest,
 output wire irq,
 input wire [7:0] entropy_raw
);
 localparam CONTROL=14'h004,STATUS=14'h008,COMMAND=14'h00c,LENGTHS=14'h010,
  SLOTS=14'h014,DEBUG=14'h018,IRQ_ENABLE=14'h01c,
  BYTE_IN=14'h020,BYTE_OUT=14'h024,HASH_IN_LO=14'h028,HASH_IN_HI=14'h02c,
  HASH_OUT_LO=14'h030,HASH_OUT_HI=14'h034,HASH_OUT_META=14'h038;
 reg [31:0] command_reg,length_reg,hash_low;
 reg [63:0] hash_snapshot;
 reg [7:0] hash_keep_snapshot;
 reg hash_last_snapshot,hash_snapshot_valid;
 reg done_sticky,error_sticky,active,ram_pending;
 reg [3:0] error_latched;
 reg [1:0] irq_enable,reset_count;
 wire core_rst_n=rst_n && reset_count==0;
 wire core_busy,core_done,core_error,host_ready,host_rvalid;
 wire [3:0] core_error_code,debug_state;
 wire [23:0] host_rdata;
 wire [15:0] slots_valid;
 wire byte_in_ready,byte_out_valid,hash_in_ready,hash_out_valid,hash_out_last;
 wire [7:0] byte_out,hash_out_keep;
 wire [63:0] hash_out_data;
 wire [255:0] seed_d,rho,sigma;
 wire seed_context_valid;
 wire [2:0] trace_stage;
 wire wrapper_busy=active || core_busy || reset_count!=0;
 wire ram_access=avs_address>=14'h1000 && avs_address<14'h3000;
 wire aligned=avs_address[1:0]==0;
 wire [31:0] byte_mask={{8{avs_byteenable[3]}},{8{avs_byteenable[2]}},
  {8{avs_byteenable[1]}},{8{avs_byteenable[0]}}};
 wire [31:0] write_bits=avs_writedata & byte_mask;
 wire bad_ram_write=ram_access && avs_write && avs_byteenable[2:0]!=3'b111;
 wire bad_hash_write=avs_address==HASH_IN_HI && avs_write && avs_byteenable!=4'hf;
 wire stall_data=aligned && !bad_ram_write && !bad_hash_write &&
  ((ram_access && !host_ready) ||
   (avs_write && avs_address==BYTE_IN && avs_byteenable[0] && !byte_in_ready) ||
   (avs_read && avs_address==BYTE_OUT && !byte_out_valid) ||
   (avs_write && avs_address==HASH_IN_HI && !hash_in_ready) ||
   (avs_read && avs_address==HASH_OUT_LO && !hash_out_valid));
 assign avs_waitrequest=!rst_n || reset_count!=0 || ram_pending ||
  ((avs_read || avs_write) && stall_data);
 wire accept=(avs_read || avs_write) && !avs_waitrequest;
 wire good=accept && aligned && !(avs_read && avs_write) && !bad_ram_write && !bad_hash_write;
 wire accepted_start=good && avs_write && avs_address==CONTROL && write_bits[0] &&
  !write_bits[1] && !wrapper_busy;
 wire accepted_reset=good && avs_write && avs_address==CONTROL && write_bits[1];
 wire host_we=good && avs_write && ram_access;
 wire host_re=good && avs_read && ram_access;
 wire byte_push=good && avs_write && avs_address==BYTE_IN && avs_byteenable[0];
 wire byte_pop=good && avs_read && avs_address==BYTE_OUT;
 wire hash_push=good && avs_write && avs_address==HASH_IN_HI;
 wire hash_pop=good && avs_read && avs_address==HASH_OUT_LO;
 assign irq=(irq_enable[0] && done_sticky) || (irq_enable[1] && error_sticky);
 mlkem_top #(.USE_EXTERNAL_ENTROPY(USE_EXTERNAL_ENTROPY)) u_top(
  .clk(clk),.rst_n(core_rst_n),.start(accepted_start),.cmd(command_reg[3:0]),
  .src_a_slot(command_reg[7:4]),.src_b_slot(command_reg[11:8]),.dst_slot(command_reg[15:12]),
  .hash_mode(command_reg[17:16]),.hash_input_bytes(length_reg[15:0]),.hash_output_bytes(length_reg[31:16]),
  .busy(core_busy),.done(core_done),.error(core_error),.error_code(core_error_code),
  .host_we(host_we),.host_re(host_re),.host_addr(avs_address[12:2]-11'h400),
  .host_wdata(avs_writedata[23:0]),.host_ready(host_ready),.host_rvalid(host_rvalid),.host_rdata(host_rdata),
  .slots_valid(slots_valid),.byte_in_valid(byte_push),.byte_in(avs_writedata[7:0]),.byte_in_ready(byte_in_ready),
  .byte_out_valid(byte_out_valid),.byte_out(byte_out),.byte_out_ready(byte_pop),
  .hash_in_valid(hash_push),.hash_in_data({avs_writedata,hash_low}),.hash_in_ready(hash_in_ready),
  .hash_out_valid(hash_out_valid),.hash_out_data(hash_out_data),.hash_out_keep(hash_out_keep),
  .hash_out_last(hash_out_last),.hash_out_ready(hash_pop),.entropy_raw(entropy_raw),
  .seed_d(seed_d),.rho(rho),.sigma(sigma),.seed_context_valid(seed_context_valid),
  .trace_we_a(),.trace_we_b(),.trace_addr_a(),.trace_addr_b(),.trace_data_a(),.trace_data_b(),
  .debug_state(debug_state),.trace_stage(trace_stage));
 function [31:0] merge_bytes;
  input [31:0] old_value,new_value,mask;
  begin merge_bytes=(old_value & ~mask) | (new_value & mask); end
 endfunction
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   command_reg<=0;length_reg<=32'h00400000;hash_low<=0;hash_snapshot<=0;
   hash_keep_snapshot<=0;hash_last_snapshot<=0;hash_snapshot_valid<=0;
   done_sticky<=0;error_sticky<=0;error_latched<=0;active<=0;ram_pending<=0;
   irq_enable<=0;reset_count<=0;avs_readdata<=0;avs_readdatavalid<=0;
  end else begin
   avs_readdatavalid<=0;
   if(reset_count!=0) reset_count<=reset_count-1'b1;
   if(ram_pending) begin
    avs_readdata<=host_rvalid ? {8'd0,host_rdata} : 32'd0;
    avs_readdatavalid<=1;ram_pending<=0;
   end
   if(accept) begin
    if(avs_read) begin avs_readdata<=0;avs_readdatavalid<=1;end
    if(!good) begin error_sticky<=1;error_latched<=bad_ram_write || bad_hash_write ? 4'd10 : 4'd9;end
    else if(ram_access) begin
     if(avs_read) begin ram_pending<=1;avs_readdatavalid<=0;end
    end else if(avs_write) begin
     case(avs_address)
      CONTROL: begin
       if(write_bits[2]) done_sticky<=0;
       if(write_bits[3]) begin error_sticky<=0;error_latched<=0;end
       if(write_bits[1]) begin
        reset_count<=3;active<=0;done_sticky<=0;error_sticky<=0;error_latched<=0;
        hash_snapshot_valid<=0;hash_snapshot<=0;hash_keep_snapshot<=0;hash_last_snapshot<=0;hash_low<=0;
       end else if(write_bits[0]) begin
        if(wrapper_busy) begin error_sticky<=1;error_latched<=8;end
        else begin active<=1;done_sticky<=0;error_sticky<=0;error_latched<=0;hash_snapshot_valid<=0;end
       end
      end
      COMMAND:command_reg<=merge_bytes(command_reg,avs_writedata,byte_mask);
      LENGTHS:length_reg<=merge_bytes(length_reg,avs_writedata,byte_mask);
      IRQ_ENABLE:if(avs_byteenable[0]) irq_enable<=avs_writedata[1:0];
      HASH_IN_LO:hash_low<=merge_bytes(hash_low,avs_writedata,byte_mask);
      BYTE_IN,HASH_IN_HI:begin end
      default:begin error_sticky<=1;error_latched<=9;end
     endcase
    end else begin
     case(avs_address)
      14'h000:avs_readdata<=32'h4d4b0100;
      CONTROL:avs_readdata<=0;
      STATUS:avs_readdata<={20'd0,error_latched,hash_out_valid,hash_in_ready,byte_out_valid,
       byte_in_ready,seed_context_valid,error_sticky,done_sticky,wrapper_busy};
      COMMAND:avs_readdata<=command_reg;
      LENGTHS:avs_readdata<=length_reg;
      SLOTS:avs_readdata<={16'd0,slots_valid};
      DEBUG:avs_readdata<={25'd0,trace_stage,debug_state};
      IRQ_ENABLE:avs_readdata<={30'd0,irq_enable};
      HASH_IN_LO:avs_readdata<=hash_low;
      BYTE_OUT:avs_readdata<={24'd0,byte_out};
      HASH_OUT_LO:begin
       avs_readdata<=hash_out_data[31:0];hash_snapshot<=hash_out_data;
       hash_keep_snapshot<=hash_out_keep;hash_last_snapshot<=hash_out_last;hash_snapshot_valid<=1;
      end
      HASH_OUT_HI:avs_readdata<=hash_snapshot[63:32];
      HASH_OUT_META:avs_readdata<={22'd0,hash_snapshot_valid,hash_last_snapshot,hash_keep_snapshot};
      default:begin
       if(avs_address>=14'h040 && avs_address<14'h060) avs_readdata<=seed_d[(avs_address-14'h040)*8 +:32];
       else if(avs_address>=14'h060 && avs_address<14'h080) avs_readdata<=rho[(avs_address-14'h060)*8 +:32];
       else if(avs_address>=14'h080 && avs_address<14'h0a0) avs_readdata<=sigma[(avs_address-14'h080)*8 +:32];
       else begin error_sticky<=1;error_latched<=9;end
      end
     endcase
    end
   end
   // Set wins over acknowledgement. Pulses from the core cannot be lost.
   if(core_rst_n && !accepted_reset && core_done) begin done_sticky<=1;active<=0;end
   if(core_rst_n && !accepted_reset && core_error) begin error_sticky<=1;error_latched<=core_error_code;end
  end
 end
endmodule
`default_nettype wire
