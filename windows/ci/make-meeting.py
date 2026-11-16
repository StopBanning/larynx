"""Lays the spoken lines of a scripted meeting out on two tracks (you.wav, call.wav) with a short pause between turns,
each line on its speaker's track and silence on the other, as meeting mode records a call."""
import json, sys, wave
from pathlib import Path

script, out = Path(sys.argv[1]), Path(sys.argv[2])
lines = json.loads(script.read_text(encoding="utf-8"))["lines"]
rate, gap = 16000, b"\x00\x00" * 8000  # 0.5 s between turns
you, call = bytearray(), bytearray()
for i, (who, _text) in enumerate(lines):
    with wave.open(str(out / "lines" / f"{i:03d}.wav")) as w:
        assert w.getframerate() == rate and w.getnchannels() == 1 and w.getsampwidth() == 2
        pcm = w.readframes(w.getnframes())
    mine, other = (you, call) if who == "You" else (call, you)
    mine += pcm + gap
    other += b"\x00" * len(pcm) + gap
for name, pcm in (("you.wav", you), ("call.wav", call)):
    with wave.open(str(out / name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(pcm))
print(f"you.wav and call.wav: {len(you) / 2 / rate:.1f} s each, {len(lines)} lines")
