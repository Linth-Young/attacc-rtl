`timescale 1ns/1ps

// Gate-level activity workload for the bank-level GEMV unit.
//
// The VCD deliberately contains a long score-only epoch after vector setup:
// 1024 independent score commands are accepted at II=1 and rotate across the
// four accumulation slots.  This avoids quoting the vectorless OpenROAD
// default activity as if it represented a real GEMV workload.
module attacc_gemv_gate_power_tb;
  localparam logic [15:0] FP16_ONE = 16'h3c00;
  localparam int STREAM_COMMANDS = 1024;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic vector_wr_en, vector_wr_buffer, swap_vector_buffers;
  logic [3:0] vector_wr_index, op_vector_word, op_broadcast_lane;
  logic [1:0] op_acc_slot, result_acc_slot;
  logic [255:0] vector_wr_data, matrix_data, lane_results;
  logic op_valid, op_ready, mode_tree, op_clear_acc;
  logic tree_result_valid, lane_result_valid;
  logic [15:0] tree_result;
  integer score_results;

  // 666.7 MHz: use the target period in the VCD so switching power is not
  // accidentally normalized to the old 100 MHz unit-test clock.
  always #0.75 clk = ~clk;

  attacc_gemv_unit dut (.*);

  task automatic drive_idle;
    begin
      vector_wr_en = 1'b0;
      vector_wr_buffer = 1'b0;
      vector_wr_index = '0;
      vector_wr_data = '0;
      swap_vector_buffers = 1'b0;
      op_valid = 1'b0;
      mode_tree = 1'b0;
      op_clear_acc = 1'b0;
      op_vector_word = '0;
      op_broadcast_lane = '0;
      op_acc_slot = '0;
      matrix_data = '0;
    end
  endtask

  initial begin
    $dumpfile("artifacts/attacc_gemv_gate_steady.vcd");
    $dumpvars(0, attacc_gemv_gate_power_tb);
    drive_idle();

    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    // Fill both selected-vector lanes and the 16 vector words.  Each word is
    // an all-ones FP16 vector, so every steady-state command is a 16-element
    // score GEMV dot product.
    for (int word = 0; word < 16; word++) begin
      @(negedge clk);
      vector_wr_en = 1'b1;
      vector_wr_buffer = 1'b0;
      vector_wr_index = word[3:0];
      for (int lane = 0; lane < 16; lane++)
        vector_wr_data[lane*16 +: 16] = FP16_ONE;
    end
    @(negedge clk);
    vector_wr_en = 1'b0;

    // Continuous score phase: clear per command so all four partial-sum
    // contexts are recurrence-safe while preserving the paper's II=1 issue.
    for (int cmd = 0; cmd < STREAM_COMMANDS; cmd++) begin
      @(negedge clk);
      if (!op_ready)
        $fatal(1, "score stream stalled at command %0d", cmd);
      op_valid = 1'b1;
      mode_tree = 1'b1;
      op_clear_acc = 1'b1;
      op_vector_word = cmd[3:0];
      op_acc_slot = cmd[1:0];
      for (int lane = 0; lane < 16; lane++)
        matrix_data[lane*16 +: 16] = FP16_ONE;
    end

    @(negedge clk);
    drive_idle();
    score_results = 0;
    repeat (96) begin
      @(posedge clk);
      if (tree_result_valid) begin
        if (tree_result !== 16'h4c00)
          $fatal(1, "score result mismatch: %h", tree_result);
        score_results++;
      end
    end
    if (score_results == 0)
      $fatal(1, "score pipeline did not drain");

    $display("PASS: %0d steady-state score GEMV commands, %0d tail results", STREAM_COMMANDS, score_results);
    $finish;
  end
endmodule
