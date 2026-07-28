`timescale 1ns/1ps

// MELON Base-Die Vector Unit: pipelined online-softmax state engine.
//
// A PIM score tile is accepted only when tile_ready is high.  The exact FP16
// comparator tree and the Q4 exp/div approximation then flow through
// max(4 stages), exp+scale(1), sum(3) and state commit.  Online softmax has a
// true inter-tile dependency, so the following tile is admitted only after
// the state update/tile_ack; no additional copy of the vector datapath is
// needed.  The Q4 approximation is intentionally the same low-area contract
// as the first reconstruction: exp={1,.75,.5,.25,.125}; the state/reciprocal
// format is exponent-only FP16 at the interface.
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
  output logic [15:0]         state_sum_out
);
  localparam int MAX_L1 = LANES / 2;
  localparam int MAX_L2 = LANES / 4;
  localparam int MAX_L3 = LANES / 8;

  logic gclk;
  logic busy, accept;
  logic state_valid, base_state_valid;
  logic [15:0] state_max, base_state_max, next_max;
  logic [11:0] state_sum_q, base_state_sum_q;
  logic tile_last_hold;
  logic [LANES*16-1:0] score_hold, weight_hold;

  logic [15:0] max_l1 [0:MAX_L1-1];
  logic [15:0] max_l2 [0:MAX_L2-1];
  logic [15:0] max_l3 [0:MAX_L3-1];
  logic [4:0] old_scale_q;
  logic [5:0] sum_l1 [0:MAX_L1-1];
  logic [6:0] sum_l2 [0:MAX_L2-1];
  logic [7:0] sum_l3 [0:MAX_L3-1];
  logic [16:0] scaled_old_q;
  logic [12:0] next_sum_wide;
  logic [11:0] next_sum_q;
  logic v1, v2, v3, v4, v5, v6, v7;
  integer i;

  function automatic logic fp16_ge(input logic [15:0] a, input logic [15:0] b);
    begin
      if (a[15] != b[15]) fp16_ge = !a[15];
      else if (!a[15])    fp16_ge = (a[14:0] >= b[14:0]);
      else                fp16_ge = (a[14:0] <= b[14:0]);
    end
  endfunction

  function automatic logic [15:0] fp16_max(input logic [15:0] a, input logic [15:0] b);
    begin
      fp16_max = fp16_ge(a, b) ? a : b;
    end
  endfunction

  function automatic logic [4:0] exp_q_approx(
    input logic [15:0] score, input logic [15:0] maximum
  );
    logic [4:0] es, em;
    begin
      es = score[14:10]; em = maximum[14:10];
      if (score == maximum) exp_q_approx = 5'd16;
      else if (score[15] != maximum[15]) exp_q_approx = 5'd2;
      else if (es == em) exp_q_approx = 5'd12;
      else if ((!score[15] && (es + 1'b1 == em)) ||
               ( score[15] && (es == em + 1'b1))) exp_q_approx = 5'd8;
      else exp_q_approx = 5'd4;
    end
  endfunction

  function automatic logic [15:0] weight_to_fp16(input logic [4:0] q);
    begin
      case (q)
        5'd16: weight_to_fp16 = 16'h3c00;
        5'd12: weight_to_fp16 = 16'h3a00;
        5'd8 : weight_to_fp16 = 16'h3800;
        5'd4 : weight_to_fp16 = 16'h3400;
        default: weight_to_fp16 = 16'h3000;
      endcase
    end
  endfunction

  function automatic logic [15:0] q_to_fp16(input logic [11:0] q);
    integer bit_index;
    begin
      bit_index = 0;
      for (integer k = 0; k < 12; k = k + 1) if (q[k]) bit_index = k;
      if (q == 0) q_to_fp16 = 16'h0000;
      else q_to_fp16 = {1'b0, (5'd11 + bit_index[4:0]), 10'b0};
    end
  endfunction

  function automatic logic [15:0] recip_q_to_fp16(input logic [11:0] q);
    integer bit_index;
    begin
      bit_index = 0;
      for (integer k = 0; k < 12; k = k + 1) if (q[k]) bit_index = k;
      if (q == 0) recip_q_to_fp16 = 16'h0000;
      else recip_q_to_fp16 = {1'b0, (5'd19 - bit_index[4:0]), 10'b0};
    end
  endfunction

  // Multiplication by the five Q4 LUT constants is implemented with shifts
  // and add/sub, rather than a generic 12x5 multiplier.
  function automatic logic [16:0] scale_q4(
    input logic [11:0] value, input logic [4:0] scale
  );
    begin
      case (scale)
        5'd16: scale_q4 = value;
        5'd12: scale_q4 = value - (value >> 2);
        5'd8 : scale_q4 = value >> 1;
        5'd4 : scale_q4 = value >> 2;
        5'd2 : scale_q4 = value >> 3;
        default: scale_q4 = '0;
      endcase
    end
  endfunction

  assign tile_ready = !busy;
  assign accept = tile_valid && tile_ready;
  assign state_max_out = state_max;
  assign state_sum_out = q_to_fp16(state_sum_q);

  // The state/data registers only receive a clock while a tile moves through
  // the pipeline (or when software explicitly resets online-softmax state).
  OPENROAD_CLKGATE u_clkgate (
    .CK  (clk),
    .E   (accept | v1 | v2 | v3 | v4 | v5 | v6 | v7 | state_reset),
    .GCK (gclk)
  );

  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      state_valid <= 1'b0;
      state_max <= '0;
      state_sum_q <= '0;
      base_state_valid <= 1'b0;
      base_state_max <= '0;
      base_state_sum_q <= '0;
      next_max <= '0;
      old_scale_q <= '0;
      scaled_old_q <= '0;
      next_sum_wide <= '0;
      tile_last_hold <= 1'b0;
      score_hold <= '0;
      weight_hold <= '0;
      tile_ack <= 1'b0;
      bank_rescale <= '0;
      normalizer_recip <= '0;
      weight_data <= '0;
      weight_valid <= 1'b0;
      sequence_done <= 1'b0;
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0;
      v5 <= 1'b0; v6 <= 1'b0; v7 <= 1'b0;
      for (i = 0; i < MAX_L1; i = i + 1) begin max_l1[i] <= '0; sum_l1[i] <= '0; end
      for (i = 0; i < MAX_L2; i = i + 1) begin max_l2[i] <= '0; sum_l2[i] <= '0; end
      for (i = 0; i < MAX_L3; i = i + 1) begin max_l3[i] <= '0; sum_l3[i] <= '0; end
    end else begin
      tile_ack <= 1'b0;
      weight_valid <= 1'b0;
      sequence_done <= 1'b0;
      v1 <= accept;
      v2 <= v1;
      v3 <= v2;
      v4 <= v3;
      v5 <= v4;
      v6 <= v5;
      v7 <= v6;

      if (accept) begin
        busy <= 1'b1;
        score_hold <= score_data;
        tile_last_hold <= tile_last;
        base_state_valid <= state_valid && !state_reset;
        base_state_max <= state_max;
        base_state_sum_q <= state_sum_q;
        for (i = 0; i < MAX_L1; i = i + 1)
          max_l1[i] <= fp16_max(score_data[(2*i)*16 +: 16], score_data[(2*i+1)*16 +: 16]);
      end
      if (v1)
        for (i = 0; i < MAX_L2; i = i + 1)
          max_l2[i] <= fp16_max(max_l1[2*i], max_l1[2*i+1]);
      if (v2)
        for (i = 0; i < MAX_L3; i = i + 1)
          max_l3[i] <= fp16_max(max_l2[2*i], max_l2[2*i+1]);
      if (v3) begin
        next_max <= (base_state_valid && fp16_ge(base_state_max, fp16_max(max_l3[0], max_l3[1]))) ?
                    base_state_max : fp16_max(max_l3[0], max_l3[1]);
        old_scale_q <= !base_state_valid ? 5'd0 :
          ((base_state_max == fp16_max(max_l3[0], max_l3[1])) ? 5'd16 :
           exp_q_approx(base_state_max, fp16_max(max_l3[0], max_l3[1])));
      end
      if (v4) begin
        for (i = 0; i < LANES; i = i + 1)
          weight_hold[i*16 +: 16] <= weight_to_fp16(exp_q_approx(score_hold[i*16 +: 16], next_max));
        for (i = 0; i < MAX_L1; i = i + 1)
          sum_l1[i] <= exp_q_approx(score_hold[(2*i)*16 +: 16], next_max) +
                       exp_q_approx(score_hold[(2*i+1)*16 +: 16], next_max);
        scaled_old_q <= scale_q4(base_state_sum_q, old_scale_q);
      end
      if (v5)
        for (i = 0; i < MAX_L2; i = i + 1)
          sum_l2[i] <= sum_l1[2*i] + sum_l1[2*i+1];
      if (v6)
        for (i = 0; i < MAX_L3; i = i + 1)
          sum_l3[i] <= sum_l2[2*i] + sum_l2[2*i+1];
      if (v7) begin
        next_sum_wide <= scaled_old_q + sum_l3[0] + sum_l3[1];
        if ((scaled_old_q + sum_l3[0] + sum_l3[1]) > 13'd4095)
          state_sum_q <= 12'hfff;
        else
          state_sum_q <= scaled_old_q + sum_l3[0] + sum_l3[1];
        state_max <= next_max;
        state_valid <= 1'b1;
        bank_rescale <= weight_to_fp16(old_scale_q);
        normalizer_recip <= recip_q_to_fp16(
          ((scaled_old_q + sum_l3[0] + sum_l3[1]) > 13'd4095) ?
          12'hfff : (scaled_old_q + sum_l3[0] + sum_l3[1]));
        weight_data <= weight_hold;
        weight_valid <= 1'b1;
        tile_ack <= 1'b1;
        sequence_done <= tile_last_hold;
        busy <= 1'b0;
      end
      if (state_reset && !accept && !busy) begin
        state_valid <= 1'b0;
        state_max <= '0;
        state_sum_q <= '0;
      end
    end
  end
endmodule
