`timescale 1ns/1ps

// 256-bit vector-word write path, matching one word of the GemV FF-based
// vector-buffer proxy.  A real PIM implementation would replace it with a
// macro characterized in its own PDK.
module attacc_vecword_write_unit (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         write_valid,
  input  logic [255:0] write_data,
  output logic [255:0] word_data
);
  logic write_gclk;
  OPENROAD_CLKGATE u_write_clkgate (
    .CK(clk), .E(write_valid), .GCK(write_gclk)
  );
  always_ff @(posedge write_gclk or negedge rst_n) begin
    if (!rst_n)
      word_data <= '0;
    else
      word_data <= write_data;
  end
endmodule

// Four-slot 256-bit state store with the same five-cycle recurrence spacing
// and controller clock gating as melon_accumulation_unit, but without the
// arithmetic pipeline. It isolates local state/control energy from 16 FP16
// adder energy.
module attacc_psum_state_unit (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         update_valid,
  output logic         update_ready,
  input  logic [1:0]   update_slot,
  input  logic [255:0] update_data,
  output logic [255:0] selected_state,
  output logic [255:0] result_data
);
  logic [255:0] state [0:3];
  logic [2:0] cooldown [0:3];
  logic [3:0] cooldown_active;
  logic state_enable, state_gclk;
  logic accept;
  integer i;

  assign update_ready = (cooldown[update_slot] == 3'd0);
  assign accept = update_valid && update_ready;
  generate
    genvar slot;
    for (slot = 0; slot < 4; slot = slot + 1)
      assign cooldown_active[slot] = |cooldown[slot];
  endgenerate
  assign state_enable = accept | (|cooldown_active);
  assign selected_state = state[update_slot];

  OPENROAD_CLKGATE u_state_clkgate (
    .CK(clk), .E(state_enable), .GCK(state_gclk)
  );

  always_ff @(posedge state_gclk or negedge rst_n) begin
    if (!rst_n) begin
      result_data <= '0;
      for (i = 0; i < 4; i = i + 1) begin
        state[i] <= '0;
        cooldown[i] <= '0;
      end
    end else begin
      for (i = 0; i < 4; i = i + 1)
        if (cooldown[i] != 0)
          cooldown[i] <= cooldown[i] - 1'b1;
      if (accept) begin
        cooldown[update_slot] <= 3'd5;
        state[update_slot] <= update_data;
        result_data <= update_data;
      end
    end
  end
endmodule
