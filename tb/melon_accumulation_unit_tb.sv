`timescale 1ns/1ps

module melon_accumulation_unit_tb;
  localparam int LANES = 16;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic partial_valid;
  logic partial_ready;
  logic [1:0] partial_slot;
  logic partial_clear;
  logic partial_last;
  logic [LANES*16-1:0] partial_data;
  logic result_valid;
  logic [1:0] result_slot;
  logic [LANES*16-1:0] result_data;
  integer result_count = 0;

  always #5 clk = ~clk;

  function automatic [LANES*16-1:0] splat(input logic [15:0] value);
    integer lane;
    begin
      for (lane = 0; lane < LANES; lane = lane + 1)
        splat[lane*16 +: 16] = value;
    end
  endfunction

  task automatic send_partial(
    input logic [1:0] slot,
    input logic clear,
    input logic last,
    input logic [15:0] value
  );
    begin
      @(negedge clk);
      partial_slot  = slot;
      partial_clear = clear;
      partial_last  = last;
      partial_data  = splat(value);
      while (!partial_ready)
        @(negedge clk);
      partial_valid = 1'b1;
      @(negedge clk);
      partial_valid = 1'b0;
    end
  endtask

  // Sample after the sequential state has settled.  The first two commands
  // exercise two independent slots returning on consecutive cycles; the
  // final result verifies the recurrence (1.0 + 2.0 = 3.0) in one slot.
  always @(negedge clk) begin
    if (result_valid) begin
      case (result_count)
        0: if ((result_slot !== 2'd0) || (result_data !== splat(16'h3c00)))
             $fatal(1, "slot0 result mismatch");
        1: if ((result_slot !== 2'd1) || (result_data !== splat(16'h4000)))
             $fatal(1, "slot1 result mismatch");
        2: if ((result_slot !== 2'd2) || (result_data !== splat(16'h4200)))
             $fatal(1, "slot2 accumulation mismatch");
        default: $fatal(1, "unexpected extra result");
      endcase
      result_count = result_count + 1;
    end
  end

  melon_accumulation_unit #(.LANES(LANES), .ACC_SLOTS(4)) dut (.*);

  initial begin
    partial_valid = 1'b0;
    partial_slot = '0;
    partial_clear = 1'b0;
    partial_last = 1'b0;
    partial_data = '0;
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    send_partial(2'd0, 1'b1, 1'b1, 16'h3c00);
    send_partial(2'd1, 1'b1, 1'b1, 16'h4000);
    send_partial(2'd2, 1'b1, 1'b0, 16'h3c00);
    send_partial(2'd2, 1'b0, 1'b1, 16'h4000);

    repeat (12) @(negedge clk);
    if (result_count != 3)
      $fatal(1, "expected three results, got %0d", result_count);
    $display("PASS: melon_accumulation_unit regression");
    $finish;
  end
endmodule
