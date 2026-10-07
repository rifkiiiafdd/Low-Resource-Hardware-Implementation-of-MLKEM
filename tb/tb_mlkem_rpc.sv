`timescale 1ns/1ps
// Text MMIO transport for the real compiled C driver. No algorithm emulation.
module tb_mlkem_rpc #(
 parameter integer USE_EXTERNAL_ENTROPY=0
);
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0;reg [13:0] address=0;reg read=0,write=0;
 reg [31:0] writedata=0;wire [31:0] readdata;
 wire readdatavalid,waitrequest,irq;
 mlkem_avalon_wrapper #(.USE_EXTERNAL_ENTROPY(USE_EXTERNAL_ENTROPY)) dut(clk,rst_n,address,read,write,writedata,4'hf,readdata,readdatavalid,waitrequest,irq,8'd0);
 integer code,scanned,t;reg [31:0] requested_address,requested_data,response;reg accepted;
 // Observation markers from the C runner; these do not drive the DUT.
 // 1 driver checks, 2 KeyGen, 3 Encaps, 4 Decaps, 5 rejection, 6 codec, 7 finished.
 reg [3:0] software_phase=0;
 reg [31:0] software_tc_id=0;
 string wave_file;
 string seed_log_file;
 integer seed_log=0,seed_sessions=0;
 reg seed_context_previous=0;
 localparam STDIN=32'h80000000,STDOUT=32'h80000001;
 initial begin
  if($value$plusargs("SEED_LOG=%s",seed_log_file)) seed_log=$fopen(seed_log_file,"w");
 end
 always @(posedge clk)begin
  if(!rst_n) seed_context_previous<=0;
  else begin
   seed_context_previous<=dut.seed_context_valid;
   if(seed_log && dut.seed_context_valid && !seed_context_previous)begin
    $fwrite(seed_log,"seed %0d %0t %064x\n",seed_sessions,$time,dut.seed_d);
    $fflush(seed_log);seed_sessions=seed_sessions+1;
   end
  end
 end
 initial begin
  if($value$plusargs("WAVE_FILE=%s",wave_file))begin
   $dumpfile(wave_file);
   $dumpvars(1,tb_mlkem_rpc);
   $dumpvars(1,tb_mlkem_rpc.dut);
   $dumpvars(0,dut.u_top.trace_we_a,dut.u_top.trace_we_b,
    dut.u_top.trace_addr_a,dut.u_top.trace_addr_b,dut.u_top.trace_data_a,dut.u_top.trace_data_b,
    dut.u_top.host_we,dut.u_top.host_re,dut.u_top.host_addr,dut.u_top.host_wdata,
    dut.u_top.host_rdata,dut.u_top.host_ready,dut.u_top.host_rvalid,
    dut.u_top.hash_in_data,dut.u_top.hash_in_valid,dut.u_top.hash_in_ready,
    dut.u_top.hash_out_data,dut.u_top.hash_out_valid,dut.u_top.hash_out_ready,
    dut.u_top.hash_out_keep,dut.u_top.hash_out_last,dut.u_top.debug_state,dut.u_top.trace_stage,
    dut.u_top.start,dut.u_top.cmd,dut.u_top.busy,dut.u_top.done,dut.u_top.error,dut.u_top.error_code);
  end
 end
 initial begin
  repeat(3)@(negedge clk);rst_n=1;$fwrite(STDOUT,"READY\n");$fflush(STDOUT);
  forever begin
   scanned=$fscanf(STDIN,"%d %h %h",code,requested_address,requested_data);
   if(scanned!=3)$fatal(1,"RPC input closed or malformed");
   if(code==3)begin if(seed_log)$fclose(seed_log);$fwrite(STDOUT,"BYE\n");$fflush(STDOUT);$finish;end
   if(code==4)begin
    @(negedge clk);software_phase=requested_address[3:0];software_tc_id=requested_data;
    $fwrite(STDOUT,"M %0t\n",$time);
   end else if(code==2)begin repeat(requested_data)@(negedge clk);$fwrite(STDOUT,"W %0t\n",$time);end
   else begin
    @(negedge clk);address=requested_address[13:0];writedata=requested_data;read=code==0;write=code==1;
    if(code!=0&&code!=1)$fatal(1,"invalid RPC opcode");
    t=0;accepted=0;
    while(!accepted)begin @(posedge clk);accepted=!waitrequest;t=t+1;if(t>100000)$fatal(1,"RPC bus timeout addr=%x",requested_address);end
    if(code==0)begin #1;while(!readdatavalid)begin @(posedge clk);#1;t=t+1;if(t>100000)$fatal(1,"RPC response timeout");end response=readdata;end
    @(negedge clk);read=0;write=0;
    if(code==0)$fwrite(STDOUT,"R %08x %0t\n",response,$time);else $fwrite(STDOUT,"W %0t\n",$time);
   end
   $fflush(STDOUT);
  end
 end
endmodule
