# Contributing to Larynx

Thanks for looking. Bug reports, missed words and pull requests are all welcome.

## Report something

- **It typed the wrong thing.** Use Send Feedback… in the Larynx menu, or open an issue. Write the sentence you
  said and what came out. Make up an equivalent sentence if the real one is private: the cleanup rules care about
  the shape ("Tuesday, no wait, Wednesday"), not your words.
- **It didn't install or start.** Use the "Install report" issue form.
- **A security problem.** See [SECURITY.md](SECURITY.md); please don't open a public issue.

Never paste real dictation history or the log with `debugText` on into an issue. Nobody needs it and it is yours.

## Build and test

Apple Silicon Mac, macOS 15 or later, Xcode command-line tools.

```bash
swift build -c release
swift test                 # every cleanup rule, numbers, history, privacy rules, settings
python3 tests/install.py   # the installer into an empty home folder, ad-hoc signed (a few minutes)
```

`./scripts/make-app.sh` builds `~/Applications/Larynx.app`. The speech-model benchmarks and the live paste test
load models and take over the keyboard focus, so they run through `scripts/when-idle.sh`.

## How a cleanup rule gets added

Cleanup is rules, not a language model, so it is instant and it never invents a word. That only works if a rule
can't damage a sentence that was fine. So:

1. **The case comes first.** Add the sentence and what it should become to `tests/cases.json`. Run `swift test`
   and watch it fail.
2. **Add what must not change.** If the rule could touch ordinary sentences, add those to `mustNotChange` (or to
   `numbers.keep`). "that that", "had had" and "very very" are in there for a reason.
3. **Write the narrowest rule that passes** in `Sources/LarynxText/` (Foundation only; it also builds on Windows
   and Linux).
4. **A rule that guesses goes in as a shadow rule first** (`Tidy.shadowRules`): it records what it would have
   changed without changing anything, and is switched on after those proposals have been read.

A rule that fixes ten sentences and breaks one is not accepted.

## Pull requests

- One change per pull request, with its test.
- `swift test` passes. CI runs it on macOS, and the text core on Windows and Linux.
- Code comments say why, in plain words. No new dependencies without discussing it first.
- Larynx is MIT. Your contribution is under the same licence. Do not copy code from GPL or AGPL projects (several
  good dictation apps are); ideas and behaviour are fine, code is not.
- No telemetry, analytics or network calls. `tests/privacy.py` runs speech to text with the network denied and has
  to keep passing.

## Where things are

`Sources/LarynxText` is the text cleanup (portable). `Sources/LarynxCore` is audio, speech models, history and
macOS integration. `Sources/larynx` is the menu bar app and the command line. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
has more, [ROADMAP.md](ROADMAP.md) says what is next, and `docs/dev/` holds the working plans.
