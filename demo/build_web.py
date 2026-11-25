import base64
import json
import shutil
import subprocess
import sys
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

    # Smoke-test the built browser bundle directly in Node.js
    smoke = (
        "require('./docs/moon-pprof.js');\n"
        "require('./docs/samples.js');\n"
        "const S = globalThis.MOON_PPROF_SAMPLES;\n"
        "const M = globalThis.MoonPprof;\n"
        "const info = M.inspectProfile(S.candidate_heap);\n"
        "if (!info.ok || info.metrics.length !== 4) throw new Error('inspect failed');\n"
        "const single = M.analyzeProfile(S.candidate_heap, { sampleType: 'alloc_space' });\n"
        "if (!single.ok || !single.callgraph_svg.includes('<svg') || !single.flamegraph_svg.includes('<svg')) throw new Error('single analyze failed');\n"
        "const diff = M.compareProfiles(S.baseline_cpu, S.candidate_cpu, {});\n"
        "if (!diff.ok || diff.diff.baseline_total !== '180000000' || diff.diff.candidate_total !== '490000000') throw new Error('diff failed');\n"
        "const peek = M.peekProfile(S.candidate_cpu, 'main.', {});\n"
        "if (!peek.ok || peek.peek.functions.length < 1) throw new Error('peek failed');\n"
        "console.log('WEB_BUNDLE_SMOKE_OK', JSON.stringify({ metrics: info.metrics.length, cg_len: single.callgraph_svg.length, diff_total: diff.diff.candidate_total, peek_matches: peek.peek.functions.length }));\n"
    )
    subprocess.run(["node", "-e", smoke], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
