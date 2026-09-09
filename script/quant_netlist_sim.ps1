param([string]$Directory)
$ErrorActionPreference='Stop';$bin=if($env:VIVADO_BIN){$env:VIVADO_BIN}else{'C:\Xilinx\2025.1\Vivado\bin'}
Push-Location $Directory
try {
 & "$bin\xvlog.bat" requantize_netlist.v "$bin\..\data\verilog\src\glbl.v"
 if ($LASTEXITCODE -ne 0) {throw 'netlist compile failed'}
 & "$bin\xvlog.bat" --sv tb_requantize.sv
 if ($LASTEXITCODE -ne 0) {throw 'testbench compile failed'}
 & "$bin\xelab.bat" -L unisims_ver -L secureip tb_requantize glbl -s quant_netlist
 if ($LASTEXITCODE -ne 0) {throw 'elaboration failed'}
 & "$bin\xsim.bat" quant_netlist -runall -log quant_netlist.log
 if ($LASTEXITCODE -ne 0) {throw 'simulation failed'}
 if (!(Select-String -Path quant_netlist.log -Pattern REQUANTIZE_PASS)) {throw 'netlist numerical check failed'}
} finally {Pop-Location}
