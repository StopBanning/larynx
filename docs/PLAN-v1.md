# Larynx: the road to 1.0 ("best in the biz")

Written Nov 11, 2026 by Fable for an executing agent (Opus). Colin's goal: "put Wispr Flow to shame and be free."
This file is the **order of work from v0.5 to v1.0 and beyond**. It replaces section 3 (order) and section 11
(status) of `docs/MASTER-PLAN.md`. The master plan stays the reference for task detail: when a task here says
"master 2.1", read that task there and apply the changes listed here. Where the two disagree, this file wins.

**Read first, every session:** `docs/HANDOFF.md` section "How to work with Colin", then master plan 1.2 (the six
invariants) and 1.3-1.4 (how to execute, shadow mode). Then the status table at the bottom of this file.

---

## 1. Where Larynx stands, seen from outside

**Already better than Wispr Flow:** price (free, no limits), privacy (nothing leaves the Mac), offline, no account,
open source, speed (0.11 s median from key-up to text), never losing a dictation (crash spool, history), a
scriptable surface (CLI, JSON lines, MCP).

**Level:** fillers and repeats, numbers as digits, hands-free, code words and acronyms.

**Behind, in the order that matters:**

1. **Nobody else can install it.** Build from source, no settings window, no onboarding, no updates. For everyone
   except Colin, Larynx does not exist yet. This is also the gap a hiring manager sees first.
2. **It can't see what you're looking at.** Names and homophones are guessed from sound alone ("reel" -> "real",
   "Opus" -> "OpenS", "Locust" -> "Logus"). The word is usually on the screen. Wispr reads it; we don't yet.
3. **It is confidently wrong sometimes.** A made-up word ("lixi" for "look-see") is pasted with no second look.
4. **Every accuracy number is from robot voices.** The benchmark is text-to-speech plus LibriSpeech. Nothing
   measures Colin's own voice, mic and music, which is the only audio that matters day to day.
5. **Long-form and formatting:** no streaming for long dictations, no spoken punctuation, lists, styles, or edits
   by voice.
6. **Mac only.** Windows is proven feasible but there is no app.

**What "best in the biz" means (the 1.0 gate):** every row of the master plan's scoreboard (section 2) is AHEAD or
LEVEL with a linked test or benchmark, a stranger can install it in two minutes, and the README can say so with
evidence. Rows that cannot be won (compliance certificates) are stated plainly.

---

## 2. How this plan is run

- **One milestone = one release.** Each has a headline a user can feel, tasks in order, and a gate. Do not start
  the next milestone until the gate passes or the failing item is written into the status table with evidence.
- **Start of every session:** read the last day of real dictations (`larynx history --json`, or `larynx review`
  once B8 exists). Colin's messages to you are dictated through Larynx: check each one too. A slip that a safe rule
  can fix gets fixed now, with tests; anything else goes under the task that will fix it.
- **Every automatic text change:** change cases and at least as many must-not-change cases in `tests/cases.json`,
  then replay it over every raw transcript in history and read each line it would change, then the full suite.
  From milestone B on, the golden set (B3) must not get worse either.
- **Decide by data.** Where a task gives a rule ("keep it only if..."), run the measurement, write the numbers into
  `docs/BENCHMARKS.md`, apply the rule. Spikes are time-boxed to one working session and end in go or no-go.
- **Speed is a feature.** Invariant 2 holds for every release: key-up to text p50 <= 150 ms, p90 <= 350 ms for
  dictations under 60 s. Real use on Nov 11: p50 109 ms, p90 266 ms. Anything slower has a deadline and a fallback.
- **Tracks that can run in parallel sessions** (they touch different files): the Windows track (section W) and the
  public-face task D7. Everything else runs in order in one session.
- **Baselines at the start of this plan (commit of this file):** text rules 59/59, rewrite 26/26, spoken cleanup
  272/300 with Parakeet Ultra (264 with Bark Clean), 38 Swift tests, speech table in docs/BENCHMARKS.md.

---

## A. v0.5.0 "Ultra": the new model, landed safely

Headline: about 37% fewer wrong words, names right twice as often, 25 languages.
Done on Nov 11: default engine is `ultra`, menu entry, docs, changelog, installed.

**A1. Watch Ultra in real use.** Ultra types what it hears, so ums, repeats and false starts are now the tidy
rules' job. For the first 200 real dictations, read every raw -> text pair. Each leftover (a filler spelling the
rules miss, a repeat, a false start, odd capitals) becomes a rule case plus a must-not-change case.
Rollback rule: if words are lost, or p90 goes over 350 ms across 100 dictations, set `"engine": "clean"` in his
settings.json, restart with `restart-app.sh`, and write down why.
**Real-voice check (audio is kept since Nov 11):** once 200 recordings exist, run every one through `ultra`,
`clean`, `unified` and `parakeet` (`larynx transcribe <file> --engine <e>`) and list each clip where Ultra differs
from what the other three agree on. First sample, Nov 11: "compact to pass off to Opus" came out of Ultra as
"Compaq to pass off Robus" while the other three wrote "Compact ... for Opus". If Ultra is the odd one out more
often than Bark Clean is, switch the default back to `clean` and bring B4's consensus pass forward: it would have
caught this one.
Done when: 200 dictations read, the four-engine comparison is in BENCHMARKS.md (counts only), findings fixed or
filed, and the default is whichever engine his own voice supports.

**A2. Close Ultra's cleanup gaps.** Suite misses today: false starts 10/20, self-corrections 29/40, repeats 55/60,
trailing off 8/10 (see `bench/results/suite2-ultra.log`). Rules only, no model. Done when: spoken >= 280/300 with
Ultra, rules and must-not-change at 100%, and the history replay changes nothing wrongly.

**A3. Stop removing commas that were right.** Tidy step 3 strips the comma after any small word
(`Tidy.joiners`). It turned "come in, whip up a plan" into "come in whip up a plan"; it also breaks "Log in, then
click save" and "Hold on, I'll check". In history, 8 raw transcripts hit this rule and 4 of them are "in,".
New rule: words that can never end a clause (the, a, an, my, your, our, their) always lose the comma.
Prepositions and "is/was/are/were/be" lose it only when the next word is a determiner, possessive, number or
capitalized name ("meet on, Thursday", "send it to, the team"). and/but/or keep today's behavior.
Done when: those three sentences are must-not-change cases, "meet on, Thursday" still passes, and the replay over
history has zero wrong changes.

**A4. End a dictation properly.** 2 of 145 dictations ended in a comma ("...the best in the biz,"). A final comma
or semicolon becomes the mode's normal ending. Done when: cases added, replay clean.

**A5. Numbers no longer wake the AI rewrite.** Remove `numberCues` from `Cleaner.reason` and rule 3 from the
rewrite instructions (the numbers stage does this in 0 ms; the rewrite costs 1.6 s in Mail and Messages).
Done when: the rewrite benchmark, run through the full pipeline, still scores 26/26.

**A6. Changing models never stops dictation.** Measured Nov 11: the first load of a model the app has never run
takes 95 s while the Neural Engine compiles it (0.4 s afterwards). The compile cache is per bundle id.
- `make-app.sh`: after installing, load the configured engine once with the app's own binary
  (`Larynx.app/Contents/MacOS/larynx transcribe tests/fixtures/report.wav`) so the cache is warm before restart.
- In the app: when the menu picks a model that is not compiled yet, keep dictating with the current one, compile
  the new one in the background ("Preparing the new speech model, one time"), then switch.
Done when: picking an uncompiled model in a `--feed` test never leaves more than 5 s without a working engine.

**A7. Release v0.5.0.** CHANGELOG, version in `make-app.sh`, tag, GitHub release notes (never the signed binary).
README first screen: a 10-second GIF of the pill recorded with `larynx pill-demo`, three numbers (0.1 s, 0 bytes
sent, $0), and the scoreboard rows that flipped (numbers, hands-free, history).

Gate: A1-A7 done; suite >= 280/300; latency inside invariant 2 over the 200 watched dictations.

---

## B. v0.6 "Trust": measure real speech, never be confidently wrong

Headline: Larynx notices when it probably misheard and fixes it, and stops clipping words. Under the hood, this
milestone builds the instruments every later milestone is judged by.

**B1. Shadow mode** (master 0.7). Stages set to `shadow` record would-be changes in History;
`larynx mine --shadow <stage>` lists them.

**B2. Live test rig** (master 0.9 without the head-to-head part): `larynx capture-window`, `scripts/when-idle.sh`,
and `tests/live.py` that drives `listen --feed` into the capture window only. This is the only place tests paste.

**B3. The golden set: Colin's real voice as the benchmark.** Q2 answered yes on Nov 11: `keepAudio` is `30` in
his settings and audio is kept as 16-bit FLAC in `history/audio/` (password fields and private apps never).
- `larynx golden add <id> [--text "what was said"]` copies that dictation's audio and the correct
  text into `~/Library/Application Support/Larynx/golden/` (never in git, never uploaded).
- Candidates are offered automatically: dictations he repeated or edited (the fix is the reference), rows flagged
  doubtful (B4), and any the agent can verify from the conversation. Nothing is added without a reference text.
- `python3 bench/run.py --set golden` reports WER, names and latency per engine.
- New standing gate: no engine, vocabulary or rule change may raise golden WER.
Done when: 100 clips with references, a baseline row in BENCHMARKS.md (numbers only, no text).
If Q2 is "no": build the same thing from TTS re-creations of his known misses and say plainly it is weaker.

**B4. Second opinion on doubtful results** (master 1.3, widened).
- Doubtful = a word that is in neither the word list nor the vocabulary and is not a capitalized name ("lixi"),
  runs of ALL-CAPS, low `ASRResult.confidence` (threshold calibrated on the bench as in master 1.3).
- Then: decode again with a second engine (Parakeet Unified first, Bark Clean second; deadline 300 ms). Take the
  second result only if it is not doubtful. Both doubtful: deliver the first, flag the row, pill says
  "Not sure I heard that" for 2 s.
- Consensus spike (one session): run Ultra and Unified on every dictation and merge word by word, preferring words
  that are in the vocabulary or screen context, else the higher-confidence one. Keep it only if WER on
  jargon + noise + golden drops by 10% relative, p90 stays inside invariant 2, and memory stays under 1.5 GB.
- Big-model spike (one session): the same doubtful rows through FluidAudio's largest local model (master 13,
  LFM3Audio) as a third opinion. Keep only if it fixes at least a third of them inside 1 s.
Done when: unit tests cover each trigger, "lixi"-class clips recover, results in BENCHMARKS.md.

**B5. No clipped first or last word** (master 1.2). Done when 0 of 50 clips lose a word.

**B6. Insertion that cannot silently fail** (master 4.6): verify the paste where the field is readable, type as a
fallback, transient clipboard marking, "scratch that" undo.

**B7. Prove learning from edits fires.** Count in the log (no text): fields watched, fields readable, lessons
learned. After 3 days, if it has never fired on a readable field, reproduce in the capture window and fix.

**B8. `larynx review`.** One command for the daily read: yesterday's doubtful rows, repeats, shadow diffs, lessons
learned, latency p50/p90 per engine, stage counts. Prints counts by default, text only with `--text`.

**B9. Latency gate.** `bench/latency.py`: 50 clips through `listen --feed`, p50/p90 written to `bench/results/`.
Run before every release; a release that breaks invariant 2 does not ship.

Gate: golden baseline exists; B4 recovers the made-up-word cases; 0/50 clipped; live rig green; latency gate green.

---

## C. v0.7 "Context": it knows what you're looking at

Headline: names and look-alike words come out right because Larynx reads them off the screen, locally.
This is the largest accuracy win left, and the one feature where Wispr sends your screen to a server and we don't.

**C1. Gather context** (master 2.1), cheapest and safest source first:
1. The last 30 minutes of dictations into the same app (memory only). No screen reading needed.
2. Text before and after the cursor in the focused field.
3. Visible text of the focused window (bounded walk).
Measure first in Claude desktop, where 98% of his dictation goes: Electron accessibility trees can be huge.
Budget 150 ms on a background task started at key-down; recording start must not move (<= 5 ms difference in the
latency gate). Late context is dropped, never waited for. Privacy rules as master 2.1.

**C2. Names from the screen into the vocabulary** (master 2.2), per dictation.

**C3. Look-alike words by context.** A small table of sound-alike pairs where one side is a topic word
(reel/real, cache/cash, Rust/rust, and pairs mined from his history). Swap to the rarer spelling only when all
hold: that exact word is in the context or his vocabulary; the heard word sits where a noun fits (after a
determiner, adjective, possessive or number; not before another noun, so "the real reason" stays); the stage has
been through shadow with every would-be change read. Replaces the phrase entries in his dictionary.

**C4. Fit what's already in the field** (master 2.3): capital or lowercase first letter and leading space from the
text before the cursor.

**C5. Profiles per app and site** (master 2.5), `apps.json`.

**C6. File names by voice** (master 2.4). Last; skip to D if C1-C5 took longer than planned and note it.

**C7. His misses as tests.** "OpenS" -> Opus, "Russ" -> Rust, "Logus" -> Locust, reel, "lixi": golden audio where
it exists, otherwise TTS plus a context paragraph, in a `context` bench set.

Gate: context-names >= 90% (also record the number without context); every C7 case passes; golden WER not worse;
a test proves context never reaches disk (put a sentinel word on screen in the capture window, run fed dictations,
grep history.sqlite and the log for it).

---

## D. v0.8 "For everyone": installed in two minutes

Headline: install with one command, grant three permissions, talk. Q1 is "not yet" (Nov 11), so D5 ships the
no-cost path first; the signed download comes when he says the traction is there.

**D1. Settings window** (master 6.1), SwiftUI, same glass as the pill. The menu keeps quick toggles.
**D2. First run** (master 6.2): permissions with live status, mic test, model download with progress and resume,
pick the talk key, a try-it box. The 95 s first compile (A6) gets a progress screen here.
**D3. History window** (master 6.3): search, copy, paste again, play audio when kept, "this is wrong" (teaches the
dictionary and adds to the golden set), stats computed locally.
**D4. Dictionary, vocabulary and snippets editors** (master 6.5, the table editors and import only).
**D5. Distribution** (master 6.7). With Q1 = yes: Developer ID, notarized DMG, Sparkle updates, Homebrew cask, all
from a GitHub Actions release workflow. Colin does the signing-identity steps himself (the executor never changes
it): write him the exact steps. Switching identity makes macOS ask for the three permissions once more: tell him
before, not after. With Q1 = no: `scripts/install.sh` plus a Homebrew tap that builds from source.
**D6. Privacy proof** (master 6.9): a test that fails if the app opens a socket; runs in CI; linked from README.
**D7. Public face** (parallel track): README first screen, comparison table with a link to evidence per row,
`docs/APPS.md`, an architecture page with one diagram, a GitHub Pages site built from the same files.
**D8. Accessibility of the app itself** (master 6.8).

Gate: on a clean macOS user account, download to first dictation in under 2 minutes not counting the model
download; the release workflow produces the artifact from a tag; the privacy test is green in CI.

---

## E. v0.9 "Flow": long-form, formatting, edits by voice

**E1. Streaming while you speak** (master 4.2). Spike first: FluidAudio's `StreamingUnifiedAsrManager` against
"cut at pauses and batch each piece with Ultra". Pick by WER on the `long` set and on golden.
Done when: a 30-minute dictation lands under 500 ms after key-up, WER within 0.2 points of one-shot.
**E2. Hands-free, finished** (master 4.1 remainder): optional auto-finish on silence, "Undo cancel" after Esc.
**E3. Spoken punctuation and lists** (master 3.1), shadow first.
**E4. Styles** (master 3.2): formal, casual, very casual, verbatim, AI. Per profile (C5).
**E5. One Polisher, several engines** (master 3.3): rules, Apple's model, a local MLX model chosen by
`larynx polish-bench`, or the user's own endpoint (off by default, labelled).
**E6. Self-correction for any phrase, fast** (master 1.5 + 3.4): rewrite only the sentence with the cue, 600 ms
deadline, tidy result delivered if the model is late.
**E7. Command Mode** (master 3.5): select text, say what to do with it.
**E8. Microphones, noise, shortcuts** (master 4.3, 4.4, 4.5).

Gate: polish-bench >= 95/100 rewrite and >= 54/60 command cases; formatting clean after its shadow period; the
30-minute test passes; latency gate green with every new stage on.

---

## F. v1.0 "Indisputable": proof

**F1. Languages.** Measure the 25 that Ultra covers on FLEURS (master 5.4) and add filler lists for the 12 most
spoken (master 5.3). Then the engine registry for 100+ (master 5.1-5.2).
**F2. Head to head** (master 0.9 rig; decision Q4). If declined: our numbers on public data next to their
published claims, worded as exactly that.
**F3. The open dictation benchmark** (master 9.8): `larynx bench` plus the rig, reproducible by anyone, including
the rows we lose.
**F4. Sync and sharing without a server** (master 6.5 shared sets, 6.6 `dataFolder`), scratchpad (master 6.4).
**F5. The scoreboard gate.** Every row 1-29 AHEAD or LEVEL with a link. README makes the claim. Draft the launch
post for Colin; he decides when and where it goes out.

---

## G. After 1.0: what a cloud product cannot do

In this order unless Colin picks otherwise (Q5). G1 and G3 do not depend on later milestones and can be pulled
forward whenever he wants a showpiece.

- **G1. Voice to agents, both ways** (master 9.1). He spends his day talking to Claude; make Larynx the voice
  layer: agents can ask a question out loud and get a spoken answer back as text.
- **G2. Only listens to you** (master 9.2).
- **G3. Fix last by cycling** (master 9.5): one shortcut swaps the last dictation for the other engine's version.
  Nearly free once B4 exists.
- **G4. Pipeline hooks** (master 9.7). **G5. Voice actions** (master 9.3).
- **G6. A model that adapts to you** (master 9.4), trained on the golden set, on this Mac.
- **G7. Phone as a wireless mic** (master 9.6). Meeting notes (master phase 7) and iPhone (master 8.2) after that.

---

## W. Windows (the Rust engine): its own track

Follow `docs/WINDOWS.md` steps W1-W7, in a worktree under `~/work/locust-wt/larynx-windows`, code in `windows/` in
this repo, tested by `.github/workflows` on Windows runners. Three calls that file left open:

- **One text core.** W1 runs `LarynxText` as a small Swift `larynx-text.exe` that speaks JSON lines: no rule is
  ever written twice, and CI already builds it. Port the rules to Rust only if the Swift pieces add more than
  60 MB to the installer or 300 ms to a cold start; in that case the Mac app moves to the Rust core too, so there is
  still exactly one implementation, checked by `tests/cases.json`.
- **Shell.** At W4, spend one session trying Tauri 2 (Rust + WebView2, about a tenth of Electron's size) with the
  locust-glass styles. Use it if the pill's three-state screenshot test passes on the Windows 11 runner and the
  window is click-through and never takes focus. Otherwise Electron as planned.
- **Speech.** Check whether Parakeet Ultra has an ONNX export for sherpa-onnx; use it if so, else v3. On CPU the
  model is several times slower than the Mac, so W2 includes transcribing during recording (same design as E1).

W7 (real-hardware numbers) needs decision Q3. Everything before it runs in CI.

---

## Decisions for Colin

| # | Decision | Recommendation | Why |
|---|---|---|---|
| Q1 | Apple Developer Program, $99/year (master C1) | **Answered Nov 11: not yet.** He will pay once Larynx has traction. Until then D5 takes the no-cost path (install script + Homebrew tap that builds from source). Ask again when people are installing it. | The only way strangers get a download that opens, keeps its permissions across updates and updates itself. Also required for an iPhone app later. He re-grants three permissions once. |
| Q2 | Keep audio of his own dictations for 30 days, on this Mac only (master C2) | **Answered Nov 11: yes** | Turns his real voice into the benchmark (B3). Without it every number is from robot voices. |
| Q3 | A real Windows machine for the final Windows tests | The old PC's C: drive, when W6 is reached | CI covers everything earlier. |
| Q4 | Sign in to Wispr Flow for a measured head-to-head (master C3) | Decide at F2 | Not needed before then. |
| Q5 | Which "beyond" features first | G1, G2, G3 | G1 fits how he works; G3 is nearly free. |

None of these block A or B except Q2 for B3 (which has a weaker fallback).

---

## Status (the executor keeps this current)

| Task | State | Notes / evidence |
|---|---|---|
| A (switch to Ultra) | done Nov 11 (v0.5.0 released; A1 watch continues to 200 dictations) | Ultra 272/300 vs Bark Clean 264/300 after the new tidy rules; default changed, installed, cache warmed. `bench/results/suite2-*.log`, docs/BENCHMARKS.md. |
| A1 | started | Watch began with the first dictation after the Nov 11 restart. Finding 1: "when we uh w when we want" left "w when we" behind; fixed with the cut-off-restart rule (Tidy step 1e), replayed over 149 real dictations: 1 change, correct. 41 Ultra dictations by Nov 11 02:47: key-up to text p50 101 ms, p90 154 ms (inside invariant 2), no lost words. |
| A1 real-voice check | tool ready | `python3 bench/realvoice.py [--show]`. First run, 25 recordings (111 s): Ultra odd one out 0 times, Bark Clean 1, Unified 2, Parakeet 0; all four agree on 10/25. Rerun at 200. |
| A2 | done | Suite with Ultra 272 -> **281/300** (`bench/results/suite4-ultra.log`): false starts 10/10, fillers 75/80, text 71/71, rewrite 26/26. New rules: no-comma false start after a determiner ("I went to the I drove", restart verb required), ", are," after is/was, "a the", leading "Ah," when hesitating, a phrase restarted after a filler ("from your uh from our", from his real dictation). Replay: 1 of 194 changes (correct). Left: 9 misses are the speech model (hummus, uh-huh, Mateo); "you eh" for "yeah"; "uh" heard as "I" (Rishi). |
| A3 | done | On/in keep their comma unless a determiner, number or capitalized name follows; be-verbs keep it before a new clause's subject. 10 must-not-change cases. Replay (`tests/replay.py`) over 188 real dictations: 5 changes, all right (commas back in "come in, whip up", "looking in, write up", "Take it all in, brother", "if we are, it's"; trailing commas gone). |
| A4 | done | Final comma/semicolon becomes the mode's ending (period; nothing in AI apps, as step 2e). |
| A5 | done | `numberCues` and rule 3 gone; `larynx rewrite` and the rewrite's output now go through the numbers stage. Rewrite benchmark through tidy -> numbers -> rewrite: 26/26 (two expectations changed to house style: "eight chairs", "three pizzas"). Numbers learned "to eleven fifteen" -> 11:15 (quarter/half hours only); numbers replay over 98 dictations: 0 changes. |
| A6 | done (menu path not tried live) | `make-app.sh` warms the configured model with the app binary (73 s on the first install after this change, 1 s on the next: some rebuilds invalidate the cache, so it runs every time). Menu pick loads the new model in a background Transcriber, keeps dictating on the old one, saves and restarts after 3 s with no recording. |
| A7 | done Nov 11 | v0.5.0 tagged and released (notes from CHANGELOG, no binary). README first screen: pill GIF from `pill-demo`, the three numbers, scoreboard rows for numbers, hands-free, history. Suite with rewrite on (`bench/results/suite5-ultra-rewrite.log`): 281/300; self-corrections 29/40 with Ultra vs 38/40 with Bark Clean, a gap for E6. |
| B1 | done | Stage shadow was already wired; added `larynx mine --shadow [stage]`, shadow rules (`Tidy.shadowRules`, recorded as `shadow:<name>` steps, never applied) and `larynx tidy --shadow`. First shadow rule `lone-letter`: 1 proposal over 216 real dictations, correct ("who f will actually"). **Rule for every risky new rule from now on: shadow first, promote after its proposals on real dictations are read.** |
| B4 | done | Per-word confidence from the model (`transcribe --words`), `Doubt` (under 0.4, or under 0.8 for an unknown lowercase word), history flag `doubtful`, pill hint (`doubtHint`), doubtful rows in `golden candidates`. Calibration and the second-opinion simulation in BENCHMARKS.md: swapping in Unified or Bark Clean where Ultra is unsure changes WER by under ±0.3 points on golden/jargon/noise: **no-go** (bar was -10%), consensus spike closed with it. Big-model spike: LFM3-Audio-2B run on golden + jargon + noise: worse than Ultra on every set (golden 4.30 vs 1.63, jargon 10.28 vs 8.78, noise5 24.40 vs 16.02), p90 up to 1.3 s; fixed "Compaq" and "clod" but none of the doubtful rows: **no-go** (BENCHMARKS.md). "lixi" can't be recovered: no recording, and the spell checker knows the word. |
| B2 | built; live run pending | `larynx capture-window`, `listen --feed --deliver` (only into a running larynx capture window, LARYNX_CAPTURE_PID; refuses other pids, checked with Finder; restores the full clipboard, checked), `scripts/when-idle.sh` (idle 5 min + unlocked + not recording; kills on input), `tests/live.py` (wraps the build as a throwaway ad-hoc-signed test app so macOS brings it to the front). Not yet run end to end: the screen was locked, and a locked session won't bring windows forward. Run `scripts/when-idle.sh python3 tests/live.py` when the screen is unlocked and nobody is typing. |
| B5 | tail done; onset measuring | Kept recordings: speech in the first 50 ms in 1 of 47 (start maybe clipped), in the last 50 ms in 1 of 47. Smart tail instead of a fixed 250 ms (which would break invariant 2): keep recording only while the last 100 ms is still speech, up to 300 ms; would run on 1 of 53 real recordings (the clipped one). Hand-over when a new press comes during the tail. `recording... mic N ms` now logged: if p90 > 80 ms over a day, start the engine earlier (master 1.2). |
| B5 onset | done | Real presses logged mic start 169 and 252 ms (bench harness: first audio 230-290 ms cold). Warm microphone (`micWarm`, 30 s, 0.15 s pre-roll ring, nothing kept): warm presses start in 0 ms with 0.15 s of pre-roll (harness on the real Recorder). Cold first press unchanged. |
| B6 | built; live run pending | Paste verification where AXValue is readable (unchanged after 0.6 s = failed; changed or unreadable = left alone, never doubled), then AX selected-text insert, then Unicode typing, then clipboard + pill. Transient + auto-generated pasteboard types on paste writes (unit test on a private pasteboard). "Scratch that"/"undo that"/"delete that" alone within 30 s in the same app → ⌘Z, row flagged `undone`; menu Undo Last Dictation. `verifyPaste` setting. Live capture-window cases (verified paste; dropped paste → fallback once) in tests/live.py, queued under when-idle. Not done: per-app insertion method learned in apps.json. |
| B7 | done | Learning has fired 3 times in the log (lessons from edits/repeats). New `edit watch:` log lines (no text) count every outcome: field not readable, dictation not found, no word fixed, N words fixed; `larynx review` totals them. |
| B8 | done | `larynx review [--hours 24] [--text]`: speed per engine against the 150/350 budget, deliveries, stages that changed text, doubtful / undone / fixed / said-again counts, shadow proposals, mic start and tails and edit watches from the log. First run: Ultra p50 106 ms, p90 160 ms over 75. |
| B9 | done | `bench/latency.py`: 50 clips (jargon, noise10, ls-other) through `serve` with the full pipeline in AI mode; exits 1 over budget. First run: Ultra p50 66 ms, p90 87 ms, max 115 ms: PASS. Run before every release (A7-style checklist). |
| B3 | started: 48 of 100 clips | `larynx golden` (add/list/remove/candidates), corrections table (edits and repeats recorded live), `bench/run.py --sets golden` (full pipeline, numbers only). 48 clips from the first 53 recordings, references checked by the agent (5 left out as unsure), so biased toward Ultra: Ultra 0.58% WER, Unified/Parakeet 2.67%, Bark Clean 3.48% (docs/BENCHMARKS.md). Next: `larynx golden candidates --apply` as edits and repeats come in; agent-check new recordings each session; standing gate from now: no change may raise Ultra's golden WER. |
| C4 | done (done early, as planned) | `Fit.adjust` (LarynxText) from the text before the cursor (AXValue + AXSelectedTextRange): missing space after the previous text, lowercase first word mid-sentence when it is an ordinary English word (not I, acronyms, camelCase, vocabulary terms, names), capitals kept after an opening bracket/quote, nothing for empty/newline/selection/unreadable. `fitToField` setting. Unit tests; live capture-window cases ("Okay." + text, "Hey Sam," + text) in tests/live.py. Fixes the "time.Are we" slips. |
| C1-C3, C5-C7 | not started | |
| D1-D8 | not started | D5: no-cost path (Q1 = not yet) |
| E1-E8 | not started | |
| F1-F5 | not started | |
| G | not chosen | Q5 |
| W1-W7 | not started | W0 done (docs/WINDOWS.md) |

Slips seen in real dictation, filed under the task that fixes them:
- "come in, whip up" lost its comma -> A3. Dictation ending in a comma -> A4.
- "lixi" for "look-see" (made-up word pasted without a second look) -> B4.
- "come in" for "come on", "make us, the best" (stray comma from the model) -> watch under A1 with Ultra; if they
  persist, B4's consensus pass and E3.
- "reel" as "real", "OpenS", "Russ", "Logus" -> C2, C3, C7.
- Ultra only: "Compaq" for compact, "Robus" for "to Opus" (dictionary entries added for him) -> A1 real-voice check,
  B4 consensus. "Two opus" for "To Opus" in a 1.4 s clip: every engine wrote it; needs context -> C1.
- Several short dictations into one field run together with no space ("time.Are we") -> C4; do it early.
