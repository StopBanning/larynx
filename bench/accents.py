#!/usr/bin/env python3
"""The accents set: real conversational English from speakers of many first languages.

    python3 bench/accents.py [--per-accent 6] [--max 300]

Takes a seeded sample of the EdAcc test split (Edinburgh International Accents of English Corpus, CC BY-SA 4.0,
huggingface.co/datasets/edinburghcstr/edacc): up to --per-accent clips per accent label, clips of 6 to 40 words, so
every accent is represented rather than the most common few. Downloads only those clips through the Hugging Face
datasets server into ~/work/scratch/larynx-bench/accents (never in git) and writes manifest.jsonl there with the
reference text, accent and first language. bench/compare.py scores it on word errors.

The same seed gives the same clips on every run. Audio is converted to 16 kHz mono WAV.
"""
import argparse, json, random, re, subprocess, time, urllib.error, urllib.request
from pathlib import Path

API = "https://datasets-server.huggingface.co/rows?dataset=edinburghcstr/edacc&config=default&split=test"
OUT = Path.home() / "work/scratch/larynx-bench/accents"


def get(url, tries=8):
    for i in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "larynx-bench"}), timeout=60) as r:
                return r.read()
        except urllib.error.HTTPError as e:  # 429: the server asks us to slow down
            if i == tries - 1:
                raise
            time.sleep(int(e.headers.get("Retry-After") or 0) or 5 * (i + 1))
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(3 * (i + 1))


def all_rows():
    """The text and labels of every test clip (no audio), cached in rows.json; audio links are fetched fresh later."""
    cache = OUT / "rows.json"
    if cache.exists():
        return json.loads(cache.read_text())
    rows, offset = [], 0
    while True:
        page = json.loads(get(f"{API}&offset={offset}&length=100"))
        batch = page.get("rows", [])
        rows += [{k: v for k, v in r["row"].items() if k != "audio"} | {"_idx": r["row_idx"]} for r in batch]
        offset += len(batch)
        if not batch or offset >= page.get("num_rows_total", 0):
            cache.write_text(json.dumps(rows))
            return rows
        time.sleep(1.5)


def audio_src(idx):
    """A fresh signed link for one clip's audio (the links in a page expire)."""
    page = json.loads(get(f"{API}&offset={idx}&length=1"))
    audio = page["rows"][0]["row"]["audio"]
    return audio[0]["src"] if isinstance(audio, list) else audio["src"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--per-accent", type=int, default=6)
    ap.add_argument("--max", type=int, default=300)
    ap.add_argument("--seed", type=int, default=14)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    rows = all_rows()
    usable = [r for r in rows if 6 <= len(re.findall(r"[A-Za-z']+", r["text"] or "")) <= 40]
    by_accent = {}
    for r in usable:
        by_accent.setdefault(r["accent"] or "unknown", []).append(r)
    rng = random.Random(a.seed)
    picked = []
    for accent in sorted(by_accent):
        group = sorted(by_accent[accent], key=lambda r: r["_idx"])
        rng.shuffle(group)
        picked += group[: a.per_accent]
    rng.shuffle(picked)
    picked = sorted(picked[: a.max], key=lambda r: (r["accent"], r["_idx"]))
    manifest, total = [], 0
    for r in picked:
        wav = OUT / f"{r['_idx']:05d}.wav"
        if not wav.exists():
            raw = OUT / f"{r['_idx']:05d}.src"
            raw.write_bytes(get(audio_src(r["_idx"])))
            time.sleep(0.5)
            total += raw.stat().st_size
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(raw), "-ar", "16000", "-ac", "1", str(wav)], check=True)
            raw.unlink()
        manifest.append({"audio": str(wav), "text": r["text"], "accent": r["accent"], "l1": r.get("l1"), "speaker": r["speaker"]})
    with open(OUT / "manifest.jsonl", "w") as f:
        for m in manifest:
            f.write(json.dumps(m) + "\n")
    print(f"accents: {len(manifest)} clips from {len({m['accent'] for m in manifest})} accents "
          f"({len(rows)} rows read, {total / 1e6:.0f} MB downloaded) -> {OUT}")


if __name__ == "__main__":
    main()
