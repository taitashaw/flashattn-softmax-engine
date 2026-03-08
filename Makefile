# ===========================================================================
# Hardened Softmax Pipeline — Master Makefile
# ===========================================================================
# Targets:
#   make golden         Phase 1: Python golden model + HBM analysis
#   make lint           Phase 3: Verilator lint check (fastest feedback)
#   make sim            Phase 3: Verilator simulation → VCD → GTKWave
#   make xsim           Phase 4: Vivado xsim simulation → WDB waveform
#   make xsim_gui       Phase 4: Vivado xsim in GUI mode (waveform viewer)
#   make synth          Phase 4: Vivado standalone synthesis + implementation
#   make block_design   Phase 4: Vivado block design (Zynq PS + IP + bitstream)
#   make regression     Phase 5: Full regression (lint + sim)
#   make clean          Clean all build artifacts
# ===========================================================================

SHELL := /bin/bash

# Source files
RTL_SRCS := rtl/pipelined_exp.sv rtl/online_softmax_exact.sv \
            rtl/fp8_convert.sv rtl/flashattn_softmax_top.sv

TB_SRCS  := tb/tb_top.sv

# Tool paths
VERILATOR  ?= verilator
VIVADO     ?= vivado
GTKWAVE    ?= gtkwave
PYTHON     ?= python3

# Verilator flags
VL_FLAGS := --binary --trace --timing \
    --top-module tb_top \
    -Wall \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-UNDRIVEN -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED -Wno-WIDTHCONCAT \
    -Wno-MULTITOP -Wno-DECLFILENAME \
    -Wno-BLKSEQ -Wno-INITIALDLY \
    -CFLAGS "-std=c++17" \
    -o flashattn_sim

# Verilator lint flags
LINT_FLAGS := --lint-only -Wall \
    --top-module flashattn_softmax_top \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-UNDRIVEN -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED -Wno-WIDTHCONCAT \
    -Wno-MULTITOP -Wno-DECLFILENAME

# Build directory
BUILD := build

# ===========================================================================
# Phase 1: Golden Model
# ===========================================================================
.PHONY: golden
golden:
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 1: Golden Model + HBM Analysis"
	@echo "═══════════════════════════════════════════"
	cd model && $(PYTHON) golden_model.py --hbm_analysis --test_fp8 --gen_vectors 64

# ===========================================================================
# Phase 3: Verilator Lint (instant feedback)
# ===========================================================================
.PHONY: lint
lint:
	@echo "Phase 3: Verilator lint"
	$(VERILATOR) $(LINT_FLAGS) $(RTL_SRCS)
	@echo "LINT PASSED"

# ===========================================================================
# Phase 3/5: Verilator Simulation → VCD
# ===========================================================================
$(BUILD):
	mkdir -p $(BUILD)

.PHONY: sim
sim: $(BUILD)
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 3: Verilator Simulation"
	@echo "═══════════════════════════════════════════"
	cd $(BUILD) && $(VERILATOR) $(VL_FLAGS) \
		$(addprefix ../,$(RTL_SRCS)) \
		$(addprefix ../,$(TB_SRCS))
	cd $(BUILD)/obj_dir && ./flashattn_sim
	@echo ""
	@echo "  VCD waveform: $(BUILD)/obj_dir/flashattn_softmax.vcd"
	@echo "  Open with:    make wave"

.PHONY: wave
wave:
	$(GTKWAVE) $(BUILD)/obj_dir/flashattn_softmax.vcd &

# ===========================================================================
# Phase 4: Vivado xsim Simulation
# ===========================================================================
.PHONY: xsim
xsim:
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 4: Vivado xsim Simulation (batch)"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/sim_build
	cd vivado/sim_build && $(VIVADO) -mode batch -source ../sim.tcl 2>&1 | tee xsim.log
	@echo ""
	@echo "  Log: vivado/sim_build/xsim.log"
	@echo "  WDB: vivado/sim_build/sim_project/*.sim/sim_1/behav/xsim/*.wdb"

.PHONY: xsim_gui
xsim_gui:
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 4: Vivado xsim (GUI — waveforms)"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/sim_build
	cd vivado/sim_build && $(VIVADO) -mode gui -source ../sim.tcl

# ===========================================================================
# Phase 4: Vivado Synthesis + Implementation (standalone RTL)
# ===========================================================================
.PHONY: synth
synth:
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 4: Vivado Synthesis + Impl"
	@echo "  Target: ZCU104 (xczu7ev-ffvc1156-2-e)"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/synth_build
	cd vivado/synth_build && $(VIVADO) -mode batch -source ../synth.tcl 2>&1 | tee synth.log
	@echo ""
	@echo "  Reports:"
	@echo "    vivado/synth_build/utilization_synth.rpt"
	@echo "    vivado/synth_build/timing_synth.rpt"
	@echo "    vivado/synth_build/power_synth.rpt"
	@echo "    vivado/synth_build/utilization_impl.rpt"
	@echo "    vivado/synth_build/timing_impl.rpt"

# ===========================================================================
# Phase 4: Vivado Block Design (Zynq PS + IP + Bitstream)
# ===========================================================================
.PHONY: block_design
block_design:
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 4: Block Design + Bitstream"
	@echo "  Target: ZCU104 Zynq UltraScale+ SoC"
	@echo "═══════════════════════════════════════════"
	mkdir -p vivado/bd_build
	cd vivado/bd_build && $(VIVADO) -mode batch -source ../block_design.tcl 2>&1 | tee bd_build.log
	@echo ""
	@echo "  Bitstream: vivado/bd_build/flashattn_soc.runs/impl_1/*_wrapper.bit"
	@echo "  XSA:       vivado/bd_build/flashattn_soc.xsa"

.PHONY: block_design_gui
block_design_gui:
	@echo "  Opening block design in Vivado GUI..."
	mkdir -p vivado/bd_build
	cd vivado/bd_build && $(VIVADO) -mode gui -source ../block_design.tcl

# ===========================================================================
# Phase 5: Full Regression
# ===========================================================================
.PHONY: regression
regression: lint sim
	@echo "═══════════════════════════════════════════"
	@echo "  Phase 5: Full Regression"
	@echo "═══════════════════════════════════════════"
	@echo "  [1/3] Verilator lint ........ DONE"
	@echo "  [2/3] Verilator sim ......... DONE"
	@echo "  [3/3] Golden model .........."
	cd model && $(PYTHON) golden_model.py --gen_vectors 16
	@echo "  [3/3] Golden model .......... DONE"
	@echo ""
	@echo "  REGRESSION COMPLETE"

# ===========================================================================
# Clean
# ===========================================================================
.PHONY: clean
clean:
	rm -rf $(BUILD)
	rm -rf vivado/sim_build vivado/synth_build vivado/bd_build
	rm -rf model/vectors
	rm -f *.vcd *.log *.jou

# ===========================================================================
# Help
# ===========================================================================
.PHONY: help
help:
	@echo ""
	@echo "  Hardened Softmax Pipeline — Build Targets"
	@echo "  ========================================="
	@echo ""
	@echo "  No Xilinx tools required:"
	@echo "    make golden         Python golden model + HBM analysis"
	@echo "    make lint           Verilator lint (instant)"
	@echo "    make sim            Verilator simulation → VCD"
	@echo "    make wave           Open VCD in GTKWave"
	@echo "    make regression     Full regression (lint + sim + golden)"
	@echo ""
	@echo "  Requires Vivado 2024.1+:"
	@echo "    make xsim           Vivado xsim simulation (batch)"
	@echo "    make xsim_gui       Vivado xsim with waveform viewer"
	@echo "    make synth          Synthesis + implementation (standalone)"
	@echo "    make block_design   Full SoC: Zynq PS + IP + bitstream"
	@echo "    make block_design_gui  Block design in Vivado GUI"
	@echo ""
	@echo "  Utilities:"
	@echo "    make clean          Remove all build artifacts"
	@echo ""
