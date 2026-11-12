#!/usr/bin/env python3
"""Pre-labels the random golden clips (R4): every downloaded engine transcribes each waiting clip.

    larynx golden sample --n 60      # picks the clips (golden/pending.jsonl)
    python3 bench/prelabel.py        # this: fills in what each engine heard, and the label where they all agree
    larynx golden label              # you: Return keeps a proposal, typing corrects it

Engines run verbatim (cleanup, vocabulary and the AI rewrite off), one `larynx serve` each, so the agreement is
between the speech models themselves. Loading a model the CLI has never run compiles it for the Neural Engine
first (one to three minutes), so run this when the Mac is otherwise idle (scripts/when-idle.sh). Nothing is printed
but counts: the clips are your words.
"""
import argparse, json, os, re, signal, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import Engine, ROOT  # noqa: E402

DATA = Path(os.environ.get("LARYNX_DATA_DIR") or Path.home() / "Library/Application Support/Larynx").expanduser()
PENDING = DATA / "golden" / "pending.jsonl"


def normalized(text):
    """Same as Golden.normalized: lower case, words only, hyphens as spaces."""
    return " ".join(re.findall(r"[\w']+", text.lower().replace("-", " ")))


def agreed(heard, typed):
    """Same as Golden.agreed: a label only when two or more engines heard the same words."""
    texts = [heard[k] for k in sorted(heard)]
    if len(texts) < 2 or not normalized(texts[0]) or any(normalized(t) != normalized(texts[0]) for t in texts):
        return None
    return typed if normalized(typed) == normalized(texts[0]) else texts[0]


def typed_texts(ids):
    """The typed text of each dictation, read from history with the CLI (so the schema stays in one place)."""
    import subprocess
    out = subprocess.run([str(ROOT / ".build/release/larynx"), "history", "--json", "--limit", "5000"],
                         capture_output=True, text=True, check=True).stdout
    return {r["id"]: r["text"] for r in json.loads(out) if r["id"] in ids}


def save(items):
    PENDING.write_text("".join(json.dumps(i, sort_keys=True) + "\n" for i in items))
    os.chmod(PENDING, 0o600)


def main():
    # when-idle.sh stops us with SIGTERM the moment you touch the keyboard: exit through finally (closes serve, saves).
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    ap = argparse.ArgumentParser()
    # The installed app's own binary: its bundle id already has your engine and the backup compiled for the Neural
    # Engine, so those start in seconds instead of minutes (the compile cache is per bundle id).
    installed = Path.home() / "Applications/Larynx.app/Contents/MacOS/larynx"
    ap.add_argument("--binary", default=str(installed if installed.exists() else ROOT / ".build/release/larynx"))
    ap.add_argument("--models-dir", default=str(DATA / "models"))
    # Already-compiled engines first, so an interrupted run still leaves two opinions per clip.
    ap.add_argument("--engines", default="ultra,clean,parakeet,unified,bark3")
    a = ap.parse_args()

    items = [json.loads(l) for l in PENDING.read_text().splitlines() if l.strip()] if PENDING.exists() else []
    if not items:
        print("nothing waiting; run larynx golden sample first"); return
    folders = {"clean": "bark-3.0-clean", "bark3": "bark-3.0", "ultra": "parakeet-ultra",
               "parakeet": "parakeet-tdt-0.6b-v3", "unified": "parakeet-unified-en-0.6b"}
    engines = [e for e in a.engines.split(",")
               if any(p.suffix == ".mlmodelc" for p in (Path(a.models_dir) / folders[e]).glob("*"))]
    print(f"{len(items)} clips, engines: {', '.join(engines)}")

    for e in engines:
        todo = [i for i in items if e not in i.get("heard", {}) and Path(i["audio"]).exists()]
        if not todo: continue
        eng = Engine(a.binary, e, a.models_dir)
        try:
            for i in todo:
                out = eng.transcribe(i["audio"])
                if out.get("event") == "result":
                    i.setdefault("heard", {})[e] = out.get("raw") or out.get("text") or ""
                    save(items)  # every clip, so an interrupted run (when-idle.sh) loses at most one
        finally:
            eng.close()
            save(items)
        print(f"  {e}: {len(todo)} clips")

    typed = typed_texts({i["id"] for i in items})
    for i in items:
        label = agreed(i.get("heard", {}), typed.get(i["id"], ""))
        if label: i["agreed"] = label
        else: i.pop("agreed", None)
    save(items)
    n = sum(1 for i in items if i.get("agreed"))
    print(f"all engines agree on {n} of {len(items)}; the other {len(items) - n} need you (larynx golden label)")


if __name__ == "__main__":
    main()
