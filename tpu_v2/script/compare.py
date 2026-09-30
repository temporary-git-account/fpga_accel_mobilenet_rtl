#!/usr/bin/env python3
"""Compare per-layer cycles between two runs. usage: compare.py OLD.log NEW.log [OLD_head.log NEW_head.log]"""
import re,sys
row=re.compile(r'^(op_\d+) job=(\d+) cycles=(\d+) reads=(\d+) writes=(\d+) status=0')
def load(path):
    out={}
    for line in open(path):
        m=row.match(line)
        if m and m.group(1) not in out:out[m.group(1)]=tuple(int(m.group(i)) for i in (3,4,5))
    return out
old=load(sys.argv[1]);new=load(sys.argv[2])
if len(sys.argv)>4:old.update(load(sys.argv[3]));new.update(load(sys.argv[4]))
print('| layer | v1 cycles | v2 cycles | speedup | v1 reads | v2 reads | v1 writes | v2 writes |')
print('|---|---|---|---|---|---|---|---|')
to=tn=0
for k in sorted(set(old)&set(new)):
    o,n=old[k],new[k];to+=o[0];tn+=n[0]
    print(f'| {k} | {o[0]} | {n[0]} | {o[0]/n[0]:.2f}x | {o[1]} | {n[1]} | {o[2]} | {n[2]} |')
print(f'| total | {to} | {tn} | {to/tn:.2f}x | | | | |')
