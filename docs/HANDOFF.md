# Larynx handoff (Nov 11, 2026)

**For the next session (Fable plans, Opus executes).** Colin's goal, his words: "put Wispr Flow to shame and be
free." Larynx is already his only dictation tool (about 600 dictations in two days, 90% into Claude desktop). Read
this file, then `docs/MASTER-PLAN.md` (roadmap, invariants, scoreboard, status table) and `docs/BENCHMARKS.md`.

**The ask:** review where Larynx stands, then write the next version of the plan: what would make it clearly better
than Wispr Flow on every row, more fleshed out, and more delightful, with tasks Opus can execute and test. Keep the
master plan's invariants (never lose words, never slower, never change a right word, local by default, free).

---

## How to work with Colin (keep these)

- Build, test, commit, push and install without asking. Commit as
  `Colin <343690415+StopBanning@users.noreply.github.com>` with the Claude co-author line. Never put his email
  addresses anywhere public. Never publish the signed app binary: its certificate names his Apple ID email.
- Install with `./scripts/make-app.sh`; restart ONLY with `./scripts/restart-app.sh` (waits until he is idle, treats
  "recording..." and "hands-free" as busy). He dictates constantly.
- Never paste into his apps from tests. Test with files (`larynx listen --feed`, `larynx transcribe`), `larynx tidy`,
  `larynx numbers`, the unit tests, `LARYNX_FORCE_COPY=1`, or `larynx pill-demo`.
- Don't change TCC/privacy permissions, keychain, signing identity or bundle id `com.automatedworkflow.larynx`.
- No subagents unless asked. Don't touch the Locust repo. Don't register the MCP server in his configs.
- Downloads (models, datasets) need his OK first (name, source, size). Scratch data in `~/work/scratch/larynx-*`.
- **Investigate his sentences.** He talks to you by dictating through Larynx. Read every message for Larynx mistakes
  (misheard words, numbers, stray commas, wrong capitals, garbles). Check `larynx history --search` for the raw text
  to see which layer made it. Fix what a safe rule can fix (with must-not-change tests checked against his real
  dictations, see below), add phrases to his dictionary when safe, and log the rest under the right plan task.
- Every new automatic text change: tests for what must change AND what must not, then run it over his real
  dictations (`larynx history --json` and old `~/Library/Logs/Larynx.log` lines) and read every line it would change
  before shipping. This caught "going -> Golang", "next -> Nuxt", "one to one to -> one to", "You -> you".
- On this Mac, Swift tests need full Xcode: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## Where things are

| What | Where |
| --- | --- |
| Repo | `~/work/larynx`, github.com/StopBanning/larynx (public, MIT), branch `main`, tags v0.1.0-v0.5.0, release v0.5.0 |
| App | `~/Applications/Larynx.app` (menu bar), log `~/Library/Logs/Larynx.log` (no transcript text unless `debugText: on`) |
| User data | `~/Library/Application Support/Larynx/`: `settings.json`, `history.sqlite`, `dictionary.json`, `vocabulary.txt`, `snippets.json`, `suggestions.json`, `privacy.json`, `models/` |
| Models on disk | bark-3.0-clean (default), parakeet-tdt-0.6b-v3, parakeet-ultra, parakeet-unified-en-0.6b, bark-3.0, parakeet-ctc-110m (vocabulary) |
| Benchmark audio | `~/work/scratch/larynx-bench` (jargon, noise10, noise5, whisper, ls-clean, ls-other, long; 930 clips) |
| Docs | README, CHANGELOG, docs/MASTER-PLAN.md, BENCHMARKS.md, SETTINGS.md, PRIVACY.md, INTEGRATION.md, WINDOWS.md, PLAN-next.md |

## What Larynx does today (all local, free)

- Hold-to-talk on any of Fn / Right Option / Right Command (his macro pad sends one); **hands-free** by double-tap
  (next press finishes, Esc cancels, 30 min cap) or a one-press Hands-Free Key.
- Speech: Bark 3.0 Clean (Parakeet family, Neural Engine) by default; `engine` can be `parakeet`, `ultra`,
  `unified`, `bark3`. Second-chance retry with another model when the first hears nothing.
- Cleanup pipeline (typed, every step recorded, each stage `off | shadow | on`): snippet -> dictionary ->
  vocabularyCase -> tidy -> **numbers** -> AI rewrite. Tidy: fillers, stutters, repeats, false starts, same-kind
  corrections ("Tuesday, no Wednesday"), trailing "and", code by voice (camelCase, file names), spelled acronyms
  ("A P I" -> API). Numbers: "Opus five point five" -> 5.5, "three percent" -> 3%, "two hundred K" -> 200K, times,
  years, with small numbers kept as words. AI rewrite (Apple Foundation Models) only outside AI apps and only when a
  cue fires, behind a guard.
- Per-app modes (AI chats/terminals light touch; Mail/Messages full sentences).
- Vocabulary boosting (CTC 110M rescoring) from ~/work project names, dictionary, vocabulary.txt, AI model names and
  ~80 dev terms. Built-in terms can never replace a real English word; only the user's own words can.
- **Self-learning:** repeats within 90 s with a word swapped teach the fix (made-up word -> dictionary, new name ->
  vocabulary, real-word swaps -> suggestions only); editing a pasted word in place teaches it too (samples the field
  every second for 20 s; works in Messages and Claude). Menu Undo Learned. `larynx mine`.
- **Never loses words:** target app locked at key-down, focus check, clipboard fallback, crash spool (audio on disk
  before transcription, recovered at next launch), history (SQLite + full-text search, 30 days, `larynx history`).
  Password fields and password managers never stored.
- **Liquid Glass pill:** one capsule with the target app's icon, a voice-driven waveform and live words; sits above
  the focused text field; warns when the mic hears nothing; lock for private fields and hands-free; Pill Glass
  slider (clear to solid) in the menu.
- Menu bar: status, Recent (from history), Undo Learned, Live Preview, Pill Glass, AI Cleanup, Talk Key,
  Double-Tap for Hands-Free, Hands-Free Key, Speech Model, Open at Login, edit dictionary/vocabulary/snippets.
- Developer surface: CLI, `serve` JSON-lines protocol (Locust integration contract), `mcp` server, `listen --feed`.
- Windows: feasibility proven in CI (text engine passes on Windows/Linux; Parakeet runs on a Windows CPU at 0.15x
  real time). Plan in docs/WINDOWS.md; no Windows app yet.

## Numbers

- Swift tests: 38 (all pass). Python: `tests/suite.py --rewrite auto` (rules, rewrite benchmark, 300 spoken clips),
  `tests/protocol.py`, `tests/history.py`. CI: macOS (build + tests), portable (Windows + Linux text engine,
  Windows speech).
- Latest suite with Bark Clean (before today's tidy rules): rules 45/45, rewrite 26/26, spoken 264/300.
- Real use: key-up to text p50 ~0.11 s, p90 ~0.34 s.
- Speech benchmark (docs/BENCHMARKS.md): Parakeet Ultra / Unified make ~37% fewer word errors than Bark Clean on
  jargon, noise and hard speech, and spell names right twice as often (54-56% vs 26%). Both fast (p90 41-54 ms).

## In flight at handoff (finish first)

**Update, later on Nov 11:** item 1 is done. Bark Clean reran at 264/300 (no regression), Ultra at 272/300, so the
default is now Parakeet Ultra, installed. The plan this handoff asked for is `docs/PLAN-v1.md`: work from it.

1. **Switching the default to Parakeet Ultra.** Ultra failed the cleanup gate (257 vs Clean 264) because it types
   false starts and repeats verbatim. New tidy rules (uncommitted at writing, committed with this handoff) remove
   false starts ("I went to the, I drove" -> "I drove"), 2-3 word repeats without a comma, mid-sentence er/ah/eh, and
   "Aye, I, I"; they changed exactly one line of Colin's 599 real dictations (correctly). A rerun of the suite with
   Ultra and with Clean was running: results in `bench/results/suite2-ultra.log` and `suite2-clean.log`.
   **Ultra's rerun: 272/300** (was 257; Clean's last score 264), text rules 59/59. It clears the bar. Still to
   read: `suite2-clean.log` (Clean with the new rules, to confirm no regression).
   Rule (master plan 1.4): switch if Ultra scores >= 262/300 and Clean didn't regress. If so: change the default in
   `Settings.Key.engine` and `App/Engine.swift`, add Ultra to the Speech Model menu (recommended, 25 languages), update
   SETTINGS/README/BENCHMARKS/CHANGELOG, install, then watch his next dictations closely.
2. CHANGELOG "Unreleased" holds hands-free, numbers, acronyms, Nuxt fix, learning fixes; release v0.5.0 once (1) lands.

## Known gaps (evidence from his real dictation)

- Homophones by sound alone: "reel" heard as "real"/"wheel" (phrase entries in his dictionary for now).
- Misheard names the model never saw: "OpenS" for Opus, "Russ" for Rust, "Logus" for Locust.
- Stray commas from the model ("something that actually, is").
- Garbled mumbles ("it should what would turn us").
- AI rewrite still triggered by number words in Mail/Messages although the numbers stage handles them (1.6 s each).
- Learning from edits not yet seen firing in real use since the every-second fix.
- No settings window or onboarding; install is build-from-source (notarized DMG needs the paid Apple account).
- No Windows app, no phone app, no meeting notes.

## Candidate directions for the next plan (Fable decides)

- Screen context (master plan 2.1-2.3): read the text around the cursor and on screen locally, bias names and
  homophones, match capitalization to what's already in the field. Likely the biggest accuracy win left.
- Consensus or second opinion (1.3): run Ultra and Clean, take the better words; flag doubtful results.
- Streaming transcription during recording (4.2) so long hands-free dictations finish instantly.
- Command Mode and voice edits on selected text with a local model (3.5), spoken formatting and lists (3.1), styles.
- A real app: settings window, onboarding, history window with audio playback, scratchpad (phase 6).
- Distribution so others can use it: signed builds via CI, Homebrew, auto-update (needs Colin's decision C1).
- Windows app (docs/WINDOWS.md), then iPhone keyboard.
- Things Wispr Flow can't do (phase 9): voice to agents both ways (MCP listen/speak), only-your-voice speaker lock,
  voice actions, a model that adapts to you, the open dictation benchmark.
