# Larynx: next build plan (written Nov 8, 2026)

Goal: make dictation never lose text or land in the wrong app, show live text while you talk, and let agents use
Larynx. Ideas taken from VoiceStudio's dictation docs (AGPL: ideas only, no code copied).

## Where things stand

- Repo `~/work/larynx`, public at github.com/StopBanning/larynx, branch `main`, all pushed. Commit as
  `Colin <343690415+StopBanning@users.noreply.github.com>` with the Claude co-author line.
- App: `~/Applications/Larynx.app`, built by `./scripts/make-app.sh`, signed with Colin's free
  "Apple Development: colindavid95@live.com (4U94C34XA7)" identity. Permissions (Mic, Input Monitoring,
  Accessibility) are stored against that certificate, so rebuilds keep them. Do not change the bundle id
  `com.automatedworkflow.larynx` or the signing identity.
- Apple's on-device model (the rewrite) only works when signed with an Apple Development identity
  (self-signed gives ModelManagerError 1013).
- Colin's keyboard is a Keychron B1 Pro: no Fn, no Right Option reaches macOS. Right Command (keycode 54) is his talk key.
- Log: `~/Library/Logs/Larynx.log`. Models: `~/Library/Application Support/Larynx/models` (bark-3.0-clean default,
  parakeet-tdt-0.6b-v3). Dictionary: `~/Library/Application Support/Larynx/dictionary.json`.
- Tests: `python3 tests/suite.py --rewrite auto` (about 7 min; `--only <id-part>`, `--voices Samantha --rates 175` for quick runs).
  Last full run (v0.3.0): rules 28/28, rewrite 26/26, spoken 264/300 (misses are mishearings), self-corrections 38/40.
- Self-test without Colin: `scratchpad/rcmd down|up` posts a Right Command press (rebuild it from the snippet below);
  speak with `say`; read the log. Bring TextEdit to front for non-AI modes:
  `osascript -e 'tell application "TextEdit" to make new document' -e 'tell application "TextEdit" to activate'`.

```swift
// rcmd.swift: swiftc -O rcmd.swift -o rcmd
import ApplicationServices
let down = CommandLine.arguments.dropFirst().first == "down"
let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 54, keyDown: down)!
e.type = .flagsChanged; e.flags = down ? .maskCommand : []; e.post(tap: .cghidEventTap)
```

## Done (Nov 8, 2026, v0.3.0)

- Item 0, bare "no" corrections: a deterministic same-kind rule in `Tidy.sameKindCorrections` (weekday, month,
  number or time on both sides: keep the second) plus the guard fix for "no wait". Rewrite benchmark 26/26 on 3 runs.
- Item 1, copy fallback: `Inserter.deliver` falls back to `copyOnly`; menu shows "Copied, press ⌘V"; `serve` reports
  `delivered`. Verified live with `LARYNX_FORCE_COPY=1` (log `copied:`, text on the clipboard).
- Item 2, target lock: the app is captured at key-down and reactivated before pasting. Verified live by accident
  (started in Safari, Finder activated mid-sentence, text went back to Safari).
- Item 3, empty-result retry: `transcribeWithFallback`, needs `--models-dir` (the app always has it). Verified with
  `LARYNX_FORCE_FALLBACK=1`. First use compiles the second model (about 30 s, once).
- Item 4, live preview pill: `Sources/larynx/Pill.swift`. Built and running; not yet seen on screen by Colin.
- Item 5, `larynx mcp`: verified with a scripted JSON-RPC session (all 4 tools).

Lesson: never run live paste tests while Colin is at the keyboard. TextEdit didn't come to the front and two test
lines pasted into his Safari. Use `LARYNX_FORCE_COPY=1` (clipboard only, restore it after) or file transcription.

## Later (not in this round)
- Done (Nov 9): vocabulary from `~/work` project names + dictionary + vocabulary.txt, via FluidAudio CTC rescoring filtered by a sounds-alike check (its raw rewrite is too eager: "update to GitHub" -> "update to Govee").
- Learn from fixes made right after a paste (Accessibility read of the field) and offer dictionary entries.
- Windows helper.

## Rules learned the hard way
- Don't spawn subagents; do the work inline.
- Switching privacy permissions is Colin's job; minimize the asks. Rebuilds no longer need them.
- Restart Larynx after a permission change; macOS applies Input Monitoring only on relaunch.
- Swift stores short string literals inline, so `strings` can't find them; check a long one.
- Toggling FluidAudio package traits needs `swift package clean` before building.
- NeMo inverse text normalization is too aggressive for dictation (tried, rejected).
