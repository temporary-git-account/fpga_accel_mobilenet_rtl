'use strict';
const $=id=>document.getElementById(id);
function calculateQuant(v,b,m,s,z,lo,hi){
 const min=-(1n<<31n),max=(1n<<31n)-1n;
 if(v<min||v>max||b<min||b>max)throw Error('Accumulator and bias must each fit signed int32.');
 if(m<=0n||m>max)throw Error('Multiplier must be positive signed Q31 (1…2147483647).');
 if(s<0n||s>31n)throw Error('Right shift must be 0…31.');
 if(z< -128n||z>127n||lo< -128n||hi>127n||lo>hi)throw Error('Zero point and ordered clamp interval must fit signed int8.');
 const biased=v+b;if(biased<min||biased>max)throw Error('Bias addition overflows int32: RTL reports an error.');
 const product=biased*m, high=(product+(1n<<30n))>>31n,mask=(1n<<s)-1n;
 const base=high>>s,rem=high&mask,threshold=(mask>>1n)+(high<0n?1n:0n),round=rem>threshold?1n:0n;
 const shifted=base+round,offset=shifted+z,result=offset<lo?lo:offset>hi?hi:offset;
 return {biased,product,high,base,rem,threshold,round,shifted,offset,result};
}
function showQuant(){try{const r=calculateQuant(...['qacc','qbias','qmult','qshift','qzero','qlo','qhi'].map(id=>BigInt($(id).value)));$('qout').textContent=`biased = ${r.biased}\nproduct = ${r.product}\nhigh Q31 result = ${r.high}\nshift base = ${r.base}; remainder = ${r.rem}; threshold = ${r.threshold}\nround increment = ${r.round}; scaled = ${r.shifted}\nafter zero point = ${r.offset}; clamped int8 = ${r.result}`;}catch(e){$('qout').textContent=e.message;}}
let selectedLane=0;
function showTile(){const pixels=Number($('tpixels').value),channels=Number($('tchannels').value),dw=$('tmode').value==='dw';
 if(!Number.isInteger(pixels)||pixels<1||pixels>4||!Number.isInteger(channels)||channels<1||channels>8){$('tout').textContent='Enter 1–4 pixels and 1–8 channels.';return;}
 for(let i=0;i<32;i++){const p=Math.floor(i/8),c=i%8,live=p<pixels&&c<channels,el=$('lane'+i);el.className='lane'+(live?'':' off')+(i===selectedLane?' selected':'');el.textContent=`p${p}, c${c}\n${live?'MAC':'masked'}`;el.setAttribute('aria-pressed',i===selectedLane?'true':'false');}
 const p=Math.floor(selectedLane/8),c=selectedLane%8;
 $('tout').textContent=`${pixels*channels}/32 useful output lanes (${(pixels*channels/32*100).toFixed(1)}% tile occupancy)\nSelected p${p},c${c}: sum[${p},${c}] += ${dw?`activation[${p},${c}]`:`activation[${p}]`} × weight[${c}]\n${p>=pixels||c>=channels?'Tail lane: output write suppressed.':dw?'Depthwise: each channel uses its own activation.':'Regular convolution: this activation is shared across eight channels.'}`;
}
function showPerf(){const mhz=Number($('pfreq').value),interval=Number($('pinterval').value),duty=Number($('pduty').value);if(!Number.isFinite(mhz)||mhz<=0||![1,2].includes(interval)||!Number.isFinite(duty)||duty<=0||duty>100){$('pout').textContent='Enter a positive frequency, feed interval 1 or 2, and duty factor above 0 through 100%.';return;}const rate=32*mhz*1e6/interval*duty/100,seconds=567718400/rate;$('pout').textContent=`Assumed useful rate: ${(rate/1e9).toFixed(3)} GMAC/s\nArithmetic-work estimate: ${(seconds*1000).toFixed(1)} ms/image\nAssumes full lanes during feed; duty factor is an input, not a measured utilization.\nThis does not model DDR queueing, quantizer drain, tail tiles or a new timing result.`;}
document.addEventListener('DOMContentLoaded',()=>{
 for(const id of ['qacc','qbias','qmult','qshift','qzero','qlo','qhi'])$(id).addEventListener('input',showQuant);
 $('qtie').addEventListener('click',()=>{$('qacc').value=-3;$('qbias').value=0;$('qmult').value=1073741824;$('qshift').value=1;$('qzero').value=0;showQuant();});
 $('qreset').addEventListener('click',()=>{const vals=[125,3,1073741824,2,-5,-128,127];['qacc','qbias','qmult','qshift','qzero','qlo','qhi'].forEach((id,i)=>$(id).value=vals[i]);showQuant();});
 for(const id of ['tpixels','tchannels','tmode'])$(id).addEventListener('input',showTile);
 for(let i=0;i<32;i++)$('lane'+i).addEventListener('click',()=>{selectedLane=i;showTile();});
 for(const id of ['pfreq','pinterval','pduty'])$(id).addEventListener('input',showPerf);
 $('toc-search').addEventListener('input',()=>{const q=$('toc-search').value.toLowerCase();document.querySelectorAll('nav .toc a').forEach(a=>a.hidden=!a.textContent.toLowerCase().includes(q));});
 $('layer-search').addEventListener('input',()=>{const q=$('layer-search').value.toLowerCase();document.querySelectorAll('#layer-table tbody tr').forEach(row=>row.hidden=!row.textContent.toLowerCase().includes(q));});
 $('print').addEventListener('click',()=>window.print());
 window.addEventListener('scroll',()=>{const h=document.documentElement;const ratio=h.scrollHeight>innerHeight?h.scrollTop/(h.scrollHeight-innerHeight):0;$('progress').style.width=`${ratio*(innerWidth-parseFloat(getComputedStyle($('progress')).left))}px`;},{passive:true});
 showQuant();showTile();showPerf();
});
