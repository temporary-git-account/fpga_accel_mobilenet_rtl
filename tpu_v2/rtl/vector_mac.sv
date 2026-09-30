// 32 independent signed products. The layer engine broadcasts activations
// for regular convolution and supplies independent lanes for depthwise.
module vector_mac (
 input logic clk,rst,valid,first,last,
 output wire ready,
 input logic [287:0] activations,
 input logic [63:0] weights,
 output logic out_valid,
 input logic out_ready,
 output wire [1023:0] results
);
 wire advance=!out_valid || out_ready;
 assign ready=advance;
 logic av,pv,af,al,pf,pl;
 logic signed [8:0] a[32];
 logic signed [7:0] w[8];
 (* use_dsp="yes" *) logic signed [16:0] product[32];
 logic signed [31:0] sum[32];
 always_ff @(posedge clk) begin
  if(rst)begin
   av<=0;pv<=0;out_valid<=0;af<=0;al<=0;pf<=0;pl<=0;
   for(integer i=0;i<32;i=i+1)begin a[i]<=0;product[i]<=0;sum[i]<=0;end
   for(integer i=0;i<8;i=i+1)w[i]<=0;
  end
  else if(advance)begin
   av<=valid;af<=first;al<=last;pv<=av;pf<=af;pl<=al;out_valid<=pv&&pl;
   if(valid)begin
    for(integer i=0;i<32;i=i+1)a[i]<=$signed(activations[i*9+:9]);
    for(integer i=0;i<8;i=i+1)w[i]<=$signed(weights[i*8+:8]);
   end
   if(av)for(integer i=0;i<32;i=i+1)product[i]<=a[i]*w[i%8];
   if(pv)for(integer i=0;i<32;i=i+1)sum[i]<=pf ? $signed(product[i]) : sum[i]+product[i];
  end
 end
 for(genvar i=0;i<32;i=i+1)assign results[i*32+:32]=sum[i];
endmodule
