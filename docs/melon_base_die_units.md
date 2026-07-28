# MELON Base-Die Accumulation / Vector Unit

本目录新增的是对 `HPCA27_submission_ssc.pdf` 中 Base Die 两个模块的架构级 RTL 实现，不是作者原始 RTL。论文给出了模块职责和算术类别，没有给出端口、流水级数、指数近似或 Bank-group 大小；下述选择因此均为可替换的实现假设。

## Accumulation Unit

`rtl/melon_accumulation_unit.sv` 是一个伪通道共享的 16-lane FP16 部分和收集器。每条 `partial_*` 命令带一个 Bank PIM 的 16 元素部分 GEMV 向量；PIM controller 对同一输出 tile 保持 `partial_slot` 不变，首条置 `partial_clear`，末条置 `partial_last`。模块在最后一条的和写回时产生 `result_*`。

它实例化 16 个既有的四级 FP16 adder pipeline，而非固定为四 Bank 复制 48 个 adder 的并行树。四个 slot 允许独立 tile 交织；同一 slot 的安全重发间隔为五拍。adder、slot state 与 result/control 均在无工作时关闭时钟。这一设计对应论文“lightweight accumulation unit collects and reduces partial GEMV results”的职责，同时把具体每个 pseudo-channel 的 Bank 数留给控制器和封装拓扑。

当前版本恢复为已测功耗更低的 controller-clock-gated 基线：不在 FP16 adder 前加入 operand-isolation mux，也不额外派生结果寄存器时钟。每条返回的部分和写回 accumulator 和 `result_data`；下游只在 `result_valid` 时采样输出。该选择保持 lane 数、FP16 算术、slot 数、握手和延迟不变，并避免在高活动率主数据通路上增加组合逻辑。

## Vector Unit

`rtl/melon_vector_unit.sv` 实现论文所述的 FP16 Vector Unit：FP16 比较树产生 `tile_max`，FP16 state buffer 保存 `state_max/state_sum`，并输出逐 lane 的未归一化 `weight_data`、给 Pseudo-channel Accumulation 的 `bank_rescale` 与最终归一化所需的 `normalizer_recip`。`tile_ack` 仅在状态写回后置位，`tile_last` 对应 sequence 完成通知。

由于论文未给出 exponent/divider/sigmoid 的内部近似公式，本实现以 FP16 输入/输出的单调 LUT 实现 `exp`、reciprocal 和 sigmoid；`state_sum`、加法、乘法及所有接口均为 binary16，**不再含 Q4 状态或 Q4-to-FP16 转换**。若拿到工艺库的 FP16 transcendental macro，可只替换三个 LUT 函数而不改变端口与 online-softmax 协议。

按 tile 宽度实现并行数据通路：16 个 FP16 delta adder、16 个 FP16 `exp` pipeline、8/4/2/1 FP16 reduction tree、16 个 FP16 reciprocal/divider pipeline、16 个 FP16 sigmoid pipeline，以及 16 个 FP16 elementwise multiplier。Softmax 保持论文 online recurrence：`weight_data=exp(score-next_max)`，而旧 partial sum 由 `bank_rescale=exp(old_max-next_max)` 重标定；不把中间 tile 错当作最终已归一化权重。所有算术级都有寄存器边界。新增 activation 命令支持并行 ReLU 和 SiLU，后者在 16 个 sigmoid/multiplier lane 上完成。

FP16 `exp`、reciprocal 与 sigmoid 是二级流水、单调 LUT 近似；论文没有公开其宏单元或多项式。softmax 专用加法树使用有限正规 binary16 的轻量四级流水实现（不处理 NaN/Inf/denormal，采用截断），以使完整 16-lane 阵列能在 1.5 ns 约束下综合；GEMV 仍使用原有 RNE FP16 adder。故本 RTL 是**论文的并行资源与数据流复现**，但不应声称与作者未公开的 transcendental macro 或 IEEE special-value 处理逐位相同。

## 验证

两顶层均用 Vivado 2022.2 的 `xvlog` 和 `xelab` 做过静态编译与 elaboration：

```bash
xvlog -sv tb/openroad_clkgate_sim.sv rtl/attacc_fp16_pkg.sv \
  rtl/attacc_fp16_operators.sv rtl/melon_accumulation_unit.sv
xelab -top melon_accumulation_unit

xvlog -sv rtl/melon_vector_unit.sv
xelab -top melon_vector_unit
```

`tb/melon_accumulation_unit_tb.sv` 额外覆盖两个 slot 连续完成，以及同一 slot 的 FP16 `1.0 + 2.0 = 3.0`。本机 Vivado 对该 testbench 的 `xvlog/xelab` 已通过；XSim 在启动 Tcl 阶段出现环境异常、未进入仿真，因而不将其标记为动态仿真通过。

`tb/melon_vector_unit_tb.sv` 覆盖全零 score tile 的 FP16 online-softmax state（`sum=16.0`、reciprocal=`1/16`）和 ReLU 的负值截断/正值直通。FP16 Vector 及其 gate-activity wrapper 已通过本机 Vivado `xvlog` 静态编译；XSim 在同一环境的 Tcl 启动阶段异常退出，因此动态 testbench 结果同样不标为通过。

门级活动测试分别由 `tb/melon_accumulation_gate_activity_wrapper.sv` 与
`tb/melon_vector_gate_activity_wrapper.sv` 可产生 Vector 的 online-softmax 流；前者以
`partial_ready` 为准发送 256 条部分 GEMV 命令，轮换 slot 并执行 clear/accumulate/last。
旧 Q4 Vector 的 128-tile VCD 不再适用；当前并行 FP16 Vector 必须按 online-state 的 `tile_ready`
间隔并加入 ReLU/SiLU command trace 后重新采样。激励均使用随 lane/命令变化的有限、正规
FP16 数据，避免全零/全一输入估计动态功耗。

## ASAP7 TC OpenROAD proxy PPA

约束均为 1.500 ns（666.7 MHz 目标），库为 ASAP7 TC，结果路径分别在 `reports/asap7/melon_accumulation_666mhz_gatedctrl/` 和 `reports/asap7/melon_vector_unit_666mhz_fp16parallel_r6/`。Vector 的完整并行阵列使用 ORFS 分层综合，避免将 100 个以上的算术 pipeline 展开成单个 ABC 网络；映射后的实例数和面积仍逐个保留。该 ORFS/ASAP7 flow 的 STA 单位为 ps，故 SDC 使用 `1500 ps` 周期、`50 ps` setup uncertainty 与 floorplan 阶段的 `0 ps` hold uncertainty；门控输出均声明为 generated clock。面积是标准单元 proxy，不是 1z-nm DRAM PDK 面积。

| 单元 | Synth logical area | Floorplan instance area | `E_instr`（pJ） | timing 指标 |
| --- | ---: | ---: | ---: | --- |
| Accumulation Unit（controller clock-gated） | 2,974.44 µm² | 3,097.39 µm² | 7.11 / accepted partial update‡ | setup/hold TNS=0；adder gated-domain fmax 749.76 MHz，setup slack 166.24 ps |
| Vector Unit（16-lane FP16 softmax + ReLU/SiLU，并行） | 7,906.98 µm² | 7,911 µm² | 129.28 / softmax tile；32.81 / SiLU vector；2.34 / ReLU vector | setup/hold TNS=0；vector gated-domain fmax 1,228.20 MHz，setup slack 685.80 ps |

‡ Accumulation 的 7.11 pJ 来自已测 `16×e_add + e_psum` 事件模型；旧 VCD 平均功耗不再作为
模块间比较列。旧 Vector 的 `1.504 mW` 是已删除 Q4 设计的结果，不能用于当前 FP16 RTL；当前
`0.561 mW` 仅为 ORFS vectorless proxy。r6 已补充下述 softmax、SiLU 与 ReLU gate-VCD
workload 测量；这些能量仍不能解释为真实 DRAM/PIM 系统能耗或与旧串行版直接作能效结论。

不过这仍是 666 MHz ASAP7 standard-cell **动态 proxy**，不能直接乘以 Bank 数得到系统功耗。
它没有 PIM SRAM/DRAM macro、封装/互连、外部结果消费者、CTS/布线寄生、IR/EM 或 1z-nm
DRAM PDK；gate-VCD 生成时的未观察输出锥也可能被 Yosys 优化。因此它比 vectorless 更接近
给定 RTL 工作负载，但仍不是 post-route/流片签核或论文系统级功耗。

## Vector Unit 门级 workload 能耗（r6 并行版本）

对 `results/asap7/melon_vector_unit_666mhz_fp16parallel_r6/base/1_2_yosys.v` 生成零延迟
ASAP7 功能模型，以同一 mapped netlist 进行 Yosys 门级功能仿真；VCD 经
`tools/normalize_gate_vcd.py` 规范到 `melon_vector_unit` 根层级后，由 OpenSTA 读取
`2_1_floorplan.odb` 报告功耗。每个 VCD 都注释了 **50,241** 个 pin activity。时钟为 1.5 ns，
功耗来自 ASAP7 Liberty，因而是 workload-specific standard-cell proxy，而不是 silicon
signoff。

| 工作负载 | 时窗 / 完成指令数 | 含基线 `E_instr` | 空闲扣除后增量 `E_instr` |
| --- | --- | ---: | ---: |
| online-softmax tile | 240 ns / 4 tile | **141.33 pJ/tile** | **129.28 pJ/tile** |
| SiLU activation vector（16 FP16） | 120 ns / 12 vector | **34.82 pJ/vector** | **32.81 pJ/vector** |
| ReLU activation vector（16 FP16） | 120 ns / 40 vector | **2.94 pJ/vector** | **2.34 pJ/vector** |

匹配的 idle VCD 平均功耗为 `0.200988 mW`，仅用于扣除空闲基线，不再作为表格比较量。
“含基线能量”按 `P_active × window / completed_instruction_count` 计算，包含该模块在实际
握手间隔内的时钟和 leakage；“增量能量”按 `(P_active − P_idle) × window / count` 计算。
softmax 激励为连续、有限正规 FP16 score tile，第二及后续 tile 会走 online state rescale；SiLU
激励包含正负值，ReLU 使用同一输入分布。这些数值不含 PIM/DRAM macro、Base-Die SRAM、Bank
侧 GEMV、封装/互连、CTS/route 寄生或真实 1z-nm PDK，不能相加外推为整个 AttAcc/MELON 系统功耗。

可复现入口为 `tb/melon_vector_gate_activity_wrapper.sv`、
`tb/melon_vector_activation_gate_activity_wrapper.sv`、
`tb/melon_vector_idle_gate_activity_wrapper.sv` 和
`openroad/report_vector_vcd.tcl`；生成的 VCD 和功能 cell model 均在 `.gitignore` 的
`artifacts/` 下。


复现：

```bash
podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_accumulation.mk floorplan

podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_vector_unit.mk floorplan
```

下一步是在 post-route/CTS 后以真实时钟树复核 hold，并以真实 attention trace、外部结果消费者
和更长序列的 SAIF/VCD 扩展该 workload 测量；若有目标库的 math macro，再替换 FP16 LUT math 单元。
