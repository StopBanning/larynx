# Changelog

## Unreleased

- **Pick your microphone** (Settings → Speech → Microphone, or `micDevice`): any input macOS knows, by name;
  an unplugged one falls back to the system default. `larynx mics` lists them.
- **Settings window** (menu: Settings…, ⌘,): talk keys, hands-free, pill, speech model, microphone, vocabulary,
  cleanup and stages, history and recordings, screen context, your words. Same settings.json as the menu.
- **Setup window** on a fresh install (or menu: Setup…): the three permissions with live status and buttons to the
  right System Settings pane, a microphone level test, the speech model's state, and a box to try a dictation.
- **One-line install**: `curl -fsSL https://raw.githubusercontent.com/StopBanning/larynx/main/scripts/install.sh | zsh`
  builds and opens Larynx (Apple Silicon, macOS 15+); run it again to update. A Homebrew formula that builds from
  source is in `packaging/homebrew/`.
- **Larynx reads what's on screen** (memory only, never kept): at each press it collects the names around the
  cursor and in the window (about 25 ms in Claude, in the background) to settle words that sound the same, like
  "doc" vs "Dock" when the Dock is on screen. Only a noun that sounds exactly like a name on screen is considered;
  "make it so" never becomes "Mac". In shadow for now: suggestions are recorded (`larynx mine --shadow context`),
  your text isn't changed until they've been checked. `context: off` turns it off; `larynx context` shows what it
  finds without showing any text.
- **Email layout in Mail and Outlook.** "Hi Sam, thanks for… Thanks, Colin." comes out with the greeting on its own
  line, a blank line, the body, and the sign-off and name on their own lines. "Thanks for the help." stays a
  sentence (a sign-off needs a name after it).
- **"New paragraph" and "new line"** said as their own phrase make real line breaks, in every app. "A new line of
  shoes" is left alone.
- Spoken lists ("Number one, flights. Number two, hotels.") are being tried in shadow: proposals are recorded
  (`larynx mine --shadow spoken-list`), your text isn't changed yet. So are announced lists: "three things … X, Y,
  Z" with exactly three items (`counted-list`).
- **Dictations fit what's already in the field.** Several dictations into one message no longer run together
  ("lunch.Are we" → "lunch. Are we"), and a dictation that continues a sentence starts lowercase ("Hey Sam, can
  you…"). Names, "I", acronyms and your vocabulary keep their capitals; empty fields, new lines and a selection
  being replaced are left alone; unreadable fields behave as before. `fitToField: off` turns it off.
- `larynx review`: the daily read in one command: speed per model against the budget, how dictations were
  delivered, which cleanup stages changed text, doubtful, undone and fixed dictations, shadow proposals, microphone
  start times. Counts only; `--text` shows the words.
- `bench/latency.py`: the speed gate run before each release (50 clips, full pipeline; fails over 150 ms median or
  350 ms p90). First run: 66 ms median.
- **The first word isn't lost either.** The microphone took 150-300 ms to start on every press, enough to swallow
  a first syllable. It now stays open for 30 s after a dictation (`micWarm`), so the next press starts instantly and
  includes the 0.15 s before it. Audio while waiting only passes through a 0.15 s buffer in memory and is never
  kept; macOS shows its microphone indicator meanwhile. `micWarm: 0` closes it after every dictation.
- **A paste can't silently fail.** Where the text field can be read, Larynx checks the words arrived; if the field
  is unchanged, it inserts them through Accessibility, then by typing, then leaves them on the clipboard and says
  so. A field that changed or can't be read is left alone, so nothing is ever inserted twice (`verifyPaste`).
- **"Scratch that"** (or "undo that") said on its own within 30 seconds of a dictation, in the same app, undoes it.
  Also in the menu: Undo Last Dictation.
- Dictations put on the clipboard for pasting are marked transient, so clipboard managers don't keep them.
- "I, uh, pressed that" → "I pressed that" (the comma was only the pause before the "uh").
- **The last word is no longer cut off** when you let go of the key while still saying it: Larynx keeps listening
  until the word ends (at most 0.3 s). Dictations that end in a pause stop at once, as before, so there's no added
  delay; on the author's recordings the tail would run for 1 in 53. A new press during the tail starts the next
  dictation without losing either. The microphone's start time is logged on each press.
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
  history without touching your text (first one: dropping a cut-off letter, "we can b maybe borrow it" → "we can maybe
  borrow it"). `larynx tidy --shadow` shows them on any text.
- Commas before a tag or a new clause are kept: "come along with, okay?", "it probably is, let's see".
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
  word cut off as you restart ("when we w when we finish" → "when we finish"), and a phrase restarted after an "uh"
  ("from your uh from our shared drive" → "from our shared drive").
- Commas after "on" and "in" are kept where they end a phrase: "come in, sit down", "Hold on, I'll check",
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
