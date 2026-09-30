// 32-bit request/response memory port -> AXI4 64-bit DDR master.
// Eight direct-mapped 16-byte read cache lines. Read bursts are two beats and
// never cross 4 KiB. Writes use byte strobes and invalidate a matching line.
// One outstanding transaction; independent AW/W handshakes. A transport
// timeout latches fatal but continues draining the outstanding transaction.
// A fatal transport requires coordinated AXI fabric reset before reuse.
module axi_memory #(parameter integer TIMEOUT_CYCLES=100000000)(
 input logic clk,rst,invalidate,
 input logic req_valid,output wire req_ready,input logic [31:0] req_addr,req_wdata,input logic [3:0] req_wstrb,
 output wire rsp_valid,input logic rsp_ready,output logic [31:0] rsp_data,output logic rsp_error,output logic fatal,
 output wire [31:0] m_axi_araddr,output wire [7:0] m_axi_arlen,output wire [2:0] m_axi_arsize,
 output wire [1:0] m_axi_arburst,output wire m_axi_arvalid,input logic m_axi_arready,
 input logic [63:0] m_axi_rdata,input logic [1:0] m_axi_rresp,input logic m_axi_rlast,m_axi_rvalid,output wire m_axi_rready,
 output wire [31:0] m_axi_awaddr,output wire [7:0] m_axi_awlen,output wire [2:0] m_axi_awsize,
 output wire [1:0] m_axi_awburst,output wire m_axi_awvalid,input logic m_axi_awready,
 output wire [63:0] m_axi_wdata,output wire [7:0] m_axi_wstrb,output wire m_axi_wlast,m_axi_wvalid,input logic m_axi_wready,
 input logic [1:0] m_axi_bresp,input logic m_axi_bvalid,output wire m_axi_bready
);
 typedef enum logic [2:0] {IDLE,LOOKUP,AR,R,SEND,B,RESP} state_t;
 state_t state;
 logic [31:0] addr,data,watchdog;
 logic [3:0] strobe;
 logic [7:0] cache_valid;
 logic [24:0] tag[8];
 logic [127:0] cache[8];
 logic [63:0] first_data;
 logic beat,bad,aw_sent,w_sent;
 assign req_ready=state==IDLE&&!fatal&&!invalidate;
 assign rsp_valid=state==RESP;
 assign m_axi_araddr={addr[31:4],4'b0};assign m_axi_arlen=1;assign m_axi_arsize=3;assign m_axi_arburst=1;
 assign m_axi_arvalid=state==AR;assign m_axi_rready=state==R;
 assign m_axi_awaddr={addr[31:3],3'b0};assign m_axi_awlen=0;assign m_axi_awsize=3;assign m_axi_awburst=1;
 assign m_axi_awvalid=state==SEND&&!aw_sent;
 assign m_axi_wvalid=state==SEND&&!w_sent;assign m_axi_wlast=1;
 assign m_axi_wdata=addr[2]?{data,32'b0}:{32'b0,data};
 assign m_axi_wstrb=addr[2]?{strobe,4'b0}:{4'b0,strobe};
 assign m_axi_bready=state==B;
 always_ff @(posedge clk)begin
  if(rst)begin state<=IDLE;cache_valid<=0;fatal<=0;rsp_error<=0;watchdog<=0;end
  else begin
   if(invalidate)cache_valid<=0;
   if(state!=IDLE&&state!=RESP)begin
    if(watchdog<TIMEOUT_CYCLES)watchdog<=watchdog+1;
    else fatal<=1;
   end
   case(state)
    IDLE:if(req_valid&&req_ready)begin
     addr<=req_addr;data<=req_wdata;strobe<=req_wstrb;rsp_error<=0;watchdog<=0;bad<=0;beat<=0;
     if(req_addr[1:0]!=0)begin rsp_error<=1;state<=RESP;end
     else if(req_wstrb!=0)begin
      if(tag[req_addr[6:4]]==req_addr[31:7])cache_valid[req_addr[6:4]]<=0;
      aw_sent<=0;w_sent<=0;state<=SEND;
     end else state<=LOOKUP;
    end
    LOOKUP:begin
     rsp_data<=cache[addr[6:4]][addr[3:2]*32+:32];
     if(cache_valid[addr[6:4]]&&tag[addr[6:4]]==addr[31:7])begin
      state<=RESP;
     end else state<=AR;
    end
    AR:if(m_axi_arready)state<=R;
    R:if(m_axi_rvalid)begin
     if(m_axi_rresp!=0)bad<=1;
     if(m_axi_rlast!=beat)begin bad<=1;fatal<=1;end
     if(!beat)begin first_data<=m_axi_rdata;beat<=1;end
     if(m_axi_rlast)begin
      rsp_error<=bad||m_axi_rresp!=0||!beat||fatal||watchdog>=TIMEOUT_CYCLES;
      rsp_data<=addr[3] ? m_axi_rdata[addr[2]*32+:32] : first_data[addr[2]*32+:32];
      if(!bad&&m_axi_rresp==0&&beat&&!fatal)begin
       cache[addr[6:4]]<={m_axi_rdata,first_data};tag[addr[6:4]]<=addr[31:7];cache_valid[addr[6:4]]<=1;
      end
      state<=RESP;
     end
    end
    SEND:begin
     if(m_axi_awready)aw_sent<=1;
     if(m_axi_wready)w_sent<=1;
     if((aw_sent||m_axi_awready)&&(w_sent||m_axi_wready))state<=B;
    end
    B:if(m_axi_bvalid)begin rsp_error<=m_axi_bresp!=0||fatal||watchdog>=TIMEOUT_CYCLES;state<=RESP;end
    RESP:if(rsp_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
