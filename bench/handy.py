#!/usr/bin/env python3
"""Handy's default cleanup against Larynx's, on the same speech-model output.

    python3 bench/handy.py [--binary .build/release/larynx]

Handy (github.com/cjpais/Handy, MIT, Copyright (c) 2025 CJ Pais) runs Parakeet V3, the speech model family Larynx
uses, then a text cleanup that is on by default. `handy_clean` below is that cleanup ported line for line from
Handy v0.10.1, src-tauri/src/audio_toolkit/text.rs (remove_filler_words with English evidence, then
normalize_transcription_output); it passes the English cases in Handy's own tests. Its optional AI rewrite is off by
default and is not tested here.

Both cleanups get the same input: the raw Parakeet transcripts saved by bench/compare.py in bench/results (larynx-raw).
So this compares cleanup only, not speech models. Scored on edits needed against what was meant, as in compare.py:
  disfluency, disfluency-validation  DisfluencySpeech transcript C (made by other people; validation is held out).
                                     Only the transcripts are fetched, not the audio.
  messy, messy2, messy3              bench/messy*.json (written by us).
"""
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from run import norm, spoken, edits  # noqa: E402
from disfluency import API, fetch_json  # noqa: E402

# ---- Handy v0.10.1 cleanup (MIT, Copyright (c) 2025 CJ Pais), ported from Rust ----
UNIVERSAL = ["uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "хм", "ммм"]
ENGLISH = ["um", "ah", "eh"]
def opens_sentence(kept):
    t=kept.rstrip(); return not t or t[-1] in ".!?…"
def push(kept,seg,owed):
    if owed:
        for i,c in enumerate(seg):
            if c.isalnum(): return kept+seg[:i]+c.upper()+seg[i+1:], False
    return kept+seg, owed
def remove_matches(text,pat):
    kept,resume,owed="",0,False
    for m in pat.finditer(text):
        kept,owed=push(kept,text[resume:m.start()],owed)
        owed = owed or (m.group()[:1].isupper() and opens_sentence(kept))
        resume=m.end()
    kept,owed=push(kept,text[resume:],owed); return kept
def collapse(text):
    w=text.split(); out=[]; i=0
    while i<len(w):
        lw=w[i].lower()
        if lw.isalpha():
            n=1
            while i+n<len(w) and w[i+n].lower()==lw: n+=1
            out.append(w[i]); i+= n if n>=3 else 1
        else: out.append(w[i]); i+=1
    return " ".join(out)
def clean(text, english=True):
    for f in UNIVERSAL+(ENGLISH if english else []):
        text=remove_matches(text,re.compile(r"(?i)\b"+re.escape(f)+r"\b[,.]?"))
    text=collapse(text); text=re.sub(r"\s{2,}"," ",text); return text.strip()
# ---- end of the port ----


def words(text):
    return spoken(norm(re.sub(r"(?<=\d),(?=\d{3})", "", text)))


def load():
    rows = []
    for split, name in (("test", "disfluency"), ("validation", "disfluency-validation")):
        f = ROOT / "results" / f"compare-2026-11-19-{name}.json"
        outs = json.loads(f.read_text())["systems"]["larynx-raw"][f"{name}_outputs"]
        meant = {}
        for off in range(0, 250, 100):
            for r in fetch_json(f"{API}{split}&offset={off}&length=100")["rows"]:
                meant[r["row_idx"]] = r["row"]["transcript_c"]
        rows += [{"set": name, "raw": t, "meant": meant[int(k.split(".")[0])]} for k, t in outs.items() if t]
    outs = json.loads((ROOT / "results/compare-2026-11-19-messy-messy2-messy3.json").read_text())["systems"]["larynx-raw"]
    for name in ("messy", "messy2", "messy3"):
        sents = json.loads((ROOT / f"{name}.json").read_text())["sentences"]
        rows += [{"set": name, "raw": t, "meant": sents[int(k.split("-")[0])]["meant"]} for k, t in outs[f"{name}_outputs"].items() if t]
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=str(ROOT.parent / ".build/release/larynx"))
    a = ap.parse_args()
    rows = load()
    stdin = "".join(json.dumps(r["raw"]) + "\n" for r in rows)
    larynx = [json.loads(l) for l in subprocess.run([a.binary, "tidy", "--stdin", "--mode", "correspondence"], input=stdin,
                                                     capture_output=True, text=True, check=True).stdout.splitlines()]
    sums = {}
    for r, lar in zip(rows, larynx):
        m = words(r["meant"])
        s = sums.setdefault(r["set"], {"clips": 0, "words": 0, "raw": 0, "handy": 0, "larynx": 0})
        s["clips"] += 1
        s["words"] += len(m)
        for k, t in (("raw", r["raw"]), ("handy", clean(r["raw"])), ("larynx", lar)):
            s[k] += edits(m, words(t))
    print("| Set | Clips | No cleanup | Handy's cleanup | Larynx cleanup |\n| --- | --- | --- | --- | --- |")
    for name, s in sums.items():
        pct = lambda k: f"{100 * s[k] / s['words']:.1f}%"
        print(f"| {name} | {s['clips']} | {pct('raw')} | {pct('handy')} | {pct('larynx')} |")


if __name__ == "__main__":
    main()
