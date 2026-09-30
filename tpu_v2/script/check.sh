#!/bin/bash
# tpu_v2 regression. usage: check.sh [BUILD_DIRECTORY] [VERILATOR] [quick|full]
# quick: AXI memory unit test, CSR checks, 26 shape fixtures at aligned and
#        misaligned bases, real classifier head with fault injection, and the
#        Icarus arithmetic testbenches when iverilog is installed.
# full:  additionally the whole MobileNet graph from build/layer_fixtures.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(cd -- "$here/.." && pwd)
work=$(realpath -m "${1:-$here/build}");verilator=${2:-verilator};mode=${3:-quick}
[[ "$mode" = quick || "$mode" = full ]]
mkdir -p "$work/logs"
"$verilator" --cc --exe --build -j 8 -O3 --assert -Wno-fatal \
  --top-module accelerator_top --Mdir "$work/top" \
  "$here"/rtl/{vector_mac,requantize,layer_engine,axi_memory,accelerator_top}.sv \
  "$here/tb/top_sim.cc" > "$work/logs/top-build.log" 2>&1
"$verilator" --cc --exe --build -j 8 -O3 --assert -Wno-fatal \
  --top-module axi_memory -GTIMEOUT_CYCLES=32 --Mdir "$work/axi" \
  "$here/rtl/axi_memory.sv" "$here/tb/axi_memory_sim.cc" > "$work/logs/axi-build.log" 2>&1
"$work/axi/Vaxi_memory" | tee "$work/logs/axi.log"
python3 "$here/script/export_shape_fixtures.py" --out "$work/shapes"
"$work/top/Vaccelerator_top" "$work/shapes" csr | tee "$work/logs/csr.log"
"$work/top/Vaccelerator_top" "$work/shapes" all | tee "$work/logs/shapes.log"
"$work/top/Vaccelerator_top" "$work/shapes" shift | tee "$work/logs/shapes-shift.log"
"$work/top/Vaccelerator_top" "$repo/fixtures/head" op_33 | tee "$work/logs/head-faults.log"
if command -v iverilog >/dev/null; then
  mkdir -p "$work/sv"
  for tb in tb_requantize tb_mac_tile tb_mac_quant; do
    iverilog -g2012 -DGOLDEN="\"$repo/golden\"" -I "$repo/golden" -o "$work/sv/$tb" \
      "$here/tb/$tb.sv" "$here/rtl/requantize.sv" "$here/rtl/mac_tile.sv" > "$work/logs/$tb-build.log" 2>&1
    (cd "$work/sv" && vvp -n "$tb" | grep -v '^\$finish' | tee "$work/logs/$tb.log")
  done
fi
if [[ "$mode" = full ]]; then
  "$work/top/Vaccelerator_top" "$repo/build/layer_fixtures" graph | tee "$work/logs/oneblade-graph.log"
fi
python3 "$here/script/cycle_report.py" "$work/logs" | tee "$work/logs/cycle-report.md"
echo "TPU_V2_CHECK_PASS mode=$mode"
