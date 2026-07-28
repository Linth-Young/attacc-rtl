// Steady pseudo-channel partial-GEMV traffic for mapped-netlist activity.
// The source advances only on accepted commands, so cooldown backpressure is
// represented rather than being hidden by an idealized fixed-rate driver.
module melon_accumulation_gate_activity_wrapper (
  input wire clk,
  input wire rst_n
);
  localparam integer COMMANDS = 256;
  reg [8:0] command_index;
  wire [1:0] partial_slot = command_index[1:0];
  wire partial_ready;
  wire running = (command_index < COMMANDS);
  wire partial_valid = running && partial_ready;
  wire partial_clear = (command_index[3:2] == 2'd0);
  wire partial_last = (command_index[3:2] == 2'd3);
  wire [255:0] partial_data;
  wire result_valid;
  wire [1:0] result_slot;
  wire [255:0] result_data;

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

  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1) begin : g_lane
      assign partial_data[lane*16 +: 16] =
        fp16_stream_value(command_index[3:0] + lane[3:0]);
    end
  endgenerate

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (partial_valid) command_index <= command_index + 1'b1;
  end

  melon_accumulation_unit dut (
    .clk(clk), .rst_n(rst_n),
    .partial_valid(partial_valid), .partial_ready(partial_ready),
    .partial_slot(partial_slot), .partial_clear(partial_clear),
    .partial_last(partial_last), .partial_data(partial_data),
    .result_valid(result_valid), .result_slot(result_slot), .result_data(result_data)
  );
endmodule
