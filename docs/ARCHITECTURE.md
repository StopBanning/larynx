# Architecture notes

How the code is split. The README's "How it works" section describes the pipeline.

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
