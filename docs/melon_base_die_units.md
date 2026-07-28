# MELON Base-Die Accumulation / Vector Unit

本目录新增的是对 `HPCA27_submission_ssc.pdf` 中 Base Die 两个模块的架构级 RTL 实现，不是作者原始 RTL。论文给出了模块职责和算术类别，没有给出端口、流水级数、指数近似或 Bank-group 大小；下述选择因此均为可替换的实现假设。

## Accumulation Unit

`rtl/melon_accumulation_unit.sv` 是一个伪通道共享的 16-lane FP16 部分和收集器。每条 `partial_*` 命令带一个 Bank PIM 的 16 元素部分 GEMV 向量；PIM controller 对同一输出 tile 保持 `partial_slot` 不变，首条置 `partial_clear`，末条置 `partial_last`。模块在最后一条的和写回时产生 `result_*`。

它实例化 16 个既有的四级 FP16 adder pipeline，而非固定为四 Bank 复制 48 个 adder 的并行树。四个 slot 允许独立 tile 交织；同一 slot 的安全重发间隔为五拍。adder、slot state 与 result/control 均在无工作时关闭时钟。这一设计对应论文“lightweight accumulation unit collects and reduces partial GEMV results”的职责，同时把具体每个 pseudo-channel 的 Bank 数留给控制器和封装拓扑。

当前版本恢复为已测功耗更低的 controller-clock-gated 基线：不在 FP16 adder 前加入 operand-isolation mux，也不额外派生结果寄存器时钟。每条返回的部分和写回 accumulator 和 `result_data`；下游只在 `result_valid` 时采样输出。该选择保持 lane 数、FP16 算术、slot 数、握手和延迟不变，并避免在高活动率主数据通路上增加组合逻辑。

## Vector Unit

`rtl/melon_vector_unit.sv` 实现论文所述的 FP16 Vector Unit：FP16 比较树产生 `tile_max`，带 tag 的 state table 保存每个 head 的 `state_max/state_sum`，并输出逐 lane 的未归一化 `weight_data`、给 Pseudo-channel Accumulation 的 `bank_rescale` 与最终归一化所需的 `normalizer_recip`。`tile_head_id` 选择状态表项，`tile_state_reset` 仅开始该 head 的新序列，`state_reset` 是 legacy/global clear；`tile_ack` 仅在状态写回后置位，`tile_last` 对应 sequence 完成通知。

由于论文未给出 exponent/divider/sigmoid 的内部近似公式，本实现以 FP16 输入/输出的单调 LUT 实现 `exp`、reciprocal 和 sigmoid；`state_sum`、加法、乘法及所有接口均为 binary16，**不再含 Q4 状态或 Q4-to-FP16 转换**。若拿到工艺库的 FP16 transcendental macro，可只替换三个 LUT 函数而不改变端口与 online-softmax 协议。

按 tile 宽度实现并行数据通路：16 个 FP16 delta adder、16 个 FP16 `exp` pipeline、8/4/2/1 FP16 reduction tree、16 个 FP16 reciprocal/divider pipeline、16 个 FP16 sigmoid pipeline，以及 16 个 FP16 elementwise multiplier。Softmax 保持论文 online recurrence：`weight_data=exp(score-next_max)`，而旧 partial sum 由 `bank_rescale=exp(old_max-next_max)` 重标定；不把中间 tile 错当作最终已归一化权重。默认 `HEADS=32`，但论文未公开固定 head 数，集成时必须按实际模型覆盖参数。

当前控制器是跨-head tagged pipeline：`head_id` 同时作为在途 slot/tag，不为每个 head 复制 FP16 阵列；不同 head 的 tile 可连续逐拍接收，`weight_head_id` 和 `ack_head_id` 标记流式权重与最终状态提交。同一 head 在 recurrence 提交前由 `head_busy` 阻塞，以保持 `state_max/state_sum` 的 RAW 依赖；若下一 tile 恰在上一 tile 提交周期到达，则由 commit-to-issue forwarding 同拍接收。32 个 head 足以覆盖当前约 32 拍 recurrence 延迟，从而在轮转 workload 中达到 softmax tile `II=1`。每个 state entry 有独立写时钟门控，score/tag 对齐寄存器与输出控制另有粗粒度 idle 门控。activation 命令支持并行 ReLU 和 SiLU，后者在 16 个 sigmoid/multiplier lane 上完成；activation 与 stateful softmax 流互斥。

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

`tb/melon_vector_unit_tb.sv` 先检查 4 个不同 head 在 4 个连续周期被接受，并按 `weight_head_id/ack_head_id` 顺序返回；随后覆盖独立 FP16 online-softmax state（每头首 tile `sum=16.0`，重访后为 `sum=32.0`、reciprocal=`1/32`）和 ReLU 的负值截断/正值直通。FP16 Vector 及三个 gate-activity wrapper 已通过本机 Vivado `xvlog` 静态编译，testbench 通过 `xelab` elaboration；XSim 在同一环境的 Tcl 启动阶段异常退出，因此动态 RTL testbench 结果仍不标为通过。另一路 ORFS Slang/Yosys 综合已成功，最终 mapped-netlist VCD 中 128 个 tile 均被接收，ack tag 以 32-head 周期连续推进。

门级活动测试分别由 `tb/melon_accumulation_gate_activity_wrapper.sv` 与
`tb/melon_vector_gate_activity_wrapper.sv` 可产生 Vector 的 online-softmax 流；前者以
`partial_ready` 为准发送 256 条部分 GEMV 命令，轮换 slot 并执行 clear/accumulate/last。
旧 Q4 Vector 和 r8 单发射 VCD 不再适用；当前 wrapper 以 32 个 head round-robin，在
`tile_ready` 允许时连续发射 128 个 tile，覆盖流水填充、稳态 II=1 和排空。激励使用随 lane/命令变化的有限、正规
FP16 数据，避免全零/全一输入估计动态功耗。

## ASAP7 TC OpenROAD proxy PPA

约束均为 1.500 ns（666.7 MHz 目标），库为 ASAP7 TC，结果路径分别在 `reports/asap7/melon_accumulation_666mhz_gatedctrl/` 和 `reports/asap7/melon_vector_unit_666mhz_fp16parallel_r9_headpipe/`。Vector 的完整并行阵列使用 ORFS 分层综合，避免将 100 个以上的算术 pipeline 展开成单个 ABC 网络；映射后的实例数和面积仍逐个保留。该 ORFS/ASAP7 flow 的 STA 单位为 ps，故 SDC 使用 `1500 ps` 周期、`50 ps` setup uncertainty 与 floorplan 阶段的 `0 ps` hold uncertainty；门控输出均声明为 generated clock。面积是标准单元 proxy，不是 1z-nm DRAM PDK 面积。

| 单元 | Synth logical area | Floorplan instance area | `E_instr`（pJ） | timing 指标 |
| --- | ---: | ---: | ---: | --- |
| Accumulation Unit（controller clock-gated） | 2,974.44 µm² | 3,097.39 µm² | 7.11 / accepted partial update‡ | setup/hold TNS=0；adder gated-domain fmax 749.76 MHz，setup slack 166.24 ps |
| Vector Unit（16-lane FP16，32-head tagged II=1 pipeline） | 10,153.25 µm² | 10,598 µm² | 34.23 / softmax tile | setup TNS=0；vector gated-domain fmax 1,013.04 MHz，setup slack 512.87 ps |

‡ Accumulation 的 7.11 pJ 来自已测 `16×e_add + e_psum` 事件模型；旧 VCD 平均功耗不再作为
模块间比较列。旧 Vector 的 `1.504 mW` 是已删除 Q4 设计的结果，不能用于当前 FP16 RTL；当前
`0.561 mW` 仅为旧 r6 ORFS vectorless proxy。下述 r9 softmax 能量来自跨-head II=1
gate-VCD；它仍不能解释为真实 DRAM/PIM 系统能耗，也不能与旧串行版直接作能效结论。

不过这仍是 666 MHz ASAP7 standard-cell **动态 proxy**，不能直接乘以 Bank 数得到系统功耗。
它没有 PIM SRAM/DRAM macro、封装/互连、外部结果消费者、CTS/布线寄生、IR/EM 或 1z-nm
DRAM PDK；gate-VCD 生成时的未观察输出锥也可能被 Yosys 优化。因此它比 vectorless 更接近
给定 RTL 工作负载，但仍不是 post-route/流片签核或论文系统级功耗。

## Vector Unit 门级 workload 能耗（r9 跨-head流水）

对 `results/asap7/melon_vector_unit_666mhz_fp16parallel_r9_headpipe/base/1_2_yosys.v` 生成零延迟
ASAP7 功能模型，以同一 mapped netlist 进行 Yosys 门级功能仿真；VCD 经
`tools/normalize_gate_vcd.py` 规范到 `melon_vector_unit` 根层级后，由 OpenSTA 读取
`2_1_floorplan.odb` 报告功耗。active/idle VCD 均注释 **111,084** 个 pin activity。时钟为 1.5 ns，
功耗来自 ASAP7 Liberty，因而是 workload-specific standard-cell proxy，而不是 silicon
signoff。

| 工作负载 | 时窗 / 完成指令数 | 含基线 `E_instr` | 空闲扣除后增量 `E_instr` |
| --- | --- | ---: | ---: |
| 32-head round-robin online-softmax | 288.002 ns / 128 tile | **34.91 pJ/tile** | **34.23 pJ/tile** |

active VCD 平均功耗为 `15.51548 mW`，匹配的 idle VCD 为 `0.303787 mW`；idle 仅用于扣除空闲基线，不作为表格比较量。
“含基线能量”按 `P_active × window / completed_instruction_count` 计算，包含该模块在实际
握手间隔内的时钟和 leakage；“增量能量”按 `(P_active − P_idle) × window / count` 计算。
softmax 激励为连续、有限正规 FP16 score tile；前 32 条分别初始化各 head，后续 tile 走各自 online state rescale。r8 的 SiLU/ReLU 数值属于旧 mapped netlist，未混入当前 r9 汇总表。这些数值不含 PIM/DRAM macro、Base-Die SRAM、Bank
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
