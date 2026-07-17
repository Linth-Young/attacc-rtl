# AttAcc GemV RTL 交接文档

## 1. 文档目的与结论

本文说明本仓库 `rtl/` 下当前可综合 GemV 单元的实现、验证和
PPA 口径，供后续维护者继续实现或重构。

当前设计是对 AttAcc ASPLOS 2024 论文 Section 5.1 bank-level GemV unit 的
**架构级 RTL 重建**：资源数对齐为 16 个 FP16 multiplier 和 16 个 FP16
adder，支持 score 与 context 两类 MAC。但它不是论文作者的原始 RTL，亦
不是修改 HBM3 控制器、bank-group accumulator 或 softmax 的替代品。

当前默认实现的关键状态如下：

| 项目 | 当前值/结论 |
| --- | --- |
| 数据类型 | binary16/FP16；有限数 RNE，包含零 |
| NaN/Inf | 默认关闭传播，以面积优化；算术模块保留 `IEEE_SPECIALS` 参数 |
| 算术资源 | 16 个 2-stage multiplier + 16 个 4-stage adder |
| 向量缓冲 | 两个 `16 x 256-bit` RTL 寄存器 bank，共 8,192 bit；每 word 写时钟门控 |
| 命令接口 | 流式 ready/valid；同一 mode、不同 accumulator slot 可 II=1 |
| 累加上下文 | 默认 4 个 `ACC_SLOTS`；4-cycle slot cooldown + 同周期结果前递 |
| 时钟约束 | 1.500 ns，50 ps uncertainty（666.7 MHz 目标） |
| 当前流式版本 PPA | 9,223.53 um2 floorplan instance area；802.77 MHz fmax metric |
| 当前流式版论文缩放面积 | 0.0922353 mm2；低于论文 0.094 mm2 |

面积的最后一行仅是与论文相同的**有效逻辑/缓冲面积缩放估算**。它不是
1z-nm foundry signoff，也不应使用 60% 利用率 core 的留白面积与论文的单元
active-area 直接比较。

## 2. 目录与文件职责

| 文件 | 职责 |
| --- | --- |
| `rtl/attacc_gemv_unit.sv` | 顶层 GemV、逐 word 写时钟门控双缓冲、4-slot 前递流式上下文与 16x16 datapath 连接 |
| `rtl/attacc_fp16_operators.sv` | 组合参考算术模块，以及当前 PPA 使用的流水乘法/加法模块 |
| `rtl/attacc_fp16_pkg.sv` | 完整 IEEE-style 组合 reference function，供 `attacc_fp16_mul/add` 使用 |
| `tb/attacc_gemv_unit_tb.sv` | score 与 context 的最小功能 testbench，并生成 VCD |
| `tb/openroad_clkgate_sim.sv` | 仿真用 `OPENROAD_CLKGATE` shim；直接透传时钟 |
| `openroad/config.mk` | ASAP7/OpenROAD 配置、标准单元选择和面积优化设置 |
| `openroad/constraint_666mhz.sdc` | 1.5 ns 时钟与 I/O 约束 |
| `vivado/run_synth_666mhz.tcl` | UltraScale+ 代理时序流程；不是 DRAM-die 面积依据 |
| `openroad/README.md` | PPA 复现与面积缩放的简版说明 |

## 3. 顶层接口与协议

顶层模块为 `attacc_gemv_unit`，默认参数 `LANES=16`、`VECTOR_WORDS=16`、
`ACC_SLOTS=4`。

### 3.1 时钟与复位

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `clk` | 输入 | GemV 时钟；PPA 约束为 1.500 ns |
| `rst_n` | 输入 | 异步低有效复位。清空控制 metadata 和 active bank；累加器需以 `op_clear_acc=1` 初始化 |

### 3.2 向量双缓冲接口

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `vector_wr_en` | 输入 | 高电平时写入一个 256-bit 向量 word |
| `vector_wr_buffer` | 输入 | 目标 bank：0 或 1 |
| `vector_wr_index` | 输入 | word index，默认 4 bit，范围 0..15 |
| `vector_wr_data` | 输入 | 16 个并排 FP16，即 `[255:0]` |
| `swap_vector_buffers` | 输入 | 高电平时翻转 `active_buffer` |

实现为 `vector_buffer[0:1][0:15]`。读路径是组合读：
`selected_vector = vector_buffer[active_buffer][op_vector_word]`。
因此外部应在发出 MAC 前完成写入，且避免对当前 active bank 写入与读出之间
存在未定义的同周期冲突。

### 3.3 MAC 命令接口

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `op_valid` | 输入 | 命令有效；只应在 `op_ready=1` 时发出 |
| `op_ready` | 输出 | 当前 mode 没有与对侧 mode 冲突、且 `op_acc_slot` 空闲时为 1 |
| `mode_tree` | 输入 | 1：score/tree reduction；0：context/broadcast |
| `op_clear_acc` | 输入 | 1：本命令从零开始累加；0：使用已保存 accumulator |
| `op_vector_word` | 输入 | 从 active vector bank 选择 word |
| `op_broadcast_lane` | 输入 | context 模式下选取一个 FP16 向量 lane |
| `op_acc_slot` | 输入 | 部分和上下文编号，默认 2 bit，合法值 0..3；流式命令应轮转不同 slot |
| `matrix_data` | 输入 | 16 个并排 FP16，作为当前 DRAM 行/列操作数 |

在同一种 mode 内，`op_valid && op_ready` 可连续每个时钟采样一次。score 和
context 不在同一批在途请求中混发：切换 mode 前须让另一侧流水排空。对同一个
`op_acc_slot`，同一 slot 需间隔至少 4 个命令时钟。score/context 在最终 adder
输入处对同 slot 的上一个结果前递，因此 4 个 round-robin slot 即可支持持续 II=1。

### 3.4 结果接口

| 信号 | 方向 | 含义 |
| --- | --- | --- |
| `tree_result_valid` | 输出 | score 最终 adder 的流式 valid，结果同周期有效 |
| `tree_result` | 输出 | score accumulator 更新后的一个 FP16 值 |
| `lane_result_valid` | 输出 | context 最终 adder的流式 valid，结果同周期有效 |
| `lane_results` | 输出 | 16 个 FP16 context accumulator 更新结果 |
| `result_acc_slot` | 输出 | 当前 result 对应的 accumulator slot |

结果总线在 `*_result_valid` 后保持最近结果，但有效语义由 valid pulse 决定。

## 4. 数据通路

### 4.1 总体结构

```text
                        vector_buffer[2][16][256b]
                                  |
                   selected vector word (16 x FP16)
                                  |
       score: lane-wise vector   |   context: one selected FP16 broadcast
                                  v
 matrix_data (16 x FP16) --> 16 x FP16 multiplier pipeline
                                  |
                         16 x FP16 products
                                  |
             +--------------------+---------------------+
             |                                          |
     score/tree mode                           context mode
  8/4/2/1 reduction tree                  16 independent adds
  + one tree accumulator                  + 16 lane accumulators
             |                                          |
        tree_result                              lane_results
```

所有 16 个 multiplier 和 16 个 adder 都实例化在顶层 generate loop 中；没有
通过综合器的资源共享把它们折叠成更少的运算单元。为让 score 的多个命令同时处在
不同 reduction level，五个 stage 使用互不重叠的 adder 集合，恰好用满 16 个
adder；这保持论文的 16-adder 资源预算而非复制归约树。

### 4.2 Score/tree 模式：`mode_tree=1`

第 `g` 个 multiplier 计算：

`product[g] = vector[g] * matrix_data[g]`。

流式 reduction 映射如下：

```text
L1: 16 product -> 8 sums   (adder 0..7)
L2: 8 sums     -> 4 sums   (adder 8..11)
L3: 4 sums     -> 2 sums   (adder 12..13)
L4: 2 sums     -> 1 sum    (adder 14)
ACC: tree sum + tree_accumulator[slot] -> tree_result  (adder 15)
```

`op_clear_acc=1` 时 ACC 的第一个加数为 FP16 zero；否则使用保存的
`tree_accumulator[op_acc_slot]`。metadata 与每个算术 stage 一起移位，因此
流水填满后每周期可完成一个 score 结果；`result_acc_slot` 标示其归属。

### 4.3 Context/broadcast 模式：`mode_tree=0`

从 selected vector word 中读取：

`broadcast_value = selected_vector[op_broadcast_lane]`。

随后每一路执行：

`product[g] = broadcast_value * matrix_data[g]`

`lane_accumulator[slot][g] = (op_clear_acc ? 0 : lane_accumulator[slot][g]) + product[g]`

所有 16 个 adder 同时执行这一轮独立累加。context phase 使用全部 16 个 adder，
可在不同 slot 间每周期接收一条命令；它与 score phase 不混发，避免对同一组
物理 adder 的争用。

## 5. 流式控制与可见延迟

控制器不再使用单事务 FSM。命令 metadata（mode、clear、slot）先随 2-stage
multiplier 移位；score 再随 L1、L2、L3、L4 和 ACC 的五段 4-stage adder 移位。
每一段的输入仅依赖上段 valid，因此可在不同命令之间重叠。

典型可见延迟和启动间隔为：

| 命令 | 典型延迟 | 说明 |
| --- | ---: | --- |
| context | 约 6 clocks | 2-stage multiplier 后的一次 4-stage 16-lane add |
| score | 约 22 clocks | multiplier、4 层 reduction、最终 accumulator add |

这里的延迟是 RTL 边沿计数而非 ISA 时序承诺。稳定同-mode 流中，若每条命令使用
空闲 `op_acc_slot`，`op_ready` 可每周期为高，启动间隔为 **1 clock (1.5 ns)**。
同一 slot 的 RAW 相关由 busy bit 阻止；因而没有把错误的旧 FP16 部分和送入流水。

## 6. FP16 算术实现

### 6.1 PPA 使用的流水模块

`attacc_fp16_mul_pipe`：

1. 在 `in_valid` 时锁存符号、指数和 11-bit significand product；
2. 下一周期规范化、RNE rounding、饱和 overflow 或 flush underflow，并产生输出。

`attacc_fp16_add_pipe`：

1. 选择较大操作数、指数对齐并生成 sticky bit；
2. 做同号加或异号减；
3. 规格化；
4. RNE rounding/pack 并输出。

两个模块通过 `OPENROAD_CLKGATE` 仅在输入或流水 valid 仍存在时打开内部时钟。
OpenROAD 使用 ASAP7 ICG cell；仿真使用 `tb/openroad_clkgate_sim.sv` 中的
直通模型。

### 6.2 数值语义和取舍

顶层未显式传递参数，因此 multiplier/adder 的
`IEEE_SPECIALS` 默认值为 `0`：

- 支持有限 FP16，包括正负零；
- 正常有限结果使用 RNE；
- overflow 输出 infinity encoding；
- gradual-underflow 的结果 flush 为 signed zero；
- NaN/Inf 输入的传播不作为默认功能保证。

将 `IEEE_SPECIALS` 设为 `1` 可以保留异常值传播路径，但需同时修改顶层两个
实例化处，并重新进行 PPA；现有 `cellopt` 面积数据不适用于该配置。

`attacc_fp16_pkg.sv` 内的 `fp16_mul_rne` 和 `fp16_add_rne` 是功能更完整的组合
reference function，供组合 wrapper 使用；顶层 PPA datapath 实际使用的是上述
流水模块，不直接调用 package function。

## 7. 验证状态

`tb/attacc_gemv_unit_tb.sv` 包含三项定向测试：

1. score：`dot([1]*16, [1]*16) = 16.0`，预期 `16'h4c00`；
2. context：broadcast `1.0` 与 16 个 `2.0` 相乘，预期 16 个 `2.0`。
3. score stream：轮转 slot 0..3 连续 24 个时钟发射独立 dot-product，检查无
   `op_ready` stall 且收回 24 个 `16'h4c00` 结果。

最新 RTL 已通过 Vivado `xvlog` 与 `xelab` 的语法、静态 elaboration。可使用：

```bash
cd /path/to/attacc-rtl
mkdir -p artifacts/vivado_handoff_compile
cd artifacts/vivado_stream_compile
/mount/hdd0/yangfan/tools/Vivado2022.2/Vivado/2022.2/bin/xvlog -sv \
  ../../tb/openroad_clkgate_sim.sv \
  ../../rtl/attacc_fp16_pkg.sv ../../rtl/attacc_fp16_operators.sv \
  ../../rtl/attacc_gemv_unit.sv ../../tb/attacc_gemv_unit_tb.sv
/mount/hdd0/yangfan/tools/Vivado2022.2/Vivado/2022.2/bin/xelab -mt off \
  -top attacc_gemv_unit_tb -snapshot attacc_gemv_stream_compile
```

本机 Vivado 2022.2 在 `xsim -runall` 阶段曾报通用 Tcl runtime exception，未给出
RTL assertion/fatal 输出；因此它不能作为当前最终版本的动态功能 PASS 证据。应先
修复本机 XSim runtime，或安装 Icarus/Verilator 后重新跑此 testbench，并新增
随机有限 FP16 与连续累加的 reference-model regression。

## 8. PPA 与缩放口径

### 8.1 当前流式版本测量

当前 `attacc_gemv_666mhz_stream4fwd_streamout_wcg` 结果来自 ASAP7 `TC` corner、1.500 ns SDC、
OpenROAD `synth + floorplan`：

| 指标 | 数值 |
| --- | ---: |
| Synth logical area | 9,106 um2 |
| Floorplan standard-cell instance area | 9,223.53 um2 |
| 60% utilization core area | 15,125.29 um2 |
| Die area | 15,672.50 um2 |
| Floorplan fmax metric | 802.77 MHz |
| Floorplan total power | 0.657587 W（非签核 proxy） |

结果文件：

- `logs/asap7/attacc_gemv_666mhz_stream4fwd_streamout_wcg/base/2_1_floorplan.json`
- `reports/asap7/attacc_gemv_666mhz_stream4fwd_streamout_wcg/base/2_floorplan_final.rpt`
- `reports/asap7/attacc_gemv_666mhz_stream4fwd_streamout_wcg/base/synth_stat.txt`

RTL 已为每个 vector-buffer word 和每个 accumulator slot 增加写时钟门控；综合后的
ICG 数由 32 增至 72。相同 ORFS flow 的总功耗从 8.96546 W 降至 0.657587 W（-92.7%），
说明原先的 9 W 主要是 FF buffer 的无条件时钟功耗。

`power_activity.tcl` 导入的 VCD 仍没有与此候选正确映射（日志为 `Annotated 0 pin
activities`），且 VCD 是短、低吞吐、门控前 testbench 生成。因此 0.657587 W 只可作为
门控后的库功耗 proxy，**不是**可引用的 II=1 workload 动态功耗，禁止用于论文或系统
功耗外推。

门控前的独立零数据翻转检查（`set_power_activity -global -activity 0.0`，仍保留 666.7 MHz
时钟）报告 `8.50 W`：其中 sequential internal power 为 `8.14 W`、clock 为
`0.360 W`、leakage 仅 `4.62 uW`。综合统计有 `2,334` 个 reset FF、`9,280` 个普通
FF 和 `32` 个 ICG；仅双缓冲 vector buffer 就是 `2 x 16 x 256 = 8,192` bit 的 FF
存储。也就是说，接近 9 W 的根源是当前 RTL 把 buffer 综合成持续时钟的标准单元
触发器，而不是 16 个 MAC 的真实工作翻转。论文/真实 PIM 实现应将这部分作为
SRAM/DRAM-local buffer macro；在本地没有对应 macro 的前提下，不能把这个数与论文
GemV unit 功耗比较。

要得到可引用的 operating power，仍需同时完成：(1) 将 vector buffer 映射为带读写功耗
模型的 SRAM macro；(2) 修复 XSim 并导入覆盖 II=1 score/context 指令流的 gate-level
VCD/SAIF；(3) 在 placement/CTS/route 后重测。

虽然 JSON 给出 802.77 MHz 的 fmax metric，高层 floorplan STA 同时报告异常的
setup WNS/TNS 与 `RSZ-0062`（未修复所有 setup violation）。两者在该 ORFS
floorplan 流中不一致，因此只能说明该 metric 高于 666 MHz；**不能**据此宣称
666 MHz 时序已通过。必须完成可解释的 placement/CTS/route STA 后再作时序结论。

### 8.2 与论文面积的比较

论文报告 1z-nm DRAM process 下每个 GemV unit 为 `0.094 mm2`，并将逻辑面积按
DRAM process 的 10x density penalty 缩放。对当前流式 active cell area，公式为：

```text
0.00922353 mm2 (ASAP7 active standard-cell area) x 10
= 0.0922353 mm2 (1z-nm scaled estimate)
```

当前流式实现比 `0.094 mm2` 小约 **1.88%**，达到“缩放后小于论文面积”的目标。
主要手段是 4-slot round-robin 与最终 add 结果前递，避免 24-slot 部分和寄存器。
旧串行基线 `attacc_gemv_666mhz_cellopt` 的缩放面积为 0.0883538 mm2，可作为
面积优化比较对象。比较口径仍要求：

- 使用 active standard-cell area，而不是含 40% placement whitespace 的 core；
- 接受论文的 10x penalty 也适用于当前逻辑；
- 当前 RTL 以寄存器实现 vector buffer，尚无真实 1z-nm SRAM macro；
- ASAP7 和 1z-nm 都只是研究级 proxy，不是流片 PDK/签核数据。

### 8.3 复现命令

不要直接运行 ORFS 默认 `all` 目标。该流在本机曾使独立阶段并行启动；按阶段执行
可避免 Yosys netlist 与 OpenROAD 读取发生竞争：

```bash
cd /mount/hdd0/yangfan/PIM/attacc_simulator

podman run --rm --userns=keep-id \
  -v /mount/hdd0/yangfan/PIM:/work \
  -w /work/attacc_simulator docker.io/openroad/orfs:latest \
  make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config.mk synth

podman run --rm --userns=keep-id \
  -v /mount/hdd0/yangfan/PIM:/work \
  -w /work/attacc_simulator docker.io/openroad/orfs:latest \
  make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config.mk floorplan
```

`config.mk` 中的 `override export DONT_USE_CELLS = SDF* ICG*` 是当前面积结果的
必要条件：它允许 platform 默认禁用的 ASAP7 `xp/x1p` small-drive cells。复现时
不要删除该设置。

## 9. 已知限制与后续工作

按优先级建议后续工作如下：

1. **补齐动态功能回归。** 修复 XSim 或安装可用的 Icarus/Verilator；将
   `attacc_fp16_pkg` reference function 用作 finite-FP16 随机向量 checker。
2. **补齐流式随机回归。** 当前实现已加入多命令 pipeline、4-slot accumulator
   scoreboard 和 RAW busy bit；应覆盖同-slot backpressure、mode-drain、slot 回收及
   `op_clear_acc=0` 的随机有限 FP16 回归。
3. **替换 RTL 寄存器 buffer。** 接入有 Liberty/LEF 的双端口或两-bank SRAM macro；
   面积和功耗应计入最终 1z-nm 比较，不能简单 black-box 掉。
4. **功耗闭环。** 用与 netlist 层级匹配的持续 PIM command trace 重新生成 VCD/SAIF，
   再做 post-route clock tree 与寄生参数提取。
5. **时序签核。** 当前 `GPL_TIMING_DRIVEN=0`、`GPL_ROUTABILITY_DRIVEN=0`，仅是
   floorplan 估计；需要完整 placement/CTS/route、DRC 与真实 PVT corner。
6. **IEEE 特殊值决策。** 若上层可能输入 NaN/Inf，必须顶层显式打开
   `IEEE_SPECIALS`，重跑数值回归和 PPA；不可沿用本文件的面积结论。

## 10. 维护规则

- 修改 `rtl/` 后，必须分别做编译/elaboration、`synth` 和 `floorplan`；不要把
  `attacc_gemv_666mhz_cellopt` 的数值归因给 `attacc_gemv_666mhz_stream`。
- 每个 PPA 候选使用新的 `DESIGN_NICKNAME`，避免 ORFS 不跟踪 RTL timestamp 时误用
  旧 netlist。
- 任何报告中必须同时写明：工艺 proxy、corner、时钟、是否有限 FP16、是否包含 macro、
  使用的是 active area 还是 core footprint、以及 VCD 是否真实映射。
- 不要把本文的单元面积或默认活动率功耗直接乘以 HBM bank 数量；论文系统能耗还涉及
  HBM command、DRAM array、SRAM/accumulator 和调度行为。
