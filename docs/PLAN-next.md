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
  Last full run: rules 25/25, rewrite 22/22, spoken 264/300 (misses are mishearings), self-corrections 28/40.
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

## Item 0 (in progress, do first): bare "no" corrections

Found by Colin in Messages: "Tuesday, no Wednesday" / "Tuesday. No, Wednesday." went through untouched (no trigger),
and once triggered, Apple's model sometimes keeps the WRONG half ("Put me down for Tuesday.").
Done so far (uncommitted work committed as WIP, NOT yet in the installed app):
- `Cleaner.bareNoCue` triggers on ", no X" / ". No, X" (excludes no problem/worries/thanks/...).
- Prompt has two bare-no examples; correction rule says keep the part said after the cue.
- Guard `correctedWord(in:)`: for corrections, the first word after the cue must survive, else fall back to the tidied text.
  Colin's exact Messages sentences now come out "...for Wednesday." Benchmark: 24/26.
Still to fix:
1. Guard bug: in "two, no wait, three thirty" the regex's ", no" branch matches first and picks "wait" as the
   corrected word, rejecting a good rewrite. Match the longer cues first (put `no wait`/`wait no` before the bare
   `[,.]\s+no`, or skip "wait" as the captured word) and skip number words after them.
2. "Put me down for Tuesday, no Wednesday" and "Book me for Friday, no Saturday": the model keeps the first half;
   the guard now rejects it safely (text stays as spoken). Try one retry with a second prompt variant, or a
   deterministic rule for the common shape "<X>, no <Y>" where X and Y are the same kind of word (weekday, month,
   number, time): replace X with Y and delete ", no Y". Prefer the rule for weekdays/months: exact and instant.
3. Re-run `python3 tests/suite.py --only r-` three times (target 26/26), then a full run with `--rewrite auto`.
4. Rebuild the app (`./scripts/make-app.sh`; permissions persist) and self-test in Messages-like mode with TextEdit
   in front: "I wanna add you on my schedule for Tuesday, no Wednesday."

## Work items, in order

### 1. Never lose a transcript (small)
- `Inserter`: add `copyOnly(_ text:)` (set the clipboard, no restore).
- In `runListen` onUp (`Sources/larynx/main.swift`): when `Inserter.paste` throws (not trusted, Secure Input, any
  error), call `copyOnly(text)`, set status "Copied, press ⌘V", play a distinct sound, log `copied:`.
- `serve` `stop` with `paste: true`: same fallback, report `"delivered": "inserted" | "copied"`.
- Done when: with Accessibility off (simulate by forcing the error path behind an env var such as
  `LARYNX_FORCE_COPY=1`), the text ends up on the clipboard and the log says copied.

### 2. Lock the target app at key-down (small)
- At key-down capture `NSWorkspace.shared.frontmostApplication` (pid, bundle id) and a session counter.
- Pick the cleanup mode from the captured app, not the app in front at release.
- Before pasting: if the front app is no longer the captured one, `activate()` it, wait about 150 ms,
  check it is in front, then paste; if it can't be brought back, fall back to item 1 (copy).
- Each utterance keeps its own target; a slow result never uses a later session's target.
- Done when: start in TextEdit, switch to another app mid-sentence, release; text lands in TextEdit.

### 3. Retry with the other model when the result is empty (small)
- `Recorder`: expose an RMS level for the clip.
- If the transcript is empty, the clip is at least 0.5 s and has speech-level energy, retry with the other
  engine (`clean` ↔ `parakeet`) when its model folder already exists (never download). Load it lazily in a
  second `Transcriber`. Log `fallback engine:`.
- Done when: a unit-style check with a clip the primary returns empty for triggers the fallback (force with an
  env var if no natural example).

### 4. Live preview pill (medium)
- A small non-activating floating panel (`NSPanel`, `.nonactivatingPanel`, borderless, `.floating` level,
  ignores mouse, bottom center) shown while recording.
- Every 0.8 s while recording, transcribe a snapshot of the samples so far (batch model, about 60 ms) and show
  the text; show "Transcribing…" after release; hide after paste. Never take focus.
- `Recorder`: add `snapshot() -> [Float]`. Skip a tick if the previous preview is still running.
- Preference to turn it off: `defaults write com.automatedworkflow.larynx preview off`.
- Done when: holding the key shows words appearing; focus never leaves the target app (paste still lands).

### 5. MCP server for agents (medium)
- `larynx mcp`: JSON-RPC 2.0 over stdio (`initialize`, `tools/list`, `tools/call`, `notifications/initialized`).
- Tools: `transcribe_file {path, mode?}`, `clean_text {text, mode?}` (dictionary + tidy + rewrite),
  `add_dictionary_word {heard, written}`, `status`.
- Document in `docs/INTEGRATION.md` with a Claude Code config snippet (`claude mcp add larynx -- ~/work/larynx/.build/release/larynx mcp`). Do not register it in Colin's configs.
- Done when: a scripted JSON-RPC session lists the tools and `transcribe_file` returns text.

### 6. Test, commit, rebuild
- `swift build -c release`, quick suite (`--voices Samantha --rates 175 --rewrite auto`), then full suite once.
- Live self-test of items 1, 2 and 4 with the rcmd trick and TextEdit.
- `./scripts/make-app.sh`, relaunch, confirm `ready:` with no permission prompts.
- Update README (features, status), commit, push. Never ask Colin to commit; just do it.

## Later (not in this round)
- Learn vocabulary from code in `~/work` (identifiers, file names) and feed FluidAudio's custom vocabulary.
- Learn from fixes made right after a paste (Accessibility read of the field) and offer dictionary entries.
- Windows helper.

## Rules learned the hard way
- Don't spawn subagents; do the work inline.
- Switching privacy permissions is Colin's job; minimize the asks. Rebuilds no longer need them.
- Restart Larynx after a permission change; macOS applies Input Monitoring only on relaunch.
- Swift stores short string literals inline, so `strings` can't find them; check a long one.
- Toggling FluidAudio package traits needs `swift package clean` before building.
- NeMo inverse text normalization is too aggressive for dictation (tried, rejected).
