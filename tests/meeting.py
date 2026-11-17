#!/usr/bin/env python3
"""Meeting mode test (docs/dev/MEETING.md): scripted meetings in, checked notes out.

    scripts/when-idle.sh python3 tests/meeting.py [--summary both|on-device|private-cloud] [--only weekly-sync]

Each script in tests/meetings/ is voiced line by line with macOS voices onto two tracks, the way a call sounds to
Larynx: "you" (the microphone) and "call" (everyone else). `larynx meeting` turns them into a transcript and notes,
and the notes are checked against what the script says must be there:

- every scripted decision, action item (with its owner and due date) and open question is in the notes;
- the key figures are right;
- nothing is invented: no owner who isn't in the meeting, no number nobody said;
- the time from the end of the audio to the notes.

Loads the speech model: run it under scripts/when-idle.sh. The audio lives in ~/work/scratch/larynx-bench/meetings.
"""
import argparse, array, json, re, subprocess, sys, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path.home() / "work/scratch/larynx-bench/meetings"
RATE = 16000


def voice_line(text, voice, path):
    if path.exists():
        return
    aiff = path.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-r", "180", "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", str(RATE), "-ac", "1", "-f", "f32le", str(path)], check=True)
    aiff.unlink()


def build(name, script):
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    tracks = {"you": array.array("f"), "call": array.array("f")}
    t = int(0.5 * RATE)
    for i, (speaker, text) in enumerate(script["lines"]):
        info = script["speakers"][speaker]
        raw = d / f"{i:03d}.f32"
        voice_line(text, info["voice"], raw)
        clip = array.array("f"); clip.frombytes(raw.read_bytes())
        for side in tracks:
            if len(tracks[side]) < t: tracks[side].extend([0.0] * (t - len(tracks[side])))
        tr = tracks[info["side"]]
        tr.extend(clip)
        t += len(clip) + int((0.45 + 0.1 * (i % 4)) * RATE)
    for side, tr in tracks.items():
        if len(tr) < t: tr.extend([0.0] * (t - len(tr)))
        with wave.open(str(d / f"{side}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
            w.writeframes(array.array("h", (max(-32767, min(32767, int(x * 32767))) for x in tr)).tobytes())
    return d / "you.wav", d / "call.wav", t / RATE


def digits(text):
    return {n.replace(",", "") for n in re.findall(r"\d[\d,]*(?:\.\d+)?", text)}


def check(notes, script, transcript):
    problems = []
    low = lambda s: (s or "").lower()
    def has(items, words):
        return any(all(w.lower() in low(it) for w in words) for it in items)
    for words in script["expect"].get("decisions", []):
        if not has(notes["decisions"] + notes["summary"], words): problems.append(f"decision missing: {words}")
    for a in script["expect"].get("actions", []):
        match = [it for it in notes["actionItems"] if all(w.lower() in low(it["task"]) for w in a["words"])]
        if not match: problems.append(f"action missing: {a['words']}"); continue
        # One sentence can hold two tasks ("tell the printer today, a new proof by Thursday"): any task that fits counts.
        fits = lambda it: (not a.get("owner") or a["owner"].lower() in low(it.get("owner"))) and \
            (not a.get("due") or a["due"].lower() in low(it.get("due")) + low(it["task"]))
        it = next((m for m in match if fits(m)), match[0])
        if a.get("owner") and a["owner"].lower() not in low(it.get("owner")): problems.append(f"action {a['words']}: owner {it.get('owner')!r}, expected {a['owner']}")
        if a.get("due") and a["due"].lower() not in low(it.get("due")) + low(it["task"]): problems.append(f"action {a['words']}: due {it.get('due')!r}, expected {a['due']}")
    for words in script["expect"].get("open", []):
        if not has(notes["openQuestions"] + notes["summary"], words): problems.append(f"open question missing: {words}")
    everything = " ".join(notes["summary"] + notes["decisions"] + notes["openQuestions"] + [notes["title"]]
                          + [f"{i['task']} {i.get('owner') or ''} {i.get('due') or ''}" for i in notes["actionItems"]])
    for fact in script["expect"].get("facts", []):
        f = fact.replace(",", "")
        if f.lower() not in everything.replace(",", "").lower(): problems.append(f"figure missing or wrong: {fact}")
    people = {p.lower() for p in script["speakers"]} | {"you", "me", "us", "we", "everyone", "team"}
    for it in notes["actionItems"]:
        o = low(it.get("owner")).strip()
        if o and not any(p in o for p in people): problems.append(f"invented owner: {it.get('owner')!r}")
    invented = digits(everything) - digits(transcript) - {"1", "2", "3", "4", "5"}
    if invented: problems.append(f"numbers nobody said: {sorted(invented)}")
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--binary", default=str(ROOT / ".build/release/larynx"))
    ap.add_argument("--summary", default="both")
    ap.add_argument("--only")
    a = ap.parse_args()
    failures = 0
    for f in sorted((ROOT / "tests/meetings").glob("*.json")):
        if a.only and f.stem != a.only: continue
        script = json.loads(f.read_text())
        you, call, seconds = build(f.stem, script)
        p = subprocess.run([a.binary, "meeting", "--you", str(you), "--them", str(call), "--summary", a.summary, "--json"],
                           capture_output=True, text=True, timeout=1800)
        if p.returncode != 0:
            print(f"FAIL {f.stem}: larynx meeting exited {p.returncode}: {p.stderr.strip()[-300:]}"); failures += 1; continue
        out = json.loads(p.stdout)
        segs = out["meeting"]["segments"]
        transcript = " ".join(s["text"] for s in segs)
        you_lines = sum(1 for s in segs if s["speaker"] == "You")
        print(f"== {f.stem}: {seconds / 60:.1f} min, {len(segs)} utterances ({you_lines} yours), transcribed in {out['timing']['transcribe']:.1f} s, stop to transcript {out['timing'].get('finish', 0):.1f} s")
        for model, why in out["failures"].items():
            print(f"   {model}: not run ({why})")
        for notes in out["notes"]:
            problems = check(notes, script, transcript)
            status = "ok  " if not problems else "FAIL"
            failures += bool(problems)
            print(f"   {status} {notes['model']}: notes in {notes['seconds']:.1f} s; {len(notes['decisions'])} decisions, {len(notes['actionItems'])} action items, {len(notes['openQuestions'])} open questions")
            for pr in problems: print(f"        {pr}")
        (OUT / f.stem / "result.json").write_text(json.dumps(out, indent=1))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
