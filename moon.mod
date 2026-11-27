name = "Sam-Hui-dot/moon-pprof"

version = "0.5.1"

license = "Apache-2.0"

readme = "README.md"

repository = "https://github.com/Sam-Hui-dot/moon-pprof"

keywords = [
  "pprof",
  "profiler",
  "flamegraph",
  "performance",
  "protobuf",
  "cli",
]

description = "Pure-MoonBit Google pprof (profile.proto) parser, differential profiler, CI regression gate, and interactive flamegraph renderer"

preferred_target = "wasm"

import {
  "moonbit-community/flate@0.10.0",
  "moonbitlang/async@0.22.4",
}
