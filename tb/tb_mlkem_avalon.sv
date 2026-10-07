`timescale 1ns/1ps
`include "integration_counts.vh"
module tb_mlkem_avalon;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0;
 reg [13:0] address=0;
 reg rd=0,wr=0;reg [31:0] wd=0;reg [3:0] be=15;
 wire [31:0] data;wire rv,waitreq,irq;
 reg [7:0] entropy=0;reg [31:0] lfsr=32'h20320204;
 always begin #3;lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};entropy=lfsr[7:0];end
 mlkem_avalon_wrapper #(.USE_EXTERNAL_ENTROPY(1)) dut(clk,rst_n,address,rd,wr,wd,be,data,rv,waitreq,irq,entropy);
 integer i,j,h,op,ni,no,io,oo,n,f,tests=0,coef=0,hashes=0,bytes_checked=0;
 reg [31:0] x,y,meta,status;
 reg [23:0] a[0:127],b[0:127],c[0:127],want[0:127];
 reg [2:0] commands[0:`PAU_CASE_COUNT-1];
 reg [7:0] decode_bytes[0:383],encode_bytes[0:383];
 reg [63:0] hin[0:`HASH_INPUT_WORDS-1],hout[0:`HASH_OUTPUT_WORDS-1],poly[0:63];
 reg [95:0] hc[0:`HASH_CASES-1];
 reg [63:0] actual,mask;reg [7:0] keep;
 string filename;
 task write32(input integer addr,input reg[31:0] value,input reg[3:0] enables=15);
  integer t;reg accepted;
  begin
   @(negedge clk);address=addr;wd=value;be=enables;wr=1;rd=0;t=0;accepted=0;
   while(!accepted) begin @(posedge clk);accepted=!waitreq;t=t+1;if(t>50000)$fatal(1,"write timeout addr=%x",addr);end
   @(negedge clk);wr=0;be=15;
  end
 endtask
 task read32(input integer addr,output reg[31:0] value);
  integer t;reg accepted;
  begin
   @(negedge clk);address=addr;rd=1;wr=0;be=15;t=0;accepted=0;
   while(!accepted) begin @(posedge clk);accepted=!waitreq;t=t+1;if(t>50000)$fatal(1,"read accept timeout addr=%x",addr);end
   #1;
   while(!rv) begin @(posedge clk);#1;t=t+1;if(t>50000)$fatal(1,"read response timeout");end
   value=data;@(negedge clk);rd=0;
  end
 endtask
 task launch(input integer cmd,input integer sa,input integer sb,input integer sd,input integer mode=0);
  begin write32('h00c,cmd|(sa<<4)|(sb<<8)|(sd<<12)|(mode<<16));write32('h004,1);end
 endtask
 task finish_ok;
  integer t;
  begin
   t=0;status=0;
   while(!status[1]) begin read32('h008,status);t=t+1;if(t>20000)$fatal(1,"done timeout");end
   if(status[2] || status[0])$fatal(1,"unexpected status %x",status);
   repeat(9) @(negedge clk);read32('h008,x);if(!x[1])$fatal(1,"done not sticky");
   write32('h004,4);read32('h008,x);if(x[1])$fatal(1,"done clear");tests=tests+1;
  end
 endtask
 task load(input integer slot,input integer which);
  begin for(j=0;j<128;j=j+1)write32('h1000+slot*512+j*4,which==0?a[j]:(which==1?b[j]:c[j]));end
 endtask
 task compare(input integer slot);
  begin for(j=0;j<128;j=j+1)begin read32('h1000+slot*512+j*4,x);if(x!=={8'd0,want[j]})$fatal(1,"RAM mismatch slot=%0d word=%0d got=%x want=%x",slot,j,x,want[j]);coef=coef+2;end end
 endtask
 task drain(input integer count,input integer offset,input integer is_poly=0);
  integer remaining,idx,k;
  begin
   remaining=count;idx=0;
   while(remaining>0)begin
    repeat(idx%5) @(negedge clk);
    read32('h030,x);read32('h034,y);read32('h038,meta);
    read32('h034,status);if(status!==y)$fatal(1,"hash snapshot changed");
    actual={y,x};keep=remaining>=8?255:255>>(8-remaining);
    mask=remaining>=8?64'hffffffffffffffff:64'hffffffffffffffff>>(8*(8-remaining));
    if((actual&mask)!==((is_poly?poly[idx]:hout[offset+idx])&mask) || meta[7:0]!==keep || meta[8]!==(remaining<=8) || !meta[9])$fatal(1,"hash mismatch idx=%0d got=%x meta=%x",idx,actual,meta);
    hashes=hashes+1;remaining=remaining>=8?remaining-8:0;idx=idx+1;
   end
   finish_ok();
  end
 endtask
 initial begin
  $readmemh("tb/vectors/commands.hex",commands);
  $readmemh("tb/vectors/decode_input.hex",decode_bytes);$readmemh("tb/vectors/encode_expected.hex",encode_bytes);
  $readmemh("tb/vectors/hash_input.hex",hin);$readmemh("tb/vectors/hash_expected.hex",hout);$readmemh("tb/vectors/hash_cases.hex",hc);
  repeat(3)@(negedge clk);rst_n=1;
  read32(0,x);if(x!==32'h4d4b0100)$fatal(1,"ID");
  read32('h1000,x);repeat(2)@(negedge clk);read32(8,x);if(!x[2] || x[11:8]!=4)$fatal(1,"invalid RAM read");write32(4,8);
  write32('h1000,24'hffffff);read32(8,x);if(!x[2] || x[11:8]!=3)$fatal(1,"invalid coefficient");write32(4,8);
  write32('h1000,0,1);read32(8,x);if(x[11:8]!=10)$fatal(1,"partial RAM write");write32(4,8);
  read32(3,x);read32(8,x);if(x[11:8]!=9)$fatal(1,"unaligned access");write32(4,8);
  write32('h02c,0,1);read32(8,x);if(x[11:8]!=10)$fatal(1,"partial hash commit");write32(4,8);
  write32('h00c,32'h12345678);write32('h00c,32'hab000000,8);read32('h00c,x);if(x!==32'hab345678)$fatal(1,"byteenable merge");
  write32('h01c,3);launch(15,0,0,0);repeat(8)@(negedge clk);read32(8,x);
  if(!irq || !x[1] || !x[2] || x[11:8]!=1)$fatal(1,"rejected command/IRQ");write32(4,12);if(irq)$fatal(1,"IRQ ack");
  // Soft reset must win when a completion/error pulse arrives on the same edge.
  launch(15,0,0,0);address=4;wd=2;wr=1;
  @(posedge clk);if(waitreq)$fatal(1,"reset acceptance");@(negedge clk);wr=0;
  repeat(5)@(negedge clk);read32(8,x);if(x[2:0]!=0)$fatal(1,"reset/completion collision");
  for(i=0;i<`PAU_CASE_COUNT;i=i+1)begin
   filename=$sformatf("tb/vectors/case_%03d_a.hex",i);$readmemh(filename,a);
   filename=$sformatf("tb/vectors/case_%03d_b.hex",i);$readmemh(filename,b);
   filename=$sformatf("tb/vectors/case_%03d_c.hex",i);$readmemh(filename,c);
   filename=$sformatf("tb/vectors/case_%03d_expected.hex",i);$readmemh(filename,want);
   load(0,0);load(1,1);load(2,2);launch(commands[i],0,1,2);finish_ok();compare(commands[i]<2?0:2);
  end
  launch(6,0,0,15);for(i=0;i<384;i=i+1)begin repeat(i%3)@(negedge clk);write32('h020,decode_bytes[i],1);end
  finish_ok();$readmemh("tb/vectors/decode_expected.hex",want);compare(15);
  launch(5,15,0,0);for(i=0;i<384;i=i+1)begin repeat(i%4)@(negedge clk);read32('h024,x);if(x!=={24'd0,encode_bytes[i]})$fatal(1,"encode byte %0d",i);bytes_checked=bytes_checked+1;end finish_ok();
  for(h=0;h<`HASH_CASES;h=h+1)begin
   ni=hc[h][23:8];no=hc[h][39:24];io=hc[h][63:40];oo=hc[h][95:64];
   write32('h010,(no<<16)|ni);launch(7,0,0,0,hc[h][1:0]);
   for(i=0;i<(ni+7)/8;i=i+1)begin write32('h028,hin[io+i][31:0]);write32('h02c,hin[io+i][63:32]);end
   drain(no,oo);
  end
  for(h=0;h<4;h=h+1)begin
   case(h)0:begin filename="tb/vectors/poly_sha512.hex";no=64;end 1:begin filename="tb/vectors/poly_shake128.hex";no=509;end 2:begin filename="tb/vectors/poly_shake256.hex";no=413;end 3:begin filename="tb/vectors/poly_sha256.hex";no=32;end endcase
   $readmemh(filename,poly,0,(no+7)/8-1);write32('h010,no<<16);launch(8,15,0,0,h);drain(no,0,1);
  end
  // Busy start is rejected, and configuration writes cannot alter captured parameters.
  launch(0,15,0,0);write32('h00c,15);write32(4,1);read32(8,x);if(x[11:8]!=8)$fatal(1,"busy start");write32(4,8);finish_ok();
  // Abort a stalled stream and run a real operation after reset.
  launch(6,0,0,2);write32('h020,1);write32(4,2);repeat(5)@(negedge clk);read32('h014,x);if(x!=0)$fatal(1,"reset slot valid");
  for(j=0;j<128;j=j+1)a[j]=0;load(0,0);launch(0,0,0,0);finish_ok();for(j=0;j<128;j=j+1)want[j]=0;compare(0);
  // External raw path, output snapshot and context word addressing.
  f=$fopen("results/avalon_seed.txt","w");launch(9,0,0,0);
  for(i=0;i<8;i=i+1)begin read32('h030,x);read32('h034,y);$fwrite(f,"word 0 %0d %016x\n",i,{y,x});end finish_ok();
  $fwrite(f,"seed 0 ");for(i=7;i>=0;i=i-1)begin read32('h040+4*i,x);$fwrite(f,"%08x",x);end $fwrite(f,"\n");$fclose(f);
  for(i=0;i<8;i=i+1)begin read32('h060+4*i,x);if(x!==dut.u_top.rho[i*32+:32])$fatal(1,"rho read map");read32('h080+4*i,x);if(x!==dut.u_top.sigma[i*32+:32])$fatal(1,"sigma read map");end
  $display("PASS Avalon: commands=%0d coefficients=%0d bytes=%0d hash_words=%0d protocol/reset/IRQ/seed",tests,coef,bytes_checked,hashes);$finish;
 end
 initial begin #60000000;$fatal(1,"Avalon watchdog");end
endmodule
