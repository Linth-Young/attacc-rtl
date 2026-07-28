`timescale 1ns/1ps

// Inference-grade FP16 elementary functions.
//
// These units target finite Transformer inference operands rather than full
// correctly-rounded IEEE-754 transcendental semantics.  They replace the
// former coarse 5-7 bucket approximations with range reduction followed by
// piecewise-linear interpolation:
//
//   exp(x), x <= 0 : x -> Q5.12, z=x*log2(e), 32 segments for 2^-frac(z)
//   1/x            : 64 segments over the normalized FP16 significand
//
// Both tables interpolate between adjacent endpoints.  The table endpoint
// quantization is Q1.15; final results are rounded back to binary16.  The
// pipelines accept one operand per cycle and are explicitly staged for the
// 1.5 ns Vector Unit target.  NaN/Inf/zero have deterministic behavior, while
// denormal inputs are flushed/saturated because online-softmax denominators
// and 1+exp terms are finite normal values.

module attacc_fp16_exp_neg_hi_pipe (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] x,
  output logic        out_valid,
  output logic [15:0] y
);
  localparam logic [15:0] EXP2_NEG_LUT [0:32] = '{
    16'h8000, 16'h7d42, 16'h7a93, 16'h77f2, 16'h7560, 16'h72dd,
    16'h7066, 16'h6dfe, 16'h6ba2, 16'h6954, 16'h6712, 16'h64dd,
    16'h62b4, 16'h6096, 16'h5e84, 16'h5c7e, 16'h5a82, 16'h5892,
    16'h56ac, 16'h54d1, 16'h52ff, 16'h5138, 16'h4f7b, 16'h4dc7,
    16'h4c1c, 16'h4a7a, 16'h48e2, 16'h4752, 16'h45cb, 16'h444c,
    16'h42d5, 16'h4167, 16'h4000
  };

  logic v0, v1, v2, v3, gclk;
  logic [17:0] mag_q0;
  logic [30:0] log2_product1;
  logic [15:0] lut_lo2, lut_hi2;
  logic [6:0] frac_rem2;
  logic [5:0] scale2, scale3;
  logic [22:0] interp_product3;
  logic [16:0] interp_base3;

  function automatic logic [17:0] fp16_abs_to_q12(input logic [15:0] a);
    integer e, sh, mant, q, rem, half;
    begin
      e = a[14:10];
      mant = 1024 + a[9:0];
      q = 0;
      if (e == 0) begin
        q = 0;
      end else if (e >= 22) begin
        q = 18'h3ffff;
      end else if (e >= 13) begin
        q = mant << (e - 13);
        if (q > 18'h3ffff) q = 18'h3ffff;
      end else begin
        sh = 13 - e;
        q = mant >> sh;
        rem = mant & ((1 << sh) - 1);
        half = 1 << (sh - 1);
        if ((rem > half) || ((rem == half) && (q & 1))) q = q + 1;
      end
      fp16_abs_to_q12 = q[17:0];
    end
  endfunction

  function automatic logic [15:0] q15_scaled_to_fp16(
    input logic [16:0] base,
    input logic [5:0]  scale
  );
    integer exp_field, mant, rounded, sh, rem, half, sub;
    begin
      q15_scaled_to_fp16 = 16'h0000;
      if (base != 0 && scale < 25) begin
        if (base >= 17'd32768) begin
          exp_field = 15 - scale;
          mant = 0;
        end else begin
          exp_field = 14 - scale;
          rounded = (base - 17'd16384);
          mant = rounded >> 4;
          rem = rounded & 15;
          if ((rem > 8) || ((rem == 8) && (mant & 1))) mant = mant + 1;
          if (mant >= 1024) begin
            mant = 0;
            exp_field = exp_field + 1;
          end
        end
        if (exp_field > 0) begin
          q15_scaled_to_fp16 = {1'b0, exp_field[4:0], mant[9:0]};
        end else begin
          sh = scale - 9;
          if (sh > 17) begin
            sub = 0;
          end else begin
            sub = base >> sh;
            rem = base & ((1 << sh) - 1);
            half = 1 << (sh - 1);
            if ((rem > half) || ((rem == half) && (sub & 1))) sub = sub + 1;
          end
          if (sub >= 1024) q15_scaled_to_fp16 = 16'h0400;
          else q15_scaled_to_fp16 = {1'b0, 5'b0, sub[9:0]};
        end
      end
    end
  endfunction

  OPENROAD_CLKGATE u_clkgate (
    .CK(clk), .E(in_valid | v0 | v1 | v2 | v3), .GCK(gclk)
  );

  always_ff @(posedge gclk or negedge rst_n) begin
    integer z_q;
    integer idx;
    integer delta;
    integer interp;
    if (!rst_n) begin
      v0 <= 0; v1 <= 0; v2 <= 0; v3 <= 0;
      mag_q0 <= 0; log2_product1 <= 0;
      lut_lo2 <= 0; lut_hi2 <= 0; frac_rem2 <= 0;
      scale2 <= 0; scale3 <= 0;
      interp_product3 <= 0; interp_base3 <= 0;
    end else begin
      v0 <= in_valid;
      if (in_valid)
        mag_q0 <= x[15] ? fp16_abs_to_q12(x) : 18'd0;

      v1 <= v0;
      if (v0)
        log2_product1 <= mag_q0 * 13'd5909; // round(log2(e)*2^12)

      v2 <= v1;
      if (v1) begin
        z_q = (log2_product1 + 31'd2048) >> 12;
        scale2 <= (z_q[17:12] > 6'd31) ? 6'd31 : z_q[17:12];
        idx = z_q[11:7];
        lut_lo2 <= EXP2_NEG_LUT[idx];
        lut_hi2 <= EXP2_NEG_LUT[idx + 1];
        frac_rem2 <= z_q[6:0];
      end

      v3 <= v2;
      if (v2) begin
        delta = lut_lo2 - lut_hi2;
        interp_product3 <= delta * frac_rem2;
        interp = lut_lo2 - ((delta * frac_rem2 + 64) >> 7);
        interp_base3 <= interp[16:0];
        scale3 <= scale2;
      end

    end
  end
  // Packing is intentionally combinational after the interpolation register.
  // The following FP16 adder captures it on the next edge; removing a
  // redundant output register keeps the 32-head recurrence at full issue rate.
  assign y = q15_scaled_to_fp16(interp_base3, scale3);
  assign out_valid = v3;
endmodule


module attacc_fp16_recip_hi_pipe (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] x,
  output logic        out_valid,
  output logic [15:0] y
);
  localparam logic [15:0] RECIP_LUT [0:64] = '{
    16'h8000, 16'h7e08, 16'h7c1f, 16'h7a45, 16'h7878, 16'h76ba,
    16'h7507, 16'h7361, 16'h71c7, 16'h7038, 16'h6eb4, 16'h6d3a,
    16'h6bca, 16'h6a64, 16'h6907, 16'h67b2, 16'h6666, 16'h6523,
    16'h63e7, 16'h62b3, 16'h6186, 16'h6060, 16'h5f41, 16'h5e29,
    16'h5d17, 16'h5c0c, 16'h5b06, 16'h5a06, 16'h590b, 16'h5816,
    16'h5726, 16'h563b, 16'h5555, 16'h5474, 16'h5398, 16'h52bf,
    16'h51ec, 16'h511c, 16'h5050, 16'h4f89, 16'h4ec5, 16'h4e05,
    16'h4d48, 16'h4c90, 16'h4bda, 16'h4b28, 16'h4a79, 16'h49cd,
    16'h4925, 16'h487f, 16'h47dc, 16'h473c, 16'h469f, 16'h4604,
    16'h456c, 16'h44d7, 16'h4444, 16'h43b4, 16'h4326, 16'h429a,
    16'h4211, 16'h4189, 16'h4104, 16'h4081, 16'h4000
  };

  logic v0, v1, v2, v3, gclk;
  logic sign0, zero0, inf0, nan0;
  logic [4:0] exponent0, exponent1, exponent2;
  logic [9:0] fraction0;
  logic sign1, sign2, zero1, zero2, inf1, inf2, nan1, nan2;
  logic [15:0] lut_lo1, lut_hi1;
  logic [3:0] frac_rem1;
  logic [16:0] interp_base2;

  function automatic logic [15:0] recip_pack(
    input logic sign,
    input logic zero,
    input logic inf,
    input logic nan,
    input logic [4:0] exponent,
    input logic [16:0] base
  );
    integer exp_field, mant, rem, sh, half, sub;
    begin
      if (nan) recip_pack = 16'h7e00;
      else if (zero) recip_pack = {sign, 15'h7bff};
      else if (inf) recip_pack = {sign, 15'h0000};
      else begin
        if (base >= 17'd32768) begin
          exp_field = 30 - exponent;
          mant = 0;
        end else begin
          exp_field = 29 - exponent;
          mant = (base - 17'd16384) >> 4;
          rem = (base - 17'd16384) & 15;
          if ((rem > 8) || ((rem == 8) && (mant & 1))) mant = mant + 1;
          if (mant >= 1024) begin
            mant = 0;
            exp_field = exp_field + 1;
          end
        end
        if (exp_field >= 31) begin
          recip_pack = {sign, 5'h1e, 10'h3ff};
        end else if (exp_field <= 0) begin
          sh = exponent - 24;
          if (sh > 17) begin
            sub = 0;
          end else begin
            sub = base >> sh;
            rem = base & ((1 << sh) - 1);
            half = 1 << (sh - 1);
            if ((rem > half) || ((rem == half) && (sub & 1))) sub = sub + 1;
          end
          if (sub >= 1024) recip_pack = {sign, 5'h01, 10'h000};
          else recip_pack = {sign, 5'h00, sub[9:0]};
        end else begin
          recip_pack = {sign, exp_field[4:0], mant[9:0]};
        end
      end
    end
  endfunction

  OPENROAD_CLKGATE u_clkgate (
    .CK(clk), .E(in_valid | v0 | v1 | v2), .GCK(gclk)
  );

  always_ff @(posedge gclk or negedge rst_n) begin
    integer idx;
    integer delta;
    integer interp;
    if (!rst_n) begin
      v0 <= 0; v1 <= 0; v2 <= 0; v3 <= 0;
      sign0 <= 0; zero0 <= 0; inf0 <= 0; nan0 <= 0;
      exponent0 <= 0; fraction0 <= 0;
      sign1 <= 0; zero1 <= 0; inf1 <= 0; nan1 <= 0; exponent1 <= 0;
      sign2 <= 0; zero2 <= 0; inf2 <= 0; nan2 <= 0; exponent2 <= 0;
      lut_lo1 <= 0; lut_hi1 <= 0; frac_rem1 <= 0;
      interp_base2 <= 0; y <= 0;
    end else begin
      v0 <= in_valid;
      if (in_valid) begin
        sign0 <= x[15];
        exponent0 <= x[14:10];
        fraction0 <= x[9:0];
        zero0 <= (x[14:0] == 0) || (x[14:10] == 0);
        inf0 <= (x[14:10] == 5'h1f) && (x[9:0] == 0);
        nan0 <= (x[14:10] == 5'h1f) && (x[9:0] != 0);
      end

      v1 <= v0;
      if (v0) begin
        idx = fraction0[9:4];
        lut_lo1 <= RECIP_LUT[idx];
        lut_hi1 <= RECIP_LUT[idx + 1];
        frac_rem1 <= fraction0[3:0];
        sign1 <= sign0; zero1 <= zero0; inf1 <= inf0; nan1 <= nan0;
        exponent1 <= exponent0;
      end

      v2 <= v1;
      if (v1) begin
        delta = lut_lo1 - lut_hi1;
        interp = lut_lo1 - ((delta * frac_rem1 + 8) >> 4);
        interp_base2 <= interp[16:0];
        sign2 <= sign1; zero2 <= zero1; inf2 <= inf1; nan2 <= nan1;
        exponent2 <= exponent1;
      end

      v3 <= v2;
      if (v2)
        y <= recip_pack(sign2, zero2, inf2, nan2, exponent2, interp_base2);
    end
  end
  assign out_valid = v3;
endmodule
