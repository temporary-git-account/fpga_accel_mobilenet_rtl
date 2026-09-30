# tpu_v2: faster memory schedule for the MobileNet accelerator

`tpu_v2/` is a self-contained iteration of the v1 accelerator in `../rtl`.
It keeps the v1 job contract (descriptor registers, region checks, status
codes, cancellation, reset rules, AXI interfaces, numerical results) and
replaces the byte-at-a-time memory schedule that made v1 wait on its own
address state machine for most of every layer.

Measured on the v1 quick suite (Verilator 5.020, same fixtures, same random
AXI stalls), cycle counts fall between 1.7x and 8x. `doc/v1-vs-v2.md` has the
full table; the totals for the ten common shapes plus the classifier head:

| | v1 | v2 | speedup |
|---|---|---|---|
| total cycles, 11 layers | 322,466 | 62,814 | 5.13x |
| classifier head (op_33, 1024 channels in, 2 out) | 66,770 | 8,336 | 8.01x |
| 1x1 conv, 1024 channels in, 9 out (op_09) | 171,288 | 28,740 | 5.96x |
| depthwise 3x3 stride 2 (op_05) | 9,069 | 2,461 | 3.69x |

## Layout

```text
rtl/            layer_engine.sv and accelerator_top.sv are new; the other
                four modules are byte-identical copies of ../rtl
tb/             v1 testbenches plus a misaligned-base mode and phase output
script/check.sh one-command regression (Verilator, Icarus when installed)
script/compare.py, cycle_report.py   cycle tables from the logs
doc/            v1 baseline logs and the v1-vs-v2 comparison
Makefile        make check | make full | make lint
```

## What changed in the layer engine

1. **Word-wide traffic.** A request now fetches up to four contiguous bytes.
   For regular convolution the input channels of one kernel tap are contiguous
   in NHWC memory, and so are the weights of one output channel. For depthwise
   layers the eight channels of a group are contiguous for one tap. A small
   unpacker writes the fetched bytes into the activation or weight banks one
   per cycle, tagged with lane and address, while the state machine already
   computes the next request. Output stores pack up to four channels of one
   pixel into a word with exact byte strobes, so unaligned output bases and
   odd channel counts still write only their own bytes.
2. **Continuation inside a run.** Within a contiguous run the next request
   address is `request_address + count`. The multiply, offset and address
   states run once per run instead of once per byte. Parameter words use the
   same path with a fixed stride of four.
3. **Discarded lanes are not loaded.** Weight channels at or beyond
   `output_c` and pixels at or beyond `output_h*output_w` are skipped; their
   bank bytes keep stale data, their MAC lanes compute garbage, their outputs
   are never stored, and a requantizer fault in such a lane is masked. Zero
   padding is still written for source pixels outside the image because those
   lanes feed real outputs. For the classifier head this alone removes six
   padded channels times 1024 terms of zero writes.
4. **One term per cycle into the MAC.** Bank reads are pipelined so the
   address issued in cycle t is data plus valid in cycle t+1. Reads and the
   feed flags advance only when the MAC can accept, so a stall holds the whole
   feed. v1 alternated a read state and a feed state.
5. **Phase counters.** Eight per-job counters classify every busy cycle:
   weight load, parameter load, activation load, MAC feed, requantize, output
   store, memory wait (cycles in the request or response states, a subset of
   the others) and other. They are read-only registers at byte offsets
   0x80 to 0x9C of the AXI-Lite map and are printed by the testbench after
   each job. The v1 map (0x00 to 0x4C) is unchanged.

## What the counters say now

For the classifier head, weight loading is 57 percent of the job and memory
wait is 40 percent; a fetched word costs about nine cycles end to end, three
of them in the engine's own next/continue/check states and the rest in the
one-outstanding request path and the cache's two-beat AXI bursts. The obvious
next steps, in order of expected payoff:

1. Deliver whole 16-byte cache lines to the engine instead of 32-bit words.
   The cache already fetches lines; the unpacker would run for up to sixteen
   cycles per request, which balances against the request round trip.
2. Fold the next, continue and check states into one cycle for the
   continuation path.
3. Allow more than one outstanding read in `axi_memory`, with response
   ordering and the same bounds, timeout and drain rules.
4. Double-buffer the activation banks so the next tile loads during the
   current tile's MAC and requantize phases.

## Verification performed

`make check` (about ten seconds) runs:

- `axi_memory` unit test: random reads and writes, cache hits, strobes,
  4 KiB boundary, error responses, bad RLAST, timeout, drain and reset.
- CSR test: byte strobes, invalid offsets and commands, reset identity.
- 26 shape fixtures against the scalar integer oracle in
  `script/export_shape_fixtures.py`: the ten v1 shapes plus sixteen aimed at
  word packing (one, two, three, five, six, seven, eleven, fifteen and
  seventeen channel counts, runs that cross word boundaries, stride two with
  padding, depthwise with odd channel counts).
- The same 26 shapes at three misaligned base-address combinations
  (input, weight and output bases offset by one to three bytes; the parameter
  block stays 16-byte aligned as the v1 contract requires).
- The real classifier head from `../fixtures/head` with an injected AXI error
  (status 2), cancellation (status 3), recovery, and an invalid descriptor
  (status 1).
- Icarus Verilog 12 on the unchanged arithmetic: 40,815 requantizer cases
  with stalls, gaps, errors and reset; the MAC tile with backpressure and an
  aborted vector; three real model tiles through MAC and requantizer.

## Not verified here

- **Synthesis and timing.** No Vivado run was possible in this environment.
  v1 closed at 166.667 MHz with 0.17 ns of slack, so the new logic was kept to
  one adder or comparator per state, but the MAC-ready gate on the bank read
  registers and the output packing mux are new paths that need a timing
  report before the design is accepted. `../script/audit_timing.py` and the
  v1 build scripts apply unchanged.
- **Full graph.** `make full` needs the TFLite-exported layer fixtures in
  `../build/layer_fixtures`, which are not in the repository.
- **XSim and post-synthesis netlist simulation.** The v1 Windows scripts
  under `../script` were not rerun.

## Register map addition

| offset | name | access |
|---|---|---|
| 0x80 | phase 0: weight load cycles | read-only |
| 0x84 | phase 1: parameter load cycles | read-only |
| 0x88 | phase 2: activation load cycles | read-only |
| 0x8C | phase 3: MAC feed cycles | read-only |
| 0x90 | phase 4: requantize cycles | read-only |
| 0x94 | phase 5: output store cycles | read-only |
| 0x98 | memory wait cycles (subset of phases 0, 1, 2, 5) | read-only |
| 0x9C | other busy cycles | read-only |

Counters reset when a job starts and hold after it completes, like `cycles`.
