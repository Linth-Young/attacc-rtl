# OpenROAD / ASAP7 PPA 说明

本目录提供 `attacc_gemv_unit` 的 ORFS（OpenROAD-flow-scripts）配置。目标时钟为
`1.500 ns`，即 666.7 MHz；工艺库为 ASAP7 `TC`。这是研究型标准单元 proxy，
不是 1z-nm DRAM 工艺、真实 SRAM macro 或流片签核。

从仓库根目录执行：

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

输出写入 `.gitignore` 排除的 `results/`、`reports/`、`logs/` 与 `objects/`。

当前记录的写时钟门控实现结果：

| 指标 | 数值 |
| --- | ---: |
| Synth logical area | 9,106 µm² |
| Floorplan instance area | 9,210.74 µm² |
| 论文 10x 缩放估计 | 0.0921074 mm² |
| 门控域 period-min | 761.80 MHz |
| Gate-VCD 能量 / issued score GEMV command | ≈6.10 pJ（含 16 次 vector setup write，下界） |

`power_activity.tcl` 仅在 `artifacts/attacc_gemv_activity.vcd` 存在时读取活动文件。
活动文件必须由与综合网表层级匹配的测试生成；若日志显示 `Annotated 0 pin activities`，
任何 power 数值都不可视作 workload 动态功耗。`0.657587 W` 是旧版错误 SDC
（将 1.500 误读为 ps）留下的无效数字，不应再引用。

当前 SDC 使用 `1500 ps` 周期，floorplan setup slack 为 187.32 ps；hold 仍有 10.38 ps
缺口，因此不是 post-route/CTS 时序签核。完整背景见 [`../docs/attacc_gemv_rtl_handoff.md`](../docs/attacc_gemv_rtl_handoff.md)。

## 门级 GEMV 活动功耗（2026-07-28）

`tb/attacc_gemv_gate_activity_wrapper.sv` 产生 16 次 vector 写入和 1024 条连续、II=1 的
score GEMV。所有 operand 都是有限正规 FP16 值，避免全零/全一的低翻转率偏差。
`tools/generate_asap7_functional_models.py` 从 ORFS 使用的 ASAP7 Liberty 提取零延迟功能模型，
Yosys 对 **同一份** `results/.../1_2_yosys.v` mapped netlist 产生 VCD；
`tools/normalize_gate_vcd.py` 将 Yosys flattened hierarchy 规范为 OpenSTA 可识别的根层次。

生成的 VCD 位于 `.gitignore` 排除的 `artifacts/`。可在 ORFS 容器中复现：

```bash
python3 tools/generate_asap7_functional_models.py \
  --netlist results/asap7/attacc_gemv_666mhz_sdcfix/base/1_2_yosys.v \
  --liberty-dir /OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM \
  --output artifacts/asap7_gate_functional_models.v

yosys -q -p 'read_verilog -sv artifacts/asap7_gate_functional_models.v; \
  read_verilog results/asap7/attacc_gemv_666mhz_sdcfix/base/1_2_yosys.v; \
  read_verilog -sv tb/attacc_gemv_gate_activity_wrapper.sv; \
  hierarchy -check -top attacc_gemv_gate_activity_wrapper; proc; flatten; opt; \
  sim -q -clock clk -resetn rst_n -rstlen 2 -n 1150 -width 1500 -timescale 1ps \
  -hdlname -a -vcd artifacts/attacc_gemv_gate_steady.vcd'
python3 tools/normalize_gate_vcd.py \
  artifacts/attacc_gemv_gate_steady.vcd artifacts/attacc_gemv_gate_steady_orfs.vcd
openroad -no_init -exit openroad/report_gemv_gate_activity.tcl
```

当前已有 floorplan 数据库上的报告：`Annotated 24668 pin activities`，总平均功耗
`3.620143 mW`（internal `1.717955 mW`、switching `1.895666 mW`、leakage
`0.006522 mW`）。对应 1,725 ns 时窗中 1024 条 issued score command，换算为约
`6.10 pJ/score command`；该时窗还包含 16 次 vector setup write，故应视为 lower bound。
这是 standard-cell 动态 proxy，不含 PIM memory、输出消费者、CTS/route 寄生或真实 1z-nm
工艺；全输出锥 VCD 在本机内存限制下尚无法完成，所以不能把它当作 silicon signoff 或系统级
每 Bank 能耗。
