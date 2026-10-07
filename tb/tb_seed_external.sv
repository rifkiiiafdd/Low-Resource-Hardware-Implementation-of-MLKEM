`timescale 1ns/1ps
// Focused test of the exact USE_EXTERNAL_ENTROPY=1 Quartus configuration.
module tb_seed_external;
 reg test_pass=0;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,start=0;reg [7:0] entropy_raw=0;
 reg [31:0] stimulus=32'h20320204;
 always begin
  #3;stimulus={stimulus[30:0],stimulus[31]^stimulus[21]^stimulus[1]^stimulus[0]};entropy_raw=stimulus[7:0];
 end
 wire busy,done,error,valid,last,context_valid;wire [3:0] ec;wire [63:0] data;wire [7:0] keep;
 wire [255:0] seed,rho,sigma;reg ready=0;
 mlkem_top #(.USE_EXTERNAL_ENTROPY(1)) dut(
  .clk(clk),.rst_n(rst_n),.start(start),.cmd(4'd9),.src_a_slot(4'd0),.src_b_slot(4'd0),.dst_slot(4'd0),
  .hash_mode(2'd0),.hash_input_bytes(16'd0),.hash_output_bytes(16'd64),.busy(busy),.done(done),.error(error),.error_code(ec),
  .host_we(1'b0),.host_re(1'b0),.host_addr(11'd0),.host_wdata(24'd0),
  .byte_in_valid(1'b0),.byte_in(8'd0),.byte_out_ready(1'b0),.hash_in_valid(1'b0),.hash_in_data(64'd0),
  .hash_out_valid(valid),.hash_out_data(data),.hash_out_keep(keep),.hash_out_last(last),.hash_out_ready(ready),
  .entropy_raw(entropy_raw),.seed_d(seed),.rho(rho),.sigma(sigma),.seed_context_valid(context_valid));
 integer n,t,f,sid;
 initial begin
  f=$fopen("results/external_seeds.txt","w");repeat(3) @(negedge clk);rst_n=1;
  for(sid=0;sid<2;sid=sid+1) begin
   @(negedge clk);start=1;@(negedge clk);start=0;n=0;t=0;
   while(n<8) begin
    @(negedge clk);ready=t%9>=3;t=t+1;
    @(posedge clk);if(valid && ready) begin
     if(keep!=255 || last!==(n==7)) $fatal(1,"external entropy hash protocol");
     $fwrite(f,"word %0d %0d %016x\n",sid,n,data);n=n+1;
    end
    if(t>20000 || error) $fatal(1,"external entropy timeout/error");
   end
   @(negedge clk);ready=0;if(!done || !context_valid || busy) $fatal(1,"external seed status");
   $fwrite(f,"seed %0d %064x\n",sid,seed);@(negedge clk);
  end
  $fclose(f);$display("PASS external entropy TOP: 2 seed sessions; independent hash checked by runner");test_pass=1;$finish;
 end
endmodule
