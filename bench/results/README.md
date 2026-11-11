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
