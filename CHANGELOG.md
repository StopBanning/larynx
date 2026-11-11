# Changelog

## Unreleased

- **Live test rig.** `larynx capture-window` (a test window that logs every text change), `larynx listen --feed
  <file> --deliver` (the real paste path, but only into that window: it refuses any other app and puts your
  clipboard back), `scripts/when-idle.sh` (runs a command only when you've been idle 5 minutes, the screen is
  unlocked and Larynx isn't recording, and stops it the moment you touch the keyboard or mouse) and `tests/live.py`.
- **"Not sure about …"** When the speech model was very unsure of a word, the pill names it for 2 seconds after the
  paste (so a glance catches "Robus" before you send), and the dictation is flagged in history. Nothing in your text
  is changed. Calibrated on real recordings; `doubtHint: off` turns it off. Each result now carries the model's own
  confidence. (A second speech model swapping in words where the first was unsure was measured and rejected: it
  fixed almost nothing. See docs/BENCHMARKS.md.)
- "Fable" is in the built-in AI model names.
- **Shadow mode you can read.** `larynx mine --shadow [stage]` lists what a stage set to `shadow` would have
  changed. New risky cleanup rules start as shadow rules: they run on every dictation and record their proposal in
  history without touching your text (first one: dropping a cut-off letter, "who f will actually" → "who will
  actually"). `larynx tidy --shadow` shows them on any text.
- Commas before a tag or a new clause are kept: "a lot with, okay?", "it probably is, let's be honest".
- **Golden set: your own voice as the benchmark.** `larynx golden add <id> [--text "what you said"]` keeps a
  dictation's recording with what you meant to type, in `golden/` on your Mac only; `larynx golden list`,
  `remove`, and `candidates [--apply]`, which offers dictations whose right text is known because you fixed them:
  a word you edited after the paste, or the same sentence said again with a word changed (both now recorded with
  the dictation). `python3 bench/run.py --sets golden` scores every engine through the whole pipeline on those
  clips; results files keep numbers only. See docs/BENCHMARKS.md.

## 0.5.0 (Nov 11, 2026): "Ultra"

**Highlights**

- **New default speech model: Parakeet Ultra.** Picked by benchmark (docs/BENCHMARKS.md): about 37% fewer word
  errors than Bark 3.0 Clean on jargon, noise and hard speech, names spelled right twice as often, and 25 languages
  instead of English only. On the 300-clip cleanup suite it scores 281 against Bark Clean's 264. Bark Clean is still
  in the Speech Model menu. First launch downloads the model (about 500 MB) if it isn't on disk.
- **Numbers as digits, in every app:** "Opus five point five" → "Opus 5.5", "Fable at ninety-four" → "94", "three
  percent" → "3%", "two hundred K" → "200K", "Max twenty X" → "20x", "seven thirty tonight" → "7:30", "move it to
  eleven fifteen" → "11:15", "twenty twenty-six" → "2026". Rules, not an AI model, so it's instant and works in
  Claude and terminals too. Small numbers stay words ("two things", "one of them") unless a unit or label makes them
  numbers ("3%", "step 2"). Numbers no longer wake the AI rewrite in Mail and Messages (it took about 1.6 s).
- **Hands-free:** double-tap the talk key to keep recording with no key held; the next press finishes, Esc cancels.
  A Hands-Free Key (menu) starts and stops with one press each, for a second macro-pad button.
- **Pill Glass slider goes all the way to see-through.** Apple's clear glass still blurs what's behind it, so on a
  dark window the pill looked dark at every setting. Now 0 is no glass at all, 25 clear glass (the new default), 50
  frosted, 100 solid. App icons with a dark tile (Claude, Terminal, dark-mode Mail and Messages) show just their mark.
- **Changing the speech model never leaves you without dictation.** Picking a model in the menu loads it in the
  background (a model's first load can take a minute or two while the Neural Engine compiles it) and keeps using the
  current one; Larynx restarts on the new model once you've been idle for a few seconds.

**Cleanup**

- Ultra types what it hears, so the tidy rules now remove what Bark Clean used to drop inside the model: false starts
  ("I went to the, I drove" and "I went to the I drove" → "I drove"), repeated phrases, mid-sentence "er/ah/eh", a
  word cut off as you restart ("when we w when we want" → "when we want"), and a phrase restarted after an "uh"
  ("from your uh from our workstation" → "from our workstation").
- Commas after "on" and "in" are kept where they end a phrase: "come in, whip up a plan", "Hold on, I'll check",
  "Log in, then click save". Leftover commas are still removed where a filler was ("meet on, Thursday" → "meet on
  Thursday"); "The thing is, we need more time" keeps its comma. A dictation no longer ends on a comma.
- A comma after "if" before a word is dropped ("if, Opus did it" → "if Opus did it"); asides keep theirs.
- Spelled-out acronyms are joined: "A P I" → API, "Q R code" → QR code, "M D files" → MD files, "T. S. M." → TSM.
- When the AI rewrite runs for a correction, the numbers stage formats its result ("at two, no wait, three thirty"
  → "at 3:30").
- Every new rule was replayed over the author's real dictations before shipping (counts in docs/PLAN-v1.md).

**Other**

- Kept audio (`keepAudio`, off by default) is stored as 16-bit FLAC: about a quarter of the size of float WAV.
- Claude and other AI model names (Opus, Sonnet, Haiku, Gemini...) are in the built-in vocabulary.
- `make-app.sh` warms the speech model after installing, so a rebuild doesn't leave the app deaf while it compiles.
- `bench/realvoice.py` compares the speech models on your own kept recordings; `tests/replay.py` replays the tidy
  stage over your history with two builds and prints every line that changes.
- `LARYNX_DEMO_BACKDROP=dark larynx pill-demo` shows the pill over a dark window.

**Fixed**

- "next" turning into "Nuxt". Built-in developer names can no longer replace a real English word; only words you
  chose (your vocabulary, dictionary, project folders, and what Larynx learned from you) can.
- Learning from edits no longer learns capital-letter tidy-ups of ordinary words.

## 0.4.0 (Nov 11, 2026)

- **Liquid Glass pill:** one glass capsule with the icon of the app your words are going to, a waveform driven by
  your voice, and the words as you speak. It sits just above the text field you're dictating into, warns when the
  mic hears nothing, and shows a lock in password fields. A Pill Glass slider in the menu goes from clear glass to
  solid. `larynx pill-demo` plays it for screenshots.
- **History and crash recovery:** dictations are kept on your Mac for 30 days in SQLite with full-text search
  (`larynx history --search`). Each recording is written to disk before transcription, so a crash can't lose it:
  the next launch recovers it. Password fields and password managers are never stored; `history: off` stores
  nothing. Transcript text is out of the log by default. See [docs/PRIVACY.md](docs/PRIVACY.md).
- **Self-learning:** say a sentence again with a word fixed and Larynx learns the fix; edit a pasted word in place
  and it learns that too (now works in Messages and Claude). Menu: Undo Learned. `larynx mine` shows what your
  history would teach.
- **Foundations:** Swift Testing suite (29 tests) on macOS CI, a portable text engine (`LarynxText`) that builds and passes on
  Windows and Linux in CI, a typed transcript and ordered pipeline with off/shadow/on stages, `settings.json` with
  live reload ([docs/SETTINGS.md](docs/SETTINGS.md)).
- **Fixes:** audio files no longer lose their last ~40 ms when transcribed from a file; the word list reads Windows
  line endings.
- **Windows:** feasibility proven in CI (text engine passes; Parakeet v3 runs on a Windows CPU at 0.15x real time).
  Plan in [docs/WINDOWS.md](docs/WINDOWS.md).

## 0.3.0 (Nov 8, 2026)

- Copy fallback: when no text field has focus, the text stays on the clipboard and the pill says so.
- Target lock: the app you started in gets the text, even if you switch apps mid-sentence.
- Second chance: an empty result from a clip with speech is retried with the other speech model.
- Live preview pill, MCP server (`larynx mcp`), vocabulary boosting from your project names, snippets, code by
  voice, menu bar settings, opens at login.

## 0.2.0 (Nov 8, 2026)

- Cleanup layers: the Bark 3.0 Clean speech model drops ums and false starts; tidy rules; an on-device AI rewrite
  (Apple Foundation Models) for self-corrections and numbers, only when needed and behind a guard.
- Per-app modes, personal dictionary, stable signing so rebuilds keep permissions, spoken test suite.

## 0.1.0 (Nov 8, 2026)

- Hold-to-talk dictation into any app with Parakeet TDT v3 on the Neural Engine; `transcribe`, `listen` and
  `serve` (JSON lines) commands.
