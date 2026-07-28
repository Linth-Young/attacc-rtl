`timescale 1ns/1ps

module melon_vector_unit_tb;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic state_reset, tile_valid, tile_last, tile_state_reset;
  logic [1:0] tile_head_id;
  logic [255:0] score_data;
  logic tile_ready, tile_ack;
  logic [1:0] ack_head_id, weight_head_id;
  logic [15:0] bank_rescale, normalizer_recip;
  logic [255:0] weight_data;
  logic weight_valid, sequence_done;
  logic [15:0] state_max_out, state_sum_out;
  logic activation_valid, activation_ready, activation_silu;
  logic [255:0] activation_data, activation_result;
  logic activation_ack, activation_out_valid;
  integer lane, head, ack_count, weight_count;

  always #0.75 clk = ~clk;

  melon_vector_unit #(.HEADS(4)) dut (
    .clk, .rst_n, .state_reset, .tile_valid, .tile_last, .tile_head_id,
    .tile_state_reset, .score_data,
    .tile_ready, .tile_ack, .ack_head_id, .bank_rescale, .normalizer_recip,
    .weight_data, .weight_valid, .weight_head_id, .sequence_done,
    .state_max_out, .state_sum_out,
    .activation_valid, .activation_ready, .activation_silu, .activation_data,
    .activation_ack, .activation_out_valid, .activation_result
  );

  task automatic send_uniform_zero_tile(input logic [1:0] head, input logic fresh, input logic last);
    begin
      @(negedge clk);
      while (!tile_ready) @(negedge clk);
      state_reset = 1'b0;
      tile_head_id = head;
      tile_state_reset = fresh;
      tile_last = last;
      tile_valid = 1'b1;
      @(negedge clk);
      tile_valid = 1'b0;
      tile_state_reset = 1'b0;
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
    state_reset = 0; tile_valid = 0; tile_last = 0; tile_head_id = '0; tile_state_reset = 0; score_data = '0;
    activation_valid = 0; activation_silu = 0; activation_data = '0;
    for (lane = 0; lane < 16; lane = lane + 1) score_data[lane*16 +: 16] = 16'h0000;
    activation_data[0 +: 16] = 16'hbc00; // -1.0
    activation_data[16 +: 16] = 16'h4000; // +2.0
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Four different heads must be accepted in four consecutive cycles.
    // This is the cross-head II=1 behavior that the former single-tile FSM
    // could not provide.
    @(negedge clk);
    for (head = 0; head < 4; head = head + 1) begin
      tile_head_id = head[1:0];
      tile_state_reset = 1'b1;
      tile_last = 1'b0;
      tile_valid = 1'b1;
      #0.1;
      if (!tile_ready) $fatal(1, "head %0d was not accepted at II=1", head);
      @(negedge clk);
    end
    tile_valid = 1'b0;
    tile_state_reset = 1'b0;

    ack_count = 0;
    weight_count = 0;
    while (ack_count < 4) begin
      @(negedge clk);
      if (weight_valid) begin
        if (weight_head_id != weight_count[1:0])
          $fatal(1, "weight tag order failed: got %0d expected %0d",
                 weight_head_id, weight_count);
        for (lane = 0; lane < 16; lane = lane + 1)
          if (weight_data[lane*16 +: 16] != 16'h3c00)
            $fatal(1, "FP16 exp weight lane %0d = %h",
                   lane, weight_data[lane*16 +: 16]);
        weight_count = weight_count + 1;
      end
      if (tile_ack) begin
        if (ack_head_id != ack_count[1:0])
          $fatal(1, "ack tag order failed: got %0d expected %0d",
                 ack_head_id, ack_count);
        if (sequence_done || state_sum_out != 16'h4c00 ||
            normalizer_recip != 16'h2c00)
          $fatal(1, "head %0d initial state failed: sum=%h recip=%h",
                 ack_count, state_sum_out, normalizer_recip);
        ack_count = ack_count + 1;
      end
    end
    if (weight_count != 4)
      $fatal(1, "expected four pipelined weight responses, got %0d", weight_count);

    send_uniform_zero_tile(2'd0, 1'b0, 1'b0);
    wait (tile_ack && ack_head_id == 2'd0);
    #0.1;
    if (state_sum_out != 16'h5000 || normalizer_recip != 16'h2800)
      $fatal(1, "head0 state was not retained independently: sum=%h recip=%h", state_sum_out, normalizer_recip);

    send_uniform_zero_tile(2'd1, 1'b0, 1'b1);
    wait (tile_ack && ack_head_id == 2'd1);
    #0.1;
    if (!sequence_done || state_sum_out != 16'h5000 || normalizer_recip != 16'h2800)
      $fatal(1, "head1 state was not retained independently: sum=%h recip=%h", state_sum_out, normalizer_recip);

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
