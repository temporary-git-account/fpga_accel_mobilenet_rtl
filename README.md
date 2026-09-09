# MobileNet RTL Accelerator

**A handwritten SystemVerilog convolution accelerator for the Zynq-7010.**
This is a standalone source and teaching snapshot for peer study. Its scope is
integer arithmetic, tile scheduling, on-chip buffering, AXI memory access,
control registers, simulation and physical timing.

Open **[ARCHITECTURE-offline.html](ARCHITECTURE-offline.html)** in a browser.
The complete guide works offline, including its diagrams and interactive
integer/tile examples. [DESIGN.md](DESIGN.md) is the editable source;
[GUIDE.md](GUIDE.md) contains build commands and study exercises.

## The design at a glance

| Item | Value |
|---|---|
| Network used for fixtures | MobileNet-v1, width 1.0, 224×224 RGB, two-class head |
| Fabric work | 15 regular + 13 depthwise convolution operators, one reusable engine |
| Tile | Four spatial positions × eight output channels = 32 MAC lanes |
| Datatypes | Corrected int9 activations × int8 weights → int32 sums → int8 outputs |
| Requantization | Eight-stage pipeline; exact double rounding |
| Memory | DDR through 64-bit AXI; eight 16-byte read-cache lines; one outstanding request |
| Device | XC7Z010-1CLG400, Z-turn Lite |
| Accepted clock | 166.667 MHz core; 100 MHz memory/control interfaces |
| Resources | 5,129 LUTs; 5,236 FFs; 42 DSPs; 12 RAMB18 |
| Routed slack | Setup +0.172 ns; hold +0.028 ns; pulse +1.750 ns |
| Arithmetic verification | 40,815 cases at RTL and synthesized-netlist levels |

The full exported graph has 37 operators. **Only its 28 convolution operators
are hardware in this design.** The graph testbench evaluates the remaining
nine numerical steps as scaffolding. There is no general-purpose all-operator
neural-network processor hidden behind this description.

## Layout

```text
ARCHITECTURE-offline.html  illustrated, self-contained study guide
DESIGN.md                 arithmetic-to-RTL explanation and operator inventory
GUIDE.md                  simulation/build steps and reading plan
rtl/                      six SystemVerilog modules
  vector_mac.sv           production 4×8 arithmetic array
  requantize.sv           bias, scaling, rounding and saturation
  layer_engine.sv         complete convolution/depthwise scheduler
  axi_memory.sv          cached 32-bit request port → 64-bit AXI4
  accelerator_top.sv      AXI-Lite registers and module composition
  mac_tile.sv             earlier arithmetic probe, not the production scheduler
tb/                       SV arithmetic and C++ memory/layer/top testbenches
script/                   fixture export, simulation and timing tools
fpga/                     integration wrapper, PS preset and Vivado build script
fixtures/head/            compact real classifier-head fixture for quick RTL tests
golden/                   numerical specifications, vectors and expected tensor hashes
model/                    portable reference model and derived layer inventory
evidence/                 accepted timing reports and verification summary
docs/                     offline HTML renderer, style and interactive examples
MANIFEST.json             packaged-file checksums
verify_package.py         standard-library checksum checker
```

## Start here

1. Open the HTML and read sections 1–6 before studying the scheduler.
2. Run `python3 verify_package.py` to check the snapshot.
3. Run the quick Verilator suite or XSim arithmetic checks from GUIDE.md.
4. Read the synthesis-debugging chapter before changing the requantizer.
5. Compare a proposed optimization against the same numerical and timing gates.

The known-good design is conservative: serialized memory access and repeated
activation loading limit utilization. The guide separates arithmetic ceilings
from the full-graph simulation cycle count. A 200 MHz candidate did not pass
timing; 166.667 MHz is an accepted result, not a proof of absolute maximum speed.

Generated programming containers and workstation build databases are not part
of this sharing snapshot. The included reports have workstation path labels
normalized; their numerical results are retained. Original notices in supplied
source are retained. No Git repository or commit was created for this package.
