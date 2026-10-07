`timescale 1ns/1ps
// Expected FAIL evidence on the original component, never used as integrated RTL.
module tb_original_transcoder;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,start=0,byte_in_valid=0;reg [7:0] byte_in=0;
 wire busy,done,ram_we,byte_in_ready,byte_out_valid;wire [10:0] ram_addr;wire [23:0] ram_din;wire [7:0] byte_out;
 transcoder dut(.clk(clk),.rst_n(rst_n),.start(start),.mode(2'b01),.ram_base_addr(11'd0),.busy(busy),.done(done),
  .ram_we(ram_we),.ram_addr(ram_addr),.ram_din(ram_din),.ram_dout(24'd0),
  .byte_in_valid(byte_in_valid),.byte_in(byte_in),.byte_in_ready(byte_in_ready),
  .byte_out_valid(byte_out_valid),.byte_out(byte_out),.byte_out_ready(1'b1));
 integer i;reg [7:0] bytes[0:2];
 initial begin
  bytes[0]=8'h34;bytes[1]=8'h12;bytes[2]=8'h56;
  repeat(3) @(negedge clk);rst_n=1;start=1;
  @(negedge clk);start=0;
  for(i=0;i<3;i=i+1) begin
   while(!byte_in_ready) @(negedge clk);
   byte_in_valid=1;byte_in=bytes[i];@(negedge clk);
  end
  byte_in_valid=0;
  if(ram_we && ram_din!==24'h561234) $fatal(1,"ORIGINAL_DECODE_BUG got=%06x expected=561234",ram_din);
  $fatal(1,"Original regression did not expose expected mismatch");
 end
endmodule
