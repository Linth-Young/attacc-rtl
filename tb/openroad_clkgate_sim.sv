`timescale 1ns/1ps
// Functional XSim model.  The OpenROAD flow replaces this module with the
// ASAP7 CLKGATE_MAP_FILE implementation and a physical ICG cell.
module OPENROAD_CLKGATE (
  input logic CK,
  input logic E,
  output logic GCK
);
  assign GCK = CK;
endmodule
