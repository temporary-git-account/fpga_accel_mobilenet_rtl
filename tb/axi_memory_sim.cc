#include "Vaxi_memory.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>
struct Test{
 Vaxi_memory d;std::vector<uint8_t> mem=std::vector<uint8_t>(65536);
 uint32_t rng=71,ra=0,wa=0;uint64_t wd=0;uint8_t ws=0;
 bool reading=false,aw=false,w=false,b=false,hold_ar=false,early=false;
 int beat=0;bool read_error=false,write_error=false,last_req=false,last_rsp=false;uint32_t got=0;bool error=false;
 unsigned ars=0,aws=0;bool held=false;uint32_t held_data=0;bool held_error=false;
 Test(){for(size_t i=0;i<mem.size();i++)mem[i]=uint8_t(i*17+3);reset();}
 uint32_t word(uint32_t a){return uint32_t(mem[a])|(uint32_t(mem[a+1])<<8)|(uint32_t(mem[a+2])<<16)|(uint32_t(mem[a+3])<<24);}
 void reset(){d.rst=1;d.req_valid=0;d.invalidate=0;reading=aw=w=b=held=false;for(int i=0;i<4;i++)tick();d.rst=0;tick();}
 void tick(){
  rng=rng*1664525+1013904223;
  d.clk=0;d.m_axi_arready=!hold_ar&&!reading&&(rng&3)!=0;d.m_axi_awready=!aw&&(rng&4)!=0;d.m_axi_wready=!w&&(rng&8)!=0;
  d.m_axi_rvalid=reading&&((rng&16)!=0);d.m_axi_rlast=early||beat==1;d.m_axi_rresp=read_error?2:0;
  uint32_t addr=ra+beat*8;d.m_axi_rdata=uint64_t(word(addr))|(uint64_t(word(addr+4))<<32);
  d.m_axi_bvalid=b;d.m_axi_bresp=write_error?2:0;d.rsp_ready=(rng&32)!=0;d.eval();
  if(held&&(!d.rsp_valid||d.rsp_data!=held_data||d.rsp_error!=held_error))throw std::runtime_error("response changed under backpressure");
  held=d.rsp_valid&&!d.rsp_ready;held_data=d.rsp_data;held_error=d.rsp_error;
  last_req=d.req_valid&&d.req_ready;last_rsp=d.rsp_valid&&d.rsp_ready;
  if(last_rsp){got=d.rsp_data;error=d.rsp_error;}
  bool ar=d.m_axi_arvalid&&d.m_axi_arready,rr=d.m_axi_rvalid&&d.m_axi_rready;
  bool aa=d.m_axi_awvalid&&d.m_axi_awready,ww=d.m_axi_wvalid&&d.m_axi_wready,bb=d.m_axi_bvalid&&d.m_axi_bready;
  if(ar){if(d.m_axi_arlen!=1||d.m_axi_arsize!=3||d.m_axi_arburst!=1||(d.m_axi_araddr&15)||((d.m_axi_araddr&4095)+16>4096))throw std::runtime_error("bad read burst");ra=d.m_axi_araddr;ars++;}
  if(aa){if(d.m_axi_awlen||d.m_axi_awsize!=3||d.m_axi_awburst!=1||(d.m_axi_awaddr&7))throw std::runtime_error("bad write burst");wa=d.m_axi_awaddr;aws++;}
  if(ww){if(!d.m_axi_wlast)throw std::runtime_error("missing WLAST");wd=d.m_axi_wdata;ws=d.m_axi_wstrb;}
  d.clk=1;d.eval();
  if(rr){if(early||beat==1)reading=false;else beat++;}
  if(ar){reading=true;beat=0;}
  if(bb){b=false;aw=w=false;}
  if(aa)aw=true;if(ww)w=true;
  if(aw&&w&&!b){if(!write_error)for(int i=0;i<8;i++)if(ws&(1<<i))mem[wa+i]=wd>>(8*i);b=true;}
 }
 uint32_t transact(uint32_t addr,uint32_t data=0,uint8_t mask=0,bool expect_error=false,bool timeout=false){
  d.req_valid=1;d.req_addr=addr;d.req_wdata=data;d.req_wstrb=mask;
  unsigned count=0;do{tick();if(++count>1000)throw std::runtime_error("accept timeout");}while(!last_req);
  d.req_valid=0;count=0;do{tick();if(timeout&&count==50)hold_ar=false;if(++count>2000)throw std::runtime_error("response timeout");}while(!last_rsp);
  if(error!=expect_error)throw std::runtime_error("unexpected response error");return got;
 }
};
int main(int argc,char**argv){try{
 Verilated::commandArgs(argc,argv);Test t;
 for(unsigned i=0;i<3000;i++){
  uint32_t addr=(i%4==0)?0xffc:((i*13)%256)*4;
  if(i%3==0)t.transact(addr,i*0x1020304u,uint8_t(1u<<(i%4)));
  if(t.transact(addr)!=t.word(addr))throw std::runtime_error("memory/cache mismatch");
 }
 auto before=t.ars;auto a=t.transact(0x1000);auto b=t.transact(0x1004);
 if(a!=t.word(0x1000)||b!=t.word(0x1004)||t.ars!=before+1)throw std::runtime_error("cache hit missing");
 t.mem[0x1000]^=0xff;t.d.invalidate=1;t.tick();t.d.invalidate=0;
 if(t.transact(0x1000)!=t.word(0x1000))throw std::runtime_error("invalidate stale read");
 t.transact(3,0,0,true);
 t.read_error=true;t.transact(0x7000,0,0,true);t.read_error=false;
 if(t.transact(0x7000)!=t.word(0x7000))throw std::runtime_error("read error poisoned cache");
 t.write_error=true;t.transact(0x7000,0xffff,3,true);t.write_error=false;
 if(t.transact(0x7000)!=t.word(0x7000))throw std::runtime_error("write error poisoned cache");
 t.early=true;t.transact(0x7100,0,0,true);t.early=false;if(!t.d.fatal)throw std::runtime_error("bad RLAST not fatal");t.reset();
 t.hold_ar=true;t.transact(0x7200,0,0,true,true);if(!t.d.fatal||t.d.req_ready)throw std::runtime_error("timeout reuse allowed");t.reset();
 if(t.transact(0x7200)!=t.word(0x7200))throw std::runtime_error("reset recovery");
 std::cout<<"AXI_MEMORY_PASS random/cache/strobes/4KiB/errors/RLAST/timeout/drain/reset AR="<<t.ars<<" AW="<<t.aws<<std::endl;
 }catch(const std::exception&e){std::cerr<<"AXI_MEMORY_FAIL "<<e.what()<<std::endl;return 1;}}
