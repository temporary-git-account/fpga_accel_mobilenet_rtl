#!/usr/bin/env python3
"""Small awkward shapes, checked with a scalar integer convolution oracle."""
import argparse,pathlib,random,struct
p=argparse.ArgumentParser();p.add_argument('--out',required=True);a=p.parse_args();out=pathlib.Path(a.out);out.mkdir(parents=True,exist_ok=True)
r=random.Random(9183);lines=[]
def scale(x,m,s):
 p=x*m;n=(1<<30) if p>=0 else 1-(1<<30)
 h=(abs(p+n)//(1<<31))*(-1 if p+n<0 else 1);mask=(1<<s)-1
 return (h>>s)+((h&mask)>((mask>>1)+(h<0)))
# IH IW IC OH OW OC K S PT PL DW IZ OZ MIN MAX
shapes=[
 [1,1,1,1,1,1,1,1,0,0,0,-128,127,-128,127],
 [3,5,3,3,5,5,1,1,0,0,0,127,-128,-128,127],
 [4,6,9,4,6,13,1,1,0,0,0,-13,7,-83,91],
 [5,7,3,3,4,9,3,2,1,1,0,-128,-5,-128,127],
 [2,3,3,3,5,5,3,1,2,3,0,19,11,-57,62],
 [5,7,5,3,4,5,3,2,1,0,1,-17,-9,-128,127],
 [2,3,9,3,5,9,3,1,2,3,1,127,127,-128,127],
 [3,5,13,3,5,13,1,1,0,0,1,-128,-128,-128,127],
 [1,7,17,1,7,17,3,1,1,1,1,0,0,-73,112],
 [1,1,1024,1,1,9,1,1,0,0,0,-128,0,-128,127],
]
for i,p in enumerate(shapes):
 ih,iw,ic,oh,ow,oc,k,s,pt,pl,dw,iz,oz,lo,hi=p
 x=[r.randrange(-128,128) for _ in range(ih*iw*ic)]
 w=[r.randrange(-128,128) for _ in range(k*k*(1 if dw else ic)*oc)]
 par=[(r.randrange(-2000,2001),r.randrange(1<<29,1<<31),r.randrange(0,12),0) for _ in range(oc)]
 y=[]
 for yy in range(oh):
  for xx in range(ow):
   for c in range(oc):
    b,m,shift,_=par[c];acc=b
    for ky in range(k):
     for kx in range(k):
      sy=yy*s+ky-pt;sx=xx*s+kx-pl
      if not (0<=sy<ih and 0<=sx<iw):continue
      for ci in ([c] if dw else range(ic)):
       wi=(ky*k+kx)*oc+c if dw else ((c*k+ky)*k+kx)*ic+ci
       acc+=(x[(sy*iw+sx)*ic+ci]-iz)*w[wi]
    y.append(max(lo,min(hi,scale(acc,m,shift)+oz)))
 stem=f'op_{i:02d}'
 for name,values in [('input',x),('weights',w),('expected',y)]: (out/f'{stem}_{name}.bin').write_bytes(bytes(v&255 for v in values))
 (out/f'{stem}_params.bin').write_bytes(b''.join(struct.pack('<iIII',*v) for v in par))
 lines.append(' '.join(map(str,['DEPTHWISE_CONV_2D' if dw else 'CONV_2D',stem,*p])))
(out/'graph.txt').write_text('\n'.join(lines)+'\n');(out/'input.bin').write_bytes(b'');(out/'softmax.bin').write_bytes(b'')
print('SHAPE_FIXTURES',len(shapes))
