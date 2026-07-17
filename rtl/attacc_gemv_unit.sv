`timescale 1ns/1ps

// Streaming AttAcc bank-level GemV unit.  The physical budget is fixed at
// sixteen FP16 multiplier pipelines and sixteen FP16 adder pipelines.
//
// Score traffic maps its reduction stages onto disjoint adder subsets:
//   L1: adders 0..7, L2: 8..11, L3: 12..13, L4: 14, accumulator: 15.
// This permits one score command per clock after pipeline fill.  Context
// traffic uses all sixteen adders and is likewise one command per clock.
// Score and context phases are not mixed while either has in-flight work;
// AttAcc executes those phases separately in the intended dataflow.
module attacc_gemv_unit #(
  parameter int LANES = 16,
  parameter int VECTOR_WORDS = 16,
  // Four round-robin contexts match the FP16-adder latency.  A same-cycle
  // accumulator-result bypass closes the feedback loop when a slot repeats.
  parameter int ACC_SLOTS = 4
) (
  input logic clk, input logic rst_n,
  input logic vector_wr_en, input logic vector_wr_buffer,
  input logic [$clog2(VECTOR_WORDS)-1:0] vector_wr_index,
  input logic [LANES*16-1:0] vector_wr_data, input logic swap_vector_buffers,
  input logic op_valid, output logic op_ready, input logic mode_tree,
  input logic op_clear_acc, input logic [$clog2(VECTOR_WORDS)-1:0] op_vector_word,
  input logic [$clog2(LANES)-1:0] op_broadcast_lane,
  // Selects an independent partial-sum context.  Consecutive commands for
  // one slot must wait until its result returns; rotating slots sustains II=1.
  input logic [$clog2(ACC_SLOTS)-1:0] op_acc_slot,
  input logic [LANES*16-1:0] matrix_data,
  output logic tree_result_valid, output logic [15:0] tree_result,
  output logic lane_result_valid, output logic [LANES*16-1:0] lane_results,
  output logic [$clog2(ACC_SLOTS)-1:0] result_acc_slot
);
  localparam int SLOT_W = $clog2(ACC_SLOTS);
  // The mode-drain counter must cover the whole score pipeline, not only slots.
  localparam int COUNT_W = 6;

  logic active_buffer;
  // Packed dimensions force this standard-cell proxy to elaborate each entry
  // as a register vector rather than as an unsupported multi-clock memory.
  logic [1:0][VECTOR_WORDS-1:0][LANES*16-1:0] vector_buffer;
  // The vector buffer is a macro in a physical PIM implementation.  In the
  // standard-cell proxy flow it is necessarily FF based, so give each word a
  // write clock gate: only the addressed 256-bit word sees a clock edge.
  logic vector_write_enable [0:1][0:VECTOR_WORDS-1];
  logic vector_write_gclk [0:1][0:VECTOR_WORDS-1];
  logic [LANES*16-1:0] selected_vector;
  logic [15:0] broadcast_value;

  logic accept_command, accept_tree, accept_context;
  logic [COUNT_W-1:0] tree_pending, context_pending;
  logic [1:0] acc_slot_cooldown [0:ACC_SLOTS-1];

  logic mul_in_valid;
  logic [LANES-1:0] mul_valid_lane, add_valid_lane;
  logic [15:0] mul_y [0:LANES-1], add_y [0:LANES-1];
  logic add_in_valid [0:LANES-1];
  logic [15:0] add_a [0:LANES-1], add_b [0:LANES-1];

  // Command metadata follows the two-stage multiplier pipeline.
  logic mul_tree_pipe [0:1], mul_clear_pipe [0:1];
  logic [SLOT_W-1:0] mul_slot_pipe [0:1];

  // Metadata follows each four-stage reduction/accumulation add pipeline.
  logic l1_valid_pipe [0:3], l1_clear_pipe [0:3];
  logic l2_valid_pipe [0:3], l2_clear_pipe [0:3];
  logic l3_valid_pipe [0:3], l3_clear_pipe [0:3];
  logic l4_valid_pipe [0:3], l4_clear_pipe [0:3];
  logic tree_acc_valid_pipe [0:3];
  logic context_valid_pipe [0:3];
  logic [SLOT_W-1:0] l1_slot_pipe [0:3], l2_slot_pipe [0:3];
  logic [SLOT_W-1:0] l3_slot_pipe [0:3], l4_slot_pipe [0:3];
  logic [SLOT_W-1:0] tree_acc_slot_pipe [0:3], context_slot_pipe [0:3];

  logic score_l1_in_valid, score_l2_in_valid, score_l3_in_valid;
  logic score_l4_in_valid, score_acc_in_valid, context_in_valid;
  logic tree_commit, context_commit;
  logic [ACC_SLOTS-1:0][15:0] tree_accumulator;
  // One packed 16-lane register per slot avoids a two-dimensional variable
  // index in synthesis frontends while preserving 16 independent FP16 sums.
  logic [ACC_SLOTS-1:0][LANES*16-1:0] lane_accumulator;
  logic tree_acc_write_enable [0:ACC_SLOTS-1];
  logic lane_acc_write_enable [0:ACC_SLOTS-1];
  logic tree_acc_gclk [0:ACC_SLOTS-1];
  logic lane_acc_gclk [0:ACC_SLOTS-1];
  integer i, j;
  genvar g, vb, vw, as;

  assign selected_vector = vector_buffer[active_buffer][op_vector_word];
  assign broadcast_value = selected_vector[op_broadcast_lane*16 +: 16];

  // Same-mode requests can be accepted while older requests are in flight.
  // A mode transition waits for the currently active datapath to drain.
  always_comb begin
    op_ready = 1'b1;
    if (op_valid) begin
      if (op_acc_slot >= ACC_SLOTS) begin
        op_ready = 1'b0;
      end else begin
        if (mode_tree) begin
          if (context_pending != '0) op_ready = 1'b0;
        end else begin
          if (tree_pending != '0) op_ready = 1'b0;
        end
        if (acc_slot_cooldown[op_acc_slot] != '0) op_ready = 1'b0;
      end
    end
  end
  assign accept_command = op_valid && op_ready;
  assign accept_tree = accept_command && mode_tree;
  assign accept_context = accept_command && !mode_tree;
  assign mul_in_valid = accept_command;

  assign score_l1_in_valid = mul_valid_lane[0] && mul_tree_pipe[1];
  assign context_in_valid = mul_valid_lane[0] && !mul_tree_pipe[1];
  assign score_l2_in_valid = l1_valid_pipe[3];
  assign score_l3_in_valid = l2_valid_pipe[3];
  assign score_l4_in_valid = l3_valid_pipe[3];
  assign score_acc_in_valid = l4_valid_pipe[3];
  assign tree_commit = tree_acc_valid_pipe[3];
  assign context_commit = context_valid_pipe[3];
  // Result outputs are a streaming view of the final adder stage.  They are
  // meaningful only while the corresponding valid signal is asserted.
  assign tree_result_valid = tree_acc_valid_pipe[3];
  assign lane_result_valid = context_valid_pipe[3];
  assign tree_result = add_y[15];
  always_comb begin
    for (int lane=0; lane<LANES; lane=lane+1) lane_results[lane*16 +: 16] = add_y[lane];
    if (tree_acc_valid_pipe[3]) result_acc_slot = tree_acc_slot_pipe[3];
    else if (context_valid_pipe[3]) result_acc_slot = context_slot_pipe[3];
    else result_acc_slot = '0;
  end

  generate
    // Keep the FF-based proxy from clocking all 8,192 vector-buffer bits on
    // every 666 MHz edge.  The conditional assignment retains correct XSim
    // behavior because its functional ICG model deliberately passes CK.
    for (vb=0; vb<2; vb=vb+1) begin : g_vector_buffer
      for (vw=0; vw<VECTOR_WORDS; vw=vw+1) begin : g_vector_word
        localparam logic [$clog2(VECTOR_WORDS)-1:0] WORD_ID = vw;
        assign vector_write_enable[vb][vw] = vector_wr_en &&
                                              (vector_wr_buffer == vb[0]) &&
                                              (vector_wr_index == WORD_ID);
        OPENROAD_CLKGATE u_vector_write_icg (
          .CK(clk), .E(vector_write_enable[vb][vw]), .GCK(vector_write_gclk[vb][vw]));
        always_ff @(posedge vector_write_gclk[vb][vw]) begin
          if (vector_write_enable[vb][vw])
            vector_buffer[vb][vw] <= vector_wr_data;
        end
      end
    end

    // Accumulator arrays are also write-clocked.  This is functionally
    // identical to a conventional clock-enable, but gives the standard-cell
    // proxy a realistic inactive-cycle clock power instead of a global clock.
    for (as=0; as<ACC_SLOTS; as=as+1) begin : g_accumulator_write
      localparam logic [SLOT_W-1:0] SLOT_ID = as;
      assign tree_acc_write_enable[as] = tree_commit && (tree_acc_slot_pipe[3] == SLOT_ID);
      assign lane_acc_write_enable[as] = context_commit && (context_slot_pipe[3] == SLOT_ID);
      OPENROAD_CLKGATE u_tree_acc_icg (
        .CK(clk), .E(tree_acc_write_enable[as]), .GCK(tree_acc_gclk[as]));
      OPENROAD_CLKGATE u_lane_acc_icg (
        .CK(clk), .E(lane_acc_write_enable[as]), .GCK(lane_acc_gclk[as]));
      always_ff @(posedge tree_acc_gclk[as]) begin
        if (tree_acc_write_enable[as]) tree_accumulator[as] <= add_y[15];
      end
      always_ff @(posedge lane_acc_gclk[as]) begin
        if (lane_acc_write_enable[as]) lane_accumulator[as] <= lane_results;
      end
    end

    for (g=0; g<LANES; g=g+1) begin : g_mul
      attacc_fp16_mul_pipe u_mul (
        .clk(clk), .rst_n(rst_n), .in_valid(mul_in_valid),
        .a(mode_tree ? selected_vector[g*16 +: 16] : broadcast_value),
        .b(matrix_data[g*16 +: 16]), .out_valid(mul_valid_lane[g]), .y(mul_y[g]));
      attacc_fp16_add_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(add_in_valid[g]),
        .a(add_a[g]), .b(add_b[g]), .out_valid(add_valid_lane[g]), .y(add_y[g]));
    end
  endgenerate

  // A score command occupies a disjoint subset at every reduction level.
  // A context phase can use all adders only after score traffic has drained.
  always_comb begin
    for (j=0; j<LANES; j=j+1) begin
      add_in_valid[j] = 1'b0;
      add_a[j] = 16'h0000;
      add_b[j] = 16'h0000;
    end

    if (score_l1_in_valid) begin
      for (j=0; j<8; j=j+1) begin
        add_in_valid[j] = 1'b1;
        add_a[j] = mul_y[j*2];
        add_b[j] = mul_y[j*2+1];
      end
    end else if (context_in_valid) begin
      for (j=0; j<LANES; j=j+1) begin
        add_in_valid[j] = 1'b1;
        add_a[j] = mul_clear_pipe[1] ? 16'h0000 :
                   ((context_commit && (context_slot_pipe[3] == mul_slot_pipe[1])) ?
                    add_y[j] : lane_accumulator[mul_slot_pipe[1]][j*16 +: 16]);
        add_b[j] = mul_y[j];
      end
    end

    if (score_l2_in_valid) begin
      for (j=0; j<4; j=j+1) begin
        add_in_valid[8+j] = 1'b1;
        add_a[8+j] = add_y[j*2];
        add_b[8+j] = add_y[j*2+1];
      end
    end else if (context_in_valid) begin
      for (j=8; j<12; j=j+1) begin
        add_in_valid[j] = 1'b1;
        add_a[j] = mul_clear_pipe[1] ? 16'h0000 :
                   ((context_commit && (context_slot_pipe[3] == mul_slot_pipe[1])) ?
                    add_y[j] : lane_accumulator[mul_slot_pipe[1]][j*16 +: 16]);
        add_b[j] = mul_y[j];
      end
    end

    if (score_l3_in_valid) begin
      for (j=0; j<2; j=j+1) begin
        add_in_valid[12+j] = 1'b1;
        add_a[12+j] = add_y[8+j*2];
        add_b[12+j] = add_y[8+j*2+1];
      end
    end else if (context_in_valid) begin
      for (j=12; j<14; j=j+1) begin
        add_in_valid[j] = 1'b1;
        add_a[j] = mul_clear_pipe[1] ? 16'h0000 :
                   ((context_commit && (context_slot_pipe[3] == mul_slot_pipe[1])) ?
                    add_y[j] : lane_accumulator[mul_slot_pipe[1]][j*16 +: 16]);
        add_b[j] = mul_y[j];
      end
    end

    if (score_l4_in_valid) begin
      add_in_valid[14] = 1'b1;
      add_a[14] = add_y[12];
      add_b[14] = add_y[13];
    end else if (context_in_valid) begin
      add_in_valid[14] = 1'b1;
      add_a[14] = mul_clear_pipe[1] ? 16'h0000 :
                  ((context_commit && (context_slot_pipe[3] == mul_slot_pipe[1])) ?
                   add_y[14] : lane_accumulator[mul_slot_pipe[1]][14*16 +: 16]);
      add_b[14] = mul_y[14];
    end

    if (score_acc_in_valid) begin
      add_in_valid[15] = 1'b1;
      add_a[15] = l4_clear_pipe[3] ? 16'h0000 :
                  ((tree_commit && (tree_acc_slot_pipe[3] == l4_slot_pipe[3])) ?
                   add_y[15] : tree_accumulator[l4_slot_pipe[3]]);
      add_b[15] = add_y[14];
    end else if (context_in_valid) begin
      add_in_valid[15] = 1'b1;
      add_a[15] = mul_clear_pipe[1] ? 16'h0000 :
                  ((context_commit && (context_slot_pipe[3] == mul_slot_pipe[1])) ?
                   add_y[15] : lane_accumulator[mul_slot_pipe[1]][15*16 +: 16]);
      add_b[15] = mul_y[15];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_buffer <= 1'b0;
      tree_pending <= '0;
      context_pending <= '0;
      for (i=0; i<ACC_SLOTS; i=i+1) begin
        acc_slot_cooldown[i] <= '0;
      end
      for (i=0; i<2; i=i+1) begin
        mul_tree_pipe[i] <= 1'b0;
        mul_clear_pipe[i] <= 1'b0;
        mul_slot_pipe[i] <= '0;
      end
      for (i=0; i<4; i=i+1) begin
        l1_valid_pipe[i] <= 1'b0; l1_clear_pipe[i] <= 1'b0; l1_slot_pipe[i] <= '0;
        l2_valid_pipe[i] <= 1'b0; l2_clear_pipe[i] <= 1'b0; l2_slot_pipe[i] <= '0;
        l3_valid_pipe[i] <= 1'b0; l3_clear_pipe[i] <= 1'b0; l3_slot_pipe[i] <= '0;
        l4_valid_pipe[i] <= 1'b0; l4_clear_pipe[i] <= 1'b0; l4_slot_pipe[i] <= '0;
        tree_acc_valid_pipe[i] <= 1'b0; tree_acc_slot_pipe[i] <= '0;
        context_valid_pipe[i] <= 1'b0; context_slot_pipe[i] <= '0;
      end
    end else begin
      if (swap_vector_buffers) active_buffer <= ~active_buffer;

      mul_tree_pipe[0] <= accept_command ? mode_tree : 1'b0;
      mul_clear_pipe[0] <= accept_command ? op_clear_acc : 1'b0;
      mul_slot_pipe[0] <= op_acc_slot;
      mul_tree_pipe[1] <= mul_tree_pipe[0];
      mul_clear_pipe[1] <= mul_clear_pipe[0];
      mul_slot_pipe[1] <= mul_slot_pipe[0];

      l1_valid_pipe[0] <= score_l1_in_valid;
      l1_clear_pipe[0] <= mul_clear_pipe[1];
      l1_slot_pipe[0] <= mul_slot_pipe[1];
      l2_valid_pipe[0] <= score_l2_in_valid;
      l2_clear_pipe[0] <= l1_clear_pipe[3];
      l2_slot_pipe[0] <= l1_slot_pipe[3];
      l3_valid_pipe[0] <= score_l3_in_valid;
      l3_clear_pipe[0] <= l2_clear_pipe[3];
      l3_slot_pipe[0] <= l2_slot_pipe[3];
      l4_valid_pipe[0] <= score_l4_in_valid;
      l4_clear_pipe[0] <= l3_clear_pipe[3];
      l4_slot_pipe[0] <= l3_slot_pipe[3];
      tree_acc_valid_pipe[0] <= score_acc_in_valid;
      tree_acc_slot_pipe[0] <= l4_slot_pipe[3];
      context_valid_pipe[0] <= context_in_valid;
      context_slot_pipe[0] <= mul_slot_pipe[1];
      for (i=1; i<4; i=i+1) begin
        l1_valid_pipe[i] <= l1_valid_pipe[i-1]; l1_clear_pipe[i] <= l1_clear_pipe[i-1]; l1_slot_pipe[i] <= l1_slot_pipe[i-1];
        l2_valid_pipe[i] <= l2_valid_pipe[i-1]; l2_clear_pipe[i] <= l2_clear_pipe[i-1]; l2_slot_pipe[i] <= l2_slot_pipe[i-1];
        l3_valid_pipe[i] <= l3_valid_pipe[i-1]; l3_clear_pipe[i] <= l3_clear_pipe[i-1]; l3_slot_pipe[i] <= l3_slot_pipe[i-1];
        l4_valid_pipe[i] <= l4_valid_pipe[i-1]; l4_clear_pipe[i] <= l4_clear_pipe[i-1]; l4_slot_pipe[i] <= l4_slot_pipe[i-1];
        tree_acc_valid_pipe[i] <= tree_acc_valid_pipe[i-1]; tree_acc_slot_pipe[i] <= tree_acc_slot_pipe[i-1];
        context_valid_pipe[i] <= context_valid_pipe[i-1]; context_slot_pipe[i] <= context_slot_pipe[i-1];
      end

      case ({accept_tree, tree_commit})
        2'b10: tree_pending <= tree_pending + 1'b1;
        2'b01: tree_pending <= tree_pending - 1'b1;
        default: tree_pending <= tree_pending;
      endcase
      case ({accept_context, context_commit})
        2'b10: context_pending <= context_pending + 1'b1;
        2'b01: context_pending <= context_pending - 1'b1;
        default: context_pending <= context_pending;
      endcase

      for (i=0; i<ACC_SLOTS; i=i+1) begin
        if (accept_command && (op_acc_slot == i[SLOT_W-1:0]))
          acc_slot_cooldown[i] <= 2'd3;
        else if (acc_slot_cooldown[i] != '0)
          acc_slot_cooldown[i] <= acc_slot_cooldown[i] - 1'b1;
      end
    end
  end

  // The accumulator state is intentionally not reset.  A slot must receive
  // op_clear_acc=1 before its first read; omitting an asynchronous reset here
  // removes thousands of resettable flops from the area-critical datapath.
endmodule
