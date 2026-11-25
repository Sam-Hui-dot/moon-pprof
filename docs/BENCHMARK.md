# `moon-pprof` Performance Benchmarks

Reproducible end-to-end benchmarks measuring gzip decompression, `profile.proto` decoding, stack aggregation, SVG rendering (Flamegraph & Sugiyama Callgraph), and filtered `.pb.gz` re-encoding (`prune`) across 10,000 to 100,000 samples (500 distinct functions, 5-frame call stacks per sample).

## Reproduction

```bash
# Build browser bundle first (for JS in-process timing)
python3 demo/build_web.py

# Run full 10k / 50k / 100k benchmark suite (builds Native release CLI automatically)
python3 demo/benchmark.py

# Quick CI smoke benchmark (10k samples only)
python3 demo/benchmark.py --quick
```

## Measured Results (Windows x64, MoonBit Native Release + Node.js V8 JS Release)

All Native timings are wall-clock process invocations (including OS process spawn, file I/O, RFC 1952 gzip decompression via pure MoonBit `flate/gzip`, protobuf decoding, computation, and file write). The JS timing runs `MoonPprof.analyzeProfile` in-process on Node.js, executing **decode + top + Flamegraph SVG + Sugiyama Callgraph SVG/DOT + line hotspots + traces + Markdown** in a single call.

| Samples | Functions | `.pb.gz` Size | Native `top` | Native `callgraph` (SVG) | Native `prune` (Re-encode `.pb.gz`) | Native `flamegraph` (SVG) | Browser JS All-in-One |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 500 | 98.8 KB | **38.2 ms** | 77.2 ms | 76.7 ms | 109.4 ms | 355.8 ms |
| 50,000 | 500 | 438.8 KB | **132.0 ms** | 272.9 ms | 298.0 ms | 482.7 ms | 1,536.6 ms |
| 100,000 | 500 | 865.1 KB | **236.9 ms** | 516.5 ms | 566.8 ms | 1,015.9 ms | 3,164.8 ms |

### Key Observations

- **Linear scaling**: From 10k to 100k samples (10x input growth), Native `top` scales sub-linearly (`38.2 ms` -> `236.9 ms`, ~422k samples/sec end-to-end), and Native `callgraph` + `prune` stay around **~0.5 s** for 100,000 samples.
- **Zero-upload browser responsiveness**: Even for a 10,000-sample gzipped profile, the pure-MoonBit JS bundle computes all 6 analysis views (`top`, Flamegraph SVG, Callgraph SVG, DOT, line hotspots, critical traces) locally in the browser in **~356 ms**.
- **Self-profiling (Dogfooding)**: Running `node --cpu-prof` on `moon-pprof` itself (`demo/fixtures/moonbit-self.cpuprofile`) and analyzing it with `moon-pprof` reveals hot paths down to demangled MoonBit functions (`string::String::Hash::hash` 9.26%, `uint64::UInt64::Hash::hash` 5.25%, `Sam-Hui-dot::moon-pprof::WireReader::read_varint` 3.02%).
