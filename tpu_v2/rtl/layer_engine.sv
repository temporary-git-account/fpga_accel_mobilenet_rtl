// tpu_v2 layer engine. Same job contract as the v1 engine (descriptor, region
// checks, status codes, cancellation, reset) with a faster memory schedule:
//  * Word-wide traffic. One request fetches up to four contiguous activation or
//    weight bytes, and one write stores up to four contiguous output channels
//    with exact byte strobes. A small unpacker writes fetched bytes into the
//    banks one per cycle while the state machine already prepares the next
//    request.
//  * Continuation. Inside a contiguous run the next request address is
//    request_address + count; the multiply/offset states run once per run.
//  * Discarded lanes are not loaded. Weight channels >= output_c and pixels
//    >= output_h*output_w produce garbage in lanes whose bytes are never
//    written; requantizer faults in those lanes are masked. Zero padding is
//    still written for source pixels outside the image because those lanes
//    feed real outputs.
//  * The MAC is fed one term per cycle from pipelined bank reads.
//  * Eight per-job phase counters classify every busy cycle.
// Memory requests are aligned 32-bit words, one outstanding. Parameters are
// 16 bytes/channel: int32 bias, Q31 multiplier, uint32 right shift, reserved.
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
 output logic [255:0] phase_counters,
 output wire mem_valid,input logic mem_ready,
 output wire [31:0] mem_addr,mem_wdata,output wire [3:0] mem_wstrb,
 input logic rsp_valid,output wire rsp_ready,input logic [31:0] rsp_data,input logic rsp_error
);
 // Explicit one-hot state bits keep bank enables and DSP enables shallow.
 localparam integer IDLE=0,CHECK=1,
  W_ADDR=2,W_NEXT=3,W_CONT=4,
  P_ADDR=5,P_NEXT=6,P_CONT=7,
  PIX_INIT=8,PIX_NEXT=9,
  A_SELECT=10,A_COORD=11,A_MUL=12,A_OFF1=13,A_OFF2=14,A_ADDR=15,A_NEXT=16,A_CONT=17,A_PAD=18,
  RUN_WAIT=19,RUN=20,SUM_WAIT=21,
  Q_SEND=22,Q_WAIT=23,
  O_ADDR=24,O_NEXT=25,O_CONT=26,
  NEXT_TILE=27,
  MULTIPLY=28,OFFSET=29,ADDRESS=30,CHECK_REQ=31,MREQ=32,MWAIT=33,FINISH=34;
 localparam integer STATES=35;
 (* fsm_encoding="none" *) logic [STATES-1:0] state;
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
 logic [10:0] term,terms,run_term,last_term;
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
 // Run bookkeeping. inner_rem counts the bytes left in the contiguous run,
 // span caps it at four, count is the bytes of the current transaction.
 logic [10:0] rem_a,rem_b,inner_rem;
 logic [2:0] span,count;
 logic [3:0] pixel_ok;
 logic [7:0] chan_ok;
 // MAC feed pipeline.
 logic feed_valid,feed_first,feed_last,run_all_issued;
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
 // Tile bases are multiples of eight channels / four pixels. Concatenate
 // the lane bits instead of building a carry chain on every address/enable.
 wire [10:0] active_channel={channel_base[10:3],chan};
 wire [16:0] active_pixel={pixel_base[16:2],pix[1:0]};
 wire [10:0] output_channel={channel_base[10:3],store_lane[2:0]};
 wire [16:0] output_pixel={pixel_base[16:2],store_lane[4:3]};
 wire channel_valid={5'b0,active_channel}<oc;
 wire last_run=reduction_x==kh-2'd1 && reduction_y==kh-2'd1;
 // Transaction sizing: bytes to the end of the word versus bytes left in the run.
 wire [2:0] lane_left=3'd4-{1'b0,request_address[1:0]};
 wire [2:0] count_comb=({8'b0,span}<{8'b0,lane_left}) ? span : lane_left;
 wire [3:0] strobe_comb=count_comb[2] ? 4'b1111 : count_comb[1] ? (count_comb[0] ? 4'b0111 : 4'b0011) : 4'b0001;
 function automatic [2:0] min4(input [10:0] x); min4=(x[10:2]!=0) ? 3'd4 : {1'b0,x[1:0]}; endfunction
 function automatic [10:0] min11(input [10:0] x,input [10:0] y); min11=(x<y) ? x : y; endfunction
 // Bank writer: unpacks one fetched word (or a zero run) into the activation
 // or weight banks, one byte per cycle, tagged with lane/address. The state
 // machine never issues a new fetch while a word is still being unpacked.
 logic [2:0] u_left;
 logic [31:0] u_word;
 logic [1:0] u_lane,u_pix;
 logic u_is_a,u_pad;
 logic [9:0] u_term;
 logic [2:0] u_chan;
 wire u_busy=u_left!=0;
 wire [7:0] u_byte=u_word >> (u_lane*8);
 wire signed [8:0] u_corrected=$signed({u_byte[7],u_byte})-$signed({iz[7],iz});
 wire pad_start=((state[A_ADDR]&&!source_inside)||state[A_PAD])&&!u_busy;
 wire fetch_start=memory_accept&&(mem_kind==KIND_A||mem_kind==KIND_W);
 logic a_write_q,w_write_q,a_dw_q;
 logic signed [8:0] a_data_q;
 logic [7:0] w_data_q;
 logic [9:0] a_term_q,w_term_q;
 logic [1:0] a_pix_q;
 logic [2:0] a_chan_q,w_chan_q;
 always_ff @(posedge clk)begin
  if(core_reset)begin u_left<=0;a_write_q<=0;w_write_q<=0;end
  else begin
   if(fetch_start||pad_start)begin
    u_left<=pad_start ? span : count;u_word<=rsp_data;u_lane<=pad_start ? 2'b0 : request_address[1:0];
    u_is_a<=pad_start||mem_kind==KIND_A;u_pad<=pad_start;
    u_term<=term[9:0];u_pix<=pix[1:0];u_chan<=chan;
   end else if(u_busy)begin
    u_left<=u_left-3'd1;u_lane<=u_lane+2'd1;
    if(dw)u_chan<=u_chan+3'd1;else u_term<=u_term+10'd1;
   end
   a_write_q<=u_busy&&u_is_a;w_write_q<=u_busy&&!u_is_a;
   a_data_q<=u_pad ? 9'sd0 : u_corrected;a_dw_q<=dw;a_term_q<=u_term;a_pix_q<=u_pix;a_chan_q<=u_chan;
   w_data_q<=u_byte;w_term_q<=u_term;w_chan_q<=u_chan;
  end
 end
 wire [35:0] shared_a;
 wire [287:0] depth_a;
 wire [63:0] packed_w;
 wire mac_ready,mac_valid;
 // Banked true synchronous memories, no reset of data arrays. Reads advance
 // only when the MAC can accept, so a stall holds the whole feed pipeline.
 for(genvar p=0;p<4;p=p+1)begin:abank
  (* ram_style="block" *) logic signed [8:0] ram[1024];
  logic signed [8:0] q;
  always_ff @(posedge clk)begin
   if(a_write_q&&!a_dw_q&&a_pix_q==p)ram[a_term_q]<=a_data_q;
   if(mac_ready)q<=ram[run_term[9:0]];
  end
  assign shared_a[p*9+:9]=q;
  for(genvar c=0;c<8;c=c+1)begin:d_bank
   (* ram_style="distributed" *) logic signed [8:0] ram[16];
   logic signed [8:0] q;
   always_ff @(posedge clk)begin
    if(a_write_q&&a_dw_q&&a_pix_q==p&&a_chan_q==c)ram[a_term_q[3:0]]<=a_data_q;
    if(mac_ready)q<=ram[run_term[3:0]];
   end
   assign depth_a[(p*8+c)*9+:9]=q;
  end
 end
 for(genvar c=0;c<8;c=c+1)begin:wbank
  (* ram_style="block" *) logic [7:0] ram[1024];
  logic [7:0] q;
  always_ff @(posedge clk)begin
   if(w_write_q&&w_chan_q==c)ram[w_term_q]<=w_data_q;
   if(mac_ready)q<=ram[run_term[9:0]];
  end
  assign packed_w[c*8+:8]=q;
 end
 wire [287:0] packed_a;
 for(genvar p=0;p<4;p=p+1)for(genvar c=0;c<8;c=c+1)
  assign packed_a[(p*8+c)*9+:9]=dw ? depth_a[(p*8+c)*9+:9] : shared_a[p*9+:9];
 // One term per cycle: the address issued in cycle t is data plus valid in t+1.
 always_ff @(posedge clk)begin
  if(core_reset)begin feed_valid<=0;feed_first<=0;feed_last<=0;end
  else if(mac_ready)begin
   feed_valid<=state[RUN]&&!run_all_issued;
   feed_first<=run_term==0;feed_last<=run_term==last_term;
  end
 end
 wire [1023:0] raw_sums;
 wire quant_ready,quant_valid,quant_error;
 wire signed [7:0] quant_result;
 vector_mac mac(.clk(clk),.rst(core_reset),.valid(feed_valid),.ready(mac_ready),
  .first(feed_first),.last(feed_last),.activations(packed_a),.weights(packed_w),
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
 // Lanes whose bytes are never stored may hold garbage; ignore their faults.
 wire lane_ok=pixel_ok[q_received[4:3]]&&chan_ok[q_received[2:0]];
 wire quant_take=quant_valid&&(state[Q_SEND]||state[Q_WAIT]);
 // Output packing: up to four channels of one pixel, masked to count.
 wire [31:0] packed_out={
  count_comb[2] ? tile_output[store_lane[4:0]+5'd3] : 8'b0,
  (count_comb[2]||count_comb[1]) ? tile_output[store_lane[4:0]+5'd2] : 8'b0,
  (count_comb[2]||count_comb[1]) ? tile_output[store_lane[4:0]+5'd1] : 8'b0,
  tile_output[store_lane[4:0]]};
 // Phase classification of every busy cycle.
 logic [2:0] phase_idx;
 wire in_mem=state[MREQ]||state[MWAIT];
 wire in_shared=state[MULTIPLY]||state[OFFSET]||state[ADDRESS]||state[CHECK_REQ]||in_mem;
 always_comb begin
  if(state[W_ADDR]||state[W_NEXT]||state[W_CONT])phase_idx=0;
  else if(state[P_ADDR]||state[P_NEXT]||state[P_CONT])phase_idx=1;
  else if(state[PIX_INIT]||state[PIX_NEXT]||state[A_SELECT]||state[A_COORD]||state[A_MUL]||state[A_OFF1]||
          state[A_OFF2]||state[A_ADDR]||state[A_NEXT]||state[A_CONT]||state[A_PAD])phase_idx=2;
  else if(state[RUN_WAIT]||state[RUN]||state[SUM_WAIT])phase_idx=3;
  else if(state[Q_SEND]||state[Q_WAIT])phase_idx=4;
  else if(state[O_ADDR]||state[O_NEXT]||state[O_CONT]||state[NEXT_TILE])phase_idx=5;
  else if(in_shared)case(mem_kind)
   KIND_W:phase_idx=0;
   KIND_P:phase_idx=1;
   KIND_A:phase_idx=2;
   default:phase_idx=5;
  endcase
  else phase_idx=7;
 end
 logic [31:0] phase_count[8];
 for(genvar i=0;i<8;i=i+1)assign phase_counters[i*32+:32]=phase_count[i];
 always_ff @(posedge clk)begin
  if(rst||(state[IDLE]&&cmd_valid))for(integer i=0;i<8;i=i+1)phase_count[i]<=0;
  else if(busy)begin
   phase_count[phase_idx]<=phase_count[phase_idx]+1;
   if(in_mem)phase_count[6]<=phase_count[6]+1;
  end
 end
 // Pixel coordinates are advanced with counters, avoiding hardware division.
 // All address intermediates have a dedicated pipeline stage.
 always_ff @(posedge clk)begin
  if(rst)begin state<=STATES'(1)<<IDLE;status<=0;aborting<=0;cycles<=0;reads<=0;writes<=0;done_id<=0;end
  else begin
   if(busy)cycles<=cycles+1;
   if(busy&&cancel)aborting<=1;
   if(quant_take)begin
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
     state<=STATES'(1)<<CHECK;
    end
    state[CHECK]:begin
     terms<=weight_terms[10:0];last_term<=weight_terms[10:0]-11'd1;last_column<=ow[8:0]-9'd1;
     channel_base<=0;chan<=0;term<=0;pixel_ok<=0;chan_ok<=0;
     // Bounded dimensions also keep all address products in 32 bits. Every
     // request is separately checked against the authorized DDR arena.
     if(ih==0||iw==0||ic==0||oh==0||ow==0||oc==0||ih>256||iw>256||oh>256||ow>256||
        ic>1024||oc>1024||(kh!=1&&kh!=3)||(st!=1&&st!=2)||
        weight_terms==0||weight_terms>1024||(dw&&ic!=oc)||amin>amax||
        rb>=rl||rb[3:0]!=0||rl[3:0]!=0||pb[3:0]!=0)begin status<=1;state<=STATES'(1)<<FINISH;end
     else state<=STATES'(1)<<W_ADDR;
    end
    // Weights. Regular convolution: term is the contiguous index for one
    // channel. Depthwise: channels are contiguous for one term. Channels at or
    // beyond output_c are never loaded; their lanes are discarded.
    state[W_ADDR]:begin
     mul_a<=dw ? {9'b0,term} : {9'b0,active_channel};mul_b<=dw ? {1'b0,oc} : {6'b0,terms};
     addend<=dw ? {21'b0,active_channel} : {21'b0,term};address_base<=wb;mem_kind<=KIND_W;
     rem_a<=dw ? 11'd8-{8'b0,chan} : terms-term;
     rem_b<=dw ? oc[10:0]-active_channel : terms-term;
     if(!channel_valid)begin
      if(dw&&term!=last_term)begin term<=term+11'd1;chan<=0;end
      else begin term<=0;chan<=0;param_word<=0;state<=STATES'(1)<<P_ADDR;end
     end else state<=STATES'(1)<<MULTIPLY;
    end
    state[W_NEXT]:begin
     inner_rem<=inner_rem-{8'b0,count};
     if(dw)chan<=chan+count;else term<=term+{8'b0,count};
     if(inner_rem=={8'b0,count})begin
      if(dw)begin
       chan<=0;
       if(term==last_term)begin term<=0;param_word<=0;state<=STATES'(1)<<P_ADDR;end
       else begin term<=term+11'd1;state<=STATES'(1)<<W_ADDR;end
      end else begin
       term<=0;
       if(chan==7)begin chan<=0;param_word<=0;state<=STATES'(1)<<P_ADDR;end
       else begin chan<=chan+3'd1;state<=STATES'(1)<<W_ADDR;end
      end
     end else state<=STATES'(1)<<W_CONT;
    end
    state[W_CONT]:begin request_address<=request_address+{30'b0,count};span<=min4(inner_rem);state<=STATES'(1)<<CHECK_REQ;end
    // Parameters: three words per channel, defaults for discarded channels.
    state[P_ADDR]:begin
     mul_a<={9'b0,active_channel};mul_b<=17'd16;addend<={28'b0,param_word,2'b0};address_base<=pb;mem_kind<=KIND_P;
     rem_a<=11'd1;rem_b<=11'd1;chan_ok[chan]<=channel_valid;
     if(!channel_valid)begin biases[chan]<=0;multipliers[chan]<=32'h40000000;shifts[chan]<=0;param_word<=2;state<=STATES'(1)<<P_NEXT;end
     else state<=STATES'(1)<<MULTIPLY;
    end
    state[P_NEXT]:begin
     if(param_word==2)begin
      param_word<=0;
      if(chan==7)begin pixel_base<=0;next_x<=0;next_y<=0;pix<=0;state<=STATES'(1)<<PIX_INIT;end
      else begin chan<=chan+3'd1;state<=STATES'(1)<<P_ADDR;end
     end else begin param_word<=param_word+2'd1;state<=STATES'(1)<<P_CONT;end
    end
    state[P_CONT]:begin request_address<=request_address+33'd4;span<=3'd1;state<=STATES'(1)<<CHECK_REQ;end
    // Activations. Regular convolution: input channels are contiguous for one
    // kernel tap. Depthwise: channels are contiguous for one tap and pixel.
    state[PIX_INIT]:begin
     tile_x[pix[1:0]]<=($signed({2'b0,next_x}) << (st==2))-$signed({9'b0,pl});
     tile_y[pix[1:0]]<=($signed({2'b0,next_y}) << (st==2))-$signed({9'b0,pt});
     pixel_ok[pix[1:0]]<={15'b0,active_pixel}<total_pixels;
     if(next_x==last_column)begin next_x<=0;next_y<=next_y+9'd1;end else next_x<=next_x+9'd1;
     state<=STATES'(1)<<PIX_NEXT;
    end
    state[PIX_NEXT]:if(pix==3)begin pix<=0;chan<=0;term<=0;reduction_c<=0;reduction_x<=0;reduction_y<=0;state<=STATES'(1)<<A_SELECT;end
     else begin pix<=pix+3'd1;state<=STATES'(1)<<PIX_INIT;end
    state[A_SELECT]:begin
     selected_x<=tile_x[pix[1:0]];selected_y<=tile_y[pix[1:0]];
     rem_a<=dw ? 11'd8-{8'b0,chan} : ic[10:0]-reduction_c[10:0];
     rem_b<=dw ? oc[10:0]-active_channel : ic[10:0]-reduction_c[10:0];
     if(!pixel_ok[pix[1:0]])begin
      chan<=0;term<=0;reduction_c<=0;reduction_x<=0;reduction_y<=0;
      if(pix!=3)pix<=pix+3'd1;else state<=STATES'(1)<<RUN_WAIT;
     end else state<=STATES'(1)<<A_COORD;
    end
    state[A_COORD]:begin
     source_x<=selected_x+$signed({9'b0,reduction_x});
     source_y<=selected_y+$signed({9'b0,reduction_y});
     inner_rem<=min11(rem_a,rem_b);state<=STATES'(1)<<A_MUL;
    end
    state[A_MUL]:begin
     source_inside<=source_x>=0&&source_y>=0&&source_x<$signed({1'b0,iw})&&source_y<$signed({1'b0,ih});
     row_offset<=source_y[7:0]*row_bytes[18:0];column_offset<=source_x[7:0]*ic[10:0];
     span<=min4(inner_rem);state<=STATES'(1)<<A_OFF1;
    end
    state[A_OFF1]:begin input_offset<=row_offset+column_offset;state<=STATES'(1)<<A_OFF2;end
    state[A_OFF2]:begin input_offset<=input_offset+(dw ? {21'b0,active_channel} : {16'b0,reduction_c});state<=STATES'(1)<<A_ADDR;end
    state[A_ADDR]:if(!source_inside)begin if(!u_busy)begin count<=span;state<=STATES'(1)<<A_NEXT;end end
     else begin request_address<={1'b0,ib}+{1'b0,input_offset};mem_kind<=KIND_A;state<=STATES'(1)<<CHECK_REQ;end
    state[A_NEXT]:begin
     inner_rem<=inner_rem-{8'b0,count};
     if(dw)chan<=chan+count;else begin term<=term+{8'b0,count};reduction_c<=reduction_c+{13'b0,count};end
     if(inner_rem=={8'b0,count})begin
      chan<=0;reduction_c<=0;
      if(dw ? term==last_term : last_run)begin
       term<=0;reduction_x<=0;reduction_y<=0;
       if(pix!=3)begin pix<=pix+3'd1;state<=STATES'(1)<<A_SELECT;end
       else state<=STATES'(1)<<RUN_WAIT;
      end else begin
       if(dw)term<=term+11'd1;
       if(reduction_x==kh-2'd1)begin reduction_x<=0;reduction_y<=reduction_y+2'd1;end
       else reduction_x<=reduction_x+2'd1;
       state<=STATES'(1)<<A_SELECT;
      end
     end else state<=STATES'(1)<<A_CONT;
    end
    state[A_CONT]:begin
     request_address<=request_address+{30'b0,count};span<=min4(inner_rem);
     state<=source_inside ? STATES'(1)<<CHECK_REQ : STATES'(1)<<A_PAD;
    end
    state[A_PAD]:if(!u_busy)begin count<=span;state<=STATES'(1)<<A_NEXT;end
    // MAC feed and requantization.
    state[RUN_WAIT]:if(!u_busy&&!a_write_q&&!w_write_q)begin run_term<=0;run_all_issued<=0;state<=STATES'(1)<<RUN;end
    state[RUN]:if(mac_ready)begin
     if(!run_all_issued)begin if(run_term==last_term)run_all_issued<=1;else run_term<=run_term+11'd1;end
     if(feed_valid&&feed_last)state<=STATES'(1)<<SUM_WAIT;
    end
    state[SUM_WAIT]:if(mac_valid)begin q_send<=0;q_received<=0;state<=STATES'(1)<<Q_SEND;end
    state[Q_SEND]:if(quant_buffer_ready)begin if(q_send==31)state<=STATES'(1)<<Q_WAIT;else q_send<=q_send+6'd1;end
    state[Q_WAIT]:if(q_received==32)begin store_lane<=0;state<=STATES'(1)<<O_ADDR;end
    // Output: channels of one pixel are contiguous; pack up to four per write.
    state[O_ADDR]:begin
     mul_a<={3'b0,output_pixel};mul_b<={1'b0,oc};addend<={21'b0,output_channel};address_base<=ob;mem_kind<=KIND_O;
     rem_a<=11'd8-{8'b0,store_lane[2:0]};rem_b<=oc[10:0]-output_channel;
     if(!pixel_ok[store_lane[4:3]]||!chan_ok[store_lane[2:0]])begin
      if(store_lane[4:3]==3)state<=STATES'(1)<<NEXT_TILE;
      else store_lane<={1'b0,store_lane[4:3]+2'd1,3'b0};
     end else state<=STATES'(1)<<MULTIPLY;
    end
    state[O_NEXT]:begin
     inner_rem<=inner_rem-{8'b0,count};store_lane[2:0]<=store_lane[2:0]+count;
     if(inner_rem=={8'b0,count})begin
      if(store_lane[4:3]==3)state<=STATES'(1)<<NEXT_TILE;
      else begin store_lane<={1'b0,store_lane[4:3]+2'd1,3'b0};state<=STATES'(1)<<O_ADDR;end
     end else state<=STATES'(1)<<O_CONT;
    end
    state[O_CONT]:begin request_address<=request_address+{30'b0,count};span<=min4(inner_rem);state<=STATES'(1)<<CHECK_REQ;end
    state[NEXT_TILE]:if(pixel_base+17'd4<total_pixels[16:0])begin pixel_base<=pixel_base+17'd4;pix<=0;state<=STATES'(1)<<PIX_INIT;end
     else if({5'b0,channel_base}+16'd8<oc)begin channel_base<=channel_base+11'd8;chan<=0;term<=0;state<=STATES'(1)<<W_ADDR;end
     else state<=STATES'(1)<<FINISH;
    // Shared address generation and memory transaction.
    state[MULTIPLY]:begin mul_product<=mul_a*mul_b;inner_rem<=min11(rem_a,rem_b);state<=STATES'(1)<<OFFSET;end
    state[OFFSET]:begin
     offset<=mul_product[31:0]+addend;span<=min4(inner_rem);
     if(mul_product[36:32]!=0)begin status<=1;state<=STATES'(1)<<FINISH;end
     else state<=STATES'(1)<<ADDRESS;
    end
    state[ADDRESS]:begin request_address<={1'b0,address_base}+{1'b0,offset};state<=STATES'(1)<<CHECK_REQ;end
    state[CHECK_REQ]:if(!address_legal)begin status<=1;state<=STATES'(1)<<FINISH;end
     else if(!u_busy)begin
      count<=count_comb;
      request_strobe<=mem_kind==KIND_O ? strobe_comb : 4'b0;
      request_data<=mem_kind==KIND_O ? packed_out : 32'b0;
      state<=STATES'(1)<<MREQ;
     end
    state[MREQ]:begin
     if(mem_ready)begin
      if(request_strobe==0)reads<=reads+1;else writes<=writes+1;
      state<=STATES'(1)<<MWAIT;
     end
    end
    state[MWAIT]:if(rsp_valid)begin
     if(rsp_error)begin status<=2;state<=STATES'(1)<<FINISH;end
     else begin
      if(mem_kind==KIND_P)begin
       case(param_word)
        0:biases[chan]<=rsp_data;
        1:multipliers[chan]<=rsp_data;
        2:shifts[chan]<=rsp_data[4:0];
        default:;
       endcase
       if((param_word==1&&(rsp_data==0||rsp_data[31]))||(param_word==2&&rsp_data>31))begin status<=1;state<=STATES'(1)<<FINISH;end
       else state<=STATES'(1)<<P_NEXT;
      end else case(mem_kind)
       KIND_W:state<=STATES'(1)<<W_NEXT;
       KIND_A:state<=STATES'(1)<<A_NEXT;
       KIND_O:state<=STATES'(1)<<O_NEXT;
       default:begin status<=1;state<=STATES'(1)<<FINISH;end
      endcase
     end
    end
    state[FINISH]:if(done_ready)state<=STATES'(1)<<IDLE;
    default:state<=STATES'(1)<<IDLE;
   endcase
   if(quant_take&&quant_error&&lane_ok)begin status<=4;state<=STATES'(1)<<FINISH;end
   // Never withdraw an offered request or abandon an accepted transaction.
   if(aborting&&!state[MREQ]&&!state[MWAIT]&&!state[FINISH]&&!state[IDLE])begin status<=3;state<=STATES'(1)<<FINISH;end
  end
 end
 // Byte writes are shifted only at the word-aligned memory interface.
 // request_data holds the packed bytes for the duration of the transaction.
endmodule
