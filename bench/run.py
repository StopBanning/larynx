#!/usr/bin/env python3
"""Larynx speech-model benchmark: word error rate, punctuation, names and speed, per engine and set.

    python3 bench/run.py                                  # every engine on every built set
    python3 bench/run.py --engines clean,unified --sets jargon,noise5 --limit 20
    python3 bench/run.py --write-doc                       # also rewrite docs/BENCHMARKS.md

Audio comes from bench/make_sets.py (~/work/scratch/larynx-bench). Each engine runs in one `larynx serve`
process with cleanup off (verbatim), vocabulary off and the AI rewrite off, so this measures the speech model.
"""
import argparse, datetime, json, os, re, statistics, subprocess, sys, time
from difflib import SequenceMatcher
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = Path.home() / "work/scratch/larynx-bench"
ALL_ENGINES = ["clean", "parakeet", "bark3", "ultra", "unified"]
ALL_SETS = ["jargon", "noise10", "noise5", "whisper", "ls-clean", "ls-other", "long"]

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def words_for(n):
    n = int(n)
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000: return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + words_for(n % 100))
    if n < 10000 and n % 1000 == 0: return ONES[n // 1000] + " thousand"
    if 1100 <= n < 2100: return words_for(n // 100) + " " + (words_for(n % 100) if n % 100 else "hundred")
    return " ".join(ONES[int(d)] for d in str(n))


def norm(text):
    t = text.lower().replace("%", " percent").replace("-", " ")
    t = re.sub(r"\$(\d+)", r"\1 dollars", t)
    t = re.sub(r"\d+", lambda m: " " + words_for(m.group()) + " ", t)
    t = re.sub(r"[^a-z' ]", " ", t)
    return [w.strip("'") for w in t.split() if w.strip("'")]


def edits(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
            prev, d[j] = d[j], cur
    return d[len(hyp)]


def punct_marks(text):
    """(normalized word, mark after it) for each word; mark is one of , . ? or ''."""
    out = []
    for tok in text.split():
        core = norm(tok)
        mark = tok[-1] if tok[-1] in ",.?!" else ""
        if mark == "!": mark = "."
        for k, w in enumerate(core):
            out.append((w, mark if k == len(core) - 1 else ""))
    return out


def punct_counts(ref, hyp):
    """True positives, false positives, false negatives of punctuation on aligned words."""
    r, h = punct_marks(ref), punct_marks(hyp)
    sm = SequenceMatcher(a=[w for w, _ in r], b=[w for w, _ in h], autojunk=False)
    tp = fp = fn = 0
    for a, b, size in sm.get_matching_blocks():
        for k in range(size):
            rm, hm = r[a + k][1], h[b + k][1]
            if rm and hm == rm: tp += 1
            elif hm and hm != rm: fp += 1; fn += bool(rm)
            elif rm and not hm: fn += 1
    return tp, fp, fn


class Engine:
    def __init__(self, binary, engine, models):
        self.p = subprocess.Popen([binary, "serve", "--engine", engine, "--rewrite", "off", "--vocab", "off",
                                   "--models-dir", models], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("event") == "ready": break
            if msg.get("event") == "error": raise RuntimeError(msg)

    def transcribe(self, path):
        self.n += 1
        self.p.stdin.write(json.dumps({"cmd": "transcribe", "path": path, "verbatim": True, "id": self.n}) + "\n")
        while True:
            msg = json.loads(self.p.stdout.readline())
            if msg.get("id") == self.n and msg.get("event") in ("result", "error"): return msg

    def close(self):
        try: self.p.stdin.write('{"cmd":"quit"}\n'); self.p.wait(timeout=10)
        except Exception: self.p.kill()


def load(name, limit):
    f = DATA / name / "manifest.jsonl"
    if not f.exists(): return []
    rows = [json.loads(l) for l in f.read_text().splitlines()]
    return rows[:limit] if limit else rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engines", default=",".join(ALL_ENGINES))
    ap.add_argument("--sets", default=",".join(ALL_SETS))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--models-dir", default=str(Path.home() / "Library/Application Support/Larynx/models"))
    ap.add_argument("--write-doc", action="store_true")
    a = ap.parse_args()
    sets = {s: load(s, a.limit) for s in a.sets.split(",")}
    sets = {k: v for k, v in sets.items() if v}
    results = {}
    for e in a.engines.split(","):
        print(f"== {e}", flush=True)
        try:
            eng = Engine(a.binary, e, a.models_dir)
        except Exception as err:
            print(f"   could not start: {err}"); continue
        results[e] = {}
        for s, rows in sets.items():
            err = refw = tp = fp = fn = names_ok = names_all = 0
            ms, secs, samples = [], 0.0, []
            for r in rows:
                out = eng.transcribe(r["audio"])
                hyp = out.get("raw", "") if out.get("event") == "result" else ""
                ref_w, hyp_w = norm(r["text"]), norm(hyp)
                err += edits(ref_w, hyp_w); refw += len(ref_w)
                if not s.startswith("ls") and s != "long":
                    c = punct_counts(r["text"], hyp); tp += c[0]; fp += c[1]; fn += c[2]
                for n in r.get("names", []):
                    names_all += 1
                    names_ok += bool(re.search(r"(?<![\w])" + re.escape(n) + r"(?![\w])", hyp))
                ms.append(out.get("asrMs", 0)); secs += out.get("audioSeconds", 0)
                if len(samples) < 3 and edits(ref_w, hyp_w): samples.append({"ref": r["text"], "hyp": hyp})
            p = tp / (tp + fp) if tp + fp else 0; rc = tp / (tp + fn) if tp + fn else 0
            ms_sorted = sorted(ms)
            results[e][s] = {
                "clips": len(rows), "wer": round(100 * err / max(refw, 1), 2),
                "punctF1": round(100 * 2 * p * rc / (p + rc), 1) if p + rc else None,
                "names": round(100 * names_ok / names_all, 1) if names_all else None,
                "p50ms": ms_sorted[len(ms) // 2], "p90ms": ms_sorted[int(len(ms) * 0.9) - 1 if len(ms) > 1 else 0],
                "rtfx": round(secs / max(sum(ms) / 1000, 1e-6), 1), "examples": samples,
            }
            r_ = results[e][s]
            print(f"   {s:9s} WER {r_['wer']:6.2f}%  punct {r_['punctF1']}  names {r_['names']}  p50 {r_['p50ms']} ms  p90 {r_['p90ms']} ms  {r_['rtfx']}x", flush=True)
        eng.close()
    stamp = datetime.date.today().isoformat()
    commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    out = ROOT / f"bench/results/bench-{stamp}-{commit}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"date": stamp, "commit": commit, "machine": machine(), "results": results}, indent=2))
    print("wrote", out)


def machine():
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30
    os_ = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    return f"{chip}, {mem} GB, macOS {os_}"


if __name__ == "__main__":
    main()
