// One complete NHWC int8 convolution/depthwise job. Four pixels x eight
// channels share the arithmetic. Weights are retained across all spatial tiles
// in a channel group. Memory requests are aligned 32-bit words, one outstanding.
// Parameters: 16 bytes/channel: int32 bias, Q31 multiplier, uint32 right shift,
// reserved. Region bounds are enforced for every memory transaction.
module layer_engine (
 input logic clk,rst,
 input logic cmd_valid, output wire cmd_ready,
 input logic [31:0] cmd_id, input_base, weights_base, params_base, output_base,
 input logic [31:0] region_base,region_limit,
 input logic [15:0] input_h,input_w,input_c,output_h,output_w,output_c,
 input logic [1:0] kernel,stride,pad_top,pad_left,
 input logic depthwise,
 input logic signed [7:0] input_zero,output_zero,activation_min,activation_max,
 input logic cancel,
 output wire busy, output wire done_valid,input logic done_ready,
 output logic [31:0] done_id,output logic [3:0] status,
 output logic [31:0] cycles, reads, writes,
 output wire mem_valid,input logic mem_ready,
 output wire [31:0] mem_addr,mem_wdata,output wire [3:0] mem_wstrb,
 input logic rsp_valid,output wire rsp_ready,input logic [31:0] rsp_data,input logic rsp_error
);
 // Explicit one-hot state bits keep bank enables and DSP enables shallow.
 localparam integer IDLE=0,CHECK=1,W_ADDR=2,W_NEXT=3,P_ADDR=4,P_NEXT=5,PIX_INIT=6,PIX_NEXT=7,A_SELECT=8,A_COORD=9,A_MUL=10,A_OFF1=11,A_OFF2=12,A_ADDR=13,A_NEXT=14,RUN_READ=15,RUN_FEED=16,SUM_WAIT=17,Q_SEND=18,Q_WAIT=19,O_ADDR=20,O_NEXT=21,NEXT_TILE=22,MULTIPLY=23,OFFSET=24,ADDRESS=25,CHECK_REQ=26,MREQ=27,MWAIT=28,FINISH=29;
 (* fsm_encoding="none" *) logic [29:0] state;
 localparam logic [2:0] KIND_W=0,KIND_P=1,KIND_A=2,KIND_O=3;
 logic [2:0] mem_kind;
 logic [31:0] ib,wb,pb,ob,rb,rl,last_region_word;
 logic [15:0] ih,iw,ic,oh,ow,oc;
 logic [1:0] kh,st,pt,pl;
 logic dw,aborting;
 logic signed [7:0] iz,oz,amin,amax;
 logic [31:0] row_bytes,total_pixels,weight_terms;
 logic [16:0] pixel_base;
 logic [10:0] channel_base;
 logic signed [10:0] tile_x[4],tile_y[4],selected_x,selected_y;
 logic [8:0] next_x,next_y;
 logic [2:0] pix,chan;
 logic [10:0] term,terms,run_term,last_term,last_input_channel;
 logic [8:0] last_column;
 logic [15:0] reduction_c;
 logic [1:0] reduction_x,reduction_y,param_word;
 logic signed [10:0] source_x,source_y;
 logic [31:0] row_offset,column_offset;
 logic [31:0] input_offset,offset,addend,address_base;
 logic [19:0] mul_a;
 logic [16:0] mul_b;
 (* use_dsp="yes" *) logic [36:0] mul_product;
 logic source_inside;
 logic [32:0] request_address;
 logic [31:0] request_data;
 logic [3:0] request_strobe;
 logic [31:0] biases[8],multipliers[8];
 logic [4:0] shifts[8];
 logic [5:0] q_send,q_received,store_lane;
 logic [7:0] tile_output[32];
 logic quant_buffer_valid;
 logic signed [31:0] quant_accumulator,quant_bias;
 logic [31:0] quant_multiplier;
 logic [4:0] quant_shift;
 wire quant_buffer_ready=!quant_buffer_valid||quant_ready;
 wire core_reset=rst || state[IDLE] || state[FINISH];
 assign busy=!state[IDLE] && !state[FINISH];
 assign cmd_ready=state[IDLE];
 assign done_valid=state[FINISH];
 wire address_legal=!request_address[32]&&request_address[31:0]>=rb&&{request_address[31:2],2'b0}<=last_region_word;
 assign mem_valid=state[MREQ];
 assign mem_addr={request_address[31:2],2'b0};
 assign mem_wdata=request_data << (request_address[1:0]*8);
 assign mem_wstrb=request_strobe << request_address[1:0];
 assign rsp_ready=state[MWAIT];
 wire memory_accept=state[MWAIT] && rsp_valid && !rsp_error;
 wire [7:0] loaded_byte=rsp_data >> (request_address[1:0]*8);
 wire signed [8:0] corrected=$signed({loaded_byte[7],loaded_byte})-$signed({iz[7],iz});
 wire a_padding=state[A_ADDR] && !source_inside;
 wire a_write=(memory_accept && mem_kind==KIND_A)||a_padding;
 wire signed [8:0] a_data=a_padding ? 9'sd0 : corrected;
 // Tile bases are multiples of eight channels / four pixels. Concatenate
 // the lane bits instead of building a carry chain on every address/enable.
 wire [10:0] active_channel={channel_base[10:3],chan};
 wire [16:0] active_pixel={pixel_base[16:2],pix[1:0]};
 wire [10:0] output_channel={channel_base[10:3],store_lane[2:0]};
 wire [16:0] output_pixel={pixel_base[16:2],store_lane[4:3]};
 wire w_padding=state[W_ADDR]&&active_channel>=oc;
 wire w_write=(memory_accept && mem_kind==KIND_W)||w_padding;
 // Register incoming bank writes, including their lane/address tags. This
 // separates response byte selection/zero-point correction from RAM fanout.
 logic a_write_q,w_write_q,a_dw_q;
 logic signed [8:0] a_data_q;
 logic [7:0] w_data_q;
 logic [9:0] a_term_q,w_term_q;
 logic [1:0] a_pix_q;
 logic [2:0] a_chan_q,w_chan_q;
 always_ff @(posedge clk)begin
  if(rst)begin a_write_q<=0;w_write_q<=0;end
  else begin
   a_write_q<=a_write;w_write_q<=w_write;
   if(a_write)begin a_data_q<=a_data;a_dw_q<=dw;a_term_q<=term[9:0];a_pix_q<=pix[1:0];a_chan_q<=chan;end
   if(w_write)begin w_data_q<=w_padding ? 8'b0 : loaded_byte;w_term_q<=term[9:0];w_chan_q<=chan;end
  end
 end
 wire [35:0] shared_a;
 wire [287:0] depth_a;
 wire [63:0] packed_w;
 // Banked true synchronous memories, no reset of data arrays.
 for(genvar p=0;p<4;p=p+1)begin:abank
  (* ram_style="block" *) logic signed [8:0] ram[1024];
  logic signed [8:0] q;
  always_ff @(posedge clk)begin
   if(a_write_q&&!a_dw_q&&a_pix_q==p)ram[a_term_q]<=a_data_q;
   q<=ram[run_term[9:0]];
  end
  assign shared_a[p*9+:9]=q;
  for(genvar c=0;c<8;c=c+1)begin:d_bank
   (* ram_style="distributed" *) logic signed [8:0] ram[16];
   logic signed [8:0] q;
   always_ff @(posedge clk)begin
    if(a_write_q&&a_dw_q&&a_pix_q==p&&a_chan_q==c)ram[a_term_q[3:0]]<=a_data_q;
    q<=ram[run_term[3:0]];
   end
   assign depth_a[(p*8+c)*9+:9]=q;
  end
 end
 for(genvar c=0;c<8;c=c+1)begin:wbank
  (* ram_style="block" *) logic [7:0] ram[1024];
  logic [7:0] q;
  always_ff @(posedge clk)begin
   if(w_write_q&&w_chan_q==c)ram[w_term_q]<=w_data_q;
   q<=ram[run_term[9:0]];
  end
  assign packed_w[c*8+:8]=q;
 end
 wire [287:0] packed_a;
 for(genvar p=0;p<4;p=p+1)for(genvar c=0;c<8;c=c+1)
  assign packed_a[(p*8+c)*9+:9]=dw ? depth_a[(p*8+c)*9+:9] : shared_a[p*9+:9];
 wire mac_ready,mac_valid;
 wire [1023:0] raw_sums;
 wire quant_ready,quant_valid,quant_error;
 wire signed [7:0] quant_result;
 vector_mac mac(.clk(clk),.rst(core_reset),.valid(state[RUN_FEED]),.ready(mac_ready),
  .first(run_term==0),.last(run_term==last_term),.activations(packed_a),.weights(packed_w),
  .out_valid(mac_valid),.out_ready(state[Q_SEND]&&q_send==31&&quant_buffer_ready),.results(raw_sums));
 requantize quant(.clk(clk),.rst(core_reset),.in_valid(quant_buffer_valid),.in_ready(quant_ready),
  .accumulator(quant_accumulator),.bias(quant_bias),
  .multiplier(quant_multiplier),.right_shift(quant_shift),
  .output_zero(oz),.activation_min(amin),.activation_max(amax),
  .out_valid(quant_valid),.out_ready(1'b1),.result(quant_result),.out_error(quant_error));
 always_ff @(posedge clk)begin
  if(core_reset)quant_buffer_valid<=0;
  else if(quant_buffer_ready)begin
   quant_buffer_valid<=state[Q_SEND];
   if(state[Q_SEND])begin
    quant_accumulator<=raw_sums[q_send[4:0]*32+:32];quant_bias<=biases[q_send[2:0]];
    quant_multiplier<=multipliers[q_send[2:0]];quant_shift<=shifts[q_send[2:0]];
   end
  end
 end
 // Pixel coordinates are advanced with counters, avoiding hardware division.
 // All address intermediates have a dedicated pipeline stage.
 always_ff @(posedge clk)begin
  if(rst)begin state<=30'b1<<IDLE;status<=0;aborting<=0;cycles<=0;reads<=0;writes<=0;done_id<=0;end
  else begin
   if(busy)cycles<=cycles+1;
   if(busy&&cancel)aborting<=1;
   if(quant_valid&&(state[Q_SEND]||state[Q_WAIT]))begin
    tile_output[q_received[4:0]]<=quant_result;
    q_received<=q_received+1;
   end
   case(1'b1)
    state[IDLE]:if(cmd_valid)begin
     ib<=input_base;wb<=weights_base;pb<=params_base;ob<=output_base;rb<=region_base;rl<=region_limit;last_region_word<=region_limit-32'd4;
     ih<=input_h;iw<=input_w;ic<=input_c;oh<=output_h;ow<=output_w;oc<=output_c;
     kh<=kernel;st<=stride;pt<=pad_top;pl<=pad_left;dw<=depthwise;
     iz<=input_zero;oz<=output_zero;amin<=activation_min;amax<=activation_max;
     done_id<=cmd_id;status<=0;aborting<=0;cycles<=0;reads<=0;writes<=0;
     row_bytes<=input_w*input_c;total_pixels<=output_h*output_w;
     weight_terms<=depthwise ? kernel*kernel : kernel*kernel*input_c;
     state<=30'b1<<CHECK;
    end
    state[CHECK]:begin
     terms<=weight_terms[10:0];last_term<=weight_terms[10:0]-11'd1;last_input_channel<=ic[10:0]-11'd1;last_column<=ow[8:0]-9'd1;channel_base<=0;chan<=0;term<=0;
     // Bounded dimensions also keep all address products in 32 bits. Every
     // request is separately checked against the authorized DDR arena.
     if(ih==0||iw==0||ic==0||oh==0||ow==0||oc==0||ih>256||iw>256||oh>256||ow>256||
        ic>1024||oc>1024||(kh!=1&&kh!=3)||(st!=1&&st!=2)||
        weight_terms==0||weight_terms>1024||(dw&&ic!=oc)||amin>amax||
        rb>=rl||rb[3:0]!=0||rl[3:0]!=0||pb[3:0]!=0)begin status<=1;state<=30'b1<<FINISH;end
     else state<=30'b1<<W_ADDR;
    end
    state[W_ADDR]:begin
     mul_a<=dw ? term : active_channel;mul_b<=dw ? oc : terms;
     addend<=dw ? active_channel : term;address_base<=wb;
     request_strobe<=0;mem_kind<=KIND_W;
     if(active_channel>=oc)state<=30'b1<<W_NEXT;
     else state<=30'b1<<MULTIPLY;
    end
    state[W_NEXT]:begin
     if(term==last_term)begin
      term<=0;
      if(chan==7)begin chan<=0;param_word<=0;state<=30'b1<<P_ADDR;end
      else begin chan<=chan+1;state<=30'b1<<W_ADDR;end
     end else begin term<=term+1;state<=30'b1<<W_ADDR;end
    end
    state[P_ADDR]:begin
     mul_a<=active_channel;mul_b<=16;addend<={28'b0,param_word,2'b0};address_base<=pb;
     request_strobe<=0;mem_kind<=KIND_P;
     if(active_channel>=oc)begin biases[chan]<=0;multipliers[chan]<=32'h40000000;shifts[chan]<=0;param_word<=2;state<=30'b1<<P_NEXT;end
     else state<=30'b1<<MULTIPLY;
    end
    state[P_NEXT]:begin
     if(param_word==2)begin
      param_word<=0;
      if(chan==7)begin pixel_base<=0;next_x<=0;next_y<=0;pix<=0;state<=30'b1<<PIX_INIT;end
      else begin chan<=chan+1;state<=30'b1<<P_ADDR;end
     end else begin param_word<=param_word+1;state<=30'b1<<P_ADDR;end
    end
    state[PIX_INIT]:begin
     tile_x[pix[1:0]]<=($signed({2'b0,next_x}) << (st==2))-$signed({9'b0,pl});
     tile_y[pix[1:0]]<=($signed({2'b0,next_y}) << (st==2))-$signed({9'b0,pt});
     if(next_x==last_column)begin next_x<=0;next_y<=next_y+1;end else next_x<=next_x+1;
     state<=30'b1<<PIX_NEXT;
    end
    state[PIX_NEXT]:if(pix==3)begin pix<=0;chan<=0;term<=0;reduction_c<=0;reduction_x<=0;reduction_y<=0;state<=30'b1<<A_SELECT;end
     else begin pix<=pix+1;state<=30'b1<<PIX_INIT;end
    state[A_SELECT]:begin selected_x<=tile_x[pix[1:0]];selected_y<=tile_y[pix[1:0]];state<=30'b1<<A_COORD;end
    state[A_COORD]:begin
     source_x<=selected_x+$signed({9'b0,reduction_x});
     source_y<=selected_y+$signed({9'b0,reduction_y});state<=30'b1<<A_MUL;
    end
    state[A_MUL]:begin
     source_inside<=source_x>=0&&source_y>=0&&source_x<$signed({1'b0,iw})&&source_y<$signed({1'b0,ih})&&
                    active_pixel<total_pixels&&(!dw||active_channel<oc);
     row_offset<=source_y[7:0]*row_bytes[18:0];column_offset<=source_x[7:0]*ic[10:0];
     state<=30'b1<<A_OFF1;
    end
    state[A_OFF1]:begin input_offset<=row_offset+column_offset;state<=30'b1<<A_OFF2;end
    state[A_OFF2]:begin input_offset<=input_offset+(dw ? active_channel : reduction_c);state<=30'b1<<A_ADDR;end
    state[A_ADDR]:if(!source_inside)state<=30'b1<<A_NEXT;
     else begin request_address<={1'b0,ib}+input_offset;
      request_strobe<=0;mem_kind<=KIND_A;state<=30'b1<<CHECK_REQ;end
    state[A_NEXT]:begin
     if(term==last_term)begin
      term<=0;reduction_c<=0;reduction_x<=0;reduction_y<=0;
      if(dw&&chan!=7)begin chan<=chan+1;state<=30'b1<<A_SELECT;end
      else if(pix!=3)begin chan<=0;pix<=pix+1;state<=30'b1<<A_SELECT;end
      else begin run_term<=0;state<=30'b1<<RUN_READ;end
     end else begin
      term<=term+1;
      if(dw||reduction_c==last_input_channel)begin
       reduction_c<=0;
       if(reduction_x==kh-1)begin reduction_x<=0;reduction_y<=reduction_y+1;end
       else reduction_x<=reduction_x+1;
      end else reduction_c<=reduction_c+1;
      state<=30'b1<<A_SELECT;
     end
    end
    state[RUN_READ]:state<=30'b1<<RUN_FEED;
    state[RUN_FEED]:if(mac_ready)begin
     if(run_term==last_term)state<=30'b1<<SUM_WAIT;
     else begin run_term<=run_term+1;state<=30'b1<<RUN_READ;end
    end
    state[SUM_WAIT]:if(mac_valid)begin q_send<=0;q_received<=0;state<=30'b1<<Q_SEND;end
    state[Q_SEND]:if(quant_buffer_ready)begin if(q_send==31)state<=30'b1<<Q_WAIT;else q_send<=q_send+1;end
    state[Q_WAIT]:if(q_received==32)begin store_lane<=0;state<=30'b1<<O_ADDR;end
    state[O_ADDR]:begin
     mul_a<=output_pixel;mul_b<=oc;addend<=output_channel;address_base<=ob;
     request_data<={24'b0,tile_output[store_lane[4:0]]};request_strobe<=1;mem_kind<=KIND_O;
     if(output_pixel>=total_pixels||output_channel>=oc)state<=30'b1<<O_NEXT;
     else state<=30'b1<<MULTIPLY;
    end
    state[O_NEXT]:if(store_lane==31)state<=30'b1<<NEXT_TILE;else begin store_lane<=store_lane+1;state<=30'b1<<O_ADDR;end
    state[NEXT_TILE]:if(pixel_base+4<total_pixels)begin pixel_base<=pixel_base+4;pix<=0;state<=30'b1<<PIX_INIT;end
     else if(channel_base+8<oc)begin channel_base<=channel_base+8;chan<=0;term<=0;state<=30'b1<<W_ADDR;end
     else state<=30'b1<<FINISH;
    state[MULTIPLY]:begin mul_product<=mul_a*mul_b;state<=30'b1<<OFFSET;end
    state[OFFSET]:begin
     offset<=mul_product[31:0]+addend;
     if(mul_product[36:32]!=0)begin status<=1;state<=30'b1<<FINISH;end
     else state<=30'b1<<ADDRESS;
    end
    state[ADDRESS]:begin request_address<={1'b0,address_base}+offset;state<=30'b1<<CHECK_REQ;end
    state[CHECK_REQ]:if(!address_legal)begin status<=1;state<=30'b1<<FINISH;end else state<=30'b1<<MREQ;
    state[MREQ]:begin
     if(mem_ready)begin
      if(request_strobe==0)reads<=reads+1;else writes<=writes+1;
      state<=30'b1<<MWAIT;
     end
    end
    state[MWAIT]:if(rsp_valid)begin
     if(rsp_error)begin status<=2;state<=30'b1<<FINISH;end
     else begin
      if(mem_kind==KIND_P)begin
       case(param_word)
        0:biases[chan]<=rsp_data;
        1:multipliers[chan]<=rsp_data;
        2:shifts[chan]<=rsp_data[4:0];
        default:;
       endcase
       if((param_word==1&&(rsp_data==0||rsp_data[31]))||(param_word==2&&rsp_data>31))begin status<=1;state<=30'b1<<FINISH;end
       else state<=30'b1<<P_NEXT;
      end else case(mem_kind)
       KIND_W:state<=30'b1<<W_NEXT;
       KIND_A:state<=30'b1<<A_NEXT;
       KIND_O:state<=30'b1<<O_NEXT;
       default:begin status<=1;state<=30'b1<<FINISH;end
      endcase
     end
    end
    state[FINISH]:if(done_ready)state<=30'b1<<IDLE;
    default:state<=30'b1<<IDLE;
   endcase
   if(quant_valid&&quant_error&&(state[Q_SEND]||state[Q_WAIT]))begin status<=4;state<=30'b1<<FINISH;end
   // Never withdraw an offered request or abandon an accepted transaction.
   if(aborting&&!state[MREQ]&&!state[MWAIT]&&!state[FINISH]&&!state[IDLE])begin status<=3;state<=30'b1<<FINISH;end
  end
 end
 // Byte writes are shifted only at the word-aligned memory interface.
 // Request_data remains a byte for the duration of the transaction.
endmodule
