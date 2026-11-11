#!/usr/bin/env python3
"""Real-voice check (PLAN-v1 A1): run every kept recording of your own dictations through several engines and count
how often each engine is the odd one out, i.e. it disagrees while all the others agree with each other.

    python3 bench/realvoice.py                     # counts only (safe to paste anywhere)
    python3 bench/realvoice.py --show              # also print each disagreement (your words: terminal only)
    python3 bench/realvoice.py --engines ultra,clean,unified,parakeet --limit 50

Audio comes from history (`keepAudio` in settings.json). Engines run verbatim with vocabulary and rewrite off, so
this compares the speech models only. Nothing is written to disk.
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import Engine, norm, edits  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engines", default="ultra,clean,unified,parakeet")
    ap.add_argument("--limit", type=int, default=0, help="newest N recordings (0 = all)")
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--models-dir", default=str(Path.home() / "Library/Application Support/Larynx/models"))
    ap.add_argument("--show", action="store_true")
    a = ap.parse_args()
    engines = a.engines.split(",")
    rows = json.loads(subprocess.run([a.binary, "history", "--json", "--limit", "5000"], capture_output=True,
                                     text=True, check=True).stdout)
    rows = [r for r in rows if r.get("audioPath") and os.path.exists(r["audioPath"])]
    if a.limit: rows = rows[:a.limit]
    if not rows: sys.exit("No kept recordings (set keepAudio in settings.json).")
    print(f"{len(rows)} recordings, {sum(r.get('audioSeconds') or 0 for r in rows):.0f} s of audio", flush=True)
    out = {}
    for e in engines:
        eng = Engine(a.binary, e, a.models_dir)
        out[e] = [(eng.transcribe(r["audioPath"]).get("text") or "") for r in rows]
        eng.close()
        print(f"   {e} done", flush=True)
    odd = {e: 0 for e in engines}
    dist = {e: 0 for e in engines}  # word edits against the majority of the others
    words = 0
    all_agree = 0
    for i, r in enumerate(rows):
        n = {e: norm(out[e][i]) for e in engines}
        if len({tuple(v) for v in n.values()}) == 1: all_agree += 1
        for e in engines:
            others = [tuple(n[o]) for o in engines if o != e]
            if len(set(others)) == 1:
                d = edits(list(others[0]), n[e])
                dist[e] += d
                if d:
                    odd[e] += 1
                    if a.show: print(f"\n[{r['id']}] {e} is the odd one out\n   {e}: {out[e][i]}\n   others: {' '.join(others[0])}")
        words += len(n[engines[0]])
    print(f"\nall engines agree: {all_agree}/{len(rows)}   words: {words}")
    print(f"{'engine':10} {'odd one out':>12} {'words off':>10}")
    for e in engines: print(f"{e:10} {odd[e]:>12} {dist[e]:>10}")


if __name__ == "__main__":
    main()
