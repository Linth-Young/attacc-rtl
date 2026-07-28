# Standalone ASAP7/TC proxy-PPA configuration for the MELON Vector Unit.
export PLATFORM                = asap7
export CORNER                  = TC
export DESIGN_NAME             = melon_vector_unit
export DESIGN_NICKNAME         = melon_vector_unit_666mhz_fp16act_pipe_r1
export VERILOG_FILES           = \
  $(abspath rtl/attacc_fp16_pkg.sv) \
  $(abspath rtl/attacc_fp16_operators.sv) \
  $(abspath rtl/melon_vector_unit.sv)
export SDC_FILE                = $(abspath openroad/constraint_vector_unit_666mhz.sdc)
export PRE_FLOORPLAN_TCL       = $(abspath openroad/power_activity.tcl)
export SYNTH_HDL_FRONTEND      = slang
export VERILOG_DEFINES         = -D OPENROAD_CLKGATE
export SYNTH_ARGS              = -noalumacc -noshare
export ADDER_MAP_FILE          =
export ABC_AREA                = 1
export CORE_UTILIZATION        = 60
export CORE_ASPECT_RATIO       = 1
export CORE_MARGIN             = 1.0
export PLACE_DENSITY           = 0.65
export TNS_END_PERCENT         = 100
export GPL_TIMING_DRIVEN       = 0
export GPL_ROUTABILITY_DRIVEN  = 0
# FP16 add/mul pipelines isolate the arithmetic critical paths. Keep default
# floorplan timing repair enabled for the 666 MHz proxy check.
