`timescale 1ns/1ps
// Real model operands traverse the actual MAC tile, then a serial quantizer.
// Expected bytes are from TFLite BUILTIN_REF, not an SV arithmetic formula.
module tb_mac_quant;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    logic in_valid=0,in_first=0,in_last=0;
    wire in_ready, mac_valid;
    wire [1023:0] results;
    logic [35:0] activations;
    logic [63:0] weights;
    wire mac_ready;
    mac_tile mac(.clk(clk),.rst(rst),.in_valid(in_valid),.in_first(in_first),.in_last(in_last),
        .in_ready(in_ready),.activations(activations),.weights(weights),
        .out_valid(mac_valid),.out_ready(mac_ready),.results(results));
    logic [35:0] av[0:31];
    logic [63:0] wv[0:31];
    logic [287:0] qv[0:31];
    integer lane=0, received=0, cycles=0;
    wire q_ready,q_valid,q_error;
    wire signed [7:0] q_result;
    logic out_ready=0;
    assign mac_ready = q_ready && lane==31;
    requantize q(.clk(clk),.rst(rst),.in_valid(mac_valid),.in_ready(q_ready),
        .accumulator(results[lane*32+:32]),.bias(qv[lane][255:224]),.multiplier(qv[lane][223:192]),
        .right_shift(qv[lane][164:160]),.output_zero(qv[lane][135:128]),
        .activation_min(qv[lane][103:96]),.activation_max(qv[lane][71:64]),
        .out_valid(q_valid),.out_ready(out_ready),.result(q_result),.out_error(q_error));
    always @(negedge clk) out_ready = !rst && cycles%29 < 17;
    always @(posedge clk) begin
        if(rst)begin lane<=0;received<=0;cycles<=0;end
        else begin
            cycles<=cycles+1;
            if(mac_valid && q_ready)begin
                if(results[lane*32+:32] !== qv[lane][287:256]) $fatal(1,"raw MAC lane %0d mismatch",lane);
                lane<=lane==31 ? 0 : lane+1;
            end
            if(q_valid && out_ready)begin
                if(q_error || q_result !== qv[received%32][39:32])
                    $fatal(1,"quantized lane %0d got %0d expected %0d",received,q_result,$signed(qv[received%32][39:32]));
                received<=received+1;
            end
        end
    end
    initial begin
        $readmemh("../../golden/mac_activations.hex",av);
        $readmemh("../../golden/mac_weights.hex",wv);
        $readmemh("../../golden/pointwise_quant.hex",qv);
        repeat(4) @(posedge clk);
        @(negedge clk);rst=0;
        // Three complete tiles, including waiting for the serialized output.
        for(integer job=0;job<3;job=job+1)begin
            for(integer k=0;k<32;k=k+1)begin
                @(negedge clk);
                in_valid=1;in_first=k==0;in_last=k==31;activations=av[k];weights=wv[k];
                @(posedge clk);
                while(!in_ready) @(posedge clk);
            end
            @(negedge clk);in_valid=0;
            wait(received==(job+1)*32);
        end
        repeat(12) @(posedge clk);
        if(received!=96) $fatal(1,"extra result");
        $display("MAC_QUANT_PASS 3 real model tiles, 96 exact TFLite output bytes");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
