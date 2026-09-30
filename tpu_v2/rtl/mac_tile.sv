// Reusable outer-product tile. Each accepted input contributes one reduction
// term to PIXELS x CHANNELS dot products. Activations are already zero-point
// corrected signed 9-bit values; weights are signed 8-bit. first/last delimit
// a vector. Input gaps and output backpressure are permitted. rst aborts all
// work. Bias, per-channel requantization and memory/control are separate blocks.
module mac_tile #(parameter integer PIXELS=4, CHANNELS=8)(
    input logic clk, rst,
    input logic in_valid, in_first, in_last,
    output logic in_ready,
    input logic [PIXELS*9-1:0] activations,
    input logic [CHANNELS*8-1:0] weights,
    output logic out_valid,
    input logic out_ready,
    output wire [PIXELS*CHANNELS*32-1:0] results
);
    wire advance = !out_valid || out_ready;
    assign in_ready=advance;
    logic av,pv,af,al,pf,pl;
    logic signed [8:0] a[PIXELS];
    logic signed [7:0] b[CHANNELS];
    (* use_dsp="yes" *) logic signed [16:0] product[PIXELS][CHANNELS];
    logic signed [31:0] sum[PIXELS][CHANNELS];
    always_ff @(posedge clk) begin
        if(rst)begin
            av<=0;pv<=0;out_valid<=0;af<=0;al<=0;pf<=0;pl<=0;
            for(integer i=0;i<PIXELS;i=i+1)a[i]<=0;
            for(integer j=0;j<CHANNELS;j=j+1)b[j]<=0;
            for(integer i=0;i<PIXELS;i=i+1)for(integer j=0;j<CHANNELS;j=j+1)begin
                product[i][j]<=0;sum[i][j]<=0;
            end
        end else if(advance)begin
            av<=in_valid;af<=in_first;al<=in_last;
            pv<=av;pf<=af;pl<=al;
            out_valid<=pv && pl;
            if(in_valid)begin
                for(integer i=0;i<PIXELS;i=i+1)a[i]<=$signed(activations[i*9+:9]);
                for(integer j=0;j<CHANNELS;j=j+1)b[j]<=$signed(weights[j*8+:8]);
            end
            if(av)for(integer i=0;i<PIXELS;i=i+1)for(integer j=0;j<CHANNELS;j=j+1)
                product[i][j]<=a[i]*b[j];
            if(pv)for(integer i=0;i<PIXELS;i=i+1)for(integer j=0;j<CHANNELS;j=j+1)
                sum[i][j]<=pf ? $signed(product[i][j]) : sum[i][j]+product[i][j];
        end
    end
    generate for(genvar i=0;i<PIXELS;i=i+1)begin:gp
        for(genvar j=0;j<CHANNELS;j=j+1)begin:gc
            assign results[(i*CHANNELS+j)*32+:32]=sum[i][j];
        end
    end endgenerate
endmodule
