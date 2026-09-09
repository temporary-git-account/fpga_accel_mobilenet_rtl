#!/bin/bash
# VERILATOR_ROOT may be needed for a locally extracted Verilator distribution.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo 'usage: check_rtl.sh WSL_BUILD_DIRECTORY VERILATOR_EXECUTABLE [quick|full]' >&2
  exit 2
fi
work=$(realpath -m "$1");verilator=$2;mode=${3:-full}
[[ "$mode" = quick || "$mode" = full ]]
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$work/logs"
"$verilator" --cc --exe --build -j 8 -O3 --assert -Wno-fatal \
  --top-module accelerator_top --Mdir "$work/top" \
  "$root"/rtl/{vector_mac,requantize,layer_engine,axi_memory,accelerator_top}.sv \
  "$root/tb/top_sim.cc" > "$work/logs/top-build.log" 2>&1
"$verilator" --cc --exe --build -j 8 -O3 --assert -Wno-fatal \
  --top-module axi_memory -GTIMEOUT_CYCLES=32 --Mdir "$work/axi" \
  "$root/rtl/axi_memory.sv" "$root/tb/axi_memory_sim.cc" > "$work/logs/axi-build.log" 2>&1
"$work/axi/Vaxi_memory" | tee "$work/logs/axi.log"
python3 "$root/script/export_shape_fixtures.py" --out "$work/shapes"
"$work/top/Vaccelerator_top" "$work/shapes" csr | tee "$work/logs/csr.log"
"$work/top/Vaccelerator_top" "$work/shapes" all | tee "$work/logs/shapes.log"
"$work/top/Vaccelerator_top" "$root/fixtures/head" op_33 | tee "$work/logs/head-faults.log"
if [[ "$mode" = full ]]; then
  # Export these from TFLite BUILTIN_REF with export_layer_fixtures.py first.
  "$work/top/Vaccelerator_top" "$root/build/layer_fixtures" graph | tee "$work/logs/oneblade-graph.log"
  "$work/top/Vaccelerator_top" "$root/build/random_fixtures" graph | tee "$work/logs/random-graph.log"
fi
echo "RTL_CHECK_PASS mode=$mode"
