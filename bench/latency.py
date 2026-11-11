#!/usr/bin/env python3
"""Latency gate (PLAN-v1 B9): 50 clips through the full pipeline (speech model, your dictionary and vocabulary,
cleanup; AI-app mode, so no AI rewrite) in one `larynx serve`, timed from "audio in" to "text out", which is what
key-up to text costs. Writes bench/results/latency-<date>-<commit>.json and exits 1 if invariant 2 is broken
(p50 > 150 ms or p90 > 350 ms). Run before every release.

    python3 bench/latency.py [--engine ultra] [--clips 50]
"""
import argparse, datetime, json, os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = Path.home() / "work/scratch/larynx-bench"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="ultra")
    ap.add_argument("--clips", type=int, default=50)
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--models-dir", default=str(Path.home() / "Library/Application Support/Larynx/models"))
    a = ap.parse_args()
    clips = []
    for s in ["jargon", "noise10", "ls-other"]:
        f = DATA / s / "manifest.jsonl"
        if f.exists(): clips += [json.loads(l)["audio"] for l in f.read_text().splitlines()][: a.clips // 3 + 1]
    clips = clips[: a.clips]
    if not clips: sys.exit(f"no benchmark audio in {DATA} (bench/make_sets.py)")
    p = subprocess.Popen([a.binary, "serve", "--engine", a.engine, "--models-dir", a.models_dir], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    while json.loads(p.stdout.readline()).get("event") != "ready": pass
    ms = []
    for i, c in enumerate([clips[0]] + clips):  # the first one warms caches and is not counted
        p.stdin.write(json.dumps({"cmd": "transcribe", "path": c, "mode": "ai", "id": i}) + "\n")
        while True:
            m = json.loads(p.stdout.readline())
            if m.get("id") == i: break
        if i > 0 and m.get("event") == "result": ms.append(m["totalMs"])
    p.stdin.write('{"cmd":"quit"}\n'); p.wait(timeout=10)
    s = sorted(ms)
    p50, p90 = s[len(s) // 2], s[int(len(s) * 0.9)]
    ok = p50 <= 150 and p90 <= 350
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    out = ROOT / f"bench/results/latency-{datetime.date.today().isoformat()}-{commit}.json"
    out.write_text(json.dumps({"engine": a.engine, "clips": len(ms), "p50ms": p50, "p90ms": p90, "maxms": s[-1], "pass": ok}, indent=2))
    print(f"{a.engine}: {len(ms)} clips, p50 {p50} ms, p90 {p90} ms, max {s[-1]} ms -> {'PASS' if ok else 'FAIL (invariant 2: p50 <= 150, p90 <= 350)'}")
    print("wrote", out)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
