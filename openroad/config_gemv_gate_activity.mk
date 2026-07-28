# Same implementation settings as config.mk, with a fresh result namespace
# and a mandatory mapped-netlist activity trace for dynamic-power estimation.
include $(abspath openroad/config.mk)

export DESIGN_NICKNAME         = attacc_gemv_666mhz_gatevcd
export PRE_FLOORPLAN_TCL       = $(abspath openroad/power_activity_gatevcd.tcl)
