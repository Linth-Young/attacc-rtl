# AttAcc RTL 分层能耗模型

## 目的

现有完整单元的 gate-VCD 功耗不能直接横向比较：GemV 的全 16-lane context
结果锥在本机 gate simulation 中超出资源限制，而 Accumulation 与 Vector 的
VCD workload、观察锥和发射间隔不同。本文件采用**同一 ASAP7 TC 库、同一
1.500 ns 时钟、有限正规 FP16 激励、mapped-netlist VCD**测得可组合的事件能量，
再由实际 trace 的事件计数计算模块能量：

\[
E_{\mathrm{workload}} = \sum_i N_i e_i + E_{\mathrm{ctrl}},\qquad
P_{\mathrm{avg}} = E_{\mathrm{workload}} / T_{\mathrm{trace}}.
\]

这里的 `E_ctrl` 必须由同一条完整 trace 的控制器活动得到；未测得它之前，下面
数字是“算术 + 本地 FF 状态”的标准单元 proxy，而不是完整芯片或系统功耗。

## 已测事件原语

所有能量都以完整仿真窗口的 `P_avg × T / accepted events` 计算；`mW × ns = pJ`。

| 事件原语 | 映射的 RTL 部件 | Synth / floorplan area | activity power | 采样窗口 | 事件能量 |
| --- | --- | ---: | ---: | --- | ---: |
| `e_add` | 1 个 4-stage FP16 adder pipeline | 137.752 / 142 µm² | 0.203885 mW | 300 cycles，256 次 II=1 add | 0.3584 pJ/add |
| `e_mac` | 1 个 2-stage FP16 multiplier + 相同 adder | 252.001 / 260 µm² | 0.325908 mW | 300 cycles，256 次 II=1 MAC | 0.5729 pJ/MAC |
| `e_vecwr` | 1 个 256-bit 写时钟门控寄存器 word | 116.057 / 127 µm² | 0.308050 mW | 300 cycles，256 次 word write | 0.5415 pJ/write |
| `e_psum` | 4×256-bit partial-sum state、cooldown、选择 mux 与 result register | 904.193 / 961 µm² | 0.728387 mW | 322 cycles，256 次 accepted update | 1.3743 pJ/update |

`e_add` / `e_mac` 的实现和结果见
[`fp16_arithmetic_microbench.md`](fp16_arithmetic_microbench.md)。后两个原语来自
`rtl/attacc_storage_power_microbench.sv`：它们沿用完整 RTL 的 `OPENROAD_CLKGATE`
写时钟门控；`e_psum` 还保留四 slot、五周期 recurrence spacing、state mux 与
cooldown。因此它比单一 256-bit 写入更接近 Accumulation 的本地状态开销。

VCD 分别注释了 2,307（vector word）和 26,813（pseudo-channel state）个 pin
activity。二者的 floorplan 面积是 standalone FF/logic proxy，不应与宏存储面积相加。

## 用 trace 计算完整工作负载

### Pseudo-channel Accumulation

一条 `partial_valid && partial_ready` 命令驱动 16 个 FP16 add lane，并更新一个
partial-sum slot。因此其已测数据路径下界为：

\[
e_{\mathrm{accum,partial}} \approx 16e_{\mathrm{add}} + e_{\mathrm{psum}}
= 16\times0.3584 + 1.3743 = 7.1087\ \mathrm{pJ}.
\]

若 trace 有 `N_partial` 条 accepted partial 命令，先计算
`E_accum,data = N_partial × 7.1087 pJ`，再加上 controller、输入/输出互连和
真实 PIM macro 的能量。该式没有把 `e_psum` 误当成 16 个独立写：它已经是一次
256-bit vector 状态更新的整体测量。

### Bank GemV context

一条 context 命令执行 16 个 MAC，并向其选中的 lane accumulator slot 写回一个
256-bit vector。vector word 的写入按照复用次数 `R` 分摊。使用最小的单 word 写
proxy，数据项为：

\[
e_{\mathrm{gemv,ctx,data}} \gtrsim 16e_{\mathrm{mac}} + e_{\mathrm{vecwr}}
+ e_{\mathrm{vecwr}}/R
= 9.7079 + 0.5415/R\ \mathrm{pJ}.
\]

若将四 slot state/mux/result 的较完整 proxy `e_psum` 用作 lane-accumulator 写回的
保守上界替代，式子变为 `10.5407 + 0.5415/R pJ`。两者之间的差是未分离的 slot
mux、metadata 与输出寄存器开销；不是 GemV 算术差异。

对每条 trace，应从命令流统计 `N_ctx`、`N_vecwr` 和每个 word 的复用次数，而非假定
`R=1`。对应的低阶估算为：

\[
E_{\mathrm{gemv,ctx}} \gtrsim N_{\mathrm{ctx}}(16e_{\mathrm{mac}}+e_{\mathrm{vecwr}})
+ N_{\mathrm{vecwr}}e_{\mathrm{vecwr}} + E_{\mathrm{ctrl}}.
\]

score/tree 模式还包含 `8+4+2+1+1=16` 个 add pipeline 使用、tree accumulator 与其
自己的 vector/slot 控制，必须按每个 reduction-stage 的实际 valid 事件单独计数，不能
套用 context 的 16-MAC 式。

## 结论与边界

在相同的 FP16 stream 下，`e_mac/e_add = 1.60×`。即使加入已测 local state，
context 数据路径在无 vector-word 复用（`R=1`）时约为 10.25–11.08 pJ；在 vector
word 高复用、仅保留每命令 accumulator 写回时则趋向 9.71–10.54 pJ。一个
pseudo-channel partial update 约为 7.11 pJ；这恢复了与架构相符的顺序：
**GemV context 的每命令算术 + 本地状态能量高于 Accumulation。**

这不推翻已有完整模块 VCD 报告中 Accumulation 的 14.501 mW 高于 GemV 的 3.620 mW：
两项采用不同 workload 和观察锥，后者还是 GemV 下界，故不可比较。分层模型只能用于
同一 trace 下按事件求和；要得到最终的完整模块功耗，仍需：

1. 用真实 GemV/Accumulation/Vector command trace 驱动各顶层，保留所有输出消费者；
2. 从完整 mapped netlist 生成 SAIF/VCD，并在 post-route、含 CTS/parasitics 的数据库回标；
3. 加入 SRAM/DRAM macro、HBM 互连和 1z-nm PIM/DRAM PDK 的 characterisation；
4. 对每一个单元报告 `E/command`、trace 时间和平均功耗，不把一个默认 activity `P_vec`
   乘以 Bank 数。

## 复现

```bash
podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_vecword_write_micro.mk floorplan

podman run --rm --userns=keep-id -v "$PWD":/work/attacc-rtl -w /work/attacc-rtl \
  docker.io/openroad/orfs:latest make -j1 -s -f /OpenROAD-flow-scripts/flow/Makefile \
  DESIGN_CONFIG=openroad/config_psum_state_micro.mk floorplan
```

随后用 `tools/generate_asap7_functional_models.py` 从 `1_2_yosys.v` 生成对应的
functional cells，以 `tb/attacc_storage_gate_activity_wrappers.sv` 做 zero-delay
gate simulation，`tools/normalize_gate_vcd.py` 整理层次，并执行
`openroad/report_{vecword_write,psum_state}_activity.tcl`。生成的 VCD 均在被 Git
忽略的 `artifacts/` 下。
