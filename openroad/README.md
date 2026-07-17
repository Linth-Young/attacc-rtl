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
| Floorplan instance area | 9,223.53 µm² |
| 论文 10x 缩放估计 | 0.0922353 mm² |
| Floorplan fmax metric | 802.77 MHz |
| 库功耗 proxy | 0.657587 W |

`power_activity.tcl` 仅在 `artifacts/attacc_gemv_activity.vcd` 存在时读取活动文件。
活动文件必须由与综合网表层级匹配的测试生成；若日志显示 `Annotated 0 pin activities`，
任何 power 数值都不可视作 workload 动态功耗。当前 0.657587 W 仅用于量化逐 word
写时钟门控相对未门控 FF buffer 的改善，不能与论文的 macro-based GemV 功耗直接比较。

同时，floorplan 流仍报告 `RSZ-0062` setup violation；其 fmax metric 不构成 666 MHz
时序通过结论。完整背景见 [`../docs/attacc_gemv_rtl_handoff.md`](../docs/attacc_gemv_rtl_handoff.md)。
