# Import an activity trace only when one is available. A VCD must be generated
# from the exact same RTL hierarchy; otherwise it is invalid for power claims.
set activity_vcd artifacts/attacc_gemv_activity.vcd
if {[file exists $activity_vcd]} {
  read_vcd -scope attacc_gemv_unit_tb.dut $activity_vcd
} else {
  puts "INFO: No VCD found; OpenROAD will use vectorless default activity."
}
