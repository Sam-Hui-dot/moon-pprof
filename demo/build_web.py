import base64
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
FIXTURES = ROOT / "demo" / "fixtures"


def main() -> None:
    cmd = ["moon", "build", "--target", "js", "--release", "--deny-warn", "web"]
    print("Running:", " ".join(cmd))
    subprocess.run(cmd, cwd=ROOT, check=True)

    built_js = ROOT / "_build" / "js" / "release" / "build" / "web" / "web.js"
    if not built_js.exists():
        raise FileNotFoundError(f"Expected JS build artifact not found: {built_js}")

    DOCS.mkdir(parents=True, exist_ok=True)
    target_js = DOCS / "moon-pprof.js"
    shutil.copy2(built_js, target_js)
    print(f"Copied {built_js} -> {target_js} ({target_js.stat().st_size} bytes)")

    sample_map = {
        "baseline_cpu": "baseline-cpu.pb.gz",
        "candidate_cpu": "candidate-cpu.pb.gz",
        "baseline_heap": "baseline-heap.pb.gz",
        "candidate_heap": "candidate-heap.pb.gz",
        "moonbit_self": "moonbit-self.cpuprofile",
    }
    encoded = {}
    for key, fname in sample_map.items():
        path = FIXTURES / fname
        encoded[key] = base64.b64encode(path.read_bytes()).decode("ascii")

    samples_js = DOCS / "samples.js"
    samples_js.write_text(
        "globalThis.MOON_PPROF_SAMPLES = " + json.dumps(encoded) + ";\n",
        encoding="utf-8",
    )
    print(f"Wrote {samples_js} ({samples_js.stat().st_size} bytes)")

    smoke = (
        "require('./docs/moon-pprof.js');\n"
        "require('./docs/samples.js');\n"
        "const S = globalThis.MOON_PPROF_SAMPLES;\n"
        "const M = globalThis.MoonPprof;\n"
        "const info = M.inspectProfile(S.candidate_heap);\n"
        "if (!info.ok || info.metrics.length !== 4 || info.format !== 'pprof-gzip') throw new Error('inspect heap failed');\n"
        "const mbt = M.inspectProfile(S.moonbit_self);\n"
        "if (!mbt.ok || mbt.format !== 'v8-cpuprofile') throw new Error('inspect moonbit self failed');\n"
        "const selfRes = M.analyzeProfile(S.moonbit_self, { sampleType: 'cpu' });\n"
        "if (!selfRes.ok || !selfRes.flamegraph_svg.includes('WireReader::read_varint') || selfRes.lines.entries.length < 1 || selfRes.traces.traces.length < 1) throw new Error('self analyze failed');\n"
        "const pruned = M.pruneProfile(S.candidate_cpu, { hide: 'runtime.' });\n"
        "if (!pruned.ok || !pruned.pb_gz_b64 || pruned.after_functions >= pruned.before_functions) throw new Error('prune failed');\n"
        "const diff = M.compareProfiles(S.baseline_cpu, S.candidate_cpu, {});\n"
        "if (!diff.ok || diff.diff.baseline_total !== '180000000' || diff.diff.candidate_total !== '490000000') throw new Error('diff failed');\n"
        "console.log('WEB_BUNDLE_SMOKE_OK', JSON.stringify({ heap_metrics: info.metrics.length, self_format: mbt.format, self_samples: mbt.sample_count, pruned_bytes: pruned.byte_length, self_lines: selfRes.lines.entries.length }));\n"
    )
    subprocess.run(["node", "-e", smoke], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
