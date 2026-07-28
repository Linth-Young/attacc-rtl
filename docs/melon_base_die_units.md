# MELON Base-Die Accumulation / Vector Unit

本目录新增的是对 `HPCA27_submission_ssc.pdf` 中 Base Die 两个模块的架构级 RTL 实现，不是作者原始 RTL。论文给出了模块职责和算术类别，没有给出端口、流水级数、指数近似或 Bank-group 大小；下述选择因此均为可替换的实现假设。

## Accumulation Unit

`rtl/melon_accumulation_unit.sv` 是一个伪通道共享的 16-lane FP16 部分和收集器。每条 `partial_*` 命令带一个 Bank PIM 的 16 元素部分 GEMV 向量；PIM controller 对同一输出 tile 保持 `partial_slot` 不变，首条置 `partial_clear`，末条置 `partial_last`。模块在最后一条的和写回时产生 `result_*`。

它实例化 16 个既有的四级 FP16 adder pipeline，而非固定为四 Bank 复制 48 个 adder 的并行树。四个 slot 允许独立 tile 交织；同一 slot 的安全重发间隔为五拍。adder、slot state 与 result/control 均在无工作时关闭时钟。这一设计对应论文“lightweight accumulation unit collects and reduces partial GEMV results”的职责，同时把具体每个 pseudo-channel 的 Bank 数留给控制器和封装拓扑。

当前版本恢复为已测功耗更低的 controller-clock-gated 基线：不在 FP16 adder 前加入 operand-isolation mux，也不额外派生结果寄存器时钟。每条返回的部分和写回 accumulator 和 `result_data`；下游只在 `result_valid` 时采样输出。该选择保持 lane 数、FP16 算术、slot 数、握手和延迟不变，并避免在高活动率主数据通路上增加组合逻辑。

## Vector Unit

`rtl/melon_vector_unit.sv` 实现 score tile 的 online-softmax 协议：FP16 比较树产生 `tile_max`，状态缓冲保存 `state_max` 与归一化和；输出逐 lane `weight_data`、给 Bank PIM 的 `bank_rescale`、`normalizer_recip`，并在状态提交时置位 `tile_ack`。`tile_last` 对应一个 sequence 的完成通知。

为满足 666 MHz，数据路径切成八拍：4 级 max tree、1 级 exp/旧状态缩放、3 级加法树与 state commit。只保存一份输入 tile；因 online softmax 的状态依赖，下一 tile 在 commit 后由 `tile_ready` 接收，固定延迟/安全 issue interval 都是 8 拍。所有在途寄存器由一个工作时钟门控，空闲时不翻转。

为控制面积，FP16 比较和 max state 是精确的，而 `exp` 与 `divide` 是可综合 Q4 近似：exp 值只取 `{1, .75, .5, .25, .125}`，归一化和保存为 Q4，倒数和 Q4-to-FP16 转换只保留指数。这是一个低面积协议/控制基线，不是数值等价的 IEEE-754 `exp/div`。若需要模型精度结论，应替换 `exp_q_approx`、`weight_to_fp16`、`q_to_fp16` 与 `recip_q_to_fp16`，然后用真实 attention trace 重新验证。

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

门级活动测试分别由 `tb/melon_accumulation_gate_activity_wrapper.sv` 与
`tb/melon_vector_gate_activity_wrapper.sv` 产生。前者以 `partial_ready` 为准发送 256 条
部分 GEMV 命令，轮换 slot 并执行 clear/accumulate/last；后者以 `tile_ready` 为准发送
128 个 online-softmax tile，保留 8 拍状态依赖。两者均使用有限、正规且随命令/lanes 变化的
FP16 数据，避免以全零/全一输入估计动态功耗。

## ASAP7 TC OpenROAD proxy PPA

约束均为 1.500 ns（666.7 MHz 目标），库为 ASAP7 TC，结果路径分别在 `reports/asap7/melon_accumulation_666mhz_gatedctrl/` 和 `reports/asap7/melon_vector_unit_666mhz_q4_pipe8_666m_r1/`。该 ORFS/ASAP7 flow 的 STA 单位为 ps，故 SDC 使用 `1500 ps` 周期、`50 ps` setup uncertainty 与 floorplan 阶段的 `0 ps` hold uncertainty；门控输出均声明为 generated clock。面积是标准单元 proxy，不是 1z-nm DRAM PDK 面积。

| 单元 | Synth logical area | Floorplan instance area | vectorless power | 门级 VCD dynamic proxy | timing 指标 |
| --- | ---: | ---: | ---: | ---: | --- |
| Accumulation Unit（controller clock-gated） | 2,974.44 µm² | 3,097.39 µm² | 13.799 mW | **14.501 mW**（5,594 pins） | setup/hold TNS=0；adder gated-domain fmax 749.76 MHz，setup slack 166.24 ps |
| Vector Unit（Q4，8-stage pipelined） | 780.55 µm² | 823.25 µm² | 1.365 mW | **1.504 mW**（2,269 pins） | setup/hold TNS=0；vector gated-domain fmax 1639.59 MHz，setup slack 890.09 ps |

新列由同一 mapped netlist 的 zero-delay functional gate simulation VCD 回标到已有 floorplan
ODB：Accumulation 为 internal `6.397662 mW`、switching `8.101760 mW`、leakage
`0.001721 mW`；Vector 为 internal `0.978613 mW`、switching `0.524618 mW`、leakage
`0.000662 mW`。日志均报告非零注释活动，因此不再是 vectorless 数字。

不过这仍是 666 MHz ASAP7 standard-cell **动态 proxy**，不能直接乘以 Bank 数得到系统功耗。
它没有 PIM SRAM/DRAM macro、封装/互连、外部结果消费者、CTS/布线寄生、IR/EM 或 1z-nm
DRAM PDK；gate-VCD 生成时的未观察输出锥也可能被 Yosys 优化。因此它比 vectorless 更接近
给定 RTL 工作负载，但仍不是 post-route/流片签核或论文系统级功耗。


复现：

```bash
podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_accumulation.mk floorplan

podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_vector_unit.mk floorplan
```

下一步是在 post-route/CTS 后以真实时钟树复核 hold，并用带实际 attention trace 和外部
结果消费者的 SAIF/VCD 复测；若需要更高 softmax 数值精度，再替换 Q4 exp/div 近似。
