VERILATOR ?= verilator
BUILD ?= build
.PHONY: check full lint clean
check:
	script/check.sh $(BUILD) $(VERILATOR) quick
full:
	script/check.sh $(BUILD) $(VERILATOR) full
lint:
	$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY --top-module accelerator_top rtl/vector_mac.sv rtl/requantize.sv rtl/layer_engine.sv rtl/axi_memory.sv rtl/accelerator_top.sv
clean:
	rm -rf $(BUILD)
