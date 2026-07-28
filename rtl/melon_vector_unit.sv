`timescale 1ns/1ps

// MELON Base-Die Vector Unit: FP16 online-softmax and ReLU/SiLU engine.
//
// The HPCA submission specifies FP16 comparator/add trees, exponent, divider,
// element-wise arithmetic, and an online-softmax state buffer.  It does not
// specify a transcendental circuit or lane count.  This area-oriented RTL uses
// one pipelined FP16 delta subtractor, reducer, and multiplier. Thus
// every externally visible datum and state value is binary16 and the critical
// arithmetic stages meet the same 1.5 ns target as the GEMV datapath.  The
// cost is a longer tile interval, which is explicit in tile_ready.
//
// exp, reciprocal, and sigmoid are monotonic FP16-output LUT approximations;
// the paper names these units but provides no exact approximation. Replacing
// the three functions by characterized FP16 math macros preserves this port
// and control protocol.
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
  localparam int IDX_W = $clog2(LANES);

  localparam logic [4:0] IDLE             = 5'd0;
  localparam logic [4:0] MAX2             = 5'd1;
  localparam logic [4:0] MAX3             = 5'd2;
  localparam logic [4:0] MAXFINAL         = 5'd3;
  localparam logic [4:0] DELTA_ISSUE      = 5'd4;
  localparam logic [4:0] DELTA_WAIT       = 5'd5;
  localparam logic [4:0] OLD_DELTA_ISSUE  = 5'd6;
  localparam logic [4:0] OLD_DELTA_WAIT   = 5'd7;
  localparam logic [4:0] OLD_MUL_ISSUE    = 5'd8;
  localparam logic [4:0] OLD_MUL_WAIT     = 5'd9;
  localparam logic [4:0] SUM_ISSUE        = 5'd10;
  localparam logic [4:0] SUM_WAIT         = 5'd11;
  localparam logic [4:0] FINAL_ISSUE      = 5'd12;
  localparam logic [4:0] FINAL_WAIT       = 5'd13;
  localparam logic [4:0] ACT_ISSUE        = 5'd14;
  localparam logic [4:0] ACT_WAIT         = 5'd15;

  import attacc_fp16_pkg::*;

  logic [4:0] phase;
  logic work_gclk, soft_accept, act_accept;
  logic state_valid, base_state_valid, tile_last_hold;
  logic [15:0] state_max, state_sum, base_state_max, base_state_sum, next_max;
  logic [15:0] old_scale_hold, old_scaled_hold, reduce_accum;
  logic [IDX_W-1:0] lane_index;
  logic [LANES*16-1:0] score_hold, exp_hold, activation_hold;
  logic activation_silu_hold;

  logic [15:0] max_l1 [0:MAX_L1-1];
  logic [15:0] max_l2 [0:MAX_L2-1];
  logic [15:0] max_l3 [0:MAX_L3-1];
  logic [15:0] max_value_comb;

  logic delta_valid;
  logic [15:0] delta_y;
  logic reducer_valid;
  logic [15:0] reducer_y;
  logic mul_valid;
  logic [15:0] mul_y;
  integer i;

  function automatic logic fp16_ge(input logic [15:0] a, input logic [15:0] b);
    begin
      if (a[15] != b[15]) fp16_ge = !a[15];
      else if (!a[15])    fp16_ge = (a[14:0] >= b[14:0]);
      else                fp16_ge = (a[14:0] <= b[14:0]);
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

  function automatic logic [15:0] fp16_exp_neg_lut(input logic [15:0] x);
    logic [14:0] mag;
    begin
      mag = x[14:0];
      if (!x[15] || mag == 0)  fp16_exp_neg_lut = 16'h3c00;
      else if (mag < 15'h3800) fp16_exp_neg_lut = 16'h3a3b;
      else if (mag < 15'h3c00) fp16_exp_neg_lut = 16'h38da;
      else if (mag < 15'h4000) fp16_exp_neg_lut = 16'h35e3;
      else if (mag < 15'h4400) fp16_exp_neg_lut = 16'h3054;
      else if (mag < 15'h4800) fp16_exp_neg_lut = 16'h24b0;
      else                      fp16_exp_neg_lut = 16'h0d7c;
    end
  endfunction

  function automatic logic [15:0] fp16_recip_lut(input logic [15:0] a);
    integer eout;
    logic [9:0] frac;
    begin
      if (a[14:0] == 0) fp16_recip_lut = 16'h7bff;
      else if (a[14:10] == 5'h1f) fp16_recip_lut = 16'h0000;
      else if (a[9:0] == 0) begin
        eout = 30 - a[14:10];
        if (eout <= 0) fp16_recip_lut = 16'h0000;
        else if (eout >= 31) fp16_recip_lut = 16'h7bff;
        else fp16_recip_lut = {1'b0, eout[4:0], 10'b0};
      end else begin
        eout = 29 - a[14:10];
        case (a[9:7])
          3'd0: frac = 10'd797; 3'd1: frac = 10'd614;
          3'd2: frac = 10'd466; 3'd3: frac = 10'd341;
          3'd4: frac = 10'd237; 3'd5: frac = 10'd146;
          default: frac = 10'd69;
        endcase
        if (eout <= 0) fp16_recip_lut = 16'h0000;
        else if (eout >= 31) fp16_recip_lut = 16'h7bff;
        else fp16_recip_lut = {1'b0, eout[4:0], frac};
      end
    end
  endfunction

  function automatic logic [15:0] fp16_sigmoid_lut(input logic [15:0] a);
    logic [14:0] mag;
    begin
      mag = a[14:0];
      if (mag < 15'h3800) fp16_sigmoid_lut = 16'h3800;
      else if (mag < 15'h3c00) fp16_sigmoid_lut = a[15] ? 16'h344e : 16'h39d9;
      else if (mag < 15'h4000) fp16_sigmoid_lut = a[15] ? 16'h2f9e : 16'h3b0c;
      else if (mag < 15'h4400) fp16_sigmoid_lut = a[15] ? 16'h2a04 : 16'h3ba0;
      else                     fp16_sigmoid_lut = a[15] ? 16'h249c : 16'h3bdb;
    end
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

  attacc_fp16_add_pipe u_delta (
    .clk(clk), .rst_n(rst_n),
    .in_valid((phase == DELTA_ISSUE) | (phase == OLD_DELTA_ISSUE)),
    .a(phase == OLD_DELTA_ISSUE ? base_state_max : score_hold[lane_index*16 +: 16]),
    .b(fp16_neg(next_max)), .out_valid(delta_valid), .y(delta_y)
  );

  // One 4-stage FP16 adder is reused for the online-normalizer recurrence and
  // final state merge. It is never placed on a combinational critical path.
  attacc_fp16_add_pipe u_reducer (
    .clk(clk), .rst_n(rst_n), .in_valid((phase == SUM_ISSUE) | (phase == FINAL_ISSUE)),
    .a(phase == FINAL_ISSUE ? reduce_accum : reduce_accum),
    .b(phase == FINAL_ISSUE ? old_scaled_hold : exp_hold[lane_index*16 +: 16]),
    .out_valid(reducer_valid), .y(reducer_y)
  );

  // The multiplier performs old-state rescaling for softmax and is reused for
  // each activation lane. The two operations are mutually exclusive by phase.
  attacc_fp16_mul_pipe u_multiplier (
    .clk(clk), .rst_n(rst_n), .in_valid((phase == OLD_MUL_ISSUE) | (phase == ACT_ISSUE)),
    .a(phase == ACT_ISSUE ?
       (activation_silu_hold ? activation_hold[lane_index*16 +: 16] : fp16_relu(activation_hold[lane_index*16 +: 16])) :
       base_state_sum),
    .b(phase == ACT_ISSUE ?
       (activation_silu_hold ? fp16_sigmoid_lut(activation_hold[lane_index*16 +: 16]) : 16'h3c00) : old_scale_hold),
    .out_valid(mul_valid), .y(mul_y)
  );

  always_ff @(posedge work_gclk or negedge rst_n) begin
    if (!rst_n) begin
      phase <= IDLE;
      state_valid <= 1'b0;
      state_max <= '0;
      state_sum <= '0;
      base_state_valid <= 1'b0;
      base_state_max <= '0;
      base_state_sum <= '0;
      next_max <= '0;
      old_scale_hold <= '0;
      old_scaled_hold <= '0;
      reduce_accum <= '0;
      lane_index <= '0;
      score_hold <= '0;
      exp_hold <= '0;
      activation_hold <= '0;
      activation_silu_hold <= 1'b0;
      tile_last_hold <= 1'b0;
      tile_ack <= 1'b0;
      bank_rescale <= '0;
      normalizer_recip <= '0;
      weight_data <= '0;
      weight_valid <= 1'b0;
      sequence_done <= 1'b0;
      activation_ack <= 1'b0;
      activation_out_valid <= 1'b0;
      activation_result <= '0;
      for (i = 0; i < MAX_L1; i = i + 1) max_l1[i] <= '0;
      for (i = 0; i < MAX_L2; i = i + 1) max_l2[i] <= '0;
      for (i = 0; i < MAX_L3; i = i + 1) max_l3[i] <= '0;
    end else begin
      tile_ack <= 1'b0;
      weight_valid <= 1'b0;
      sequence_done <= 1'b0;
      activation_ack <= 1'b0;
      activation_out_valid <= 1'b0;

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
            lane_index <= '0;
            phase <= ACT_ISSUE;
          end else if (state_reset) begin
            state_valid <= 1'b0;
            state_max <= '0;
            state_sum <= '0;
          end
        end
        MAX2: begin
          for (i = 0; i < MAX_L2; i = i + 1)
            max_l2[i] <= fp16_max(max_l1[2*i], max_l1[2*i+1]);
          phase <= MAX3;
        end
        MAX3: begin
          for (i = 0; i < MAX_L3; i = i + 1)
            max_l3[i] <= fp16_max(max_l2[2*i], max_l2[2*i+1]);
          phase <= MAXFINAL;
        end
        MAXFINAL: begin
          next_max <= max_value_comb;
          lane_index <= '0;
          phase <= DELTA_ISSUE;
        end
        DELTA_ISSUE: begin
          phase <= DELTA_WAIT;
        end
        DELTA_WAIT: if (delta_valid) begin
          exp_hold[lane_index*16 +: 16] <= fp16_exp_neg_lut(delta_y);
          if (lane_index == LANES-1) begin
            if (base_state_valid) phase <= OLD_DELTA_ISSUE;
            else begin
              old_scale_hold <= '0;
              old_scaled_hold <= '0;
              reduce_accum <= '0;
              lane_index <= '0;
              phase <= SUM_ISSUE;
            end
          end else begin
            lane_index <= lane_index + 1'b1;
            phase <= DELTA_ISSUE;
          end
        end
        OLD_DELTA_ISSUE: phase <= OLD_DELTA_WAIT;
        OLD_DELTA_WAIT: if (delta_valid) begin
          old_scale_hold <= fp16_exp_neg_lut(delta_y);
          phase <= OLD_MUL_ISSUE;
        end
        OLD_MUL_ISSUE: phase <= OLD_MUL_WAIT;
        OLD_MUL_WAIT: if (mul_valid) begin
          old_scaled_hold <= mul_y;
          reduce_accum <= '0;
          lane_index <= '0;
          phase <= SUM_ISSUE;
        end
        SUM_ISSUE: phase <= SUM_WAIT;
        SUM_WAIT: if (reducer_valid) begin
          reduce_accum <= reducer_y;
          if (lane_index == LANES-1) phase <= FINAL_ISSUE;
          else begin
            lane_index <= lane_index + 1'b1;
            phase <= SUM_ISSUE;
          end
        end
        FINAL_ISSUE: phase <= FINAL_WAIT;
        FINAL_WAIT: if (reducer_valid) begin
          state_max <= next_max;
          state_sum <= reducer_y;
          state_valid <= 1'b1;
          bank_rescale <= old_scale_hold;
          normalizer_recip <= fp16_recip_lut(reducer_y);
          weight_data <= exp_hold;
          weight_valid <= 1'b1;
          tile_ack <= 1'b1;
          sequence_done <= tile_last_hold;
          phase <= IDLE;
        end
        ACT_ISSUE: phase <= ACT_WAIT;
        ACT_WAIT: if (mul_valid) begin
          activation_result[lane_index*16 +: 16] <= mul_y;
          if (lane_index == LANES-1) begin
            activation_ack <= 1'b1;
            activation_out_valid <= 1'b1;
            phase <= IDLE;
          end else begin
            lane_index <= lane_index + 1'b1;
            phase <= ACT_ISSUE;
          end
        end
        default: phase <= IDLE;
      endcase
    end
  end
endmodule
