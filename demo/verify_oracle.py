"""Cross-check moon-pprof against official `go tool pprof` on real Go CPU, Heap, and merged .pb.gz profiles."""
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "demo" / "fixtures"
OUT = ROOT / "demo" / "out"
OUT.mkdir(parents=True, exist_ok=True)


def run(cmd, cwd=ROOT, check=True):
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\n{res.stdout}\n{res.stderr}")
    return res


def to_base_unit(val: float, unit: str) -> int:
    mult = {
        "ns": 1,
        "us": 1_000,
        "ms": 1_000_000,
        "s": 1_000_000_000,
        "B": 1,
        "kB": 1024,
        "MB": 1024 * 1024,
        "GB": 1024 * 1024 * 1024,
        "": 1,
    }[unit]
    return int(round(val * mult))


def parse_go_pprof_top(pprof_path: Path, sample_index: str | None = None, unit_flag: str = "ns"):
    cmd = ["go", "tool", "pprof", "-top", "-nodecount=100", f"-unit={unit_flag}"]
    if sample_index:
        cmd.append(f"-sample_index={sample_index}")
    cmd.append(str(pprof_path))
    res = run(cmd)
    total = None
    rows = {}
    for line in res.stdout.splitlines():
        m_tot = re.search(r"Showing .*? of ([\d.]+)(ns|us|ms|s|B|kB|MB|GB)? total", line)
        if m_tot:
            total = to_base_unit(float(m_tot.group(1)), m_tot.group(2) or "")
            continue
        m = re.match(
            r"^\s*(\d+(?:\.\d+)?)(ns|us|ms|s|B|kB|MB|GB)?\s+[\d.]+%\s+[\d.]+%\s+(\d+(?:\.\d+)?)(ns|us|ms|s|B|kB|MB|GB)?\s+[\d.]+%\s+(.+?)\s*$",
            line,
        )
        if m:
            flat_val = to_base_unit(float(m.group(1)), m.group(2) or "")
            cum_val = to_base_unit(float(m.group(3)), m.group(4) or "")
            name = m.group(5).strip()
            if name.endswith("(inline)"):
                name = name[: -len("(inline)")].strip()
            rows[name] = (flat_val, cum_val)
    assert total is not None and total > 0, f"Could not parse total from go tool pprof:\n{res.stdout}"
    return total, rows


def run_moon_pprof(args, check=True):
    return run(["moon", "run", "--target", "wasm", "cmd/main", "--", *args], check=check)


def verify_single(pprof_path: Path, sample_type: str | None = None, unit_flag: str = "ns", expected_type: str = "cpu"):
    go_total, go_rows = parse_go_pprof_top(pprof_path, sample_index=sample_type, unit_flag=unit_flag)
    cli_args = ["top", str(pprof_path), "--limit", "100", "--format", "json"]
    if sample_type:
        cli_args.extend(["--sample-type", sample_type])
    res = run_moon_pprof(cli_args)
    report = json.loads(res.stdout.strip().splitlines()[-1])
    assert report["sample_type"] == expected_type, report
    assert int(report["total"]) == go_total, f"total mismatch: moon={report['total']} go={go_total}"

    moon_rows = {e["name"]: (int(e["flat"]), int(e["cum"])) for e in report["entries"]}
    checked = 0
    for fn_name, (g_flat, g_cum) in go_rows.items():
        if fn_name in moon_rows:
            m_flat, m_cum = moon_rows[fn_name]
            assert m_flat == g_flat and m_cum == g_cum, (
                f"{pprof_path.name} ({expected_type}) mismatch on {fn_name}: moon=({m_flat},{m_cum}) vs go=({g_flat},{g_cum})"
            )
            checked += 1
    assert checked >= 3, f"Expected at least 3 matched Go functions, got {checked}"
    print(f"[ORACLE OK] {pprof_path.name} ({expected_type}): total={go_total}{unit_flag}, exact 0-error match on {checked} functions")


def verify_merge_oracle(base_path: Path, cand_path: Path):
    moon_merged = OUT / "moon-merged-cpu.pb.gz"
    go_merged = OUT / "go-merged-cpu.pb.gz"
    run_moon_pprof(["merge", str(base_path), str(cand_path), "--out", str(moon_merged)])
    run(["go", "tool", "pprof", "-proto", f"-output={go_merged}", str(base_path), str(cand_path)])

    go_total, go_rows = parse_go_pprof_top(go_merged, unit_flag="ns")
    res = run_moon_pprof(["top", str(moon_merged), "--limit", "100", "--format", "json"])
    report = json.loads(res.stdout.strip().splitlines()[-1])
    assert int(report["total"]) == go_total, f"merge total mismatch: moon={report['total']} go={go_total}"
    moon_rows = {e["name"]: (int(e["flat"]), int(e["cum"])) for e in report["entries"]}
    checked = 0
    for fn_name, (g_flat, g_cum) in go_rows.items():
        if fn_name in moon_rows:
            assert moon_rows[fn_name] == (g_flat, g_cum), f"merge mismatch on {fn_name}"
            checked += 1
    assert checked >= 4
    print(f"[MERGE ORACLE OK] merged total={go_total}ns, exact 0-error match on {checked} functions against `go tool pprof -proto`")


def verify_diff(base_path: Path, cand_path: Path):
    fg_svg = OUT / "diff-flamegraph.svg"
    diff_html = OUT / "diff-report.html"
    diff_md = OUT / "diff-report.md"
    res = run_moon_pprof(
        [
            "diff",
            str(base_path),
            str(cand_path),
            "--hide",
            "runtime.",
            "--max-total-pct",
            "15",
            "--max-func-pct",
            "25",
            "--format",
            "json",
            "--flamegraph-out",
            str(fg_svg),
            "--html-out",
            str(diff_html),
        ],
        check=False,
    )
    assert res.returncode == 1, f"Expected CI regression exit code 1, got {res.returncode}\n{res.stdout}\n{res.stderr}"
    report = json.loads(res.stdout.strip().splitlines()[-1])
    assert report["gate"]["passed"] is False
    # Verify --hide runtime. removed runtime frames from diff entries
    assert all("runtime." not in e["name"] for e in report["entries"]), report["entries"]
    slow = [e for e in report["entries"] if "slowRegressionLoop" in e["name"]]
    assert slow and slow[0]["classification"] == "regressed", f"Expected slowRegressionLoop regressed: {report['entries']}"
    assert fg_svg.exists() and "Regressed (slower/larger)" in fg_svg.read_text(encoding="utf-8")
    assert diff_html.exists() and "slowRegressionLoop" in diff_html.read_text(encoding="utf-8")

    res_md = run_moon_pprof(
        ["diff", str(base_path), str(cand_path), "--max-total-pct", "15", "--format", "md", "--out", str(diff_md)],
        check=False,
    )
    assert res_md.returncode == 1 and diff_md.exists()
    print(
        f"[DIFF OK] total {report['baseline_total']}ns -> {report['candidate_total']}ns "
        f"(+{report['delta_total_pct']}%), slowRegressionLoop delta={slow[0]['delta_cum']}ns, gate exit=1"
    )


def verify_peek_and_callgraph(base_cpu: Path, cand_cpu: Path, cand_heap: Path):
    # Cross-check peek flat/cum and direct callers/callees against `go tool pprof -peek`
    go_res = run(["go", "tool", "pprof", "-peek=main.captureCPU", "-unit=ns", str(cand_cpu)])
    go_edges = {}
    for line in go_res.stdout.splitlines():
        m = re.match(r"^\s+(\d+(?:\.\d+)?)(ns|us|ms|s)\s+(\d+(?:\.\d+)?)(ns|us|ms|s)?\s+\|\s+(.+?)\s*$", line)
        if m:
            # go tool pprof -peek shows edge weight in the cum column for callers/callees
            w = to_base_unit(float(m.group(1)), m.group(2))
            go_edges[m.group(5).strip()] = w

    res = run_moon_pprof(["peek", str(cand_cpu), "--pattern", "main.captureCPU", "--format", "json"])
    peek = json.loads(res.stdout.strip().splitlines()[-1])
    assert len(peek["functions"]) == 1, peek
    fn = peek["functions"][0]
    assert fn["name"] == "main.captureCPU"
    assert int(fn["cum"]) == 490_000_000
    assert len(fn["callers"]) >= 1 and len(fn["callees"]) >= 1
    for edge in fn["callers"] + fn["callees"]:
        if edge["name"] in go_edges:
            assert int(edge["weight"]) == go_edges[edge["name"]], (
                f"peek edge mismatch on {edge['name']}: moon={edge['weight']} go={go_edges[edge['name']]}"
            )
    print(f"[PEEK ORACLE OK] main.captureCPU cum={fn['cum']}ns, callers={len(fn['callers'])}, callees={len(fn['callees'])}")

    # Verify callgraph SVG, DOT, and differential callgraph SVG
    cg_svg = OUT / "callgraph-cpu.svg"
    cg_dot = OUT / "callgraph-cpu.dot"
    dcg_svg = OUT / "diff-callgraph-cpu.svg"
    multi_html = OUT / "heap-all-metrics.html"
    run_moon_pprof(["callgraph", str(cand_cpu), "--format", "svg", "--out", str(cg_svg)])
    run_moon_pprof(["callgraph", str(cand_cpu), "--format", "dot", "--out", str(cg_dot)])
    run_moon_pprof(["callgraph", str(base_cpu), "--diff", str(cand_cpu), "--format", "svg", "--out", str(dcg_svg)])
    run_moon_pprof(["flamegraph", str(cand_heap), "--all-metrics", "--out", str(multi_html)])

    assert cg_svg.exists() and "main.captureCPU" in cg_svg.read_text(encoding="utf-8")
    assert cg_dot.exists() and "digraph \"moon-pprof\"" in cg_dot.read_text(encoding="utf-8")
    assert dcg_svg.exists() and "slowRegressionLoop" in dcg_svg.read_text(encoding="utf-8")
    mh_text = multi_html.read_text(encoding="utf-8")
    for metric in ("alloc_objects", "alloc_space", "inuse_objects", "inuse_space"):
        assert metric in mh_text, f"Missing metric {metric} in multi-metric HTML"
    assert "moon-pprof-cg-svg" in mh_text
    print("[CALLGRAPH & MULTI-METRIC OK] generated callgraph SVG/DOT, diff callgraph SVG, and 4-metric Heap HTML")


def verify_prune_list_and_dogfood(cand_cpu: Path, self_v8: Path):
    # Cross-check `moon-pprof prune --focus main.slowRegressionLoop` against `go tool pprof -proto -focus=main.slowRegressionLoop`
    moon_pruned = OUT / "moon-pruned-cpu.pb.gz"
    go_pruned = OUT / "go-pruned-cpu.pb.gz"
    run_moon_pprof(["prune", str(cand_cpu), "--focus", "main.slowRegressionLoop", "--out", str(moon_pruned)])
    run(["go", "tool", "pprof", "-proto", "-focus=main.slowRegressionLoop", f"-output={go_pruned}", str(cand_cpu)])

    go_total, go_rows = parse_go_pprof_top(go_pruned, unit_flag="ns")
    res = run_moon_pprof(["top", str(moon_pruned), "--limit", "100", "--format", "json"])
    report = json.loads(res.stdout.strip().splitlines()[-1])
    assert int(report["total"]) == go_total, f"prune total mismatch: moon={report['total']} go={go_total}"
    moon_rows = {e["name"]: (int(e["flat"]), int(e["cum"])) for e in report["entries"]}
    checked = 0
    for fn_name, (g_flat, g_cum) in go_rows.items():
        if fn_name in moon_rows:
            assert moon_rows[fn_name] == (g_flat, g_cum), f"prune mismatch on {fn_name}"
            checked += 1
    assert checked >= 2
    print(f"[PRUNE ORACLE OK] focused total={go_total}ns, exact 0-error match on {checked} functions against `go tool pprof -proto -focus`")

    # Verify `list` source-line hotspots + annotated Go source + `traces`
    list_res = run_moon_pprof(["list", str(cand_cpu), "--pattern", "slowRegressionLoop", "--format", "json"])
    list_report = json.loads(list_res.stdout.strip().splitlines()[-1])
    assert len(list_report["entries"]) >= 1 and int(list_report["entries"][0]["line"]) > 0
    annot_res = run_moon_pprof([
        "list", str(cand_cpu), "--pattern", "slowRegressionLoop",
        "--source-file", str(ROOT / "demo" / "gen_go_profiles.go"),
    ])
    assert "ROUTINE ========================" in annot_res.stdout and "slowRegressionLoop" in annot_res.stdout
    traces_res = run_moon_pprof(["traces", str(cand_cpu), "--limit", "10", "--format", "json"])
    traces_report = json.loads(traces_res.stdout.strip().splitlines()[-1])
    assert int(traces_report["total"]) == 490_000_000 and len(traces_report["traces"]) >= 1
    print(f"[LIST & TRACES OK] line hotspots={len(list_report['entries'])}, traces={len(traces_report['traces'])}")

    # Verify V8 .cpuprofile -> .pb.gz conversion (MoonBit Dogfooding) is readable by official `go tool pprof`!
    converted_gz = OUT / "moonbit-self-converted.pb.gz"
    run_moon_pprof(["convert", str(self_v8), "--from", "v8", "--out", str(converted_gz)])
    go_self_total, _ = parse_go_pprof_top(converted_gz, unit_flag="ns")
    moon_self_res = run_moon_pprof(["top", str(converted_gz), "--limit", "50", "--format", "json"])
    moon_self_report = json.loads(moon_self_res.stdout.strip().splitlines()[-1])
    assert int(moon_self_report["total"]) == go_self_total
    assert any("WireReader::read_varint" in e["name"] for e in moon_self_report["entries"])
    print(f"[V8 CPU -> PPROF INTEROP OK] MoonBit self-profile converted to .pb.gz and verified by `go tool pprof` (total={go_self_total}ns)")


def verify_v8_heap_trend_and_icicle(base_cpu: Path, cand_cpu: Path, self_heap: Path):
    # 1. V8 .heapprofile -> .pb.gz conversion cross-checked with 0 error against `go tool pprof`
    converted_heap_gz = OUT / "moonbit-self-heap.pb.gz"
    run_moon_pprof(["convert", str(self_heap), "--from", "v8-heap", "--out", str(converted_heap_gz)])
    go_heap_total, _ = parse_go_pprof_top(converted_heap_gz, sample_index="alloc_space", unit_flag="B")
    moon_heap_res = run_moon_pprof([
        "top", str(converted_heap_gz), "--sample-type", "alloc_space", "--limit", "50", "--format", "json",
    ])
    moon_heap_report = json.loads(moon_heap_res.stdout.strip().splitlines()[-1])
    assert int(moon_heap_report["total"]) == go_heap_total, (
        f"v8-heap total mismatch: moon={moon_heap_report['total']} go={go_heap_total}"
    )
    assert any("moon-pprof" in e["name"] or "flate" in e["name"] for e in moon_heap_report["entries"])
    print(f"[V8 HEAP -> PPROF INTEROP OK] MoonBit self-heap converted to .pb.gz and verified by `go tool pprof` (alloc_space={go_heap_total}B)")

    # 2. Multi-version trend inflection detection + SVG output + --fail-on-regression exit code
    trend_svg = OUT / "trend-cpu.svg"
    trend_res = run_moon_pprof([
        "trend",
        f"v1={base_cpu}",
        f"v2={base_cpu}",
        f"v3={cand_cpu}",
        "--top-k", "5",
        "--threshold-pct", "15",
        "--format", "json",
        "--fail-on-regression",
    ], check=False)
    assert trend_res.returncode == 1, f"Expected trend --fail-on-regression exit 1, got {trend_res.returncode}"
    trend_report = json.loads(trend_res.stdout.strip().splitlines()[-1])
    assert trend_report["totals"][0]["regressed"] is False
    assert trend_report["totals"][1]["regressed"] is False
    assert trend_report["totals"][2]["regressed"] is True
    assert len(trend_report["alerts"]) >= 2

    run_moon_pprof([
        "trend",
        f"v1={base_cpu}",
        f"v2={base_cpu}",
        f"v3={cand_cpu}",
        "--format", "svg",
        "--out", str(trend_svg),
    ])
    svg_text = trend_svg.read_text(encoding="utf-8")
    assert "moon-pprof-trend-svg" in svg_text and "trend-regressed" in svg_text

    # 3. Icicle (Top-Down) SVG layout verification
    icicle_svg = OUT / "icicle-cpu.svg"
    run_moon_pprof(["flamegraph", str(cand_cpu), "--icicle", "--out", str(icicle_svg)])
    icicle_text = icicle_svg.read_text(encoding="utf-8")
    assert 'data-layout="icicle"' in icicle_text and "slowRegressionLoop" in icicle_text
    print(f"[TREND & ICICLE OK] 3-version trend detected {len(trend_report['alerts'])} inflection alerts at v3 + valid trend & icicle SVGs")


def main():
    base_cpu = FIXTURES / "baseline-cpu.pb.gz"
    cand_cpu = FIXTURES / "candidate-cpu.pb.gz"
    base_heap = FIXTURES / "baseline-heap.pb.gz"
    cand_heap = FIXTURES / "candidate-heap.pb.gz"
    self_v8 = FIXTURES / "moonbit-self.cpuprofile"
    self_heap = FIXTURES / "moonbit-self.heapprofile"
    for p in (base_cpu, cand_cpu, base_heap, cand_heap, self_v8, self_heap):
        if not p.exists():
            raise SystemExit(f"Missing fixture {p}")
    verify_single(base_cpu, expected_type="cpu", unit_flag="ns")
    verify_single(cand_cpu, expected_type="cpu", unit_flag="ns")
    verify_single(base_heap, sample_type="alloc_space", expected_type="alloc_space", unit_flag="B")
    verify_single(cand_heap, sample_type="alloc_space", expected_type="alloc_space", unit_flag="B")
    verify_merge_oracle(base_cpu, cand_cpu)
    verify_diff(base_cpu, cand_cpu)
    verify_peek_and_callgraph(base_cpu, cand_cpu, cand_heap)
    verify_prune_list_and_dogfood(cand_cpu, self_v8)
    verify_v8_heap_trend_and_icicle(base_cpu, cand_cpu, self_heap)


if __name__ == "__main__":
    main()
