`timescale 1ns/1ps
`include "integration_counts.vh"
module tb_mlkem_top;
 reg test_pass=0;
 reg clk=0;always #10 clk=~clk;
 reg rst_n=0,start=0;reg [3:0] cmd=0,src_a_slot=0,src_b_slot=1,dst_slot=2;
 reg [1:0] hash_mode=0;reg [15:0] hash_input_bytes=0,hash_output_bytes=64;
 wire busy,done,error;wire [3:0] error_code;
 reg host_we=0,host_re=0;reg [10:0] host_addr=0;reg [23:0] host_wdata=0;
 wire host_ready,host_rvalid;wire [23:0] host_rdata;wire [15:0] slots_valid;
 reg byte_in_valid=0;reg [7:0] byte_in=0;wire byte_in_ready,byte_out_valid;wire [7:0] byte_out;reg byte_out_ready=0;
 reg hash_in_valid=0;reg [63:0] hash_in_data=0;wire hash_in_ready,hash_out_valid;wire [63:0] hash_out_data;
 wire [7:0] hash_out_keep;wire hash_out_last;reg hash_out_ready=0;
 reg [7:0] entropy_raw=0;wire [255:0] seed_d,rho,sigma;wire seed_context_valid;
 wire trace_we_a,trace_we_b;wire [10:0] trace_addr_a,trace_addr_b;
 wire [23:0] trace_data_a,trace_data_b;wire [3:0] debug_state;wire [2:0] trace_stage;
 mlkem_top dut(.*);
 reg [23:0] a[0:127],b[0:127],c[0:127],expected[0:127];
 reg [23:0] decoded[0:127],chain_a[0:127],chain_b[0:127],chain_expected[0:127];
 reg [2:0] commands[0:`PAU_CASE_COUNT-1];
 reg [7:0] decode_bytes[0:383],encode_bytes[0:383],chain_bytes[0:383];
 reg [63:0] hash_inputs[0:`HASH_INPUT_WORDS-1],hash_expected[0:`HASH_OUTPUT_WORDS-1];
 reg [95:0] hash_cases[0:`HASH_CASES-1];reg [63:0] poly_expected[0:63];
 integer i,j,k,h,sa,sb,sd,n_in,n_out,in_off,out_off,in_count,out_count,cycle=0;
 integer coeff_checks=0,byte_checks=0,hash_checks=0,commands_done=0,protocol_checks=0;
 integer case_log,coeff_log,hash_log,seed_log,cycles_start,cycles_elapsed,active_dst;
 reg monitor=0;reg [3:0] active_cmd;reg [127:0] stage_seen[0:6];integer writes;
 reg held_check=0,byte_held_check=0;reg [7:0] held_byte;reg negative=0;
 reg [63:0] held_word;reg [7:0] held_keep;reg held_last;
 string filename,label;
 always @(posedge clk) begin
  cycle=cycle+1;
  if(!rst_n && (trace_we_a || trace_we_b || hash_out_valid || byte_out_valid)) $fatal(1,"activity during reset");
  if(rst_n && trace_we_a && trace_we_b && trace_addr_a==trace_addr_b) $fatal(1,"two writes to same address");
  if(monitor && (trace_we_a || trace_we_b)) begin
   if(trace_we_a && trace_addr_a[10:7]!=active_dst) $fatal(1,"wrong destination slot A");
   if(trace_we_b && trace_addr_b[10:7]!=active_dst) $fatal(1,"wrong destination slot B");
   if(trace_we_a && (trace_data_a[11:0]>=3329 || trace_data_a[23:12]>=3329)) $fatal(1,"noncanonical result");
   if(active_cmd<2) begin
    if(!trace_we_a || !trace_we_b) $fatal(1,"transform needs two writes");
    if(stage_seen[trace_stage][trace_addr_a[6:0]] || stage_seen[trace_stage][trace_addr_b[6:0]]) $fatal(1,"repeated stage write");
    stage_seen[trace_stage][trace_addr_a[6:0]]=1;stage_seen[trace_stage][trace_addr_b[6:0]]=1;
   end
   writes=writes+1;
  end
  if(held_check && rst_n && (hash_out_data!==held_word || hash_out_keep!==held_keep || hash_out_last!==held_last || !hash_out_valid))
   $fatal(1,"hash output changed under backpressure");
  held_check=hash_out_valid && !hash_out_ready;
  held_word=hash_out_data;held_keep=hash_out_keep;held_last=hash_out_last;
  if(byte_held_check && rst_n && (!byte_out_valid || byte_out!==held_byte)) $fatal(1,"byte output changed under backpressure");
  byte_held_check=byte_out_valid && !byte_out_ready;held_byte=byte_out;
 end
 task reset_dut;
  @(negedge clk);rst_n=0;start=0;host_we=0;host_re=0;byte_in_valid=0;byte_out_ready=0;hash_in_valid=0;hash_out_ready=0;monitor=0;
  repeat(3) @(negedge clk);rst_n=1;@(negedge clk);
  if(busy || slots_valid || seed_context_valid) $fatal(1,"reset state");
 endtask
 task launch(input integer operation,input integer slot_a,input integer slot_b,input integer slot_d);
  begin
   @(negedge clk);if(busy) $fatal(1,"launch while busy");
   cmd=operation;src_a_slot=slot_a;src_b_slot=slot_b;dst_slot=slot_d;start=1;cycles_start=cycle;
   @(negedge clk);start=0;
  end
 endtask
 task wait_done;
  integer timeout;
  begin
   timeout=0;
   while(!done) begin @(negedge clk);timeout=timeout+1;if(timeout>40000) $fatal(1,"command timeout cmd=%0d state=%0d",cmd,debug_state);end
   if(error || busy) $fatal(1,"unexpected command error %0d",error_code);
   cycles_elapsed=cycle-cycles_start;commands_done=commands_done+1;
   @(negedge clk);if(done) $fatal(1,"done must pulse");
  end
 endtask
 task load_slot(input integer slot,input integer source);
  integer w;
  begin
   for(w=0;w<128;w=w+1) begin
    @(negedge clk);if(!host_ready) $fatal(1,"loader unavailable");host_we=1;host_addr=slot*128+w;
    case(source) 0:host_wdata=a[w];1:host_wdata=b[w];2:host_wdata=c[w];3:host_wdata=chain_a[w];4:host_wdata=chain_b[w];endcase
   end
   @(negedge clk);host_we=0;if(!slots_valid[slot]) $fatal(1,"valid slot absent");
  end
 endtask
 task compare_slot(input integer slot);
  integer w;reg [23:0] wanted;
  begin
   for(w=0;w<128;w=w+1) begin
    @(negedge clk);host_re=1;host_addr=slot*128+w;
    @(posedge clk);#1;if(!host_rvalid) $fatal(1,"missing read valid");
    wanted=expected[w];if(negative && coeff_checks==0) wanted=wanted^24'd1;
    if(host_rdata!==wanted) $fatal(1,"TOP mismatch word=%0d got=%06x expected=%06x",w,host_rdata,wanted);
    $fwrite(coeff_log,"%s,%0d,%0d,%06x,%06x,PASS\n",label,slot,w,host_rdata,wanted);coeff_checks=coeff_checks+2;
   end
   @(negedge clk);host_re=0;
  end
 endtask
 task run_pau(input integer operation,input integer slot_a,input integer slot_b,input integer slot_d);
  begin
   active_dst=operation<2 ? slot_a : slot_d;active_cmd=operation;monitor=1;writes=0;
   for(k=0;k<7;k=k+1) stage_seen[k]=0;
   launch(operation,slot_a,slot_b,slot_d);
   // Disturb unlatched command inputs and attempt a busy host write.
   @(negedge clk);cmd=15;src_a_slot=15;src_b_slot=15;dst_slot=15;host_we=1;host_addr=15*128;host_wdata=0;start=1;
   @(negedge clk);host_we=0;start=0;
   wait_done();monitor=0;
   if(writes!=(operation<2 ? 448 : 128)) $fatal(1,"wrong write count %0d",writes);
   if(operation<2) for(k=0;k<7;k=k+1) if(stage_seen[k]!=={128{1'b1}}) $fatal(1,"incomplete transform stage");
   compare_slot(active_dst);
   $fwrite(case_log,"%s,%0d,%0d,%0d,%0d,%0d,PASS\n",label,operation,slot_a,slot_b,active_dst,cycles_elapsed);
  end
 endtask
 task drain_hash(input integer count,input integer offset,input integer poly);
  integer n,remaining,t;reg [63:0] wanted,mask;reg [7:0] keep;
  begin
   n=0;remaining=count;t=0;
   while(remaining>0) begin
    @(negedge clk);hash_out_ready=(t%11>=4);t=t+1;
    @(posedge clk);
    if(hash_out_valid && hash_out_ready) begin
     keep=remaining>=8 ? 8'hff : 8'hff>>(8-remaining);
     mask=remaining>=8 ? 64'hffffffffffffffff : (64'hffffffffffffffff>>(8*(8-remaining)));
     wanted=poly ? poly_expected[n] : hash_expected[offset+n];
     if((hash_out_data&mask)!==(wanted&mask) || hash_out_keep!==keep || hash_out_last!==(remaining<=8))
      $fatal(1,"HASH mismatch %s word=%0d got=%016x expected=%016x keep=%02x",label,n,hash_out_data,wanted,hash_out_keep);
     $fwrite(hash_log,"%s,%0d,%016x,%016x,%02x,PASS\n",label,n,hash_out_data,wanted,keep);
     hash_checks=hash_checks+1;n=n+1;remaining=remaining>=8 ? remaining-8 : 0;
    end
    if(t>10000) $fatal(1,"hash output timeout");
   end
   @(negedge clk);hash_out_ready=0;
   // done was raised on the last accepted output, so consume it here.
   wait_done();
  end
 endtask
 initial begin
  if($test$plusargs("WAVE")) begin $dumpfile("results/top_demo.vcd");$dumpvars(1,tb_mlkem_top);end
  negative=$test$plusargs("NEGATIVE_CHECKER");
  case_log=$fopen(negative ? "results/negative_cases.csv" : "results/integration_cases.csv","w");
  coeff_log=$fopen(negative ? "results/negative_coefficients.csv" : "results/coefficients.csv","w");
  hash_log=$fopen(negative ? "results/negative_hashes.csv" : "results/hashes.csv","w");seed_log=$fopen(negative ? "results/negative_seeds.txt" : "results/seeds.txt","w");
  $fwrite(case_log,"case,cmd,src_a,src_b,dst,cycles,status\n");$fwrite(coeff_log,"case,slot,word,actual,expected,status\n");
  $fwrite(hash_log,"case,word,actual,expected,keep,status\n");
  $readmemh("tb/vectors/commands.hex",commands);$readmemh("tb/vectors/decode_input.hex",decode_bytes);
  $readmemh("tb/vectors/encode_expected.hex",encode_bytes);$readmemh("tb/vectors/decode_expected.hex",decoded);
  $readmemh("tb/vectors/hash_input.hex",hash_inputs);$readmemh("tb/vectors/hash_expected.hex",hash_expected);$readmemh("tb/vectors/hash_cases.hex",hash_cases);
  $readmemh("tb/vectors/chain_a.hex",chain_a);$readmemh("tb/vectors/chain_b.hex",chain_b);$readmemh("tb/vectors/chain_expected.hex",chain_expected);
  $readmemh("tb/vectors/chain_encoded.hex",chain_bytes);
  reset_dut();
  // Uninitialized input, invalid command/length, and invalid raw host data.
  launch(0,0,1,2);if(!done || !error || error_code!=2) $fatal(1,"missing-bank rejection");protocol_checks=protocol_checks+1;
  @(negedge clk);launch(15,0,1,2);if(!done || !error || error_code!=1) $fatal(1,"invalid command");protocol_checks=protocol_checks+1;
  @(negedge clk);hash_output_bytes=0;launch(7,0,1,2);if(!done || !error || error_code!=1) $fatal(1,"invalid hash length");protocol_checks=protocol_checks+1;
  @(negedge clk);host_we=1;host_wdata=24'hffffff;
  @(posedge clk);#1;if(!error || error_code!=3 || slots_valid) $fatal(1,"invalid host coefficient");protocol_checks=protocol_checks+1;
  @(negedge clk);host_we=0;host_re=1;
  @(posedge clk);#1;if(!error || error_code!=4 || host_rvalid) $fatal(1,"unwritten read");protocol_checks=protocol_checks+1;
  @(negedge clk);host_re=0;
  // Protected slot 15 catches busy writes and destination mux mistakes.
  for(j=0;j<128;j=j+1) a[j]={12'd1234,12'd432};load_slot(15,0);
  for(i=0;i<`PAU_CASE_COUNT;i=i+1) begin
   filename=$sformatf("tb/vectors/case_%03d_a.hex",i);$readmemh(filename,a);
   filename=$sformatf("tb/vectors/case_%03d_b.hex",i);$readmemh(filename,b);
   filename=$sformatf("tb/vectors/case_%03d_c.hex",i);$readmemh(filename,c);
   filename=$sformatf("tb/vectors/case_%03d_expected.hex",i);$readmemh(filename,expected);
   sa=i%13;sb=(i+1)%13;sd=(i+2)%13;
   load_slot(sa,0);load_slot(sb,1);load_slot(sd,2);label=$sformatf("PAU_%03d",i);
   run_pau(commands[i],sa,sb,sd);
  end
  for(j=0;j<128;j=j+1) expected[j]={12'd1234,12'd432};label="protected_slot";compare_slot(15);protocol_checks=protocol_checks+1;
  // Decode: all 384 bytes, input gaps, coefficients including 3329 and 4095.
  label="Decode12";launch(6,0,1,14);in_count=0;
  while(in_count<384) begin
   @(negedge clk);byte_in_valid=(cycle%7!=0);byte_in=decode_bytes[in_count];
   @(posedge clk);if(byte_in_valid && byte_in_ready) in_count=in_count+1;
  end
  @(negedge clk);byte_in_valid=0;wait_done();for(j=0;j<128;j=j+1) expected[j]=decoded[j];compare_slot(14);
  // Encode: hold ready low repeatedly; output must include every third byte.
  label="Encode12";launch(5,14,1,2);out_count=0;
  while(out_count<384) begin
   @(negedge clk);byte_out_ready=(cycle%9>=3);
   @(posedge clk);if(byte_out_valid && byte_out_ready) begin
    if(byte_out!==encode_bytes[out_count]) $fatal(1,"byte encode mismatch n=%0d",out_count);
    byte_checks=byte_checks+1;out_count=out_count+1;
   end
  end
  @(negedge clk);byte_out_ready=0;wait_done();
  // In-place linear alias is valid: read pair before same-address writeback.
  for(j=0;j<128;j=j+1) begin a[j]=decoded[j];b[j]={12'd7,12'd11};
   expected[j]=(((decoded[j][23:12]+7)%3329)<<12)|((decoded[j][11:0]+11)%3329);end
  load_slot(0,0);load_slot(1,1);label="ADD_alias_srcA";run_pau(4,0,1,0);
  // Actual DUT chain: shared RAM never replaced by a software NTT intermediate.
  load_slot(0,3);load_slot(1,4);
  launch(0,0,1,2);wait_done();launch(0,1,0,2);wait_done();
  launch(2,0,1,2);wait_done();launch(1,2,0,2);wait_done();
  for(j=0;j<128;j=j+1) expected[j]=chain_expected[j];label="DUT_schoolbook_chain";compare_slot(2);
  label="DUT_chain_Encode12";launch(5,2,0,0);out_count=0;
  while(out_count<384) begin
   @(negedge clk);byte_out_ready=cycle%7>=2;
   @(posedge clk);if(byte_out_valid && byte_out_ready) begin
    if(byte_out!==chain_bytes[out_count]) $fatal(1,"chain encode mismatch");out_count=out_count+1;byte_checks=byte_checks+1;
   end
  end
  @(negedge clk);byte_out_ready=0;wait_done();
  // Independent SHA3/SHAKE vectors, host input pauses, partial final words,
  // invalid padding lanes, exact rate boundaries, and output backpressure.
  for(h=0;h<`HASH_CASES;h=h+1) begin
   hash_mode=hash_cases[h][1:0];n_in=hash_cases[h][23:8];n_out=hash_cases[h][39:24];
   in_off=hash_cases[h][63:40];out_off=hash_cases[h][95:64];hash_input_bytes=n_in;hash_output_bytes=n_out;
   label=$sformatf("HASH_%03d",h);launch(7,0,1,2);in_count=0;
   while(in_count<(n_in+7)/8) begin
    @(negedge clk);hash_in_valid=(cycle%5!=0);hash_in_data=hash_inputs[in_off+in_count];
    @(posedge clk);if(hash_in_valid && hash_in_ready) in_count=in_count+1;
   end
   @(negedge clk);hash_in_valid=0;drain_hash(n_out,out_off,0);
  end
  // Internal RAM -> corrected transcoder -> 64-bit packer -> SHA3/SHAKE.
  for(h=0;h<4;h=h+1) begin
   case(h) 0:begin filename="tb/vectors/poly_sha512.hex";n_out=64;end
    1:begin filename="tb/vectors/poly_shake128.hex";n_out=509;end
    2:begin filename="tb/vectors/poly_shake256.hex";n_out=413;end
    3:begin filename="tb/vectors/poly_sha256.hex";n_out=32;end endcase
   $readmemh(filename,poly_expected,0,(n_out+7)/8-1);
   hash_mode=h;hash_output_bytes=n_out;label=$sformatf("HASH_POLY_mode%0d",h);
   launch(8,14,0,0);drain_hash(n_out,0,1);
  end
  // Two seed sessions exercise TRNG core, debiaser, bridge and shared SHA3.
  for(h=0;h<2;h=h+1) begin
   label=$sformatf("TRNG_G_%0d",h);launch(9,0,0,0);out_count=0;
   while(out_count<8) begin
    @(negedge clk);hash_out_ready=cycle%7>=2;
    @(posedge clk);if(hash_out_valid && hash_out_ready) begin
     $fwrite(seed_log,"word %0d %0d %016x\n",h,out_count,hash_out_data);out_count=out_count+1;
    end
   end
   @(negedge clk);hash_out_ready=0;
   if(!seed_context_valid || {sigma,rho}!=={dut.hash_buffer[7],dut.hash_buffer[6],dut.hash_buffer[5],dut.hash_buffer[4],dut.hash_buffer[3],dut.hash_buffer[2],dut.hash_buffer[1],dut.hash_buffer[0]}) $fatal(1,"seed context");
   $fwrite(seed_log,"seed %0d %064x\n",h,seed_d);wait_done();
  end
  // Held start cannot retrigger, reset aborts TC/hash/PAU and invalidates RAM.
  @(negedge clk);cmd=4;src_a_slot=0;src_b_slot=1;dst_slot=3;start=1;
  @(negedge clk);wait_done();repeat(10) @(negedge clk);if(busy || done) $fatal(1,"held start retrigger");start=0;protocol_checks=protocol_checks+1;
  launch(6,0,1,4);repeat(5) @(negedge clk);reset_dut();protocol_checks=protocol_checks+1;
  hash_mode=3;hash_input_bytes=3;hash_output_bytes=32;launch(7,0,0,0);
  while(!hash_in_ready) @(negedge clk);hash_in_valid=1;hash_in_data=64'h636261;
  @(negedge clk);hash_in_valid=0;repeat(8) @(negedge clk);reset_dut();protocol_checks=protocol_checks+1;
  for(j=0;j<128;j=j+1) a[j]=decoded[j];load_slot(0,0);launch(0,0,1,2);
  repeat(20) @(negedge clk);reset_dut();protocol_checks=protocol_checks+1;
  // Recovery after reset must run a real command correctly.
  load_slot(14,0);for(j=0;j<128;j=j+1) expected[j]=decoded[j];
  launch(0,14,0,0);wait_done();launch(1,14,0,0);wait_done();label="reset_recovery_NTT_INTT";compare_slot(14);
  $fclose(case_log);$fclose(coeff_log);$fclose(hash_log);$fclose(seed_log);
  $display("PASS TOP: pau_vectors=%0d coefficients=%0d encoded_bytes=%0d hash_cases=%0d hash_words=%0d commands=%0d protocol_groups=%0d seed_sessions=2",`PAU_CASE_COUNT,coeff_checks,byte_checks,`HASH_CASES+4,hash_checks,commands_done,protocol_checks);
  test_pass=1;$finish;
 end
 initial begin #40000000;$fatal(1,"global watchdog");end
endmodule
