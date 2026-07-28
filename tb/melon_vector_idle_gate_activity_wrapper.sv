// Idle baseline for incremental Vector command energy.  It uses the same
// clock/reset waveform as the active wrappers, with no accepted instruction.
module melon_vector_idle_gate_activity_wrapper (
  input wire clk,
  input wire rst_n,
  output wire [15:0] activity_observe
);
  wire [15:0] bank_rescale, normalizer_recip, state_max_out, state_sum_out;
  wire [255:0] weight_data, activation_result;
  wire tile_ack, weight_valid, sequence_done, activation_ready;
  wire activation_ack, activation_out_valid;

  melon_vector_unit dut (
    .clk(clk), .rst_n(rst_n), .state_reset(1'b0),
    .tile_valid(1'b0), .tile_last(1'b0), .tile_head_id(5'd0),
    .tile_state_reset(1'b0), .score_data('0),
    .tile_ready(), .tile_ack(tile_ack), .bank_rescale(bank_rescale),
    .normalizer_recip(normalizer_recip), .weight_data(weight_data), .weight_valid(weight_valid),
    .sequence_done(sequence_done), .state_max_out(state_max_out), .state_sum_out(state_sum_out),
    .activation_valid(1'b0), .activation_ready(activation_ready), .activation_silu(1'b0),
    .activation_data('0), .activation_ack(activation_ack), .activation_out_valid(activation_out_valid),
    .activation_result(activation_result)
  );
  assign activity_observe = bank_rescale ^ normalizer_recip ^ state_max_out ^ state_sum_out ^
                            weight_data[15:0] ^ activation_result[15:0] ^
                            {{13{1'b0}}, tile_ack, weight_valid, sequence_done};
endmodule
