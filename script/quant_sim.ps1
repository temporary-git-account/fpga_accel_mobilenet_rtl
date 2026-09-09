$ErrorActionPreference='Stop'
$bin=if($env:VIVADO_BIN){$env:VIVADO_BIN}else{'C:\Xilinx\2025.1\Vivado\bin'}
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $root 'build\quant_sim'
New-Item -ItemType Directory -Force $build | Out-Null
Push-Location $build
try {
 & "$bin\xvlog.bat" --sv "$root\rtl\mac_tile.sv" "$root\rtl\requantize.sv" "$root\tb\tb_requantize.sv" "$root\tb\tb_mac_quant.sv"
 if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
 foreach($test in @(@('tb_requantize','REQUANTIZE_PASS'),@('tb_mac_quant','MAC_QUANT_PASS'))) {
  & "$bin\xelab.bat" $test[0] -s $test[0] --timescale 1ns/1ps
  if($LASTEXITCODE -ne 0){throw 'xelab failed'}
  & "$bin\xsim.bat" $test[0] -runall -log "$($test[0]).log"
  if($LASTEXITCODE -ne 0){throw 'xsim failed'}
  if(!(Select-String -Path "$($test[0]).log" -Pattern $test[1])){throw 'missing PASS'}
 }
} finally {Pop-Location}
