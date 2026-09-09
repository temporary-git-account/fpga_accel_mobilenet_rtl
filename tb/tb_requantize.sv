`timescale 1ns/1ps
module tb_requantize;
    `include "../../golden/quant_cases.svh"
    logic clk=0, rst=1;
    always #5 clk=~clk;
    logic in_valid=0, out_ready=0;
    wire in_ready, out_valid, out_error;
    logic signed [31:0] accumulator, bias;
    logic [31:0] multiplier;
    logic [4:0] right_shift;
    logic signed [7:0] output_zero, activation_min, activation_max;
    wire signed [7:0] result;
    requantize dut(.*);
    logic [287:0] cases[0:QUANT_CASES-1];
    integer queue[0:QUANT_CASES-1];
    integer sent=0, received=0, cycles=0, goal=0, drive_id=0;
    logic running=0, block_output=0, held=0;
    logic [8:0] held_value;
    logic [31:0] random_state=32'h582194;
    always @(negedge clk) begin
        random_state = (random_state * 1664525) + 1013904223;
        if(rst) begin in_valid=0;out_ready=0;end
        else begin
            out_ready = !block_output && ((random_state[7:4] != 0) && (cycles % 101 < 80));
            if (!(in_valid && !in_ready)) begin
                in_valid = running && sent < goal && random_state[11:10] != 0;
                if(in_valid) begin
                    drive_id=sent;
                    accumulator=cases[sent][287:256];
                    bias=cases[sent][255:224];
                    multiplier=cases[sent][223:192];
                    right_shift=cases[sent][164:160];
                    output_zero=cases[sent][135:128];
                    activation_min=cases[sent][103:96];
                    activation_max=cases[sent][71:64];
                end
            end
        end
    end
    always @(posedge clk) begin
        if(rst) begin sent=0;received=0;cycles=0;held=0;end
        else begin
            cycles=cycles+1;
            if(held && (!out_valid || {out_error,result} !== held_value))
                $fatal(1,"output changed while stalled");
            held=out_valid && !out_ready;
            held_value={out_error,result};
            if(out_valid && out_ready) begin
                if(received>=sent) $fatal(1,"unexpected or post-reset output");
                if(result !== cases[queue[received]][39:32] || out_error !== cases[queue[received]][0])
                    $fatal(1,"case %0d got %0d error %0d expected %0d error %0d",queue[received],result,
                           out_error,$signed(cases[queue[received]][39:32]),cases[queue[received]][0]);
                received=received+1;
            end
            if(in_valid && in_ready) begin queue[sent]=drive_id;sent=sent+1;end
        end
    end
    initial begin
        $readmemh("../../golden/quant_cases.hex",cases);
        repeat(4) @(posedge clk);
        #1;rst=0;running=1;goal=32;block_output=1;
        repeat(40) @(posedge clk);
        #1;
        if(sent==0 || received!=0 || !out_valid) $fatal(1,"reset test did not fill blocked pipeline");
        rst=1;running=0;
        repeat(3) @(posedge clk);
        #1;rst=0;block_output=0;
        repeat(12) @(posedge clk);
        #1;running=1;goal=QUANT_CASES;
        wait(received==QUANT_CASES);
        @(negedge clk);running=0;
        repeat(15) @(posedge clk);
        $display("REQUANTIZE_PASS cases=%0d cycles=%0d (stalls, gaps, errors, reset)",received,cycles);
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
