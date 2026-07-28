// Synthesizable long-running score-GEMV stimulus for Yosys gate simulation.
// Top-level clk/rst_n are driven by `yosys sim`; all DUT inputs are generated
// internally so the emitted VCD preserves the mapped DUT cell hierarchy.
module attacc_gemv_gate_activity_wrapper (
  input wire clk,
  input wire rst_n
);
  localparam integer STREAM_COMMANDS = 1024;
  reg [10:0] cycle_count;
  wire vector_wr_en = (cycle_count >= 11'd1) && (cycle_count <= 11'd16);
  wire [3:0] vector_wr_index = cycle_count - 11'd1;
  wire op_valid = (cycle_count >= 11'd17) &&
                  (cycle_count < (11'd17 + STREAM_COMMANDS));
  wire [255:0] vector_wr_data;
  wire [255:0] matrix_data;
  wire op_ready, tree_result_valid, lane_result_valid;
  wire [15:0] tree_result;
  wire [255:0] lane_results;
  wire [1:0] result_acc_slot;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_count <= '0;
    else cycle_count <= cycle_count + 1'b1;
  end

  // Finite normal FP16 values only: this drives a genuine arithmetic stream
  // without NaN/Inf corner cases.  The operand changes with both command and
  // lane, so measured activity is not the artificial all-ones lower bound.
  function [15:0] fp16_stream_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_stream_value = 16'h3c00; // 1.0
        4'h1: fp16_stream_value = 16'h3800; // 0.5
        4'h2: fp16_stream_value = 16'h4000; // 2.0
        4'h3: fp16_stream_value = 16'h3a00; // 0.75
        4'h4: fp16_stream_value = 16'h3e00; // 1.5
        4'h5: fp16_stream_value = 16'h4200; // 3.0
        4'h6: fp16_stream_value = 16'h3400; // 0.25
        4'h7: fp16_stream_value = 16'h4100; // 2.5
        4'h8: fp16_stream_value = 16'h3d00; // 1.25
        4'h9: fp16_stream_value = 16'h4400; // 4.0
        4'ha: fp16_stream_value = 16'h3900; // 0.625
        4'hb: fp16_stream_value = 16'h3f00; // 1.75
        4'hc: fp16_stream_value = 16'h4300; // 3.5
        4'hd: fp16_stream_value = 16'h3600; // 0.375
        4'he: fp16_stream_value = 16'h4080; // 2.25
        default: fp16_stream_value = 16'h3b00; // 0.875
      endcase
    end
  endfunction

  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1) begin : g_operand_lane
      // The vector word is captured during the initial sixteen write cycles;
      // matrix operands continue to vary throughout the II=1 score stream.
      assign vector_wr_data[lane*16 +: 16] =
        fp16_stream_value(cycle_count[3:0] + lane[3:0]);
      assign matrix_data[lane*16 +: 16] =
        fp16_stream_value(cycle_count[3:0] + lane[3:0] + 4'h5);
    end
  endgenerate

  attacc_gemv_unit dut (
    .clk(clk), .rst_n(rst_n),
    .vector_wr_en(vector_wr_en), .vector_wr_buffer(1'b0),
    .vector_wr_index(vector_wr_index), .vector_wr_data(vector_wr_data),
    .swap_vector_buffers(1'b0),
    .op_valid(op_valid), .op_ready(op_ready), .mode_tree(1'b1),
    .op_clear_acc(1'b1), .op_vector_word(cycle_count[3:0]),
    .op_broadcast_lane(4'b0), .op_acc_slot(cycle_count[1:0]),
    .matrix_data(matrix_data),
    .tree_result_valid(tree_result_valid), .tree_result(tree_result),
    .lane_result_valid(lane_result_valid), .lane_results(lane_results),
    .result_acc_slot(result_acc_slot)
  );
endmodule
