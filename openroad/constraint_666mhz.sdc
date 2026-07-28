create_clock -name gemv_clk -period 1500 [get_ports clk]
create_generated_clock -name gemv_gclk -source [get_ports clk] -divide_by 1 [get_nets -regexp {.*gclk.*}]
set_clock_uncertainty -setup 50 [get_clocks gemv_clk]
set_clock_uncertainty -hold 0 [get_clocks gemv_clk]
set_clock_uncertainty -setup 50 [get_clocks gemv_gclk]
set_clock_uncertainty -hold 0 [get_clocks gemv_gclk]

# This is a bank-local macro measurement, not a package-I/O timing contract.
set_false_path -from [get_ports rst_n]
set_input_delay 0.000 -clock gemv_clk [get_ports {vector_wr_en vector_wr_buffer vector_wr_index vector_wr_data swap_vector_buffers op_valid mode_tree op_clear_acc op_vector_word op_broadcast_lane op_acc_slot matrix_data}]
set_output_delay 0.000 -clock gemv_clk [all_outputs]
