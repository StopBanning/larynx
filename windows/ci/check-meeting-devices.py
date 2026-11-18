"""Checks `larynx e2e-meeting-devices` (meeting mode through real audio devices on the CI desktop, a virtual cable
standing in for speakers and a microphone in a room with no headphones):

- the call was recorded from the speakers and your voice from the microphone, each on its own side;
- the call the microphone heard from the speakers did not end up as "You" (the echo filter, on real device timing);
- your voice did not leak into the call side;
- with Windows blocking microphones, the panel said so; once access was turned on, the microphone was picked up;
- restarting Windows' audio service partway (every app's audio drops) was shown, recording went on, and the lines
  after it are in time with the lines before it (the gap was filled with silence, not dropped).

    python windows/ci/check-meeting-devices.py e2e-devices
"""
import json, re, statistics, sys
from pathlib import Path

out = Path(sys.argv[1])
report = json.loads((out / "e2e-devices.json").read_text(encoding="utf-8-sig"))
problems = []


def words(t):
    return re.findall(r"[a-z0-9]+", t.lower().replace("'", ""))


def overlap(a, b):
    a, b = words(a), set(words(b))
    return sum(w in b for w in a) / len(a) if a else 0.0


path = out / "data" / "meetings" / f"{report.get('meeting_id')}.json"
if not path.exists():
    print("FAIL the meeting was not saved")
    sys.exit(1)
m = json.loads(path.read_text(encoding="utf-8"))
segs = m["segments"]
offset = report.get("playing_from_s_after_start", 0.0)
lines = report["lines"]
gap_from, gap_to = report["unplugged"]
print(f"{len(segs)} lines in the transcript; audio service restarted {gap_from:.1f} s; players {report.get('players')}")
for s in segs:
    print(f"  {s['start'] - offset:6.1f} {s['speaker'][:11]:11} {s['text']}")

# Each scripted line well clear of the restart should be in the transcript, on its own side, near its time. The speech
# model may split a line into several, so the line's start is the earliest piece of it.
found, missed, shifts = 0, [], {"before": [], "after": []}
for l in lines:
    if l["end"] > gap_from - 1 and l["start"] < gap_to + 2:
        continue
    you_side = l["who"] == "You"
    pieces = [s for s in segs if (s["speaker"] == "You") == you_side
              and l["start"] - 3 <= s["start"] - offset <= l["end"] + 3 and overlap(s["text"], l["text"]) >= 0.7]
    heard = set(w for s in pieces for w in words(s["text"]))
    covered = sum(w in heard for w in words(l["text"])) / max(1, len(words(l["text"])))
    if pieces and covered >= 0.6:
        found += 1
        shifts["before" if l["end"] < gap_from else "after"].append(min(s["start"] for s in pieces) - offset - l["start"])
    else:
        missed.append(f"{l['who']}: {l['text']}")
total = found + len(missed)
print(f"lines found on the right side near their time: {found}/{total}")
for x in missed:
    print(f"  missed: {x}")
if total == 0 or found < 0.75 * total:
    problems.append(f"only {found} of {total} lines were heard on the right side at the right time")
for k, v in shifts.items():
    if v:
        med = statistics.median(v)
        print(f"time shift {k} the restart: median {med:+.2f} s over {len(v)} lines")
        if abs(med) > 1.5:
            problems.append(f"lines {k} the restart are {med:+.2f} s off their time (the tracks are out of step)")
    else:
        problems.append(f"no lines found {k} the restart")
if shifts["before"] and shifts["after"]:
    drift = statistics.median(shifts["after"]) - statistics.median(shifts["before"])
    print(f"after the restart, lines moved {drift:+.2f} s against before")
    if abs(drift) > 1.0:
        problems.append(f"the restart moved the later lines {drift:+.2f} s (the gap was not filled)")

# Echo: "You" lines made of the call's words. Leak: "On the call" lines made of your words.
call_text = " ".join(l["text"] for l in lines if l["who"] != "You")
you_text = " ".join(l["text"] for l in lines if l["who"] == "You")
echo = [s["text"] for s in segs if s["speaker"] == "You" and overlap(s["text"], call_text) >= 0.6 and overlap(s["text"], you_text) < 0.5]
leak = [s["text"] for s in segs if s["speaker"] != "You" and overlap(s["text"], you_text) >= 0.6 and overlap(s["text"], call_text) < 0.5]
print(f"echo lines left as yours: {echo}")
print(f"your lines on the call side: {leak}")
if len(echo) > 1:
    problems.append(f"{len(echo)} lines of the call heard by the microphone ended up as yours")
if len(leak) > 1:
    problems.append(f"{len(leak)} of your lines ended up on the call side")

# The unplug: shown and logged, and cleared once the cable came back.
audio = [e for e in report.get("app_log", []) if e.get("event") == "meeting_audio"]
print(f"audio events: {audio}")
if not report.get("blocked_microphone_shown"):
    problems.append("with microphones blocked by Windows, the panel didn't say where to turn them on")
if report.get("microphone_picked_up_s") is None:
    problems.append("after microphone access was turned on, the microphone was never picked up")
# After the microphone was picked up (the first event with no problem), the restart must show as a problem again.
first_ok = next((i for i, e in enumerate(audio) if not e.get("problem")), None)
dropped = [e for e in audio[first_ok + 1:] if e.get("problem")] if first_ok is not None else []
if not dropped:
    problems.append("the audio dropping out (service restarted) was not shown on the panel")
if audio and audio[-1].get("problem"):
    problems.append(f"the panel still showed a problem after the audio came back: {audio[-1].get('problem')!r}")
for side, p in (report.get("players") or {}).items():
    if p.get("error") and p.get("lost", 0) > 20:
        problems.append(f"the test couldn't play {side} for most of the meeting: {p['error']}")

# "Send a report…": written, says what's in it, lists the audio devices, and holds nothing anyone said.
rep = out / "Larynx report.txt"
if not rep.exists():
    problems.append("the report file was not written")
else:
    text = rep.read_text(encoding="utf-8", errors="replace")
    print(f"report: {len(text)} characters, {text.count(chr(10))} lines")
    for need in ["Larynx report", "== This computer", "Audio devices:", "CABLE", "== Recent meetings (1)", "== Log"]:
        if need not in text:
            problems.append(f"the report has no {need!r}")
    said = [l["text"] for l in lines] + [s["text"] for s in segs]
    for t in said:
        ws = words(t)
        for i in range(len(ws) - 3):
            if " ".join(ws[i:i + 4]) in " ".join(words(text)):
                problems.append(f"the report holds words from the meeting: {' '.join(ws[i:i + 4])!r}")
                break
    if re.search(r"C:\\?Users\\?runneradmin", text, re.I):
        problems.append("the report holds the user's folder name")

for f in report.get("failures", []):
    problems.append(f"driver: {f}")
for p in problems:
    print("FAIL", p)
print("ok" if not problems else f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
