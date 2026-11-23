# Changelog

## Unreleased

- **Mac meeting notes no longer fail when Claude can't write them.** If Claude Code hits its plan's limit (or is offline) and no key is saved, the Mac's own model writes the notes, and the page says so. A used-up plan now says plainly that the limit was reached and when it resets. The privacy page and README now say that meeting notes send the transcript text (never audio) to the AI you set up.

- **Windows: meeting notes by Gemini, or by Copilot with one paste.** Right-click the Larynx icon → Set Gemini key… and Gemini writes the summary, with the same instructions and the same check against what was said as Claude. It also takes over when Claude can't (a used-up plan, for one). Every meeting page now has **Copy for Copilot or Gemini**, which puts the meeting and the instructions on the clipboard, with buttons that open Copilot and Gemini to paste into, for workplaces that only allow their own AI.

- **Repeats said on purpose stay, and a restart around "you know" goes.** "Tries and tries and tries" and "and so on and so on" now keep every copy (one was being dropped as a stumble), while "a lot of days it's, you know, a lot of days it's fine" ends as one copy. Found by running every cleanup rule since Nov 10 over 1,004 clips of other people's speech; on those clips the rules that came from one stutterer's dictations fixed 28 and broke none.

- **Strong stutter cleanup, for people who stutter.** A new setting (Settings › Cleanup, or `stutterCleanup: strong`) also removes restarts the standard rules leave: a cut-off word said twice and never finished ("packing and cle to cle to leave" becomes "packing and to leave"), and a two- or three-word phrase said twice in a row. One word said over and over ("no no no") stays. It is off by default, because it can now and then drop a word someone meant; on the developer's 3,007 dictations it changes 2, both right.

- **Stray letters from a stumble are gone.** When a word is started and restarted, the speech model sometimes writes the start as a lone letter: "walked o over to", "maybe b as biking". The letter now goes ("walked over to", "maybe biking"); labels like "plan b" and "vitamin d" stay. The rule ran in shadow first, and all 13 of its proposals on the developer's real dictations were right.

- **"Hey Dad" gets its capital.** Dad, Mom, Grandma and the like are capitalized when you speak to them: after a greeting or thanks ("Hey Dad", "Thanks, Mom") or at the end of a sentence ("pretty quick, Dad."). "My dad" stays lowercase. 6 of the developer's real dictations change, all to the right form.

- **Windows: a first start you can see.** Starting Larynx on Windows used to show only a tray icon while it downloaded 670 MB, so it looked like nothing happened. Now a welcome window opens on Windows' own glass, with the Larynx icon: the download with a progress bar, then how to talk and a box to try it in, or what went wrong in plain words. The tray icon and a second start bring it back. Also new on Windows: Larynx's own icon and name on `larynx.exe`, a Talk key choice in the tray (Right Ctrl, Right Alt or Right Shift) for keyboards without a Right Ctrl, the Visual C++ runtime shipped beside the app so it starts on PCs without it, and a download that resumes properly if it was cut off. CI now tests the whole first start and dictating into a web page in Edge.

- **Checked on 250 clips nobody had looked at.** After tuning on DisfluencySpeech's test clips, we ran its validation clips as a fresh held-out test: Larynx needs 8.6% of words fixed (8.2% professional), against Apple's 15.7%, close to the 8.3% on the tuned clips, so the fixes carry over. `bench/disfluency.py --split validation` fetches them.

- **A comma you said is no longer dropped after "about", "with" or "for".** Larynx removes the comma a filler leaves behind ("meet at, um, the library" becomes "meet at the library"), but it also took real ones: "ask them what they argued about, without shouting" lost its comma. Now a comma before a word that starts a new phrase ("without", "and", "but", "so", "just") stays. 21 of the developer's real dictations change, each one getting back a comma that was said.

- **"You know" as a filler is gone, in every style.** "The soup was, you know, a bit cold" becomes "The soup was a bit cold". It stays where it means something ("if you know, tell me", "as you know", "you know what she said"). The professional style also drops a "Well," that starts a sentence. Checked against all 2,490 of the developer's real dictations first. On the outside test set, Larynx went from 10.9% to 8.3% of words needing a fix, and to 7.5% in the professional style.

- **Tested on a set other people made.** DisfluencySpeech is 250 clips of a human voice reading phone-call transcripts with every "uh" and restart kept in, from university researchers (`bench/disfluency.py`). Larynx needs 10.9% of words fixed, Apple's on-device speech 13.9%, and the speech model alone gets 97.1% of the words said right. Most of what's left is "you know", a leading "well", "I mean" and "oh", which the set removes and Larynx keeps for now. Details in docs/BENCHMARKS.md.

- **"No, it opens at ten" is understood as a correction.** "The store opens at nine. No, it opens at ten on Sundays" becomes "The store opens at ten on Sundays": the restart names the subject with "it", "he", "she", "they" or "we" and repeats the verb. "Ham," at the start of a sentence is read as "hmm". Neither changed any of the developer's 2,443 real dictations; on the third messy set, false starts went from 17.8% to 6.7% (not held out, since the set showed the miss).
- **A third held-out test, and false starts are much better.** Forty new messy sentences, written without rereading the rules and never used to tune them (`bench/messy3.json`): Larynx needs 7.5% of words fixed, Apple's on-device speech 24.3%. False starts, the weakest row, went from 47.6% on the last held-out set to 17.8%. Every miss is sorted in docs/BENCHMARKS.md, including the ones that only come from how the set was written.
- **A first install no longer downloads speech models in a silent Terminal.** The build's warm-up ran the speech model to get it ready, and on a Mac without one that meant downloading it (about 600 MB, with no progress shown), and then a backup model too. Now the warm-up only touches models already on the Mac; a new install gets its one model in the app, with the progress bar. Your Mac never showed it because its models were already there, and the install test skipped the warm-up; now it runs it, in an empty home.
- **A failed build says so.** The installer printed "Done" even when the build failed. Now it shows the error and where the full log is, with a link to report it. Tested with a build made to fail.
- **Plain words for the install's waits**: the developer tools take 10 to 20 minutes, the first build 5 to 10 with Terminal quiet, and after the tools install you paste the same line again.
- **Permissions macOS forgot after an update.** A build from the install line has no signing certificate, so after each update macOS treats it as a new app: System Settings still shows Larynx switched on, but it no longer works. The setup window now says what to do (remove Larynx with −, then Open Settings again), and so does the installer after an update.

## 0.7.0 (Nov 18, 2026): "Think out loud"

Cleaner text from messy speech (stutters, restarts, changes of mind), a History window, an app icon, a professional style and a texting style, and meeting notes to try: meeting mode is off by default (Settings → Meetings).

- **A one-letter stumble is cleaned up**: "bring snacks that k kids like" becomes "bring snacks that kids like". Not after a word that makes the letter a label ("plan b", "vitamin d", "the c code"), and never "a" or "I". Checked against every saved dictation on the developer's Mac: it changed 14, all real stumbles.
- **Send a Report…** (Mac menu; Windows tray menu). When something goes wrong, it saves one text file for whoever helps you: the version, the computer, its microphones, permissions, the log's timings and errors, and how long your recent meetings were. Never anything you said, a meeting's transcript or notes, the words a correction taught Larynx, your key or your user name. On the Mac it opens a Mail message with the file attached; on Windows it's saved to the Desktop. The log now keeps its newer half once it passes 5 MB.
- **Two more stutter shapes are cleaned.** A phrase restarted around a "yeah" ("we need to finish, yeah, we need to finish the deck" becomes "we need to finish the deck"), and a word sounded out in tries that the speech model wrote as real words ("the hem the ham the hammer" becomes "the hammer"). Checked against 2,038 real dictations: 2 changes, both real restarts. Emphasis ("That's fine, yeah, that's fine.") and lists with commas are kept. Mac and Windows.
- **Meeting polish from a real 25-minute test.** Holding the dictation key during a meeting no longer puts that dictation in the meeting's transcript. Meetings has a **Write the notes again** button (it also clears echoes from meetings recorded before the echo filter). Meeting mode now writes its steps to the Larynx log (started, stopped, transcript and notes timings, failures).
- **A meeting cut off by a crash or restart is finished the next time Larynx starts.** The audio was always kept as it was recorded, but the meeting never showed up. Now Larynx writes its transcript and notes and opens it in Meetings. Also: if the summary can't be written, the panel now says so instead of closing silently.
- **Meetings without headphones.** When the call plays through the speakers, the microphone hears it again and those lines used to land in the transcript as yours. Larynx now drops a line of yours when it repeats what the call was saying at that moment. A reply that reuses the call's words ("Let's stay with the standard paper then") stays. On a real 6-minute call played through speakers: 36 echoes out, nothing you said lost.
- **Notes for calls you listened to.** For a talk, webcast or earnings call, the notes now cover what was said, not your side remarks. A presenter's own plans ("we'll ship early next year") go in the summary instead of your to-dos.
- **Choose which Claude writes meeting notes** (Settings → Meetings → Claude model, `meetingClaude`): Opus (the default) or Sonnet, which is lighter on a Claude plan. Tested on four meetings, twice each: Sonnet was twice as fast but left out due dates that Opus kept. Also: the recording panel is now Liquid Glass, with a red Stop button.
- **Mute me, while a meeting records.** A button beside the level meters keeps recording the call but stops recording your microphone, for a noisy room or a call playing through the speakers. Your side is kept as silence, so the transcript's times stay lined up. Mac.
- **Meeting notes on your Claude plan.** When Claude Code is installed and signed in, Larynx has it write the notes: no API key and nothing extra to pay. It runs with no tools, no MCP servers and none of your settings, and gets only the transcript. A saved API key is the backup; with neither, the Mac's own model writes them. Mac and Windows.
- **More spoken corrections are caught**, found by a fresh held-out test set (see BENCHMARKS): a short swap after "sorry" or "I mean" ("ship it to Austin, sorry, to Dallas", "on the third, sorry, the fourth"), a one-word swap after "no wait" ("red, no wait, orange"), and a correction after a full stop ("We land at nine. No, we land at ten"). Also "Ask, ask the neighbors" at the start of a sentence, "more more", a leading "Hum," and a time written with a dot ("at 9.45" becomes "9:45"). Checked against 1,561 real dictations: 2 changes, both real corrections. "Actually" after a full stop, "Testing, testing" and other meant repeats are kept.
- **English stays in the English alphabet.** The 25-language models sometimes wrote a short word in Cyrillic (a one-word "manual" came out as "Меню"). Larynx now keeps them to your alphabet (Settings → Speech → Alphabet, `alphabet`: Latin by default, or Cyrillic, Greek, Any).
- **Restarts partway through a word are cleaned up**, the way a stutter sounds: "Could th could we" becomes "Could we", "for the conf for the conference room" becomes "for the conference room", "pr probably" becomes "probably". Checked against 1,590 real dictations: 14 changes, all restarts; chants ("bam bam bam") and real words ("in into") are kept. Also on Windows, which uses the same cleanup.
- **Texting style** (Settings → Cleanup → Style, or `style: texting`): casual, written the way people text. Sentences start lowercase and the last full stop goes ("sounds good, see you at 7"). Names, "I" and acronyms keep their capitals.
- Meeting mode (still hidden): Claude writes the notes after every meeting once a Claude key is saved in Settings → Meetings (kept in the Keychain). Only the transcript is sent, never the audio. A meeting without notes gets a "Write the summary now" button.
- **Paper Mono in the pill, if you want it** (Settings → Pill → Show my words in Paper Mono, or `pillFont`):
  the live words in the website's typeface. Off by default; the Mac's own font stays the standard. The font ships
  inside the app under the SIL Open Font License.
- **Meeting mode, in progress and hidden** (`meetingMode`, off): record a meeting from the microphone and the call's
  audio, transcribe it while it runs, tell the speakers apart and write notes (summary, decisions, to-dos with names,
  open questions) checked against the transcript. `larynx meeting` runs it from recordings; `tests/meeting.py` scores
  it on scripted meetings. Design and status: [docs/dev/MEETING.md](docs/dev/MEETING.md).
- **The AI mode cleans noise, not voice** (Colin, Nov 14): in coding agents and terminals, "you know", "I mean" and
  filler "like" now go, in casual too. Forms of address ("keep going, big dog"), swearing, "gonna" and an answering
  "Yeah," stay: they are how the speaker talks. Professional Style still does the rest. Read against every real
  dictation first: 51 of 1,055 change, all padding; the forms of address the first version dropped were the
  speaker's voice, so they were put back.
- **Fixed in the professional style**: "Like I said", "like they do in Japan", "but like it or not" and "and like
  that, it was gone" keep their "like"; removing "you know" no longer leaves a stray comma. A new test runs every
  must-not-change sentence that has a "like" through the professional style.
- **Spoken corrections, every style**: "forward it to Ellen, no, forward it to Marcus", "at nine, sorry, at ten",
  "for three, I mean four people" and "Friday, no wait, Saturday" keep only what was meant, with no AI rewrite
  needed (so in coding apps and on Macs without Apple Intelligence too). The cue ("no", "no wait", "sorry", "I mean",
  "actually", "or rather") must be followed by a restart of something said just before, or a word of the same kind;
  a plain "no," answering a question stays.
- **Any word said twice is a stutter** ("print print the passes"), except doubles that are meant ("that that",
  "really really", "not not", "knock knock") and anything said three or more times.
- **Professional drops "I mean" as a filler** with a stray word before it ("Is I mean because...") or mid-sentence
  before the thought ("It compiles, I mean the warnings are gone"). "I mean it" and "what I mean is" stay.
  All three were read against every real dictation on the author's Mac before they were turned on; each wrong
  change found that way became an exclusion.
- **Professional style, cleaner**: filler "like" goes where it cannot be a verb or a comparison ("Like most of
  them...", "but like it needs...", "in like the back row"); a swear said as an exclamation before the sentence
  ("Oh s***, the oven...") goes; "there's two files" becomes "there are two files"; a stray "yep" before "and"
  goes. Checked against every real dictation on the author's Mac first: 10 of 923 change, and the two that read
  wrong ("Like her, I...", "Like the blue one") shaped the exclusions.
- **Restarts and ranges, every style**: "we're going to be we're stuck in traffic" keeps only the restart; "10 15 minutes"
  becomes "10 to 15 minutes".
- **Days of the week are capitalized** by the cleanup rules ("friday" is "Friday"), outside the AI mode and never
  inside a path or an identifier. The speech model usually does this already; typed text through `tidy` and MCP did not.
- **Professional style**: the same voice, a cleaner register for work. Drops "you know", "I mean", "dude" and
  other forms of address, openers like "Yeah," and "Alright,", swearing used for emphasis, and spoken forms like
  "gonna", and turns a list you say ("three things: ...", "first..., second...") into a numbered list. Turn it on
  for everything (menu: Professional Style) or hold the Professional Key for one dictation; the pill shows a
  briefcase. Casual output is unchanged. `--style professional` on the command line, `"style"` in serve and MCP.

- **Credits and licences** ([packaging/CREDITS.md](packaging/CREDITS.md)): every speech model with its maker,
  licence and source, in the README and the About panel. The Bark models are non-commercial (CC BY-NC 4.0) and
  are labelled so in Settings and the menu. The app now carries the licence texts of the code compiled into it.
- **Works with your AI tools** ([docs/AGENTS.md](docs/AGENTS.md)): dictating into coding agents and terminals,
  the MCP server in one line for Claude Code (and the JSON for other clients), and the command line from the app
  itself. `tests/agents.py` runs the page's examples.
- Fixed: `LARYNX_DATA_DIR` now moves the dictionary too, so tests and scripts using a throwaway folder no longer
  write to your real dictionary. The MCP server reports the app's version and accepts the `email` mode.

- **History window** (menu: History…, ⌘Y): the last 30 days by day, with search, copy, play (when the recording is
  kept), what went where, and running totals. **Fix…** on a row (or Fix Last Dictation… in the menu) takes what you
  actually said: the fix is saved, an invented word is learned for next time under the same rules as learning from
  a repeat, and the clip joins your test set when its recording is kept.
- **An app icon**, and in the menu: Send Feedback… (a new issue with your version, macOS and speech model filled in;
  nothing you dictated is attached), Check for Updates… and About Larynx.
- **Setup shows every wait**: the speech model's download has a bar with megabytes and the time left, and the
  one-time preparation says how long it usually takes and how long it has been. Each permission says in one
  sentence why it is needed and what Larynx cannot see.
- **Uninstall** in one line (`scripts/uninstall.sh`): lists what it will remove, asks, and can keep your data.
- **Accuracy on real dictation, measured**: 0.87% of words wrong over 57 dictations picked at random
  ([docs/BENCHMARKS.md](docs/BENCHMARKS.md)).
- **Privacy, tested**: `tests/privacy.py` runs speech to text with every network connection denied.
- **Cut-off words dropped**: a word the speech model doubted, that no dictionary knows and that is only the
  start of a real word (you started one word and switched to another) is left out. History records it.
- **Fewer "like"s**: "like" is dropped where it is only a filler ("to like talk", "for like the whole day",
  "Like, does that matter?") and kept wherever it can be the verb or a comparison ("I honestly like both",
  "looks like", "it's like a", "like that"). Read against every "like" in 677 real dictations first.
- Cleanup: stutters on more words ("some some", "I'm I'm"); a phrase said three times is one stumble or a meant
  chant, never two copies; "hindsight is 20/20" is not the year.

### Windows (not in this release)

The Windows app is built and tested on every push, but nothing is published yet: these are for the coming Windows beta.

- **Windows: the meeting panel is glass**, the same recipe as Locust Glass on Windows: Windows 11's own Acrylic blurs what's behind it, under a dark tint, with a lit top edge, a soft grey rim, round corners and new buttons (Stop solid and light, Mute me glassy). Windows draws an inactive window's Acrylic as a flat colour, and the panel never takes the keyboard from your call, so it tells Windows to keep drawing its frame as active. On Windows 10, Windows 11 before 22H2 or in high contrast it's the same dark look without the blur. The pill has the panel's colours and lit edge.
- **Windows: a blocked microphone says so.** When Windows' privacy switch blocks microphones for desktop apps, the meeting panel and the pill now say where to turn it on (Settings → Privacy & security → Microphone), instead of "check it isn't muted" or "didn't hear anything". Found by the new test: GitHub's Windows machines block microphones by default. Also fixed: an "&" in the panel's text was drawn as an underline.
- **Windows: a meeting survives a lost microphone or speakers.** If a headset is unplugged, Bluetooth drops or Windows switches devices mid-meeting, Larynx opens the new ones within a second and keeps recording; the gap is silence, so the rest stays in time, and the panel says what's wrong until the device is back. Before, that side of the recording stopped until the meeting ended. The meeting panel also follows the screen's scaling now, instead of the scaling from when you signed in.
- **Windows: tested through real audio devices, in bad rooms and at high scaling.** Every build now also runs a meeting through Windows' audio stack (a virtual cable stands in for speakers and a microphone; Windows' audio service is restarted partway, which drops every app's audio at once), in a hard room with a cheap microphone and on a Bluetooth headset's microphone, and screenshots the panel at 150% and 200%.
- **Mac and Windows meeting rules come from one test file** (`tests/meeting-cases.json`). It caught one difference on its first run: Windows put two lines of the notes prompt in the other order.
- **A Windows beta channel.** One button in GitHub Actions publishes a build that passed every test as the `windows-beta` pre-release, with one link a tester can keep. Nothing is published unless it's pressed.
- **Windows: meeting mode is now tested in the real app on every build.** GitHub's Windows machine starts a meeting with the call echoing into the mic, clicks Mute me and Unmute, clicks Stop, checks the notes came through Claude Code (a stand-in) with no API key reaching it, then kills the app mid-meeting and checks the meeting is finished after the restart. That found two problems, both fixed: opening the notes page froze the app while the browser started, and the panel cut its two-line notes in half.
- **Windows: today's meeting fixes.** The echo filter (the call picked up from the speakers no longer shows as yours), notes for calls you listened to, and a **Mute me** button beside Stop. "Write the summary again" now tries Claude Code on your plan first, like the notes after Stop. Cut-off recordings were already finished when Larynx starts.
- **Windows: meeting mode.** Right-click the Larynx icon → Start recording this meeting: the microphone and the computer's sound, a big "Recording · 12:04" window with a Stop button, then notes written by Claude open as a page with Email, Copy and Print. Key in Windows Credential Manager (Set Claude key…).

## 0.6.0 (Nov 12, 2026): "Trust"

Never lose a word, never be confidently wrong, and installed with one line.

- **Pick your microphone** (Settings → Speech → Microphone, or `micDevice`): any input macOS knows, by name;
  an unplugged one falls back to the system default. `larynx mics` lists them.
- **Settings window** (menu: Settings…, ⌘,): talk keys, hands-free, pill, speech model, microphone, vocabulary,
  cleanup and stages, history and recordings, screen context, your words. Same settings.json as the menu.
- **Setup window** on a fresh install (or menu: Setup…): the three permissions with live status and buttons to the
  right System Settings pane, a microphone level test, the speech model's state, and a box to try a dictation.
- **One-line install**: `curl -fsSL https://raw.githubusercontent.com/StopBanning/larynx/main/scripts/install.sh | zsh`
  builds and opens Larynx (Apple Silicon, macOS 15+); run it again to update. A Homebrew formula that builds from
  source is in `packaging/homebrew/`.
- **Larynx reads the field you are dictating into** (memory only, never kept): at each press it collects the names
  in the text around the cursor to settle words that sound the same, like "doc" vs "Dock". Only a noun that sounds
  exactly like a name it found is considered; "make it so" never becomes "Mac". In shadow for now: suggestions are
  recorded (`larynx mine --shadow context`), your text isn't changed until they've been checked. `context: on` also
  reads the visible text of the window (off by default: walking a very long page may stall Chromium apps);
  `context: off` turns it off; `larynx context` shows what it finds without showing any text.
- Chromium and Electron apps only build their accessibility tree while something asks for it. Larynx now turns that
  back off 25 s after it last used such an app, so it adds no lasting load to them.
- Reads of another app's text field give up after 0.25 s, so a busy app can't hold up a dictation.
- When Larynx can't tell whether a paste arrived, the words also stay on the clipboard.
- **Email layout in Mail and Outlook.** "Hi Sam, thanks for… Thanks, Colin." comes out with the greeting on its own
  line, a blank line, the body, and the sign-off and name on their own lines. "Thanks for the help." stays a
  sentence (a sign-off needs a name after it).
- **"New paragraph" and "new line"** said as their own phrase make real line breaks, in every app. "A new line of
  shoes" is left alone.
- Spoken lists ("Number one, flights. Number two, hotels.") are being tried in shadow: proposals are recorded
  (`larynx mine --shadow spoken-list`), your text isn't changed yet. So are announced lists: "three things … X, Y,
  Z" with exactly three items (`counted-list`), and spoken punctuation ("…tomorrow question mark" → "…tomorrow?";
  "a period of time" stays) as `spoken-punctuation`.
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
