# Meeting mode: design

For people who sit in meetings all day and want to
walk out with the summary already written. The bar is the rest of Larynx: no setup, instant, private, and nothing to
fix afterwards.

## What the person does

1. **Start.** Menu bar → Start Meeting, or a shortcut (⌥⌘M). A small pill shows a red dot, the time and the level of
   each side (you, and the call). Nothing else on screen.
2. **Talk.** In a room, Larynx hears the room through the Mac's microphone. On a call (Zoom, Teams, Meet, FaceTime,
   anything), it also hears the call's audio directly from the Mac, so it gets the other people clearly, not through
   the speakers.
3. **Stop.** Same shortcut or the pill's stop button. **The summary is ready within seconds**, because the transcript was
   written while the meeting ran: stopping only finishes the last half minute and writes the summary.
4. **Read.** A Meeting window, one page:
   - a title it gives the meeting, the date, the length, who spoke;
   - **Summary**: three to five lines;
   - **Decisions**;
   - **Action items**: what, who, by when (only when someone said so: never guessed);
   - **Open questions**;
   - the full transcript underneath, with times and who said what, searchable.
5. **Use it.** Copy (Markdown or plain), Email it (opens Mail with the summary), Save to Notes, or Export. Every meeting
   stays in a Meetings list beside History, on the Mac.

## How it works

| Piece | How | Already in Larynx? |
| --- | --- | --- |
| Microphone | The same capture as dictation, kept running | Yes |
| The call's audio | macOS's own audio tap (Core Audio process tap, macOS 14.4+): no driver to install. Asks once for "System Audio Recording" permission | New |
| Who said what | Your microphone is **you**; the call's audio is **them**, for free. Telling the other people apart (Speaker 1, 2, 3) uses FluidAudio's on-device speaker separation (models from Hugging Face, a download) | Partly new |
| Transcript | Parakeet Ultra in 30-second pieces as the meeting runs, so the transcript is done when the meeting is | Engine yes, chunking new |
| Cleanup | The dictation cleanup, in the AI mode's spirit: fillers and stutters out, voice kept, nothing rewritten | Yes |
| Never losing it | The crash spool: audio written to disk as it comes in, so a crash or a closed lid loses nothing | Yes (spool), extended |
| Summary | Apple's Foundation Models with guided generation: the summary comes back as a typed structure (summary, decisions, action items with owner and date, open questions), so the layout never breaks | Framework yes, meeting prompts new |

**Decided (Nov 14): Claude writes the notes, automatically after every meeting.** Apple's on-device model (8,192
tokens) was too weak on the test meetings, and Private Cloud Compute needs an entitlement we can't get yet. So the
notes come from Claude Opus 5.5 through the Anthropic API (`Sources/LarynxCore/ClaudeNotes.swift`): one request with
the whole transcript (never the audio), structured output in a fixed shape (title, summary, decisions, action items
with owner and due, open questions), then the same `verify()` check against the transcript before anyone sees it.
The key is saved in the Keychain from Settings → Meetings; without one, `auto` falls back to the Mac's own model. If
the request fails (no internet, no credit), the transcript is saved and the meeting shows "Write the summary now".
The Windows app uses the same request and schema, so both write the same notes.

**Claude Code first, on the person's own Claude plan.** A Claude subscription can't be used by
an app through the API, but Claude Code, signed in to the plan, can be run headless. When it is installed, Larynx runs
`claude -p` with the same instructions and schema (`ClaudeCode` in `ClaudeNotes.swift`, `claude_code_notes` in
`windows/src/meeting.rs`): `--json-schema` for the shape, `--model opus`, `--tools ""` (no tools at all),
`--strict-mcp-config` and `--setting-sources ""` (none of the person's MCP servers, settings or hooks),
`--no-session-persistence`, the transcript on stdin and an empty temporary folder as its working directory.
`ANTHROPIC_API_KEY` is removed from its environment, or Claude Code would bill that key instead of the plan. If Claude
Code isn't installed, or fails (not signed in, offline) and a key is saved, the API key is used; with neither, the
Mac's own model. Not `--bare`: it skips reading the keychain, where the plan's sign-in is kept. On Windows only the
native install (`claude.exe`) is found, not the npm one.
First real run (Nov 16, `tests/meeting.py --summary claude`, on a real Claude plan): notes in 9 to 11 seconds. The weekly sync
passes; the client call names "Kriya" throughout, because the speech model heard "Priya" that way and Claude used the
name as heard (a speech error, not a notes error). The test now accepts any task that fits when one sentence holds
two ("tell the printer today, a new proof by Thursday").

The comparison that led there:

| | On the Mac (Apple on-device model) | Apple Private Cloud Compute |
| --- | --- | --- |
| Where the transcript goes | Nowhere | Apple's private servers, for the summary only; Apple's design keeps nothing and lets researchers verify that. Audio and transcript are still made on the Mac |
| Size it can read at once | 8,192 tokens (about 40 minutes of talk) | 32,768 tokens (two to three hours) |
| Long meetings | Summarized in parts, then the parts summarized: works, can lose the thread | The whole meeting in one pass |
| Quality | Good on short meetings | Expected to be clearly better: a larger model |
| Promise | "Nothing leaves your Mac" stays true | "Your audio never leaves your Mac" |

The plan: build both behind one switch, run both on the same test meetings, and read the two summaries side by side before
picking the default.

## Who it is for

Someone busy who is not a computer person. Every screen is judged by: would they know what is happening, and
what to do next, without asking anyone?

- **One big button that says what it does:** "Start recording this meeting". The shortcut exists, but nothing needs it.
- **Always say what is happening, in plain words, big enough to read at a glance:** "Recording · 12:04" with a steady
  red dot; after stopping, "Writing your summary… about 10 seconds"; then the summary opens by itself.
- **No technical words anywhere:** no "transcript chunking", no model names, no "Speaker 2" (it is "You", the person's
  name if it was said, or "Someone on the call").
- **Large type, high contrast, generous click targets;** follows the Mac's text size and contrast settings.
- **Hard to get wrong:** stopping asks nothing (it is never destructive); discarding a meeting asks first and can be
  undone from the Meetings list; closing the window never loses a meeting.
- **The obvious next step is a button:** "Email this to me" (one click, their own address filled in), "Copy", "Print".
- **If something is wrong, say it plainly with what to do:** "I can't hear the microphone. Check it isn't muted."

## Refinement: the details that make it feel finished

- The summary uses people's names when they were said ("Dana will send the deck by Friday"), never "Speaker 2 will".
- Action items only when someone committed; no invented owners or dates.
- Starts in under half a second; stopping to summary under 10 seconds for an hour-long meeting.
- An hour of meeting costs no fan noise and little battery (the Neural Engine does the work).
- A quiet reminder when a call app starts using the microphone: "Record this meeting?" (one click, never automatic).
- A visible recording indicator the whole time, and a one-line note in the window: recording others may need their
  consent where you live.
- Audio is not kept by default (an hour is about 30 MB); the transcript and summary are. A setting keeps audio for
  30 days, like dictations.

## How it is tested (before anyone sees it)

- **Synthetic meetings** made on the Mac with macOS voices: two to five people, 5, 20 and 60 minutes, with known
  decisions and action items written into the script. The test checks that every scripted decision and action item
  is in the summary, nothing invented is, and the timings hold.
- **Two-sided audio**: a "you" track and a "call" track fed as files, so the you/them split is checked without a real
  call or permission prompt.
- **A real meeting** (or a public meeting recording with permission to use it).
- Summaries from both models read side by side.

## On Windows

The Windows app has meeting mode too (`windows/src/meeting.rs`, portable
and unit-tested; `windows/src/win/meeting.rs`, the recording and the window):

- **Right-click the Larynx icon → Start recording this meeting.** The microphone is "You"; the computer's sound (WASAPI
  loopback, so Zoom, Teams, Meet or a phone app all work) is "On the call". Both go to disk every second under
  `%LOCALAPPDATA%\Larynx\meetings\spool`, so a crash loses nothing; an interrupted recording is finished the next
  time Larynx starts.
- A small window in the corner, always on top, says "Recording · 12:04" beside a red dot, with a big Stop button.
  While recording, the talk key is ignored (the microphone belongs to the meeting).
- Stop: "Writing your summary…", then the notes open by themselves as a page in the browser: summary, decisions, to
  do with names, still open, and everything that was said underneath; Email this to me, Copy and Print buttons; large
  type. **Your meetings** (same menu) lists them all.
- The notes are the Mac's: the same Claude request, schema and `verify()`, through Windows' own `curl.exe` (the tool
  `larynx setup` already uses), with the key going in on standard input. The key lives in Windows Credential Manager:
  right-click → **Set Claude key…**. Claude Code (`claude.exe`, signed in to a Claude plan) is used first when it is
  installed, the same as on the Mac. **Gemini**, for workplaces that allow Gemini or Copilot but not Claude: right-click → **Set Gemini key…** (a free key from aistudio.google.com) and Gemini writes the notes with the
  same instructions, schema and `verify()` (`gemini_notes`, generateContent with `responseJsonSchema`; model
  `gemini-flash-latest`, or `LARYNX_GEMINI_MODEL`). The order is Claude Code, the Claude key, then Gemini; Gemini also
  steps in when Claude fails (a plan's 5-hour limit, say). Copilot has no API for this, so every meeting page has
  **Copy for Copilot or Gemini**: the same instructions and the transcript as one message, with buttons that open
  Copilot and Gemini to paste it into. With no AI set up at all, the page says to use that button. If the notes fail,
  the transcript is saved and the menu offers **Write the summary again**.
- "Email this to me" fills in the address in `%LOCALAPPDATA%\Larynx\meetings\email.txt` (or `LARYNX_MEETING_EMAIL`).
- CI speaks the scripted client call with Windows' voices into two tracks, runs `larynx-cli meeting you.wav call.wav
  --save` against a stand-in for the API, and checks both sides, the request and the saved page.

**A second computer as the recorder.** When the recording computer plays nothing (it sits by the speakers of the
computer the call is on, or among people in a room), the microphone hears everyone: every line is "In the room"
instead of "You", and the notes request says one microphone heard everyone (`ROOM_LEGEND`), so names come from how
people address each other and nothing is credited to "you" by guess. **Start Larynx with Windows** in the tray keeps
such a computer ready after a restart.

Not yet on Windows: transcribing while the meeting runs (it happens after Stop, about a minute per 20 minutes of
meeting on a CPU) and telling several people on the call apart.

## What is not in version 1

Calendar integration, live captions during the meeting, translation, sharing links, teams. Each is easy to add later
once the core is right.

## Order of work

1. Meeting recorder: start/stop, mic plus call audio into the spool, the pill. Tested with files.
2. Chunked transcription while recording, you/them labels.
3. The summary: guided generation on both models; the test meetings; the two read side by side.
4. The Meeting window and the Meetings list; Copy, Email, Notes, Export.
5. Speaker separation inside the call (after the model download is approved).
6. Polish pass: timings, the reminder, the consent note, the empty and error states, the first run.
