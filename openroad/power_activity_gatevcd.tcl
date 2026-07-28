# This VCD comes from the mapped ORFS netlist, not RTL.  It represents 16
# vector-word writes followed by 1024 II=1 score GEMV commands at 666.7 MHz.
set activity_vcd artifacts/attacc_gemv_gate_steady_orfs.vcd
if {![file exists $activity_vcd]} {
  error "Missing required gate-level GEMV VCD: $activity_vcd"
}
puts "INFO: Reading mapped-netlist steady-state GEMV activity from $activity_vcd"
read_vcd -scope attacc_gemv_unit $activity_vcd
