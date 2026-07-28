`timescale 1ns/1ps

// MELON base-die Vector Unit.
//
// The softmax datapath is a tagged, feed-forward pipeline.  One tile from a
// different attention head can be accepted every cycle; head_id is also the
// transaction slot/tag, so the arithmetic array is shared rather than copied
// per head.  A head remains busy until its online-softmax recurrence commits,
// which preserves the true dependency between consecutive tiles of that head.
// A tile for the committing head may be accepted in the same cycle through
// commit-to-issue state forwarding.
//
// Arithmetic is 16-lane binary16: parallel delta/exp, a pipelined 8/4/2/1
// reduction tree, online max/sum rescaling, tile-width reciprocal lanes, and
// parallel sigmoid/multiply for SiLU.  The paper does not disclose the exact
// exp/div circuits; attacc_fp16_operators.sv therefore supplies replaceable,
// synthesizable monotonic FP16 approximation pipelines.
module melon_vector_unit #(
  parameter int LANES = 16,
  parameter int HEADS = 32,
  parameter int HEAD_ID_W = (HEADS <= 1) ? 1 : $clog2(HEADS)
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  state_reset,
  input  logic                  tile_valid,
  input  logic                  tile_last,
  input  logic [HEAD_ID_W-1:0]  tile_head_id,
  input  logic                  tile_state_reset,
  input  logic [LANES*16-1:0]   score_data,
  output logic                  tile_ready,
  output logic                  tile_ack,
  output logic [HEAD_ID_W-1:0]  ack_head_id,
  output logic [15:0]           bank_rescale,
  output logic [15:0]           normalizer_recip,
  output logic [LANES*16-1:0]   weight_data,
  output logic                  weight_valid,
  output logic [HEAD_ID_W-1:0]  weight_head_id,
  output logic                  sequence_done,
  output logic [15:0]           state_max_out,
  output logic [15:0]           state_sum_out,

  input  logic                  activation_valid,
  output logic                  activation_ready,
  input  logic                  activation_silu,
  input  logic [LANES*16-1:0]   activation_data,
  output logic                  activation_ack,
  output logic                  activation_out_valid,
  output logic [LANES*16-1:0]   activation_result
);
  localparam int MAX_L1 = LANES / 2;
  localparam int MAX_L2 = LANES / 4;
  localparam int MAX_L3 = LANES / 8;
  localparam int RECIP_LANES = 4;

  localparam logic [3:0] ACT_IDLE        = 4'd0;
  localparam logic [3:0] ACT_EXP_WAIT    = 4'd1;
  localparam logic [3:0] ACT_DENOM_WAIT  = 4'd2;
  localparam logic [3:0] ACT_RECIP_ISSUE = 4'd3;
  localparam logic [3:0] ACT_RECIP_DRAIN = 4'd4;
  localparam logic [3:0] ACT_MUL1_ISSUE  = 4'd5;
  localparam logic [3:0] ACT_MUL1_WAIT   = 4'd6;
  localparam logic [3:0] ACT_MUL2_ISSUE  = 4'd7;
  localparam logic [3:0] ACT_MUL2_WAIT   = 4'd8;

  logic [HEADS-1:0] head_busy;
  logic [HEADS-1:0] state_valid;
  logic [HEADS-1:0] state_gclk;
  logic [15:0] state_max [0:HEADS-1];
  logic [15:0] state_sum [0:HEADS-1];

  // Per-head transaction metadata.  At most one recurrence is in flight for
  // a head, hence head_id itself is a lossless slot identifier.
  logic        slot_last       [0:HEADS-1];
  logic        slot_base_valid [0:HEADS-1];
  logic [15:0] slot_base_sum   [0:HEADS-1];
  logic [15:0] slot_next_max   [0:HEADS-1];
  logic [15:0] slot_old_scaled [0:HEADS-1];
  logic [15:0] slot_final_sum  [0:HEADS-1];

  logic any_inflight, head_id_valid, selected_head_busy, soft_accept;
  logic global_state_clear, commit_valid, state_update_valid;
  logic state_update_same_head, soft_tail_busy;
  logic pipe_gclk, io_gclk, pipe_clock_enable, io_clock_enable;
  logic [HEAD_ID_W-1:0] commit_head;
  logic [HEAD_ID_W-1:0] state_update_head;
  logic [15:0] accept_base_max, accept_base_sum;
  logic accept_base_valid;
  logic [15:0] state_max_out_reg, state_sum_out_reg;

  // Four-stage compare tree (the fourth stage compares the tile maximum with
  // the previously committed maximum).
  logic [15:0] max_l1 [0:MAX_L1-1];
  logic [15:0] max_l2 [0:MAX_L2-1];
  logic [15:0] max_l3 [0:MAX_L3-1];
  logic [15:0] score_pipe [0:3][0:LANES-1];
  logic [15:0] base_max_pipe [0:3];
  logic [15:0] base_sum_pipe [0:3];
  logic        base_valid_pipe [0:3];
  logic [HEAD_ID_W-1:0] max_head_pipe [0:3];
  logic [3:0] max_valid_pipe;
  logic [15:0] next_max_pipe;

  logic [15:0] delta_y [0:LANES-1];
  logic [15:0] exp_y [0:LANES-1];
  logic [15:0] recip_y [0:RECIP_LANES-1];
  logic [15:0] elem_y [0:LANES-1];
  logic [15:0] sum1_y [0:MAX_L1-1];
  logic [15:0] sum2_y [0:MAX_L2-1];
  logic [15:0] sum3_y [0:MAX_L3-1];
  logic [15:0] sum4_y;
  logic [15:0] old_delta_y, old_exp_y, old_mul_y, final_y;
  logic [LANES-1:0] delta_valid, exp_valid, elem_valid;
  logic [RECIP_LANES-1:0] recip_valid;
  logic [MAX_L1-1:0] sum1_valid;
  logic [MAX_L2-1:0] sum2_valid;
  logic [MAX_L3-1:0] sum3_valid;
  logic sum4_valid, old_delta_valid, old_exp_valid, old_mul_valid, final_valid;

  // Tags mirror the registered latency of the arithmetic primitives.
  logic [3:0] delta_tag_valid, sum1_tag_valid, sum2_tag_valid;
  logic [3:0] sum3_tag_valid, sum4_tag_valid, old_delta_tag_valid;
  logic [3:0] final_tag_valid;
  logic [3:0] exp_tag_valid, old_exp_tag_valid;
  logic [1:0] old_mul_tag_valid;
  logic [3:0] recip_tag_valid;
  logic [HEAD_ID_W-1:0] delta_tag [0:3];
  logic [HEAD_ID_W-1:0] exp_tag [0:3];
  logic [HEAD_ID_W-1:0] sum1_tag [0:3];
  logic [HEAD_ID_W-1:0] sum2_tag [0:3];
  logic [HEAD_ID_W-1:0] sum3_tag [0:3];
  logic [HEAD_ID_W-1:0] sum4_tag [0:3];
  logic [HEAD_ID_W-1:0] old_delta_tag [0:3];
  logic [HEAD_ID_W-1:0] old_exp_tag [0:3];
  logic [HEAD_ID_W-1:0] old_mul_tag [0:1];
  logic [HEAD_ID_W-1:0] final_tag [0:3];
  logic [HEAD_ID_W-1:0] recip_tag [0:3];
  logic [3:0] recip_last;

  // Activations share the same arithmetic lane count and run only when the
  // stateful softmax pipe is empty.
  logic act_busy;
  logic [LANES*16-1:0] activation_hold;
  logic act_sig_issue;
  logic act_accept;
  logic [3:0] act_phase;
  logic [2:0] act_recip_issue_group;
  logic [3:0] act_recip_tag_valid;
  logic [1:0] act_recip_tag [0:3];
  logic [LANES*16-1:0] act_exp_hold;
  logic [LANES*16-1:0] act_denom_hold;
  logic [LANES*16-1:0] act_recip_hold;
  logic [LANES*16-1:0] act_mul_hold;
  logic [15:0] recip_x [0:RECIP_LANES-1];
  logic soft_delta_valid, soft_exp_valid;
  logic act_exp_done, act_denom_done, act_recip_issue;
  logic elem_issue;

  function automatic logic fp16_ge(input logic [15:0] a, input logic [15:0] b);
    begin
      if (a[15] != b[15]) fp16_ge = !a[15];
      else if (!a[15]) fp16_ge = (a[14:0] >= b[14:0]);
      else fp16_ge = (a[14:0] <= b[14:0]);
    end
  endfunction

  function automatic logic [15:0] fp16_max(input logic [15:0] a, input logic [15:0] b);
    begin fp16_max = fp16_ge(a, b) ? a : b; end
  endfunction

  function automatic logic [15:0] fp16_neg(input logic [15:0] a);
    begin fp16_neg = {~a[15], a[14:0]}; end
  endfunction

  function automatic logic [15:0] fp16_relu(input logic [15:0] a);
    begin fp16_relu = a[15] ? 16'h0000 : a; end
  endfunction

  assign any_inflight = |head_busy;
  assign head_id_valid = (tile_head_id < HEADS);
  assign commit_valid = recip_valid[0] && recip_tag_valid[3];
  assign commit_head = recip_tag[3];
  assign state_update_valid = final_valid && final_tag_valid[3];
  assign state_update_head = final_tag[3];
  assign state_update_same_head =
    state_update_valid && (state_update_head == tile_head_id);
  assign soft_tail_busy = final_valid || (|recip_tag_valid);
  assign tile_ready = !act_busy && !state_reset && head_id_valid &&
                      (!selected_head_busy || state_update_same_head);
  assign soft_accept = tile_valid && tile_ready;
  assign activation_ready = !act_busy && !any_inflight && !soft_tail_busy &&
                            !tile_valid && !state_reset;
  assign act_accept = activation_valid && activation_ready;
  assign act_sig_issue = act_accept && activation_silu;
  assign soft_delta_valid = delta_valid[0] && delta_tag_valid[3];
  assign soft_exp_valid = exp_valid[0] && exp_tag_valid[3];
  assign act_exp_done = exp_valid[0] && (act_phase == ACT_EXP_WAIT);
  assign act_denom_done = delta_valid[0] && (act_phase == ACT_DENOM_WAIT);
  assign act_recip_issue = (act_phase == ACT_RECIP_ISSUE);
  assign elem_issue = (act_phase == ACT_MUL1_ISSUE) ||
                      (act_phase == ACT_MUL2_ISSUE);
  assign global_state_clear =
    state_reset && !any_inflight && !soft_tail_busy && !act_busy;
  assign pipe_clock_enable =
    any_inflight || soft_accept || soft_tail_busy || state_reset;
  assign io_clock_enable = any_inflight || soft_accept || act_busy || act_accept ||
                           tile_ack || weight_valid || activation_ack ||
                           activation_out_valid || soft_tail_busy || commit_valid ||
                           state_reset;

  // The tagged alignment/state machinery need not toggle when no softmax
  // transaction exists.  The output/activation bank gets a separate gate so
  // one cleanup edge can clear one-cycle valid/ack pulses after completion.
  OPENROAD_CLKGATE u_pipe_clkgate (
    .CK(clk), .E(pipe_clock_enable), .GCK(pipe_gclk)
  );
  OPENROAD_CLKGATE u_io_clkgate (
    .CK(clk), .E(io_clock_enable), .GCK(io_gclk)
  );

  // Commit-to-issue forwarding removes the otherwise mandatory bubble when a
  // head's next tile arrives on the same edge as its prior tile commits.
  always_comb begin
    selected_head_busy = 1'b1;
    accept_base_valid = 1'b0;
    accept_base_max = 16'h0000;
    accept_base_sum = 16'h0000;
    if (head_id_valid) begin
      selected_head_busy = head_busy[tile_head_id];
      accept_base_valid = state_valid[tile_head_id];
      accept_base_max = state_max[tile_head_id];
      accept_base_sum = state_sum[tile_head_id];
      if (state_update_same_head) begin
        accept_base_valid = 1'b1;
        accept_base_max = slot_next_max[state_update_head];
        accept_base_sum = final_y;
      end
    end
    if (tile_state_reset) begin
      accept_base_valid = 1'b0;
      accept_base_max = 16'h0000;
      accept_base_sum = 16'h0000;
    end
  end

  always_comb begin
    integer k;
    for (k = 0; k < RECIP_LANES; k = k + 1) begin
      if (final_valid)
        recip_x[k] = final_y;
      else
        recip_x[k] =
          act_denom_hold[((act_recip_issue_group * RECIP_LANES) + k)*16 +: 16];
    end
  end

  assign state_max_out = (commit_valid) ? slot_next_max[commit_head] : state_max_out_reg;
  assign state_sum_out = (commit_valid) ? slot_final_sum[commit_head] : state_sum_out_reg;

  genvar g;
  generate
    for (g = 0; g < HEADS; g = g + 1) begin : g_head_state
      wire state_update_select =
        state_update_valid && (state_update_head == g);
      OPENROAD_CLKGATE u_state_clkgate (
        .CK(clk), .E(global_state_clear || state_update_select),
        .GCK(state_gclk[g])
      );
      always_ff @(posedge state_gclk[g] or negedge rst_n) begin
        if (!rst_n) begin
          state_valid[g] <= 1'b0;
          state_max[g] <= 16'h0000;
          state_sum[g] <= 16'h0000;
        end else if (global_state_clear) begin
          state_valid[g] <= 1'b0;
          state_max[g] <= 16'h0000;
          state_sum[g] <= 16'h0000;
        end else begin
          state_valid[g] <= 1'b1;
          state_max[g] <= slot_next_max[g];
          state_sum[g] <= final_y;
        end
      end
    end

    for (g = 0; g < LANES; g = g + 1) begin : g_lane
      // The full RNE FP16 adder is shared by softmax delta subtraction and
      // the SiLU denominator 1+exp(-|x|).
      attacc_fp16_add_pipe u_delta (
        .clk(clk), .rst_n(rst_n),
        .in_valid(max_valid_pipe[3] | act_exp_done),
        .a(act_exp_done ? exp_y[g] : score_pipe[3][g]),
        .b(act_exp_done ? 16'h3c00 : fp16_neg(next_max_pipe)),
        .out_valid(delta_valid[g]), .y(delta_y[g])
      );
      // These 16 high-accuracy exp lanes are shared by online softmax and
      // SiLU.  Activation uses the stable exp(-abs(x)) formulation.
      attacc_fp16_exp_neg_hi_pipe u_exp (
        .clk(clk), .rst_n(rst_n),
        .in_valid(soft_delta_valid | act_sig_issue),
        .x(act_sig_issue ? {1'b1, activation_data[g*16 +: 15]} : delta_y[g]),
        .out_valid(exp_valid[g]), .y(exp_y[g])
      );
      attacc_fp16_mul_pipe u_elementwise_mul (
        .clk(clk), .rst_n(rst_n), .in_valid(elem_issue),
        .a((act_phase == ACT_MUL1_ISSUE) ?
           activation_hold[g*16 +: 16] : act_mul_hold[g*16 +: 16]),
        .b((act_phase == ACT_MUL1_ISSUE) ?
           act_recip_hold[g*16 +: 16] :
           (activation_hold[g*16+15] ? act_exp_hold[g*16 +: 16] : 16'h3c00)),
        .out_valid(elem_valid[g]), .y(elem_y[g])
      );
    end

    for (g = 0; g < MAX_L1; g = g + 1) begin : g_sum_l1
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(soft_exp_valid),
        .a(exp_y[2*g]), .b(exp_y[2*g+1]),
        .out_valid(sum1_valid[g]), .y(sum1_y[g])
      );
    end
    for (g = 0; g < MAX_L2; g = g + 1) begin : g_sum_l2
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(sum1_valid[0]),
        .a(sum1_y[2*g]), .b(sum1_y[2*g+1]),
        .out_valid(sum2_valid[g]), .y(sum2_y[g])
      );
    end
    for (g = 0; g < MAX_L3; g = g + 1) begin : g_sum_l3
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(sum2_valid[0]),
        .a(sum2_y[2*g]), .b(sum2_y[2*g+1]),
        .out_valid(sum3_valid[g]), .y(sum3_y[g])
      );
    end
  endgenerate

  generate
    for (g = 0; g < RECIP_LANES; g = g + 1) begin : g_shared_recip
      attacc_fp16_recip_hi_pipe u_recip (
        .clk(clk), .rst_n(rst_n),
        .in_valid(act_recip_issue | ((g == 0) && final_valid)),
        .x(recip_x[g]), .out_valid(recip_valid[g]), .y(recip_y[g])
      );
    end
  endgenerate

  attacc_fp16_add_fast_pipe u_sum_l4 (
    .clk(clk), .rst_n(rst_n), .in_valid(sum3_valid[0]),
    .a(sum3_y[0]), .b(sum3_y[1]), .out_valid(sum4_valid), .y(sum4_y)
  );
  attacc_fp16_add_fast_pipe u_old_delta (
    .clk(clk), .rst_n(rst_n), .in_valid(max_valid_pipe[3]),
    .a(base_valid_pipe[3] ? base_max_pipe[3] : next_max_pipe),
    .b(fp16_neg(next_max_pipe)), .out_valid(old_delta_valid), .y(old_delta_y)
  );
  attacc_fp16_exp_neg_hi_pipe u_old_exp (
    .clk(clk), .rst_n(rst_n), .in_valid(old_delta_valid), .x(old_delta_y),
    .out_valid(old_exp_valid), .y(old_exp_y)
  );
  attacc_fp16_mul_pipe u_old_rescale_mul (
    .clk(clk), .rst_n(rst_n), .in_valid(old_exp_valid),
    .a(slot_base_valid[old_exp_tag[3]] ? slot_base_sum[old_exp_tag[3]] : 16'h0000),
    .b(old_exp_y), .out_valid(old_mul_valid), .y(old_mul_y)
  );
  attacc_fp16_add_fast_pipe u_final_add (
    .clk(clk), .rst_n(rst_n), .in_valid(sum4_valid),
    .a(slot_old_scaled[sum4_tag[3]]), .b(sum4_y),
    .out_valid(final_valid), .y(final_y)
  );

  // Tag/compare pipeline and per-head transaction storage.
  always_ff @(posedge pipe_gclk or negedge rst_n) begin
    integer i, p;
    if (!rst_n) begin
      max_valid_pipe <= '0;
      delta_tag_valid <= '0; exp_tag_valid <= '0;
      sum1_tag_valid <= '0; sum2_tag_valid <= '0;
      sum3_tag_valid <= '0; sum4_tag_valid <= '0;
      old_delta_tag_valid <= '0; old_exp_tag_valid <= '0;
      old_mul_tag_valid <= '0; final_tag_valid <= '0; recip_tag_valid <= '0;
      recip_last <= '0;
      head_busy <= '0;
      state_max_out_reg <= 16'h0000;
      state_sum_out_reg <= 16'h0000;
      for (i = 0; i < HEADS; i = i + 1) begin
        slot_last[i] <= 1'b0;
        slot_base_valid[i] <= 1'b0;
        slot_base_sum[i] <= 16'h0000;
        slot_next_max[i] <= 16'h0000;
        slot_old_scaled[i] <= 16'h0000;
        slot_final_sum[i] <= 16'h0000;
      end
      for (p = 0; p < 4; p = p + 1) begin
        max_head_pipe[p] <= '0;
        base_max_pipe[p] <= 16'h0000;
        base_sum_pipe[p] <= 16'h0000;
        base_valid_pipe[p] <= 1'b0;
        delta_tag[p] <= '0; sum1_tag[p] <= '0; sum2_tag[p] <= '0;
        sum3_tag[p] <= '0; sum4_tag[p] <= '0;
        old_delta_tag[p] <= '0; final_tag[p] <= '0;
        for (i = 0; i < LANES; i = i + 1) score_pipe[p][i] <= 16'h0000;
      end
      for (p = 0; p < 4; p = p + 1) begin
        exp_tag[p] <= '0;
        old_exp_tag[p] <= '0;
      end
      for (p = 0; p < 2; p = p + 1) old_mul_tag[p] <= '0;
      for (p = 0; p < 4; p = p + 1) recip_tag[p] <= '0;
      for (i = 0; i < MAX_L1; i = i + 1) max_l1[i] <= 16'h0000;
      for (i = 0; i < MAX_L2; i = i + 1) max_l2[i] <= 16'h0000;
      for (i = 0; i < MAX_L3; i = i + 1) max_l3[i] <= 16'h0000;
      next_max_pipe <= 16'h0000;
    end else begin
      if (global_state_clear) begin
        head_busy <= '0;
        state_max_out_reg <= 16'h0000;
        state_sum_out_reg <= 16'h0000;
      end else begin
        if (state_update_valid) begin
          head_busy[state_update_head] <= 1'b0;
        end
        if (commit_valid) begin
          state_max_out_reg <= slot_next_max[commit_head];
          state_sum_out_reg <= slot_final_sum[commit_head];
        end
        if (soft_accept) head_busy[tile_head_id] <= 1'b1;
      end

      if (soft_accept) begin
        slot_last[tile_head_id] <= tile_last;
        slot_base_valid[tile_head_id] <= accept_base_valid;
        slot_base_sum[tile_head_id] <= accept_base_sum;
        for (i = 0; i < MAX_L1; i = i + 1)
          max_l1[i] <= fp16_max(score_data[(2*i)*16 +: 16],
                                score_data[(2*i+1)*16 +: 16]);
        for (i = 0; i < LANES; i = i + 1) score_pipe[0][i] <= score_data[i*16 +: 16];
        base_max_pipe[0] <= accept_base_max;
        base_sum_pipe[0] <= accept_base_sum;
        base_valid_pipe[0] <= accept_base_valid;
        max_head_pipe[0] <= tile_head_id;
      end
      max_valid_pipe[0] <= soft_accept;
      max_valid_pipe[1] <= max_valid_pipe[0];
      max_valid_pipe[2] <= max_valid_pipe[1];
      max_valid_pipe[3] <= max_valid_pipe[2];

      if (max_valid_pipe[0]) begin
        for (i = 0; i < MAX_L2; i = i + 1)
          max_l2[i] <= fp16_max(max_l1[2*i], max_l1[2*i+1]);
      end
      if (max_valid_pipe[1]) begin
        for (i = 0; i < MAX_L3; i = i + 1)
          max_l3[i] <= fp16_max(max_l2[2*i], max_l2[2*i+1]);
      end
      if (max_valid_pipe[2]) begin
        next_max_pipe <= base_valid_pipe[2] ?
                         fp16_max(base_max_pipe[2], fp16_max(max_l3[0], max_l3[1])) :
                         fp16_max(max_l3[0], max_l3[1]);
      end
      for (p = 1; p < 4; p = p + 1) begin
        if (max_valid_pipe[p-1]) begin
          max_head_pipe[p] <= max_head_pipe[p-1];
          base_max_pipe[p] <= base_max_pipe[p-1];
          base_sum_pipe[p] <= base_sum_pipe[p-1];
          base_valid_pipe[p] <= base_valid_pipe[p-1];
          for (i = 0; i < LANES; i = i + 1)
            score_pipe[p][i] <= score_pipe[p-1][i];
        end
      end
      if (max_valid_pipe[3])
        slot_next_max[max_head_pipe[3]] <= next_max_pipe;
      if (old_mul_valid)
        slot_old_scaled[old_mul_tag[1]] <= old_mul_y;
      if (final_valid)
        slot_final_sum[final_tag[3]] <= final_y;

      // Latency-4 tag paths.
      delta_tag_valid[0] <= max_valid_pipe[3];
      delta_tag[0] <= max_head_pipe[3];
      sum1_tag_valid[0] <= soft_exp_valid;
      sum1_tag[0] <= exp_tag[3];
      sum2_tag_valid[0] <= sum1_valid[0];
      sum2_tag[0] <= sum1_tag[3];
      sum3_tag_valid[0] <= sum2_valid[0];
      sum3_tag[0] <= sum2_tag[3];
      sum4_tag_valid[0] <= sum3_valid[0];
      sum4_tag[0] <= sum3_tag[3];
      old_delta_tag_valid[0] <= max_valid_pipe[3];
      old_delta_tag[0] <= max_head_pipe[3];
      final_tag_valid[0] <= sum4_valid;
      final_tag[0] <= sum4_tag[3];
      for (p = 1; p < 4; p = p + 1) begin
        delta_tag_valid[p] <= delta_tag_valid[p-1];
        delta_tag[p] <= delta_tag[p-1];
        sum1_tag_valid[p] <= sum1_tag_valid[p-1];
        sum1_tag[p] <= sum1_tag[p-1];
        sum2_tag_valid[p] <= sum2_tag_valid[p-1];
        sum2_tag[p] <= sum2_tag[p-1];
        sum3_tag_valid[p] <= sum3_tag_valid[p-1];
        sum3_tag[p] <= sum3_tag[p-1];
        sum4_tag_valid[p] <= sum4_tag_valid[p-1];
        sum4_tag[p] <= sum4_tag[p-1];
        old_delta_tag_valid[p] <= old_delta_tag_valid[p-1];
        old_delta_tag[p] <= old_delta_tag[p-1];
        final_tag_valid[p] <= final_tag_valid[p-1];
        final_tag[p] <= final_tag[p-1];
      end

      // Latency-4 high-accuracy exponential tag paths.
      exp_tag_valid[0] <= soft_delta_valid;
      exp_tag[0] <= delta_tag[3];
      for (p = 1; p < 4; p = p + 1) begin
        exp_tag_valid[p] <= exp_tag_valid[p-1];
        exp_tag[p] <= exp_tag[p-1];
      end
      old_exp_tag_valid[0] <= old_delta_valid;
      old_exp_tag[0] <= old_delta_tag[3];
      for (p = 1; p < 4; p = p + 1) begin
        old_exp_tag_valid[p] <= old_exp_tag_valid[p-1];
        old_exp_tag[p] <= old_exp_tag[p-1];
      end

      // Latency-2 multiplier and latency-4 reciprocal tag paths.
      old_mul_tag_valid[0] <= old_exp_valid;
      old_mul_tag[0] <= old_exp_tag[3];
      old_mul_tag_valid[1] <= old_mul_tag_valid[0];
      old_mul_tag[1] <= old_mul_tag[0];
      recip_tag_valid[0] <= final_valid;
      recip_tag[0] <= final_tag[3];
      recip_last[0] <= slot_last[final_tag[3]];
      for (p = 1; p < 4; p = p + 1) begin
        recip_tag_valid[p] <= recip_tag_valid[p-1];
        recip_tag[p] <= recip_tag[p-1];
        recip_last[p] <= recip_last[p-1];
      end
    end
  end

  // Protocol outputs and the mutually exclusive activation command path.
  always_ff @(posedge io_gclk or negedge rst_n) begin
    integer i;
    if (!rst_n) begin
      tile_ack <= 1'b0;
      ack_head_id <= '0;
      bank_rescale <= 16'h0000;
      normalizer_recip <= 16'h0000;
      weight_data <= '0;
      weight_valid <= 1'b0;
      weight_head_id <= '0;
      sequence_done <= 1'b0;
      act_busy <= 1'b0;
      act_phase <= ACT_IDLE;
      act_recip_issue_group <= 0;
      act_recip_tag_valid <= 0;
      for (i = 0; i < 4; i = i + 1) act_recip_tag[i] <= 0;
      activation_hold <= '0;
      act_exp_hold <= '0;
      act_denom_hold <= '0;
      act_recip_hold <= '0;
      act_mul_hold <= '0;
      activation_ack <= 1'b0;
      activation_out_valid <= 1'b0;
      activation_result <= '0;
    end else begin
      tile_ack <= 1'b0;
      weight_valid <= 1'b0;
      sequence_done <= 1'b0;
      activation_ack <= 1'b0;
      activation_out_valid <= 1'b0;

      if (soft_exp_valid) begin
        weight_valid <= 1'b1;
        weight_head_id <= exp_tag[3];
        bank_rescale <= slot_base_valid[exp_tag[3]] ?
                        old_exp_y : 16'h0000;
        for (i = 0; i < LANES; i = i + 1)
          weight_data[i*16 +: 16] <= exp_y[i];
      end
      if (commit_valid) begin
        tile_ack <= 1'b1;
        ack_head_id <= commit_head;
        normalizer_recip <= recip_y[0];
        sequence_done <= recip_last[3];
      end

      if (act_accept) begin
        activation_hold <= activation_data;
        if (activation_silu) begin
          act_busy <= 1'b1;
          act_phase <= ACT_EXP_WAIT;
        end else begin
          for (i = 0; i < LANES; i = i + 1)
            activation_result[i*16 +: 16] <=
              fp16_relu(activation_data[i*16 +: 16]);
          activation_ack <= 1'b1;
          activation_out_valid <= 1'b1;
          act_phase <= ACT_IDLE;
        end
      end

      if (act_exp_done) begin
        for (i = 0; i < LANES; i = i + 1)
          act_exp_hold[i*16 +: 16] <= exp_y[i];
        act_phase <= ACT_DENOM_WAIT;
      end

      if (act_denom_done) begin
        for (i = 0; i < LANES; i = i + 1)
          act_denom_hold[i*16 +: 16] <= delta_y[i];
        act_recip_issue_group <= 0;
        act_phase <= ACT_RECIP_ISSUE;
      end

      act_recip_tag_valid[0] <= act_recip_issue;
      act_recip_tag[0] <= act_recip_issue_group[1:0];
      for (i = 1; i < 4; i = i + 1) begin
        act_recip_tag_valid[i] <= act_recip_tag_valid[i-1];
        act_recip_tag[i] <= act_recip_tag[i-1];
      end
      if (act_recip_issue) begin
        if (act_recip_issue_group == 3) begin
          act_phase <= ACT_RECIP_DRAIN;
        end else begin
          act_recip_issue_group <= act_recip_issue_group + 1'b1;
        end
      end

      if (recip_valid[0] && act_recip_tag_valid[3]) begin
        for (i = 0; i < RECIP_LANES; i = i + 1)
          act_recip_hold[((act_recip_tag[3] * RECIP_LANES) + i)*16 +: 16]
            <= recip_y[i];
        if (act_recip_tag[3] == 3) act_phase <= ACT_MUL1_ISSUE;
      end

      if (act_phase == ACT_MUL1_ISSUE) act_phase <= ACT_MUL1_WAIT;
      if ((act_phase == ACT_MUL1_WAIT) && elem_valid[0]) begin
        for (i = 0; i < LANES; i = i + 1)
          act_mul_hold[i*16 +: 16] <= elem_y[i];
        act_phase <= ACT_MUL2_ISSUE;
      end
      if (act_phase == ACT_MUL2_ISSUE) act_phase <= ACT_MUL2_WAIT;
      if ((act_phase == ACT_MUL2_WAIT) && elem_valid[0]) begin
        for (i = 0; i < LANES; i = i + 1)
          activation_result[i*16 +: 16] <= elem_y[i];
        activation_ack <= 1'b1;
        activation_out_valid <= 1'b1;
        act_busy <= 1'b0;
        act_phase <= ACT_IDLE;
      end
    end
  end
endmodule
