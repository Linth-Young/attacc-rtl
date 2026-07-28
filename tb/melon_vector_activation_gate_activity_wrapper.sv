// Continuous, handshake-correct SiLU vector commands for gate-level activity.
// The observable port prevents Yosys from dropping the activation result cone.
module melon_vector_activation_gate_activity_wrapper #(
  parameter bit SILU = 1'b1
) (
  input wire clk,
  input wire rst_n,
  output wire [15:0] activity_observe
);
  localparam integer COMMANDS = 128;
  reg [7:0] command_index;
  wire activation_ready, activation_ack, activation_out_valid;
  wire running = (command_index < COMMANDS);
  wire activation_valid = running && activation_ready;
  wire [255:0] activation_data;
  wire [255:0] activation_result;
  wire [15:0] bank_rescale, normalizer_recip, state_max_out, state_sum_out;

  function [15:0] fp16_activation_value;
    input [4:0] selector;
    begin
      case (selector[3:0])
        4'h0: fp16_activation_value = 16'hbc00; // -1.0
        4'h1: fp16_activation_value = 16'h4000; // +2.0
        4'h2: fp16_activation_value = 16'hc000; // -2.0
        4'h3: fp16_activation_value = 16'h3a00; // +0.75
        4'h4: fp16_activation_value = 16'h4200; // +3.0
        4'h5: fp16_activation_value = 16'hb800; // -0.5
        4'h6: fp16_activation_value = 16'h3e00; // +1.5
        4'h7: fp16_activation_value = 16'hc200; // -3.0
        4'h8: fp16_activation_value = 16'h3400; // +0.25
        4'h9: fp16_activation_value = 16'hbe00; // -1.5
        4'ha: fp16_activation_value = 16'h4400; // +4.0
        4'hb: fp16_activation_value = 16'hb400; // -0.25
        4'hc: fp16_activation_value = 16'h3c00; // +1.0
        4'hd: fp16_activation_value = 16'hc400; // -4.0
        4'he: fp16_activation_value = 16'h3800; // +0.5
        default: fp16_activation_value = 16'hba00; // -0.75
      endcase
    end
  endfunction

  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
      assign activation_data[lane*16 +: 16] =
        fp16_activation_value(command_index[3:0] + lane[3:0]);
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (activation_valid) command_index <= command_index + 1'b1;
  end

  melon_vector_unit dut (
    .clk(clk), .rst_n(rst_n), .state_reset(1'b0),
    .tile_valid(1'b0), .tile_last(1'b0), .tile_head_id(5'd0),
    .tile_state_reset(1'b0), .score_data('0),
    .tile_ready(), .tile_ack(), .bank_rescale(bank_rescale),
    .normalizer_recip(normalizer_recip), .weight_data(), .weight_valid(),
    .sequence_done(), .state_max_out(state_max_out), .state_sum_out(state_sum_out),
    .activation_valid(activation_valid), .activation_ready(activation_ready),
    .activation_silu(SILU), .activation_data(activation_data),
    .activation_ack(activation_ack), .activation_out_valid(activation_out_valid),
    .activation_result(activation_result)
  );

  assign activity_observe = activation_result[15:0] ^ activation_result[255:240] ^
                            state_max_out ^ state_sum_out ^ bank_rescale ^ normalizer_recip ^
                            {{15{1'b0}}, activation_ack} ^ {{15{1'b0}}, activation_out_valid};
endmodule
