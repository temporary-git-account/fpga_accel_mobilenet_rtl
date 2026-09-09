# Post-synthesis numerical regression; run before accepting a new bitstream.
param([string]$Directory)
$ErrorActionPreference='Stop'
$bin=if($env:VIVADO_BIN){$env:VIVADO_BIN}else{'C:\Xilinx\2025.1\Vivado\bin'}
$root=Split-Path $PSScriptRoot -Parent
if (!$Directory) {$Directory=Join-Path $root 'build\quant_netlist'}
New-Item -ItemType Directory -Force $Directory | Out-Null
$Directory=(Resolve-Path $Directory).Path
$tb=Get-Content -Raw "$root\tb\tb_requantize.sv"
$golden=($root -replace '\\','/') + '/golden/'
# glbl holds GSR for 100 ns; wait beyond it before the blocked-pipeline test.
$tb=$tb.Replace('../../golden/',$golden).Replace('repeat(4) @(posedge clk);','repeat(40) @(posedge clk);')
Set-Content -Encoding ascii -Path "$Directory\tb_requantize.sv" -Value $tb
Push-Location $Directory
try {
 & "$bin\vivado.bat" -mode batch -notrace -source "$root\script\quant_netlist.tcl" -tclargs "$root\rtl\requantize.sv" $Directory
 if ($LASTEXITCODE -ne 0) {throw 'requantizer synthesis failed'}
 & "$root\script\quant_netlist_sim.ps1" -Directory $Directory
} finally {Pop-Location}
