"""Cross-check moon-pprof against official `go tool pprof` on real Go .pb.gz profiles."""
import json
import re
import subprocess
import sys
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


def parse_go_pprof_top_ns(pprof_path: Path):
    # `go tool pprof -top -nodecount=100 -unit=ns` prints exact nanoseconds (with optional 'ns' suffix).
    res = run(["go", "tool", "pprof", "-top", "-nodecount=100", "-unit=ns", str(pprof_path)])
    total = None
    rows = {}
    for line in res.stdout.splitlines():
        m_tot = re.search(r"Showing top .*? of (\d+)ns total", line)
        if m_tot:
            total = int(m_tot.group(1))
            continue
        # Format: flat  flat%  sum%  cum  cum%  Name
        m = re.match(
            r"^\s*(\d+(?:\.\d+)?)(ns|us|ms|s)?\s+[\d.]+%\s+[\d.]+%\s+(\d+(?:\.\d+)?)(ns|us|ms|s)?\s+[\d.]+%\s+(.+?)\s*$",
            line,
        )
        if m:
            flat_val = to_ns(float(m.group(1)), m.group(2) or "ns")
            cum_val = to_ns(float(m.group(3)), m.group(4) or "ns")
            name = m.group(5).strip()
            if name.endswith("(inline)"):
                name = name[: -len("(inline)")].strip()
            rows[name] = (flat_val, cum_val)
    if total is None:
        # Handle zero-prefix or scaled total line
        m_tot2 = re.search(r"Showing .*? of ([\d.]+)(ns|us|ms|s) total", res.stdout)
        if m_tot2:
            total = to_ns(float(m_tot2.group(1)), m_tot2.group(2))
    assert total is not None and total > 0, f"Could not parse total from go tool pprof:\n{res.stdout}"
    return total, rows


def to_ns(val: float, unit: str) -> int:
    mult = {"ns": 1, "us": 1_000, "ms": 1_000_000, "s": 1_000_000_000}[unit]
    return int(round(val * mult))


def run_moon_pprof(args, check=True):
    return run(["moon", "run", "--target", "wasm", "cmd/main", "--", *args], check=check)


def verify_single(pprof_path: Path):
    go_total, go_rows = parse_go_pprof_top_ns(pprof_path)
    res = run_moon_pprof(["top", str(pprof_path), "--limit", "100", "--format", "json"])
    report = json.loads(res.stdout.strip().splitlines()[-1])
    assert report["sample_type"] == "cpu", report
    assert report["unit"] == "nanoseconds", report
    assert int(report["total"]) == go_total, f"total mismatch: moon={report['total']} go={go_total}"

    moon_rows = {e["name"]: (int(e["flat"]), int(e["cum"])) for e in report["entries"]}
    checked = 0
    for fn_name, (g_flat, g_cum) in go_rows.items():
        if fn_name in moon_rows:
            m_flat, m_cum = moon_rows[fn_name]
            assert m_flat == g_flat and m_cum == g_cum, (
                f"{pprof_path.name} mismatch on {fn_name}: moon=({m_flat},{m_cum}) vs go=({g_flat},{g_cum})"
            )
            checked += 1
    assert checked >= 3, f"Expected at least 3 matched Go functions, got {checked}"
    print(f"[ORACLE OK] {pprof_path.name}: total={go_total}ns, exact 0-error match on {checked} functions")


def verify_diff(base_path: Path, cand_path: Path):
    fg_svg = OUT / "diff-flamegraph.svg"
    diff_html = OUT / "diff-report.html"
    diff_md = OUT / "diff-report.md"
    res = run_moon_pprof(
        [
            "diff",
            str(base_path),
            str(cand_path),
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
    slow = [e for e in report["entries"] if "slowRegressionLoop" in e["name"]]
    assert slow and slow[0]["classification"] == "regressed", f"Expected slowRegressionLoop regressed: {report['entries']}"
    assert fg_svg.exists() and "Regressed (slower/larger)" in fg_svg.read_text(encoding="utf-8")
    assert diff_html.exists() and "slowRegressionLoop" in diff_html.read_text(encoding="utf-8")

    # Also verify Markdown output for CI Step Summary
    res_md = run_moon_pprof(
        ["diff", str(base_path), str(cand_path), "--max-total-pct", "15", "--format", "md", "--out", str(diff_md)],
        check=False,
    )
    assert res_md.returncode == 1 and diff_md.exists()
    print(
        f"[DIFF OK] total {report['baseline_total']}ns -> {report['candidate_total']}ns "
        f"(+{report['delta_total_pct']}%), slowRegressionLoop delta={slow[0]['delta_cum']}ns, gate exit=1"
    )


def main():
    base = FIXTURES / "baseline-cpu.pb.gz"
    cand = FIXTURES / "candidate-cpu.pb.gz"
    if not base.exists() or not cand.exists():
        raise SystemExit(f"Missing fixtures in {FIXTURES}; run `go run demo/gen_go_profiles.go` first.")
    verify_single(base)
    verify_single(cand)
    verify_diff(base, cand)


if __name__ == "__main__":
    main()
