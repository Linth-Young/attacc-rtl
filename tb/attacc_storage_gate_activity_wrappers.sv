module attacc_vecword_write_gate_activity_wrapper (
  input wire clk,
  input wire rst_n,
  output wire [255:0] activity_word_data
);
  localparam integer COMMANDS = 256;
  reg [8:0] command_index;
  wire write_valid = (command_index < COMMANDS);
  wire [255:0] write_data;
  wire [255:0] word_data;

  function [15:0] fp16_stream_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_stream_value = 16'h3c00; 4'h1: fp16_stream_value = 16'h3800;
        4'h2: fp16_stream_value = 16'h4000; 4'h3: fp16_stream_value = 16'h3a00;
        4'h4: fp16_stream_value = 16'h3e00; 4'h5: fp16_stream_value = 16'h4200;
        4'h6: fp16_stream_value = 16'h3400; 4'h7: fp16_stream_value = 16'h4100;
        4'h8: fp16_stream_value = 16'h3d00; 4'h9: fp16_stream_value = 16'h4400;
        4'ha: fp16_stream_value = 16'h3900; 4'hb: fp16_stream_value = 16'h3f00;
        4'hc: fp16_stream_value = 16'h4300; 4'hd: fp16_stream_value = 16'h3600;
        4'he: fp16_stream_value = 16'h4080; default: fp16_stream_value = 16'h3b00;
      endcase
    end
  endfunction
  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1)
      assign write_data[lane*16 +: 16] = fp16_stream_value(command_index[3:0] + lane[3:0]);
  endgenerate
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (write_valid) command_index <= command_index + 1'b1;
  end
  assign activity_word_data = word_data;
  attacc_vecword_write_unit dut (
    .clk(clk), .rst_n(rst_n), .write_valid(write_valid), .write_data(write_data), .word_data(word_data)
  );
endmodule

module attacc_psum_state_gate_activity_wrapper (
  input wire clk,
  input wire rst_n,
  output wire activity_ready,
  output wire [255:0] activity_selected_state,
  output wire [255:0] activity_result_data
);
  localparam integer COMMANDS = 256;
  reg [8:0] command_index;
  wire ready;
  wire update_valid = (command_index < COMMANDS) && ready;
  wire [1:0] update_slot = command_index[1:0];
  wire [255:0] update_data;
  wire [255:0] selected_state;
  wire [255:0] result_data;

  function [15:0] fp16_stream_value;
    input [3:0] selector;
    begin
      case (selector)
        4'h0: fp16_stream_value = 16'h3c00; 4'h1: fp16_stream_value = 16'h3800;
        4'h2: fp16_stream_value = 16'h4000; 4'h3: fp16_stream_value = 16'h3a00;
        4'h4: fp16_stream_value = 16'h3e00; 4'h5: fp16_stream_value = 16'h4200;
        4'h6: fp16_stream_value = 16'h3400; 4'h7: fp16_stream_value = 16'h4100;
        4'h8: fp16_stream_value = 16'h3d00; 4'h9: fp16_stream_value = 16'h4400;
        4'ha: fp16_stream_value = 16'h3900; 4'hb: fp16_stream_value = 16'h3f00;
        4'hc: fp16_stream_value = 16'h4300; 4'hd: fp16_stream_value = 16'h3600;
        4'he: fp16_stream_value = 16'h4080; default: fp16_stream_value = 16'h3b00;
      endcase
    end
  endfunction
  genvar lane;
  generate
    for (lane = 0; lane < 16; lane = lane + 1)
      assign update_data[lane*16 +: 16] = fp16_stream_value(command_index[3:0] + lane[3:0]);
  endgenerate
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) command_index <= '0;
    else if (update_valid) command_index <= command_index + 1'b1;
  end
  assign activity_ready = ready;
  assign activity_selected_state = selected_state;
  assign activity_result_data = result_data;
  attacc_psum_state_unit dut (
    .clk(clk), .rst_n(rst_n), .update_valid(update_valid), .update_ready(ready),
    .update_slot(update_slot), .update_data(update_data),
    .selected_state(selected_state), .result_data(result_data)
  );
endmodule
