# Re-evaluate the already generated 666 MHz floorplan database with a mapped
# netlist VCD.  This avoids changing synthesis/P&R when only activity changes.
set lib_dir /OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM
read_liberty $lib_dir/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib.gz
read_liberty $lib_dir/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib.gz
read_liberty $lib_dir/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib.gz
read_liberty $lib_dir/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
read_liberty $lib_dir/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib.gz
read_db results/asap7/attacc_gemv_666mhz_sdcfix/base/2_1_floorplan.odb
read_sdc results/asap7/attacc_gemv_666mhz_sdcfix/base/2_1_floorplan.sdc
read_vcd -scope attacc_gemv_unit artifacts/attacc_gemv_gate_steady_orfs.vcd
report_power -digits 6
exit
