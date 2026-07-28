// Continuous online-softmax tile traffic for mapped-netlist activity.
// tile_valid is qualified by tile_ready, accurately preserving the Vector
// Unit's eight-stage inter-tile state dependency.
module melon_vector_gate_activity_wrapper (
  input wire clk,
  input wire rst_n
);
  localparam integer TILES = 128;
  reg [7:0] tile_index;
  wire tile_ready, tile_ack, weight_valid, sequence_done;
  wire running = (tile_index < TILES);
  wire tile_valid = running && tile_ready;
  wire state_reset = (tile_index == 0) && tile_ready;
  wire tile_last = (tile_index[3:0] == 4'hf);
  wire [255:0] score_data;
  wire [15:0] bank_rescale, normalizer_recip, state_max_out, state_sum_out;
  wire [255:0] weight_data;

  function [15:0] fp16_score_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_score_value = 16'h3c00;
        4'h1: fp16_score_value = 16'hbc00;
        4'h2: fp16_score_value = 16'h4000;
        4'h3: fp16_score_value = 16'h3a00;
        4'h4: fp16_score_value = 16'hbe00;
        4'h5: fp16_score_value = 16'h4200;
        4'h6: fp16_score_value = 16'h3400;
        4'h7: fp16_score_value = 16'hc000;
        4'h8: fp16_score_value = 16'h3d00;
        4'h9: fp16_score_value = 16'h4400;
        4'ha: fp16_score_value = 16'hb900;
        4'hb: fp16_score_value = 16'h3f00;
        4'hc: fp16_score_value = 16'h4300;
        4'hd: fp16_score_value = 16'hb600;
        4'he: fp16_score_value = 16'h4080;
        default: fp16_score_value = 16'h3b00;
      endcase
    end
  endfunction

  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
      assign score_data[lane*16 +: 16] =
        fp16_score_value(tile_index[3:0] + lane[3:0]);
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) tile_index <= '0;
    else if (tile_valid) tile_index <= tile_index + 1'b1;
  end

  melon_vector_unit dut (
    .clk(clk), .rst_n(rst_n), .state_reset(state_reset),
    .tile_valid(tile_valid), .tile_last(tile_last), .score_data(score_data),
    .tile_ready(tile_ready), .tile_ack(tile_ack), .bank_rescale(bank_rescale),
    .normalizer_recip(normalizer_recip), .weight_data(weight_data),
    .weight_valid(weight_valid), .sequence_done(sequence_done),
    .state_max_out(state_max_out), .state_sum_out(state_sum_out),
    .activation_valid(1'b0), .activation_ready(), .activation_silu(1'b0),
    .activation_data('0), .activation_ack(), .activation_out_valid(),
    .activation_result()
  );
endmodule
