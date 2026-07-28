# FP16 Arithmetic Microbenchmark: Add vs. Mul+Add

## Purpose

The full Bank GEMV and pseudo-channel Accumulation blocks cannot yet be compared
fairly with a complete gate-level VCD in the current execution environment: once
the GEMV context-mode 16-lane result cone is retained, Yosys gate simulation
exceeds the available resource limit. This microbenchmark instead compares the
common arithmetic primitives under the same conditions. It is a cross-check of
the expected ordering, **not** a replacement for full-unit or PIM-system PPA.

- `attacc_fp16_add_lane_unit`: one four-stage FP16 add pipeline, matching one
  Accumulation lane.
- `attacc_fp16_mac_lane_unit`: one two-stage FP16 multiply pipeline followed by
  the same four-stage FP16 add pipeline, matching the arithmetic core of one
  GEMV context lane. Two registered addend-delay stages align the addend with
  the multiplier output.

## Measurement setup

Both kernels use the identical finite-normal FP16 sequence, 256 accepted II=1
commands, 300 simulated cycles, a 1.500 ns clock, full top-level output
observation, and a mapped-netlist VCD annotated onto the kernel's own ASAP7 TC
floorplan ODB. The VCD reports 5,372 annotated pin activities for Add and 9,490
for Mul+Add. Energy is calculated over the complete 300-cycle window as
`P_avg × 300 × 1.5 ns / 256 accepted commands`.

| Arithmetic kernel | Synth area | Floorplan area | Gate-VCD power | Energy / accepted command | Relative to Add |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP16 Add (4-stage) | 137.752 µm² | 142 µm² | 0.203885 mW | 0.3584 pJ | 1.00× |
| FP16 Mul+Add (2+4-stage) | 252.001 µm² | 260 µm² | 0.325908 mW | 0.5729 pJ | 1.60× |

The Mul+Add kernel is 1.83× larger and consumes 1.60× the measured dynamic
power/energy of Add under this matched workload. This supports the architectural
expectation that, absent memory and controller effects, a GEMV context lane
(multiply plus add) costs more arithmetic energy than an Accumulation lane
(add only).

## Reproduction

```bash
podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_fp16_add_lane.mk floorplan

podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_fp16_mac_lane.mk floorplan
```

The activity wrappers, functional-cell generator, and OpenROAD report scripts
are in `tb/attacc_fp16_lane_gate_activity_wrappers.sv`, `tools/`, and
`openroad/report_fp16_{add,mac}_lane_activity.tcl`, respectively. Generated
VCDs stay under the ignored `artifacts/` directory.

## Boundaries

This is an ASAP7 TC standard-cell proxy only. It excludes the GEMV vector
buffer, slot scoreboards, pseudo-channel routing, PIM SRAM/DRAM macros,
HBM/DRAM command energy, CTS/route parasitics, and the 1z-nm DRAM process.
It establishes an arithmetic-core ordering, not a full AttAcc system power
number.
