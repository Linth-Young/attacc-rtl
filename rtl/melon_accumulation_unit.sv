`timescale 1ns/1ps

// Pseudo-channel accumulation unit from the MELON Base Die.
//
// One command contributes a complete 16-element FP16 partial GEMV vector from
// one Bank PIM.  Commands belonging to the same output tile use the same
// slot: partial_clear marks the first bank result and partial_last marks the
// final bank result.  Thus the PIM controller can use any bank-group size
// without baking a topology-specific bank count into this block.
//
// The implementation deliberately uses one 16-lane FP16 adder vector rather
// than a 4-bank fully parallel tree.  This follows the paper's description of
// a "lightweight accumulation unit" and trades a few collection cycles for
// substantially lower Base-Die area and clock power.  Four scoreboards slots
// hide the four-cycle adder latency when independent output tiles are present.
module melon_accumulation_unit #(
  parameter int LANES     = 16,
  parameter int ACC_SLOTS = 4
) (
  input  logic                   clk,
  input  logic                   rst_n,

  input  logic                   partial_valid,
  output logic                   partial_ready,
  input  logic [$clog2(ACC_SLOTS)-1:0] partial_slot,
  input  logic                   partial_clear,
  input  logic                   partial_last,
  input  logic [LANES*16-1:0]    partial_data,

  output logic                   result_valid,
  output logic [$clog2(ACC_SLOTS)-1:0] result_slot,
  output logic [LANES*16-1:0]    result_data
);
  localparam int SLOT_W = $clog2(ACC_SLOTS);

  logic [LANES*16-1:0] accum [0:ACC_SLOTS-1];
  logic [2:0] cooldown [0:ACC_SLOTS-1];
  logic [LANES*16-1:0] add_y;
  logic [LANES-1:0] add_valid;
  logic [ACC_SLOTS-1:0] cooldown_active;
  logic state_enable, state_gclk;
  logic accept;
  logic [SLOT_W-1:0] slot_p [0:3];
  logic last_p [0:3];
  integer i;

  // An add result is committed one cycle after the pipeline's fourth stage;
  // the five-cycle issue separation keeps a slot recurrence hazard-free.
  assign partial_ready = (cooldown[partial_slot] == 3'd0);
  assign accept = partial_valid && partial_ready;
  assign state_enable = accept | add_valid[0] | (|cooldown_active);

  // Unlike the arithmetic pipelines, this small control/state bank would
  // otherwise see every root-clock edge while the pseudo-channel is idle.
  // Gate it on real work only; reset remains asynchronous.
  OPENROAD_CLKGATE u_state_clkgate (
    .CK(clk), .E(state_enable), .GCK(state_gclk)
  );

  genvar lane;
  generate
    for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane_add
      attacc_fp16_add_pipe u_add (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (accept),
        .a         (partial_clear ? 16'h0000 :
                    accum[partial_slot][lane*16 +: 16]),
        .b         (partial_data[lane*16 +: 16]),
        .out_valid (add_valid[lane]),
        .y         (add_y[lane*16 +: 16])
      );
    end
    for (lane = 0; lane < ACC_SLOTS; lane = lane + 1) begin : g_cooldown_active
      assign cooldown_active[lane] = |cooldown[lane];
    end
  endgenerate

  always_ff @(posedge state_gclk or negedge rst_n) begin
    if (!rst_n) begin
      result_valid <= 1'b0;
      result_slot  <= '0;
      result_data  <= '0;

      for (i = 0; i < ACC_SLOTS; i = i + 1) begin
        accum[i] <= '0;
        cooldown[i] <= '0;
      end
      for (i = 0; i < 4; i = i + 1) begin
        slot_p[i] <= '0;
        last_p[i] <= 1'b0;
      end
    end else begin
      result_valid <= 1'b0;
      for (i = 0; i < ACC_SLOTS; i = i + 1)
        if (cooldown[i] != 0) cooldown[i] <= cooldown[i] - 1'b1;

      if (accept) begin
        cooldown[partial_slot] <= 3'd5;
        slot_p[0] <= partial_slot;
        last_p[0] <= partial_last;
      end
      for (i = 1; i < 4; i = i + 1) begin
        slot_p[i] <= slot_p[i-1];
        last_p[i] <= last_p[i-1];
      end

      // All lanes have the same valid because they share a command.  Keeping
      // the vector commit at this point makes the state buffer explicit and
      // maps cleanly to Base-Die registers in synthesis.
      if (add_valid[0]) begin
        accum[slot_p[3]] <= add_y;
        result_data <= add_y;
        if (last_p[3]) begin
          result_valid <= 1'b1;
          result_slot  <= slot_p[3];
        end
      end
    end
  end

endmodule
