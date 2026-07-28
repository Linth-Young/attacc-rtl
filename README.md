# AttAcc Bank-level GemV RTL 复现

本仓库是对论文 [*AttAcc! Unleashing the Power of PIM for Batched Transformer-based Generative Model Inference*（ASPLOS 2024）](https://dl.acm.org/doi/10.1145/3620665.3640422) Section 5.1 中 **bank-level GemV unit** 的可综合 SystemVerilog 架构级复现。

它实现一个 bank 内的 FP16 GemV 数据通路、向量双缓冲和流式命令控制；另提供 HPCA 投稿稿件中 Base Die 的 Accumulation Unit 和轻量 online-softmax Vector Unit。它不包含 HBM3 命令控制器、DRAM 时序或完整 Transformer 推理系统，也不是论文作者发布的原始 RTL。

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
  melon_accumulation_unit.sv # pseudo-channel 16-lane partial-GEMV collector
  melon_vector_unit.sv       # Base-Die FP16 online-softmax + ReLU/SiLU Vector Unit
tb/
  attacc_gemv_unit_tb.sv     # score/context/II=1 score stream 测试
  melon_vector_unit_tb.sv    # FP16 softmax state 与 ReLU 功能测试
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
  melon_base_die_units.md    # Accumulation/Vector 接口、近似与独立 PPA
  fp16_arithmetic_microbench.md # 同 trace 的 FP16 Add vs. Mul+Add 功耗交叉验证
  hierarchical_energy_model.md  # 以 trace 事件计数计算模块能耗的分层模型
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
| Floorplan instance area | 9,210.74 µm² | 不含 placement 留白 |
| 论文 10x 密度惩罚缩放面积 | 0.0921074 mm² | 比论文 0.094 mm² 小约 2.01% |
| 门控域 period-min | 1312.68 ps（761.80 MHz） | 666 MHz target 下 setup slack 187.32 ps |
| ORFS vectorless power proxy | 5.177 mW | 非真实 workload 功耗 |
| 门级 VCD 动态功耗 proxy | 3.620 mW | 1024 条连续 score GEMV、有效 FP16 数据流、24,668 pin activities |

**功耗与时序限制：**

1. ORFS/ASAP7 STA 的时间单位为 ps，因此 666 MHz SDC 使用 `1500 ps` 周期、50 ps setup uncertainty 和门控 derived clocks。旧版把 `1.500` 误当作 ns，实际被解释为 1.5 ps，旧 PPA 数值不可再用于时序或功耗比较。
2. `5.177 mW` 是 vectorless 默认活动率，并非 workload 功耗。新增的 `3.620 mW` 来自与 ORFS 映射网表一致的 gate VCD：先写入 16 个 vector words，再以 II=1 发射 1024 条 score GEMV；输入是 16 组有限、正规 FP16 值而非全零/全一。OpenROAD 确认注释了 24,668 个 pin activities。由于该 gate-VCD 生成器的全内部、全结果观察版本超过本机内存限制，这个值仍是 standard-cell GEMV **动态 proxy/下界**，不含 PIM SRAM/DRAM、互连、输出消费者、CTS/route 寄生或真实 1z-nm 工艺。
3. 这也解释了为什么 VCD 数值可能低于 vectorless 数值：默认 activity 会对未注释网络施加统一翻转率，而本 workload 的实际位翻转受具体 FP16 数据分布与时钟门控限制；两者不能互相替代，也不能直接外推到数百个 Bank。
4. 该 floorplan proxy 已通过 setup（187.32 ps slack），但 hold 仍有 10.38 ps 缺口；它不是 post-route/CTS 签核结论。

### 表 I：单元级 PPA 汇总（HPCA 风格）

所有条目使用 ASAP7 TC 标准单元库和 1.500 ns（666.7 MHz）约束。面积为 `synth / floorplan`
实例面积；`P_vec` 是 ORFS vectorless power proxy。

| Unit | Function / configuration | Area (µm²) | Freq. target | `P_vec` (mW) | Timing proxy |
| --- | --- | ---: | ---: | ---: | --- |
| Bank GEMV | FP16, 16× mul, 16× add, 4 accumulator slots | 9,106 / 9,210.74 | 666.7 MHz | 5.177 | setup +187.32 ps; hold −10.38 ps† |
| Pseudo-channel Accumulation | FP16 16-lane collector, 4 slots, 4-stage add | 2,974.44 / 3,097.39 | 666.7 MHz | 13.799 | setup +166.24 ps; setup/hold TNS=0 |
| Base-Die Vector | FP16 softmax + ReLU/SiLU, time-multiplexed pipeline | 1,711.41 / 1,794 | 666.7 MHz | 3.930 | setup +5.80 ps; setup/hold TNS=0 |

† GEMV 的 floorplan hold 尚有 10.38 ps 缺口，不能表述为 post-route/CTS 时序签核通过。
所有 `P_vec` 均为工具默认活动率下的标准单元 proxy，不能直接相加、按 Bank 数外推或视为真实
1z-nm/系统级功耗。

### Base-Die 新增模块 PPA

下表是 `rtl/melon_accumulation_unit.sv` 与 `rtl/melon_vector_unit.sv` 的独立测量，使用同一
ASAP7 TC / 1.500 ns（666.7 MHz）约束。Accumulation 的 VCD 为 256 条遵守 `partial_ready` 的
部分 GEMV 命令；当前 FP16 Vector 尚未用完整 softmax + ReLU/SiLU trace 重采 VCD。所有动态
激励均应使用随 lane 和命令变化的有限、正规 FP16 输入，而非全零/全一激励。

| 模块 | 算术/流水实现 | Synth logical area | Floorplan instance area | vectorless power proxy | 门级 VCD dynamic proxy | 666 MHz 时序 proxy |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Accumulation Unit | 16-lane FP16 partial-GEMV collector；4 slot；4-stage FP16 add | 2,974.44 µm² | 3,097.39 µm² | 13.799 mW | **14.501 mW**（5,594 annotated pins） | setup/hold TNS=0；adder gated-domain fmax 749.76 MHz，setup slack 166.24 ps |
| Vector Unit | FP16 online-softmax + ReLU/SiLU；时分复用 FP16 add/mul pipeline | 1,711.41 µm² | 1,794 µm² | 3.930 mW | 尚未以新网表复测 | setup/hold TNS=0；vector gated-domain fmax 669.26 MHz，setup slack 5.80 ps |

Accumulation 的门级 VCD 功耗由 internal `6.398 mW`、switching `8.102 mW`、leakage
`0.002 mW` 组成。旧 Vector 的 `1.504 mW` 属于删除的 Q4 RTL，不能与当前 FP16 Vector
混用；当前 FP16 版本的 `3.930 mW` 是 vectorless proxy，仍需实际 softmax/activation trace
重测。所有这些数字均未包含 PIM memory macro、DRAM/封装互连、外部消费者、CTS/route 寄生或
真实 1z-nm DRAM PDK。

完整接口、工作负载和测量复现步骤见 [Base-Die 模块文档](docs/melon_base_die_units.md)。
对不同模块/工作负载如何计算可比的 `E/command` 与完整 trace 平均功耗，见
[分层能耗模型](docs/hierarchical_energy_model.md)。

## 与论文的关系与边界

本实现对齐论文 GemV 的 16 multiplier / 16 adder 资源和 score/context 数据流，但以下内容不在范围内：

- HBM3 PIM ISA 译码与 DRAM bank 调度；
- bank-group、pseudo-channel 级 accumulator；
- softmax、Transformer layer 调度和系统级性能模型；
- 1z-nm DRAM PDK、SRAM macro 与流片签核。

面积比较采用论文使用的 10x DRAM-logic density penalty，仅为研究估算。详见 [完整交接文档](docs/attacc_gemv_rtl_handoff.md)。

## 许可证

MIT License。论文及其商标、图表和实验数据的权利归原作者所有；本仓库仅提供独立的 RTL 架构级复现。
