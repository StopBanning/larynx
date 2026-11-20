#!/usr/bin/env python3
"""Fetch a DisfluencySpeech split (a set made by other people) for bench/compare.py.

    python3 bench/disfluency.py                     # the test split   -> --sets disfluency
    python3 bench/disfluency.py --split validation  # held out         -> --sets disfluency-validation

DisfluencySpeech (Wang et al., 2024, arXiv 2406.08820; Apache-2.0; huggingface.co/datasets/amaai-lab/DisfluencySpeech)
is one human speaker reading Switchboard phone-call transcripts aloud with every "uh", repeat and restart kept in.
Each clip has transcript A (every word said) and transcript C (fillers, discourse markers, edit terms and restarts
removed), which are our "say" and "meant". We did not write it. The test split was first run on Nov 18 and rules were then tuned on its misses (Nov 19),
so it is no longer held out. The validation split (250 more clips) was first run on Nov 19, after that tuning,
and nothing is tuned on it.

The 250 clips of a split (about 70 MB) go to ~/work/scratch/larynx-bench/disfluency (or disfluency-<split>) with a manifest.jsonl; nothing is
committed. Each clip is tagged by what its Switchboard annotation holds, the first that applies:
  restarts   a repair ("[ I want to, + I want this to ]")
  fillers    a filled pause ({F uh})
  discourse  a discourse marker or edit term ({D well}, {E I mean})
  none       nothing to remove
"""
import argparse, json, sys, time, urllib.error, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_sets import OUT  # noqa: E402

API = "https://datasets-server.huggingface.co/rows?dataset=amaai-lab/DisfluencySpeech&config=default&split="


def fetch_json(url, tries=5):
    """The rows API sometimes answers 502 for a moment; wait and try again."""
    for n in range(tries):
        try:
            return json.load(urllib.request.urlopen(url, timeout=60))
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            if n == tries - 1:
                raise
            print(f"retrying after {e}", file=sys.stderr)
            time.sleep(5 * (n + 1))


def kind(annotated):
    if "[" in annotated:
        return "restarts"
    if "{F" in annotated:
        return "fillers"
    if "{D" in annotated or "{E" in annotated:
        return "discourse"
    return "none"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="test", choices=["test", "validation"])
    split = ap.parse_args().split
    d = OUT / ("disfluency" if split == "test" else f"disfluency-{split}")
    d.mkdir(parents=True, exist_ok=True)
    rows = []
    for off in range(0, 250, 100):
        page = fetch_json(f"{API}{split}&offset={off}&length=100")
        for r in page["rows"]:
            i, row = r["row_idx"], r["row"]
            p = d / f"{i:03d}.wav"
            if not p.exists():
                urllib.request.urlretrieve(row["audio"][0]["src"], p)
            rows.append({"audio": str(p), "say": row["transcript_a"], "meant": row["transcript_c"],
                         "cat": kind(row["transcript_annotated"])})
    (d / "manifest.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{len(rows)} clips in {d}")


if __name__ == "__main__":
    main()
