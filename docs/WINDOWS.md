# Larynx for Windows: plan

Written Nov 11, 2026. Goal: the same product on Windows 10/11 (x64 and ARM64): hold a key, speak, release, the text
lands where the cursor is, all on the PC, free. Same cleanup, same settings and history format, same `serve` JSON
protocol (so Locust can drive it on Windows too), and the same glass pill.

## What is already proven

| Piece | Evidence |
| --- | --- |
| The text cleanup (`LarynxText`: fillers, stutters, corrections, code words, dictionary, snippets, rewrite guard) compiles with Swift on Windows and passes the same tests as the Mac | `.github/workflows/portable.yml`, job `windows` (windows-2025, Swift 6.1.2). All 43 golden cases and the unchanged-sentence checks passed on the first run; the one failure was the word list reading CRLF line endings, fixed in 7d55bdb. |
| The same speech model family runs on Windows | Same workflow, job `speech-windows`: Parakeet TDT 0.6B v3 (int8 ONNX) through sherpa-onnx 2.0.1 on a 4-core CI VM transcribes `tests/fixtures/report.wav` exactly ("Please send the report tomorrow.") at a real-time factor of 0.147 on 4 threads (5.3 s of audio in 0.78 s, run 42960287829): about 1.5 s per 10 s of speech on CI hardware, against about 0.1 s on the Mac's Neural Engine. A modern laptop CPU should be 2-3x faster than the CI VM; streaming during recording (master plan 4.2) hides most of the rest. |
| The glass look on Windows | [locust-glass](https://github.com/StopBanning/locust-glass): Acrylic/Mica on Windows 11, the lens and melting shapes on any Chromium, screenshot-tested on Windows 11 24H2 in CI. |

## Architecture (recommended)

Three parts, each replaceable, talking JSON lines like the Mac app already does with Locust:

1. **`larynx.exe` (Rust, `windows` crate):** the engine. It handles the talk key, the microphone, speech, focus
   detection and pasting, and serves the same `serve` protocol as the Mac binary (see INTEGRATION.md).
   - Talk key: a low-level keyboard hook (`WH_KEYBOARD_LL`) on Right Ctrl or Right Alt. Fn never reaches Windows.
     A key pressed while holding cancels, as on the Mac.
   - Microphone: WASAPI (through `cpal`), resampled to 16 kHz mono.
   - Speech: sherpa-onnx (C API through `sherpa-rs`, or the C API directly) running Parakeet TDT 0.6B v3 int8, plus
     the Parakeet CTC 110M model for vocabulary (sherpa-onnx hotwords). DirectML when a GPU is present, else CPU.
   - Cleanup: links `LarynxText` built as a Swift static library for Windows (CI already builds it), or runs it as a
     small `larynx-text.exe` JSON-lines process. One implementation, one test file (`tests/cases.json`).
   - Focus, password fields, reading the field back (learning from fixes): UI Automation (`IUIAutomation`).
     `IsPassword` replaces Secure Input; `ValuePattern`/`TextPattern` replace AXValue; the element's
     `BoundingRectangle` places the pill above the field.
   - Paste: save the clipboard, set the text with the `ExcludeClipboardContentFromMonitorProcessing` format (so
     clipboard history doesn't fill up), `SendInput` Ctrl+V, restore. Fall back to typing with `KEYEVENTF_UNICODE`
     where paste is blocked. Bring the target window back first (`SetForegroundWindow` with the usual
     `AttachThreadInput` dance).
   - History: the same SQLite schema as `History.swift`, in `%APPDATA%\Larynx\`.
2. **The shell (Electron + locust-glass):** tray icon and menu, settings, history window, and the pill. The pill is
   a transparent, always-on-top, non-focusable, click-through window (`focusable: false`, `setIgnoreMouseEvents`)
   with Acrylic behind the same single capsule as the Mac (app icon, waveform, words). The waveform reads levels
   from `larynx.exe` events.
3. **AI rewrite (optional):** Apple's model doesn't exist on Windows. Use the plan's `Polisher` (task 3.3): Windows
   AI APIs (Phi Silica) on Copilot+ PCs when available, a local model (Ollama / llama.cpp), or rules only.
   Everything else works without it.

Why not all Swift on Windows: the text core is fine in Swift, but UI Automation, hooks and a glass UI are much
easier in Rust + Electron, and Electron is what Locust and locust-glass already use.

## Steps (each ends in a test)

| # | Step | Done when |
| --- | --- | --- |
| W0 | Feasibility (this commit range) | Text core and speech model run on Windows in CI |
| W1 | `larynx.exe transcribe <file>` and `serve` with `transcribe` (no mic): sherpa-onnx + LarynxText | `tests/protocol.py` passes against it on the Windows runner; the cleanup suite's text cases match the Mac output exactly |
| W2 | Microphone + `serve` `start`/`stop` | A WAV fed through a virtual input on the runner (or `--feed`) gives the same text as the file path |
| W3 | Talk key, focus check, paste, clipboard restore, target lock, copy fallback | Scripted test on the runner pastes into Notepad (CI only: never on a real user's desktop), plus a password field stays unstored |
| W4 | Shell: tray, settings, pill with locust-glass | Screenshot test like locust-glass's `screens` workflow shows the pill's three states |
| W5 | History, crash spool, learning from fixes via UI Automation | Port of `tests/history.py` passes on Windows |
| W6 | Installer and updates | A signed (or clearly unsigned) installer from CI; winget manifest |
| W7 | Latency and accuracy on real hardware | p50 key-up-to-text and WER on the bench sets measured on a real Windows laptop, written into BENCHMARKS.md |

## Decisions for Colin

| # | Decision | Default until answered |
| --- | --- | --- |
| W-a | Architecture above (Rust engine + Electron/locust-glass shell + Swift text core) | Go with it |
| W-b | A real Windows machine for W3/W7 (the old PC's C: drive, a VM in Parallels/UTM on ARM, or a cheap mini PC) | CI only; real-hardware numbers wait |
| W-c | Code signing: unsigned shows a SmartScreen warning; Azure Trusted Signing costs about $10/month | Unsigned, with instructions |
| W-d | ARM64 Windows (Snapdragon laptops) in the first release | x64 first, ARM64 right after |

## Risks

- **CPU speed:** the Mac runs the model on the Neural Engine. On a CPU-only laptop, Parakeet 0.6B int8 may be
  several times slower. Mitigation: DirectML/GPU when present, the 110M model as a fast tier, and streaming
  transcription during recording so key-up only finishes the last segment (master plan 4.2).
- **Apps that block synthetic paste** (some remote desktops, elevated windows): Windows won't let a normal app send
  input to an elevated one. Say so in the pill and keep the text on the clipboard.
- **Antivirus heuristics** flag keyboard hooks in unsigned apps. Signing (W-c) reduces it.
