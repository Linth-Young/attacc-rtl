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

// Fixed-latency FP16 transcendental approximations used by the MELON Vector
// Unit.  The HPCA paper identifies exponent/divider/activation hardware but
// does not prescribe a polynomial or a vendor math macro.  These blocks make
// that architectural resource explicit while retaining a small, monotonic
// finite-FP16 approximation that can be swapped for a characterized macro.
// Each unit has two registered stages; it is safe to instantiate one per tile
// lane without adding an unpipelined LUT to a 666 MHz control path.
module attacc_fp16_exp_neg_pipe (
  input logic clk, input logic rst_n, input logic in_valid,
  input logic [15:0] x, output logic out_valid, output logic [15:0] y
);
  function automatic logic [15:0] exp_neg_lut(input logic [15:0] a);
    logic [14:0] mag;
    begin
      mag = a[14:0];
      if (!a[15] || mag == 0)       exp_neg_lut = 16'h3c00;
      else if (mag < 15'h3800)      exp_neg_lut = 16'h3a3b;
      else if (mag < 15'h3c00)      exp_neg_lut = 16'h38da;
      else if (mag < 15'h4000)      exp_neg_lut = 16'h35e3;
      else if (mag < 15'h4400)      exp_neg_lut = 16'h3054;
      else if (mag < 15'h4800)      exp_neg_lut = 16'h24b0;
      else                           exp_neg_lut = 16'h0d7c;
    end
  endfunction
  logic v0, v1, gclk;
  logic [15:0] y0;
  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0), .GCK(gclk));
  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin v0 <= 0; v1 <= 0; y0 <= 0; y <= 0; end
    else begin
      v0 <= in_valid;
      if (in_valid) y0 <= exp_neg_lut(x);
      v1 <= v0;
      if (v0) y <= y0;
    end
  end
  assign out_valid = v1;
endmodule

module attacc_fp16_recip_pipe (
  input logic clk, input logic rst_n, input logic in_valid,
  input logic [15:0] x, output logic out_valid, output logic [15:0] y
);
  function automatic logic [15:0] recip_lut(input logic [15:0] a);
    integer eout;
    logic [9:0] frac;
    begin
      if (a[14:0] == 0) recip_lut = 16'h7bff;
      else if (a[14:10] == 5'h1f) recip_lut = 16'h0000;
      else if (a[9:0] == 0) begin
        eout = 30 - a[14:10];
        if (eout <= 0) recip_lut = 16'h0000;
        else if (eout >= 31) recip_lut = 16'h7bff;
        else recip_lut = {1'b0, eout[4:0], 10'b0};
      end else begin
        eout = 29 - a[14:10];
        case (a[9:7])
          3'd0: frac = 10'd797; 3'd1: frac = 10'd614;
          3'd2: frac = 10'd466; 3'd3: frac = 10'd341;
          3'd4: frac = 10'd237; 3'd5: frac = 10'd146;
          default: frac = 10'd69;
        endcase
        if (eout <= 0) recip_lut = 16'h0000;
        else if (eout >= 31) recip_lut = 16'h7bff;
        else recip_lut = {1'b0, eout[4:0], frac};
      end
    end
  endfunction
  logic v0, v1, gclk;
  logic [15:0] y0;
  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0), .GCK(gclk));
  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin v0 <= 0; v1 <= 0; y0 <= 0; y <= 0; end
    else begin
      v0 <= in_valid;
      if (in_valid) y0 <= recip_lut(x);
      v1 <= v0;
      if (v0) y <= y0;
    end
  end
  assign out_valid = v1;
endmodule

module attacc_fp16_sigmoid_pipe (
  input logic clk, input logic rst_n, input logic in_valid,
  input logic [15:0] x, output logic out_valid, output logic [15:0] y
);
  function automatic logic [15:0] sigmoid_lut(input logic [15:0] a);
    logic [14:0] mag;
    begin
      mag = a[14:0];
      if (mag < 15'h3800)           sigmoid_lut = 16'h3800;
      else if (mag < 15'h3c00)      sigmoid_lut = a[15] ? 16'h344e : 16'h39d9;
      else if (mag < 15'h4000)      sigmoid_lut = a[15] ? 16'h2f9e : 16'h3b0c;
      else if (mag < 15'h4400)      sigmoid_lut = a[15] ? 16'h2a04 : 16'h3ba0;
      else                           sigmoid_lut = a[15] ? 16'h249c : 16'h3bdb;
    end
  endfunction
  logic v0, v1, gclk;
  logic [15:0] y0;
  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0), .GCK(gclk));
  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin v0 <= 0; v1 <= 0; y0 <= 0; y <= 0; end
    else begin
      v0 <= in_valid;
      if (in_valid) y0 <= sigmoid_lut(x);
      v1 <= v0;
      if (v0) y <= y0;
    end
  end
  assign out_valid = v1;
endmodule

// Finite-normal binary16 adder for the Vector Unit's softmax recurrence.
// It deliberately omits NaN/Inf/denormal handling and uses truncation after
// normalization.  Transformer inference tiles use finite normal operands;
// this reduces the cost of each of the 33 parallel reduction/subtraction
// lanes while preserving an FP16 sign/exponent/mantissa datapath and explicit
// four-stage timing boundary.  GEMV continues to use attacc_fp16_add_pipe.
module attacc_fp16_add_fast_pipe (
  input logic clk, input logic rst_n, input logic in_valid,
  input logic [15:0] a, input logic [15:0] b,
  output logic out_valid, output logic [15:0] y
);
  function automatic [3:0] lzc12(input logic [11:0] x);
    begin
      casez (x)
        12'b1???????????: lzc12 = 0;
        12'b01??????????: lzc12 = 1;
        12'b001?????????: lzc12 = 2;
        12'b0001????????: lzc12 = 3;
        12'b00001???????: lzc12 = 4;
        12'b000001??????: lzc12 = 5;
        12'b0000001?????: lzc12 = 6;
        12'b00000001????: lzc12 = 7;
        12'b000000001???: lzc12 = 8;
        12'b0000000001??: lzc12 = 9;
        12'b00000000001?: lzc12 = 10;
        default:          lzc12 = 11;
      endcase
    end
  endfunction
  logic v0, v1, v2, v3, gclk;
  logic sign1, same1;
  logic [5:0] exp1;
  logic [11:0] large1, small1;
  logic sign2;
  logic [5:0] exp2;
  logic [12:0] raw2;
  logic sign3;
  logic [5:0] exp3;
  logic [10:0] mant3;
  logic zero3;
  logic [15:0] result4;
  logic a_is_large;
  logic [4:0] exp_a, exp_b, exp_large, exp_small;
  logic [10:0] mant_large, mant_small;
  logic [5:0] exp_diff;
  logic [3:0] shift3;

  always_comb begin
    exp_a = a[14:10]; exp_b = b[14:10];
    a_is_large = ({exp_a, a[9:0]} >= {exp_b, b[9:0]});
    exp_large = a_is_large ? exp_a : exp_b;
    exp_small = a_is_large ? exp_b : exp_a;
    mant_large = a_is_large ? {(exp_a != 0), a[9:0]} : {(exp_b != 0), b[9:0]};
    mant_small = a_is_large ? {(exp_b != 0), b[9:0]} : {(exp_a != 0), a[9:0]};
    exp_diff = exp_large - exp_small;
    shift3 = lzc12(raw2[11:0]);
    if (zero3 || exp3 == 0) result4 = 16'h0000;
    else if (exp3 >= 31) result4 = {sign3, 5'h1f, 10'b0};
    else result4 = {sign3, exp3[4:0], mant3[9:0]};
  end

  OPENROAD_CLKGATE u_clkgate (.CK(clk), .E(in_valid | v0 | v1 | v2), .GCK(gclk));
  always_ff @(posedge gclk or negedge rst_n) begin
    if (!rst_n) begin
      v0 <= 0; v1 <= 0; v2 <= 0; v3 <= 0; y <= 0;
      sign1 <= 0; same1 <= 0; exp1 <= 0; large1 <= 0; small1 <= 0;
      sign2 <= 0; exp2 <= 0; raw2 <= 0; sign3 <= 0; exp3 <= 0; mant3 <= 0; zero3 <= 0;
    end else begin
      v0 <= in_valid;
      if (in_valid) begin
        sign1 <= a_is_large ? a[15] : b[15];
        same1 <= (a[15] == b[15]);
        exp1 <= {1'b0, exp_large};
        large1 <= {mant_large, 1'b0};
        small1 <= (exp_diff >= 12) ? 12'b0 : ({mant_small, 1'b0} >> exp_diff);
      end
      v1 <= v0;
      if (v0) begin
        sign2 <= sign1; exp2 <= exp1;
        raw2 <= same1 ? ({1'b0, large1} + {1'b0, small1}) : ({1'b0, large1} - {1'b0, small1});
      end
      v2 <= v1;
      if (v1) begin
        sign3 <= sign2;
        zero3 <= (raw2 == 0);
        if (raw2[12]) begin exp3 <= exp2 + 1'b1; mant3 <= raw2[12:2]; end
        else begin exp3 <= (exp2 > shift3) ? (exp2 - shift3) : 0; mant3 <= raw2[11:1] << shift3; end
      end
      v3 <= v2;
      if (v2) y <= result4;
    end
  end
  assign out_valid = v3;
endmodule

`endif
