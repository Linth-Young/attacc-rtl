`timescale 1ns/1ps

module attacc_gemv_unit_tb;
  localparam logic [15:0] FP16_ONE = 16'h3c00;
  localparam logic [15:0] FP16_TWO = 16'h4000;
  logic clk = 0, rst_n = 0;
  logic vector_wr_en, vector_wr_buffer, swap_vector_buffers;
  logic [3:0] vector_wr_index, op_vector_word, op_broadcast_lane;
  logic [1:0] op_acc_slot, result_acc_slot;
  logic [255:0] vector_wr_data, matrix_data, lane_results;
  logic op_valid, op_ready, mode_tree, op_clear_acc, tree_result_valid, lane_result_valid;
  logic [15:0] tree_result;
  integer score_results;

  always #5 clk = ~clk;

  attacc_gemv_unit dut (.*);

  task automatic drive_idle;
    begin
      vector_wr_en = 0; swap_vector_buffers = 0; op_valid = 0;
      op_clear_acc = 0; mode_tree = 0; vector_wr_buffer = 0;
      vector_wr_index = 0; op_vector_word = 0; op_broadcast_lane = 0; op_acc_slot = 0;
      vector_wr_data = 0; matrix_data = 0;
    end
  endtask

  initial begin
    $dumpfile("artifacts/attacc_gemv_activity.vcd");
    $dumpvars(0, attacc_gemv_unit_tb);
    drive_idle();
    repeat (2) @(posedge clk);
    rst_n = 1;

    // Load active buffer word 0 with sixteen 1.0 values.
    vector_wr_en = 1; vector_wr_buffer = 0; vector_wr_index = 0;
    for (int i = 0; i < 16; i++) vector_wr_data[i*16 +: 16] = FP16_ONE;
    @(posedge clk); #1; drive_idle();

    // Score mode: dot([1]*16, [1]*16) = 16.0 (0x4c00).
    mode_tree = 1; op_valid = 1; op_clear_acc = 1; op_vector_word = 0;
    for (int i = 0; i < 16; i++) matrix_data[i*16 +: 16] = FP16_ONE;
    @(posedge clk); #1; drive_idle();
    for (int cycle = 0; cycle < 80 && !tree_result_valid; cycle++) begin
      @(posedge clk); #1;
    end
    if (!tree_result_valid || tree_result !== 16'h4c00)
      $fatal(1, "tree reduction failed: got %h", tree_result);
    // Context mode: broadcast 1.0 and multiply sixteen 2.0 values.
    mode_tree = 0; op_valid = 1; op_clear_acc = 1; op_vector_word = 0;
    op_broadcast_lane = 0;
    for (int i = 0; i < 16; i++) matrix_data[i*16 +: 16] = FP16_TWO;
    @(posedge clk); #1; drive_idle();
    for (int cycle = 0; cycle < 40 && !lane_result_valid; cycle++) begin
      @(posedge clk); #1;
    end
    if (!lane_result_valid)
      $fatal(1, "context result did not complete");
    for (int i = 0; i < 16; i++)
      if (lane_results[i*16 +: 16] !== FP16_TWO)
        $fatal(1, "context lane %0d failed: got %h", i, lane_results[i*16 +: 16]);

    // Streaming score: four slots rotate every four clocks. Same-cycle result
    // forwarding allows this recurrence-safe schedule to sustain II=1.
    for (int cmd = 0; cmd < 24; cmd++) begin
      if (!op_ready) $fatal(1, "score stream stalled at command %0d", cmd);
      mode_tree = 1; op_valid = 1; op_clear_acc = 1; op_vector_word = 0;
      op_acc_slot = cmd % 4;
      for (int i = 0; i < 16; i++) matrix_data[i*16 +: 16] = FP16_ONE;
      @(posedge clk); #1;
    end
    drive_idle();
    score_results = 0;
    for (int cycle = 0; cycle < 100 && score_results < 24; cycle++) begin
      @(posedge clk); #1;
      if (tree_result_valid) begin
        if (tree_result !== 16'h4c00)
          $fatal(1, "stream score result failed: got %h", tree_result);
        score_results++;
      end
    end
    if (score_results != 24)
      $fatal(1, "stream score returned %0d results, expected 24", score_results);

    $display("PASS: AttAcc GEMV unit score/context modes and II=1 score stream");
    $finish;
  end
endmodule
