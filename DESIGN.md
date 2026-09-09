# MobileNet convolution: from integer math to RTL

*A study guide for a handwritten SystemVerilog accelerator on the Zynq-7010.
Read the arithmetic first, then follow it through buffers, pipelines, state
machines and AXI transactions. Every implementation claim refers to the source
files in this directory. Snapshot: 9 September 2026.*

## 1. What this hardware implements

The design accelerates **integer convolution and depthwise convolution** from a
MobileNet-v1, width multiplier 1.0, input 224×224×3, with a two-class classifier
head. One reusable layer engine executes 28 convolution operators sequentially.
It does not instantiate a separate physical circuit for every network layer.

The exported graph has 37 operators: 15 regular convolutions, 13 depthwise
convolutions, four explicit pads, two quantization conversions, mean, reshape
and softmax. Only the **28 convolutions are implemented by this RTL**. The
full-graph C++ testbench evaluates the other nine operations as numerical
scaffolding. A full-graph simulation therefore proves the composition of the
RTL convolutions and that scaffold; it does not mean all 37 operators exist
as fabric blocks.

| Property | Implemented value |
|---|---|
| Target part | XC7Z010-1CLG400 on Z-turn Lite |
| Core clock | 166.667 MHz; 6 ns period |
| AXI interconnect / memory-side clock | 100 MHz; 10 ns period |
| Spatial tile | Up to four output pixels |
| Channel tile | Up to eight output channels |
| Multiplier lanes | 32, organized as 4×8 |
| Corrected activation | Signed 9 bits |
| Weight | Signed 8 bits, symmetric zero point |
| Product / accumulation | Signed 17-bit product / signed 32-bit sum |
| Output requantization | Eight registered stages, one result per advancing cycle |
| Kernels / stride | 1×1 or 3×3; stride 1 or 2 |
| Maximum reduction length | 1,024 terms per output |
| Memory port | 32-bit internal request/response to 64-bit AXI4 |
| Read cache | Eight direct-mapped lines × 16 bytes = 128 bytes |
| Outstanding memory transactions | One |

The implemented part uses 5,129 LUTs, 5,236 flip-flops, 42 DSPs and 12 RAMB18
blocks. The 12 RAMB18 blocks equal six BRAM36 capacities. The FPGA has 80 DSPs
and 60 BRAM36 capacities; those are device totals, not unused resources.
Weights and full activation tensors live in external DDR; only tiles and a
small read cache live on chip.

The 28 convolutions require **567,718,400 multiply-accumulates per image**.
Weights plus biases occupy 3,230,920 bytes. The largest intermediate tensor
occupies 817,216 bytes. These sizes explain why a layer-by-layer DDR design
was a useful first implementation on this small device.

## 2. Source map: read these blocks in order

| File | Responsibility | Useful reading question |
|---|---|---|
| [rtl/vector_mac.sv](rtl/vector_mac.sv) | 32 lane products and accumulation | Which operands are shared? |
| [rtl/requantize.sv](rtl/requantize.sv) | Bias, fixed-point scale, rounding and clamp | Where can a one-bit error appear? |
| [rtl/layer_engine.sv](rtl/layer_engine.sv) | Tile loading, addressing and scheduling | What is the engine waiting for? |
| [rtl/axi_memory.sv](rtl/axi_memory.sv) | Read cache and AXI transactions | When is a transaction truly finished? |
| [rtl/accelerator_top.sv](rtl/accelerator_top.sv) | AXI-Lite registers and block composition | When may configuration change? |
| [fpga/accelerator_top_v.v](fpga/accelerator_top_v.v) | Verilog integration wrapper | How are interfaces inferred? |
| [fpga/build_soc.tcl](fpga/build_soc.tcl) | Clocks, reset, SmartConnect and DDR hookup | Which crossings need analysis? |

`rtl/mac_tile.sv` is an earlier arithmetic teaching/probe block. Its dedicated
testbench is useful, but the production `layer_engine` instantiates
`vector_mac`, not `mac_tile`. Do not infer the production schedule from the
older probe alone.

<!-- ARCH_DIAGRAM -->

## 3. Tensor layout and convolution math

### 3.1 NHWC: channels are adjacent in memory

Batch size is one. A tensor is written as `[H, W, C]` below. NHWC means that
all channels of one pixel are contiguous, then the next pixel, then the next
row. For a byte tensor whose base is `B`:

```text
address(y, x, c) = B + ((y × W + x) × C + c)
```

For `[2,3,4]`, the four channels of pixel `(0,0)` occupy offsets 0–3; pixel
`(0,1)` occupies 4–7; pixel `(1,0)` starts at 12. A 32-bit memory read can
therefore contain four neighboring channels. The current engine still issues
individual logical accesses while the read cache captures some locality.

Regular-convolution weights use **OHWI**: output channel, kernel row, kernel
column, input channel. Their byte offset is:

```text
weight_offset(co, ky, kx, ci) = (((co × K + ky) × K + kx) × Cin + ci)
```

Depthwise weights use `[1,K,K,C]` with depth multiplier one:

```text
depthwise_weight_offset(ky, kx, c) = (ky × K + kx) × C + c
```

Getting the tensor values right but flattening one layout incorrectly produces
plausible-looking yet wrong output. Index equations are part of the datapath.

### 3.2 Ordinary convolution

For output pixel `(yo,xo)` and output channel `co`, the reduction is:

```text
acc = Σky Σkx Σci (input[yo×S+ky−Pt, xo×S+kx−Pl, ci] − Zin)
                    × weight[co,ky,kx,ci]
biased = acc + bias[co]
```

`S` is stride, `Pt/Pl` are top/left padding and `Zin` is the input zero point.
Only coordinates inside the input tensor participate; an outside sample has
quantized value `Zin`, which contributes exactly zero after correction.

The number of reduction terms is `K² × Cin`; MAC count is
`Hout × Wout × Cout × K² × Cin`. The first layer maps `[224,224,3]` to
`[112,112,32]` using 3×3 stride 2, for 10,838,016 MACs.

### 3.3 Depthwise convolution

Depthwise convolution processes each channel independently. Output channel `c`
uses only input channel `c`, so the inner `Σci` disappears. The reduction is
`K²` terms and the MAC count is `Hout × Wout × C × K²`.

A following 1×1 **pointwise** convolution mixes the channels. This pair is the
central MobileNet idea: spatial filtering and channel mixing are separate.
For a 3×3 layer with 128 input and 128 output channels, a conventional layer
needs 147,456 MACs per output pixel; depthwise plus pointwise needs
`9×128 + 128×128 = 17,536`, about 8.4× fewer. This is an arithmetic comparison
at equal spatial size, not a promise of an 8.4× speedup for this scheduler.

### 3.4 Padding and output geometry

For a normal convolution, output height is
`floor((Hin + Pt + Pb − K)/S) + 1`; width follows the same rule.
Padding can be asymmetric. In the exported graph, some stride-2 depthwise
steps receive an explicitly padded tensor, such as 112×112 becoming 113×113
before a 3×3 stride-2 operation produces 56×56.

The layer engine validates bounded dimensions and operand forms, then uses the
provided output geometry. It does not derive and enforce every framework shape
rule; unusual but address-safe padded shapes are deliberately exercised in the
testbench. Treat descriptor generation and RTL range checking as complementary.

## 4. Quantization is arithmetic, not just an integer datatype

### 4.1 Scale and zero point

A quantized value represents approximately `real = scale × (q − zero_point)`.
The image arrives as uint8 in the numerical fixtures. The graph's first
conversion subtracts 128 to produce int8. Subsequent layer zero points are
exported per tensor; they are not all interchangeable with −128.

The activation correction must be **signed 9-bit**. Two signed 8-bit operands
can differ by −255…255. For example, `127 − (−128) = 255`, which would become
−1 if narrowed to int8 before multiplication. Weight zero points are zero;
weights are signed int8. A signed 9×8 multiply fits a signed 17-bit product.

The exporter checked a conservative per-output-channel bound:

```text
abs(bias) + 255 × sum(abs(weights)) < 2³¹
```

The maximum recorded bound is 1,073,742,079, below 2,147,483,648. This establishes
that valid model operands fit the 32-bit accumulators, including partial sums.
It is not a blanket guarantee for arbitrary future weights or descriptor sizes.

### 4.2 Why each channel has a multiplier and a shift

Accumulation has the product of activation and weight scales. Output has its
own scale. The ratio is encoded using a positive Q31 multiplier `M` followed
by a right shift `s`. Each output channel has its own bias, multiplier and
shift, packed into a 16-byte parameter record:

| Byte offset | Value |
|---:|---|
| 0 | Signed int32 bias |
| 4 | Positive Q31 multiplier |
| 8 | uint32 right shift, validated 0…31 |
| 12 | Reserved |

Actual convolution shifts in this model span 1…27. The reusable block accepts
0…31. Positive left shifts are not implemented. The activation minimum/maximum
encode fused clamping, including the exported equivalents of activation limits;
do not substitute hardcoded floating-point ReLU bounds.

### 4.3 The exact two rounding steps

The numerical authority is the TensorFlow Lite 2.15.1 built-in reference path.
For positive `M`, the first operation is:

```text
v = acc + bias                     // require signed int32 fit
p = int64(v) × M
h = floor((p + 2³⁰) / 2³¹)         // signed arithmetic shift
```

This high multiply rounds negative halfway cases toward positive infinity.
Then divide `h` by `2ˢ`, rounding halfway cases **away from zero**:

```text
mask      = (1 << s) − 1
base      = arithmetic_shift_right(h, s)
remainder = h & mask
threshold = (mask >> 1) + (h < 0 ? 1 : 0)
scaled    = base + (remainder > threshold ? 1 : 0)
output    = clamp(scaled + Zout, activation_min, activation_max)
```

For `s=0`, mask and rounding increment are zero. A single floating-point
multiply followed by a cast is not equivalent to these two steps. Neither is
an unspecified optimized inference kernel. Exact reference bytes matter.

### 4.4 A worked integer example

Take input bytes already interpreted as int8: `[-128, -127, 0]`, zero point
`−128`, weights `[2, −3, 1]`, bias `3`. Corrected activations are `[0,1,128]`.
The dot product is `0×2 + 1×(−3) + 128×1 = 125`, so `v=128`.
With `M=2³⁰`, the first scale gives `h=64`. Shift by two gives `16`. Add output
zero point `−5` to get `11`, then clamp to the allowed interval.

For a signed tie, take `v=−3`, `M=2³⁰`: the high result is `−1`, because
`−1.5` rounds toward positive infinity. A subsequent right shift of one rounds
`−0.5` away from zero, producing `−1`. The two tie rules intentionally differ.

<!-- QUANT_DEMO -->

### 4.5 Mean and softmax in the graph testbench

The final 7×7 feature tensor reduces to 1×1×1024. The numerical scaffold scales
the sum of zero-point-corrected values using the reference reduction multiplier;
it does not first round an integer average and then rescale it.

For the two-class softmax, a 511-entry table maps logit difference −255…255 to
an output pair. All 65,536 int8 logit pairs were checked when deriving this
model-specific table. It is not a general multiclass softmax circuit and is
not instantiated in this RTL. These details explain how the graph testbench
checks the final head without confusing support calculations with hardware.

## 5. The 4×8 compute tile

### 5.1 Ordinary convolution: broadcast activations

Imagine a matrix with four rows (output pixels) and eight columns (output
channels). Each cell is an accumulator. For one reduction term, the engine
has four corrected activations and eight weights. Activation `a[p]` fans out
to all eight columns; weight `w[c]` fans out to all four rows:

```text
sum[p,c] ← sum[p,c] + activation[p] × weight[c]
```

That is 32 products for each accepted term. Eight channel-specific weights are
reused across four pixels, and a pixel's activation is reused across eight
output channels. After all reduction terms, there are up to 32 independent
32-bit sums, ready for per-channel requantization.

### 5.2 Depthwise: independent channel activations

The same physical multipliers support depthwise work, but activations no longer
broadcast across channels. Each lane gets `activation[p,c]`; the eight weights
still repeat across the four spatial positions. The wiring changes, not the
number of multiplier lanes.

For tail tiles, fewer than four pixels or eight channels may be real. The engine
loads safe values for inactive lanes and suppresses their output writes. It
must not let a spare lane overwrite an adjacent tensor. Odd output-channel
counts and short final rows are important tests, not cosmetic corner cases.

<!-- TILE_DEMO -->

### 5.3 On-chip banks and what remains resident

Regular-convolution activation storage comprises four 1,024-entry banks of
signed 9-bit values. Weight storage comprises eight 1,024-entry 8-bit banks.
Depthwise activations use small 16-entry banks for each of the 32 lanes;
a 3×3 kernel needs only nine entries.

Weights and eight parameter records are loaded once per output-channel group
and reused across all spatial tiles for that group. Activations are loaded per
spatial tile. When the engine moves to the next group of eight output channels,
it repeats the spatial traversal and activation loading. This is a crucial
source of repeated traffic; the network weights are not magically all resident
inside the arithmetic lanes.

### 5.4 `vector_mac`: ready/valid and accumulation

`vector_mac` registers the input activations and weights, registers products,
then accumulates them into the 32 sums. `first` initializes a reduction; `last`
marks its completion. Those markers advance alongside the values. A valid
output corresponds to completed sums for the last term, not merely the latest
product.

The pipeline uses a global advance condition: `!out_valid || out_ready`. When
the consumer blocks a valid output, products, accumulators and metadata hold
still. Advancing only the data, or only `last`, would associate the wrong sum
with a completion event. Reset clears pending valid state.

Although the arithmetic block can accept a term on every advancing cycle, the
production scheduler alternates `RUN_READ` and `RUN_FEED` to accommodate bank
read timing. Its current feed interval is therefore **two core cycles per
term**, even before the much larger load/store overhead.

## 6. Requantization as an eight-stage circuit

The 32 sums are serialized through one requantizer. That is a deliberate area
tradeoff: there are not 32 copies of the 32-bit scaling multiplier.

| Stage | Registers / operation | Reason for the boundary |
|---:|---|---|
| 0 | Bias addition; capture multiplier and metadata | Detect int32 overflow before scaling |
| 1 | Four partial products | Map into manageable DSP multipliers |
| 2 | Two shifted partial-sum additions | Keep carry chains bounded |
| 3 | Recombine signed 64-bit product | Register the wide result |
| 4 | High multiply with its rounding bit | Finish Q31 scaling |
| 5 | Arithmetic shift and guard/sticky rounding flag | Implement signed divide rounding |
| 6 | Add rounding increment and output zero point | Use a wider sum before narrowing |
| 7 | Clamp; publish int8 and aligned error | Prevent wraparound at the output |

The multiplier split uses 16-bit low/high portions. Low portions must be
zero-extended; signed high portions must be sign-extended. Let `v = vl + vh×2¹⁶`
and `M = ml + mh×2¹⁶`; then:

```text
v×M = vl×ml + (vh×ml + vl×mh)×2¹⁶ + vh×mh×2³²
```

The implementation groups that expression into two 48-bit sums and a final
64-bit sum. Losing a shift or interpreting a low half as signed corrupts the
result, often without producing an obvious overflow.

The quantizer accepts one input each advancing cycle and holds all eight stages
under backpressure. Zero/negative multipliers, reversed activation limits and
bias overflow propagate an error bit and a zero result. Consumers must inspect
valid and error together. The layer engine converts an arithmetic error to
job status 4; it does not write a fabricated successful classification.

## 7. The layer scheduler is the main architecture

### 7.1 The high-level sequence

1. Capture a descriptor and validate its supported dimensions and formats.
2. Load eight output channels' weights and parameters.
3. Generate coordinates for four output pixels.
4. Load corrected activation terms into the appropriate banks.
5. Feed all terms into the vector MAC and wait for completed sums.
6. Send 32 sums through the quantizer and collect their outputs.
7. Write only real pixel/channel outputs using byte strobes.
8. Advance the spatial tile, or load the next group of channels, or finish.

`layer_engine.sv` encodes its 30 states as explicit one-hot bits. This keeps
state decodes and bank enables shallow. It uses counters and pipelined address
arithmetic rather than hardware division to convert a linear pixel index to
coordinates on every access.

<!-- FSM_DIAGRAM -->

### 7.2 Map the conceptual sequence to actual states

| State group | Role |
|---|---|
| IDLE, CHECK | Accept one descriptor, capture dimensions, reject unsupported jobs |
| W_ADDR, W_NEXT | Walk weights for one eight-channel group |
| P_ADDR, P_NEXT | Fetch bias, multiplier and shift for those channels |
| PIX_INIT, PIX_NEXT | Capture four pixel origins and advance row/column counters |
| A_SELECT … A_ADDR, A_NEXT | Walk kernel/input coordinates, handle padding, load banks |
| RUN_READ, RUN_FEED, SUM_WAIT | Read banks, feed MAC terms, wait for sums |
| Q_SEND, Q_WAIT | Serialize 32 sums and wait for 32 quantized results |
| O_ADDR, O_NEXT, NEXT_TILE | Store valid lanes and choose the next tile/group |
| MULTIPLY, OFFSET, ADDRESS, CHECK_REQ | Shared pipelined address generation |
| MREQ, MWAIT | Offer a memory request and wait for its response |
| FINISH | Hold completion until acknowledgement |

### 7.3 Address checks and overflow

Each memory request is checked against a configured half-open DDR region
`[region_base, region_limit)`. Region boundaries and parameter records are
aligned; the last legal word starts at `region_limit−4`. A 33-bit request
address catches carry out of a base-plus-offset calculation. Intermediate
multiplication overflow is also rejected.

Supported image dimensions are nonzero and at most 256 in each spatial axis;
channel counts are at most 1,024. Kernel is 1 or 3, stride is 1 or 2, and the
reduction length must fit the 1,024-term banks. Depthwise requires equal input
and output channel counts. Valid arithmetic cannot compensate for a descriptor
that addresses the wrong region; check both classes of conditions.

### 7.4 Why this schedule is slow

Loading, computing, quantizing and writing are mostly sequential. The MAC array
waits while activation words are fetched through several address states and a
single-outstanding memory interface. Outputs are written as individual bytes,
each with transaction machinery, rather than aggregated into long contiguous
writes. A small cache helps repeated reads but does not overlap misses.

At 166.667 MHz, 32 products every cycle would suggest 5.333 billion MAC/s, or
about 106.4 ms for 567.7 million MACs. That is an **arithmetic-only ceiling**.
The current two-cycle feed interval lowers even the feed-only ceiling to
2.667 billion MAC/s, or about 212.9 ms. Both calculations exclude all loads,
stores, tail-lane waste, quantization and control.

The full graph's recorded testbench execution is about 1.184 billion core cycles,
roughly 7.10 seconds at the target frequency under that testbench's memory delays.
It is a simulation-derived estimate, not a measured clock-to-clock hardware
inference duration. Do not compare it directly with the ideal 106 ms figure
and conclude a specific DDR bandwidth without measuring state occupancy.

<!-- PERFORMANCE_DEMO -->

## 8. From the internal memory port to AXI

### 8.1 A small internal request interface

The layer engine submits an aligned 32-bit address, data word and four write
strobes. A zero strobe denotes a read. `req_valid/req_ready` accepts a request;
`rsp_valid/rsp_ready` retires its response. Only one request is active. This
simple abstraction keeps AXI burst and channel details out of the layer FSM.

For an output byte, data is shifted to its position in the aligned word and a
single byte strobe is asserted. `axi_memory` then selects the appropriate half
of its aligned 64-bit write beat using address bit 2. Both alignment steps must
agree; otherwise the right value can be written into the wrong neighbor byte.

### 8.2 The 128-byte read cache

Read addresses select a 16-byte-aligned line. Address bits `[6:4]` select one
of eight entries; bits `[31:7]` are the tag; bits `[3:2]` select the requested
32-bit word inside the line.

A miss issues a two-beat 64-bit INCR read burst, starting at a 16-byte boundary.
Such a burst never crosses a 4 KiB boundary. Both beats are collected before a
line becomes valid. A response error or malformed `RLAST` must not populate
the cache with partially trusted data.

A write invalidates a matching cached line. Starting a new job invalidates the
cache so a new tensor or descriptor does not observe stale data. This is a
small direct-mapped cache, not a coherent shared cache or a full tensor buffer.
Two hot lines mapping to the same index can continually evict one another.

### 8.3 Independent AXI write channels

AXI's write address and write data channels may handshake on different cycles.
The memory block tracks `aw_sent` and `w_sent` independently. It does not assume
that `AWREADY` and `WREADY` arrive together, and it holds payload stable while
a valid channel is blocked. Completion occurs after the write response `B`,
not when the data beat is merely offered.

The testbench deliberately changes channel ordering and backpressure. An
always-ready memory model would miss many bugs in a seemingly simple master.

### 8.4 Timeouts do not erase outstanding traffic

The memory block's watchdog defaults to 100,000,000 cycles. If a transaction
exceeds that bound, `fatal` latches, but the block keeps draining the outstanding
transaction. Dropping `VALID`, abandoning a read burst or reusing memory early
would leave another part of the fabric with an accepted request and no matching
lifetime owner.

Malformed burst termination also latches fatal. A fatal interface cannot accept
new work; recovery requires a coordinated fabric reset. A local reset of only
one active master is not a safe substitute for completing or resetting all
participants in that transaction.

## 9. AXI-Lite control and layer descriptors

The integration assigns a 4 KiB AXI-Lite window at **0x43C00000**. The core uses
12-bit offsets. Reads and writes must be word aligned. Unsupported accesses
return an AXI slave error. Address and data for writes are captured independently.

| Offset | Read meaning / configuration |
|---:|---|
| 0x00 | Flags: bit 0 busy, bit 1 completion valid, bit 2 fatal |
| 0x04 | Identity `0x49414331` |
| 0x08 | Completed job ID |
| 0x0C | Job result status |
| 0x10 | Busy-cycle counter |
| 0x14 | Internal read-request count |
| 0x18 | Internal write-request count |
| 0x20 | Job ID |
| 0x24 / 0x28 / 0x2C / 0x30 | Input / weights / parameters / output addresses |
| 0x34 / 0x38 | Authorized region base / exclusive limit |
| 0x3C | Input height bits 15:0; input width bits 31:16 |
| 0x40 | Input channels bits 15:0; output height bits 31:16 |
| 0x44 | Output width bits 15:0; output channels bits 31:16 |
| 0x48 | Kernel [1:0], stride [3:2], top pad [5:4], left pad [7:6], depthwise [8] |
| 0x4C | Input zero, output zero, activation min, activation max: four signed bytes |

Writing exact command value **1** to offset 0 starts an idle job; **2** requests
cancellation while busy; **4** acknowledges a valid completion. These are not
freely combinable command bits. Configuration writes honor byte strobes but are
rejected while a job is active, completion is pending, a start is pending, or
the memory interface is fatal.

Statuses are 0 success, 1 invalid descriptor/address/parameter, 2 memory error,
3 cancelled and 4 arithmetic error. The completion ID tells the controller
which job ended. It remains stable with completion until acknowledged. Reading
a previous completion and mistaking it for a newly started job is a classic
race; explicit ID and acknowledgement semantics prevent it.

The cycle counter counts core cycles while busy. The read/write counters count
accepted requests at the internal port; **they do not directly count DDR bytes
or cache misses**. A cache hit still belongs to an internal read request.

## 10. Cancellation and reset behavior

Cancellation first latches `aborting`. The engine stops at a boundary where it
is not withdrawing an offered request or abandoning an accepted one. In `MREQ`
and `MWAIT`, it continues until the memory handshake/response resolves. At the
next safe state it publishes status 3 and waits in FINISH for acknowledgement.

A cancelled output buffer may contain partially written data; cancellation does
not roll back DDR contents. The useful guarantee is that completion is published
after the accepted traffic drains, so a controller can then safely reuse the
buffer. Arithmetic pipeline valid bits clear on the appropriate core reset.

Distinguish three cases: normal completion, drained cancellation and fatal bus
failure. They require different recovery actions. Reporting all three as a
successful “stop” would conceal an unsafe memory lifetime.

## 11. Clock domains and physical implementation

`fpga/build_soc.tcl` instantiates the processing-system DDR interfaces, AXI-Lite
control and SmartConnect bridges. The control GP0 and 64-bit HP0 interfaces run
at 100 MHz. The accelerator runs from FCLK1 at 166.667 MHz. Two-clock
SmartConnect instances perform the data crossings. Reset synchronizers exist
for the bus and core domains; the external reset polarity is active low.

There is no custom asynchronous datapath between the two domains. That does not
eliminate the need to review vendor CDC reports, generated clocks and reset
behavior. The source adds no ad hoc false-path exceptions to hide failing paths.

Accepted routed timing is +0.172 ns setup slack, +0.028 ns hold slack and
+1.750 ns pulse-width slack. Unconstrained endpoint and missing-delay checks are
zero. Thirteen bus-skew constraints passed in the accepted implementation.
The report includes reviewed CDC and DRC warnings; it is not warning-free.
A 200 MHz candidate did not meet timing. “166.667 MHz passed” does not establish
the absolute maximum achievable frequency under every placement or redesign.

Reports in [evidence](evidence/) are snapshots of the accepted implementation.
This package includes source and reports, not generated programming containers.
Create a new output directory for your build and repeat all acceptance gates.

## 12. A synthesis bug that RTL simulation did not catch

The first complete implementation returned wrong values on physical hardware
even though RTL arithmetic tests had passed. The first convolution already
differed; the faulty result pattern matched truncation behavior in the scaled
accumulator path. The investigation moved backward from class scores to tensor
hashes, then to isolated arithmetic cases.

Vivado 2025.1 had folded shifted partial-product additions into unshifted DSP
cascade connections. The symbolic source expression was correct, but the
inferred implementation of that expression was not numerically equivalent.
The fix keeps the two 48-bit partial recombination registers in fabric:

```systemverilog
(* use_dsp="no" *) logic signed [47:0] left2, right2;
```

The four product multipliers remain mapped to DSPs. The same 40,815-case suite
then passed both RTL and the synthesized functional netlist, followed by full
hardware tensor checks. This is why the post-synthesis regression is a required
step rather than an optional visualization exercise.

Do not overgeneralize this observation to every DSP cascade. It is a concrete
synthesis result for this expression, tool version and implementation. Preserve
the reproducer and numerical checks whenever changing the decomposition.

## 13. Verification ladder and what each rung proves

| Rung | Evidence | Does not establish |
|---|---|---|
| Independent arithmetic oracle | 40,815 requantizer cases; signed/tie/error boundaries | Complete address generation |
| RTL arithmetic | Backpressure, reset, ordered valid/error, repeated tiles | Synthesis equivalence |
| Synthesized arithmetic | Same oracle through mapped functional netlist | Routed timing or external memory behavior |
| Layer simulation | Real operands and awkward dimensions; exact bytes | Whole graph composition |
| AXI/CSR simulation | Independent channels, strobes, faults, cancellation, recovery | Real DDR latency |
| Full graph simulation | Chained RTL conv outputs with numerical scaffold | All operators implemented in RTL |
| Routed implementation | Clock constraints, setup/hold/pulse, CDC/DRC review | Numerical correctness by itself |
| Physical numerical checks | Seven inputs × 37 exact intermediate tensors | Generalization to unseen data or a throughput promise |

The seven inputs comprise four prepared example images plus all-zero, all-255
and seeded-random RGB. Non-saturated synthetic results are valuable: black
produces `[226,30]`, white `[249,7]`, random `[153,103]` in the frozen reference.
A saturated `[0,255]` result can hide internal errors. Comparing all tensor
hashes localizes the first divergence instead of arguing over final labels.

`tb/top_runner.hpp` models memory and control handshakes with randomized delays,
checks stable payload under backpressure, injects read/write errors, and exercises
cancellation followed by a fresh job. Shape fixtures include odd channels,
partial spatial tiles, extreme zero points, padding and the 1,024-term boundary.

## 14. The complete operator inventory

The table below is generated from the included frozen model specification.
Shapes include batch dimension one. MAC totals count a multiplication followed
by accumulation as one MAC, not two operations. “Scaffold” means a numerical
operation in graph simulation rather than a fabric block.

| Index | Operator | Input shape | Output shape | Execution | MACs |
|---:|---|---|---|---|---:|
| 0 | QUANTIZE | 1×224×224×3 | 1×224×224×3 | Scaffold | 0 |
| 1 | CONV_2D | 1×224×224×3 | 1×112×112×32 | RTL | 10,838,016 |
| 2 | DEPTHWISE_CONV_2D | 1×112×112×32 | 1×112×112×32 | RTL | 3,612,672 |
| 3 | CONV_2D | 1×112×112×32 | 1×112×112×64 | RTL | 25,690,112 |
| 4 | PAD | 1×112×112×64 | 1×113×113×64 | Scaffold | 0 |
| 5 | DEPTHWISE_CONV_2D | 1×113×113×64 | 1×56×56×64 | RTL | 1,806,336 |
| 6 | CONV_2D | 1×56×56×64 | 1×56×56×128 | RTL | 25,690,112 |
| 7 | DEPTHWISE_CONV_2D | 1×56×56×128 | 1×56×56×128 | RTL | 3,612,672 |
| 8 | CONV_2D | 1×56×56×128 | 1×56×56×128 | RTL | 51,380,224 |
| 9 | PAD | 1×56×56×128 | 1×57×57×128 | Scaffold | 0 |
| 10 | DEPTHWISE_CONV_2D | 1×57×57×128 | 1×28×28×128 | RTL | 903,168 |
| 11 | CONV_2D | 1×28×28×128 | 1×28×28×256 | RTL | 25,690,112 |
| 12 | DEPTHWISE_CONV_2D | 1×28×28×256 | 1×28×28×256 | RTL | 1,806,336 |
| 13 | CONV_2D | 1×28×28×256 | 1×28×28×256 | RTL | 51,380,224 |
| 14 | PAD | 1×28×28×256 | 1×29×29×256 | Scaffold | 0 |
| 15 | DEPTHWISE_CONV_2D | 1×29×29×256 | 1×14×14×256 | RTL | 451,584 |
| 16 | CONV_2D | 1×14×14×256 | 1×14×14×512 | RTL | 25,690,112 |
| 17 | DEPTHWISE_CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 903,168 |
| 18 | CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 51,380,224 |
| 19 | DEPTHWISE_CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 903,168 |
| 20 | CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 51,380,224 |
| 21 | DEPTHWISE_CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 903,168 |
| 22 | CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 51,380,224 |
| 23 | DEPTHWISE_CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 903,168 |
| 24 | CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 51,380,224 |
| 25 | DEPTHWISE_CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 903,168 |
| 26 | CONV_2D | 1×14×14×512 | 1×14×14×512 | RTL | 51,380,224 |
| 27 | PAD | 1×14×14×512 | 1×15×15×512 | Scaffold | 0 |
| 28 | DEPTHWISE_CONV_2D | 1×15×15×512 | 1×7×7×512 | RTL | 225,792 |
| 29 | CONV_2D | 1×7×7×512 | 1×7×7×1024 | RTL | 25,690,112 |
| 30 | DEPTHWISE_CONV_2D | 1×7×7×1024 | 1×7×7×1024 | RTL | 451,584 |
| 31 | CONV_2D | 1×7×7×1024 | 1×7×7×1024 | RTL | 51,380,224 |
| 32 | MEAN | 1×7×7×1024 | 1×1×1×1024 | Scaffold | 0 |
| 33 | CONV_2D | 1×1×1×1024 | 1×1×1×2 | RTL | 2,048 |
| 34 | RESHAPE | 1×1×1×2 | 1×2 | Scaffold | 0 |
| 35 | SOFTMAX | 1×2 | 1×2 | Scaffold | 0 |
| 36 | QUANTIZE | 1×2 | 1×2 | Scaffold | 0 |

## 15. Where to optimize next

Start with counters that classify cycles: weight loading, activation loading,
cache hits/misses, stalled AXI, MAC feed, quantizer drain and output writes.
The existing total/request counters are useful but insufficient to assign a
precise fraction of time to DDR latency versus address-state overhead.

Potential experiments, each requiring renewed numerical and timing checks:

1. **Widen useful work per access.** Consume all relevant bytes from a fetched
   word instead of repeatedly entering the request FSM for neighboring bytes.
2. **Aggregate output writes.** Pack adjacent valid channels into aligned words
   or bursts, retaining exact strobes for tail channels and row boundaries.
3. **Double-buffer tiles.** Load the next tile while the current one computes;
   track which bank owns each outstanding operation, including cancellation.
4. **Increase outstanding reads.** Add transaction tracking and response routing;
   the complexity moves into ordering, bounds, timeout and drain handling.
5. **Change loop ordering.** Reuse activation tiles across channel groups, subject
   to on-chip capacity and weight traffic. Measure the tradeoff rather than
   assuming one reuse strategy wins for every layer.
6. **Improve bank feeding.** Pipeline synchronous reads to feed one term per cycle.
   Confirm `first/last`, tile tags and the final sum remain aligned.

Higher clock or more multipliers alone will not fix a design whose arithmetic
waits most of the time. Conversely, an efficient memory schedule can increase
useful MAC utilization without increasing the multiplier count.

## 16. Study exercises

1. Compute the NHWC byte offset for pixel `(3,5)`, channel 7 in a `[14,14,512]`
   tensor. Answer: `(3×14+5)×512+7 = 24,071`.
2. For a pointwise `[14,14,512]→[14,14,512]` layer, derive 51,380,224 MACs.
   How many times are activations reloaded if you process eight output channels
   per group? There are 64 groups in the current loop ordering.
3. Explain why a padded input sample must use the input zero point, not integer
   zero, before correction.
4. Trace one byte output through word alignment, strobe shift and the 64-bit bus.
5. Find the last accepted memory request when cancellation arrives in MWAIT.
   Which state first has permission to publish the cancelled completion?
6. Propose a test that detects invalid cached data after a read-response error.
7. Remove the arithmetic-only idealization from a MAC throughput calculation.
   Which cycle categories and lane masks must you measure?
8. Explain why passing timing and passing RTL simulation are independent claims.

## 17. Glossary and suggested reading order

**MAC:** multiply-accumulate. **Depthwise:** spatial filtering without channel
mixing. **Pointwise:** 1×1 channel mixing. **NHWC/OHWI:** tensor/weight memory
orders. **Zero point:** integer representing real zero. **Q31:** fixed-point
multiplier scaled by 2³¹. **Requantization:** converting an accumulated value
into the next tensor's integer scale. **DSP:** dedicated multiplier/accumulator
resource. **BRAM:** dedicated on-chip memory. **AXI-Lite:** memory-mapped control
interface. **AXI4 burst:** a sequence of data beats associated with one address.
**Backpressure:** a receiver delaying acceptance. **CDC:** clock-domain crossing.
**Slack:** timing margin against a constraint. **One-hot FSM:** one state bit
active at a time. **Oracle:** independently generated expected numerical result.

For a first code pass: `vector_mac` → `requantize` → `layer_engine` → `axi_memory`
→ `accelerator_top`. For a verification pass: arithmetic testbench → shape
fixtures → `top_runner.hpp` → graph comparison → timing reports. The practical
commands are in [GUIDE.md](GUIDE.md).
