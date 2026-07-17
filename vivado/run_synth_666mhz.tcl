# Functional/timing synthesis flow for the pipelined AttAcc GEMV datapath.
# The locally installed UltraScale+ device is used only to check the 1.5 ns
# requirement; this does not claim that a DRAM-die PIM unit is FPGA fabric.
set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file normalize [file join $root artifacts vivado_gemv_666mhz]]
file mkdir $out
set_param general.maxThreads 1

read_verilog -sv [file join $root tb openroad_clkgate_sim.sv]
read_verilog -sv [file join $root rtl attacc_fp16_pkg.sv]
read_verilog -sv [file join $root rtl attacc_fp16_operators.sv]
read_verilog -sv [file join $root rtl attacc_gemv_unit.sv]

synth_design -top attacc_gemv_unit -part xcu30-fbvb900-2-e -flatten_hierarchy none
read_xdc [file join $root vivado attacc_gemv_666mhz.xdc]
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -delay_type max -max_paths 20 -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]
report_power -file [file join $out power.rpt]
write_checkpoint -force [file join $out attacc_gemv_666mhz_routed.dcp]

set slack [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]]
puts "ATTACC_666MHZ_WNS_NS=$slack"
if {$slack < 0.0} {
  puts "ATTACC_666MHZ_STATUS=FAIL"
  exit 2
}
puts "ATTACC_666MHZ_STATUS=PASS"
exit 0
