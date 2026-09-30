#!/usr/bin/env python3
"""Summarize per-layer cycles and phase breakdown from the check.sh logs."""
import re,sys,pathlib
logs=pathlib.Path(sys.argv[1])
row=re.compile(r'^(op_\d+) job=(\d+) cycles=(\d+) reads=(\d+) writes=(\d+) status=0 phases\[(.*)\]')
print('| layer | cycles | reads | writes | w | p | a | mac | q | o | memwait |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for name in ['shapes.log','head-faults.log']:
    f=logs/name
    if not f.exists():continue
    for line in f.read_text().splitlines():
        m=row.match(line)
        if not m:continue
        ph=dict(kv.split('=') for kv in m.group(6).split(','))
        print(f"| {m.group(1)} | {m.group(3)} | {m.group(4)} | {m.group(5)} | {ph['w']} | {ph['p']} | {ph['a']} | {ph['mac']} | {ph['q']} | {ph['o']} | {ph['memwait']} |")
