# RTL study and build guide

Run commands from **Repo** unless stated otherwise. All simulations are offline.
Tool installation is a separate prerequisite. Build into a scratch directory
when possible; preserve the supplied sources and accepted evidence.

## 1. Reading plan

**30 minutes:** DESIGN sections 1–5. Work through the zero-point subtraction,
quantizer example and 4×8 lane sharing. Derive one pointwise layer's MAC count.

**90 minutes:** sections 6–12 with the RTL open. Follow `first/last` through the
MAC, one output through the quantizer, then one memory request through the layer
FSM and AXI master. Inspect every state where cancellation must wait.

**Hands-on:** quick shape/AXI tests → arithmetic netlist regression → full graph
simulation → fresh physical implementation and timing review.

## 2. Check package integrity

```bash
python3 verify_package.py
```

This uses the Python standard library. It checks packaged file contents against
MANIFEST.json; newly generated build outputs are not part of that manifest.
The original model and constant-array identities are also recorded in the
numerical metadata. The guide itself needs no Python or web connection to read.

## 3. Quick RTL tests with Verilator

Prerequisites: Linux/WSL, Verilator and its matching runtime, a C++ compiler,
make and Python 3. The quick suite requires neither TensorFlow nor NumPy.
The compact real head fixture is included at `fixtures/head`.

```bash
bash script/check_rtl.sh /tmp/mobilenet-rtl-quick "$(command -v verilator)" quick
```

If your Verilator is locally extracted, set `VERILATOR_ROOT` to its matching
share/runtime directory and pass the actual executable path. Do not mix an
executable from one version with another version's generated-code headers.

Expected markers include AXI memory checks, `CSR_PASS`, awkward-shape
`TOP_SIM_PASS`, classifier-head recovery checks and `RTL_CHECK_PASS mode=quick`.
The suite randomizes memory/control channel acceptance, checks held payloads,
injects faults, cancels jobs and runs fresh jobs afterward. Its head case uses
real weights and expected outputs rather than a purely synthetic identity map.

Logs go under your scratch build directory. The C++ testbench provides a memory
model; it does not require a physical board or generated programming file.

## 4. Arithmetic with Windows XSim

Validated tool release: Vivado/XSim **2025.1**. In PowerShell:

```powershell
$env:VIVADO_BIN = 'C:\Xilinx\2025.1\Vivado\bin'
.\script\quant_sim.ps1
.\script\quant_netlist.ps1
```

`quant_sim.ps1` runs the RTL requantizer and MAC-plus-quantizer testbenches.
`quant_netlist.ps1` synthesizes the requantizer, compiles its functional netlist
with the device simulation primitives, and runs the same 40,815-case oracle.
It accounts for the global startup reset before injecting testbench traffic.

Outputs are created in `build/quant_sim` and `build/quant_netlist`. The tests
include gaps, stalls, stable outputs, blocked-pipeline reset, rounding boundaries
and invalid inputs. Functional netlist simulation does not replace routed
setup/hold/pulse-width analysis.

## 5. Full graph fixtures and RTL simulation

This path additionally needs **TensorFlow 2.15.1 and NumPy**, in a compatible
Python environment. The original portable model is included. Its frozen hash
and constants are used to detect accidental model mismatch.

```bash
python3 script/export_layer_fixtures.py --model model/oneblade_int8.tflite \
  --golden golden --out build/layer_fixtures
python3 - <<'PY'
import numpy as np
np.random.default_rng(2309).integers(0,256,(1,224,224,3),np.uint8).tofile('/tmp/mobilenet-random.rgb')
PY
python3 script/export_layer_fixtures.py --model model/oneblade_int8.tflite \
  --golden golden --image /tmp/mobilenet-random.rgb --out build/random_fixtures
bash script/check_rtl.sh /tmp/mobilenet-rtl-full "$(command -v verilator)" full
```

Full graph simulation can take substantial time because it executes more than
a billion clock ticks with modeled memory delays. It chains the 28 RTL
convolution outputs and evaluates the remaining numerical graph operations in
C++ scaffolding. Every expected intermediate tensor is compared; final scores
alone are not the acceptance criterion.

The pure NumPy numerical implementation is `script/integer_reference.py`.
It is useful for studying fixed-point equations without involving RTL scheduling.
The independent C++ arithmetic oracle uses gemmlowp headers supplied with the
matching TensorFlow install. Existing exported arithmetic vectors are included,
so normal XSim regression does not need to regenerate them.

## 6. Full Zynq fabric integration

The build script uses the bundled board preset at `fpga/z-turn-lite.tcl`. The
processing-system block supplies DDR and two clock domains. The script creates
the control and high-performance AXI hookups, SmartConnect clock crossings and
reset synchronizers. No application-side components are required to study or
implement this block design.

Build a new candidate in a **new output directory**:

```powershell
& "$env:VIVADO_BIN\vivado.bat" -mode batch -source .\fpga\build_soc.tcl `
  -tclargs 166.667 implement D:/scratch/mobilenet-166
```

Use `validate` in place of `implement` for block-design validation only. The
script snapshots the source into the candidate's output directory. An existing
GUI project therefore does not automatically follow edits to the source at
Repo/rtl; regenerate a candidate after source changes.

Expected artifacts include the project, source snapshot, checkpoint, XSA and
timing/CDC/DRC/utilization reports. A programming file is only emitted after the
script's routed setup/hold checks pass. Still inspect all report categories:
presence of that file alone is not a complete timing or numerical signoff.

The accepted report set is at `evidence/`. Run
`python3 script/audit_timing.py --help` for its explicit report-audit options.
Do not invent timing exceptions to make violations disappear. Review the actual
crossing, reset path or combinational depth and preserve its intended behavior.

## 7. Experiments with a narrow purpose

- **Signed arithmetic:** change a zero point in a small fixture and calculate
  the corrected activation range by hand. Observe why nine bits are necessary.
- **Tail lanes:** choose 13 channels or fewer than four output pixels. Verify
  output byte guards and untouched neighbors.
- **Backpressure:** extend a blocked AXI channel interval. Confirm address,
  data, strobes and valid remain stable until the handshake.
- **Cancellation:** request cancellation during a delayed write response.
  Confirm the accepted traffic drains before completion is published.
- **Numerical localization:** corrupt one expected intermediate byte and see
  which layer comparison fails first.
- **Performance:** add state-occupancy counters before changing bank feeding,
  loop order or outstanding-request count. Compare useful output bytes and
  exact tensor results, not just a shorter testbench wall-clock run.

For any changed design: repeat arithmetic RTL and netlist checks, focused
memory/scheduler tests, complete graph checks, then routed timing. The guide's
recorded numbers describe the accepted snapshot; they are not automatic
validation of a new build.
