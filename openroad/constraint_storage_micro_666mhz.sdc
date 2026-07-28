create_clock -name core_clk -period 1500 [get_ports clk]
# ORFS preserves this explicit gate output as u_*_clkgate.GCK. Keep it as a
# derived clock so the storage-only microbench uses the full RTL's gating.
create_generated_clock -name storage_gclk -source [get_ports clk] -divide_by 1 [get_nets -regexp {.*(GCK|gclk).*}]
set_clock_uncertainty -setup 50 [get_clocks core_clk]
set_clock_uncertainty -hold 0 [get_clocks core_clk]
set_clock_uncertainty -setup 50 [get_clocks storage_gclk]
set_clock_uncertainty -hold 0 [get_clocks storage_gclk]
set_false_path -from [get_ports rst_n]
