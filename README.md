# moon-pprof

纯 MoonBit 实现的 **Google `pprof`（`profile.proto`）二进制性能剖析引擎、A/B 差异火焰图（Differential Flamegraph）渲染器与 CI 性能回归门禁工具**。

项目以**全目标纯 MoonBit 核心库**（`Sam-Hui-dot/moon-pprof`，支持 `wasm` / `wasm-gc` / `js` / `native`）与**命令行工具**（`cmd/main`）双形态交付。不依赖外部 `go tool pprof` 运行时，即可直接解析 `.pb` 与 gzip 压缩的 `.pb.gz` 剖析文件，产出 `top` 热点统计、folded 调用栈、红蓝差异火焰图 SVG、离线可搜索/缩放单文件 HTML 报告以及 GitHub Actions 性能门禁。

## 核心能力

- **原生 `profile.proto` 编解码与 Gzip 自动解包**：零外部 C 绑定实现 Protobuf Wire Format（varint / length-delimited / packed repeated / 未知字段安全跳过），通过 `moonbit-community/flate/gzip` 自动解包 `.pb.gz`，并支持 `encode_profile` 编码与全链路 round-trip 校验。
- **与 `go tool pprof` 对齐的聚合语义**：正确按 leaf-first 顺序展开内联帧（`Location.lines`），在计算 `cum` 时对递归栈帧去重避免重复计入，支持多指标（`cpu` / `samples` / `alloc_space` 等）与 `default_sample_type` 解析。
- **A/B 性能差分与 CI 回归门禁**：对比基线与候选两份 profile，支持绝对差分与占比归一化（`--normalize`），自动标记 `regressed` / `improved` / `added` / `removed` / `unchanged`，按总回归比例与单函数阈值返回退出码（`0` 通过、`1` 回归拦截、`2` 输入或解析错误）。
- **交互式火焰图与差异火焰图（SVG / 离线 HTML）**：
  - 单文件火焰图：暖色系前缀合并树，悬停显示完整函数名、`cum`、`flat` 与占比。
  - **差异火焰图（Differential Flamegraph）**：遵循 Brendan Gregg 红蓝配色规范——红色越深表示性能退化越重、蓝色越深表示优化下降越多、浅灰表示基本持平。
  - **单文件离线 HTML 报告**：零外部 CDN，内置关键词高亮搜索、点击任意栈帧缩放（Zoom / Reset）与 Top 热点/回归表格。

## 快速使用

### 1. 作为 MoonBit 核心库导入（支持 Wasm / WasmGC / JS / Native）

```powershell
moon add Sam-Hui-dot/moon-pprof@0.1.0
```

```moonbit
let base = @moon-pprof.decode_profile(base_bytes)
let cand = @moon-pprof.decode_profile(cand_bytes)
let policy = @moon-pprof.gate_policy(
  max_total_regression_pct=Some(15.0),
  max_func_cum_regression_pct=Some(25.0),
)
let diff = @moon-pprof.compare_profiles(base, cand, policy~)
let svg = @moon-pprof.render_diff_flamegraph_svg(base, cand)
let html = @moon-pprof.render_diff_html(base, cand, policy~)
```

### 2. CLI 命令

```powershell
# 查看 Top 热点（支持 text / json / md）
moon run cmd/main --target wasm -- top demo/fixtures/baseline-cpu.pb.gz --sort flat --limit 15

# 导出 Brendan Gregg folded stacks
moon run cmd/main --target wasm -- folded demo/fixtures/baseline-cpu.pb.gz

# 生成单文件交互式 HTML 火焰图
moon run cmd/main --target wasm -- flamegraph demo/fixtures/baseline-cpu.pb.gz --html --out demo/out/baseline.html

# A/B 性能回归门禁 + 红蓝差异火焰图 SVG + 离线交互 HTML 报告
moon run cmd/main --target wasm -- diff demo/fixtures/baseline-cpu.pb.gz demo/fixtures/candidate-cpu.pb.gz --max-total-pct 15 --max-func-pct 25 --format md --flamegraph-out demo/out/diff.svg --html-out demo/out/diff.html
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
- `baseline-cpu.pb.gz`（`180,000,000 ns`）与 `candidate-cpu.pb.gz`（`490,000,000 ns`）的 `total` 以及全部 6 个函数的 `flat` / `cum` 数值与 `go tool pprof -top -unit=ns` **0 误差完全一致**。
- `diff` 命令准确检出退化函数 `main.slowRegressionLoop`（`50,000,000 ns` → `350,000,000 ns`，`+600%`，占比 `+43.65pp`），返回退出码 `1`，并生成差异火焰图 SVG、离线 HTML 与 Markdown 汇总表。

## 与 MoonBit 现有生态的互补关系

- 现有 `moonflame` 面向纯文本 folded stack 渲染，`moonsize` 面向 Wasm 二进制体积统计，`mooncallgrind` 面向 Callgrind 文本，`moonheap` 面向 V8 Heap Snapshot JSON。
- `moon-pprof` 填补跨语言工业标准 **Google `pprof`（`profile.proto` 二进制 / `.pb.gz`）** 解析、A/B 性能差分门禁与红蓝差异火焰图空白，既可独立用于 Go/Rust/Python/C++/Node.js 服务的离线剖析与 CI 回归拦截，也可作为全目标库被浏览器 Wasm 前端或其他 MoonBit 工具复用。

更多验证边界与源码统计见 [docs/VALIDATION.md](docs/VALIDATION.md)。
