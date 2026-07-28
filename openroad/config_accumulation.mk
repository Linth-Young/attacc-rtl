# Standalone ASAP7/TC proxy-PPA configuration for the MELON accumulation unit.
export PLATFORM                = asap7
export CORNER                  = TC
export DESIGN_NAME             = melon_accumulation_unit
export DESIGN_NICKNAME         = melon_accumulation_666mhz_gatedctrl
export VERILOG_FILES           = \
  $(abspath rtl/attacc_fp16_pkg.sv) \
  $(abspath rtl/attacc_fp16_operators.sv) \
  $(abspath rtl/melon_accumulation_unit.sv)
export SDC_FILE                = $(abspath openroad/constraint_accumulation_666mhz.sdc)
export PRE_FLOORPLAN_TCL       = $(abspath openroad/power_activity.tcl)
export SYNTH_HDL_FRONTEND      = slang
export VERILOG_DEFINES         = -D OPENROAD_CLKGATE
override export DONT_USE_CELLS = SDF* ICG*
export SYNTH_ARGS              = -noalumacc -noshare
export SYNTH_MEMORY_MAX_BITS   = 16384
export ADDER_MAP_FILE          =
export ABC_AREA                = 1
export CORE_UTILIZATION        = 60
export CORE_ASPECT_RATIO       = 1
export CORE_MARGIN             = 1.0
export PLACE_DENSITY           = 0.65
export TNS_END_PERCENT         = 100
export GPL_TIMING_DRIVEN       = 0
export GPL_ROUTABILITY_DRIVEN  = 0
