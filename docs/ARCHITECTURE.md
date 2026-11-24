# Architecture notes

How the code is split, and how a dictation becomes text.

## Portable text core

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
[SCOWL-Copyright.txt](../Sources/LarynxText/Resources/SCOWL-Copyright.txt).
Our modifications are selection, lowercasing, deduplication, sorting, and UTF-8
encoding; `scripts/generate-wordlist.py` reproduces them from the upstream release.
The app build script bundles both the list and its notices. When moving the CLI
executable manually, keep `Larynx_LarynxText.bundle` beside it.

The dictation pipeline in `LarynxCore` now records each cleanup decision as a typed
Step, preserving the existing stage order. Stage policies and the existing menu
preferences share [Settings](SETTINGS.md), with optional JSON overrides and
legacy `defaults` fallbacks. The app's capture/session, engine, serve, and command
wiring live under `Sources/larynx/App/`; `main.swift` only launches the app or CLI.

## The files

Three Swift targets: `LarynxText` (the text rules, Foundation only, builds on Windows and Linux), `LarynxCore`
(audio, the speech and language models, Accessibility) and `larynx` (the CLI and the menu bar app).

| File | Job |
| --- | --- |
| `Recorder.swift` | The microphone: 16 kHz mono, kept warm between dictations, with a short pre-roll and a tail |
| `Transcriber.swift` | Loads the speech model once, transcribes a clip, reports each word's confidence |
| `Hotkey.swift` | Event tap on one modifier; re-arms itself when macOS switches it off |
| `Inserter.swift` | Paste into the target app, check it arrived, fall back to Accessibility, typing, then the clipboard |
| `Pipeline.swift` | Runs the stages in order (snippet, dictionary, vocabulary, tidy, numbers, rewrite); each can be off, shadow or on |
| `Tidy.swift` | Cleanup rules and the per-app mode |
| `Numbers.swift` | Spoken numbers, times, percentages and units as digits |
| `Fit.swift` | Space and capital to match the text before the cursor |
| `Cleaner.swift`, `RewriteGuard.swift` | Optional Apple Foundation Models pass, and the guard that rejects a reply that adds words |
| `CodeWords.swift`, `Snippets.swift` | Spoken code and voice shortcuts |
| `Vocabulary.swift`, `Learner.swift` | Your words, and learning new ones from your fixes |
| `Doubt.swift` | Which words the model was unsure of |
| `Context.swift`, `ContextWords.swift` | Names in the text field you are dictating into, to settle sound-alike words (shadow) |
| `History.swift`, `Privacy.swift` | Local history (SQLite, full-text search), the crash spool, and what is never stored |
| `Golden.swift` | Your own recordings with what you meant, as a private benchmark |
| `HistoryFix.swift` | A fix made in the History window: saved, and turned into a lesson when it is safe to learn |
| `Pill.swift`, `Menu.swift`, `SettingsWindow.swift`, `HistoryWindow.swift`, `FirstRun.swift` | The pill, the menu bar menu, Settings, History and the setup window |
| `App/` | The listen session, the engine, `serve`, and the CLI commands |
| `MCP.swift` | The `mcp` command |

New cleanup rules start in **shadow**: they run on every dictation and record what they would have changed, without
touching the text. A rule is switched on only after its proposals have been read (`larynx mine --shadow`).

## The cleanup, in four layers

Four layers, cheapest first:

1. **Speech model.** The default, Parakeet Ultra (25 European languages), was picked by benchmark: about 37% fewer
   word errors than the previous default on jargon, noise and hard speech, and names spelled right twice as often
   ([docs/BENCHMARKS.md](BENCHMARKS.md)). It types what you said, so the tidy rules remove the ums, repeats and
   false starts. `--engine clean` switches to Underdog Bark 3.0 Clean (English, non-commercial licence), which drops them as it listens.
2. **Tidy rules.** Leftover fillers, stutters ("the the", "I, I"), stranded commas and capitals. Instant, never
   rewrites a word, and leaves real doubles alone ("very very", "had had").
3. **Numbers.** Spoken numbers, times and percentages become digits by rule, in every app.
4. **AI rewrite, only when needed.** Self-corrections ("three, no wait, four") and verbal tics ("you know",
   "basically") go to Apple's on-device model (macOS 26+, free, about 0.3 s). It never runs for AI chats,
   terminals or code editors, and a guard rejects any reply that adds a word or drops too much, falling back to
   the tidied text. Turn it off in Settings (Cleanup) or with `--rewrite off`.

The app you are dictating into sets the mode: a light touch for AI chats, terminals and editors; text that ends like
a sentence for Mail, Slack, Messages and Notes.
