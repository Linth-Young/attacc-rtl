`timescale 1ns/1ps

// MELON Base-Die Vector Unit, HPCA architecture-level reconstruction.
//
// A Vector tile is 16 binary16 values, matching the GemV tile width.  Unlike
// the former area-oriented prototype, this implementation has a lane-parallel
// FP16 datapath: 16 delta adders, 16 exponent units, a pipelined 8/4/2/1 FP16
// adder tree, 16 reciprocal/divider lanes, and 16 element-wise multipliers.
// The multiplier array executes SiLU; softmax weights remain in the online
// recurrence's unnormalised exp domain so Pseudo-channel Accumulation can
// rescale prior partial sums exactly as described by the paper.  ReLU is a
// per-lane compare/select.  All arithmetic blocks have registered
// boundaries.  The paper does not specify exp/div approximation circuitry, so
// the explicit FP16 pipelines in attacc_fp16_operators.sv use replaceable
// monotonic LUT implementations rather than claiming bit-exact libm results.
module melon_vector_unit #(
  parameter int LANES = 16
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                state_reset,
  input  logic                tile_valid,
  input  logic                tile_last,
  input  logic [LANES*16-1:0] score_data,
  output logic                tile_ready,
  output logic                tile_ack,
  output logic [15:0]         bank_rescale,
  output logic [15:0]         normalizer_recip,
  output logic [LANES*16-1:0] weight_data,
  output logic                weight_valid,
  output logic                sequence_done,
  output logic [15:0]         state_max_out,
  output logic [15:0]         state_sum_out,

  input  logic                activation_valid,
  output logic                activation_ready,
  input  logic                activation_silu,
  input  logic [LANES*16-1:0] activation_data,
  output logic                activation_ack,
  output logic                activation_out_valid,
  output logic [LANES*16-1:0] activation_result
);
  localparam int MAX_L1 = LANES / 2;
  localparam int MAX_L2 = LANES / 4;
  localparam int MAX_L3 = LANES / 8;

  localparam logic [5:0] IDLE             = 6'd0;
  localparam logic [5:0] MAX2             = 6'd1;
  localparam logic [5:0] MAX3             = 6'd2;
  localparam logic [5:0] MAX4             = 6'd3;
  localparam logic [5:0] DELTA_ISSUE      = 6'd4;
  localparam logic [5:0] DELTA_WAIT       = 6'd5;
  localparam logic [5:0] EXP_WAIT         = 6'd6;
  localparam logic [5:0] OLD_DELTA_ISSUE  = 6'd7;
  localparam logic [5:0] OLD_DELTA_WAIT   = 6'd8;
  localparam logic [5:0] OLD_EXP_WAIT     = 6'd9;
  localparam logic [5:0] OLD_MUL_ISSUE    = 6'd10;
  localparam logic [5:0] OLD_MUL_WAIT     = 6'd11;
  localparam logic [5:0] SUM1_ISSUE       = 6'd12;
  localparam logic [5:0] SUM1_WAIT        = 6'd13;
  localparam logic [5:0] SUM2_ISSUE       = 6'd14;
  localparam logic [5:0] SUM2_WAIT        = 6'd15;
  localparam logic [5:0] SUM3_ISSUE       = 6'd16;
  localparam logic [5:0] SUM3_WAIT        = 6'd17;
  localparam logic [5:0] SUM4_ISSUE       = 6'd18;
  localparam logic [5:0] SUM4_WAIT        = 6'd19;
  localparam logic [5:0] FINAL_ISSUE      = 6'd20;
  localparam logic [5:0] FINAL_WAIT       = 6'd21;
  localparam logic [5:0] RECIP_ISSUE      = 6'd22;
  localparam logic [5:0] RECIP_WAIT       = 6'd23;
  localparam logic [5:0] WEIGHT_ISSUE     = 6'd24;
  localparam logic [5:0] WEIGHT_WAIT      = 6'd25;
  localparam logic [5:0] ACT_SIG_ISSUE    = 6'd26;
  localparam logic [5:0] ACT_SIG_WAIT     = 6'd27;
  localparam logic [5:0] ACT_MUL_ISSUE    = 6'd28;
  localparam logic [5:0] ACT_MUL_WAIT     = 6'd29;
  localparam logic [5:0] ACT_RELU         = 6'd30;

  logic [5:0] phase;
  logic work_gclk, soft_accept, act_accept;
  logic state_valid, base_state_valid, tile_last_hold, activation_silu_hold;
  logic [15:0] state_max, state_sum, base_state_max, base_state_sum;
  logic [15:0] next_max, old_scale_hold, old_scaled_hold, new_sum_hold;
  logic [15:0] final_sum_hold;
  logic [LANES*16-1:0] score_hold, exp_hold, activation_hold;
  logic [15:0] max_l1 [0:MAX_L1-1];
  logic [15:0] max_l2 [0:MAX_L2-1];
  logic [15:0] max_l3 [0:MAX_L3-1];
  logic [15:0] sum_l1 [0:MAX_L1-1];
  logic [15:0] sum_l2 [0:MAX_L2-1];
  logic [15:0] sum_l3 [0:MAX_L3-1];
  logic [15:0] sum_l4;
  logic [15:0] delta_y [0:LANES-1];
  logic [15:0] exp_y [0:LANES-1];
  logic [15:0] recip_y [0:LANES-1];
  logic [15:0] sigmoid_y [0:LANES-1];
  logic [15:0] elem_y [0:LANES-1];
  logic [15:0] sum1_y [0:MAX_L1-1];
  logic [15:0] sum2_y [0:MAX_L2-1];
  logic [15:0] sum3_y [0:MAX_L3-1];
  logic [15:0] sum4_y;
  logic [LANES-1:0] delta_valid, exp_valid, recip_valid, sigmoid_valid, elem_valid;
  logic [MAX_L1-1:0] sum1_valid;
  logic [MAX_L2-1:0] sum2_valid;
  logic [MAX_L3-1:0] sum3_valid;
  logic sum4_valid, old_delta_valid, old_exp_valid, old_mul_valid, final_valid;
  logic [15:0] old_delta_y, old_exp_y, old_mul_y, final_y;
  logic [15:0] max_value_comb;
  integer i;

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

  assign tile_ready = (phase == IDLE);
  assign activation_ready = (phase == IDLE) && !tile_valid;
  assign soft_accept = tile_valid && tile_ready;
  assign act_accept = activation_valid && activation_ready;
  assign state_max_out = state_max;
  assign state_sum_out = state_sum;
  assign max_value_comb = (base_state_valid && fp16_ge(base_state_max,
                          fp16_max(max_l3[0], max_l3[1]))) ? base_state_max :
                          fp16_max(max_l3[0], max_l3[1]);

  OPENROAD_CLKGATE u_work_clkgate (
    .CK(clk), .E((phase != IDLE) | soft_accept | act_accept | state_reset), .GCK(work_gclk)
  );

  genvar g;
  generate
    for (g = 0; g < LANES; g = g + 1) begin : g_lane
      attacc_fp16_add_fast_pipe u_delta (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == DELTA_ISSUE),
        .a(score_hold[g*16 +: 16]), .b(fp16_neg(next_max)),
        .out_valid(delta_valid[g]), .y(delta_y[g])
      );
      attacc_fp16_exp_neg_pipe u_exp (
        .clk(clk), .rst_n(rst_n), .in_valid(delta_valid[g]), .x(delta_y[g]),
        .out_valid(exp_valid[g]), .y(exp_y[g])
      );
      // The paper leaves divider count open.  The tile-width reciprocal array
      // makes a lane-local normalization result available; the current online
      // protocol exports lane 0 because all lanes divide the same state sum.
      (* keep = "true" *) attacc_fp16_recip_pipe u_recip (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == RECIP_ISSUE), .x(final_sum_hold),
        .out_valid(recip_valid[g]), .y(recip_y[g])
      );
      attacc_fp16_sigmoid_pipe u_sigmoid (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == ACT_SIG_ISSUE),
        .x(activation_hold[g*16 +: 16]), .out_valid(sigmoid_valid[g]), .y(sigmoid_y[g])
      );
      attacc_fp16_mul_pipe u_elementwise_mul (
        .clk(clk), .rst_n(rst_n),
        .in_valid(phase == ACT_MUL_ISSUE),
        .a(activation_hold[g*16 +: 16]), .b(sigmoid_y[g]),
        .out_valid(elem_valid[g]), .y(elem_y[g])
      );
    end
    for (g = 0; g < MAX_L1; g = g + 1) begin : g_sum_l1
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == SUM1_ISSUE),
        .a(exp_hold[(2*g)*16 +: 16]), .b(exp_hold[(2*g+1)*16 +: 16]),
        .out_valid(sum1_valid[g]), .y(sum1_y[g])
      );
    end
    for (g = 0; g < MAX_L2; g = g + 1) begin : g_sum_l2
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == SUM2_ISSUE),
        .a(sum_l1[2*g]), .b(sum_l1[2*g+1]), .out_valid(sum2_valid[g]), .y(sum2_y[g])
      );
    end
    for (g = 0; g < MAX_L3; g = g + 1) begin : g_sum_l3
      attacc_fp16_add_fast_pipe u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(phase == SUM3_ISSUE),
        .a(sum_l2[2*g]), .b(sum_l2[2*g+1]), .out_valid(sum3_valid[g]), .y(sum3_y[g])
      );
    end
  endgenerate

  attacc_fp16_add_fast_pipe u_sum_l4 (
    .clk(clk), .rst_n(rst_n), .in_valid(phase == SUM4_ISSUE),
    .a(sum_l3[0]), .b(sum_l3[1]), .out_valid(sum4_valid), .y(sum4_y)
  );
  attacc_fp16_add_fast_pipe u_old_delta (
    .clk(clk), .rst_n(rst_n), .in_valid(phase == OLD_DELTA_ISSUE),
    .a(base_state_max), .b(fp16_neg(next_max)), .out_valid(old_delta_valid), .y(old_delta_y)
  );
  attacc_fp16_exp_neg_pipe u_old_exp (
    .clk(clk), .rst_n(rst_n), .in_valid(old_delta_valid), .x(old_delta_y),
    .out_valid(old_exp_valid), .y(old_exp_y)
  );
  attacc_fp16_mul_pipe u_old_rescale_mul (
    .clk(clk), .rst_n(rst_n), .in_valid(phase == OLD_MUL_ISSUE),
    .a(base_state_sum), .b(old_scale_hold), .out_valid(old_mul_valid), .y(old_mul_y)
  );
  attacc_fp16_add_fast_pipe u_final_add (
    .clk(clk), .rst_n(rst_n), .in_valid(phase == FINAL_ISSUE),
    .a(old_scaled_hold), .b(new_sum_hold), .out_valid(final_valid), .y(final_y)
  );

  always_ff @(posedge work_gclk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= IDLE; state_valid <= 0; state_max <= 0; state_sum <= 0;
      base_state_valid <= 0; base_state_max <= 0; base_state_sum <= 0;
      next_max <= 0; old_scale_hold <= 0; old_scaled_hold <= 0; new_sum_hold <= 0;
      final_sum_hold <= 0; score_hold <= 0; exp_hold <= 0; activation_hold <= 0;
      tile_last_hold <= 0; activation_silu_hold <= 0; tile_ack <= 0; bank_rescale <= 0;
      normalizer_recip <= 0; weight_data <= 0; weight_valid <= 0; sequence_done <= 0;
      activation_ack <= 0; activation_out_valid <= 0; activation_result <= 0;
      for (i = 0; i < MAX_L1; i = i + 1) begin max_l1[i] <= 0; sum_l1[i] <= 0; end
      for (i = 0; i < MAX_L2; i = i + 1) begin max_l2[i] <= 0; sum_l2[i] <= 0; end
      for (i = 0; i < MAX_L3; i = i + 1) begin max_l3[i] <= 0; sum_l3[i] <= 0; end
      sum_l4 <= 0;
    end else begin
      tile_ack <= 0; weight_valid <= 0; sequence_done <= 0;
      activation_ack <= 0; activation_out_valid <= 0;
      case (phase)
        IDLE: begin
          if (soft_accept) begin
            score_hold <= score_data;
            tile_last_hold <= tile_last;
            base_state_valid <= state_valid && !state_reset;
            base_state_max <= state_max;
            base_state_sum <= state_sum;
            for (i = 0; i < MAX_L1; i = i + 1)
              max_l1[i] <= fp16_max(score_data[(2*i)*16 +: 16], score_data[(2*i+1)*16 +: 16]);
            phase <= MAX2;
          end else if (act_accept) begin
            activation_hold <= activation_data;
            activation_silu_hold <= activation_silu;
            phase <= activation_silu ? ACT_SIG_ISSUE : ACT_RELU;
          end else if (state_reset) begin
            state_valid <= 0; state_max <= 0; state_sum <= 0;
          end
        end
        MAX2: begin
          for (i = 0; i < MAX_L2; i = i + 1) max_l2[i] <= fp16_max(max_l1[2*i], max_l1[2*i+1]);
          phase <= MAX3;
        end
        MAX3: begin
          for (i = 0; i < MAX_L3; i = i + 1) max_l3[i] <= fp16_max(max_l2[2*i], max_l2[2*i+1]);
          phase <= MAX4;
        end
        MAX4: begin next_max <= max_value_comb; phase <= DELTA_ISSUE; end
        DELTA_ISSUE: phase <= DELTA_WAIT;
        DELTA_WAIT: if (&delta_valid) phase <= EXP_WAIT;
        EXP_WAIT: if (&exp_valid) begin
          for (i = 0; i < LANES; i = i + 1) exp_hold[i*16 +: 16] <= exp_y[i];
          phase <= base_state_valid ? OLD_DELTA_ISSUE : SUM1_ISSUE;
          if (!base_state_valid) begin old_scale_hold <= 0; old_scaled_hold <= 0; end
        end
        OLD_DELTA_ISSUE: phase <= OLD_DELTA_WAIT;
        OLD_DELTA_WAIT: if (old_delta_valid) phase <= OLD_EXP_WAIT;
        OLD_EXP_WAIT: if (old_exp_valid) begin old_scale_hold <= old_exp_y; phase <= OLD_MUL_ISSUE; end
        OLD_MUL_ISSUE: phase <= OLD_MUL_WAIT;
        OLD_MUL_WAIT: if (old_mul_valid) begin old_scaled_hold <= old_mul_y; phase <= SUM1_ISSUE; end
        SUM1_ISSUE: phase <= SUM1_WAIT;
        SUM1_WAIT: if (&sum1_valid) begin
          for (i = 0; i < MAX_L1; i = i + 1) sum_l1[i] <= sum1_y[i];
          phase <= SUM2_ISSUE;
        end
        SUM2_ISSUE: phase <= SUM2_WAIT;
        SUM2_WAIT: if (&sum2_valid) begin
          for (i = 0; i < MAX_L2; i = i + 1) sum_l2[i] <= sum2_y[i];
          phase <= SUM3_ISSUE;
        end
        SUM3_ISSUE: phase <= SUM3_WAIT;
        SUM3_WAIT: if (&sum3_valid) begin
          for (i = 0; i < MAX_L3; i = i + 1) sum_l3[i] <= sum3_y[i];
          phase <= SUM4_ISSUE;
        end
        SUM4_ISSUE: phase <= SUM4_WAIT;
        SUM4_WAIT: if (sum4_valid) begin sum_l4 <= sum4_y; new_sum_hold <= sum4_y; phase <= FINAL_ISSUE; end
        FINAL_ISSUE: phase <= FINAL_WAIT;
        FINAL_WAIT: if (final_valid) begin final_sum_hold <= final_y; phase <= RECIP_ISSUE; end
        RECIP_ISSUE: phase <= RECIP_WAIT;
        RECIP_WAIT: if (&recip_valid) begin
          state_max <= next_max; state_sum <= final_sum_hold; state_valid <= 1'b1;
          normalizer_recip <= recip_y[0]; bank_rescale <= old_scale_hold;
          for (i = 0; i < LANES; i = i + 1) weight_data[i*16 +: 16] <= exp_hold[i*16 +: 16];
          weight_valid <= 1'b1; tile_ack <= 1'b1; sequence_done <= tile_last_hold; phase <= IDLE;
        end
        ACT_SIG_ISSUE: phase <= ACT_SIG_WAIT;
        ACT_SIG_WAIT: if (&sigmoid_valid) phase <= ACT_MUL_ISSUE;
        ACT_MUL_ISSUE: phase <= ACT_MUL_WAIT;
        ACT_MUL_WAIT: if (&elem_valid) begin
          for (i = 0; i < LANES; i = i + 1) activation_result[i*16 +: 16] <= elem_y[i];
          activation_ack <= 1'b1; activation_out_valid <= 1'b1; phase <= IDLE;
        end
        ACT_RELU: begin
          for (i = 0; i < LANES; i = i + 1) activation_result[i*16 +: 16] <= fp16_relu(activation_hold[i*16 +: 16]);
          activation_ack <= 1'b1; activation_out_valid <= 1'b1; phase <= IDLE;
        end
        default: phase <= IDLE;
      endcase
    end
  end
endmodule
