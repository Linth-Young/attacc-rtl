`ifndef ATTACC_FP16_OPERATORS_SV
`define ATTACC_FP16_OPERATORS_SV
`timescale 1ns/1ps

module attacc_fp16_mul (
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic [15:0] y
);
  import attacc_fp16_pkg::*;
  always_comb y = fp16_mul_rne(a, b);
endmodule

module attacc_fp16_add (
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic [15:0] y
);
  import attacc_fp16_pkg::*;
  always_comb y = fp16_add_rne(a, b);
endmodule

// Timing-oriented FP16 arithmetic pipelines used by the PPA implementation.
// They retain binary16 sign/exponent/fraction encoding and RNE for finite
// operands.  NaN/Inf propagation is optional (disabled by the top-level PPA
// configuration); gradual-underflow results are flushed to signed zero.  The
// fixed latency lets the GemV controller schedule the paper's 16 physical
// adders without putting a full FP operation in one 1.5 ns clock interval.
module attacc_fp16_mul_pipe #(
  // AttAcc inference consumes finite FP16 activations and weights.  Keeping
  // this false lets synthesis remove NaN/Inf propagation flops and muxes;
  // set it for a full IEEE exceptional-value datapath when that is required.
  parameter bit IEEE_SPECIALS = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic        out_valid,
  output logic [15:0] y
);
  logic v0, v1;
  logic gclk;
  logic s1, special1;
  logic [15:0] special_y1;
  logic [21:0] product1;
  logic [5:0] exp_sum1;
  integer i;
  reg [10:0] sig;
  reg [11:0] sig_rnd;
  reg guard_bit, round_bit, sticky_bit;
  reg [5:0] exp_field;
  reg [15:0] result2;

  always_comb begin
    result2 = 16'h0000;
    if (IEEE_SPECIALS && special1) begin
      result2 = special_y1;
    end else if (product1 == 0) begin
      result2 = {s1, 15'b0};
    end else begin
      if (product1[21]) begin
        sig = product1[21:11];
        guard_bit = product1[10]; round_bit = product1[9];
        sticky_bit = |product1[8:0];
        exp_field = exp_sum1 - 6'd14;
      end else begin
        sig = product1[20:10];
        guard_bit = product1[9]; round_bit = product1[8];
        sticky_bit = |product1[7:0];
        exp_field = exp_sum1 - 6'd15;
      end
      sig_rnd = {1'b0, sig};
      if (guard_bit && (round_bit || sticky_bit || sig[0])) sig_rnd = sig_rnd + 1'b1;
      if (sig_rnd[11]) begin
        sig = sig_rnd[11:1];
        exp_field = exp_field + 1'b1;
      end else begin
        sig = sig_rnd[10:0];
      end
      if (exp_field >= 6'd31)
        result2 = {s1, 5'h1f, 10'b0};
      else if (exp_field == 0)
        result2 = {s1, 15'b0};
      else
        result2 = {s1, exp_field[4:0], sig[9:0]};
    end
  end

  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0), .GCK(gclk));

  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin
      v0 <= 0; v1 <= 0; y <= 0;
      s1 <= 0; special1 <= 0; special_y1 <= 0;
      product1 <= 0; exp_sum1 <= 0;
    end else begin
      v0 <= in_valid;
      if (in_valid) begin
        s1 <= a[15] ^ b[15];
        special1 <= 0;
        special_y1 <= 16'h0000;
        product1 <= {((a[14:10] == 0) ? 1'b0 : 1'b1), a[9:0]} *
                    {((b[14:10] == 0) ? 1'b0 : 1'b1), b[9:0]};
        exp_sum1 <= ((a[14:10] == 0) ? 6'd1 : {1'b0, a[14:10]}) +
                    ((b[14:10] == 0) ? 6'd1 : {1'b0, b[14:10]});
        if (IEEE_SPECIALS && ((a[14:10] == 5'h1f) || (b[14:10] == 5'h1f))) begin
          special1 <= 1;
          if ((a[9:0] != 0) || (b[9:0] != 0) ||
              (((a[14:10] == 0) && (a[9:0] == 0)) ||
               ((b[14:10] == 0) && (b[9:0] == 0))))
            special_y1 <= 16'h7e00;
          else
            special_y1 <= {a[15] ^ b[15], 5'h1f, 10'b0};
        end
      end
      v1 <= v0;
      if (v0) y <= result2;
    end
  end
  assign out_valid = v1;
endmodule

module attacc_fp16_add_pipe #(
  // See attacc_fp16_mul_pipe.  Finite FP16 values, including zero, remain
  // supported in the default area-optimized mode.
  parameter bit IEEE_SPECIALS = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic        out_valid,
  output logic [15:0] y
);
  function automatic [13:0] shift_sticky(input [13:0] x, input [5:0] sh);
    integer k;
    reg sticky;
    begin
      if (sh == 0) shift_sticky = x;
      else if (sh >= 14) shift_sticky = {13'b0, |x};
      else begin
        shift_sticky = x >> sh; sticky = 0;
        for (k = 0; k < 14; k = k + 1) if (k < sh) sticky = sticky | x[k];
        shift_sticky[0] = shift_sticky[0] | sticky;
      end
    end
  endfunction
  logic v0, v1, v2, v3;
  logic gclk;
  logic sign1, same_sign1, special1;
  logic [15:0] special_y1;
  logic [5:0] exp1;
  logic [13:0] large1, small1;
  logic sign2, special2;
  logic [15:0] special_y2;
  logic [5:0] exp2;
  logic [14:0] mag2;
  logic sign3, special3;
  logic [15:0] special_y3;
  logic [5:0] exp3;
  logic [13:0] norm3;
  reg [13:0] norm;
  reg [10:0] sig;
  reg [11:0] sig_rnd;
  reg [5:0] exp_calc, exp_round;
  reg guard_bit, round_bit, sticky_bit;
  reg [15:0] result4;
  integer n;
  always_comb begin
    norm = 0; exp_calc = exp2;
    if (mag2 != 0) begin
      if (mag2[14]) begin
        norm = mag2[14:1]; norm[0] = norm[0] | mag2[0]; exp_calc = exp2 + 1'b1;
      end else begin
        norm = mag2[13:0];
        for (n = 0; n < 14; n = n + 1)
          if (!norm[13] && (exp_calc > 0)) begin norm = norm << 1; exp_calc = exp_calc - 1'b1; end
      end
    end
  end

  always_comb begin
    result4 = 16'h0000; sig = 0; sig_rnd = 0; guard_bit = 0; round_bit = 0; sticky_bit = 0;
    exp_round = exp3;
    if (IEEE_SPECIALS && special3) result4 = special_y3;
    else if (norm3 == 0) result4 = 16'h0000;
    else begin
      sig = norm3[13:3]; guard_bit = norm3[2]; round_bit = norm3[1]; sticky_bit = norm3[0];
      sig_rnd = {1'b0, sig};
      if (guard_bit && (round_bit || sticky_bit || sig[0])) sig_rnd = sig_rnd + 1'b1;
      if (sig_rnd[11]) begin sig = sig_rnd[11:1]; exp_round = exp_round + 1'b1; end else sig = sig_rnd[10:0];
      if (exp_round >= 6'd31) result4 = {sign3, 5'h1f, 10'b0};
      else if (exp_round == 0) result4 = {sign3, 15'b0};
      else result4 = {sign3, exp_round[4:0], sig[9:0]};
    end
  end

  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0 | v1 | v2), .GCK(gclk));

  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin
      v0<=0; v1<=0; v2<=0; v3<=0; sign1<=0; same_sign1<=0; special1<=0;
      special_y1<=0; exp1<=0; large1<=0; small1<=0; sign2<=0; special2<=0;
      special_y2<=0; exp2<=0; mag2<=0; sign3<=0; special3<=0; special_y3<=0; exp3<=0; norm3<=0; y<=0;
    end else begin
      v0 <= in_valid;
      if (in_valid) begin
        special1 <= 0; special_y1 <= 0;
        same_sign1 <= (a[15] == b[15]);
        if (IEEE_SPECIALS && ((a[14:10] == 5'h1f) || (b[14:10] == 5'h1f))) begin
          special1 <= 1;
          if ((a[9:0] != 0) || (b[9:0] != 0) ||
              ((a[14:10] == 5'h1f) && (b[14:10] == 5'h1f) && (a[15] != b[15]))) special_y1 <= 16'h7e00;
          else if (a[14:10] == 5'h1f) special_y1 <= a; else special_y1 <= b;
          sign1 <= 0; exp1 <= 0; large1 <= 0; small1 <= 0;
        end else if ((a[14:10] > b[14:10]) ||
                     ((a[14:10] == b[14:10]) &&
                      ({(a[14:10] != 0),a[9:0]} >= {(b[14:10] != 0),b[9:0]}))) begin
          sign1 <= a[15]; exp1 <= (a[14:10] == 0) ? 6'd1 : {1'b0,a[14:10]};
          large1 <= {(a[14:10] != 0),a[9:0],3'b0};
          small1 <= shift_sticky({(b[14:10] != 0),b[9:0],3'b0}, ((a[14:10] == 0)?6'd1:{1'b0,a[14:10]}) - ((b[14:10] == 0)?6'd1:{1'b0,b[14:10]}));
        end else begin
          sign1 <= b[15]; exp1 <= (b[14:10] == 0) ? 6'd1 : {1'b0,b[14:10]};
          large1 <= {(b[14:10] != 0),b[9:0],3'b0};
          small1 <= shift_sticky({(a[14:10] != 0),a[9:0],3'b0}, ((b[14:10] == 0)?6'd1:{1'b0,b[14:10]}) - ((a[14:10] == 0)?6'd1:{1'b0,a[14:10]}));
        end
      end
      v1 <= v0;
      if (v0) begin
        sign2 <= sign1; special2 <= special1; special_y2 <= special_y1; exp2 <= exp1;
        mag2 <= (IEEE_SPECIALS && special1) ? 0 : (same_sign1 ? (large1 + small1) : (large1 - small1));
      end
      v2 <= v1;
      if (v1) begin sign3<=sign2; special3<=special2; special_y3<=special_y2; exp3<=exp_calc; norm3<=norm; end
      v3 <= v2; if (v2) y <= result4;
    end
  end
  assign out_valid = v3;
endmodule

`endif
