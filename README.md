# AttAcc Bank-level GemV RTL 复现

本仓库是对论文 [*AttAcc! Unleashing the Power of PIM for Batched Transformer-based Generative Model Inference*（ASPLOS 2024）](https://dl.acm.org/doi/10.1145/3620665.3640422) Section 5.1 中 **bank-level GemV unit** 的可综合 SystemVerilog 架构级复现。

它只实现一个 bank 内的 FP16 GemV 数据通路、向量双缓冲和流式命令控制，不包含论文中的 HBM3 命令控制器、bank-group/pseudo-channel accumulator、DRAM 时序、softmax 或完整 Transformer 推理系统。它不是论文作者发布的原始 RTL。

## 当前实现概览

| 项目 | 实现 |
| --- | --- |
| 计算精度 | binary16 / FP16；有限数 round-to-nearest-even，支持零 |
| 算术资源 | 16 个 2-stage FP16 multiplier，16 个 4-stage FP16 adder |
| 向量缓冲 | 2 个 bank，每 bank 16 个 256-bit word，共 8,192 bit |
| score 模式 | 16 路乘法后进行 8/4/2/1 reduction，再经 1 个 accumulator adder |
| context 模式 | 选取一个 FP16 vector lane 广播，完成 16 路独立 MAC |
| 流式吞吐 | 同一模式下、4 个 accumulator slot 轮转时可做到 II=1 |
| 时钟目标 | 1.500 ns（666.7 MHz） |
| 低功耗实现 | vector buffer 每个 word 与每个 accumulator slot 均采用写时钟门控 |

## 架构

```text
vector_buffer[2][16][256b]
          │
          ├── score：16 lane vector
          │
          └── context：选取一个 FP16 lane 并广播
                                      │
matrix_data[16 x FP16] ──> 16 x FP16 multiplier pipeline
                                      │
                         16 x FP16 products
                         ┌────────────┴────────────┐
                         │                         │
                  score / tree                context / broadcast
                  8/4/2/1 reduction          16 路独立累加
                  + tree accumulator          + lane accumulators
                         │                         │
                   tree_result                lane_results
```

score 模式将 16 个加法器固定分配给不同 reduction level：

```text
L1: 16 -> 8   : adder 0..7
L2:  8 -> 4   : adder 8..11
L3:  4 -> 2   : adder 12..13
L4:  2 -> 1   : adder 14
ACC: 1 + sum  : adder 15
```

因此多个 score 命令可以在不同 reduction level 重叠，而无需复制额外的加法器。context 模式需要全部 16 个加法器，故 score 与 context 的在途命令不可混发；切换模式前需等待另一模式流水排空。

## 目录

```text
rtl/
  attacc_gemv_unit.sv        # 顶层 GemV、双缓冲、时钟门控、流式控制
  attacc_fp16_operators.sv   # 2-stage multiplier、4-stage adder pipeline
  attacc_fp16_pkg.sv         # 组合 FP16 参考函数
tb/
  attacc_gemv_unit_tb.sv     # score/context/II=1 score stream 测试
  openroad_clkgate_sim.sv    # 仿真用 OPENROAD_CLKGATE 功能模型
  vcd_activity.py            # VCD 全局翻转率辅助统计
openroad/
  config.mk                  # ORFS ASAP7 配置
  constraint_666mhz.sdc      # 1.5 ns 时钟与 I/O 约束
  power_activity.tcl         # VCD 导入钩子
vivado/
  run_synth_666mhz.tcl       # UltraScale+ 时序代理流程
docs/
  attacc_gemv_rtl_handoff.md # 完整中文交接、PPA 与限制说明
```

## 顶层接口

顶层模块为 `attacc_gemv_unit`，默认参数为 `LANES=16`、`VECTOR_WORDS=16`、`ACC_SLOTS=4`。

### 向量缓冲

| 信号 | 含义 |
| --- | --- |
| `vector_wr_en` | 写使能；每次写一个 256-bit word |
| `vector_wr_buffer` | 目标双缓冲 bank（0/1） |
| `vector_wr_index` | word 编号（默认 0..15） |
| `vector_wr_data` | 16 个并行 FP16 数据 |
| `swap_vector_buffers` | 翻转 active bank |

写操作使用逐 word 时钟门控；在真实 PIM 中，该缓冲应映射为 SRAM/DRAM-local macro。本仓库中的 FF 实现仅用于功能与标准单元 proxy PPA。

### MAC 命令与结果

| 信号 | 含义 |
| --- | --- |
| `op_valid` / `op_ready` | ready/valid 命令握手 |
| `mode_tree` | `1`：score/tree reduction；`0`：context/broadcast |
| `op_clear_acc` | `1`：从零开始累加；`0`：读取保存的 partial sum |
| `op_vector_word` | active bank 内选择的 vector word |
| `op_broadcast_lane` | context 模式的广播 lane |
| `op_acc_slot` | 部分和上下文编号（默认 0..3） |
| `matrix_data` | 当前 PIM 行/列提供的 16 个 FP16 操作数 |
| `tree_result_valid` / `tree_result` | score 流式输出 |
| `lane_result_valid` / `lane_results` | context 的 16-lane 流式输出 |
| `result_acc_slot` | 当前结果对应的 accumulator slot |

连续命令需轮转 4 个 `op_acc_slot`。同一 slot 在前一条结果返回前会被 `op_ready` 阻塞，以避免 accumulator RAW hazard。最终加法器的结果前递使 4-slot 调度能够维持每周期一条命令。

## 功能仿真

测试平台覆盖：

- vector word 写入；
- score：`dot([1]*16, [1]*16) = 16.0`；
- context：`1.0 x [2.0]*16`；
- 24 条连续 score 命令、4-slot round-robin 的 II=1 流。

使用支持 SystemVerilog 的仿真器。以 Icarus Verilog 为例：

```bash
mkdir -p artifacts
iverilog -g2012 -s attacc_gemv_unit_tb -o /tmp/attacc_gemv_tb \
  tb/openroad_clkgate_sim.sv \
  rtl/attacc_fp16_pkg.sv rtl/attacc_fp16_operators.sv rtl/attacc_gemv_unit.sv \
  tb/attacc_gemv_unit_tb.sv
vvp /tmp/attacc_gemv_tb
```

Vivado 的静态编译/展开命令：

```bash
xvlog -sv tb/openroad_clkgate_sim.sv rtl/attacc_fp16_pkg.sv \
  rtl/attacc_fp16_operators.sv rtl/attacc_gemv_unit.sv tb/attacc_gemv_unit_tb.sv
xelab -top attacc_gemv_unit_tb -snapshot attacc_gemv_tb
```

## OpenROAD / ASAP7 PPA

本仓库使用 OpenROAD-flow-scripts（ORFS）`ASAP7 TC` 库作研究型标准单元 proxy。执行时请将本仓库置于 `/work/attacc-rtl` 或相应地修改挂载路径：

```bash
podman run --rm --userns=keep-id \
  -v "$PWD/..":/work -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest \
  make -f /OpenROAD-flow-scripts/flow/Makefile DESIGN_CONFIG=openroad/config.mk synth

podman run --rm --userns=keep-id \
  -v "$PWD/..":/work -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest \
  make -f /OpenROAD-flow-scripts/flow/Makefile DESIGN_CONFIG=openroad/config.mk floorplan
```

当前工作区记录的写时钟门控版本 `synth + floorplan` 结果：

| 指标 | 数值 | 备注 |
| --- | ---: | --- |
| Synth logical area | 9,106 µm² | ASAP7 标准单元 |
| Floorplan instance area | 9,223.53 µm² | 不含 placement 留白 |
| 论文 10x 密度惩罚缩放面积 | 0.0922353 mm² | 比论文 0.094 mm² 小约 1.88% |
| Floorplan fmax metric | 802.77 MHz | 非时序签核结论 |
| ORFS power proxy | 0.657587 W | 非真实 workload 功耗 |

**功耗与时序限制：**

1. 本仓库不随附活动 VCD；若 `artifacts/attacc_gemv_activity.vcd` 不存在，flow 会退化为 vectorless 默认活动率。当前 VCD 尚未正确映射到最新门控层级，OpenROAD 日志会显示 `Annotated 0 pin activities`。因此 0.657587 W 仅表明时钟门控的库级估算效果，不能作为论文或系统功耗。
2. 该 proxy 前，未门控 FF buffer 的相同 flow 曾得到约 8.97 W；逐 word 写时钟门控将其降至约 0.658 W。真实 macro-based PIM buffer 的功耗仍需 SRAM macro、门级 VCD/SAIF 与 post-route 提取验证。
3. floorplan 阶段仍有未修复 setup violation（`RSZ-0062`）；802.77 MHz 不能表述为已通过 666 MHz 签核。

## 与论文的关系与边界

本实现对齐论文 GemV 的 16 multiplier / 16 adder 资源和 score/context 数据流，但以下内容不在范围内：

- HBM3 PIM ISA 译码与 DRAM bank 调度；
- bank-group、pseudo-channel 级 accumulator；
- softmax、Transformer layer 调度和系统级性能模型；
- 1z-nm DRAM PDK、SRAM macro 与流片签核。

面积比较采用论文使用的 10x DRAM-logic density penalty，仅为研究估算。详见 [完整交接文档](docs/attacc_gemv_rtl_handoff.md)。

## 许可证

MIT License。论文及其商标、图表和实验数据的权利归原作者所有；本仓库仅提供独立的 RTL 架构级复现。
