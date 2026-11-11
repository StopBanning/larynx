# Phase Zero task 0.1 evidence (Nov 10, 2026)

Source baseline: `4e1b4cb` (roadmap only; preceding code baseline unchanged).

- `phase0-before-swift-test.log`: first build, then expected failure because no test target existed.
- `phase0-before-suite.log` and `phase0-before-spoken.json`: existing release binary,
  `python3 tests/suite.py --rewrite auto --json bench/results/phase0-before-spoken.json`.
  Rules 43/43, rewrite 26/26, spoken 264/300 excluding known gaps. Exit 1 reflects
  pre-existing spoken failures. These are synthesized fixture sentences, not personal dictation.
- `phase0-task01-swift-test.log`: selected Command Line Tools cannot load TestingMacros.
- `phase0-task01-native-test.log`: native build fallback cannot import Testing.
- `phase0-task01-xcode-test.log`: full Xcode toolchain, five Swift Testing tests pass.
- `phase0-task01-warm-test.log`: timed warm repeat, 3.36 seconds wall / 1.955 seconds
  test execution, exit 0. Command: `/usr/bin/time -p env
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

The five Swift tests cover fixture integrity, 43 exact text outputs, 26 rewrite
reference guard expectations, 100 unchanged sentences in all three cleanup modes,
and six explicit guard acceptance/rejection checks. No production sources changed.
No post-phase speech benchmark is claimed: tasks 0.2–0.9 remain outstanding.

## Task 0.2

`phase0-task02-*`: independent Foundation-only text build, eight Swift tests,
release build, 343 release text checks and the reproducible word-list selection
and hash. Existing cleanup behavior is preserved; no Linux/Windows build is claimed.

## Task 0.3

`phase0-task03-*`: debug/release builds, eleven Swift tests (eight portable text,
three transcript/core compatibility), and a real file-fed protocol smoke through
CLI, serve and MCP. The smoke checks the pre-refactor fixed-audio golden fields,
request IDs, verbatim behavior and the additive MCP structured result. It never
uses mic capture or insertion. Existing main.swift preview concurrency warnings
remain. Speech confidence is not yet exposed by the wrapper and is omitted;
steps remain empty until task 0.4. No full post-phase speech benchmark is claimed.

## Tasks 0.4 and 0.5

`phase0-task04-*` covers both the pipeline/session refactor and its Settings
prerequisite. Nineteen Swift tests cover the portable text contract, pipeline
order/snippet bypass, off/shadow behavior, independent session states, Settings
precedence/reloads/atomic writes and every registered setting's documentation.
Release build and real CLI/serve/MCP file-only protocol checks pass.

The full suite scores exactly match the pre-phase baseline: rules 43/43,
rewrite 26/26, spoken 264/300 excluding known gaps. The Python exit status is 1
because existing spoken failures remain. `phase0-task04-baseline-comparison.log`
compares all 410 voice/rate/case combinations: zero differences in raw text,
final text, pass/fail or failure reasons, including the known-gap fixtures.
The pipeline adds Step metadata but no new text transformations. The existing
Cleaner Foundation Models deprecation warning remains; preview captured-variable
warnings disappeared with the MainActor session split. No live paste/keyboard
overlap test or full key-up latency measurement is claimed (capture rig is 0.9).
