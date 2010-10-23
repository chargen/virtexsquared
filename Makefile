RUNTIME := $(shell date +R%Y%m%d-%H%M)
RUN ?= $(RUNTIME)
RUNDIR ?= runs/$(RUN)

default:
	@echo "targets:"
	@echo "  fpga         runs a complete pass through the tool flow"
	@echo "  sim          produces a Verilator binary"
	@echo "  tests        rebuilds tests"
	@echo "  auto         re-autoizes all RTL"
	@echo ""
	@echo "variables:"
	@echo "  RUN=[...]    name of run (for runs/ directory; defaults to date+time)"
	@echo
	@echo "error: you must specify a valid target"
	@exit 1

###############################################################################

sim-genrtl: .DUMMY $(RUNDIR)/stamps/sim-genrtl

$(RUNDIR)/stamps/sim-genrtl:
	@echo "Copying RTL for simulation to $(RUNDIR)/sim/rtl..."
	@mkdir -p $(RUNDIR)/stamps
	@mkdir -p $(RUNDIR)/sim/rtl
	@cp `find rtl -iname '*.v' | grep -v fpga/` $(RUNDIR)/sim/rtl
	@cp `find rtl -iname '*.vh' | grep -v fpga/` $(RUNDIR)/sim/rtl
	@echo "Copying testbench for simulation to $(RUNDIR)/sim..."
	@cp sim/* $(RUNDIR)/sim
	@touch $(RUNDIR)/stamps/sim-genrtl

sim-verilate: .DUMMY $(RUNDIR)/stamps/sim-verilate

$(RUNDIR)/stamps/sim-verilate: $(RUNDIR)/stamps/sim-genrtl
	@echo "Building simulator source with Verilator into $(RUNDIR)/sim/obj_dir..."
	@mkdir -p $(RUNDIR)/sim/obj_dir
	cd $(RUNDIR)/sim; verilator -Irtl --cc rtl/system.v testbench.cpp --exe --assert
	@touch $(RUNDIR)/stamps/sim-verilate

sim-build: .DUMMY $(RUNDIR)/stamps/sim-build

$(RUNDIR)/stamps/sim-build: $(RUNDIR)/stamps/sim-verilate
	@echo "Building simulator from Verilated source into $(RUNDIR)/sim/obj_dir..."
	make -C $(RUNDIR)/sim/obj_dir -f Vsystem.mk
	ln -sf obj_dir/Vsystem $(RUNDIR)/sim/
	@touch $(RUNDIR)/stamps/sim-build

sim: .DUMMY $(RUNDIR)/stamps/sim

$(RUNDIR)/stamps/sim: $(RUNDIR)/stamps/sim-build
	@echo "Simulator built in $(RUNDIR)/sim."
	@touch $(RUNDIR)/stamps/sim

###############################################################################

FPGA_TARGET = FireARM

# not actually used? also needs to be changed in fgpa/xst/FireARM.xst
PART = xc5vlx110t-ff1136-2

# XXX: should we generate the .xst file?
fpga-genrtl: .DUMMY $(RUNDIR)/stamps/fpga-genrtl

$(RUNDIR)/stamps/fpga-genrtl:
	@echo "FPGA RTL is currently UNSYNTHESIZABLE...?"
	@echo "Copying RTL for synthesis to $(RUNDIR)/fpga/xst..."
	@mkdir -p $(RUNDIR)/stamps
	@mkdir -p $(RUNDIR)/fpga/xst
	@cp `find rtl -iname '*.v' | grep -v sim/` $(RUNDIR)/fpga/xst
	@cp `find rtl -iname '*.vh' | grep -v sim/` $(RUNDIR)/fpga/xst
	@echo "Copying XST configuration to $(RUNDIR)/fpga/xst..."
	@mkdir -p $(RUNDIR)/fpga/xst/xst/projnav.tmp
	@echo work > $(RUNDIR)/fpga/xst/$(FPGA_TARGET).lso
	@rm -rf $(RUNDIR)/fpga/xst/$(FPGA_TARGET).prj
	@cd $(RUNDIR)/fpga/xst; for i in *.v; do echo verilog work '"'$$i'"' >> $(FPGA_TARGET).prj; done
	@cp fpga/xst/* $(RUNDIR)/fpga/xst
	@touch $(RUNDIR)/stamps/fpga-genrtl

fpga-synth: .DUMMY $(RUNDIR)/stamps/fpga-synth

$(RUNDIR)/stamps/fpga-synth: $(RUNDIR)/stamps/fpga-genrtl
	@echo "Synthesizing in $(RUNDIR)/fpga/xst..."
	@touch $(RUNDIR)/stamps/fpga-synth-start
	cd $(RUNDIR)/fpga/xst; xst -ifn $(FPGA_TARGET).xst -ofn $(FPGA_TARGET).syr
	@touch $(RUNDIR)/stamps/fpga-synth

fpga-xflow-prep: .DUMMY $(RUNDIR)/stamps/fpga-xflow-prep

$(RUNDIR)/stamps/fpga-xflow-prep: $(RUNDIR)/stamps/fpga-synth
	@echo "Copying files for back-end flow to $(RUNDIR)/fpga/xflow..."
	@mkdir -p $(RUNDIR)/fpga/xflow
	@cp fpga/xflow/* $(RUNDIR)/fpga/xflow
	@cp $(RUNDIR)/fpga/xst/$(FPGA_TARGET).ngc $(RUNDIR)/fpga/xflow
	@touch $(RUNDIR)/stamps/fpga-xflow-prep

fpga-xflow: .DUMMY $(RUNDIR)/stamps/fpga-xflow

$(RUNDIR)/stamps/fpga-xflow: $(RUNDIR)/stamps/fpga-xflow-prep
	@echo "Running back-end flow in $(RUNDIR)/fpga/xflow..."
	@touch $(RUNDIR)/stamps/fpga-xflow-start
	cd $(RUNDIR)/fpga/xflow; xflow -p $(PART) -implement balanced.opt -config bitgen.opt $(FPGA_TARGET).ngc
	@touch $(RUNDIR)/stamps/fpga-xflow
	@ln -s xflow/$(FPGA_TARGET).bit $(RUNDIR)/fpga/
	@echo "Bit file generated in $(RUNDIR)/fpga/xflow."
	@echo -en "\n\n\n"
	@figlet "Bit file generated! Go program the FPGA now."
	@echo -en "\n\n\n"

fpga-cdc: .DUMMY $(RUNDIR)/stamps/fpga-cdc

$(RUNDIR)/stamps/fpga-cdc: $(RUNDIR)/stamps/fpga-xflow
	@echo "Generating CDC file..."
	@touch $(RUNDIR)/stamps/fpga-cdc-start
	rm -f $(RUNDIR)/fpga/xflow/$(FPGA_TARGET)_fpga_edline.*
	cd $(RUNDIR)/fpga/xflow; echo "Y" | fpga_edline -p cdc_script.scr $(FPGA_TARGET).ncd $(FPGA_TARGET).pcf
	@echo "CDC file generated in $(RUNDIR)/fpga/xflow."
	@touch $(RUNDIR)/stamps/fpga-cdc

fpga: .DUMMY $(RUNDIR)/stamps/fpga

$(RUNDIR)/stamps/fpga: $(RUNDIR)/stamps/fpga-cdc
	@echo "Done!!!"
	@touch $(RUNDIR)/stamps/fpga

###############################################################################


auto: .DUMMY
	emacs -l ~/elisp/verilog-mode.el --batch `find rtl -iname '*.v'` -f verilog-batch-auto

tests: .DUMMY
	make -C tests

.DUMMY:
