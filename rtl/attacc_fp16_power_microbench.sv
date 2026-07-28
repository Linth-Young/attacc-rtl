`timescale 1ns/1ps

// Small, fully observable arithmetic kernels for like-for-like activity
// comparison.  They use the exact FP16 pipeline implementations used by the
// larger units; they are not substitutes for a 16-lane PIM macro PPA.
module attacc_fp16_add_lane_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic        out_valid,
  output logic [15:0] y
);
  attacc_fp16_add_pipe u_add (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
    .out_valid(out_valid), .y(y)
  );
endmodule

// Context-GEMV arithmetic for one lane: a two-stage FP16 multiplier followed
// by the same four-stage FP16 adder used above.  The addend is delayed with
// the multiplier result, so every accepted input exercises both pipelines.
module attacc_fp16_mac_lane_unit (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [15:0] a,
  input  logic [15:0] b,
  input  logic [15:0] addend,
  output logic        out_valid,
  output logic [15:0] y
);
  logic mul_valid;
  logic [15:0] mul_y;
  logic meta_v0, meta_gclk;
  logic [15:0] addend_p0, addend_p1;

  OPENROAD_CLKGATE u_meta_clkgate (
    .CK(clk), .E(in_valid | meta_v0), .GCK(meta_gclk)
  );

  always_ff @(posedge meta_gclk or negedge rst_n) begin
    if (!rst_n) begin
      meta_v0 <= 1'b0;
      addend_p0 <= '0;
      addend_p1 <= '0;
    end else begin
      meta_v0 <= in_valid;
      if (in_valid)
        addend_p0 <= addend;
      if (meta_v0)
        addend_p1 <= addend_p0;
    end
  end

  attacc_fp16_mul_pipe u_mul (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
    .out_valid(mul_valid), .y(mul_y)
  );
  attacc_fp16_add_pipe u_add (
    .clk(clk), .rst_n(rst_n), .in_valid(mul_valid), .a(mul_y), .b(addend_p1),
    .out_valid(out_valid), .y(y)
  );
endmodule
