#!/usr/bin/env python3
"""Larynx against what a Mac already has (PLAN-launch L0.5), on the same audio.

    python3 bench/compare.py [--binary path] [--limit N]

Systems:
  larynx      the full Larynx pipeline (Parakeet Ultra, cleanup rules; AI rewrite off, so it is the same on every Mac)
  larynx-raw  the same speech model with no cleanup (verbatim)
  apple       Apple's on-device SpeechTranscriber (macOS 26 Speech framework). This is the speech API apps can call;
              it is not the same as the Dictation button on the keyboard, whose model was not installed here.

Sets:
  messy   bench/messy.json: 40 sentences with fillers, stutters, false starts and spoken numbers, said by three macOS
          voices. Scored on edits needed: the words a person would still change to get from the output to what was
          meant. Written after the rules and never used to tune them.
  jargon  the bench's jargon set (bench/make_sets.py), scored on word errors against the words said.

Audio lives in ~/work/scratch/larynx-bench (never in git). Results go to bench/results/compare-<date>.json and a
Markdown table is printed for docs/BENCHMARKS.md.
"""
import argparse, json, re, subprocess, sys, tempfile, time
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from make_sets import say, OUT  # noqa: E402
from run import Engine, norm, spoken, edits  # noqa: E402

VOICES = ["Samantha", "Daniel", "Karen"]
MODELS = Path.home() / "Library/Application Support/Larynx/models"


def words(text):
    text = re.sub(r"(?<=\d),(?=\d{3})", "", text)  # "1,400" and "1400" are the same number
    return spoken(norm(text))


def messy_clips(limit):
    data = json.loads((ROOT / "messy.json").read_text())["sentences"][:limit or None]
    d = OUT / "messy"
    d.mkdir(parents=True, exist_ok=True)
    rows = []
    for i, s in enumerate(data):
        for v in VOICES:
            p = d / f"{i:02d}-{v}.wav"
            if not p.exists():
                say(s["say"], v, p)
            rows.append({"audio": str(p), "say": s["say"], "meant": s["meant"], "cat": s["cat"], "voice": v})
    return rows


def jargon_clips(limit):
    f = OUT / "jargon/manifest.jsonl"
    if not f.exists():
        return []
    rows = [json.loads(l) for l in f.read_text().splitlines()]
    return rows[: limit * 3] if limit else rows


def apple(paths):
    exe = Path(tempfile.gettempdir()) / "larynx-apple-transcribe"
    src = ROOT / "apple_transcribe.swift"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-parse-as-library", "-O", str(src), "-o", str(exe)], check=True)
    out = {}
    for i in range(0, len(paths), 20):
        r = subprocess.run([str(exe), *paths[i:i + 20]], capture_output=True, text=True, timeout=600)
        for line in r.stdout.splitlines():
            path, _, text = line.partition("\t")
            out[path] = None if text.startswith("ERROR:") else text
    return out


def larynx(binary, paths, verbatim):
    e = Engine(binary, "ultra", str(MODELS))
    try:
        out = {}
        for p in paths:
            r = e.transcribe(p, verbatim=verbatim, mode=None if verbatim else "correspondence")
            out[p] = r.get("text", "") if r.get("event") == "result" else None
        return out
    finally:
        e.close()


def score(rows, outputs, ref_key):
    total_ref = total_edits = failed = 0
    per_cat = {}
    for r in rows:
        hyp = outputs.get(r["audio"])
        ref = words(r[ref_key])
        if hyp is None:
            failed += 1
            continue
        e = edits(ref, words(hyp))
        total_ref += len(ref)
        total_edits += e
        c = per_cat.setdefault(r.get("cat", "all"), [0, 0])
        c[0] += e
        c[1] += len(ref)
    pct = lambda e, n: round(100 * e / n, 2) if n else None
    return {"rate": pct(total_edits, total_ref), "edits": total_edits, "words": total_ref, "failed": failed,
            "by_category": {k: pct(*v) for k, v in per_cat.items()}}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=str(ROOT.parent / ".build/release/larynx"))
    ap.add_argument("--limit", type=int, default=0, help="first N sentences of each set (for a quick run)")
    a = ap.parse_args()

    sets = {"messy": (messy_clips(a.limit), "meant"), "jargon": (jargon_clips(a.limit), "text")}
    results = {"date": date.today().isoformat(), "systems": {}}
    for name, run in (("larynx", lambda p: larynx(a.binary, p, False)),
                      ("larynx-raw", lambda p: larynx(a.binary, p, True)),
                      ("apple", apple)):
        results["systems"][name] = {}
        for set_name, (rows, ref_key) in sets.items():
            if not rows:
                continue
            started = time.time()
            outputs = run([r["audio"] for r in rows])
            s = score(rows, outputs, ref_key)
            s["seconds"] = round(time.time() - started, 1)
            results["systems"][name][set_name] = s
            print(f"{name:10} {set_name:7} {s['rate']}% ({s['edits']}/{s['words']}, {s['failed']} failed)", file=sys.stderr)
            if set_name == "messy":
                results["systems"][name]["messy_outputs"] = {r["audio"].rsplit("/", 1)[-1]: outputs.get(r["audio"]) for r in rows}

    out = ROOT / "results" / f"compare-{results['date']}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(results, indent=1))
    cats = ["fillers", "stutters", "false starts", "numbers", "mixed"]
    print("| System | Messy: edits needed | " + " | ".join(cats) + " | Jargon: word errors |")
    print("| --- | --- | " + " | ".join("---" for _ in cats) + " | --- |")
    for name, r in results["systems"].items():
        m, j = r.get("messy", {}), r.get("jargon", {})
        print(f"| {name} | {m.get('rate')}% | " + " | ".join(f"{m.get('by_category', {}).get(c)}%" for c in cats)
              + f" | {j.get('rate')}% |")
    print(f"\nwrote {out.relative_to(ROOT.parent)}", file=sys.stderr)


if __name__ == "__main__":
    main()
