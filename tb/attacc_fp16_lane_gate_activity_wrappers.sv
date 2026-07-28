// Same finite-FP16 II=1 stream for small gate-level arithmetic comparisons.
module attacc_fp16_add_lane_gate_activity_wrapper (
  input wire clk,
  input wire rst_n,
  output wire activity_out_valid,
  output wire [15:0] activity_y
);
  localparam integer COMMANDS = 256;
  reg [8:0] command_index;
  wire in_valid = (command_index < COMMANDS);
  wire [15:0] a;
  wire [15:0] b;
  wire out_valid;
  wire [15:0] y;

  function [15:0] fp16_stream_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_stream_value = 16'h3c00;
        4'h1: fp16_stream_value = 16'h3800;
        4'h2: fp16_stream_value = 16'h4000;
        4'h3: fp16_stream_value = 16'h3a00;
        4'h4: fp16_stream_value = 16'h3e00;
        4'h5: fp16_stream_value = 16'h4200;
        4'h6: fp16_stream_value = 16'h3400;
        4'h7: fp16_stream_value = 16'h4100;
        4'h8: fp16_stream_value = 16'h3d00;
        4'h9: fp16_stream_value = 16'h4400;
        4'ha: fp16_stream_value = 16'h3900;
        4'hb: fp16_stream_value = 16'h3f00;
        4'hc: fp16_stream_value = 16'h4300;
        4'hd: fp16_stream_value = 16'h3600;
        4'he: fp16_stream_value = 16'h4080;
        default: fp16_stream_value = 16'h3b00;
      endcase
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (in_valid) command_index <= command_index + 1'b1;
  end
  assign a = fp16_stream_value(command_index[3:0]);
  assign b = fp16_stream_value(command_index[3:0] + 4'h5);
  assign activity_out_valid = out_valid;
  assign activity_y = y;
  attacc_fp16_add_lane_unit dut (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
    .out_valid(out_valid), .y(y)
  );
endmodule

module attacc_fp16_mac_lane_gate_activity_wrapper (
  input wire clk,
  input wire rst_n,
  output wire activity_out_valid,
  output wire [15:0] activity_y
);
  localparam integer COMMANDS = 256;
  reg [8:0] command_index;
  wire in_valid = (command_index < COMMANDS);
  wire [15:0] a;
  wire [15:0] b;
  wire [15:0] addend;
  wire out_valid;
  wire [15:0] y;

  function [15:0] fp16_stream_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_stream_value = 16'h3c00;
        4'h1: fp16_stream_value = 16'h3800;
        4'h2: fp16_stream_value = 16'h4000;
        4'h3: fp16_stream_value = 16'h3a00;
        4'h4: fp16_stream_value = 16'h3e00;
        4'h5: fp16_stream_value = 16'h4200;
        4'h6: fp16_stream_value = 16'h3400;
        4'h7: fp16_stream_value = 16'h4100;
        4'h8: fp16_stream_value = 16'h3d00;
        4'h9: fp16_stream_value = 16'h4400;
        4'ha: fp16_stream_value = 16'h3900;
        4'hb: fp16_stream_value = 16'h3f00;
        4'hc: fp16_stream_value = 16'h4300;
        4'hd: fp16_stream_value = 16'h3600;
        4'he: fp16_stream_value = 16'h4080;
        default: fp16_stream_value = 16'h3b00;
      endcase
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (in_valid) command_index <= command_index + 1'b1;
  end
  assign a = fp16_stream_value(command_index[3:0]);
  assign b = fp16_stream_value(command_index[3:0] + 4'h5);
  assign addend = fp16_stream_value(command_index[3:0] + 4'ha);
  assign activity_out_valid = out_valid;
  assign activity_y = y;
  attacc_fp16_mac_lane_unit dut (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
    .addend(addend), .out_valid(out_valid), .y(y)
  );
endmodule
