# Larynx for Windows

Goal: the same product on Windows 10/11: hold a key, speak, let go, and clean text lands where the cursor is,
fast, all on the PC, free. First written Nov 11, 2026 as a plan; rewritten Nov 14 after the first working build.

Status: **a working prototype, built and tested in CI only.** It dictates into Notepad end to end on GitHub's
`windows-2025` runner (`.github/workflows/windows.yml`). No one has used it on a real Windows PC yet. The table
"What still needs a real PC" says exactly what CI cannot show.

![The pill on CI's Windows desktop, mid-dictation: a blue waveform and the words heard so far, just above
Notepad's caret, while Notepad keeps the focus](images/windows-pill.png)

The pill on the runner's desktop halfway through a dictation, from the end-to-end test. These are the raw words
heard so far; the cleaned text replaces them at key-up.

## The stack (decision)

| Part | Choice | Why |
| --- | --- | --- |
| App | **One native Rust program** (`windows/`), Win32 through the `windows` crate. `larynx.exe` is the tray app; `larynx-cli.exe` is the same code with a console, for tools and tests. | No Electron: a dictation app sits in the tray all day, so it should start instantly and use little memory. The Nov 11 plan had an Electron shell; one process with no IPC between the key, the microphone and the pill is simpler and feels more native. |
| Speech | **Parakeet TDT 0.6B v3** (the Mac's default model family), int8 ONNX ([istupakov/parakeet-tdt-0.6b-v3-onnx](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx), CC-BY-4.0), run by **ONNX Runtime 1.31** through [`ort`](https://github.com/pykeio/ort) 2.0.0-rc.15 | `ort`'s Windows build already includes the **DirectML** execution provider (any DirectX 12 GPU: NVIDIA, AMD, Intel, Qualcomm). The same code can use OpenVINO (Intel NPU), QNN (Snapdragon NPU) or Windows ML later. The greedy TDT decoder is ~80 lines of Rust (`asr.rs`), so we don't depend on sherpa-onnx. |
| Where it runs | The encoder (nearly all the work) on DirectML or the CPU; the small decoder always on the CPU. `--provider auto` (the default) times both on first launch and remembers the faster in `provider.txt`. | A per-token decoder call costs microseconds on the CPU and a round trip on a GPU. |
| Streaming | Recording is cut at pauses while you talk. Each piece is transcribed in the background with 1.5 s of audio before it and 1 s after it, keeping only the words that fall inside it (`stream.rs`). At key-up only the audio after the last cut is left. | Key-up latency depends on the last few seconds, not on the whole dictation. The context on both sides keeps the model from treating each piece as a separate sentence. |
| Cleanup | **LarynxText itself** (Swift), run as `larynx-text.exe`: a small process that starts once and cleans one JSON line at a time | Same code, same `tests/cases.json` as the Mac. The first try loaded Swift as a DLL into the Rust process; on Windows that hung (a CI test ran for 10 minutes before it was cancelled). A separate process works, costs well under a millisecond per request, and a crash in it can't take the app down: the words then go out as the model heard them. |
| Talk key | `WH_KEYBOARD_LL` hook on its own thread; **Right Ctrl** by default (`--key ralt/capslock/f13…`) | The key is never swallowed, and pressing any other key while holding it cancels, so Right Ctrl+C and other shortcuts still work. Right Alt gets the masking key other hotkey tools use, so a lone Alt doesn't open menus. Our own synthetic keys are marked and ignored. |
| Microphone | WASAPI shared mode, asking Windows for 16 kHz mono float (`AUTOCONVERTPCM`), warm for 30 s after a dictation with 0.2 s of pre-roll | Same as the Mac: the next dictation starts at once, and the first word isn't clipped. |
| Insertion | Mirrors the Mac's `Inserter`: bring the app back if you switched away, refuse password fields (UI Automation `IsPassword`), paste through the clipboard **marked to stay out of clipboard history and cloud clipboard**, check that the field changed (UI Automation, or `WM_GETTEXT` for classic Edit controls), fall back to typing Unicode characters, and if nothing worked, leave the words on the clipboard and say so. The old clipboard comes back unless something new was copied meanwhile. | Reliable in any app, never inserts twice, never loses words. |
| Pill | A layered, click-through, never-activated tool window, drawn with Direct2D/DirectWrite, just above the caret (or the focused field, or the taskbar): waveform, the words as you speak, then ✓ or the reason the text went to the clipboard | Never steals focus (CI checks it). It is a tinted capsule for now, **not real Acrylic**: see "What's left". |
| Tray | Notification-area icon with status, the last latency, "Copy last dictation", "Open Larynx folder", "Quit" | |

## What was measured

All on GitHub's `windows-2025` runner: a Hyper-V virtual machine with 2 cores / 4 threads of an Intel Xeon
Platinum 8573C and **no GPU**, so every number below is the CPU path with the int8 model. The audio is synthetic:
Windows' own text-to-speech voice reading sentences written for the test (`windows/ci/sentences.json`). No one's
real dictation is used. Runs on different VMs vary by about ±20%.

**End to end in Notepad** (`larynx-cli e2e`; timed from outside the app, from the synthetic key-up until the
words are in Notepad's text box; a 7.9 s dictation with fillers):

| Run | First dictation | Second (warm) | Inserted |
| --- | --- | --- | --- |
| [43558130163](https://github.com/StopBanning/larynx/actions/runs/43558130163) | 413 ms | 352 ms | "So I think we should push the launch to next week, because the installer still needs testing." |
| [43560527362](https://github.com/StopBanning/larynx/actions/runs/43560527362) | 539 ms | 423 ms | the same |

Where the time goes (app log, run 43560527362, second dictation): about 396 ms finishing speech after key-up (3.5 s
of audio was left after the last cut), 16 ms cleanup, 8 ms paste, and the field confirmed changed 7 ms after that.
The app is ready 4 s after launch (model load plus a timing probe).

**Speech alone** (`larynx-cli bench`, run 43560527362): "whole" transcribes the full recording after key-up, which
is what a non-streaming app does (the median of 3). "Streamed" plays the recording in real time, the way the app
hears it, and measures the wait after the key is let go at the end.

| File | Audio (s) | Whole (ms) | RTF | WER | **Streamed: after key-up (ms)** | Left at key-up (s) | Segments | WER |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| short | 2.5 | 232 | 0.094 | 0.0% | **213** | 2.5 | 0 | 0.0% |
| question | 4.4 | 372 | 0.085 | 0.0% | **294** | 1.7 | 1 | 0.0% |
| medium | 10.8 | 827 | 0.076 | 0.0% | **386** | 3.1 | 3 | 0.0% |
| fillers | 7.9 | 624 | 0.079 | 0.0% | **366** | 3.2 | 2 | 0.0% |
| long | 24.2 | 1858 | 0.077 | 2.9% | **494** | 4.8 | 7 | 2.9% |
| longer | 36.6 | 2970 | 0.081 | 1.9% | **502** | 4.1 | 11 | 1.9% |

What this says:

- **On CI's slow CPU, the wait after key-up stays at 0.2-0.5 s however long you talk**, against up to 3 s for
  transcribing at key-up. The Mac is at about 0.15 s on the Neural Engine. A modern laptop CPU should be well
  ahead of a shared 2-core VM, and a GPU or NPU ahead again. That is the first thing to measure on a real PC.
- **Streaming costs no accuracy** on these files: the same word error rate as transcribing the whole recording.
  CI fails if it ever gets worse by more than 3 points. Getting there took three attempts, all kept as unit tests
  in `stream.rs`: two transcriptions place the same word at slightly different times, so the seam is joined by
  the words both pieces share, with timing only as the fallback. One known leftover: an occasional repeated word
  at a seam ("The budget's budget"), within the same error rate as whole-file transcription.
- The int8 model's real-time factor on this VM is 0.08-0.09 (3 s for 37 s of audio). The Nov 11 sherpa-onnx
  measurement on a similar runner was 0.147. The difference is ONNX Runtime 1.31 and a per-piece pipeline with no
  resampling or file overhead.
- The waits that remain are the right-context rule (a segment is only sent once 1 s of audio exists after its
  cut), plus the last few seconds. On faster hardware both shrink, and the cut rule can be tuned (`stream::Config`).

## What works (and how CI proves it)

| Works | Proven by |
| --- | --- |
| Builds from source into a self-contained folder (no toolchain needed to run it) | `stage.ps1`, then the cleanup cases run from that folder with `PATH` stripped to `C:\Windows\System32` |
| The cleanup matches the Mac's on every case in `tests/cases.json` (all text cases through tidy, every number case) | `larynx-cli cleanup-check tests/cases.json` through `larynx-text.exe`, plus the Rust unit test that also checks a full sentence and accented text |
| The model hears the fixture exactly | `larynx-cli transcribe` on `tests/fixtures/report.wav` |
| DirectML is built in and selectable; `auto` falls back to the CPU when there is no GPU | the DirectML step: on CI it reports "No devices detected that match the filter criteria", because the VM has no GPU. **DirectML has not run the model yet.** |
| Hold Right Ctrl in Notepad, speak, let go: the cleaned words appear (fillers gone), Notepad keeps the focus, the pill is on screen while talking, the clipboard is restored | `larynx-cli e2e`, twice in a row (cold and warm) |
| Right Ctrl+C while talking cancels the dictation and types nothing | same test |
| The very first start, from an empty folder: a welcome window at once (on Acrylic, with the Larynx icon), no console window, the 670 MB model downloading with a progress bar, then the instructions with the cursor in a practice box; talking into that box types the cleaned words; closing it leaves Larynx running; starting Larynx again brings it back; picking another talk key in the tray takes effect and is remembered | `larynx-cli e2e-welcome`, with screenshots of the window downloading and ready |
| Dictating into a web page in Microsoft Edge (webmail; Teams and Outlook use the same engine): the words arrive, Edge keeps the focus, the clipboard comes back | `larynx-cli e2e-browser` |
| Meeting mode: the call echoing into the microphone stays out of your side, Mute me and Unmute (real mouse clicks), Stop, notes through Claude Code (a stand-in) with no API key reaching it, a meeting cut off by killing the app finished after the restart | `larynx-cli e2e-meeting`, checked by `windows/ci/check-meeting-app.py` |
| The same meeting in a hard room with a cheap microphone (echo off the walls, fan noise, hum, clipping) and on a Bluetooth headset's 8 kHz microphone | `e2e-meeting --room bad` and `--room headset` (`room.rs`) |
| Meeting mode through real Windows audio devices: a virtual cable (VB-Cable) plays the call on the speakers, which the app records and the microphone hears in full, as with no headphones while you stay quiet (the hardest echo case; nothing may end up as yours). The cable's second input is the same input underneath, so your own voice is covered by the file-fed runs instead. It starts with Windows blocking microphones (the panel must say where to turn them on) and turns access on mid-meeting (the microphone must be picked up; a registry change reaches Windows when its audio service restarts, so the test restarts it). Partway, Windows' audio service is restarted, dropping every app's audio: the panel says so, recording goes on, both sides reconnect, and the lines after the gap are on time | `larynx-cli e2e-meeting-devices`, checked by `windows/ci/check-meeting-devices.py` |
| The meeting panel at 100%, 150% and 200% screen scaling | screenshots from the room runs (`--dpi`, which sets `LARYNX_TEST_DPI`) |
| "Send a report…" writes a report with the computer's details and audio devices, and nothing that was said | the devices test, then the checker reads the file |
| The meeting rules (echo filter, listening hint, names, numbers, the notes check, the exact notes prompt) match the Mac's | `tests/meeting-cases.json`, read by the Rust and the Swift tests |

The `e2e` test feeds the recording through `--feed` at real-time speed, because CI machines have no microphone.
Everything after the microphone is the real code path: hook, focus, speech, cleanup, clipboard, `SendInput`,
read-back.

## What still needs a real PC

| Needs a real Windows PC | Why CI can't show it |
| --- | --- |
| **GPU and NPU speed** (DirectML on a real graphics card; QNN on Snapdragon; OpenVINO on Intel NPUs) | CI has no GPU; DirectML falls back to a software adapter there |
| Latency on a normal laptop CPU | CI's 4 vCPUs are slow and shared |
| A real microphone and speakers in a real room, a real sound chip, Bluetooth itself | CI's audio devices are a virtual cable: the capture and loopback code is real, the sound is clean |
| The pill's look and placement over real apps, on several monitors; Windows' own scaling (CI draws the meeting panel scaled, but Windows stays at 100%) | CI has one screen at 100% and no GPU compositor effects |
| Claude Code installed and signed in for real | CI uses a stand-in that checks what it is given |
| Insertion into apps beyond Notepad and Edge: Word, Slack/Teams (Electron), Windows Terminal, elevated windows | only Notepad and Edge are scripted |
| Antivirus and SmartScreen reactions to an unsigned app with a keyboard hook | CI has no third-party antivirus |

These need a real Windows PC, which is the next step.

**The Windows beta**, for testers: the Actions tab → `windows` → Run workflow on main with "Publish this build as the
Windows beta" ticked. If every test passes, the build replaces the one pre-release tagged `windows-beta`, so a
tester keeps one link: `https://github.com/StopBanning/larynx/releases/download/windows-beta/larynx-windows-x64.zip`.
Nothing is published unless someone presses that button.

To try it on a PC: download the beta (or the `larynx-windows-x64` artifact from a green `windows` run), unzip it
and start `larynx.exe`; the first start downloads the model (about 670 MB) into `%LOCALAPPDATA%\Larynx`. Hold Right Ctrl and talk. `%LOCALAPPDATA%\Larynx\larynx.log` has the timings of every dictation
(not the words), including which provider `auto` chose and how long each took on the probe.

## What's left

| # | Step | Done when |
| --- | --- | --- |
| W7 | Real-hardware numbers: p50 key-up-to-text on a laptop CPU, an NVIDIA/AMD/Intel GPU, a Snapdragon | numbers in BENCHMARKS.md from `larynx-cli bench` + the app log |
| W4b | The meeting panel is on Acrylic (`glass.rs`, done; the blur itself is unchecked until a real GPU). Still to do: Acrylic behind the pill, which needs it off the colour key (per-pixel alpha, a capsule shape and click-through kept), and the target app's icon in the pill | a screenshot on real hardware |
| W8 | NPU: Windows ML (Windows App SDK) or `ort`'s QNN/OpenVINO builds, an fp16 encoder for GPUs | faster than DirectML on a Copilot+ PC |
| W2b | Microphone choice, hands-free (double tap), Esc to cancel, the "no sound" warning | parity with the Mac's Talking section |
| W5 | History (same SQLite schema as `History.swift`), dictionary and snippets from `%APPDATA%\Larynx`, learning from fixes via UI Automation | port of `tests/history.py` |
| W6 | Installer (MSIX or a signed zip), start at login, updates; code signing (W-c) | a signed build from CI |
| W9 | ARM64 build (`ort` ships an `aarch64-pc-windows-msvc` DirectML build; Swift supports ARM64 Windows) | the CI matrix builds it |
| W10 | `serve` JSON protocol (INTEGRATION.md) so Locust can drive it | `tests/protocol.py` passes against it |

## Open decisions

| # | Decision | For now |
| --- | --- | --- |
| W-c | Code signing: an unsigned app shows a SmartScreen warning, and antivirus is wary of keyboard hooks in unsigned apps. Azure Trusted Signing costs about $10 a month | Unsigned, with instructions |
| W-d | ARM64 (Snapdragon) in the first release | x64 first, ARM64 right after |

## Risks

- **CPU-only laptops:** Parakeet 0.6B is heavy for a CPU. Streaming hides most of it for long dictations; a
  short one is transcribed whole at key-up. Mitigations, in order: DirectML (most laptops have a DirectX 12 iGPU),
  the NPU (W8), and a smaller model as a fast tier.
- **Elevated windows:** Windows won't let a normal app send input to an elevated one. The words then stay on the
  clipboard and the pill says so.
- **Pause-based cuts on the CPU:** if the model can't keep up while you talk, segments queue up and key-up waits
  for them. The benchmark measures this as "after key-up".
