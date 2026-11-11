# Larynx

Local, offline dictation for macOS. Hold a key, speak, release: the text lands wherever your cursor is.
Speech runs on the Neural Engine with NVIDIA's Parakeet TDT v3 (25 European languages) through
[FluidAudio](https://github.com/FluidInference/FluidAudio). Nothing leaves your Mac.

Built to stand alone and to be embedded: apps such as Locust drive it over JSON lines (see
[docs/INTEGRATION.md](docs/INTEGRATION.md)).

## Status

Daily-driver quality on Apple Silicon, macOS 15+ (the AI rewrite needs macOS 26). Measured on an M6 Mac mini:
about 0.1 s from releasing the key to text, about 0.3 s more when the AI rewrite runs.

- **Hold to talk** with Fn, Right Option or Right Command; pressing another key while holding cancels, so shortcuts still work.
- **Live preview in Liquid Glass**: while you talk, a small glass orb shows the icon of the app your words are going
  to and a waveform that moves with your voice; your words appear in a bubble that grows out of it. When you let go
  the two melt into one shape while the transcript is made. It sits just above the text box you're dictating into
  (or at the bottom of the screen when the app doesn't say where that is), never takes focus, warns you if the mic
  hears nothing, and shows a lock when you're in a password field (nothing saved). Turn it off from the menu (Live
  Preview); `larynx pill-demo` plays it for a screenshot.
- **Never lands in the wrong app**: the target app is captured when you press the key. Switch apps mid-sentence and
  Larynx brings the original back before pasting.
- **Never loses a transcript**: before pasting, Larynx asks macOS whether a text field has focus. If nothing can take
  the text (no text box clicked, a password field, missing permission), it stays on your clipboard and the pill says
  "Copied, press ⌘V to paste". When an app won't say what has focus, Larynx pastes and keeps the text on the
  clipboard too.
- **Second chance**: if the main speech model hears nothing in a clip that clearly has speech, the other model tries.
- **Cleanup for messages**: fillers, stutters, self-corrections ("Tuesday, no Wednesday" becomes "Wednesday"),
  spoken numbers, all on-device.
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
- **25 languages**: switch the Speech Model in the menu to Parakeet v3.
- **Menu bar settings**: Live Preview, AI Cleanup, Talk Key and Open at Login are checkboxes in the menu; Recent lists
  your last 10 transcripts (click to copy). Opens at login by default.
- **History that stays on your Mac**: dictations are kept for 30 days in a local database you can search with
  `larynx history --search <words>`. Audio is not kept (unless you turn on `keepAudio`), and nothing typed into a
  password field or a password manager is ever stored. `history: off` keeps everything in memory instead. See
  [docs/PRIVACY.md](docs/PRIVACY.md).
- **Survives a crash**: each recording is written to disk before it is transcribed, so if Larynx quits mid-way the
  next launch finishes the job and shows it under Recent as "Recovered".
- **Agents**: `larynx mcp` is an MCP server (see [docs/INTEGRATION.md](docs/INTEGRATION.md)).

## Use

The easy way is the menu bar app: `./scripts/make-app.sh` builds `~/Applications/Larynx.app`. Open it, allow
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

1. **Speech model.** The default, Underdog Bark 3.0 Clean (English), drops "um", "uh", false starts and repeated words
   as it transcribes. `--engine parakeet` switches to verbatim Parakeet v3 for 25 European languages.
2. **Tidy rules.** Leftover fillers, stutters ("the the", "I, I"), stranded commas and capitals. Instant, never
   rewrites a word, and leaves real doubles alone ("very very", "had had").
3. **AI rewrite, only when needed.** Self-corrections ("three, no wait, four"), verbal tics ("you know", "basically")
   and spoken numbers go to Apple's on-device model (macOS 26+, free, about 0.3 s). It never runs for AI chats,
   terminals or code editors, and a guard rejects any reply that adds a word or drops too much, falling back to
   the tidied text. Turn it off with `--rewrite off` or `defaults write com.automatedworkflow.larynx rewrite off`.

The app you are dictating into sets the mode: a light touch for AI chats, terminals and editors; text that ends like
a sentence for Mail, Slack, Messages and Notes.

## Testing

`python3 tests/suite.py --rewrite auto` speaks about 40 messy sentences in five voices at two speeds, transcribes
them and scores the result. It also runs 36 exact tidy-rule checks and a 26-case rewrite benchmark that includes
questions, requests and "actually"/"sorry"/"I mean" sentences the rewrite must leave alone. Latest run (Nov 8, 2026):

| Area | Pass |
| --- | --- |
| Tidy rules (exact) | 36/36 |
| AI rewrite benchmark | 26/26 on 4 of 4 runs |
| Fillers | 72/80 |
| Repeats | 57/60 |
| False starts | 10/10 |
| Self-corrections | 38/40 (0/40 before the rewrite layer) |
| Trailing off | 10/10 |
| Verbal tics | 30/30 |
| Must not change | 95/120 |
| Real-world messages | 30/30 |

Nearly every remaining miss is the speech model mishearing a synthetic voice (hummus as "Hamas", Priya as "prio",
"uh-huh" as "aha"). Still open: dropping a spoken preamble ("The thing is, what I mean is, ...") is left alone on purpose. NeMo inverse text normalization was
tried for numbers and rejected: it turned "two thirty and it costs" into "32 it costs".

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

The full plan, with a scoreboard against Wispr Flow and a task list, is in [docs/MASTER-PLAN.md](docs/MASTER-PLAN.md).
In short: measure first (benchmarks, history), fix what real use shows (numbers, clipped words, doubtful results),
read the screen locally for names and context, hands-free and microphone handling, spoken formatting, styles and
voice edits with a local model, a proper settings app, 100+ languages, then meeting notes and other platforms.

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
