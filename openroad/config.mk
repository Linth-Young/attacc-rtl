# Out-of-tree ORFS configuration for the AttAcc bank-level GEMV unit.
# Results are deliberately written under this repository by invoking the ORFS
# Makefile from the attacc_simulator directory with WORK_HOME=.
export PLATFORM                = asap7
export CORNER                  = TC
export DESIGN_NAME             = attacc_gemv_unit
export DESIGN_NICKNAME         = attacc_gemv_666mhz_stream4fwd_streamout_wcg

export VERILOG_FILES           = \
  $(abspath rtl/attacc_fp16_pkg.sv) \
  $(abspath rtl/attacc_fp16_operators.sv) \
  $(abspath rtl/attacc_gemv_unit.sv)
export SDC_FILE                = $(abspath openroad/constraint_666mhz.sdc)
export PRE_FLOORPLAN_TCL       = $(abspath openroad/power_activity.tcl)
export SYNTH_HDL_FRONTEND      = slang
export VERILOG_DEFINES         = -D OPENROAD_CLKGATE
# The platform disables ASAP7 xp/x1p cells globally to ease congestion in
# large SoCs.  This bank-local block is only 0.009 mm2, and its floorplan
# remains above 666 MHz with these smaller cells enabled.  Keep only the
# invalid sequential/clock-gate patterns excluded.
override export DONT_USE_CELLS = SDF* ICG*
# SAT-based arithmetic-resource sharing is disproportionally expensive for the
# parameterized FP16 datapath and is not needed: the RTL already fixes the
# intended 16-multiplier/16-adder sharing structure.
export SYNTH_ARGS              = -noalumacc -noshare
# Two 16 x 256-bit vector-buffer banks are represented as RTL memories.  This
# is a synthesis-limit setting, not a request for an SRAM macro.
export SYNTH_MEMORY_MAX_BITS   = 16384
# The ASAP7 optional full-adder mapper is prohibitively expensive on the
# behavioral IEEE-754 arithmetic.  Use normal ABC standard-cell mapping for a
# reproducible full-unit baseline; this favors area and leaves timing honest.
export ADDER_MAP_FILE           =
export ABC_AREA                 = 1

# Area-oriented core target.  The flow may enlarge this if routability needs it.
export CORE_UTILIZATION        = 60
export CORE_ASPECT_RATIO       = 1
export CORE_MARGIN             = 1.0
export PLACE_DENSITY           = 0.65
export TNS_END_PERCENT         = 100
# Keep this architecture exploration reproducible and area-oriented.  Full
# timing/routability repair is reserved for a later post-route signoff run.
export GPL_TIMING_DRIVEN       = 0
export GPL_ROUTABILITY_DRIVEN  = 0
