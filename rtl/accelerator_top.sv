// AXI-Lite register bank plus layer engine and cached AXI DDR master.
module accelerator_top (
 (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET resetn" *)
 input wire clk,
 (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME resetn, POLARITY ACTIVE_LOW" *) input wire resetn,
 input wire [11:0] s_axi_awaddr,input wire [2:0] s_axi_awprot,input wire s_axi_awvalid,output wire s_axi_awready,
 input wire [31:0] s_axi_wdata,input wire [3:0] s_axi_wstrb,input wire s_axi_wvalid,output wire s_axi_wready,
 output reg [1:0] s_axi_bresp,output reg s_axi_bvalid,input wire s_axi_bready,
 input wire [11:0] s_axi_araddr,input wire [2:0] s_axi_arprot,input wire s_axi_arvalid,output wire s_axi_arready,
 output reg [31:0] s_axi_rdata,output reg [1:0] s_axi_rresp,output reg s_axi_rvalid,input wire s_axi_rready,
 output wire [31:0] m_axi_araddr,output wire [7:0] m_axi_arlen,output wire [2:0] m_axi_arsize,
 output wire [1:0] m_axi_arburst,output wire m_axi_arvalid,input logic m_axi_arready,
 input logic [63:0] m_axi_rdata,input logic [1:0] m_axi_rresp,input logic m_axi_rlast,m_axi_rvalid,output wire m_axi_rready,
 output wire [31:0] m_axi_awaddr,output wire [7:0] m_axi_awlen,output wire [2:0] m_axi_awsize,
 output wire [1:0] m_axi_awburst,output wire m_axi_awvalid,input logic m_axi_awready,
 output wire [63:0] m_axi_wdata,output wire [7:0] m_axi_wstrb,output wire m_axi_wlast,m_axi_wvalid,input logic m_axi_wready,
 input logic [1:0] m_axi_bresp,input logic m_axi_bvalid,output wire m_axi_bready,
 output wire [3:0] m_axi_arcache,m_axi_awcache,
 output wire [2:0] m_axi_arprot,m_axi_awprot,
 output wire m_axi_arlock,m_axi_awlock,
 output wire [3:0] m_axi_arqos,m_axi_awqos
);
 wire rst=!resetn;
 logic [31:0] config_regs[8:19];
 logic aw_held,w_held;logic [11:0] awaddr;logic [31:0] wdata;logic [3:0] wstrb;
 logic start,cancel,ack;
 wire cmd_ready,busy,done_valid,fatal;
 wire [31:0] done_id,cycles,reads,writes;wire [3:0] status;
 wire mem_valid,mem_ready,rsp_valid,rsp_ready,rsp_error;
 wire [31:0] mem_addr,mem_wdata,rsp_data;wire [3:0] mem_wstrb;
 assign s_axi_awready=!aw_held&&!s_axi_bvalid;
 assign s_axi_wready=!w_held&&!s_axi_bvalid;
 assign s_axi_arready=!s_axi_rvalid;
 assign m_axi_arcache=3;assign m_axi_awcache=3;
 assign m_axi_arprot=0;assign m_axi_awprot=0;
 assign m_axi_arlock=0;assign m_axi_awlock=0;
 assign m_axi_arqos=0;assign m_axi_awqos=0;
 always_ff @(posedge clk)begin
  if(rst)begin
   aw_held<=0;w_held<=0;s_axi_bvalid<=0;s_axi_rvalid<=0;s_axi_bresp<=0;s_axi_rresp<=0;
   start<=0;cancel<=0;ack<=0;
   for(integer i=8;i<20;i=i+1)config_regs[i]<=0;
  end else begin
   start<=0;cancel<=0;ack<=0;
   if(s_axi_awvalid&&s_axi_awready)begin awaddr<=s_axi_awaddr;aw_held<=1;end
   if(s_axi_wvalid&&s_axi_wready)begin wdata<=s_axi_wdata;wstrb<=s_axi_wstrb;w_held<=1;end
   if(s_axi_bvalid&&s_axi_bready)s_axi_bvalid<=0;
   if(aw_held&&w_held&&!s_axi_bvalid)begin
    aw_held<=0;w_held<=0;s_axi_bvalid<=1;s_axi_bresp<=0;
    if(awaddr[1:0]!=0)s_axi_bresp<=2;
    else if(awaddr==0)begin
     if(!wstrb[0])s_axi_bresp<=2;
     else if(wdata==1&&cmd_ready&&!fatal&&!start)start<=1;
     else if(wdata==2&&busy)cancel<=1;
     else if(wdata==4&&done_valid)ack<=1;
     else s_axi_bresp<=2;
    end else if(awaddr>=32&&awaddr<80&&!busy&&!done_valid&&!start&&!fatal)begin
     for(integer i=0;i<4;i=i+1)if(wstrb[i])config_regs[awaddr[6:2]][i*8+:8]<=wdata[i*8+:8];
    end else s_axi_bresp<=2;
   end
   if(s_axi_rvalid&&s_axi_rready)s_axi_rvalid<=0;
   if(s_axi_arvalid&&s_axi_arready)begin
    s_axi_rvalid<=1;s_axi_rresp<=0;
    if(s_axi_araddr[1:0]!=0)begin s_axi_rresp<=2;s_axi_rdata<=0;end
    else case(s_axi_araddr)
     0:s_axi_rdata<={29'b0,fatal,done_valid,busy};
     4:s_axi_rdata<=32'h49414331;
     8:s_axi_rdata<=done_id;
     12:s_axi_rdata<={28'b0,status};
     16:s_axi_rdata<=cycles;
     20:s_axi_rdata<=reads;
     24:s_axi_rdata<=writes;
     default:if(s_axi_araddr>=32&&s_axi_araddr<80)s_axi_rdata<=config_regs[s_axi_araddr[6:2]];
      else begin s_axi_rresp<=2;s_axi_rdata<=0;end
    endcase
   end
  end
 end
 layer_engine engine(.clk(clk),.rst(rst),.cmd_valid(start),.cmd_ready(cmd_ready),
  .cmd_id(config_regs[8]),.input_base(config_regs[9]),.weights_base(config_regs[10]),.params_base(config_regs[11]),
  .output_base(config_regs[12]),.region_base(config_regs[13]),.region_limit(config_regs[14]),
  .input_h(config_regs[15][15:0]),.input_w(config_regs[15][31:16]),
  .input_c(config_regs[16][15:0]),.output_h(config_regs[16][31:16]),
  .output_w(config_regs[17][15:0]),.output_c(config_regs[17][31:16]),
  .kernel(config_regs[18][1:0]),.stride(config_regs[18][3:2]),.pad_top(config_regs[18][5:4]),
  .pad_left(config_regs[18][7:6]),.depthwise(config_regs[18][8]),
  .input_zero(config_regs[19][7:0]),.output_zero(config_regs[19][15:8]),
  .activation_min(config_regs[19][23:16]),.activation_max(config_regs[19][31:24]),
  .cancel(cancel),.busy(busy),.done_valid(done_valid),.done_ready(ack),.done_id(done_id),.status(status),
  .cycles(cycles),.reads(reads),.writes(writes),
  .mem_valid(mem_valid),.mem_ready(mem_ready),.mem_addr(mem_addr),.mem_wdata(mem_wdata),.mem_wstrb(mem_wstrb),
  .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error));
 axi_memory memory(.clk(clk),.rst(rst),.invalidate(start),.req_valid(mem_valid),.req_ready(mem_ready),
  .req_addr(mem_addr),.req_wdata(mem_wdata),.req_wstrb(mem_wstrb),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
  .rsp_data(rsp_data),.rsp_error(rsp_error),.fatal(fatal),
  .m_axi_araddr(m_axi_araddr),
  .m_axi_arlen(m_axi_arlen),
  .m_axi_arsize(m_axi_arsize),
  .m_axi_arburst(m_axi_arburst),
  .m_axi_arvalid(m_axi_arvalid),
  .m_axi_arready(m_axi_arready),
  .m_axi_rdata(m_axi_rdata),
  .m_axi_rresp(m_axi_rresp),
  .m_axi_rlast(m_axi_rlast),
  .m_axi_rvalid(m_axi_rvalid),
  .m_axi_rready(m_axi_rready),
  .m_axi_awaddr(m_axi_awaddr),
  .m_axi_awlen(m_axi_awlen),
  .m_axi_awsize(m_axi_awsize),
  .m_axi_awburst(m_axi_awburst),
  .m_axi_awvalid(m_axi_awvalid),
  .m_axi_awready(m_axi_awready),
  .m_axi_wdata(m_axi_wdata),
  .m_axi_wstrb(m_axi_wstrb),
  .m_axi_wlast(m_axi_wlast),
  .m_axi_wvalid(m_axi_wvalid),
  .m_axi_wready(m_axi_wready),
  .m_axi_bresp(m_axi_bresp),
  .m_axi_bvalid(m_axi_bvalid),
  .m_axi_bready(m_axi_bready));
endmodule
