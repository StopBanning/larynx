#!/usr/bin/env python3
"""Replay the tidy stage over every dictation in your history with two builds and print each line that changes.
Use it before shipping any text rule (HANDOFF: "run it over his real dictations and read every line").

    cp .build/release/larynx /tmp/larynx-old      # before the change
    swift build -c release                         # after the change
    python3 tests/replay.py --old /tmp/larynx-old [--new .build/release/larynx]

Prints your own words: terminal only, never into the repo.
"""
import argparse, json, subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def tidy(binary, text, mode):
    return subprocess.run([binary, "tidy", "--mode", mode, text], capture_output=True, text=True).stdout.rstrip("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--new", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--limit", type=int, default=5000)
    a = ap.parse_args()
    rows = json.loads(subprocess.run([a.new, "history", "--json", "--limit", str(a.limit)], capture_output=True,
                                     text=True, check=True).stdout)
    jobs = []
    for r in rows:
        step = next((s for s in r.get("steps", []) if s.get("stage") == "tidy"), None)
        jobs.append(((step or {}).get("before") or r["raw"], r.get("mode") or "standard"))
    with ThreadPoolExecutor(8) as ex:
        old = list(ex.map(lambda j: tidy(a.old, *j), jobs))
        new = list(ex.map(lambda j: tidy(a.new, *j), jobs))
    changed = 0
    for (text, mode), o, n in zip(jobs, old, new):
        if o != n:
            changed += 1
            print(f"[{mode}]\n   in:  {text}\n   old: {o}\n   new: {n}")
    print(f"\n{changed} of {len(jobs)} dictations change")


if __name__ == "__main__":
    main()
