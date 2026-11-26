# `moon-pprof` Conformance & Feature Matrix

This document tracks exact specification coverage of `Sam-Hui-dot/moon-pprof` against the Google `perftools.profiles.Profile` (`profile.proto`) specification, external profiling ingestion formats, and official `go tool pprof` CLI commands.

---

## 1. `profile.proto` Binary Codec Conformance

| Message / Field | Decode | Encode | Round-Trip Verified | Notes |
| --- | :---: | :---: | :---: | --- |
| `Profile.sample_type` (field 1) | Yes | Yes | Yes | Multi-metric (`cpu`, `alloc_objects`, `alloc_space`, `inuse_objects`, `inuse_space`, custom) |
| `Profile.sample` (field 2) | Yes | Yes | Yes | Packed & unpacked `location_id` and `value`; arbitrary `Sample.label` metadata |
| `Profile.mapping` (field 3) | Yes | Yes | Yes | Preserved across `decode`, `merge`, `prune`, and `encode` |
| `Profile.location` (field 4) | Yes | Yes | Yes | Leaf-first inlined `Location.line` expansion + `is_folded` + hex fallback |
| `Profile.function` (field 5) | Yes | Yes | Yes | `name`, `system_name`, `filename`, `start_line` |
| `Profile.string_table` (field 6) | Yes | Yes | Yes | Validates `string_table[0] == ""`; garbage-collected on `merge` & `prune` |
| `Profile.drop_frames` / `keep_frames` (7, 8) | Yes | Yes | Yes | Preserved on round-trip |
| `Profile.time_nanos` / `duration_nanos` (9, 10) | Yes | Yes | Yes | Preserved; accumulated cleanly on `merge` |
| `Profile.period_type` / `period` (11, 12) | Yes | Yes | Yes | Preserved on round-trip and `merge` |
| `Profile.comment` (field 13) | Yes | Yes | Yes | Deduplicated on `merge` |
| `Profile.default_sample_type` (field 14) | Yes | Yes | Yes | Aligned with `go tool pprof` fallback to last declared sample type |
| RFC 1952 Gzip `.pb.gz` wrapper | Yes | Yes | Yes | Pure MoonBit via `moonbit-community/flate/gzip` |
| Unknown Protobuf fields | Skip | — | Fuzz-tested | Safe wire-type 0/1/2/5 skipping; 256-case + prefix-truncation panic-free fuzz suite |

---

## 2. Multi-Format Ingestion Conformance

| Input Format | Auto-Detect | Convert to `.pb.gz` | `go tool pprof` Interop Verified | Primary Use Case |
| --- | :---: | :---: | :---: | --- |
| Google pprof `.pb.gz` | Yes | Native | Yes (0-error CPU/Heap/Merge/Prune) | Go, Rust (`pprof-rs`), C++ (`gperftools`), Python (`py-spy`/pprof) |
| Uncompressed `.pb` | Yes | Native | Yes | Raw protobuf streams & embedded targets |
| V8 `.cpuprofile` JSON | Yes | Yes | Yes (`moonbit-self.cpuprofile` -> `.pb.gz`, `758,330,000 ns`) | **MoonBit JS/Wasm CPU (`node --cpu-prof`)**, Node.js, Chrome DevTools (with MoonBit symbol demangling) |
| V8 `.heapprofile` JSON | Yes | Yes | Yes (`moonbit-self.heapprofile` -> `.pb.gz`, `5,039,760 B`) | **MoonBit JS/Wasm Heap (`node --heap-prof`)**, Node.js, Chrome DevTools allocation sampling |
| Linux `perf script` | Yes | Yes | Yes | Native MoonBit binaries, Linux C/C++/Rust perf captures (zero Perl dependency) |
| Brendan Gregg `folded` | Yes | Yes | Yes | Existing flamegraph pipelines & DTrace/eBPF stack collapses |

---

## 3. `go tool pprof` Command & Feature Alignment

| Capability | `go tool pprof` Equivalent | `moon-pprof` Subcommand / API | Verification Status |
| --- | --- | --- | --- |
| Function Flat & Cum Table | `-top` | `top` / `compute_top` | **0-error match** (Go CPU 180M/490M ns; Heap 3.25MB/6.54MB) |
| Caller/Callee Breakdown | `-peek=<re>` | `peek` / `compute_peek` | **0-error match** (`main.captureCPU` callers & callees) |
| Source-Line Attribution | `-list=<re>` | `list` / `compute_line_hotspots` + `render_annotated_source` | Verified against `demo/gen_go_profiles.go` |
| Top Call Paths | `-traces` | `traces` / `compute_traces` | Verified on Go CPU & MoonBit self-profile |
| Multi-Profile Merge | `-proto a b` | `merge` / `merge_profiles` | **0-error match** (670M ns merged CPU) |
| Filtered Re-Encode | `-proto -focus=...` | `prune` / `prune_profile` | **0-error match** (`-focus=main.slowRegressionLoop`) |
| Callgraph Visualization | `-svg` / `-dot` | `callgraph` / `render_callgraph_svg` / `render_callgraph_dot` | Pure MoonBit Sugiyama layout (no Graphviz required) |
| Differential Profiling | `-diff_base` | `diff` / `compare_profiles` + `render_diff_flamegraph_svg(..., icicle~)` + `action.yml` | Verified with CI exit-code gate (`0` / `1` / `2`) and reusable GitHub Action |
| Multi-Version Trend | — (beyond `go tool pprof`) | `trend` / `compute_trend` + `render_trend_svg` | Verified 3-version regression inflection detection & native SVG chart |
| Sample Label Slicing | `-tagfocus` / `-tags` | `labels` + `--label key=val` / `group_by_label` | Unit-tested across 4 targets |
| Multi-Metric Interactive HTML | `-http` (multi-index) | `flamegraph --all-metrics` / `render_multi_metric_html` | Offline zero-CDN 4-metric Heap HTML |
| Zero-Upload Browser App | Web UI (local server) | [Live GitHub Pages](https://sam-hui-dot.github.io/moon-pprof/) (`web/` + `docs/index.html`) | 100% client-side, 6 input formats, default Top-Down Icicle + Flame toggle, in-browser `.pb.gz` prune export |

## 4. Explicit Scope Boundaries

- Substring filtering (`--focus`, `--ignore`, `--hide`) uses deterministic literal substring matching rather than full RE2 regular expressions.
- Unsymbolized raw ELF/Mach-O/PE instruction addresses are not disassembled from DWARF debug info; locations without `Line` entries are displayed by hexadecimal address (`0x...`).
