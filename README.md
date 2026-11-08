# Larynx

Local, offline dictation for macOS. Hold a key, speak, release: the text lands wherever your cursor is.
Speech runs on the Neural Engine with NVIDIA's Parakeet TDT v3 (25 European languages) through
[FluidAudio](https://github.com/FluidInference/FluidAudio). Nothing leaves your Mac.

Built to stand alone and to be embedded: apps such as Locust drive it over JSON lines (see
[docs/INTEGRATION.md](docs/INTEGRATION.md)).

## Status

Phase 0 spike. Measured on an M6 Mac mini with 16 GB:

| Step | Time |
| --- | --- |
| First run, model download (about 500 MB) and compile | 46 s, once |
| Later model loads | about 0.1 s |
| Transcribing an 8.7 s clip | 51 to 74 ms |
| Optional cleanup with Apple's on-device model | 1.3 to 3.9 s, results vary run to run |

Cleanup (`--clean`) is experimental. In testing it sometimes dropped words ("I think we should") or turned a
question into a statement, so it is off by default and falls back to the raw transcript on any doubt.

## Use

The easy way is the menu bar app: `./scripts/make-app.sh` builds `~/Applications/Larynx.app`. Open it, allow
Microphone, Input Monitoring and Accessibility when macOS asks, then hold Fn, Right Option or Right Command to talk (pressing another key while holding cancels, so shortcuts still work). Its model
lives in `~/Library/Application Support/Larynx/models`; its log is `~/Library/Logs/Larynx.log`. Some keyboards (Keychron, for one) never send
Fn to macOS. Change the keys with `defaults write com.automatedworkflow.larynx keys rightCommand` (comma-separated).
The app is signed ad hoc, so each rebuild makes macOS forget its permissions: run
`tccutil reset All com.automatedworkflow.larynx` and allow them again.

From a terminal:

```bash
swift build -c release
.build/release/larynx transcribe note.m4a          # print a transcript
.build/release/larynx listen --key fn              # system-wide hold-to-talk
.build/release/larynx serve                        # JSON lines for host apps
```

`listen` needs three macOS permissions, each granted by you in System Settings > Privacy & Security:
Microphone, Accessibility (to paste) and Input Monitoring (to see the key). Keys: `fn`, `rightOption`,
`rightCommand`, `rightControl`. `--models-dir <path>` keeps the model somewhere other than FluidAudio's default.

## How it works

| File | Job |
| --- | --- |
| `Recorder.swift` | AVAudioEngine tap, resampled to 16 kHz mono |
| `Transcriber.swift` | Loads Parakeet v3 once, transcribes a clip |
| `Hotkey.swift` | Event tap on one modifier; re-arms itself when macOS switches it off |
| `Inserter.swift` | Clipboard plus Cmd+V mapped through the keyboard layout; restores your clipboard; refuses during Secure Input |
| `Cleaner.swift` | Optional Apple Foundation Models pass with a guard against answers |
| `main.swift` | The `transcribe`, `listen` and `serve` commands |

## Roadmap

1. Daily driver: menu bar app, overlay, sounds, history, personal dictionary, a better cleanup model, guided permissions.
2. Context: text around the cursor and the selection via Accessibility, per-app styles, code words.
3. Voice edits on selected text, learning from your fixes.
4. Signed, notarized releases; Windows later.

## License

MIT. Parakeet TDT v3 weights are CC-BY-4.0 (NVIDIA); FluidAudio is Apache-2.0.
