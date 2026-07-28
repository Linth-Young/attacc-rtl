# Standalone ASAP7/TC proxy-PPA configuration for the MELON Vector Unit.
ATTACC_RTL_HOME              := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
export PLATFORM                = asap7
export CORNER                  = TC
export DESIGN_NAME             = melon_vector_unit
export DESIGN_NICKNAME         = melon_vector_unit_666mhz_fp16parallel_r9_headpipe
export VERILOG_FILES           = \
  $(ATTACC_RTL_HOME)/rtl/attacc_fp16_pkg.sv \
  $(ATTACC_RTL_HOME)/rtl/attacc_fp16_operators.sv \
  $(ATTACC_RTL_HOME)/rtl/melon_vector_unit.sv
export SDC_FILE                = $(ATTACC_RTL_HOME)/openroad/constraint_vector_unit_666mhz.sdc
export PRE_FLOORPLAN_TCL       = $(ATTACC_RTL_HOME)/openroad/power_activity.tcl
export SYNTH_HDL_FRONTEND      = slang
export VERILOG_DEFINES         = -D OPENROAD_CLKGATE
# Resource sharing must remain enabled for this 16-lane hierarchical design:
# the RTL owns one named arithmetic pipeline per lane; disabling all sharing
# makes Yosys expand equivalent LUT-control cones before technology mapping.
export SYNTH_ARGS              = -noalumacc
# Map each replicated FP16 pipeline as an explicit hierarchy.  This prevents
# ABC from constructing one monolithic Boolean network for the full 16-lane
# Vector Unit while retaining every lane instance in the mapped netlist.
export SYNTH_HIERARCHICAL      = 1
export SYNTH_KEEP_MODULES      = attacc_fp16_add_fast_pipe attacc_fp16_exp_neg_pipe attacc_fp16_recip_pipe attacc_fp16_sigmoid_pipe attacc_fp16_mul_pipe
export ADDER_MAP_FILE          =
# The speed script is materially less memory-hungry than the area script for
# a fully expanded FP16 lane array; it is still a mapped ASAP7 proxy result.
export ABC_AREA                = 0
export CORE_UTILIZATION        = 60
export CORE_ASPECT_RATIO       = 1
export CORE_MARGIN             = 1.0
export PLACE_DENSITY           = 0.65
export TNS_END_PERCENT         = 100
export GPL_TIMING_DRIVEN       = 0
export GPL_ROUTABILITY_DRIVEN  = 0
# FP16 add/mul pipelines isolate the arithmetic critical paths. Keep default
# floorplan timing repair enabled for the 666 MHz proxy check.
