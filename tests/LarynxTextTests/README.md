# Cleanup contract tests

Run `swift test` from the repository root. These tests use Swift Testing and read
`tests/cases.json` directly. They do not load speech models, record audio, call the
Apple rewrite model, paste text, or access the personal dictionary.

- `text`: every golden output is checked with its specified cleanup mode.
- `rewrite`: each expected output is checked by the deterministic rewrite guard.
  `guardCorrection` selects the correction policy; `guardProblem` is null for an
  accepted output or the exact rejection reason. These checks do not claim that
  the language model actually produces that output; `tests/suite.py` tests that.
- `mustNotChange`: 100 distinct ordinary sentences, checked unchanged in standard,
  AI, and correspondence modes. Keep each `in` equal to its `expect`.
- Separate rejection tests cover empty output, excessive deletion, additions,
  invented words, and retaining the wrong side of a correction.

On this Mac, the selected Command Line Tools installation cannot resolve the
Swift Testing macro plugin (and native build mode cannot import Testing). Use the
already installed full Xcode for this command only:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

This does not change the system developer directory.

The first build compiles FluidAudio dependencies and takes longer than the
10-second test budget. Measure a warm `swift test` separately. The target depends
on LarynxCore until Phase Zero task 0.2 extracts LarynxText.
