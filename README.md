# moon-pprof

纯 MoonBit 实现的 **Google `pprof`（`profile.proto`）二进制性能剖析引擎、A/B 差异火焰图（Differential Flamegraph）渲染器与 CI 性能回归门禁工具**。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-pprof`，支持 `wasm` / `wasm-gc` / `js` / `native`）、**命令行工具**（`cmd/main`）与**零上传浏览器离线分析站**（`web/` + `docs/index.html`）三形态交付。不依赖外部 `go tool pprof` 或 Graphviz，即可直接解析 `.pb` 与 gzip 压缩的 `.pb.gz` 剖析文件，产出 `top` 热点统计、folded 调用栈、原生层次布局调用图（Callgraph SVG / DOT）、`peek` 上下游拆解、红蓝差异火焰图 SVG、多指标切换离线 HTML 报告以及 GitHub Actions 性能门禁。

## 核心能力

- **原生 `profile.proto` 编解码与 Gzip 自动解包**：零外部 C 绑定实现 Protobuf Wire Format（varint / length-delimited / packed repeated / 未知字段安全跳过），通过 `moonbit-community/flate/gzip` 自动解包 `.pb.gz`，并支持 `encode_profile` 编码与全链路 round-trip 校验。
- **与 `go tool pprof` 对齐的聚合语义**：正确按 leaf-first 顺序展开内联帧（`Location.lines`），在计算 `cum` 时对递归栈帧去重避免重复计入，支持多指标（`cpu` / `samples` / `alloc_space` / `inuse_space` 等）与 `default_sample_type` 解析。
- **原生层次布局调用图（Callgraph SVG / Diff Callgraph / DOT）**：纯 MoonBit 实现加权有向调用图构图、DFS 环边检测、最长路径拓扑分层与双遍重心法（barycenter）交叉最小化排序，无需安装 Graphviz 即可直接输出单文件/差分层次调用图 SVG 与标准 DOT 文件。
- **`peek` 上下游调用拆解与多指标交互式 HTML**：支持类似 `go tool pprof -peek` 的 callers / callees 精确拆解，以及 `--all-metrics` 单文件离线 HTML 报告（一键切换全部 Heap/CPU 指标及 Flamegraph / Callgraph / Top 视图）。
- **多文件合并（`merge`）**：支持将多台机器/多时间窗口采集的 `.pb.gz` 按字符串表重映射、函数/位置去重、样本累加合并为规范 `.pb.gz`，与官方 `go tool pprof -proto` 0 误差一致。
- **标签切片与噪音过滤**：支持按 `Sample.label`（如 HTTP 路由/租户/Goroutine 标签）分组汇总（`labels`）与定向过滤，并提供 `--focus` / `--ignore` / `--hide` 规则以屏蔽 `runtime.*` 等底层噪音栈帧。
- **A/B 性能差分与 CI 回归门禁**：对比基线与候选两份 profile，支持绝对差分与占比归一化（`--normalize`），自动标记 `regressed` / `improved` / `added` / `removed` / `unchanged`，按总回归比例与单函数阈值返回退出码（`0` 通过、`1` 回归拦截、`2` 输入或解析错误）。
- **零上传浏览器离线分析站**：通过 `web/` 包将核心库编译为纯客户端 JS 产物（`python demo/build_web.py`），打开 `docs/index.html` 即可在浏览器本地拖拽分析 `.pb.gz`（内置真实 Go CPU & Heap 示例一键体验，附带 `.github/workflows/pages.yml` 支持部署 GitHub Pages）。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-pprof@0.3.0
```

```moonbit
let base = @moon-pprof.decode_profile(base_bytes)
let cand = @moon-pprof.decode_profile(cand_bytes)
let policy = @moon-pprof.gate_policy(
  max_total_regression_pct=Some(15.0),
  max_func_cum_regression_pct=Some(25.0),
)
let diff = @moon-pprof.compare_profiles(base, cand, policy~)
let fg_svg = @moon-pprof.render_diff_flamegraph_svg(base, cand)
let cg_svg = @moon-pprof.render_diff_callgraph_svg(@moon-pprof.build_diff_callgraph(base, cand))
let html = @moon-pprof.render_diff_html(base, cand, policy~)
```

### 2. CLI 命令

```powershell
# 查看 Top 热点（支持 text / json / md）
moon run cmd/main --target wasm -- top demo/fixtures/baseline-cpu.pb.gz --sort flat --limit 15

# 生成原生层次布局调用图 SVG / 差分调用图 / Graphviz DOT
moon run cmd/main --target wasm -- callgraph demo/fixtures/candidate-cpu.pb.gz --format svg --out demo/out/callgraph.svg
moon run cmd/main --target wasm -- callgraph demo/fixtures/baseline-cpu.pb.gz --diff demo/fixtures/candidate-cpu.pb.gz --out demo/out/diff-callgraph.svg
moon run cmd/main --target wasm -- callgraph demo/fixtures/candidate-cpu.pb.gz --format dot --out demo/out/callgraph.dot

# 查看指定函数的直接调用方与被调用方（对齐 go tool pprof -peek）
moon run cmd/main --target wasm -- peek demo/fixtures/candidate-cpu.pb.gz --pattern main.captureCPU --format md

# 生成多指标切换离线交互式 HTML（一次性内嵌全部 4 个 Heap 指标 + Flamegraph/Callgraph/Top）
moon run cmd/main --target wasm -- flamegraph demo/fixtures/candidate-heap.pb.gz --all-metrics --out demo/out/heap-all-metrics.html

# A/B 性能回归门禁 + 屏蔽 runtime 噪音 + 红蓝差异火焰图 SVG + 离线交互 HTML 报告
moon run cmd/main --target wasm -- diff demo/fixtures/baseline-cpu.pb.gz demo/fixtures/candidate-cpu.pb.gz --hide runtime. --max-total-pct 15 --max-func-pct 25 --format md --flamegraph-out demo/out/diff.svg --html-out demo/out/diff.html

# 合并多份剖析文件为规范 .pb.gz（对齐 go tool pprof -proto）
moon run cmd/main --target wasm -- merge demo/fixtures/baseline-cpu.pb.gz demo/fixtures/candidate-cpu.pb.gz --out demo/out/merged.pb.gz

# 构建零上传浏览器离线分析站（构建完成后直接双击打开 docs/index.html）
python demo/build_web.py
```

## 与官方 `go tool pprof` 的精确对拍

仓库随附纯标准库 Go 基准程序 [demo/gen_go_profiles.go](demo/gen_go_profiles.go)、两份真实生成的 CPU 剖析样本（`demo/fixtures/baseline-cpu.pb.gz`、`demo/fixtures/candidate-cpu.pb.gz`）以及自动对拍脚本 [demo/verify_oracle.py](demo/verify_oracle.py)：

```powershell
# 零外部依赖四目标单元测试
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn

# 与官方 go tool pprof 逐函数精确对拍 + 回归门禁验证
python demo/verify_oracle.py
```

实测结果：
- **CPU 对拍**：`baseline-cpu.pb.gz`（`180,000,000 ns`）与 `candidate-cpu.pb.gz`（`490,000,000 ns`）全部 6 个函数的 `flat` / `cum` 与 `go tool pprof -top -unit=ns` **0 误差一致**。
- **Heap 内存对拍**：`baseline-heap.pb.gz`（`alloc_space` `3,247,944 B`，22 个函数）与 `candidate-heap.pb.gz`（`alloc_space` `6,543,480 B`，25 个函数）与 `go tool pprof -top -sample_index=alloc_space -unit=B` **逐字节 0 误差一致**。
- **多文件合并对拍**：`moon-pprof merge` 合并两份 CPU 样本（`670,000,000 ns`）与 `go tool pprof -proto` **0 误差一致**。
- **差分门禁与过滤**：`diff --hide runtime.` 准确屏蔽运行时帧并检出退化函数 `main.slowRegressionLoop`，返回退出码 `1`，生成差异火焰图 SVG、离线 HTML 与 Markdown 汇总表。

## 与 MoonBit 现有生态的互补关系

- 现有 `moonflame` 面向纯文本 folded stack 渲染，`moonsize` 面向 Wasm 二进制体积统计，`mooncallgrind` 面向 Callgrind 文本，`moonheap` 面向 V8 Heap Snapshot JSON。
- `moon-pprof` 填补跨语言工业标准 **Google `pprof`（`profile.proto` 二进制 / `.pb.gz`）** 解析、A/B 性能差分门禁与红蓝差异火焰图空白，既可独立用于 Go/Rust/Python/C++/Node.js 服务的离线剖析与 CI 回归拦截，也可作为全目标库被浏览器 Wasm 前端或其他 MoonBit 工具复用。

更多验证边界与源码统计见 [docs/VALIDATION.md](docs/VALIDATION.md)。
