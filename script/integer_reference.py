#!/usr/bin/env python3
"""Frozen-model integer reference. Inference requires NumPy, not TensorFlow.

Quantization follows TFLite 2.15's double-rounding integer reference. The
specification exporter rejects unsupported shapes/options rather than approximating.
"""
import hashlib
import json
from pathlib import Path
import numpy as np


def multiply(x, multiplier, right_shift):
    x = np.asarray(x, dtype=np.int64)
    m = np.asarray(multiplier, dtype=np.int64)
    s = np.asarray(right_shift, dtype=np.int64)
    if np.any(x < -(1 << 31)) or np.any(x >= (1 << 31)):
        raise OverflowError('accumulator outside int32')
    if np.any(m <= 0) or np.any(m >= (1 << 31)) or np.any(s < 0) or np.any(s > 31):
        raise ValueError('requires positive Q31 multiplier and right shift 0..31')
    # Positive multiplier: saturating high-multiply overflow cannot occur.
    high = (x * m + (1 << 30)) >> 31
    mask = (np.int64(1) << s) - 1
    return (high >> s) + ((high & mask) > ((mask >> 1) + (high < 0)))


def requantize(raw, bias, multiplier, shift, zero, low=-128, high=127):
    return np.clip(multiply(raw + bias, multiplier, shift) + zero, low, high).astype(np.int8)


class Reference:
    def __init__(self, directory):
        root = Path(directory)
        self.spec = json.loads((root / 'model_spec.json').read_text())
        for filename, expected_hash in self.spec['artifacts'].items():
            if hashlib.sha256((root / filename).read_bytes()).hexdigest() != expected_hash:
                raise ValueError(f'corrupt or mismatched reference artifact: {filename}')
        self.constants = dict(np.load(root / 'model_constants.npz'))
        self.softmax = np.load(root / 'softmax_lut.npy')

    def run(self, image, check=None, capture=None):
        c = self.spec
        if image.dtype != np.uint8 or list(image.shape) != c['input_shape']:
            raise ValueError('expected tight NHWC uint8 [1,224,224,3]')
        tensors = {c['input']: image}
        for op in c['operators']:
            name = op['name']
            x = tensors[op['input']]
            if name == 'QUANTIZE':
                y = (x.astype(np.int16) + op['offset']).astype(op['dtype'])
            elif name == 'PAD':
                y = np.pad(x, op['padding'], constant_values=op['zero'])
            elif name in ('CONV_2D', 'DEPTHWISE_CONV_2D'):
                w = self.constants[op['weights']].astype(np.int64)
                bias = self.constants[op['bias']].astype(np.int64)
                z = x.astype(np.int64) - op['input_zero']
                n, oh, ow, oc = op['output_shape']
                kh, kw = op['kernel']
                sh, sw = op['stride']
                top, bottom, left, right = op['pad']
                z = np.pad(z, ((0, 0), (top, bottom), (left, right), (0, 0)))
                raw = np.zeros((n, oh, ow, oc), dtype=np.int64)
                for h in range(kh):
                    for k in range(kw):
                        patch = z[:, h:h + oh * sh:sh, k:k + ow * sw:sw, :]
                        if name == 'CONV_2D':
                            raw += (patch.reshape(-1, patch.shape[-1]) @ w[:, h, k, :].T).reshape(raw.shape)
                        else:
                            raw += patch * w[0, h, k, :]
                y = requantize(raw, bias, op['multiplier'], op['right_shift'],
                               op['output_zero'], op['activation_min'], op['activation_max'])
                if capture is not None:
                    capture(op, raw, y)
            elif name == 'MEAN':
                raw = (x.astype(np.int64) - op['input_zero']).sum(axis=tuple(op['axes']), keepdims=True)
                y = requantize(raw, 0, op['multiplier'], op['right_shift'], op['output_zero'])
            elif name == 'RESHAPE':
                y = x.reshape(op['output_shape'])
            elif name == 'SOFTMAX':
                diff = x[..., 0].astype(np.int16) - x[..., 1].astype(np.int16)
                y = self.softmax[diff + 255]
            else:
                raise ValueError(name)
            if list(y.shape) != op['output_shape']:
                raise ValueError(f"bad shape at op {op['index']}: {y.shape}")
            if check is not None:
                check(op, y)
            tensors[op['output']] = y
            # Linear graph: release the previous activation after verification.
            if op['input'] != op['output']:
                tensors.pop(op['input'])
        return tensors[c['output']]
