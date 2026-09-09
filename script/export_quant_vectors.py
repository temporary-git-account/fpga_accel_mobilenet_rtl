#!/usr/bin/env python3
"""C++ gemmlowp oracle vs NumPy vs TFLite layer data; export XSim vectors."""
import argparse
import json
from pathlib import Path
import subprocess
import numpy as np
from integer_reference import requantize

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--golden', required=True)
p.add_argument('--oracle', required=True)
a = p.parse_args()
g = Path(a.golden)
actual = np.load(g / 'quant_model_cases.npy')
rows = actual[:, :7].tolist()
model_count = len(rows)
rng = np.random.default_rng(914)
for _ in range(6000):
    rows.append([int(rng.integers(-(1 << 31), 1 << 31)), 0, int(rng.integers(1, 1 << 31)),
                 int(rng.integers(0, 32)), int(rng.integers(-128, 128)), -128, 127])
for shift in range(32):
    for value in [-(1 << 31), -(1 << 31) + 1, -65537, -257, -255, -3, -1, 0, 1, 3, 255, 257, 65537, (1 << 31) - 1]:
        for multiplier in [1, (1 << 30), (1 << 30) + 1, (1 << 31) - 1]:
            rows.append([value, 0, multiplier, shift, -3, -128, 127])
    # Construct both signs at, just below, and just above second-stage ties.
    if shift < 29:
        for sign in [-1, 1]:
            for delta in [-1, 0, 1]:
                rows.append([sign * ((3 << (shift + 1)) + (1 << shift)) + delta,
                             0, 1 << 30, shift, 0, -128, 127])
# Wide zero-point addition must clamp before narrowing; opposite-sign bias
# operands must not be rejected merely because either operand is extreme.
rows += [[(1 << 31) - 1, 0, (1 << 31) - 1, 0, 127, -128, 127],
         [-(1 << 31), 0, (1 << 31) - 1, 0, -128, -128, 127],
         [(1 << 31) - 1, -(1 << 31), 1 << 30, 0, 0, -128, 127],
         [-(1 << 31), (1 << 31) - 1, 1 << 30, 0, 0, -128, 127],
         [1, (1 << 31) - 2, (1 << 31) - 1, 0, 127, -128, 127],
         [-1, -(1 << 31) + 1, (1 << 31) - 1, 0, -128, -128, 127]]
rows += [[(1 << 31) - 1, 1, 1 << 30, 0, 0, -128, 127],
         [-(1 << 31), -1, 1 << 30, 0, 0, -128, 127],
         [123, 0, 0, 0, 0, -128, 127], [123, 0, 1 << 31, 0, 0, -128, 127],
         [123, 0, 1 << 30, 0, 0, 127, -128]]
text = ''.join(' '.join(map(str, row)) + '\n' for row in rows)
r = subprocess.run([a.oracle], input=text, text=True, capture_output=True, check=True)
expected = np.array([list(map(int, line.split())) for line in r.stdout.splitlines()], np.int64)
assert expected.shape == (len(rows), 2)
assert np.array_equal(expected[:model_count], actual[:, 7:]), 'C++ vs TFLite layer vectors mismatch'
for row, (value, fault) in zip(rows, expected):
    if not fault:
        assert int(requantize(np.int64(row[0]), *row[1:])) == value, (row, value)
with (g / 'quant_cases.hex').open('w') as f:
    for row, pair in zip(rows, expected):
        f.write(''.join(f'{int(v) & 0xffffffff:08x}' for v in row + pair.tolist()) + '\n')
(g / 'quant_cases.svh').write_text(f'localparam integer QUANT_CASES = {len(rows)};\n')
meta = dict(cases=len(rows), tflite_layer_cases=model_count, fault_cases=int(expected[:, 1].sum()),
            oracle='gemmlowp scalar SaturatingRoundingDoublingHighMul + RoundingDivideByPOT', seed=914)
(g / 'quant_cases.json').write_text(json.dumps(meta, indent=2) + '\n')
# Real MAC result -> bias -> requantization expected directly from TFLite.
v = json.loads((g / 'pointwise_quant_vector.json').read_text())
op = v['op']
with (g / 'pointwise_quant.hex').open('w') as f:
    for pixel in range(4):
        for ch in range(8):
            row = [v['raw'][pixel][ch], v['bias'][ch], op['multiplier'][ch], op['right_shift'][ch],
                   op['output_zero'], op['activation_min'], op['activation_max'], v['expected'][pixel][ch], 0]
            f.write(''.join(f'{x & 0xffffffff:08x}' for x in row) + '\n')
print(json.dumps(meta))
