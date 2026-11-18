"""Checks `larynx e2e-meeting` (meeting mode driven in the real app on the CI desktop):

- the notes came through Claude Code (the stand-in), with no tools, Opus, and no API key reaching it;
- the call heard through the speakers did not end up as "You" (the echo filter);
- the line spoken while Mute me was on is not in the transcript, and the lines before and after are;
- the meeting cut off by killing the app was finished after the restart, and its audio cleared.

    python windows/ci/check-meeting-app.py e2e-meeting tests/meetings/client-call.json
"""
import json, re, sys
from pathlib import Path

out, script = Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
report = json.loads((out / "e2e-meeting.json").read_text(encoding="utf-8-sig"))
meetings = out / "data" / "meetings"
problems = []


def words(t):
    return re.findall(r"[a-z0-9]+", t.lower().replace("'", ""))


def load(mid):
    p = meetings / f"{mid}.json"
    return json.loads(p.read_text(encoding="utf-8")) if mid and p.exists() else None


m = load(report.get("first_id"))
if not m:
    problems.append(f"the first meeting was not saved ({report.get('first_id')})")
else:
    segs = m["segments"]
    you = [s for s in segs if s["speaker"] == "You"]
    print(f"first meeting: {len(segs)} lines, {len(you)} yours, Stop to notes {report.get('stop_to_notes_s')} s")
    for s in segs:
        print(f"  {s['start']:6.1f} {s['speaker'][:11]:11} {s['text']}")
    notes = m.get("notes") or {}
    if notes.get("title") != "Renovation schedule (through Claude Code)":
        problems.append(f"the notes did not come through Claude Code: {notes.get('title')!r}")
    if not (meetings / f"{m['id']}.html").exists():
        problems.append("the meeting's page was not saved")

    # Echo: a line of "You" that is mostly words of the call's lines and not of You's own lines.
    call_words = set(w for who, text in script["lines"] if who != "You" for w in words(text))
    you_words = set(w for who, text in script["lines"] if who == "You" for w in words(text))
    leaked = []
    for s in you:
        ws = words(s["text"])
        if not ws:
            continue
        in_call = sum(w in call_words for w in ws) / len(ws)
        in_yours = sum(w in you_words for w in ws) / len(ws)
        if in_call >= 0.6 and in_yours < 0.5:
            leaked.append(s["text"])
    print(f"echo lines left as yours: {leaked}")
    if len(leaked) > 1:
        problems.append(f"{len(leaked)} lines of the call ended up as yours: {leaked}")

    # Mute: the muted line is gone; You's lines before and after it are there.
    muted = script["lines"][report["muted_line"]][1]
    said = " ".join(s["text"].lower() for s in you)
    if "permit" in said:
        problems.append(f"the line said while muted is in the transcript ({muted!r})")
    for word in ["bathroom", "faucets"]:
        if word not in said:
            problems.append(f"your line with {word!r} is missing (the microphone may not have come back after Unmute)")
    if not report.get("mute_logged"):
        problems.append("Mute me was not logged")

call = out / "claude-code-call.json"
if not call.exists():
    problems.append("Claude Code (the stand-in) was never called")
else:
    c = json.loads(call.read_text(encoding="utf-8"))
    a = c["args"]
    if c["api_key_reached_claude_code"]:
        problems.append("the API key reached Claude Code (it would bill the key instead of the plan)")
    for flag, value in [("--model", "opus"), ("--tools", ""), ("--output-format", "json")]:
        if flag not in a or a[a.index(flag) + 1] != value:
            problems.append(f"Claude Code was not given {flag} {value!r}")
    for flag in ["-p", "--strict-mcp-config", "--no-session-persistence", "--json-schema"]:
        if flag not in a:
            problems.append(f"Claude Code was not given {flag}")
    if "] You:" not in c["stdin"]:
        problems.append("the transcript did not reach Claude Code on stdin")

cut = load(report.get("cut_off_id"))
if not cut:
    problems.append(f"the meeting cut off by the restart was not finished ({report.get('cut_off_id')})")
else:
    print(f"cut-off meeting: {len(cut['segments'])} lines, finished {report.get('recovered_after_restart_s')} s after the restart")
    if not cut["segments"]:
        problems.append("the cut-off meeting has no transcript")
    left = list((meetings / "spool").glob(f"{cut['id']}*")) if (meetings / "spool").exists() else []
    if left:
        problems.append(f"the cut-off meeting's audio was not cleared: {[p.name for p in left]}")

for f in report.get("failures", []):
    problems.append(f"driver: {f}")
for p in problems:
    print("FAIL", p)
print("ok" if not problems else f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
