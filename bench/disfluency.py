#!/usr/bin/env python3
"""Fetch the DisfluencySpeech test split (a set made by other people) for bench/compare.py --sets disfluency.

    python3 bench/disfluency.py

DisfluencySpeech (Wang et al., 2024, arXiv 2406.08820; Apache-2.0; huggingface.co/datasets/amaai-lab/DisfluencySpeech)
is one human speaker reading Switchboard phone-call transcripts aloud with every "uh", repeat and restart kept in.
Each clip has transcript A (every word said) and transcript C (fillers, discourse markers, edit terms and restarts
removed), which are our "say" and "meant". We did not write it and never tuned rules on it.

The 250 test clips (about 70 MB) go to ~/work/scratch/larynx-bench/disfluency with a manifest.jsonl; nothing is
committed. Each clip is tagged by what its Switchboard annotation holds, the first that applies:
  restarts   a repair ("[ I want to, + I want this to ]")
  fillers    a filled pause ({F uh})
  discourse  a discourse marker or edit term ({D well}, {E I mean})
  none       nothing to remove
"""
import json, sys, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_sets import OUT  # noqa: E402

API = "https://datasets-server.huggingface.co/rows?dataset=amaai-lab/DisfluencySpeech&config=default&split=test"


def kind(annotated):
    if "[" in annotated:
        return "restarts"
    if "{F" in annotated:
        return "fillers"
    if "{D" in annotated or "{E" in annotated:
        return "discourse"
    return "none"


def main():
    d = OUT / "disfluency"
    d.mkdir(parents=True, exist_ok=True)
    rows = []
    for off in range(0, 250, 100):
        page = json.load(urllib.request.urlopen(f"{API}&offset={off}&length=100"))
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
