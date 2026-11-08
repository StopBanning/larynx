#!/usr/bin/env python3
"""Larynx cleanup test suite.

Text cases run straight through `larynx tidy`. Spoken cases are synthesized with macOS `say`
in several voices and speeds, transcribed by one `larynx serve` process, and scored.

    python3 tests/suite.py                      # full run
    python3 tests/suite.py --voices Samantha --rates 175 --only filler
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILLERS = {"um", "uh", "uhm", "umm", "uhh", "er", "erm", "hmm", "hm"}


def norm(text):
    text = text.lower().replace("-", " ")
    text = re.sub(r"[^\w\s']", " ", text)
    return text.split()


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    if not r:
        return 0.0 if not h else 1.0
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hw in enumerate(h, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
            prev, d[j] = d[j], cur
    return d[len(h)] / len(r)


def judge(case, out):
    words = norm(out)
    left = [w for w in words if w in FILLERS and w not in norm(case["expect"])]
    joined = " ".join(words)
    missing = [k for k in case.get("keep", []) if " ".join(norm(k)) not in joined]
    error = wer(case["expect"], out)
    limit = 1.0 if case.get("loose") else 0.15
    ok = not left and not missing and error <= limit
    # Blame: if the speech model's own raw transcript already lost a must-keep word, it's a hearing error, not cleanup.
    raw_joined = " ".join(norm(case.get("_raw", "")))
    if not ok and missing and all(" ".join(norm(k)) not in raw_joined for k in missing):
        return ok, error, "speech model misheard: " + str(missing)
    why = []
    if left: why.append(f"fillers left: {left}")
    if missing: why.append(f"lost: {missing}")
    if error > limit: why.append(f"WER {error:.2f}")
    return ok, error, "; ".join(why)


def run_text(binary, cases, only):
    rows = []
    for c in cases:
        if only and only not in c["id"]:
            continue
        out = subprocess.run([binary, "tidy", "--mode", c["mode"], c["in"]], capture_output=True, text=True).stdout.rstrip("\n")
        rows.append((c, out, out == c["expect"]))
    return rows


def run_spoken(binary, cases, voices, rates, engine, models, only, workdir):
    jobs = []
    for c in cases:
        if only and only not in c["id"]:
            continue
        for v in voices:
            for r in rates:
                path = workdir / f"{c['id']}__{v}__{r}.aiff"
                subprocess.run(["say", "-v", v, "-r", str(r), "-o", str(path), c["say"]], check=True)
                jobs.append((c, v, r, path))
    cmd = [binary, "serve", "--engine", engine] + (["--models-dir", models] if models else [])
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for i, (_, _, _, path) in enumerate(jobs):
        proc.stdin.write(json.dumps({"id": i, "cmd": "transcribe", "path": str(path), "mode": "standard"}) + "\n")
    proc.stdin.write(json.dumps({"cmd": "quit"}) + "\n")
    proc.stdin.flush()
    results = {}
    for line in proc.stdout:
        msg = json.loads(line)
        if msg.get("event") in ("result", "error") and "id" in msg:
            results[msg["id"]] = msg
        if len(results) == len(jobs):
            break
    proc.wait(timeout=30)
    rows = []
    for i, (c, v, r, _) in enumerate(jobs):
        msg = results.get(i, {})
        out = msg.get("text", f"<error: {msg.get('message', 'no reply')}>")
        ok, error, why = judge(dict(c, _raw=msg.get("raw", "")), out)
        rows.append({"case": c, "voice": v, "rate": r, "out": out, "raw": msg.get("raw", ""), "ok": ok, "wer": error, "why": why, "ms": msg.get("asrMs", 0)})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--voices", default="Samantha,Daniel,Karen,Rishi,Moira")
    ap.add_argument("--rates", default="175,230")
    ap.add_argument("--engine", default="clean")
    ap.add_argument("--models-dir", default=os.path.expanduser("~/Library/Application Support/Larynx/models"))
    ap.add_argument("--only", default="")
    ap.add_argument("--json", help="write every result to this file")
    a = ap.parse_args()
    data = json.loads((ROOT / "tests/cases.json").read_text())

    text_rows = run_text(a.binary, data["text"], a.only)
    passed = sum(ok for _, _, ok in text_rows)
    print(f"\nTEXT RULES  {passed}/{len(text_rows)} exact")
    for c, out, ok in text_rows:
        if not ok:
            print(f"  FAIL {c['id']}: {c['in']!r} -> {out!r} (want {c['expect']!r})")

    with tempfile.TemporaryDirectory(dir=os.path.expanduser("~/work/scratch")) as tmp:
        rows = run_spoken(a.binary, data["spoken"], a.voices.split(","), [int(r) for r in a.rates.split(",")],
                          a.engine, a.models_dir, a.only, Path(tmp))

    by_cat = defaultdict(lambda: [0, 0])
    gaps = defaultdict(lambda: [0, 0])
    for row in rows:
        bucket = gaps if row["case"].get("gap") else by_cat
        bucket[row["case"]["cat"]][0] += row["ok"]
        bucket[row["case"]["cat"]][1] += 1
    core = [r for r in rows if not r["case"].get("gap")]
    print(f"\nSPOKEN ({a.engine}, {len(a.voices.split(','))} voices x {len(a.rates.split(','))} speeds)  "
          f"{sum(r['ok'] for r in core)}/{len(core)} pass, excluding known gaps")
    for cat, (ok, n) in sorted(by_cat.items()):
        print(f"  {cat:<18} {ok:>3}/{n}")
    if gaps:
        print("  known gaps (need the AI rewrite layer):")
        for cat, (ok, n) in sorted(gaps.items()):
            print(f"    {cat:<16} {ok:>3}/{n}")

    heard = [r for r in core if not r["ok"] and r["why"].startswith("speech model")]
    if heard:
        print(f"  of the failures, {len(heard)} are the speech model mishearing (not cleanup)")
    fails = defaultdict(list)
    for r in core:
        if not r["ok"]:
            fails[r["case"]["id"]].append(r)
    if fails:
        print("\nFAILURES (case: voice/speed -> output)")
        for cid, rs in fails.items():
            print(f"  {cid}  ({len(rs)} of {sum(1 for x in core if x['case']['id'] == cid)})  want: {rs[0]['case']['expect']}")
            for r in rs[:3]:
                print(f"     {r['voice']}/{r['rate']}: {r['out']}   [{r['why']}]   raw: {r['raw']}")
    if a.json:
        Path(a.json).write_text(json.dumps([{k: v for k, v in r.items() if k != 'case'} | {"id": r["case"]["id"]} for r in rows], indent=1))
    return 0 if passed == len(text_rows) and not fails else 1


if __name__ == "__main__":
    sys.exit(main())
