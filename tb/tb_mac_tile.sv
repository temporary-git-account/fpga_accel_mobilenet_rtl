`timescale 1ns/1ps
module tb_mac_tile;
    logic clk=0,rst=1,iv=0,first=0,last=0,ready,ov,oready=1;
    logic [35:0] a=0;logic [63:0] w=0;wire [1023:0] result;
    always #2 clk=~clk;
    mac_tile dut(clk,rst,iv,first,last,ready,a,w,ov,oready,result);
    integer expected[0:127][0:31];integer running[0:31];
    integer sent=0,received=0,cycles=0;
    logic [35:0] real_a[32];logic [63:0] real_w[32];logic [31:0] real_expected[32];
    logic [1023:0] held;logic stalled=0;
    always @(posedge clk)begin
        if(rst)begin sent=0;received=0;stalled=0;end
        else begin
            if(stalled && (!ov || result!==held))$fatal(1,"output changed during backpressure");
            stalled=ov&&!oready;held=result;
            if(ov&&oready)begin
                if(received>=sent)$fatal(1,"unexpected output");
                for(integer q=0;q<32;q=q+1)
                    if($signed(result[q*32+:32])!==expected[received][q])
                        $fatal(1,"vector %0d lane %0d got %0d expected %0d",received,q,$signed(result[q*32+:32]),expected[received][q]);
                if(received==64)for(integer q=0;q<32;q=q+1)
                    if(result[q*32+:32]!==real_expected[q])$fatal(1,"MobileNet reference mismatch lane %0d",q);
                received=received+1;
            end
            if(iv&&ready)begin
                for(integer i=0;i<4;i=i+1)for(integer j=0;j<8;j=j+1)begin
                    if(first)running[i*8+j]=0;
                    running[i*8+j]=running[i*8+j]+$signed(a[i*9+:9])*$signed(w[j*8+:8]);
                    if(last)expected[sent][i*8+j]=running[i*8+j];
                end
                if(last)sent=sent+1;
            end
        end
        cycles=cycles+1;if(cycles>100000)$fatal(1,"timeout");
    end
    task automatic term(input integer n,input integer k,input integer len);
        @(negedge clk);
        iv=1;first=k==0;last=k==len-1;
        for(integer i=0;i<4;i=i+1)a[i*9+:9]=(n==0?-255:n==1?255:$urandom_range(0,510)-255);
        for(integer j=0;j<8;j=j+1)w[j*8+:8]=(n==0?-128:n==1?127:$urandom_range(0,255)-128);
        oready=$urandom_range(0,3)!=0;
        @(posedge clk);
        while(!ready)begin @(negedge clk);oready=$urandom_range(0,3)!=0;@(posedge clk);end
    endtask
    initial begin
        $readmemh("../../golden/mac_activations.hex",real_a);
        $readmemh("../../golden/mac_weights.hex",real_w);
        $readmemh("../../golden/mac_expected.hex",real_expected);
        repeat(4)@(negedge clk);rst=0;
        // Abort an incomplete vector and verify no stale pipeline output.
        term(0,0,20);@(negedge clk);iv=0;rst=1;
        repeat(4)@(negedge clk);rst=0;
        for(integer n=0;n<64;n=n+1)begin
            integer len;len=n<2?1024:n<6?n-1:$urandom_range(1,128);
            for(integer k=0;k<len;k=k+1)begin
                term(n,k,len);
                if($urandom_range(0,5)==0)begin @(negedge clk);iv=0;oready=1;end
            end
        end
        for(integer k=0;k<32;k=k+1)begin
            @(negedge clk);iv=1;first=k==0;last=k==31;a=real_a[k];w=real_w[k];oready=1;
            @(posedge clk);while(!ready)@(posedge clk);
        end
        @(negedge clk);iv=0;oready=1;
        wait(received==65);repeat(5)@(negedge clk);
        if(sent!=received)$fatal(1,"missing output");
        $display("MAC_TILE_PASS vectors=%0d lanes=32 cycles=%0d",received,cycles);$finish;
    end
endmodule
