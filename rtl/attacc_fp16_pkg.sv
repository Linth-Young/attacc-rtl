`ifndef ATTACC_FP16_PKG_SV
`define ATTACC_FP16_PKG_SV
`timescale 1ns/1ps

// Synthesizable IEEE-754 binary16 operators used by the AttAcc GEMV unit.
// Rounding is round-to-nearest, ties-to-even.  The functions are intentionally
// combinational: the GEMV unit determines the pipeline boundary.
package attacc_fp16_pkg;

  function automatic [13:0] shr_sticky14;
    input [13:0] value;
    input integer shift;
    reg [13:0] shifted;
    reg sticky;
    integer j;
    begin
      if (shift == 0) begin
        shr_sticky14 = value;
      end else if (shift >= 14) begin
        shr_sticky14 = {13'b0, |value};
      end else begin
        shifted = value >> shift;
        sticky = 1'b0;
        for (j = 0; j < 14; j = j + 1)
          if (j < shift) sticky = sticky | value[j];
        shifted[0] = shifted[0] | sticky;
        shr_sticky14 = shifted;
      end
    end
  endfunction

  function automatic [15:0] fp16_mul_rne;
    input [15:0] a;
    input [15:0] b;
    reg sign_out;
    reg [4:0] exp_a_field, exp_b_field;
    reg [9:0] frac_a, frac_b;
    reg [10:0] mant_a, mant_b, mant_round;
    reg [11:0] mant_rounded_ext;
    reg [21:0] product, normalized_product;
    reg guard_bit, round_bit, sticky_bit;
    integer exp_a, exp_b, exp_out, lead, i;
    begin
      sign_out    = a[15] ^ b[15];
      exp_a_field = a[14:10];
      exp_b_field = b[14:10];
      frac_a      = a[9:0];
      frac_b      = b[9:0];

      if ((exp_a_field == 5'h1f) || (exp_b_field == 5'h1f)) begin
        // NaN propagation, and infinity times zero is a quiet NaN.
        if (((exp_a_field == 5'h1f) && (frac_a != 0)) ||
            ((exp_b_field == 5'h1f) && (frac_b != 0)) ||
            (((exp_a_field == 0) && (frac_a == 0)) ||
             ((exp_b_field == 0) && (frac_b == 0))))
          fp16_mul_rne = 16'h7e00;
        else
          fp16_mul_rne = {sign_out, 5'h1f, 10'b0};
      end else if (((exp_a_field == 0) && (frac_a == 0)) ||
                   ((exp_b_field == 0) && (frac_b == 0))) begin
        fp16_mul_rne = {sign_out, 15'b0};
      end else begin
        if (exp_a_field == 0) begin
          exp_a  = -14;
          mant_a = {1'b0, frac_a};
        end else begin
          exp_a  = $signed({1'b0, exp_a_field}) - 15;
          mant_a = {1'b1, frac_a};
        end
        if (exp_b_field == 0) begin
          exp_b  = -14;
          mant_b = {1'b0, frac_b};
        end else begin
          exp_b  = $signed({1'b0, exp_b_field}) - 15;
          mant_b = {1'b1, frac_b};
        end

        product = mant_a * mant_b;
        lead = 0;
        for (i = 21; i >= 0; i = i - 1)
          if (product[i] && (lead == 0)) lead = i;
        normalized_product = product << (21 - lead);
        exp_out = exp_a + exp_b + lead - 20;

        // 11-bit significand plus guard, round, and sticky bits.
        mant_round = normalized_product[21:11];
        guard_bit  = normalized_product[10];
        round_bit  = normalized_product[9];
        sticky_bit = |normalized_product[8:0];
        mant_rounded_ext = {1'b0, mant_round};
        if (guard_bit && (round_bit || sticky_bit || mant_round[0]))
          mant_rounded_ext = mant_rounded_ext + 1'b1;
        if (mant_rounded_ext[11]) begin
          // 1.111... rounded to 10.000...; re-normalize and advance exp.
          mant_round = mant_rounded_ext[11:1];
          exp_out = exp_out + 1;
        end else begin
          mant_round = mant_rounded_ext[10:0];
        end

        if (exp_out > 15) begin
          fp16_mul_rne = {sign_out, 5'h1f, 10'b0};
        end else if (exp_out >= -14) begin
          fp16_mul_rne = {sign_out, exp_out + 15, mant_round[9:0]};
        end else begin
          // Gradual underflow: shift the hidden-bit significand into frac.
          if ((-14 - exp_out) >= 11)
            fp16_mul_rne = {sign_out, 15'b0};
          else begin
            mant_round = mant_round >> (-14 - exp_out);
            fp16_mul_rne = {sign_out, 5'b0, mant_round[9:0]};
          end
        end
      end
    end
  endfunction

  function automatic [15:0] fp16_add_rne;
    input [15:0] a;
    input [15:0] b;
    reg sign_a, sign_b, sign_out;
    reg [4:0] exp_a_field, exp_b_field;
    reg [9:0] frac_a, frac_b;
    reg [10:0] mant_a, mant_b, mant_round;
    reg [11:0] mant_rounded_ext;
    reg [13:0] mag_a, mag_b;
    reg [14:0] mag_result;
    reg [13:0] rounded_mag;
    reg guard_bit, round_bit, sticky_bit;
    integer exp_a, exp_b, exp_out, shift, norm_i;
    begin
      sign_a = a[15]; sign_b = b[15];
      exp_a_field = a[14:10]; exp_b_field = b[14:10];
      frac_a = a[9:0]; frac_b = b[9:0];

      if ((exp_a_field == 5'h1f) || (exp_b_field == 5'h1f)) begin
        if (((exp_a_field == 5'h1f) && (frac_a != 0)) ||
            ((exp_b_field == 5'h1f) && (frac_b != 0)) ||
            ((exp_a_field == 5'h1f) && (exp_b_field == 5'h1f) &&
             (sign_a != sign_b)))
          fp16_add_rne = 16'h7e00;
        else if (exp_a_field == 5'h1f)
          fp16_add_rne = a;
        else
          fp16_add_rne = b;
      end else if ((exp_a_field == 0) && (frac_a == 0)) begin
        fp16_add_rne = b;
      end else if ((exp_b_field == 0) && (frac_b == 0)) begin
        fp16_add_rne = a;
      end else begin
        if (exp_a_field == 0) begin exp_a = -14; mant_a = {1'b0, frac_a}; end
        else begin exp_a = $signed({1'b0, exp_a_field}) - 15; mant_a = {1'b1, frac_a}; end
        if (exp_b_field == 0) begin exp_b = -14; mant_b = {1'b0, frac_b}; end
        else begin exp_b = $signed({1'b0, exp_b_field}) - 15; mant_b = {1'b1, frac_b}; end

        mag_a = {mant_a, 3'b0};
        mag_b = {mant_b, 3'b0};
        if ((exp_a > exp_b) || ((exp_a == exp_b) && (mag_a >= mag_b))) begin
          exp_out = exp_a;
          shift = exp_a - exp_b;
          mag_b = shr_sticky14(mag_b, shift);
          sign_out = sign_a;
          if (sign_a == sign_b) mag_result = mag_a + mag_b;
          else                  mag_result = mag_a - mag_b;
        end else begin
          exp_out = exp_b;
          shift = exp_b - exp_a;
          mag_a = shr_sticky14(mag_a, shift);
          sign_out = sign_b;
          if (sign_a == sign_b) mag_result = mag_a + mag_b;
          else                  mag_result = mag_b - mag_a;
        end

        if (mag_result == 0) begin
          fp16_add_rne = 16'b0;
        end else begin
          if (mag_result[14]) begin
            rounded_mag = mag_result[14:1];
            rounded_mag[0] = rounded_mag[0] | mag_result[0];
            exp_out = exp_out + 1;
          end else begin
            rounded_mag = mag_result[13:0];
            // Fixed iteration bound keeps the normalizer synthesizable.
            for (norm_i = 0; norm_i < 14; norm_i = norm_i + 1)
              if (!rounded_mag[13] && (exp_out > -14)) begin
                rounded_mag = rounded_mag << 1;
                exp_out = exp_out - 1;
              end
          end

          mant_round = rounded_mag[13:3];
          guard_bit  = rounded_mag[2];
          round_bit  = rounded_mag[1];
          sticky_bit = rounded_mag[0];
          mant_rounded_ext = {1'b0, mant_round};
          if (guard_bit && (round_bit || sticky_bit || mant_round[0]))
            mant_rounded_ext = mant_rounded_ext + 1'b1;
          if (mant_rounded_ext[11]) begin
            mant_round = mant_rounded_ext[11:1];
            exp_out = exp_out + 1;
          end else begin
            mant_round = mant_rounded_ext[10:0];
          end

          if (exp_out > 15)
            fp16_add_rne = {sign_out, 5'h1f, 10'b0};
          else if ((exp_out == -14) && !mant_round[10])
            fp16_add_rne = {sign_out, 5'b0, mant_round[9:0]};
          else
            fp16_add_rne = {sign_out, exp_out + 15, mant_round[9:0]};
        end
      end
    end
  endfunction
endpackage

`endif
