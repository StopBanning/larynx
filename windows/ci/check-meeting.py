"""Checks a meeting run end to end: both sides were transcribed and labelled (the call side named from "Thanks,
Priya"), the request to Claude had the right shape and the whole transcript, and the notes and page were saved."""
import json, sys
from pathlib import Path

out = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
req = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
data = Path(sys.argv[3])
m = out["meeting"]
problems = []
speakers = {s["speaker"] for s in m["segments"]}
said = " ".join(s["text"].lower() for s in m["segments"])
print(f"{len(m['segments'])} lines, speakers {sorted(speakers)}, transcribed in {out['transcribe_ms'] / 1000:.1f} s")
if "You" not in speakers: problems.append("no lines from You")
if not ({"On the call", "Priya"} & speakers): problems.append("no lines from the call")
for word in ["kitchen", "faucet", "permit", "electrician"]:
    if word not in said: problems.append(f"'{word}' not in the transcript")
h, b = req["headers"], req["body"]
if req["path"] != "/v1/messages": problems.append(f"path {req['path']}")
if h.get("x-api-key") != "ci-stand-in-key": problems.append("key header missing")
if h.get("anthropic-version") != "2026-10-21": problems.append("anthropic-version header")
if b.get("model") != "claude-opus-5-5": problems.append(f"model {b.get('model')}")
if b.get("output_config", {}).get("format", {}).get("type") != "json_schema": problems.append("no structured output")
user = b["messages"][0]["content"]
if "] You:" not in user or ("] Priya:" not in user and "] On the call:" not in user): problems.append("transcript lines missing from the request")
notes = m.get("notes") or {}
if notes.get("title") != "Renovation schedule": problems.append(f"notes not saved: {out.get('notes_failure')}")
if not notes.get("actionItems"): problems.append("action item dropped")
if not (data / "meetings" / f"{m['id']}.html").exists(): problems.append("page not saved")
if not (data / "meetings" / "index.html").exists(): problems.append("index not saved")
for p in problems: print("FAIL", p)
sys.exit(1 if problems else 0)
