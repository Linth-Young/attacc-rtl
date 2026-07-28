# Workload-specific dynamic power for the r9 cross-head pipelined Vector Unit.
# Usage: VECTOR_ACTIVITY_VCD=artifacts/<trace>.vcd openroad -no_init -exit
#        openroad/report_vector_vcd.tcl
if {![info exists ::env(VECTOR_ACTIVITY_VCD)]} {
  error "set VECTOR_ACTIVITY_VCD to a normalized gate VCD"
}
set activity_vcd $::env(VECTOR_ACTIVITY_VCD)
set lib_dir /OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM
read_liberty $lib_dir/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib.gz
read_liberty $lib_dir/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib.gz
read_liberty $lib_dir/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib.gz
read_liberty $lib_dir/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty $lib_dir/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib.gz
read_db results/asap7/melon_vector_unit_666mhz_fp16parallel_r9_headpipe/base/2_1_floorplan.odb
read_sdc results/asap7/melon_vector_unit_666mhz_fp16parallel_r9_headpipe/base/2_1_floorplan.sdc
read_vcd -scope melon_vector_unit $activity_vcd
report_power -digits 6
exit
