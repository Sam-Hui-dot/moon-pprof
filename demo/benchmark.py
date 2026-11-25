"""Generate synthetic large-scale .pb.gz profiles (10k / 50k / 100k samples) and benchmark moon-pprof across Native, Wasm, and JS."""
import base64
import gzip
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "demo" / "out" / "bench"
OUT.mkdir(parents=True, exist_ok=True)


def encode_varint(n: int) -> bytes:
    buf = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            buf.append(b | 0x80)
        else:
            buf.append(b)
            break
    return bytes(buf)


def pb_field_varint(num: int, val: int) -> bytes:
    return encode_varint((num << 3) | 0) + encode_varint(val)


def pb_field_bytes(num: int, data: bytes) -> bytes:
    return encode_varint((num << 3) | 2) + encode_varint(len(data)) + data


def generate_large_pprof(path: Path, sample_count: int, func_count: int = 500) -> int:
    strings = ["", "cpu", "nanoseconds"]
    for i in range(func_count):
        strings.append(f"svc/pkg{i % 20}.Worker{i // 20}.Handle{i}")
        strings.append(f"pkg{i % 20}/worker_{i // 20}.go")

    out = bytearray()
    # sample_type (field 1): cpu / nanoseconds
    st_msg = pb_field_varint(1, 1) + pb_field_varint(2, 2)
    out += pb_field_bytes(1, st_msg)

    # functions (field 5) and locations (field 4)
    for i in range(func_count):
        fid = i + 1
        name_idx = 3 + i * 2
        file_idx = 4 + i * 2
        fmsg = (
            pb_field_varint(1, fid)
            + pb_field_varint(2, name_idx)
            + pb_field_varint(3, name_idx)
            + pb_field_varint(4, file_idx)
            + pb_field_varint(5, (i % 80) + 1)
        )
        out += pb_field_bytes(5, fmsg)

        line_msg = pb_field_varint(1, fid) + pb_field_varint(2, (i % 80) + 5)
        lmsg = (
            pb_field_varint(1, fid)
            + pb_field_varint(3, 0x400000 + fid * 16)
            + pb_field_bytes(4, line_msg)
        )
        out += pb_field_bytes(4, lmsg)

    # samples (field 2): realistic 6-frame call stacks with pseudo-random skew
    state = 0x9E3779B9
    for _ in range(sample_count):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        leaf = 1 + (state % func_count)
        mid1 = 1 + ((state >> 7) % (func_count // 4))
        mid2 = 1 + ((state >> 13) % (func_count // 10))
        mid3 = 1 + ((state >> 19) % 20)
        root = 1 + ((state >> 24) % 4)
        # packed location_id (field 1) and value (field 2)
        lids = b"".join(encode_varint(x) for x in (leaf, mid1, mid2, mid3, root))
        vals = encode_varint(10_000 + (state % 50_000))
        smsg = pb_field_bytes(1, lids) + pb_field_bytes(2, vals)
        out += pb_field_bytes(2, smsg)

    # string_table (field 6)
    for s in strings:
        out += pb_field_bytes(6, s.encode("utf-8"))

    # default_sample_type (field 14)
    out += pb_field_varint(14, 1)

    gz_bytes = gzip.compress(bytes(out), compresslevel=6)
    path.write_bytes(gz_bytes)
    return len(gz_bytes)


def bench_cmd(cmd: list[str]) -> float:
    t0 = time.perf_counter()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if res.returncode != 0:
        raise RuntimeError(f"Bench command failed: {cmd}\n{res.stdout}\n{res.stderr}")
    return elapsed_ms


def bench_js_in_process(pb_gz_path: Path) -> dict:
    b64 = base64.b64encode(pb_gz_path.read_bytes()).decode("ascii")
    tmp_b64 = OUT / (pb_gz_path.stem + ".b64")
    tmp_b64.write_text(b64, encoding="ascii")
    script = (
        "const fs=require('fs');\n"
        "require('./docs/moon-pprof.js');\n"
        f"const b64=fs.readFileSync({json.dumps(str(tmp_b64))},'ascii');\n"
        "const t0=performance.now();\n"
        "const res=globalThis.MoonPprof.analyzeProfile(b64,{maxNodes:30});\n"
        "const ms=performance.now()-t0;\n"
        "if(!res.ok) throw new Error(res.error);\n"
        "console.log(JSON.stringify({js_full_ms: +ms.toFixed(1), fg_kb: +(res.flamegraph_svg.length/1024).toFixed(1), cg_kb: +(res.callgraph_svg.length/1024).toFixed(1)}));\n"
    )
    res = subprocess.run(["node", "-e", script], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=True)
    return json.loads(res.stdout.strip().splitlines()[-1])


def main() -> None:
    quick = "--quick" in sys.argv
    sizes = [10_000] if quick else [10_000, 50_000, 100_000]

    # Build native release CLI binary once so we benchmark pure binary execution, not moon compilation!
    subprocess.run(["moon", "build", "--target", "native", "--release", "cmd/main"], cwd=ROOT, check=True)
    native_dir = ROOT / "_build" / "native" / "release" / "build" / "cmd" / "main"
    native_exe = native_dir / "main.exe"
    if not native_exe.exists():
        native_exe = native_dir / "main"
    if not native_exe.exists():
        raise FileNotFoundError(f"Native release binary not found under: {native_dir}")

    rows = []
    for n in sizes:
        pb_path = OUT / f"bench-{n}.pb.gz"
        gz_bytes = generate_large_pprof(pb_path, n, func_count=500)
        # Warmup once on 10k
        if n == sizes[0]:
            bench_cmd([str(native_exe), "top", str(pb_path), "--limit", "10"])

        nat_top_ms = bench_cmd([str(native_exe), "top", str(pb_path), "--limit", "20", "--out", str(OUT / f"top-{n}.txt")])
        nat_fg_ms = bench_cmd([str(native_exe), "flamegraph", str(pb_path), "--out", str(OUT / f"fg-{n}.svg")])
        nat_cg_ms = bench_cmd([str(native_exe), "callgraph", str(pb_path), "--out", str(OUT / f"cg-{n}.svg")])
        nat_prune_ms = bench_cmd([str(native_exe), "prune", str(pb_path), "--focus", "pkg0", "--out", str(OUT / f"pruned-{n}.pb.gz")])
        js_stats = bench_js_in_process(pb_path)

        row = {
            "samples": n,
            "functions": 500,
            "gz_kb": round(gz_bytes / 1024.0, 1),
            "native_top_ms": round(nat_top_ms, 1),
            "native_fg_ms": round(nat_fg_ms, 1),
            "native_cg_ms": round(nat_cg_ms, 1),
            "native_prune_ms": round(nat_prune_ms, 1),
            "js_full_ms": js_stats["js_full_ms"],
        }
        rows.append(row)
        print(
            f"[BENCH {n:>6} samples | {row['gz_kb']:>6.1f} KB .pb.gz] "
            f"Native top={row['native_top_ms']}ms | fg={row['native_fg_ms']}ms | "
            f"cg={row['native_cg_ms']}ms | prune={row['native_prune_ms']}ms | "
            f"JS(all-in-one)={row['js_full_ms']}ms"
        )

    (OUT / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
