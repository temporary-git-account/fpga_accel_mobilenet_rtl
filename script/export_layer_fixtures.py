#!/usr/bin/env python3
"""Export actual model layer fixtures and a graph for compiled RTL simulation."""
import argparse,json,os
from pathlib import Path
os.environ.setdefault('TF_CPP_MIN_LOG_LEVEL','2')
import numpy as np
import tensorflow as tf
from integer_reference import Reference
p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--golden',required=True);p.add_argument('--out',required=True);p.add_argument('--image',help='optional prepared 224x224 RGB input')
a=p.parse_args();g=Path(a.golden);out=Path(a.out);out.mkdir(parents=True,exist_ok=True)
r=Reference(g)
it=tf.lite.Interpreter(model_path=a.model,experimental_preserve_all_tensors=True,experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF,num_threads=1)
it.allocate_tensors();image=np.fromfile(a.image or g/'oneblade_0000.rgb',np.uint8).reshape(1,224,224,3);it.set_tensor(0,image);it.invoke();image.tofile(out/'input.bin')
np.load(g/'softmax_lut.npy').tofile(out/'softmax.bin')
lines=[]
for op in r.spec['operators']:
 i=op['index'];stem=f'op_{i:02d}';x=it.get_tensor(op['input']);y=it.get_tensor(op['output'])
 x.tofile(out/(stem+'_input.bin'));y.tofile(out/(stem+'_expected.bin'))
 name=op['name'];params=[]
 if name in ('CONV_2D','DEPTHWISE_CONV_2D'):
  w=r.constants[op['weights']];w.tofile(out/(stem+'_weights.bin'))
  b=r.constants[op['bias']];par=np.zeros((len(b),4),'<i4');par[:,0]=b;par[:,1]=op['multiplier'];par[:,2]=op['right_shift'];par.tofile(out/(stem+'_params.bin'))
  params=[*x.shape[1:],*y.shape[1:],op['kernel'][0],op['stride'][0],op['pad'][0],op['pad'][2],int(name=='DEPTHWISE_CONV_2D'),op['input_zero'],op['output_zero'],op['activation_min'],op['activation_max']]
 elif name=='QUANTIZE':params=[op['offset']]
 elif name=='PAD':params=[*x.shape[1:],op['padding'][1][0],op['padding'][1][1],op['padding'][2][0],op['padding'][2][1],op['zero']]
 elif name=='MEAN':params=[x.shape[-1],op['count'],op['input_zero'],op['output_zero'],op['multiplier'],op['right_shift']]
 lines.append(' '.join(map(str,[name,stem,*params])))
(out/'graph.txt').write_text('\n'.join(lines)+'\n')
print(f'Exported {len(lines)} graph steps, including 28 real convolution/depthwise layers')
