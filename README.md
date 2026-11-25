# moon-pprof

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-065f46?style=for-the-badge)](https://sam-hui-dot.github.io/moon-pprof/)
[![CI](https://github.com/Sam-Hui-dot/moon-pprof/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-pprof/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--pprof%400.4.0-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-pprof%400.4.0)

**[在线零上传演示站（GitHub Pages）](https://sam-hui-dot.github.io/moon-pprof/)** · [性能压测基准（10 万样本）](docs/BENCHMARK.md) · [规范与命令符合性矩阵](docs/CONFORMANCE.md) · [验证范围与源码统计](docs/VALIDATION.md)

纯 MoonBit 实现的 **全栈通用性能剖析引擎（`profile.proto` + V8 `.cpuprofile` + Linux `perf script` + `folded`）、原生层次调用图与差异火焰图渲染器、CI 性能回归门禁与零上传浏览器分析工作台**。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-pprof`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器离线分析站**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-pprof/)）三形态交付。既可直接剖析 **MoonBit 自身编译出的 JS/Native 程序**（含 MoonBit JS 符号自动反混淆），也无缝兼容 Go / Rust / Python / C++ / Node.js 工业标准 `.pb.gz` 性能剖析文件，零外部 `go tool pprof` / Graphviz / Perl 依赖。

## 核心能力

- **5 格式自动识别与统一转码（`convert` / `decode_any_profile`）**：
  - 原生二进制 Google `profile.proto`（`.pb.gz` / `.pb`）编解码与 RFC 1952 Gzip 解包；
  - 原生解析 **V8 `.cpuprofile` JSON**（`node --cpu-prof` / Chrome DevTools）并内置 **MoonBit JS 符号反混淆**（例如将 `_M0MP215Sam_2dHui_2ddot12moon_2dpprof10WireReader12read__varint` 还原为 `Sam-Hui-dot::moon-pprof::WireReader::read_varint`），支持直接转换成标准 `.pb.gz` 并被官方 `go tool pprof` 读取；
  - 原生解析 **Linux `perf script`** 采样块（零 Perl `stackcollapse` 依赖）与 **Brendan Gregg `folded`** 文本栈。
- **完整剖析工作流闭环（对齐 `go tool pprof`）**：
  - `top`（flat / cum 排序与内联帧展开、递归栈去重）、`peek`（直接 callers / callees 权重拆解）、`list`（源码行级热点与带耗时标注的源码视图）、`traces`（Top 关键调用路径与累积覆盖率）；
  - `merge`（多文件字符串表重映射、符号去重与样本合并，对齐 `go tool pprof -proto`）；
  - `prune`（按 `--focus` / `--ignore` / `--hide` / `--label` 裁剪并垃圾回收死符号，重新编码为精简 `.pb.gz`，对齐 `go tool pprof -proto -focus`）；
  - `labels`（按 `Sample.label` 如路由/租户切片统计）。
- **原生可视化与 CI 回归门禁**：
  - **单文件 & 红蓝差异火焰图（SVG / 离线 HTML）**：遵循 Brendan Gregg 差异配色，零 CDN 搜索与缩放；
  - **原生层次布局调用图（Callgraph SVG / Diff Callgraph / Graphviz DOT）**：纯 MoonBit 实现 DFS 环边检测、最长路径拓扑分层与双遍重心法（barycenter）交叉最小化排序，无需安装 Graphviz；
  - **多指标离线 HTML（`--all-metrics`）**：单文件内嵌全部指标（如 Go Heap 全部 4 项指标）并支持 Flamegraph / Callgraph / Top 切换；
  - **A/B 性能差分门禁（`diff`）**：支持 `--normalize` 占比归一化与总回归/单函数阈值退出码门禁（`0` 通过、`1` 回归拦截、`2` 错误）。
- **零上传浏览器工作台（[立即在线体验](https://sam-hui-dot.github.io/moon-pprof/)）**：
  - 100% 本地浏览器执行，内置 **MoonBit 自举剖析（`moon-pprof` 剖析自己跑在 MoonBit JS 上的真实 `.cpuprofile`）** 以及 Go CPU / Heap 示例一键加载，支持 Flamegraph ↔ Callgraph 双向点击高亮联动、Lines/Traces 视图与浏览器内本地裁剪导出 `.pb.gz`。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-pprof@0.4.0
```

```moonbit
// 自动识别 .pb.gz / .pb / V8 .cpuprofile / perf script / folded
let base = @moon-pprof.decode_any_profile(base_bytes)
let cand = @moon-pprof.decode_any_profile(cand_bytes)
let pruned = @moon-pprof.prune_profile(cand, @moon-pprof.filter_spec(hide="runtime."))
let pruned_gz = @moon-pprof.encode_profile(pruned, gzip=true)
let diff = @moon-pprof.compare_profiles(base, cand, policy=@moon-pprof.gate_policy(max_total_regression_pct=Some(15.0)))
let cg_svg = @moon-pprof.render_diff_callgraph_svg(@moon-pprof.build_diff_callgraph(base, cand))
```

### 2. CLI 命令

```powershell
# 直接剖析 MoonBit 自身 JS 程序（node --cpu-prof 产出的 V8 .cpuprofile），自动反混淆 MoonBit 符号
moon run cmd/main --target wasm -- top demo/fixtures/moonbit-self.cpuprofile --limit 15

# 将 V8 .cpuprofile / perf script / folded 转为标准 .pb.gz（可交由 go tool pprof 直接打开）
moon run cmd/main --target wasm -- convert demo/fixtures/moonbit-self.cpuprofile --from v8 --out demo/out/self.pb.gz

# 过滤裁剪并重新编码为精简 .pb.gz（对齐 go tool pprof -proto -focus）
moon run cmd/main --target wasm -- prune demo/fixtures/candidate-cpu.pb.gz --focus main.slowRegressionLoop --out demo/out/pruned.pb.gz

# 查看源码行级热点与带耗时注释的源码（对齐 go tool pprof -list）
moon run cmd/main --target wasm -- list demo/fixtures/candidate-cpu.pb.gz --pattern slowRegressionLoop --source-file demo/gen_go_profiles.go

# 查看 Top 关键调用路径 / 调用上下游 / 层次调用图 SVG
moon run cmd/main --target wasm -- traces demo/fixtures/candidate-cpu.pb.gz --limit 10 --format md
moon run cmd/main --target wasm -- peek demo/fixtures/candidate-cpu.pb.gz --pattern main.captureCPU --format md
moon run cmd/main --target wasm -- callgraph demo/fixtures/baseline-cpu.pb.gz --diff demo/fixtures/candidate-cpu.pb.gz --out demo/out/diff-callgraph.svg

# A/B 性能回归门禁 + 红蓝差异火焰图 + 离线 HTML 报告
moon run cmd/main --target wasm -- diff demo/fixtures/baseline-cpu.pb.gz demo/fixtures/candidate-cpu.pb.gz --hide runtime. --max-total-pct 15 --max-func-pct 25 --format md --flamegraph-out demo/out/diff.svg --html-out demo/out/diff.html

# 构建本地离线浏览器分析站（构建后可直接打开 docs/index.html）
python demo/build_web.py
```

## 实测验证与性能数据

```powershell
# 1. 零外部依赖四目标单元测试与 256 组模糊测试
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 2. 官方 go tool pprof 0 误差对拍（CPU / Heap / Merge / Peek / Prune / V8->pprof 互操作）
python demo/verify_oracle.py

# 3. 10k / 50k / 100k 样本大规模端到端性能压测
python demo/benchmark.py
```

- **官方 `go tool pprof` 0 误差对拍**：CPU（`180M` / `490M ns`）、Heap `alloc_space`（`3,247,944 B` / `6,543,480 B`，22 & 25 个函数）、`merge`（`670M ns` 对照 `-proto`）、`prune`（`350M ns` 对照 `-proto -focus`）、`peek`（callers/callees）以及 **MoonBit 自举 `.cpuprofile` 转换后的 `.pb.gz` 被官方 `go tool pprof` 直接读取**（`758,330,000 ns`）全部 0 误差一致。
- **10 万样本大规模性能表现**（详见 [docs/BENCHMARK.md](docs/BENCHMARK.md)）：
  - Native 释放版处理 **100,000 samples（865 KB `.pb.gz`）** 仅需 **`236.9 ms`**（端到端 `top`，约 42.2 万样本/秒），层次调用图 SVG **`516.5 ms`**，过滤裁剪重写出 `.pb.gz` **`566.8 ms`**；
  - 浏览器零上传 JS 引擎一次性完成 10,000 样本全部 6 个视图渲染仅需 **`355.8 ms`**。
