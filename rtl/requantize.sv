// One-result/cycle, eight-stage integer bias/requantization pipeline.
// TFLite double rounding: positive Q31 multiplier, right_shift 0..31.
// No left shifts. Illegal multiplier, activation interval, or int32 bias
// addition overflow produces out_error=1, result=0. Global stall preserves
// every transaction and metadata; synchronous reset aborts all pending work.
module requantize (
    input logic clk, rst,
    input logic in_valid,
    output wire in_ready,
    input logic signed [31:0] accumulator, bias,
    input logic [31:0] multiplier,
    input logic [4:0] right_shift,
    input logic signed [7:0] output_zero, activation_min, activation_max,
    output wire out_valid,
    input logic out_ready,
    output logic signed [7:0] result,
    output wire out_error
);
    logic [7:0] valid, fault;
    wire advance = !valid[7] || out_ready;
    assign in_ready = advance;
    assign out_valid = valid[7];
    assign out_error = fault[7];
    wire signed [32:0] biased = {accumulator[31], accumulator} + {bias[31], bias};
    logic signed [31:0] value0, multiplier0;
    // Four DSP-sized products, then two registered additions. A monolithic
    // 32x32 multiply inferred a long unregistered DSP cascade on this part.
    (* use_dsp="yes" *) logic [31:0] ll1;
    (* use_dsp="yes" *) logic signed [31:0] hl1, lh1, hh1;
    // Keep shifted partial-product additions in fabric. Vivado 2025.1
    // incorrectly folds these into unshifted DSP PCIN cascades otherwise;
    // post-synthesis simulation must pass the same integer golden vectors.
    (* use_dsp="no" *) logic signed [47:0] left2, right2;
    logic signed [63:0] product3;
    logic signed [31:0] high4, base5;
    logic round5;
    logic signed [33:0] offset6;
    logic [4:0] shift_pipe [0:4];
    logic signed [7:0] zero_pipe [0:5], low_pipe [0:6], high_pipe [0:6];
    // Decode masks ahead of the high-multiply result. Guard/sticky logic
    // avoids a subtract -> add -> compare carry chain in the rounding stage.
    logic [30:0] guard_pipe [0:4], sticky_pipe [0:4];
    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= 0;
            fault <= 0;
            result <= 0;
        end else if (advance) begin
            valid <= {valid[6:0], in_valid};
            fault <= {fault[6:0], (biased[32] != biased[31]) || multiplier[31] ||
                      (multiplier == 0) || (activation_min > activation_max)};
            value0 <= biased[31:0];
            multiplier0 <= $signed(multiplier);
            ll1 <= $signed({1'b0,value0[15:0]}) * $signed({1'b0,multiplier0[15:0]});
            hl1 <= $signed(value0[31:16]) * $signed({1'b0,multiplier0[15:0]});
            lh1 <= $signed({1'b0,value0[15:0]}) * $signed({1'b0,multiplier0[30:16]});
            hh1 <= $signed(value0[31:16]) * $signed({1'b0,multiplier0[30:16]});
            left2 <= $signed({16'b0,ll1}) + $signed({hl1,16'b0});
            right2 <= {{16{lh1[31]}},lh1} + $signed({hh1,16'b0});
            product3 <= {{16{left2[47]}},left2} + $signed({right2,16'b0});
            // High multiply rounds negative ties toward +infinity.
            high4 <= $signed(product3[62:31]) + $signed({31'b0, product3[30]});
            base5 <= high4 >>> shift_pipe[4];
            // Subsequent power-of-two divide rounds ties away from zero.
            round5 <= (|(high4[30:0] & guard_pipe[4])) &&
                      (!high4[31] || (|(high4[30:0] & sticky_pipe[4])));
            offset6 <= {{2{base5[31]}}, base5} + $signed({33'b0, round5}) +
                       {{26{zero_pipe[5][7]}}, zero_pipe[5]};
            if (fault[6]) result <= 0;
            else if (offset6 < $signed(low_pipe[6])) result <= low_pipe[6];
            else if (offset6 > $signed(high_pipe[6])) result <= high_pipe[6];
            else result <= offset6[7:0];
            shift_pipe[0] <= right_shift;
            for (integer bit_index=0; bit_index<31; bit_index=bit_index+1) begin
                guard_pipe[0][bit_index] <= right_shift == bit_index+1;
                sticky_pipe[0][bit_index] <= right_shift > bit_index+1;
            end
            for (integer stage=1; stage<5; stage=stage+1) begin
                guard_pipe[stage] <= guard_pipe[stage-1];
                sticky_pipe[stage] <= sticky_pipe[stage-1];
            end
            zero_pipe[0] <= output_zero;
            low_pipe[0] <= activation_min;
            high_pipe[0] <= activation_max;
            for (integer i=1; i<5; i=i+1) shift_pipe[i] <= shift_pipe[i-1];
            for (integer i=1; i<6; i=i+1) zero_pipe[i] <= zero_pipe[i-1];
            for (integer i=1; i<7; i=i+1) begin
                low_pipe[i] <= low_pipe[i-1];
                high_pipe[i] <= high_pipe[i-1];
            end
        end
    end
endmodule
