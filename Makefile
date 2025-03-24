# Try to use /u/nate/verilator if it exists; otherwise, use Verilator from PATH
ifneq ($(wildcard /u/nate/verilator),)
    VERILATOR := /u/nate/verilator
else
    VERILATOR := $(shell which verilator)
endif
$(info Using Verilator: $(VERILATOR))

CCACHE_PATH := $(shell which ccache 2>/dev/null)
ifeq ($(strip $(CCACHE_PATH)),)
    OBJCACHE :=
else
    OBJCACHE := OBJCACHE=ccache
endif
$(info OBJCACHE: $(OBJCACHE))

# Compiler
VERILATOR ?= /u/nate/verilator

# Flags
VFLAGS = --binary -j $$(( `nproc` - 1 )) --trace --trace-underscore

# Target-specific flags
DIMM_VFLAGS = $(VFLAGS) --top-module ddr4_dimm
SCHEDULER_VFLAGS = $(VFLAGS) --top-module mem_scheduler_tb
LLC_VFLAGS = $(VFLAGS) --top-module last_level_cache
SDRAM_VFLAGS = $(VFLAGS) --top-module ddr4_system_tb
CACHE_VFLAGS = $(VFLAGS) --top-module cache_tb
L1D_VFLAGS = $(VFLAGS) --top-module l1_data_cache_tb
LLC_DIMM_VFLAGS = $(VFLAGS) --top-module llc_dimm_tb
L1D_LLC_DIMM_VFLAGS = $(VFLAGS) --top-module l1d_llc_tv

# Source files
DIMM_SRCS = --cc src/ddr4_dimm.sv --exe verif/dimm_tb2.cpp
SCHEDULER_SRCS = --cc src/mem_control/bank_state.sv src/mem_control/comb_util.sv src/mem_control/mem_scheduler.sv src/mem_control/req_queue.sv src/testbenches/mem_scheduler_tb.sv
LLC_SRCS = --cc src/last_level_cache.sv src/mem_control/bank_state.sv src/mem_control/comb_util.sv src/mem_control/mem_scheduler.sv src/mem_control/req_queue src/cache.sv
SDRAM_SRCS = --cc tb/ddr4_system_tb.sv src/mem_control/sdram_controller.sv src/ddr4_dimm.sv src/mem_control/bank_state.sv src/mem_control/comb_util.sv --exe verif/ddr4_sys_verif.cpp
CACHE_SRCS = --cc --timing src/cache.sv tb/cache_tb.sv
L1D_SRCS = --cc --timing src/l1_data_cache.sv tb/l1d_tb.sv src/mem_control/comb_util.sv src/cache.sv # still adding more
LLC_DIMM_SRCS = --cc --timing tb/llc_dimm_tb.sv src/cache.sv src/last_level_cache.sv src/ddr4_dimm.sv src/mem_control/bank_state.sv src/mem_control/comb_util.sv src/mem_control/mem_scheduler.sv src/mem_control/req_queue.sv src/mem_control/sdram_controller.sv --exe verif/llc_dimm_verif.cpp
L1D_LLC_SRCS = --cc --timing tb/l1d_llc_tb.sv src/cache.sv src/last_level_cache.sv src/l1_data_cache.sv src/mem_control/bank_state.sv src/mem_control/comb_util.sv src/mem_control/mem_scheduler.sv src/mem_control/req_queue.sv src/mem_control/sdram_controller.sv --exe verif/l1d_llc_verif.cpp

# Output binaries
DIMM_BIN = obj_dir/Vddr4_dimm
SCHEDULER_BIN = obj_dir/Vmem_scheduler
LLC_BIN = obj_dir/Vlast_level_cache
SDRAM_BIN = obj_dir/Vddr4_system_tb
CACHE_BIN = obj_dir/Vcache_tb
L1D_BIN = obj_dir/Vl1_data_cache_tb
LLC_DIMM_BIN = obj_dir/Vllc_dimm_tb
L1D_LLC_BIN = obj_dir/Vl1d_llc_tb

# Default target (alias for dimm)
all: dimm

# Compile and run for DIMM

dimm: $(DIMM_BIN)
	./$(DIMM_BIN)

# Compile and run for Scheduler
scheduler: $(SCHEDULER_BIN)
	./$(SCHEDULER_BIN)

llc: $(LLC_BIN)
	./$(LLC_BIN)

sdram: $(SDRAM_BIN)
	./$(SDRAM_BIN)

cache: $(CACHE_BIN)
	./$(CACHE_BIN)

l1d: clean ${L1D_BIN}
	clear
	./${L1D_BIN}

# Compile and run for System Controller and DIMM testbench
llc_dimm: clean $(LLC_DIMM_BIN)
	./$(LLC_DIMM_BIN)

l1d_llc: clean $(L1D_LLC_BIN)
	./$(L1D_LLC_BIN)

# Compile with Verilator
$(DIMM_BIN):
	$(OBJCACHE) $(VERILATOR) $(DIMM_VFLAGS) $(DIMM_SRCS)

$(SCHEDULER_BIN):
	$(OBJCACHE) $(VERILATOR) $(SCHEDULER_VFLAGS) $(SCHEDULER_SRCS)

$(LLC_BIN):
	$(OBJCACHE) $(VERILATOR) $(LLC_VFLAGS) $(LLC_SRCS)

$(SDRAM_BIN):
	$(OBJCACHE) $(VERILATOR) $(SDRAM_VFLAGS) $(SDRAM_SRCS)

$(CACHE_BIN):
	$(OBJCACHE) $(VERILATOR) $(CACHE_VFLAGS) $(CACHE_SRCS)

${L1D_BIN}:
	$(OBJCACHE) $(VERILATOR) $(L1D_VFLAGS) $(L1D_SRCS)

$(LLC_DIMM_BIN):
	$(OBJCACHE) $(VERILATOR) $(LLC_DIMM_VFLAGS) $(LLC_DIMM_SRCS)

$(L1D_LLC_BIN):
	$(OBJCACHE) $(VERILATOR) $(L1D_LLC_VFLAGS) $(L1D_LLC_SRCS)

# Clean generated files
clean:
	rm -rf obj_dir $(DIMM_BIN) $(SCHEDULER_BIN) $(CACHE_BIN) $(LLC_DIMM_BIN) *.log *.dmp *.vcd

clean-dimm:
	rm -rf obj_dir/Vddr4_dimm *.log *.dmp *.vcd

clean-scheduler:
	rm -rf obj_dir/Vmem_scheduler

clean-sdram:
	rm -rf obj_dir/Vsdram_controller

clean-cache:
	rm -rf obj_dir/Vcache
	rm -rf obj_dir/Vl1_data_cache

clean-llc-dimm:
	rm -rf obj_dir/Vllc_dimm_tb *.log *.dmp *.vcd

clean-l1d-llc:
	rm -rf obj_dir/Vl1d_llc_tb *.log *.dmp *.vcd

.PHONY: all clean run dimm scheduler sdram cache llc_dimm clean-dimm clean-scheduler clean-sdram clean-cache clean-sd-ctrl-dimm