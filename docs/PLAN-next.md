# Larynx: handoff and plan (updated Nov 10, 2026)

**Start with `docs/HANDOFF.md` (Nov 11): full status, rules for working with Colin, what is in flight.**


Start here. Colin uses Larynx for all his dictation now (Right Command, mostly into Claude desktop, Messages).
The roadmap is `docs/MASTER-PLAN.md` (Nov 10): the task-by-task plan to make Larynx better than Wispr Flow on every
row of its scoreboard. Execute from that file, top to bottom. This file is the short handoff: where things live, how
to work with Colin, lessons learned. Read README.md for the feature list and how it works.

## How to work with Colin on this
- Just do it: build, test, commit, push and install without asking (he's tired of manual steps). Don't ask him to
  run commands unless it's a privacy permission (TCC), which only he can change.
- Install with `./scripts/make-app.sh`, then restart ONLY with `./scripts/restart-app.sh` (waits until he isn't
  dictating). He dictates constantly; a restart mid-sentence loses his words, and a rebuild can trigger a ~2 min
  CoreML recompile ("Loading speech model...").
- Never run live paste tests while he's at the keyboard (they paste into his apps). Test with files (`larynx transcribe`),
  `larynx tidy`, `larynx fixes`, `larynx focus`, `larynx pill-demo`, or `LARYNX_FORCE_COPY=1`.
- No subagents unless he asks. Don't touch the Locust repo (integration doc lives in docs/INTEGRATION.md).
- Every new heuristic needs "must not change" tests: the vocabulary swap once turned "going" into "Golang" in his
  real messages. Check `~/Library/Logs/Larynx.log` for what he actually said and what came out.

## Phase Zero started (Nov 10, task 0.1)

- Task 0.1 is complete: Swift Testing covers 43 text fixtures, 26 rewrite guard expectations,
  100 ordinary sentences unchanged in all three modes, and six guard acceptance/rejection checks.
- On this Mac use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
  The selected Command Line Tools fail to load Testing macros; native build mode also fails to import Testing.
  The full Xcode command passes in 3.36 s wall (1.955 s test execution) without changing system settings.
- Fresh baseline from the existing release binary: rules 43/43, rewrite 26/26, spoken 264/300
  excluding known gaps, matching the prior score. The Python suite exits 1 for those existing spoken failures;
  it is not an all-green suite. Logs and all spoken results are under `bench/results/phase0-*`.
- Tests live in lowercase `tests/LarynxTextTests` with an explicit package path because this repository already
  uses `tests/`; this avoids a case-sensitive checkout problem. See its README for fixture semantics.
- Task 0.2 is complete: portable LarynxText contains Tidy, CleanupMode, CodeWords, Dictionary, Snippets and
  RewriteGuard. LarynxCore re-exports the text API and keeps frontmost-app lookup and Mac spelling.
  WordList abstraction defaults to the same NSSpellChecker behavior; the portable fallback has 56,372 SCOWL
  entries and bundled upstream notices. `make-app.sh` now includes the resource bundle.
- Task 0.2 checks: independent text-target build, 8 Swift tests, release build, and 343/343 release CLI text
  checks pass. See `bench/results/phase0-task02-*`. Task 0.3 is also complete: `finish` returns Codable Transcript/Step records; serve preserves the old fields
  and adds steps (empty until 0.4); confidence is optional/omitted until the speech wrapper exposes it. MCP
  keeps its text and adds structuredContent. Old result records decode with empty steps.
- Task 0.3 checks: 11 Swift tests and release build pass; `python3 tests/protocol.py` verifies file-fed CLI,
  serve IDs/verbatim/status, legacy fields/types/text, and MCP text plus structured fields. It never uses the
  microphone or pastes. Existing preview captured-variable Swift concurrency warnings remain in main.swift.
- Tasks 0.2/0.3 are installed in ~/Applications/Larynx.app, retaining the existing signing identity and bundle
  ID. Bundled resources and strict deep signature verification pass. The idle-safe restart script reported
  `Larynx ready` after the expected CoreML reload. No live paste test was run.
- Tasks 0.4 and 0.5 are complete together (Settings was a prerequisite of stage policy). `Pipeline` records
  snippet → dictionary → vocabularyCase → tidy → rewrite decisions; a matched snippet remains literal and
  stops the pipeline. Off stages skip work; shadow proposals do not affect delivered text or later stages.
  History persistence/mining of shadow proposals remains task 0.7.
- `main.swift` is now 25 lines of entry wiring. App/Session, Listen, Serve, Commands and Engine own the shell.
  Each utterance keeps its own lifecycle and target while another recording can begin. Preview UI is owned by
  the current session, and the single outstanding preview request gate is preserved. Vocabulary case terms are
  copied through a lock during background reload. No new text transformations were added.
- Settings reads optional settings.json with JSON > legacy defaults > built-in precedence (CLI overrides still
  win where supported). Menu writes are atomic and mirrored to defaults. Malformed edits retain the last valid
  object; unknown fields survive saves. See docs/SETTINGS.md for all 14 keys/defaults, reload timing and stage
  semantics. All existing preference consumers use Settings; the documentation coverage test enforces the list.
- Task 0.4/0.5 checks: 19 Swift tests, release build and file-fed protocol smoke pass. Full suite exactly equals
  the pre-phase baseline: rules 43/43, rewrite 26/26, spoken 264/300 excluding known gaps. All 410 raw/final
  strings and pass/fail/reasons match, including known gaps. The suite exits 1 for existing spoken failures;
  this is not an all-green speech suite. See bench/results/phase0-task04-*.
- Installed through make-app.sh with the existing signing identity/bundle ID; resources and strict deep
  signature verification pass. restart-app.sh reported `Larynx ready`. Live hotkey/paste and overlap behavior
  have not been exercised; only lifecycle tests, file-fed processing and app startup are covered in this task. The existing
  Cleaner Foundation Models deprecation remains; the old captured preview-variable warnings are gone.
- Push is optional per Colin's latest instruction. Task 0.2 is on origin/main; task 0.3 and the current work
  are kept as local commits for the main agent to review. Next implementation task: 0.6, History and crash spool.

## Where things stand

- Repo `~/work/larynx`, public at github.com/StopBanning/larynx, branch `main` (see push status above). Commit as
  `Colin <343690415+StopBanning@users.noreply.github.com>` with the Claude co-author line.
- App: `~/Applications/Larynx.app`, built by `./scripts/make-app.sh`, signed with Colin's free
  "Apple Development" identity (team 4U94C34XA7; `security find-identity -v -p codesigning` shows it). Permissions (Mic, Input Monitoring,
  Accessibility) are stored against that certificate, so rebuilds keep them. Do not change the bundle id
  `com.automatedworkflow.larynx` or the signing identity.
- Apple's on-device model (the rewrite) only works when signed with an Apple Development identity
  (self-signed gives ModelManagerError 1013).
- Colin's keyboard is a Keychron B1 Pro: no Fn, no Right Option reaches macOS. Right Command (keycode 54) is his talk key.
- Log: `~/Library/Logs/Larynx.log`. Models: `~/Library/Application Support/Larynx/models` (bark-3.0-clean default,
  parakeet-tdt-0.6b-v3). Dictionary: `~/Library/Application Support/Larynx/dictionary.json`.
- History and crash recovery: `python3 tests/history.py` (file-only, throwaway `LARYNX_DATA_DIR`; kills a fed
  dictation mid-transcription and checks the next run recovers it). Swift tests need full Xcode on this Mac:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Tests: `python3 tests/suite.py --rewrite auto` (about 7 min; `--only <id-part>`, `--voices Samantha --rates 175` for quick runs).
  Last full run (Nov 10): rules 43/43, rewrite 26/26, spoken 264/300 (misses are mishearings).
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

## Done since (Nov 9-10)
- Menu: Recent (last 10, memory only), Live Preview / AI Cleanup / Talk Key / Speech Model / Open at Login, Edit
  Dictionary / Vocabulary / Snippets, Reload Vocabulary. Opens at login by default (SMAppService).
- Pill: clear Liquid Glass (`NSGlassEffectView`, macOS 26), up to 3 lines, scrolls to newest words; preview only
  transcribes the last 12 s.
- Tidy rules: trailing "and"/"but", restarted questions ("can you could you"), filler "like" before intensifiers,
  same-kind corrections ("Tuesday, no Wednesday"). Code by voice (`CodeWords.swift`): case commands, "main dot swift",
  acronyms/brand spellings.
- Vocabulary (`Vocabulary.swift`): ~/work project names + ~70 dev terms + dictionary + vocabulary.txt, boosted by
  FluidAudio CTC 110M rescoring (`Transcriber.loadVocabulary`). FluidAudio's own rewritten text is far too eager, so
  only its one-word swaps are used, gated by `Transcriber.soundsAlike` (strict for real English words). `fixCase`
  spells non-English terms properly ("prisma" -> "Prisma").
- Learns from fixes (`Learner.swift`): 15 s after a paste it rereads the field (AX value) and learns sound-alike word
  changes. Built and unit-checked with `larynx fixes`; NOT yet confirmed in real use.
- Never loses text when no field has focus: `Inserter.focusedField` (AX) decides insert / copy only / paste+keep.
- Snippets (`snippets.json`, cue on its own expands).
- Latest full suite: rules 43/43, rewrite 26/26, spoken 264/300 (misses are speech mishearing synthetic voices).

## Open questions / candidates (all now covered by tasks in MASTER-PLAN.md)
- Confirm learning-from-fixes works in Claude desktop and Messages (AX value readable? Electron?).
- Voice commands on selected text ("make this shorter") with Apple's on-device model.
- Context from the text around the cursor (names already in a thread) to bias spelling.
- Real-world accuracy: mine Larynx.log for repeated misheard words and add to tests / vocabulary.
- Settings window instead of `defaults` switches; first-run onboarding for other people.
- Distribution: notarized DMG needs the paid Apple developer program ($99/yr); otherwise build from source.
- Windows / phone: not started.
- Long dictation: final transcription of 60 s+ clips is untested for speed; preview is fine.

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
- Restart the app only with `./scripts/restart-app.sh` (waits until Colin is not dictating). A rebuild can make CoreML
  recompile the model, about 2 minutes of "Loading speech model...".
- Don't spawn subagents; do the work inline.
- Switching privacy permissions is Colin's job; minimize the asks. Rebuilds no longer need them.
- Restart Larynx after a permission change; macOS applies Input Monitoring only on relaunch.
- Swift stores short string literals inline, so `strings` can't find them; check a long one.
- Toggling FluidAudio package traits needs `swift package clean` before building.
- NeMo inverse text normalization is too aggressive for dictation (tried, rejected).
