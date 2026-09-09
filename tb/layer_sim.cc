#include "Vlayer_engine.h"
#include "verilated.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
using Bytes=std::vector<uint8_t>;
static Bytes read_file(const std::string& p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error("open "+p);return Bytes(std::istreambuf_iterator<char>(f),{});}
static void equal(const Bytes&a,const Bytes&b,const std::string& tag){if(a.size()!=b.size())throw std::runtime_error(tag+" size");size_t n=0,first=0;for(size_t i=0;i<a.size();i++)if(a[i]!=b[i]){if(!n)first=i;n++;}if(n)throw std::runtime_error(tag+" mismatches="+std::to_string(n)+" first="+std::to_string(first)+" got="+std::to_string(int(int8_t(a[first])))+" expected="+std::to_string(int(int8_t(b[first]))));}
struct Runner{
 Vlayer_engine d;
 Bytes mem=Bytes(16*1024*1024);
 uint64_t ticks=0;
 uint32_t rng=17;
 bool pending=false;uint32_t response=0;int delay=0;bool err=false;
 uint64_t accepted=0;long inject=-1;bool random_stalls=true;
 static constexpr uint32_t IB=0x1000, WB=0x200000, PB=0x600000, OB=0x700000;
 Runner(){d.clk=0;d.rst=1;d.cmd_valid=0;d.cancel=0;d.done_ready=0;for(int i=0;i<4;i++)tick();d.rst=0;}
 void tick(){
  rng=rng*1664525+1013904223;
  d.clk=0;d.mem_ready=!pending&&(!random_stalls||(rng&7)!=0);
  d.rsp_valid=pending&&delay==0;d.rsp_data=response;d.rsp_error=err;d.eval();
  bool req=d.mem_valid&&d.mem_ready, rsp=d.rsp_valid&&d.rsp_ready;
  uint32_t addr=d.mem_addr,data=d.mem_wdata;uint8_t mask=d.mem_wstrb;
  d.clk=1;d.eval();ticks++;
  if(rsp)pending=false;
  if(pending&&delay)delay--;
  if(req){
   if(pending)throw std::runtime_error("multiple memory requests");
   if((addr&3)||addr<0x1000||addr+4>mem.size())throw std::runtime_error("illegal bus address");
   err=inject>=0&&accepted==uint64_t(inject);accepted++;
   if(!err)for(int j=0;j<4;j++)if(mask&(1<<j))mem[addr+j]=data>>(8*j);
   response=uint32_t(mem[addr])|(uint32_t(mem[addr+1])<<8)|(uint32_t(mem[addr+2])<<16)|(uint32_t(mem[addr+3])<<24);
   pending=true;delay=random_stalls?int((rng>>4)%4):0;
  }
 }
 Bytes run(const std::vector<int>&p,const Bytes&input,const Bytes&w,const Bytes&par,uint32_t id,long cancel_at=-1,int expected_status=0){
  if(p.size()!=15)throw std::runtime_error("descriptor size");
  std::fill(mem.begin(),mem.end(),0xa5);std::copy(input.begin(),input.end(),mem.begin()+IB);
  std::copy(w.begin(),w.end(),mem.begin()+WB);std::copy(par.begin(),par.end(),mem.begin()+PB);
  size_t outbytes=size_t(p[3])*p[4]*p[5];
  d.input_h=p[0];d.input_w=p[1];d.input_c=p[2];d.output_h=p[3];d.output_w=p[4];d.output_c=p[5];
  d.kernel=p[6];d.stride=p[7];d.pad_top=p[8];d.pad_left=p[9];d.depthwise=p[10];
  d.input_zero=p[11];d.output_zero=p[12];d.activation_min=p[13];d.activation_max=p[14];
  d.input_base=IB;d.weights_base=WB;d.params_base=PB;d.output_base=OB;d.region_base=0x1000;d.region_limit=mem.size();
  d.cmd_id=id;d.cmd_valid=1;d.cancel=0;d.done_ready=0;
  if(!d.cmd_ready)throw std::runtime_error("not ready at new job");
  tick();d.cmd_valid=0;uint64_t start=ticks;
  while(!d.done_valid){
   if(cancel_at>=0&&ticks-start>=uint64_t(cancel_at))d.cancel=1;
   tick();
   if(ticks-start>1000000000ULL)throw std::runtime_error("layer timeout");
  }
  d.cancel=0;
  if(d.done_id!=id||d.status!=expected_status||pending)throw std::runtime_error("completion id/status/drain: "+std::to_string(d.done_id)+" status="+std::to_string(d.status));
  auto writes=d.writes;
  for(int i=0;i<9;i++){tick();if(!d.done_valid||d.done_id!=id||d.writes!=writes)throw std::runtime_error("unstable completion");}
  for(size_t i=OB+outbytes;i<OB+outbytes+16;i++)if(mem[i]!=0xa5)throw std::runtime_error("output overrun");
  if(mem[OB-1]!=0xa5)throw std::runtime_error("output underrun");
  std::cout<<" job="<<id<<" cycles="<<d.cycles<<" reads="<<d.reads<<" writes="<<d.writes<<" status="<<int(d.status)<<std::endl;
  d.done_ready=1;tick();d.done_ready=0;
  return Bytes(mem.begin()+OB,mem.begin()+OB+outbytes);
 }
};
static int32_t scale(int32_t x,int32_t m,int shift){
 int64_t p=int64_t(x)*m;int64_t n=p>=0?(1LL<<30):1-(1LL<<30);
 int32_t h=(p+n)/(1LL<<31);uint32_t mask=(uint64_t(1)<<shift)-1;
 return (h>>shift)+((uint32_t(h)&mask)>((mask>>1)+(h<0)));
}
int main(int argc,char**argv){
 try{
  Verilated::commandArgs(argc,argv);
  if(argc<2)throw std::runtime_error("usage: layer_sim FIXTURE_DIRECTORY [op_NN|all|graph]");
  std::string root=argv[1],mode=argc>2?argv[2]:"op_03";
  Runner r;std::ifstream graph(root+"/graph.txt");if(!graph)throw std::runtime_error("graph missing");
  Bytes current=read_file(root+"/input.bin"),softmax=read_file(root+"/softmax.bin");
  std::string line;uint32_t id=0;int jobs=0;
  while(std::getline(graph,line)){
   std::istringstream ss(line);std::string name,stem;ss>>name>>stem;std::vector<int> p;int v;while(ss>>v)p.push_back(v);
   bool conv=name=="CONV_2D"||name=="DEPTHWISE_CONV_2D";
   if(mode!="graph"&&(!conv||(mode!="all"&&stem!=mode)))continue;
   Bytes expected=read_file(root+"/"+stem+"_expected.bin");
   if(conv){
    auto input=mode=="graph"?current:read_file(root+"/"+stem+"_input.bin");
    if(mode=="graph")equal(input,read_file(root+"/"+stem+"_input.bin"),stem+" chained input");
    auto w=read_file(root+"/"+stem+"_weights.bin"),par=read_file(root+"/"+stem+"_params.bin");
    std::cout<<stem<<std::flush;current=r.run(p,input,w,par,++id);equal(current,expected,stem);jobs++;
    if(mode!="graph"&&mode!="all"){
     auto accepted=r.accepted;r.inject=accepted+7;r.run(p,input,w,par,++id,-1,2);r.inject=-1;
     r.run(p,input,w,par,++id,27,3);
     current=r.run(p,input,w,par,++id);equal(current,expected,stem+" after faults");
     auto invalid=p;invalid[2]=0;r.run(invalid,input,w,par,++id,-1,1);
    }
   }else if(name=="QUANTIZE")for(auto&x:current)x=uint8_t(int(x)+p[0]);
   else if(name=="RESHAPE"){}
   else if(name=="PAD"){
    int h=p[0],w=p[1],c=p[2],top=p[3],bottom=p[4],left=p[5],right=p[6];
    Bytes y(size_t(h+top+bottom)*(w+left+right)*c,uint8_t(p[7]));
    for(int row=0;row<h;row++)std::copy(current.begin()+row*w*c,current.begin()+(row+1)*w*c,y.begin()+((row+top)*(w+left+right)+left)*c);current=std::move(y);
   }else if(name=="MEAN"){
    Bytes y(p[0]);for(int c=0;c<p[0];c++){int32_t sum=0;for(int i=0;i<p[1];i++)sum+=int8_t(current[i*p[0]+c])-p[2];y[c]=uint8_t(std::min(127,std::max(-128,scale(sum,p[4],p[5])+p[3])));}current=std::move(y);
   }else if(name=="SOFTMAX"){
    int index=int(int8_t(current[0]))-int(int8_t(current[1]))+255;current={softmax[index*2],softmax[index*2+1]};
   }else throw std::runtime_error("unsupported step");
   equal(current,expected,stem+" output");
  }
  if(!jobs)throw std::runtime_error("no layer selected");
  std::cout<<"LAYER_SIM_PASS mode="<<mode<<" layers="<<jobs<<" total_cycles="<<r.ticks;
  if(mode=="graph")std::cout<<" scores="<<int(current[0])<<","<<int(current[1]);
  std::cout<<std::endl;
 }catch(const std::exception&e){std::cerr<<"LAYER_SIM_FAIL "<<e.what()<<std::endl;return 1;}
}
