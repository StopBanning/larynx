#!/usr/bin/env python3
"""Builds the benchmark audio in ~/work/scratch/larynx-bench (never in git).

Sets (each a folder with manifest.jsonl lines {"audio", "text", "names"}):
  jargon      bench/sentences.json spoken by three macOS voices
  noise10     jargon (two voices) under background chatter + pink noise at 10 dB SNR
  noise5      the same at 5 dB SNR
  whisper     the sentences in macOS's Whisper voice
  ls-clean    300 LibriSpeech test-clean utterances (needs the download in librispeech/)
  ls-other    300 LibriSpeech test-other utterances
  long        10 clips of 8 consecutive LibriSpeech utterances (60-120 s each)
Needs ffmpeg. Deterministic: the same files every run.
"""
import json, math, os, random, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = Path.home() / "work/scratch/larynx-bench"
VOICES = ["Samantha", "Daniel", "Karen"]


def sh(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def say(text, voice, path, rate=185):
    aiff = path.with_suffix(".aiff")
    sh("say", "-v", voice, "-r", str(rate), "-o", str(aiff), text)
    sh("ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", "16000", "-ac", "1", str(path))
    aiff.unlink()


def mean_db(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
                       capture_output=True, text=True)
    return float(re.search(r"mean_volume: (-?[\d.]+) dB", r.stderr).group(1))


def write(name, rows):
    d = OUT / name
    with open(d / "manifest.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"{name}: {len(rows)} clips")


def tts_sets(data):
    sents = data["sentences"]
    jd = OUT / "jargon"; jd.mkdir(parents=True, exist_ok=True)
    rows = []
    for i, s in enumerate(sents):
        for v in VOICES:
            p = jd / f"{i:02d}-{v}.wav"
            if not p.exists():
                say(s["text"], v, p)
            rows.append({"audio": str(p), "text": s["text"], "names": s["names"], "voice": v})
    write("jargon", rows)

    # Background bed: three voices talking over each other plus pink noise, 90 s long.
    bed = OUT / "bed.wav"
    if not bed.exists():
        tracks = []
        for k, v in enumerate(["Moira", "Rishi", "Fred"]):
            t = OUT / f"babble{k}.wav"
            say("  ".join(data["babble"][k:] + data["babble"][:k]) * 2, v, t, rate=170)
            tracks.append(t)
        sh("ffmpeg", "-loglevel", "error", "-y", *sum([["-i", str(t)] for t in tracks], []),
           "-f", "lavfi", "-i", "anoisesrc=color=pink:amplitude=0.08:sample_rate=16000:duration=90",
           "-filter_complex", "[0][1][2][3]amix=inputs=4:duration=longest:normalize=0,atrim=0:90",
           "-ar", "16000", "-ac", "1", str(bed))
        for t in tracks: t.unlink()
    bed_db = mean_db(bed)
    for snr in (10, 5):
        nd = OUT / f"noise{snr}"; nd.mkdir(exist_ok=True)
        rows = []
        rnd = random.Random(snr)
        for i, s in enumerate(sents):
            for v in VOICES[:2]:
                src = jd / f"{i:02d}-{v}.wav"
                p = nd / src.name
                if not p.exists():
                    gain = mean_db(src) - snr - bed_db
                    start = rnd.uniform(0, 70)
                    sh("ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-ss", f"{start:.2f}", "-i", str(bed),
                       "-filter_complex", f"[1]volume={gain:.2f}dB[n];[0][n]amix=inputs=2:duration=first:normalize=0",
                       "-ar", "16000", "-ac", "1", str(p))
                rows.append({"audio": str(p), "text": s["text"], "names": s["names"], "voice": v, "snr": snr})
        write(f"noise{snr}", rows)

    wd = OUT / "whisper"; wd.mkdir(exist_ok=True)
    rows = []
    for i, s in enumerate(sents):
        p = wd / f"{i:02d}.wav"
        if not p.exists():
            say(s["text"], "Whisper", p, rate=170)
        rows.append({"audio": str(p), "text": s["text"], "names": s["names"], "voice": "Whisper"})
    write("whisper", rows)


def librispeech():
    base = OUT / "librispeech"
    for name, sub, n in (("ls-clean", "test-clean", 300), ("ls-other", "test-other", 300)):
        root = base / f"x-{sub}" / "LibriSpeech" / sub
        if not root.exists():
            print(f"{name}: skipped (no {root})"); continue
        utts = []
        for trans in sorted(root.glob("*/*/*.trans.txt")):
            for line in trans.read_text().splitlines():
                uid, text = line.split(" ", 1)
                utts.append((uid, text, trans.parent / f"{uid}.flac"))
        step = max(1, len(utts) // n)
        rows = [{"audio": str(p), "text": t, "names": []} for _, t, p in utts[::step][:n]]
        (OUT / name).mkdir(exist_ok=True)
        write(name, rows)
        if sub == "test-clean":
            ld = OUT / "long"; ld.mkdir(exist_ok=True)
            rows = []
            chapters = {}
            for uid, text, p in utts:
                chapters.setdefault(p.parent, []).append((text, p))
            for k, (ch, items) in enumerate(sorted(chapters.items())[:10]):
                items = items[:8]
                out = ld / f"long-{k:02d}.wav"
                if not out.exists():
                    lst = ld / "list.txt"
                    lst.write_text("".join(f"file '{p}'\n" for _, p in items))
                    sh("ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
                       "-ar", "16000", "-ac", "1", str(out))
                    lst.unlink()
                rows.append({"audio": str(out), "text": " ".join(t for t, _ in items), "names": []})
            write("long", rows)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    data = json.loads((ROOT / "sentences.json").read_text())
    if len(sys.argv) < 2 or "tts" in sys.argv: tts_sets(data)
    if len(sys.argv) < 2 or "librispeech" in sys.argv: librispeech()
