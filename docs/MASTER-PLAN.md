# Larynx master plan: free, open, local, and better than Wispr Flow

Written Nov 10, 2026 for an executing agent (Opus). Read this whole file once, then work top to bottom.
`docs/PLAN-next.md` stays as the short handoff (where things live, how to work with Colin). This file is the roadmap.

**Goal (Colin's words):** "a free, open source, better version of this. Indisputable across the board. Sacrifice
nothing." So the bar is not "good for a local app". It is: on every row of the scoreboard in section 2, Larynx is
ahead or level, and there is a test or benchmark file in this repo that proves it. Where a row cannot be won (for
example a compliance certificate), the README says so plainly instead of pretending.

Wispr Flow facts in this file come from its public website on Nov 10, 2026 (home, features, pricing, developers,
data controls, what's new). Re-check them before publishing any comparison. Use behavior only: never its code,
prompts, assets or name in our product.

---

## 1. Rules for the executor

### 1.1 Working with Colin (unchanged, these override everything below)
- Build, test, commit, push and install without asking. Commit as
  `Colin <343690415+StopBanning@users.noreply.github.com>` plus the Claude co-author line. Never put his email
  addresses in commits or docs.
- Install with `./scripts/make-app.sh`; restart ONLY with `./scripts/restart-app.sh` (it waits until he is idle).
- Never paste into his apps. Tests paste only into Larynx's own capture window (task 0.9) and only when the Mac has
  been idle for 5 minutes (`scripts/when-idle.sh`, task 0.9). Everything else is tested with files.
- Never change privacy permissions (TCC), keychain trust, security settings or the signing identity / bundle id.
  If a task needs a new permission, stop that task, write the exact switch he must flip into section 12, move on.
- No subagents unless he asks. Never touch the Locust repo. Do not register the MCP server in his configs.
- Scratch output (datasets, model caches, builds) goes under `~/work/scratch/larynx-*`; delete it when done.
- He dictates all day, mostly into Claude desktop. Anything that makes the app slower, flakier or wrong in that app
  is a regression even if a benchmark improved.

### 1.2 Invariants (a change that breaks one is reverted, not patched forward)
1. **Never lose words.** Every finished dictation ends up inserted, or on the clipboard, or in History. Crash
   included: audio is written to History's spool before transcription starts (task 0.6).
2. **Never slower.** Key-up to text p50 <= 150 ms and p90 <= 350 ms for dictations under 60 s on this Mac (M6,
   16 GB). Measured from real use on Nov 10: p50 111 ms, p90 336 ms. Optional layers (LLM polish, second opinion)
   must have a deadline after which the plain result is delivered.
3. **Never change a word that was right.** Every automatic text change needs must-not-change tests and ships
   through shadow mode first (1.4). The "going" -> "Golang" bug is the reason.
4. **Local by default.** After models are downloaded the app opens no network connections. Anything that leaves the
   Mac (a user-supplied LLM endpoint, an update check) is off by default, labelled, and listed in docs/PRIVACY.md.
   Task 6.9 adds a test that fails if a socket opens.
5. **Free means free.** No accounts, no limits, no telemetry, no paid tier.
6. **`larynx serve` and `larynx mcp` stay compatible.** Add fields, never rename or remove
   (docs/INTEGRATION.md is a contract with Locust).

### 1.3 How to execute a task
- Tasks are numbered `phase.task`. Do phases in the order of section 3. Inside a phase, do tasks in order unless one
  is blocked on Colin (section 12); then skip it and note that in the status table.
- Before a phase: run `swift test` and `python3 tests/suite.py --rewrite auto`, save the output under
  `bench/results/`. After each task: `swift test`. After each phase: full suite plus `larynx bench` (task 0.8).
- One task = one or a few commits, pushed. Message says what changed for the user, like the existing history.
- Verify every external API before using it (FluidAudio is pinned at 0.18.3 in `.build/checkouts/FluidAudio`; its
  `Documentation/` folder is the reference. Apple APIs: check the SDK headers, not memory). If a named API does
  not exist, find the nearest real one and note the difference in the commit.
- When a task says "decide by data", run the named benchmark, write the numbers into `docs/BENCHMARKS.md`, and
  apply the decision rule given. Do not pick by feel.
- Update section 11 (status) at the end of every task: done / skipped (why) / blocked (on what).
- If a task turns out to be wrong or impossible, say so in section 11 with the evidence and continue. Do not
  quietly build something else.

### 1.4 Shadow mode (how new automatic text changes ship)
Every pipeline stage has a setting `off | shadow | on`.
1. Build the stage with tests (including at least as many must-not-change cases as change cases).
2. Ship it as `shadow`: it runs on every real dictation, the text is NOT changed, and History records
   `stage, before, after` for each would-be change.
3. After at least 200 real dictations and 48 hours, run `larynx mine --shadow <stage>` (task 1.7). Read every
   would-be change. If any is wrong: add it as a must-not-change test, fix, restart the count.
4. Zero wrong changes -> switch to `on`, note the count in the commit message.

---

## 2. Scoreboard (the definition of "better")

"Flips in" is the task that turns the row. v1.0 ships when no row says BEHIND except the ones marked "cannot".

| # | Area | Wispr Flow (public pages) | Larynx today (Nov 10) | Today | Flips in |
|---|---|---|---|---|---|
| 1 | Price and limits | Free with weekly limits; Pro $15/user/mo | Free, unlimited | AHEAD | - |
| 2 | Where audio goes | "Transcription always occurs on the cloud" | Never leaves the Mac | AHEAD | prove: 6.9 |
| 3 | Works offline | No | Yes | AHEAD | - |
| 4 | Account | Required | None | AHEAD | - |
| 5 | Open source | No | MIT | AHEAD | - |
| 6 | Speed, key-up to text | Not measured by us | p50 0.11 s, p90 0.34 s | likely AHEAD, unproven | 0.9 |
| 7 | Accuracy, clean English | Own model ("Canto"), claims lowest WER on real dictation | Bark 3.0 Clean (0.6B, local) | UNKNOWN | 0.8, 0.9, 1.4 |
| 8 | Accuracy in noise, music, whisper | Claims best real-time model on a stress set | Untested | UNKNOWN, assume BEHIND | 4.4 |
| 9 | Names and jargon | Dictionary + learns from edits + reads surrounding text | Vocabulary boost, project names, learns from edits (unproven live) | BEHIND | 1.6, 2.2 |
| 10 | Fillers, repeats, false starts | Yes | Yes (model + rules) | LEVEL | - |
| 11 | Self-correction ("2... actually 3") | Any phrase | Same-kind rule everywhere; LLM only outside AI apps, 1.6 s median | BEHIND | 1.5, 3.4 |
| 12 | Numbers, money, times as digits | Yes | Only when the LLM runs; never in AI apps (30 of 447 real dictations left number words) | BEHIND | 1.1 |
| 13 | Punctuation | Automatic + spoken ("comma", "new line") | Automatic only; stray and missing commas seen in real use | BEHIND | 1.4, 3.1 |
| 14 | Lists and paragraphs | Numbered lists from speech | No | BEHIND | 3.1 |
| 15 | Tone / styles per app | Formal, casual, very casual by app category | 3 fixed modes by app | BEHIND | 3.2, 2.5 |
| 16 | Context awareness | App, text around cursor, window text | App only | BEHIND | 2.1-2.3 |
| 17 | Snippets | Yes, rich text | Yes, plain text | BEHIND | 6.5 |
| 18 | Edit by voice (Command Mode) | Yes | No | BEHIND | 3.5 |
| 19 | Hands-free (lock) mode | Double-tap the key | No | BEHIND | 4.1 |
| 20 | Languages | 100+, auto-detect, mid-sentence switching | 25 (manual model switch) | BEHIND | 5 |
| 21 | Code: cases, acronyms, dev jargon | Yes | Yes | LEVEL | - |
| 22 | Code: file tagging in editors | Cursor, Windsurf | No | BEHIND | 2.4 |
| 23 | History, search, audio playback | 14 days with audio | Last 10 in memory | BEHIND | 0.6, 6.3 |
| 24 | Scratchpad notes | Yes | No | BEHIND | 6.4 |
| 25 | Microphones | Priority list, auto-switch, virtual mics, no-sound warning | System default only | BEHIND | 4.3 |
| 26 | Never lose text / right app | "Switchback", history | Focus check, clipboard fallback, target lock | LEVEL | 0.6 makes it AHEAD |
| 27 | Settings, onboarding, install, updates | Polished app, installer, auto-update | Menu + `defaults`, build from source | BEHIND | 6 |
| 28 | Automation: CLI, JSON API, MCP for dictation | MCP for meeting notes only | CLI, JSON lines, MCP | AHEAD | 9 widens it |
| 29 | Sync and team sharing | Cloud sync, shared dictionary/snippets | No | BEHIND | 6.5, 6.6 |
| 30 | Meeting notes (Notetaker) | Yes: speakers, summaries, ask across meetings | No | BEHIND | 7 |
| 31 | Windows, iPhone, Android | All three | Mac only | BEHIND | 8 |
| 32 | Compliance certificates, SSO, admin console | SOC 2, ISO 27001, HIPAA BAA, SSO | None; nothing leaves the Mac so there is no processor to certify | cannot (say so) | docs only |
| 33 | Things only a local, open tool can do | - | - | - | 9 |

Honest count today: ahead on 6, level on 3, unknown on 3, behind on 20. Most "behind" rows are features, not
research: the speech library already ships the hard parts (section 13). Rows 7 and 8 are the only ones where the
outcome is uncertain, so phase 0 builds the measuring tools first.

**Evidence from Colin's real use (447 dictations, 92% into Claude desktop):**
- Number words left as words in 30 (6.7%), 29 of them in AI apps where no rewrite runs. Examples of the shape:
  "ninety-four", "two hundred K", "version five point two", "twenty X".
- Said the same thing again right after in 15 (3.4%): the clearest signal that the first result was wrong.
- A run of ALL-CAPS nonsense words in 2: the speech model hallucinating on unclear audio.
- Misheard names and jargon that no dictionary could have known in advance (product names, a stock ticker spelled
  as letters, "cache" heard as "cash").
- Stray commas ("such a good, check") in about 3%; long sentences with punctuation missing in about 4%.
- Several results end mid-word or on a dangling word: possibly the recording stops the instant the key is released.
- The LLM rewrite ran 12 times: median 1.6 s, worst 3.0 s. That breaks invariant 2 for Messages.
- "Learned from your fix" fired 0 times in 423 inserts. Either it does not work in Claude desktop / Messages or he
  sends before the 15 s check. Unverified feature = not a feature.
- The log file stores every transcript as plain text forever, while the README says Recent is "never saved to
  disk". Fix in 0.6.

---

## 3. Order of work

| Phase | Name | Size | Release |
|---|---|---|---|
| 0 | Foundations: tests, structure, history, benchmarks | L | - |
| 1 | Fix what real use shows | L | v0.4 |
| 2 | Context engine | L | v0.5 |
| 4 | Capture and control (hands-free, mics, noise, paste hardening) | L | v0.6 |
| 3 | Formatting, styles, local LLM polish, Command Mode | L | v0.7 |
| 6 | The app: settings, onboarding, history, install, updates | L | v0.9 |
| 5 | 100+ languages | M | v1.0 = "better on the Mac, row by row" |
| 9 | Things Wispr Flow cannot do (pick 3) | M each | v1.x |
| 7 | Meeting notes | XL | v1.x |
| 8 | Windows, iPhone, Android | XL each | v2 |

Phase 4 runs before 3 on purpose: capture problems lose words, formatting problems only look bad.

---

## 4. Phase 0: Foundations

Nothing here changes what Colin sees except History. It makes the next 60 tasks safe and measurable.

**0.1 `swift test`.** Add `Tests/LarynxTextTests` (Swift Testing). Load `tests/cases.json` and run every `text`
case through `Tidy.apply` and every `rewrite` case's guard expectations through `Cleaner.guardProblem`. Add a
`mustNotChange` array to cases.json (input == expected) and seed it with 100 ordinary sentences.
Done when: `swift test` passes in under 10 s and runs the 43 text cases.

**0.2 Split the package.** Three targets:
- `LarynxText`: pure Foundation, no AppKit. Tidy, CodeWords, Snippets, Dictionary, the Cleaner guard, and later
  Numbers, Formatting, Styles. This is the part other platforms will share (phase 8).
- `LarynxCore`: audio, speech engines, Accessibility, insertion, vocabulary, the Apple-model call. Depends on
  LarynxText.
- `larynx`: CLI and app.
`CleanupMode.frontmost()` (uses NSWorkspace) moves to LarynxCore. `Vocabulary.isEnglish` (NSSpellChecker) goes
behind a `WordList` protocol; LarynxText gets a bundled word-list fallback (a plain text resource, about 60k
common English words, licence checked and recorded in README).
Done when: `swift build --target LarynxText` succeeds and `grep -l "import AppKit" Sources/LarynxText` is empty.

**0.3 Typed transcript.** Replace the `[String: Any]` returned by `finish` in `Sources/larynx/main.swift` with
`struct Transcript: Codable` (text, raw, engine, mode, audioSeconds, asrMs, rewriteMs, totalMs, rewrite note,
confidence, `steps: [Step]` where Step = stage, before, after, applied). `serve` and `mcp` encode the same JSON
keys as today plus new ones.
Done when: a golden-file test proves `serve` output for a fixed audio file has every key it had at commit 8927727.

**0.4 Pipeline.** `Pipeline` in LarynxCore: ordered stages, each `(Transcript, Context) -> Transcript`, each with
`off | shadow | on` from Settings, each appending a Step. Initial order = today's behavior exactly:
snippet match -> dictionary -> vocabulary case -> tidy -> rewrite. `main.swift` shrinks to wiring. Split the
remaining globals in main.swift into `App/Session.swift` (state machine: idle, recording, finishing, delivering),
`App/Listen.swift`, `App/Serve.swift`, `App/Commands.swift`.
Done when: full suite numbers equal the pre-phase baseline exactly.

**0.5 Settings.** `Settings` type: reads `~/Library/Application Support/Larynx/settings.json`, falls back to the
existing `defaults` keys (they keep working), reloads when the file changes. Every setting in this plan goes
through it. Write `docs/SETTINGS.md` listing every key, default and meaning; a test fails if a key is undocumented.

**0.6 History.** `History.swift`, SQLite through the system `libsqlite3` (no new dependency), file
`~/Library/Application Support/Larynx/history.sqlite`, FTS5 index on text.
- Row: id, time, app bundle id, window title hash (not the title), mode, engine, raw, text, steps JSON,
  audioSeconds, totalMs, delivery, audio file path (nullable), flags.
- Spool: at key-up the samples are written to `history/spool/<id>.caf` BEFORE transcription. On success the spool
  file is deleted (or moved to `history/audio/` when `keepAudio` is on). On launch, leftover spool files are
  transcribed and offered in the menu as "Recovered dictation". This is invariant 1 surviving a crash.
- Settings: `history` = `on` (default, 30 days of text) or `off` (memory only, as today); `keepAudio` = `off`
  (default) or a number of days. Password fields and apps on the privacy list (2.1) are never stored.
- The log stops printing transcript text. It prints id, timing, app, delivery and stage names. `debugText: true`
  restores the old lines (leave it off).
- Menu "Recent" reads History. `larynx history [--search q] [--json]` prints it.
- Update README (the "never saved to disk" sentence) and add `docs/PRIVACY.md`.
Done when: killing the app with `kill -9` during transcription of a file-fed dictation leads to a "Recovered
dictation" on next launch (test with `larynx listen --feed <file>`, see 0.9).

**0.7 Wire shadow mode** (1.4) into Pipeline and History; `larynx mine --shadow <stage>` lists would-be changes.

**0.8 `larynx bench`.** A benchmark anyone can rerun. Data lives in `~/work/scratch/larynx-bench`, never in git.
- Sets: (a) LibriSpeech test-clean and test-other (OpenSLR 12); (b) `jargon`: 200 sentences full of tech and
  product names with punctuated references, spoken by `say` voices and by FluidAudio TTS voices (needs the `TTS`
  package trait in a separate bench-only target so the app binary does not grow); (c) `noise`: set (b) mixed with
  music, babble and pink noise at 20, 10 and 5 dB SNR (use a small CC-licensed noise subset; record the source);
  (d) `whisper`: set (b) spoken with `say -v Whisper` and at low gain; (e) `cleanup`: today's spoken suite;
  (f) `long`: ten 3-10 minute readings stitched from LibriSpeech.
- Metrics per engine and set: WER (one normalizer for all engines, the one in tests/suite.py moved to a shared
  module), punctuation F1 on sets with punctuated references, name accuracy (share of listed names spelled
  exactly), real-time factor, latency p50/p90, peak memory (`/usr/bin/time -l`).
- Output: `bench/results/<date>-<commit>.json` and a regenerated `docs/BENCHMARKS.md` table.
Done when: `larynx bench --engine clean --set all` finishes and BENCHMARKS.md has a first full row.

**0.9 Head-to-head rig and safe live tests.**
- `larynx capture-window`: a small window with one text view that logs every text change with a timestamp to
  stdout. All live paste tests target this window only.
- `larynx listen --feed <audio>`: feeds a file through the Recorder path instead of the microphone, so the whole
  live path (hotkey, preview, pipeline, delivery) runs without sound or a mic.
- `scripts/when-idle.sh <cmd>`: runs the command only after 5 minutes without keyboard or mouse input
  (`CGEventSource.secondsSinceLastEventType`), aborts if input arrives.
- `scripts/h2h/`: for comparing dictation apps as products. Plays each clip into a virtual microphone, presses and
  releases the app's talk key with synthetic events, reads the result from the capture window, records
  key-up-to-text time and the text. Works for Larynx, Wispr Flow, Apple Dictation or anything else.
  Needs Colin (section 12, C3): a virtual audio device and a signed-in copy of the other app. Read the other
  product's terms first; if they forbid publishing benchmarks, keep the numbers private and publish only ours on
  public data next to their own published claims.
Done when: the Larynx row of the rig runs unattended via `when-idle.sh` and writes latency + WER for set (b).

---

## 5. Phase 1: Fix what real use shows (v0.4)

**1.1 Numbers without the LLM.** New `LarynxText/Numbers.swift`, a pipeline stage after tidy, in every mode
including AI apps. Deterministic, not NeMo ITN (tried and rejected: too aggressive).
- Parse: zero-nineteen, tens, hyphenated tens ("ninety-four"), hundred / thousand / million / billion, "and",
  decimals with "point" when a number word is on BOTH sides ("five point two" -> 5.2; "at this point" untouched).
- Convert to digits when any of: value >= 10; a unit follows (percent -> %, dollars/bucks -> $, cents, K, X or
  "times" -> "20x", seconds, minutes, hours, days, weeks, months, years, ms, GB, MB, px, a.m./p.m., o'clock);
  a label precedes (version, step, item, line, page, chapter, port, number, top, level, phase); it is a decimal;
  it sits in a run of numbers ("one, two, three" in a count stays as said; "three, four and twelve" converts all).
- Keep as words: "one" as a pronoun ("this one", "no one", "one of", "one day", "the one"); values under 10 with
  no unit or label; anything inside a snippet or code-case result.
- Times: "seven thirty" -> 7:30 only after "at"/"by"/"around" or before a.m./p.m./"tonight"/"tomorrow";
  "eight o'clock" -> 8:00. Years: "twenty twenty-six" -> 2026. Money: "twenty dollars" -> $20,
  "two hundred K" -> 200K. Seven or more single digits in a row -> joined as one number.
- Setting `numbers`: `smart` (default) | `digits` | `words`.
- Tests: at least 120 change cases and 120 must-not-change cases in cases.json. Ship via shadow mode.
- When `on`: remove `numberCues` from `Cleaner.reason` (numbers no longer cost an LLM call) and delete rule 3 from
  the LLM instructions.
Done when: shadow review is clean and the rewrite count for "numbers" in a week of History is 0.

**1.2 Stop clipping the first and last word.**
- Tail: after key-up keep recording `tailMs` (default 250) before stopping; a new key-down during the tail starts a
  new session after the old one is sealed.
- Onset: call `engine.prepare()` at launch; log how long `Recorder.start()` takes each time. If p90 is above
  80 ms, start the engine on the first modifier-down event of any talk key candidate rather than after debounce.
- Test (`bench/onset.py` using `--feed` with a real-time file feed): 50 clips where speech begins 0-150 ms after
  key-down and ends 0-150 ms before key-up. Done when 0 of 50 lose the first or last word (today: measure first
  and write the number down).

**1.3 Second opinion on doubtful results.** New `Sanity.swift`. A result is doubtful if: two or more consecutive
ALL-CAPS words that are not known acronyms or vocabulary, or one all-caps token of 9+ letters; or
`ASRResult.confidence` under a threshold calibrated on bench (catch >= 80% of clips with WER > 30% at <= 5% false
alarms; write the threshold and the curve into BENCHMARKS.md); or over 30% of words are in neither the word list
nor the vocabulary. Doubtful -> decode again with the other loaded engine (deadline 300 ms). Take the second
result only if it is not doubtful. If both are doubtful, deliver the first, flag the History row, and show
"Not sure I heard that" in the pill for 2 s. Generalizes today's `transcribeWithFallback` (empty result).
Done when: unit tests cover each trigger and the two real caps-run cases (recreated with noise-mixed TTS) recover.

**1.4 Pick the default English engine by data.** Put engines behind a `SpeechEngine` protocol
(`load`, `transcribe(samples, vocabulary) -> EngineResult{text, confidence, tokenTimings, language}`) and add:
`.bark3` (verbatim), `.ultra` (`AsrModelVersion.ultra`), `.unified` (`UnifiedAsrManager`: punctuation and capitals
are native, 2.16% avg WER on test-clean in FluidAudio's own table vs 2.6% for v3). Run `larynx bench` on all sets
for clean, bark3, ultra, unified, parakeet.
Decision rule: the default is the engine with the lowest mean WER over `jargon` + `noise` + `test-other`, provided
(a) its cleanup-suite score with the tidy rules on is within 2 points of Bark Clean's, (b) p90 latency on clips
under 30 s is <= 200 ms, (c) punctuation F1 is not lower than Bark Clean's. If nothing beats Bark Clean under those
conditions, keep it. Write the table and the decision into BENCHMARKS.md. If a verbatim engine wins, fillers and
repeats become the tidy rules' job: add cases until the cleanup suite matches.
Also try a consensus pass (cap the effort at one working session): run the top two engines, and where they differ
on a word prefer the one that is in the vocabulary or context, else the higher-confidence one. Keep it only if WER
drops by 10% relative on `jargon` + `noise` with p90 latency still inside invariant 2.

**1.5 Make the LLM rewrite fast or skip it.** In `Cleaner.rewrite`:
- Rewrite only the sentence(s) containing the cue, not the whole message, then splice back. Smaller input is
  faster and gives the guard less to get wrong.
- Keep one prewarmed `LanguageModelSession` (call its prewarm API at launch and after each use; verify the exact
  name in the macOS 26 SDK).
- Deadline `rewriteDeadlineMs` (default 600): if the model has not answered, deliver the tidied text. In apps where
  the field can be read back (1.6) and the text is unchanged 1 s later, replace it with the rewritten version;
  otherwise keep the tidy result and record the late rewrite in History only.
- Grow the rewrite benchmark from 26 to 100 cases (corrections of every cue type, 40 must-not-change).
Done when: on the 100 cases, accuracy >= today's and added latency p90 <= 600 ms.

**1.6 Prove (or fix) learning from fixes.**
- `larynx focus --dump [seconds]`: prints the focused element's role, subrole, whether AXValue is readable, value
  length, AXSelectedTextRange, AXNumberOfCharacters, and whether the parameterized AXStringForRange works. Run it
  (through `when-idle.sh`, read-only, no typing) with Claude desktop, Messages, Safari text areas, Notes, Terminal,
  VS Code, Slack frontmost. Record a table in `docs/APPS.md`.
- `FieldReader` with fallbacks in this order: AXValue; AXStringForRange over the full range; the focused
  descendant of an AXWebArea / AXGroup that has a value. Used by Learner, by context (2.1) and by paste
  verification (4.6).
- Sample at 1 s intervals for 20 s instead of once at 15 s. Keep the last snapshot that still contains >= 60% of
  the pasted words; when the field empties (message sent) diff against that snapshot.
- Test in the capture window: paste "send it to Gavy", script an edit to "Govee" through AX, expect the learn.
Done when: the capture-window test passes and docs/APPS.md says, per app, whether learning can work. For apps where
the field cannot be read, say so in the README instead of implying it works everywhere.

**1.7 `larynx mine`: turn real use into fixes.** Reads History and writes
`~/Library/Application Support/Larynx/suggestions.md`:
- Re-dictations: two results within 90 s in the same app with text similarity > 0.6. Diff them word by word; each
  differing pair is a candidate (heard, meant).
- Rows flagged by Sanity (1.3); words in neither word list nor vocabulary, counted.
- With `keepAudio` on: re-transcribe stored audio with the strongest engine and list disagreements.
Menu item "Review suggestions (n)" opens the file; each line has an `add` command. Nothing is ever added
automatically. `--shadow <stage>` lists would-be changes (0.7).
Done when: run on Colin's History it lists the known "said it twice" cases.

**1.8 Close out v0.4.** Full suite + bench, README + BENCHMARKS.md updated, version 0.4.0 in `make-app.sh`,
git tag, install via the idle-restart script.

---

## 6. Phase 2: Context engine (v0.5)

Wispr Flow's public data page says it uses the app, the text around the cursor and, optionally, text from the
active window, all sent to its servers. We do the same thing without anything leaving the Mac.

**2.1 `Context.swift`.** Gathered at key-down on a background task; budget 150 ms; never delays recording.
- Fields: app bundle id, browser URL host for Safari/Chrome/Arc/Edge/Firefox (from the web area's AXURL or the
  window's AXDocument), window title, text before the cursor (up to 2,000 characters), text after (500), selected
  text, visible text of the focused window (bounded tree walk: 4,000 characters, 300 elements, whatever comes
  first within the budget).
- Privacy: nothing from secure fields; an app list that is always skipped (password managers, Keychain Access,
  banking apps; user-editable `privacy.json`); context lives in memory for one dictation and is never logged or
  stored. Setting `context`: `on` (default) | `app-only` | `off`, also a menu checkbox.
- `larynx context [seconds]` prints what would be gathered (lengths and the proper nouns only, never raw text).

**2.2 Names from the screen.** Extract candidates from context: capitalized words not at sentence start, words
that fail the English word list, identifiers (camelCase, snake_case, dotted names), up to 40 per dictation, most
recent first. Build a per-dictation `VocabularyBoostingSession` = standing vocabulary + these, started at key-down
(measured 300-500 ms for 77 terms on this Mac, hidden under the speaking time; if it is not ready at key-up, use
the standing one, never wait). Same `soundsAlike` gate as today, strict for real English words.
Bench set `context-names`: 100 sentences with uncommon names plus a context paragraph that contains them.
Done when: name accuracy on that set is >= 90% with context (record the without-context number too) and the
must-not-change suite is clean. Shadow mode first.

**2.3 Write so it fits what is already there.** Using text before the cursor:
- Field empty or previous character is a newline -> capitalize as today.
- Previous text ends with `.`, `!`, `?` (optionally followed by space) -> capitalize; add a leading space if the
  previous character is not whitespace.
- Previous text ends mid-sentence -> lowercase the first word unless it is a proper noun, "I", or code; add a
  leading space if needed; in correspondence mode still end with a period.
- Selection non-empty -> the paste replaces it (normal), no leading space logic.
Tests in the capture window for each case. When the field cannot be read, behave exactly as today.

**2.4 File tagging.** Index file names from the projects under `vocabularyRoots` (`git ls-files`, refreshed when a
repo's HEAD changes; cap 20k files). When the frontmost app is an editor or terminal or the AI mode is active, and
the user says something that resolves to exactly one file ("main dot swift", "the inserter file", "menu swift"),
write the right form: `@Sources/larynx/Menu.swift` in Cursor and Windsurf, the plain relative path elsewhere.
Ambiguous matches (two or more files) are left as spoken. Setting `fileTagging`: `on | off`.
Done when: 40 test phrases against this repo's own file list resolve correctly and 40 ordinary sentences containing
words like "main", "menu", "test" are unchanged.

**2.5 Per-app and per-site profiles.** Replace the hard-coded sets in `CleanupMode` with `apps.json`: bundle id or
URL host -> profile (mode, style from 3.2, numbers, context level, language). Ship defaults for the current lists
plus sites: mail.google.com and outlook -> email; claude.ai, chatgpt.com, gemini -> ai; github.com -> code review
comment (standard); slack/discord/teams web -> work chat; docs.google.com, notion.so -> document.
Done when: the old behavior is reproduced by the default file (test) and editing the file changes behavior live.

---

## 7. Phase 4: Capture and control (v0.6)

**4.1 Hands-free.** Double-tap the talk key (two taps under 400 ms apart, each under 300 ms) locks recording.
One more tap finishes. Esc cancels (History keeps the audio spool so a wrong Esc is recoverable for 60 s:
"Undo cancel" in the menu). The pill shows a lock mark and the time. Auto-finish after `handsFreeSilenceSec`
(default off; when set, uses `VadManager` streaming). Hard cap `maxDictationMin` (default 30).
Done when: scripted key events drive lock, finish and cancel correctly, and holding the key still works as before.

**4.2 Long dictation without limits.** Verify first: feed 1, 5, 15 and 30 minute files through `--feed`. Record
key-up latency, memory and seam errors (dropped or doubled words at 15 s window joins; FluidAudio's
`Documentation/ASR/LongTranscription.md` lists the failure modes). If key-up latency for 5 minutes exceeds 500 ms,
transcribe in the background while recording: cut at pauses found by `VadManager`, transcribe finished segments
during recording, and at key-up only the last segment is left. The preview then shows committed text plus the live
tail, replacing today's "last 12 s every 0.8 s" loop. Memory stays bounded by spooling audio to disk.
Done when: a 30 minute dictation delivers in under 500 ms after key-up with WER equal to the one-shot result.

**4.3 Microphones.** Settings: choose a mic or an ordered priority list; automatic fallback when a device
disappears mid-dictation (keep what was recorded); virtual and aggregate devices listed under "other devices" and
never auto-selected; when the lid closes, switch to the next physical mic. Warn in the pill within 1 s if input RMS
stays at silence level ("No sound from <mic>"). Show a small level meter in the pill. Note in docs: Bluetooth
headset mics force low-quality call mode; offer "prefer built-in mic when AirPods are connected" (default on).
Done when: unplug and replug of a device during `--feed`-less manual testing by Colin is confirmed, and the
silence warning triggers in an automated test with a zeroed input.

**4.4 Noise, music and whisper.** Colin dictates with music playing. Using bench sets `noise` and `whisper`:
- Baseline every engine.
- Try, one at a time, each kept only if it lowers WER on those sets by >= 10% relative without raising clean-set
  WER by more than 2% relative: (a) loudness normalization before the engine for quiet input; (b) FluidAudio
  LocalVQE noise suppression (`Documentation/Enhancement/LocalVQE.md`; with system audio as the far-end reference
  when available, silence otherwise); (c) routing doubtful results (1.3) to a larger model.
- Optional setting `duckMedia`: pause or lower other audio while the key is held (media key or volume ramp),
  restore after.
- Speaker lock belongs here if 9.2 is chosen.
Done when: BENCHMARKS.md has before/after rows and the README states measured noise and whisper numbers.

**4.5 Shortcuts.** A recorder in Settings for any key or modifier chord, mouse buttons 3-5 and Fn. Separate
bindings for: dictate (hold), hands-free toggle, Command Mode (3.5), paste last transcript, cancel. Optional
per-binding language or profile ("this key always dictates Spanish"). Keep modifier-only keys working exactly as
today. For Fn on keyboards that hide it, document the limitation rather than pretending.

**4.6 Insertion that cannot silently fail.** In `Inserter`:
- After a paste, where the field is readable (1.6), check within 300 ms that the text arrived. If not: try setting
  `kAXSelectedTextAttribute` on the element; if that fails, type it with Unicode key events
  (`CGEventKeyboardSetUnicodeString`, chunked); if that fails, clipboard + pill message.
- Per-app insertion method in `apps.json` (paste | type | ax) for apps that block paste (remote desktops, some
  terminals); learned automatically when verification fails twice in an app.
- Mark our clipboard writes as transient (`org.nspasteboard.TransientType`, `org.nspasteboard.AutoGeneratedType`)
  so clipboard managers do not record every dictation; the "copied, press Cmd+V" fallback is written normally.
- "Undo last dictation": if the user says only "scratch that" / "undo that" within 30 s in the same field, send
  Cmd+Z once and mark the History row. Also a menu item and optional shortcut.
Done when: capture-window tests cover verify-success, verify-fail -> type fallback, and transient marking.

---

## 8. Phase 3: Formatting, styles, local LLM, Command Mode (v0.7)

**3.1 Spoken formatting (rules, no LLM).** `LarynxText/Formatting.swift`, shadow mode first.
- Punctuation words when they stand as commands: "comma", "period"/"full stop", "question mark", "exclamation
  point", "colon", "semicolon", "new line", "new paragraph", "open/close quote", "open/close paren", "dash",
  "ellipsis". Guard against real uses ("the Jurassic period", "a comma separated list", "bring it to a full
  stop"): act only when the word is at a clause boundary and not preceded by a determiner or adjective. At least
  60 must-not-change cases.
- Lists: "one ... two ... three ..." or "first ... second ... third ..." with three or more items, or "bullet"
  repeated -> a numbered or bulleted list with line breaks. In fields that take only one line (search fields,
  single-line AXTextField) keep it inline.
- Setting `spokenPunctuation`: `on | off`.

**3.2 Styles.** Per profile (2.5): `formal` (full sentences, capitals, final punctuation), `casual` (capitals, no
final period on a single short sentence), `very-casual` (lowercase start, no final period, keeps "gonna"),
`verbatim` (nothing but spacing), `ai` (today's AI mode). Deterministic. Defaults: email and documents formal,
work chat casual, personal messages casual, AI apps ai. Optional per-contact override in Messages keyed by a hash
of the window title.
Done when: 5 styles x 20 cases pass and the default profiles reproduce today's output for today's apps.

**3.3 One `Polisher` interface, several engines.** Everything that asks a language model goes through it and
through the existing guard. Backends:
1. `rules` (none).
2. `apple`: Foundation Models, macOS 26 (today's).
3. `local`: a small instruct model run in-process with MLX (mlx-swift) for Macs without Apple's model or when it
   scores better. Choose the model by data at execution time: build `larynx polish-bench` (the 100 rewrite cases +
   60 Command Mode cases from 3.5) and test current open-weight candidates that fit in 4 GB of memory; record
   accuracy, latency, licence, size; pick the best under a 700 ms p90. Downloaded on demand, never bundled.
4. `endpoint`: any OpenAI-compatible URL. `http://localhost` (Ollama, LM Studio) counts as local. Any other host
   is "cloud": off by default, a visible badge in the menu while enabled, and a line in docs/PRIVACY.md. This is
   how "sacrifice nothing" covers people who want a frontier model for polish: their key, their choice.
Setting `polisher`: `auto` (apple if available, else local if downloaded, else rules) | one of the names.

**3.4 Self-correction for any phrase.** Extend the cue set and examples; scope to the sentence (1.5); keep the
"kept the correction" guard; add the deterministic same-kind rule for more kinds (names from context, clock
times, amounts). In AI apps: run only the deterministic rules by default (`aiPolish: off`), because a model reads
that text anyway and latency matters most there; setting to turn the LLM on for AI apps too.
Done when: the 100-case benchmark passes >= 95 with 0 must-not-change failures on three consecutive runs.

**3.5 Command Mode.** A second binding (default: talk key + Right Shift; configurable in 4.5).
- With text selected: the speech is an instruction ("make this shorter", "fix the grammar", "turn this into
  bullets", "translate to Spanish", "more formal"). Selected text + instruction go to the Polisher; the result
  replaces the selection by paste, so the app's own undo works. The original goes to History.
- With nothing selected: the speech is a writing request ("reply saying I'll be ten minutes late") using context
  (2.1); the result is inserted.
- The guard for commands differs: output must be non-empty, must not be a refusal or a chat reply ("Sure, here
  is..."), and for edit commands must keep at least 30% of the content words unless the instruction asked for a
  rewrite or translation. Deadline 4 s with a progress pill; on failure nothing is changed.
- Translation uses Apple's on-device Translation framework when the pair is installed (verify API availability);
  Polisher otherwise.
- 60 benchmark cases in `polish-bench`.
Done when: >= 54 of 60 pass and a selection is never destroyed (test: failure paths leave it intact).

---

## 9. Phases 6 and 5: the app, then languages (v0.9, v1.0)

### Phase 6: an app other people can install
**6.1 Settings window** (SwiftUI): General, Shortcuts, Microphone, Languages, Style and Apps, Dictionary,
Snippets, History, Privacy, Models, Advanced. Reads and writes `Settings` (0.5). The menu keeps the quick toggles.
**6.2 First run.** One window: the three permissions with live status and a button that opens the right settings
pane (we never flip them), microphone test with a level meter, model download with progress and resume, a try-it
box, pick the talk key (detects keyboards that do not send Fn). Apple Silicon only; say so.
**6.3 History window.** Search, copy, paste again, play audio (when kept), "this is wrong" (type the fix; feeds
dictionary and vocabulary the same way 1.6 does), delete, export, retention. A stats strip computed locally:
words dictated, average words per minute, time saved against 45 wpm typing, top apps.
**6.4 Scratchpad.** A floating note window (global shortcut) to dictate into when no app is the target; notes are
Markdown files in `~/Documents/Larynx Notes/` (folder configurable).
**6.5 Dictionary and snippets, grown up.** Table editors; rich-text snippets (stored as Markdown, pasted as rich
text where the field accepts it, plain otherwise); import from CSV and JSON; "shared sets": subscribe to a file
path or an https URL of a JSON set (a team's git repo or shared drive) that refreshes daily and merges under the
personal entries. A URL subscription is a network call: off by default, listed in docs/PRIVACY.md. That is team
sharing with no server and no account.
**6.6 Sync without a cloud of ours.** Setting `dataFolder` for settings, dictionary, vocabulary, snippets, apps
and privacy files (not History, not models). Point it at iCloud Drive, Dropbox or a Syncthing folder. Merge by
file, last writer wins per entry; never lose an entry on conflict (keep both).
**6.7 Distribution.** GitHub Actions on a macOS runner: build, `swift test`, the text and rewrite-guard suites.
Tagged releases attach a zipped app. Two paths depending on Colin's decision C1:
- With an Apple Developer ID: notarized DMG, Sparkle auto-update (EdDSA-signed appcast in the repo), Homebrew cask.
- Without: `scripts/install.sh` that clones, builds and signs locally (ad hoc or the user's own identity), plus a
  Homebrew tap formula that builds from source. Update check is `git fetch` on demand from the menu.
**6.8 Accessibility of the app itself.** VoiceOver labels everywhere, full keyboard navigation, reduced-motion and
increased-contrast variants of the pill, a "no sounds" option, localized UI strings scaffold (English first).
**6.9 Privacy proof.** `tests/network.sh`: launch the app with models present, run 20 fed dictations, assert no
sockets were opened (`lsof -i -a -p <pid>` and `nettop` sampling). Setting `offline: true` additionally refuses
model downloads. CI runs it. README links the test: this is the claim Wispr Flow cannot make.
**6.10 v0.9:** update README (feature list, comparison table from section 2 with links to evidence),
docs/BENCHMARKS.md, docs/PRIVACY.md, docs/SETTINGS.md, docs/APPS.md.

### Phase 5: 100+ languages
**5.1 Engine registry.** Using the `SpeechEngine` protocol from 1.4, add: Nemotron Unified multilingual (25
European languages with punctuation, has an `auto` language prompt), SenseVoice (50+ languages including Chinese,
Japanese, Korean, Cantonese), Paraformer (Mandarin), Parakeet Japanese, Cohere Transcribe (14 languages), and for
the long tail Whisper large-v3-turbo through WhisperKit (new dependency: check its licence and current API, pin a
version). Each engine declares its languages, size, and measured WER.
**5.2 Languages I speak.** A list in Settings. One language -> that language's best engine, loaded at launch.
Several -> identify the language per dictation (the detected-language output of the multilingual engine, checked
on the first 3 s of audio) and route; keep at most two engines in memory, load others on demand with a pill
message. A dictation in an unlisted language triggers a one-time offer to add it.
**5.3 Cleanup per language.** Filler lists and stutter words for the 12 most spoken supported languages in
`LarynxText/Languages/<code>.json`; styles and spoken punctuation for those; for the rest only spacing and
capitals. Numbers (1.1) stay English-only until someone contributes rules: say so.
**5.4 Measure.** FLEURS test subsets (100 clips per language) for every claimed language, table in BENCHMARKS.md.
A language is "supported" only if its WER/CER is within 20% relative of the engine's published number on our run.
Done when: the README can list the supported languages with numbers, and the count is at least 100.

**v1.0 gate:** every row 1-29 of the scoreboard is AHEAD or LEVEL with a linked test or benchmark, or is marked
"cannot" with one honest sentence. Then update the README's first screen to make the claim.

---

## 10. Beyond parity

### Phase 9: things a cloud product cannot do (pick three with Colin, in this suggested order)
Each starts with a time-boxed spike that ends in a number and a go / no-go written in section 11.
**9.1 Voice to agents, both ways.** MCP tools `listen` (the agent asks, the user answers by voice, hands-free) and
`speak` (local text-to-speech through FluidAudio; needs the `TTS` trait). A binding that sends a dictation to a
named target regardless of focus ("tell Locust ..."): targets are defined in `targets.json` as an app + window
match, a CLI command, or an HTTP hook on localhost. This turns Larynx into the voice layer for Claude Code, Locust
and anything scriptable. Spike: round-trip latency under 1.5 s for ask -> spoken answer -> text to the agent.
**9.2 Only listens to you.** Enroll the user's voice once (30 s). During dictation, drop segments whose speaker
embedding does not match (FluidAudio speaker embeddings; needs the `Diarizer` trait), so a TV, a call on speaker
or a person nearby is not typed. Real use shows other voices being transcribed. Spike: on a two-speaker bench set,
remove >= 90% of the other speaker's words while losing <= 1% of the user's.
**9.3 Voice actions.** `actions.json`: a spoken cue runs a Shortcut, a shell command or opens a URL, with
arguments from the rest of the sentence ("run the tests", "open the larynx repo", "new note called ..."). Off by
default; every action is user-defined; destructive commands require a confirm tap. 
**9.4 A model that adapts to you.** Nightly, on the Mac, from kept audio + corrected text (only with `keepAudio`
on): first step is cheap and certain: per-user confusion pairs and vocabulary weights mined automatically (1.7
made automatic once a pair has been confirmed three times). Second step is a research spike: fine-tune a small
adapter for the speech model locally (MLX port of the model) and measure WER on held-out personal audio. Ship
step two only if it beats step one by 10% relative.
**9.5 Fix last, by cycling.** A shortcut replaces the last insertion with the next-best alternative (the other
engine's result, then the pre-polish text, then verbatim). Works where the field is readable.
**9.6 Phone as a wireless mic.** A small web page served on the LAN by `larynx serve --lan` (off by default,
pairing code, local network only) that streams the phone's mic to the Mac. Dictate into the Mac from across the
room; covers "use my phone" before native mobile apps exist.
**9.7 Pipeline hooks.** `hooks/` folder: any executable that reads the Transcript JSON on stdin and writes one on
stdout becomes a pipeline stage (per app profile). Documented, sandbox-free by design, user-installed only.
**9.8 The open dictation benchmark.** Publish `larynx bench` + the head-to-head rig as a standalone, reproducible
benchmark for any dictation app, with our own results including the rows we lose.

### Phase 7: meeting notes, all local (XL)
7.1 Capture mic and system audio as two tracks (Core Audio process tap; needs the System Audio Recording
permission: section 12). Detect likely meetings (a call app is running and the mic is in use) and offer to start;
never auto-record. Show a clear recording indicator; add a consent reminder in docs.
7.2 Transcribe with speakers: mic track = "Me"; system track through streaming diarization (Sortformer or
Nemotron Transcribe Lite in FluidAudio; `Diarizer` trait). Names from the calendar event (EventKit permission,
optional) and from enrolled voices (9.2). Dictionary and vocabulary apply.
7.3 Notes with the Polisher (3.3), chunked for long meetings: summary, decisions, action items with owners;
"What did I miss?" for the last 5 minutes; reusable prompt files ("skills") in Markdown.
7.4 Ask across meetings: local embeddings + search over the notes folder; answers cite the meeting and time.
MCP tools `search_meetings`, `get_meeting`.
7.5 Storage: one Markdown file + audio per meeting in a folder the user picks (works with Obsidian and git).

### Phase 8: other platforms (XL each; each needs hardware or accounts, see section 12)
8.0 Contract first: `tests/cases.json` is the cross-platform spec for the text pipeline. `LarynxText` (0.2) must
build with the Swift toolchain on Linux and Windows in CI; that is the shared core. Speech on non-Apple hardware:
the same Parakeet-family models through ONNX Runtime (sherpa-onnx), measured with the same bench.
8.1 Windows: a tray app (`larynx.exe`): low-level keyboard hook for the talk key, WASAPI capture, sherpa-onnx,
`LarynxText`, UI Automation for focus, context and field reading, SendInput paste with the same clipboard-restore
and verification logic, same JSON `serve` protocol. Acceptance: the cleanup suite and the capture-window tests
ported and passing on Windows 11 x64 and ARM64.
8.2 iPhone and iPad: an app + keyboard extension. The keyboard cannot use the mic itself, so the app holds the
audio session and passes text through an app group. FluidAudio supports iOS. Distribution needs the paid Apple
developer program (C1).
8.3 Android: an input method (IME) with sherpa-onnx and the text core.
8.4 Sync across devices: the `dataFolder` files (6.6) are the format everywhere.

---

## 11. Status (the executor keeps this current)

| Task | State | Notes / evidence |
|---|---|---|
| 0.1 | done | Swift Testing covers all 43 text cases, 26 rewrite guard expectations, 100 unchanged sentences in all 3 modes, and unsafe rewrite rejection. Warm run: 3.36 s wall, 1.955 s tests. Use full Xcode via per-command DEVELOPER_DIR on this Mac; CLT cannot load Testing macros. See tests/LarynxTextTests/README.md and bench/results/phase0-task01-warm-test.log. |
| 0.2 | done | LarynxText builds independently with Foundation only; rules, dictionary, snippets and RewriteGuard extracted. WordList policy preserves NSSpellChecker on Mac; portable fallback bundles 56,372 SCOWL entries and notices. 8 Swift tests pass; release CLI 343/343 text checks; release build passes. See phase0-task02-* evidence. |
| 0.3 | done | Codable Transcript/Step replace finish dictionaries. All old serve fields and MCP text retained; steps added, optional confidence reserved, MCP structuredContent added. Legacy fixed-audio golden round trip and real CLI/serve/MCP checks pass; 11 Swift tests and release build pass. See phase0-task03-* and tests/protocol.py. |
| 0.4 | done | Ordered Pipeline/Context stages with off/shadow/on policies and Step records; literal snippets bypass later stages. main.swift reduced to entry wiring; App/Session, Listen, Serve, Commands and Engine own the rest. Per-utterance lifecycle/target ownership and shared preview gate retained. 19 Swift tests, release build and protocol smoke pass. Full suite exactly matches baseline: rules 43/43, rewrite 26/26, spoken 264/300; all 410 raw/final outputs and pass/fail/reasons identical (phase0-task04-baseline-comparison.log). |
| 0.5 | done | Implemented as 0.4's prerequisite: Settings reads optional JSON on access, preserves legacy defaults, retains last good config on malformed edits, atomically saves menu changes and mirrors legacy values. All existing preference consumers use it. docs/SETTINGS.md lists all 14 registered keys/defaults, enforced by tests. Stage snapshots are immutable per utterance; engine/initial keys remain launch configuration. |
| 0.6 | done | History.swift: system SQLite + FTS5 (`history.sqlite`, 0600, WAL), rows carry app, mode, engine, raw, text, Steps, timing, delivery, flags. Crash spool: a 16 kHz float WAV + JSON meta written before transcription; leftovers transcribed at launch (`recoverAbandoned`, `larynx recover`) and flagged "recovered" (Recent menu + pill). Settings `history` (on), `historyDays` (30), `keepAudio` (off), `debugText` (off). Password fields (Secure Input / AXSecureTextField) and a privacy app list (`privacy.json`) never touch disk. Log no longer contains transcript text. Recent reads History. `larynx history [--search] [--json]`, `larynx listen --feed` (from 0.9, file-only). Gate: tests/history.py kills a fed dictation mid-transcription and the next run recovers it with the right text. Found and fixed: `loadAudioFile` returned only the first piece of float WAVs (one AVAudioFile read is partial). 25 Swift tests; full suite identical to baseline (410/410 outputs, rules 43/43, rewrite 26/26, spoken 264/300). Not done: window-title hash (needs 2.1 context). Also shipped alongside (Colin's request): the Liquid Glass pill (orb + word bubble in an NSGlassEffectContainerView, voice waveform from `Recorder.level`, target-app icon, anchored above the focused field via `pillPosition`, no-sound warning, lock for private fields). |
| 0.7 - 0.9 | not started | |
| 1.6 | done (partly) | Edit watcher now samples the field every second for 20 s and keeps the last version that still holds the paste (people send before 15 s); text read falls back to AXStringForRange / attributed string (Messages answers only that way). Verified read-only that Claude's composer and Messages' field are readable. Not yet seen firing in real use. |
| 1.7 | done (partly) | Self-learning from repeats (`Corrections` in LarynxText, `Relearn` in the app): same app, within 90 s, same sentence with 1-2 words swapped. Invented word -> dictionary; unknown name -> vocabulary; real-word swaps -> suggestions.json only. Menu Undo Learned. `larynx mine [--log] [--apply]`. Mining the old log found nothing to learn (its repeats were rephrasings). |
| 1.1 - 1.8 | not started | |
| 2.1 - 2.5 | not started | |
| 4.1 - 4.6 | not started | |
| 3.1 - 3.5 | not started | |
| 6.1 - 6.10 | not started | |
| 5.1 - 5.4 | not started | |
| 9.x | not chosen | Colin picks three |
| 8.1 | started | Windows plan in docs/WINDOWS.md. W0 feasibility: LarynxText builds and passes its tests on Windows and Linux in CI (`portable.yml`); Parakeet v3 int8 transcribes the fixture exactly on a Windows CPU via sherpa-onnx in CI (RTF 0.147 on a 4-core VM). |
| 7.x, 8.0, 8.2-8.4 | not started | |

Baseline before any work (Nov 10, commit 8927727): rules 43/43, rewrite 26/26, spoken 264/300; real use p50
111 ms, p90 336 ms, 447 dictations.

---

## 12. What only Colin can decide or do

None of these block phases 0-2. Defaults apply until he says otherwise.

| # | Decision | Default until answered | Unlocks |
|---|---|---|---|
| C1 | Pay for the Apple Developer Program ($99/yr)? | No: build-from-source install | Notarized DMG, auto-update, iPhone app |
| C2 | Keep audio of his own dictations on this Mac for 14 days? | Off | Audio playback, 1.7 re-transcription, 9.4 |
| C3 | Install a virtual audio device and sign into Wispr Flow for head-to-head runs? | Skip; publish our numbers on public data only | Rows 6-8 proven against the real product |
| C4 | Allow an optional cloud LLM endpoint (off by default, labelled)? | Yes | "Sacrifice nothing" for people who want it |
| C5 | Which three of 9.1-9.8 first? | 9.1, 9.2, 9.3 | Phase 9 |
| C6 | A Windows machine or VM for phase 8? | Not started | Windows |
| P1 | New permission: System Audio Recording (meeting notes) | Not requested | Phase 7 |
| P2 | New permission: Calendar (speaker names) | Not requested | 7.2 |

---

## 13. Reference for the executor

**FluidAudio 0.18.3 (checked in `.build/checkouts/FluidAudio` on Nov 10; verify again before use):**
- Batch engines via `AsrModelVersion`: v2, v3, redux, ultra, phonon2, phonon25, bark3, bark3Clean, tdtCtc110m.
- `UnifiedAsrManager` (English, punctuation + capitals, `transcribeDetailed` returns `ASRResult`),
  `StreamingUnifiedAsrManager` (`appendAudio`, `setPartialTranscriptCallback`, `finish`); both have
  `configureVocabularyBoosting`. Multilingual: `UnifiedConfig(family: .nemotronMultilingual(...))`.
- `ASRResult`: `text`, `confidence`, `tokenTimings`, `ctcReplacements`.
- `VadManager`: `makeStreamState`, `processStreamingChunk`, `segmentSpeech`.
- Other folders: `ASR/SenseVoice`, `ASR/Paraformer`, `ASR/Cohere`, `ASR/Canary`, `ASR/NemotronTranscribeLite`,
  `ASR/LFM3Audio` (a 2B audio language model, about 2.5 GB, the candidate for a "maximum accuracy" tier and for
  1.3's larger second opinion), `Enhancement/LocalVQE`, `Speaker` (embeddings), `Diarizer`, `TTS`, `ITN`.
- `Package.swift` currently passes `traits: []`, which turns OFF the TTS, Diarizer and ITN parts. Tasks that need
  them (0.8 TTS for bench data, 9.1, 9.2, 7.2) must add the trait and run `swift package clean` first. Prefer a
  separate bench target so the shipped binary only grows when a shipped feature needs it.
- Docs worth reading before the matching task: `Documentation/Models.md`, `ASR/CustomVocabulary.md`,
  `ASR/LongTranscription.md`, `ASR/Bark3.md`, `Enhancement/LocalVQE.md`, `Sources/.../Unified/benchmark.md`.

**Repo facts:** see `docs/PLAN-next.md` (paths, signing, test commands, the synthetic key press snippet, lessons).

**Things already tried and rejected (do not redo without new evidence):** NeMo inverse text normalization for
numbers (too aggressive); FluidAudio's own rescored text for vocabulary (rewrites real words; only its one-word
swaps behind `soundsAlike` are used); the LLM for whole-message rewrites in AI apps (slow, and a model reads the
text anyway).
