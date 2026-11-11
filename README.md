# Larynx

[![portable](https://github.com/StopBanning/larynx/actions/workflows/portable.yml/badge.svg)](https://github.com/StopBanning/larynx/actions/workflows/portable.yml)
[![macOS](https://github.com/StopBanning/larynx/actions/workflows/macos.yml/badge.svg)](https://github.com/StopBanning/larynx/actions/workflows/macos.yml)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)
![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange)

**Free, open-source, fully offline dictation for the Mac.** Hold a key, speak, let go: clean, punctuated text lands
wherever your cursor is, in about a tenth of a second. Speech runs on the Neural Engine with NVIDIA's Parakeet
models through [FluidAudio](https://github.com/FluidInference/FluidAudio). Nothing you say ever leaves your Mac.
No account, no subscription, no word limits.

<p align="center"><b>0.1 s</b> from letting go of the key to text &nbsp;·&nbsp; <b>0 bytes</b> of your voice sent anywhere &nbsp;·&nbsp; <b>$0</b>, no limits</p>

<p align="center">
  <img src="docs/images/pill-demo.gif" alt="The Larynx pill in clear Liquid Glass over colour stripes: the app icon, a waveform moving with the voice, and the words appearing as they are spoken" width="640">
</p>
<p align="center"><sub>The pill, in Liquid Glass: where your words are going, a waveform that moves with your voice, and the
words as you say them. The menu's Pill Glass slider goes from fully see-through to clear glass, frosted and solid:</sub></p>
<p align="center">
  <img src="docs/images/pill-glass-frosted.png" alt="The pill frosted" width="380">
  <img src="docs/images/pill-glass-solid.png" alt="The pill solid" width="380">
</p>

## Why it exists

Cloud dictation apps are excellent, and they send your voice to a server. Larynx sets out to match them feature for
feature while staying local and free. Where it stands (measured from daily use and the test suite in this repo):

| | Larynx | Typical cloud dictation app |
| --- | --- | --- |
| Where your audio goes | Stays on your Mac ([PRIVACY.md](docs/PRIVACY.md)) | Its servers |
| Works offline | Yes | No |
| Price, limits | Free, unlimited, MIT | Free tier with weekly limits, paid plans |
| Key-up to text | 0.11 s median, 0.25 s p90 (205 real dictations) | Network round trip |
| Cleanup | Fillers, stutters, false starts, self-corrections ("Tuesday, no Wednesday"), code by voice | Similar |
| Numbers as digits | "five point five" → 5.5, "three percent" → 3%, in every app, instantly (rules, no AI call) | Yes |
| Hands-free | Double-tap the key, or a one-press Hands-Free Key; up to 30 min | Yes |
| History | 30 days on your Mac, full-text search, audio optional; password fields never kept | Yes |
| Learns your words | From repeats and from your edits, with Undo | From your edits |
| Never loses a dictation | Crash spool + clipboard fallback + target-app lock | Varies |
| Scriptable | CLI, JSON-lines API, MCP server | Limited |

The full roadmap, with a row-by-row scoreboard and the evidence for each row, is [docs/MASTER-PLAN.md](docs/MASTER-PLAN.md).
Windows is in progress: the text engine and the speech model already run on Windows in CI ([docs/WINDOWS.md](docs/WINDOWS.md)).

Built to stand alone and to be embedded: apps such as [Locust](https://locust.lol) drive it over JSON lines (see
[docs/INTEGRATION.md](docs/INTEGRATION.md)).

## Status

Daily-driver quality on Apple Silicon, macOS 15+ (the AI rewrite needs macOS 26). Measured on an M6 Mac mini:
about 0.1 s from releasing the key to text, about 0.3 s more when the AI rewrite runs.

- **Hold to talk** with Fn, Right Option or Right Command (or a macro-pad button that sends one); pressing another key
  while holding cancels, so shortcuts still work.
- **Hands-free**: double-tap the talk key and keep talking with nothing held (a lock shows in the pill); press it
  again to finish, Esc to cancel. Or pick a Hands-Free Key in the menu (a second macro-pad button, say): one press
  starts, the next finishes. Stops by itself after 30 minutes.
- **Live preview in Liquid Glass**: while you talk, a small glass orb shows the icon of the app your words are going
  to and a waveform that moves with your voice; your words appear in a bubble that grows out of it. When you let go
  the two melt into one shape while the transcript is made. It sits just above the text box you're dictating into
  (or at the bottom of the screen when the app doesn't say where that is), never takes focus, warns you if the mic
  hears nothing, and shows a lock when you're in a password field (nothing saved). The menu's Pill Glass slider sets
  how see-through it is, from no glass at all to clear glass, frosted and solid, and shows the pill while you drag. Turn it off from the menu
  (Live Preview); `larynx pill-demo` plays it for a screenshot (`LARYNX_DEMO_BACKDROP=1` adds colour stripes behind it, `=dark` a dark window).
- **Never lands in the wrong app**: the target app is captured when you press the key. Switch apps mid-sentence and
  Larynx brings the original back before pasting.
- **Never loses a transcript**: before pasting, Larynx asks macOS whether a text field has focus. If nothing can take
  the text (no text box clicked, a password field, missing permission), it stays on your clipboard and the pill says
  "Copied, press ⌘V to paste". When an app won't say what has focus, Larynx pastes and keeps the text on the
  clipboard too.
- **Second chance**: if the main speech model hears nothing in a clip that clearly has speech, the other model tries.
- **Cleanup for messages**: fillers, stutters, self-corrections ("Tuesday, no Wednesday" becomes "Wednesday"),
  all on-device.
- **Numbers as digits everywhere**, AI chats included: "Opus five point five" → "Opus 5.5", "three percent" → "3%",
  "two hundred K" → "200K", "seven thirty tonight" → "7:30". Small numbers stay words ("two things") unless a unit
  or label makes them numbers ("step 2").
- **Knows your words**: project names from `~/work` (one-word folders like "larynx", and the unusual part of names
  like "govee-lights"), your dictionary, and anything in `~/Library/Application Support/Larynx/vocabulary.txt`.
  A small keyword model (Parakeet CTC 110M, downloaded once) listens for them after each transcript and swaps a
  misheard word only when it sounds like the term ("macropod" becomes "Macropad"). `larynx vocab` lists them; change
  the folders with `defaults write com.automatedworkflow.larynx vocabularyRoots ~/work,~/code`; turn it off with
  `defaults write com.automatedworkflow.larynx vocabulary off`.
- **Teaches itself your words**, two ways, and the pill says "Learned" when it does:
  - *Say it again.* If you repeat a sentence within 90 seconds with one word changed ("Tell Logus to start" ...
    "Tell Locust to start"), Larynx learns the fix. A made-up word the speech model produced goes into your
    dictionary (always safe: it can't change a real word); a new name goes into your vocabulary. When both are real
    words ("send"/"sent") it's probably a change of mind, so it's only saved as a suggestion.
  - *Fix it in place.* For 20 seconds after a paste, Larynx watches the text field (works in Messages and Claude).
    If you change a word to one that sounds like what it heard ("Gavy" to "Govee"), it learns that too.
  - The menu has **Undo Learned** for the last thing it learned; `larynx mine` lists what your history would teach.
    Turn learning off with `learn: off`.
- **Snippets**: say a cue on its own ("my calendar link") and Larynx types the saved text. Edit them from the menu
  (`snippets.json`, `{"cue": "text"}`).
- **Code by voice**: "camel case user id" becomes `userId`; also snake, kebab, pascal and constant case ("all caps").
  "main dot swift" becomes `main.swift`, "dot env" becomes `.env`, and API, JSON, URL, GitHub, iOS and friends get
  their proper spelling. About 70 developer names (Supabase, Vercel, Postgres, Kubernetes...) are in the vocabulary
  out of the box (`defaults write com.automatedworkflow.larynx devTerms off` removes them).
- **25 languages**: the default model, Parakeet Ultra, covers 25 European languages with no switch.
- **Menu bar settings**: Live Preview, AI Cleanup, Talk Key and Open at Login are checkboxes in the menu; Recent lists
  your last 10 transcripts (click to copy). Opens at login by default.
- **History that stays on your Mac**: dictations are kept for 30 days in a local database you can search with
  `larynx history --search <words>`. Audio is not kept (unless you turn on `keepAudio`), and nothing typed into a
  password field or a password manager is ever stored. `history: off` keeps everything in memory instead. See
  [docs/PRIVACY.md](docs/PRIVACY.md).
- **Survives a crash**: each recording is written to disk before it is transcribed, so if Larynx quits mid-way the
  next launch finishes the job and shows it under Recent as "Recovered".
- **Agents**: `larynx mcp` is an MCP server (see [docs/INTEGRATION.md](docs/INTEGRATION.md)).

## Install

On an Apple Silicon Mac with macOS 15 or later, one line in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/StopBanning/larynx/main/scripts/install.sh | zsh
```

It checks the Mac, fetches the source, builds `~/Applications/Larynx.app` (Apple's free command-line developer tools
are needed; it opens their installer if they're missing) and opens it. A setup window walks you through the three
permissions (Microphone, Input Monitoring, Accessibility), a microphone test and a box to try it. The speech model
(about 500 MB) downloads once, on first launch. Run the same line again to update. Everything else is in
Settings… in the menu (⌘,).

## Use

The menu bar app: `./scripts/make-app.sh` builds `~/Applications/Larynx.app` from a checkout. Open it, allow
Microphone, Input Monitoring and Accessibility when macOS asks, then hold Fn, Right Option or Right Command to talk (pressing another key while holding cancels, so shortcuts still work). Its model
lives in `~/Library/Application Support/Larynx/models`; its log is `~/Library/Logs/Larynx.log`. Some keyboards (Keychron, for one) never send
Fn to macOS. Change the keys with `defaults write com.automatedworkflow.larynx keys rightCommand` (comma-separated).
`make-app.sh` signs with your Apple Development identity if you have one (free with an Apple ID in Xcode), so
rebuilds keep their permissions and Apple's on-device model works. Without one it signs ad hoc, and each rebuild
makes macOS forget the permissions (`tccutil reset All com.automatedworkflow.larynx`, then allow them again).

From a terminal:

```bash
swift build -c release
.build/release/larynx transcribe note.m4a          # print a transcript
.build/release/larynx listen --key fn              # system-wide hold-to-talk
.build/release/larynx history --search deploy      # search your dictation history
.build/release/larynx serve                        # JSON lines for host apps
.build/release/larynx mcp                          # MCP server for agents
```

`listen` needs three macOS permissions, each granted by you in System Settings > Privacy & Security:
Microphone, Accessibility (to paste) and Input Monitoring (to see the key). Keys: `fn`, `rightOption`,
`rightCommand`, `rightControl`. `--models-dir <path>` keeps the model somewhere other than FluidAudio's default.

## Cleanup

Three layers, cheapest first:

1. **Speech model.** The default, Parakeet Ultra (25 European languages), was picked by benchmark: about 37% fewer
   word errors than the previous default on jargon, noise and hard speech, and names spelled right twice as often
   ([docs/BENCHMARKS.md](docs/BENCHMARKS.md)). It types what you said, so the tidy rules remove the ums, repeats and
   false starts. `--engine clean` switches to Underdog Bark 3.0 Clean (English), which drops them as it listens.
2. **Tidy rules.** Leftover fillers, stutters ("the the", "I, I"), stranded commas and capitals. Instant, never
   rewrites a word, and leaves real doubles alone ("very very", "had had").
3. **AI rewrite, only when needed.** Self-corrections ("three, no wait, four"), verbal tics ("you know", "basically")
   and spoken numbers go to Apple's on-device model (macOS 26+, free, about 0.3 s). It never runs for AI chats,
   terminals or code editors, and a guard rejects any reply that adds a word or drops too much, falling back to
   the tidied text. Turn it off with `--rewrite off` or `defaults write com.automatedworkflow.larynx rewrite off`.

The app you are dictating into sets the mode: a light touch for AI chats, terminals and editors; text that ends like
a sentence for Mail, Slack, Messages and Notes.

## Testing

| Suite | What it checks | Latest (Nov 11, 2026) |
| --- | --- | --- |
| `swift test` | 39 tests: every cleanup rule against `tests/cases.json`, 100 sentences that must not change in 3 modes, the rewrite guard, the pipeline, settings, history, crash spool, privacy rules, self-learning | all pass |
| `python3 tests/suite.py --rewrite auto` | About 40 messy sentences spoken by 5 macOS voices at 2 speeds, transcribed and scored, plus a 26-case benchmark for the on-device AI rewrite | rules 73/73, rewrite 26/26, spoken 281/300 with Parakeet Ultra (most misses are the speech model mishearing a synthetic voice) |
| `python3 tests/protocol.py` | The `serve` and MCP wire formats stay compatible | pass |
| `scripts/when-idle.sh python3 tests/live.py` | A recording goes through the real listen and paste path into Larynx's own capture window only (never another app), once you're idle and the screen is unlocked; your clipboard and history are left as they were | not yet run live (screen was locked); safety checks pass |
| `python3 tests/history.py` | Kills a dictation mid-transcription; the next launch must recover it word for word | pass |
| CI `portable.yml` | The text engine builds and passes its tests on Windows and Linux; Parakeet runs on a Windows CPU | pass |

Spoken-suite detail (Parakeet Ultra, AI rewrite on where it would run, Nov 11):

| Area | Pass |
| --- | --- |
| Fillers | 75/80 |
| Repeats | 55/60 |
| False starts | 10/10 (harder ones: 10/20) |
| Self-corrections | 29/40 (0/40 without the rewrite layer; Bark Clean scored 38/40) |
| Trailing off | 8/10 |
| Verbal tics | 30/30 |
| Must not change | 111/120 |
| Real-world messages | 30/30 |

Nearly every remaining miss is the speech model mishearing a synthetic voice (hummus as "Hamas", Priya as "prio",
"uh-huh" as "aha"). Still open: dropping a spoken preamble ("The thing is, what I mean is, ...") is left alone on
purpose. NeMo inverse text normalization was tried for numbers and rejected: it turned "two thirty and it costs"
into "32 it costs".

## How it works

| File | Job |
| --- | --- |
| `Recorder.swift` | AVAudioEngine tap, resampled to 16 kHz mono |
| `Transcriber.swift` | Loads Parakeet v3 once, transcribes a clip |
| `Hotkey.swift` | Event tap on one modifier; re-arms itself when macOS switches it off |
| `Inserter.swift` | Clipboard plus Cmd+V mapped through the keyboard layout; restores your clipboard; brings the target app back; falls back to copy |
| `Tidy.swift` | Cleanup rules and the per-app mode |
| `Cleaner.swift` | Optional Apple Foundation Models pass with a guard against answers |
| `CodeWords.swift` | Spoken code: case commands, file names, acronyms |
| `Snippets.swift` | Voice shortcuts |
| `Learner.swift` | Learns words from your fixes |
| `History.swift` | Local dictation history (SQLite, full-text search) and the crash spool |
| `Privacy.swift` | Password fields and apps whose dictations are never stored |
| `Vocabulary.swift` | Your words: project names, dictionary, vocabulary.txt |
| `Pill.swift` | The live preview panel |
| `Menu.swift` | The menu bar menu: recent transcripts and settings |
| `MCP.swift` | The `mcp` command |
| `main.swift` | The `transcribe`, `listen`, `serve`, `rewrite` and `tidy` commands, and the menu bar app |

## Roadmap

[docs/MASTER-PLAN.md](docs/MASTER-PLAN.md) has the whole plan as tasks with acceptance tests, and a status table.
Done so far: tests and package split, typed pipeline with shadow mode, settings, history and crash recovery,
self-learning, the Liquid Glass pill. Next: benchmarks against public speech sets, spoken numbers without the AI
model, context from the screen for names, hands-free mode, spoken formatting and lists, voice edits on selected
text, a settings window, 100+ languages, then Windows ([docs/WINDOWS.md](docs/WINDOWS.md)) and meeting notes.

## License

MIT. Parakeet TDT v3 weights are CC-BY-4.0 (NVIDIA); FluidAudio is Apache-2.0.

### Portable text core

`LarynxText` contains cleanup modes and rules, spoken code, snippets, dictionary
replacement, and the deterministic rewrite guard. It imports Foundation only and
can be built independently with `swift build --target LarynxText`. `LarynxCore`
keeps audio, the speech and Apple language models, Accessibility, app focus, and
macOS spelling. Existing `import LarynxCore` clients still see the text APIs.

Spelling is supplied through the `WordList` protocol. On macOS, `MacWordList`
continues to use NSSpellChecker, preserving the app's existing behavior. Other
hosts can use `BundledWordList.shared`: 56,372 case-insensitive entries from
[SCOWL 2020.12.07](https://wordlist.aspell.net/), American/common word and
contraction lists through level 40. This is a finite fallback, not a complete
English dictionary, and it does not stem words or use the macOS learned dictionary.
The upstream MIT-like/BSD-compatible notices are preserved verbatim in
[SCOWL-Copyright.txt](Sources/LarynxText/Resources/SCOWL-Copyright.txt).
Our modifications are selection, lowercasing, deduplication, sorting, and UTF-8
encoding; `scripts/generate-wordlist.py` reproduces them from the upstream release.
The app build script bundles both the list and its notices. When moving the CLI
executable manually, keep `Larynx_LarynxText.bundle` beside it.

The dictation pipeline in `LarynxCore` now records each cleanup decision as a typed
Step, preserving the existing stage order. Stage policies and the existing menu
preferences share [Settings](docs/SETTINGS.md), with optional JSON overrides and
legacy `defaults` fallbacks. The app's capture/session, engine, serve, and command
wiring live under `Sources/larynx/App/`; `main.swift` only launches the app or CLI.
