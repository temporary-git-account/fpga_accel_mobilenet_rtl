struct Runner{
 Vaccelerator_top d;Bytes mem=Bytes(16*1024*1024);uint64_t ticks=0,accepted=0;
 uint32_t rng=17,ra=0,wa=0;uint64_t wd=0;uint8_t ws=0;int beat=0;
 bool reading=false,aw=false,w=false,b=false,re=false,we=false,r_offer=false;long inject=-1;
 bool ca=false,cw=false,cb=false,cr=false,cd=false;uint32_t rd=0;uint8_t br=0,rr=0;
 bool ar_hold=false,aw_hold=false,w_hold=false,br_hold=false,rd_hold=false;
 uint64_t old_ar=0,old_aw=0,old_w=0,old_rd=0;uint8_t old_ws=0,old_br=0;
 static void stable(bool held,bool valid,uint64_t old_value,uint64_t value,const char*channel){if(held&&(!valid||old_value!=value))throw std::runtime_error(std::string("unstable backpressured ")+channel);}
 static constexpr uint32_t IB=0x1000,WB=0x200000,PB=0x600000,OB=0x700000;
 Runner(){d.resetn=0;d.s_axi_awvalid=d.s_axi_wvalid=d.s_axi_arvalid=0;d.s_axi_bready=d.s_axi_rready=0;for(int i=0;i<8;i++)tick();d.resetn=1;tick();}
 uint32_t word(uint32_t a){if(a+4>mem.size())throw std::runtime_error("AXI read outside arena");return uint32_t(mem[a])|(uint32_t(mem[a+1])<<8)|(uint32_t(mem[a+2])<<16)|(uint32_t(mem[a+3])<<24);}
 void tick(){
  rng=rng*1664525+1013904223;d.clk=0;
  d.m_axi_arready=!reading&&(rng&3)!=0;d.m_axi_awready=!aw&&(rng&4)!=0;d.m_axi_wready=!w&&(rng&8)!=0;
  d.m_axi_rvalid=reading&&(r_offer||(rng&16)!=0);d.m_axi_rlast=beat==1;d.m_axi_rresp=re?2:0;
  uint32_t a=ra+beat*8;d.m_axi_rdata=uint64_t(word(a))|(uint64_t(word(a+4))<<32);
  d.m_axi_bvalid=b;d.m_axi_bresp=we?2:0;d.eval();
  uint64_t ar_meta=d.m_axi_araddr|(uint64_t(d.m_axi_arlen)<<32)|(uint64_t(d.m_axi_arsize)<<40)|(uint64_t(d.m_axi_arburst)<<43);
  uint64_t aw_meta=d.m_axi_awaddr|(uint64_t(d.m_axi_awlen)<<32)|(uint64_t(d.m_axi_awsize)<<40)|(uint64_t(d.m_axi_awburst)<<43);
  uint64_t rd_meta=d.s_axi_rdata|(uint64_t(d.s_axi_rresp)<<32);
  stable(ar_hold,d.m_axi_arvalid,old_ar,ar_meta,"AR");stable(aw_hold,d.m_axi_awvalid,old_aw,aw_meta,"AW");
  stable(w_hold,d.m_axi_wvalid,old_w,d.m_axi_wdata,"W data");stable(w_hold,d.m_axi_wvalid,old_ws,d.m_axi_wstrb,"W strobe");
  stable(br_hold,d.s_axi_bvalid,old_br,d.s_axi_bresp,"AXIL B");stable(rd_hold,d.s_axi_rvalid,old_rd,rd_meta,"AXIL R");
  ar_hold=d.m_axi_arvalid&&!d.m_axi_arready;aw_hold=d.m_axi_awvalid&&!d.m_axi_awready;w_hold=d.m_axi_wvalid&&!d.m_axi_wready;
  br_hold=d.s_axi_bvalid&&!d.s_axi_bready;rd_hold=d.s_axi_rvalid&&!d.s_axi_rready;
  old_ar=ar_meta;old_aw=aw_meta;old_w=d.m_axi_wdata;old_ws=d.m_axi_wstrb;old_br=d.s_axi_bresp;old_rd=rd_meta;
  r_offer=d.m_axi_rvalid&&!d.m_axi_rready;
  ca=d.s_axi_awvalid&&d.s_axi_awready;cw=d.s_axi_wvalid&&d.s_axi_wready;
  cb=d.s_axi_bvalid&&d.s_axi_bready;br=d.s_axi_bresp;
  cr=d.s_axi_arvalid&&d.s_axi_arready;cd=d.s_axi_rvalid&&d.s_axi_rready;rd=d.s_axi_rdata;rr=d.s_axi_rresp;
  bool ar=d.m_axi_arvalid&&d.m_axi_arready,r=d.m_axi_rvalid&&d.m_axi_rready;
  bool aa=d.m_axi_awvalid&&d.m_axi_awready,ww=d.m_axi_wvalid&&d.m_axi_wready,bb=d.m_axi_bvalid&&d.m_axi_bready;
  if(ar){if(d.m_axi_arlen!=1||(d.m_axi_araddr&15)||((d.m_axi_araddr&4095)+16>4096))throw std::runtime_error("AXI burst boundary");ra=d.m_axi_araddr;re=inject>=0&&accepted==uint64_t(inject);accepted++;}
  if(aa){if(d.m_axi_awlen||(d.m_axi_awaddr&7))throw std::runtime_error("AXI write alignment");wa=d.m_axi_awaddr;we=inject>=0&&accepted==uint64_t(inject);accepted++;}
  if(ww){wd=d.m_axi_wdata;ws=d.m_axi_wstrb;if(!d.m_axi_wlast)throw std::runtime_error("WLAST");}
  d.clk=1;d.eval();ticks++;
  if(r){if(beat==1)reading=false;else beat++;}if(ar){reading=true;beat=0;}
  if(bb){b=false;aw=w=false;}if(aa)aw=true;if(ww)w=true;
  if(aw&&w&&!b){if(wa+8>mem.size())throw std::runtime_error("AXI write outside arena");if(!we)for(int j=0;j<8;j++)if(ws&(1<<j))mem[wa+j]=wd>>(8*j);b=true;}
 }
 void wr(uint32_t address,uint32_t value,int expected=0,uint8_t mask=15){
  bool aa=false,ww=false;unsigned t=0;
  d.s_axi_awaddr=address;d.s_axi_wdata=value;d.s_axi_wstrb=mask;
  do{
   // Alternate independent channel ordering and delay the response consumer.
   d.s_axi_awvalid=!aa&&(t>unsigned(value&3));d.s_axi_wvalid=!ww&&(t>unsigned((value>>2)&3));
   d.s_axi_bready=t>10;tick();aa|=ca;ww|=cw;if(++t>1000)throw std::runtime_error("AXIL write timeout");
  }while(!cb);
  d.s_axi_awvalid=d.s_axi_wvalid=d.s_axi_bready=0;
  if(br!=expected)throw std::runtime_error("AXIL write response "+std::to_string(address)+" got "+std::to_string(br));
 }
 uint32_t read(uint32_t address,int expected=0){
  d.s_axi_araddr=address;d.s_axi_arvalid=1;unsigned t=0;
  do{tick();if(++t>1000)throw std::runtime_error("AXIL read address timeout");}while(!cr);
  d.s_axi_arvalid=0;d.s_axi_rready=0;
  for(int i=0;i<4;i++)tick();d.s_axi_rready=1;
  do{tick();if(++t>1000)throw std::runtime_error("AXIL read data timeout");}while(!cd);
  d.s_axi_rready=0;if(rr!=expected)throw std::runtime_error("AXIL read response");return rd;
 }
 void csr_checks(){
  if(read(4)!=0x49414331||read(0)!=0)throw std::runtime_error("reset identity");
  wr(32,0x11223344);wr(32,0xaabbccdd,0,5);
  if(read(32)!=0x11bb33dd)throw std::runtime_error("CSR byte strobes");
  wr(32,0xffffffff,0,0);if(read(32)!=0x11bb33dd)throw std::runtime_error("zero CSR strobe");
  wr(33,0,2);wr(4,0,2);wr(80,0,2);read(33,2);read(80,2);
  wr(0,1,2,0);wr(0,3,2);wr(0,2,2);wr(0,4,2);
  if(read(0)!=0)throw std::runtime_error("invalid command changed state");
 }
 Bytes run(const std::vector<int>&p,const Bytes&input,const Bytes&weights,const Bytes&params,uint32_t id,long cancel_at=-1,int expected_status=0){
  std::fill(mem.begin(),mem.end(),0xa5);std::copy(input.begin(),input.end(),mem.begin()+IB);std::copy(weights.begin(),weights.end(),mem.begin()+WB);std::copy(params.begin(),params.end(),mem.begin()+PB);
  size_t outbytes=size_t(p[3])*p[4]*p[5];
  if(read(4)!=0x49414331||read(0)!=0)throw std::runtime_error("identity or idle state");
  wr(32,id);wr(36,IB);wr(40,WB);wr(44,PB);wr(48,OB);wr(52,0x1000);wr(56,mem.size());
  wr(60,uint32_t(p[0])|(uint32_t(p[1])<<16));wr(64,uint32_t(p[2])|(uint32_t(p[3])<<16));wr(68,uint32_t(p[4])|(uint32_t(p[5])<<16));
  wr(72,p[6]|(p[7]<<2)|(p[8]<<4)|(p[9]<<6)|(p[10]<<8));
  wr(76,uint8_t(p[11])|(uint32_t(uint8_t(p[12]))<<8)|(uint32_t(uint8_t(p[13]))<<16)|(uint32_t(uint8_t(p[14]))<<24));
  wr(0,1);uint64_t start=ticks;bool cancelled=false;
  if(expected_status==0){wr(32,123,2);wr(0,1,2);wr(0,4,2);}
  while(!(read(0)&2)){
   if(cancel_at>=0&&!cancelled&&ticks-start>=uint64_t(cancel_at)){wr(0,2);cancelled=true;}
   for(int i=0;i<64;i++)tick();if(ticks-start>1500000000ULL)throw std::runtime_error("layer timeout");
  }
  if(read(8)!=id||read(12)!=uint32_t(expected_status)||reading||aw||w||b)throw std::runtime_error("completion mismatch/drain: "+std::to_string(read(12)));
  auto writes=read(24);for(int i=0;i<10;i++)tick();if(!(read(0)&2)||read(8)!=id||read(24)!=writes)throw std::runtime_error("stale/unstable completion");
  for(size_t i=OB+outbytes;i<OB+outbytes+16;i++)if(mem[i]!=0xa5)throw std::runtime_error("output overrun");
  if(mem[OB-1]!=0xa5)throw std::runtime_error("output underrun");
  std::cout<<" job="<<id<<" cycles="<<read(16)<<" reads="<<read(20)<<" writes="<<writes<<" status="<<read(12)<<std::endl;
  wr(0,4);return Bytes(mem.begin()+OB,mem.begin()+OB+outbytes);
 }
};
