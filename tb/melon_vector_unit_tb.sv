`timescale 1ns/1ps

module melon_vector_unit_tb;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic state_reset, tile_valid, tile_last;
  logic [255:0] score_data;
  logic tile_ready, tile_ack;
  logic [15:0] bank_rescale, normalizer_recip;
  logic [255:0] weight_data;
  logic weight_valid, sequence_done;
  logic [15:0] state_max_out, state_sum_out;
  logic activation_valid, activation_ready, activation_silu;
  logic [255:0] activation_data, activation_result;
  logic activation_ack, activation_out_valid;
  integer lane;

  always #0.75 clk = ~clk;

  melon_vector_unit dut (
    .clk, .rst_n, .state_reset, .tile_valid, .tile_last, .score_data,
    .tile_ready, .tile_ack, .bank_rescale, .normalizer_recip, .weight_data,
    .weight_valid, .sequence_done, .state_max_out, .state_sum_out,
    .activation_valid, .activation_ready, .activation_silu, .activation_data,
    .activation_ack, .activation_out_valid, .activation_result
  );

  task automatic send_uniform_zero_tile;
    begin
      @(negedge clk);
      while (!tile_ready) @(negedge clk);
      state_reset = 1'b1;
      tile_last = 1'b1;
      tile_valid = 1'b1;
      @(negedge clk);
      tile_valid = 1'b0;
      state_reset = 1'b0;
    end
  endtask

  task automatic send_relu;
    begin
      @(negedge clk);
      while (!activation_ready) @(negedge clk);
      activation_silu = 1'b0;
      activation_valid = 1'b1;
      @(negedge clk);
      activation_valid = 1'b0;
    end
  endtask

  initial begin
    state_reset = 0; tile_valid = 0; tile_last = 0; score_data = '0;
    activation_valid = 0; activation_silu = 0; activation_data = '0;
    for (lane = 0; lane < 16; lane = lane + 1) score_data[lane*16 +: 16] = 16'h0000;
    activation_data[0 +: 16] = 16'hbc00; // -1.0
    activation_data[16 +: 16] = 16'h4000; // +2.0
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    send_uniform_zero_tile();
    wait (tile_ack);
    #0.1;
    if (!weight_valid || !sequence_done || state_sum_out != 16'h4c00 ||
        normalizer_recip != 16'h2c00)
      $fatal(1, "FP16 softmax state failed: sum=%h recip=%h", state_sum_out, normalizer_recip);
    for (lane = 0; lane < 16; lane = lane + 1)
      if (weight_data[lane*16 +: 16] != 16'h3c00)
        $fatal(1, "FP16 exp weight lane %0d = %h", lane, weight_data[lane*16 +: 16]);

    send_relu();
    wait (activation_ack);
    #0.1;
    if (!activation_out_valid || activation_result[0 +: 16] != 16'h0000 ||
        activation_result[16 +: 16] != 16'h4000)
      $fatal(1, "ReLU failed: lane0=%h lane1=%h", activation_result[0 +: 16], activation_result[16 +: 16]);

    $display("melon_vector_unit_tb PASS");
    $finish;
  end
endmodule
