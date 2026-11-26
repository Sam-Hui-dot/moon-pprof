# moon-pprof

[![Live Browser Playground](https://img.shields.io/badge/Live%20Demo-GitHub%20Pages%20(Zero%20Upload)-065f46?style=for-the-badge)](https://sam-hui-dot.github.io/moon-pprof/)
[![CI](https://github.com/Sam-Hui-dot/moon-pprof/actions/workflows/ci.yml/badge.svg)](https://github.com/Sam-Hui-dot/moon-pprof/actions/workflows/ci.yml)
[![Mooncakes](https://img.shields.io/badge/mooncakes-Sam--Hui--dot%2Fmoon--pprof%400.5.0-orange)](https://mooncakes.io/docs/Sam-Hui-dot/moon-pprof%400.5.0)

**[在线零上传演示站（GitHub Pages）](https://sam-hui-dot.github.io/moon-pprof/)** · [性能压测基准（10 万样本）](docs/BENCHMARK.md) · [规范与命令符合性矩阵](docs/CONFORMANCE.md) · [验证范围与源码统计](docs/VALIDATION.md)

纯 MoonBit 实现的 **全栈通用性能剖析引擎（`profile.proto` + V8 `.cpuprofile` / `.heapprofile` + Linux `perf script` + `folded`）、原生 Icicle/火焰图与层次调用图渲染器、多版本性能趋势拐点分析、CI 回归门禁（含可复用 GitHub Action）与零上传浏览器分析工作台**。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-pprof`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）、**可复用 GitHub Action**（`action.yml`）与**零上传浏览器离线分析站**（`web/` + [GitHub Pages](https://sam-hui-dot.github.io/moon-pprof/)）四形态交付。既可直接剖析 **MoonBit 自身编译出的 JS/Native 程序的 CPU 与内存分配**（含 MoonBit JS 符号自动反混淆），也无缝兼容 Go / Rust / Python / C++ / Node.js 工业标准 `.pb.gz` 性能剖析文件，零外部 `go tool pprof` / Graphviz / Perl 依赖。

## 核心能力

- **6 格式自动识别与统一转码（`convert` / `decode_any_profile`）**：
  - 原生二进制 Google `profile.proto`（`.pb.gz` / `.pb`）编解码与 RFC 1952 Gzip 解包；
  - 原生解析 **V8 `.cpuprofile` 与 `.heapprofile` JSON**（`node --cpu-prof` / `node --heap-prof` / Chrome DevTools）并内置 **MoonBit JS 符号反混淆**（例如将 `_M0MP215Sam_2dHui_2ddot12moon_2dpprof10WireReader12read__varint` 还原为 `Sam-Hui-dot::moon-pprof::WireReader::read_varint`），支持直接转换成标准 `.pb.gz` 并被官方 `go tool pprof` 0 误差读取；
  - 原生解析 **Linux `perf script`** 采样块（零 Perl `stackcollapse` 依赖）与 **Brendan Gregg `folded`** 文本栈。
- **完整剖析工作流闭环（对齐 `go tool pprof`）**：
  - `top`（flat / cum 排序与内联帧展开、递归栈去重）、`peek`（直接 callers / callees 权重拆解）、`list`（源码行级热点与带耗时标注的源码视图）、`traces`（Top 关键调用路径与累积覆盖率）；
  - `merge`（多文件字符串表重映射、符号去重与样本合并，对齐 `go tool pprof -proto`）；
  - `prune`（按 `--focus` / `--ignore` / `--hide` / `--label` 裁剪并垃圾回收死符号，重新编码为精简 `.pb.gz`，对齐 `go tool pprof -proto -focus`）；
  - `labels`（按 `Sample.label` 如路由/租户切片统计）。
- **原生可视化、多版本趋势与 CI 回归门禁**：
  - **单文件 & 红蓝差异 Icicle / 火焰图（SVG / 离线 HTML）**：可见深度自适应消除空白区域，支持 Top-Down Icicle（`--icicle`）与 Bottom-Up Flame 双布局切换，零 CDN 搜索与缩放；
  - **多版本性能演进趋势（`trend` / `compute_trend` / `render_trend_svg`）**：输入多个版本快照（`v1` → `v2` → `v3`），自动追踪总耗时与 Top-K 函数轨迹、标记退化拐点并生成纯 MoonBit 原生折线图 SVG 与 Markdown 报告；
  - **原生层次布局调用图（Callgraph SVG / Diff Callgraph / Graphviz DOT）**：纯 MoonBit 实现 DFS 环边检测、最长路径拓扑分层与双遍重心法（barycenter）交叉最小化排序，无需安装 Graphviz；
  - **多指标离线 HTML（`--all-metrics`）**：单文件内嵌全部指标（如 Go Heap 全部 4 项指标）并支持 Flamegraph / Callgraph / Top 切换；
  - **A/B 性能差分门禁（`diff` + 根目录 `action.yml`）**：支持 `--normalize` 占比归一化、退出码门禁（`0` / `1` / `2`）及一行接入的 GitHub Action（自动输出 `$GITHUB_STEP_SUMMARY`）。
- **零上传浏览器工作台（[立即在线体验](https://sam-hui-dot.github.io/moon-pprof/)）**：
  - 100% 本地浏览器执行，默认 Top-Down **Icicle 视图**并支持一键切换 Flame 布局；内置 **MoonBit 自举 CPU（`.cpuprofile`）与自举内存（`.heapprofile`）** 及 Go CPU / Heap 示例一键加载，支持 Icicle/Flame ↔ Callgraph 双向点击高亮联动、Lines/Traces 视图与浏览器内本地裁剪导出 `.pb.gz`。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-pprof@0.5.0
```

```moonbit
// 自动识别 .pb.gz / .pb / V8 .cpuprofile / V8 .heapprofile / perf script / folded
let base = @moon-pprof.decode_any_profile(base_bytes)
let cand = @moon-pprof.decode_any_profile(cand_bytes)
let icicle_svg = @moon-pprof.render_flamegraph_svg(cand, icicle=true)
let trend = @moon-pprof.compute_trend([("v1", base), ("v2", base), ("v3", cand)])
let trend_svg = @moon-pprof.render_trend_svg(trend)
let diff = @moon-pprof.compare_profiles(base, cand, policy=@moon-pprof.gate_policy(max_total_regression_pct=Some(15.0)))
```

### 2. CLI 命令

```powershell
# 直接剖析 MoonBit 自身 JS 程序的 CPU (.cpuprofile) 与内存分配 (.heapprofile)
moon run cmd/main --target wasm -- top demo/fixtures/moonbit-self.cpuprofile --limit 15
moon run cmd/main --target wasm -- top demo/fixtures/moonbit-self.heapprofile --sample-type alloc_space --limit 15

# 将 V8 .cpuprofile / .heapprofile / perf script / folded 转为标准 .pb.gz（可交由 go tool pprof 直接打开）
moon run cmd/main --target wasm -- convert demo/fixtures/moonbit-self.heapprofile --from v8-heap --out demo/out/self-heap.pb.gz

# 多版本性能趋势追踪 + 退化拐点折线图 SVG
moon run cmd/main --target wasm -- trend v1=demo/fixtures/baseline-cpu.pb.gz v2=demo/fixtures/baseline-cpu.pb.gz v3=demo/fixtures/candidate-cpu.pb.gz --format svg --out demo/out/trend.svg

# 渲染自顶向下 Icicle 图或离线交互式 HTML 报告
moon run cmd/main --target wasm -- flamegraph demo/fixtures/candidate-cpu.pb.gz --icicle --out demo/out/icicle.svg

# 过滤裁剪并重新编码为精简 .pb.gz（对齐 go tool pprof -proto -focus）
moon run cmd/main --target wasm -- prune demo/fixtures/candidate-cpu.pb.gz --focus main.slowRegressionLoop --out demo/out/pruned.pb.gz

# 查看源码行级热点、Top 路径、调用上下游与层次调用图 SVG
moon run cmd/main --target wasm -- list demo/fixtures/candidate-cpu.pb.gz --pattern slowRegressionLoop --source-file demo/gen_go_profiles.go
moon run cmd/main --target wasm -- traces demo/fixtures/candidate-cpu.pb.gz --limit 10 --format md
moon run cmd/main --target wasm -- peek demo/fixtures/candidate-cpu.pb.gz --pattern main.captureCPU --format md
moon run cmd/main --target wasm -- callgraph demo/fixtures/baseline-cpu.pb.gz --diff demo/fixtures/candidate-cpu.pb.gz --out demo/out/diff-callgraph.svg

# A/B 性能回归门禁 + 红蓝差异 Icicle 图 + 离线 HTML 报告
moon run cmd/main --target wasm -- diff demo/fixtures/baseline-cpu.pb.gz demo/fixtures/candidate-cpu.pb.gz --hide runtime. --icicle --max-total-pct 15 --max-func-pct 25 --format md --flamegraph-out demo/out/diff.svg --html-out demo/out/diff.html

# 构建本地离线浏览器分析站（构建后可直接打开 docs/index.html）
python demo/build_web.py
```

### 3. 可复用 GitHub Action（CI 回归门禁）

```yaml
- uses: Sam-Hui-dot/moon-pprof@main
  with:
    baseline: profiles/main-cpu.pb.gz
    candidate: profiles/pr-cpu.pb.gz
    hide: runtime.
    max-total-pct: '15'
    max-func-pct: '25'
```

## 实测验证与性能数据

```powershell
# 1. 零外部依赖四目标单元测试与 256 组模糊测试
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 2. 官方 go tool pprof 0 误差对拍（CPU / Heap / Merge / Peek / Prune / V8 CPU & Heap 互操作 / Trend & Icicle）
python demo/verify_oracle.py

# 3. 10k / 50k / 100k 样本大规模端到端性能压测
python demo/benchmark.py
```

- **官方 `go tool pprof` 0 误差对拍**：CPU（`180M` / `490M ns`）、Heap `alloc_space`（`3,247,944 B` / `6,543,480 B`，22 & 25 个函数）、`merge`（`670M ns` 对照 `-proto`）、`prune`（`350M ns` 对照 `-proto -focus`）、`peek`（callers/callees），以及 **MoonBit 自举 `.cpuprofile`（`758,330,000 ns`）与 `.heapprofile`（`5,039,760 B`）转换后的 `.pb.gz` 被官方 `go tool pprof` 直接读取**，全部 0 误差一致。
- **10 万样本大规模性能表现**（详见 [docs/BENCHMARK.md](docs/BENCHMARK.md)）：
  - Native 释放版处理 **100,000 samples（865 KB `.pb.gz`）** 仅需 **`236.9 ms`**（端到端 `top`，约 42.2 万样本/秒），层次调用图 SVG **`516.5 ms`**，过滤裁剪重写出 `.pb.gz` **`566.8 ms`**；
  - 浏览器零上传 JS 引擎一次性完成 10,000 样本全部 6 个视图渲染仅需 **`355.8 ms`**。
