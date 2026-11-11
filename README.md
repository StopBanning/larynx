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
- **Live preview**: a small pill at the bottom of the screen shows the words as you speak. It never takes focus.
  Turn it off from the menu (Live Preview).
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
- **Learns from your fixes**: about 15 seconds after a paste, Larynx reads the text field again. If you changed a word
  to something that sounds like what it heard ("Gavy" to "Govee"), the new word joins your vocabulary and comes out
  right next time. Turn it off with `defaults write com.automatedworkflow.larynx learn off`.
- **Snippets**: say a cue on its own ("my calendar link") and Larynx types the saved text. Edit them from the menu
  (`snippets.json`, `{"cue": "text"}`).
- **Code by voice**: "camel case user id" becomes `userId`; also snake, kebab, pascal and constant case ("all caps").
  "main dot swift" becomes `main.swift`, "dot env" becomes `.env`, and API, JSON, URL, GitHub, iOS and friends get
  their proper spelling. About 70 developer names (Supabase, Vercel, Postgres, Kubernetes...) are in the vocabulary
  out of the box (`defaults write com.automatedworkflow.larynx devTerms off` removes them).
- **25 languages**: switch the Speech Model in the menu to Parakeet v3.
- **Menu bar settings**: Live Preview, AI Cleanup, Talk Key and Open at Login are checkboxes in the menu; Recent lists
  your last 10 transcripts (click to copy; kept in memory only, never saved to disk). Opens at login by default.
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
