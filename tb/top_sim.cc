#include "Vaccelerator_top.h"
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
#include "top_runner.hpp"
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
  Runner r;if(mode=="csr"){r.csr_checks();std::cout<<"CSR_PASS byte strobes/invalid offsets/commands/reset identity"<<std::endl;return 0;}
  std::ifstream graph(root+"/graph.txt");if(!graph)throw std::runtime_error("graph missing");
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
  std::cout<<"TOP_SIM_PASS mode="<<mode<<" layers="<<jobs<<" total_cycles="<<r.ticks;
  if(mode=="graph")std::cout<<" scores="<<int(current[0])<<","<<int(current[1]);
  std::cout<<std::endl;
 }catch(const std::exception&e){std::cerr<<"TOP_SIM_FAIL "<<e.what()<<std::endl;return 1;}
}
