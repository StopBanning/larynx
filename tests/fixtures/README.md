# Protocol fixture

`report.wav`: synthetic Samantha voice at 175 words/minute, generated locally with:

```sh
say -v Samantha -r 175 --file-format=WAVE --data-format=LEI16@16000 \
  -o tests/fixtures/report.wav 'Please send the report tomorrow.'
```

It contains no personal audio. `serve-before-transcript.json` was captured from
release `fedce03` before task 0.3, using clean/standard with rewrite and vocabulary
off. At that revision `Sources/larynx/main.swift` was byte-for-byte unchanged
from `8927727` (verified with git diff). The JSON contains the real pre-refactor
text, field names and types; timing values are observations, not performance targets.

Swift tests preserve all Transcript fields when round-tripping the old record.
`python3 tests/protocol.py` exercises the real file-fed serve, MCP and CLI paths;
it requires the existing downloaded speech model and never uses the microphone,
hotkey, clipboard or insertion. It compares timing types and nonnegative values,
not exact milliseconds. Tests do not modify dictionary or snippet files.
