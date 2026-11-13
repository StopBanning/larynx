# Larynx launch plan: from one user to many

Written Nov 13, 2026 (Fable plans, Opus executes, Colin decides the rows marked **Colin**). This sits beside
[PLAN-v1.md](PLAN-v1.md): that file makes Larynx better, this one gets it into other people's hands. Section 6 says
how the two interleave. The standing rules in PLAN-v1 section 2 apply here unchanged.

## 1. The honest picture

**Where it stands.** Larynx works well for one person. On Nov 13 the repo had 1 star and 4 page views, and nobody
outside this Mac has installed it. The work so far went into the product; none has gone into being found.

**The field is crowded.** Free, offline, open-source Mac dictation already exists several times over: Handy (MIT,
Mac/Windows/Linux), FluidVoice and VoiceInk (GPL), OpenWhispr and more, some with over ten thousand stars (figures
from third-party listings, Nov 2026; task L0.5 checks them). The paid cloud leader costs about $144 a year with a
weekly word limit on its free tier. So "free, private, open source" is the entry ticket. It is not a reason to
pick Larynx over the others.

**What Larynx has that it can prove today:**

| Edge | Evidence that exists now |
| --- | --- |
| Text you don't have to fix: fillers, stutters, false starts, self-corrections and numbers cleaned by rules, instantly, with no language model in the way | `tests/cases.json`, 0.87% words wrong on 57 random real dictations (BENCHMARKS) |
| It shows its work: every claim has a test anyone can run | `tests/privacy.py` (speech to text with the network denied), `bench/latency.py`, `tests/install.py` |
| It never loses a dictation | Checked paste with three fallbacks, crash spool, history (`tests/live.py`) |
| Free with nothing held back | MIT, no account, no paid tier, no limits |
| Built for people who talk to AI all day | CLI, JSON lines, MCP server |

**The line:** *Think out loud. Larynx writes it down.* Under it, the proof: *text you don't have to fix; free,
private, and it can prove it.*

**The feel** (Colin, Nov 13): less like dictating, more like thinking out loud. Nobody thinks in finished
sentences, so the product's job is to let you talk the way you think (pauses, restarts, changing your mind) and
hand back what you meant. That is what the cleanup edge is for, and it is a light steer, not a redesign: when a
choice comes up, prefer the one that asks the speaker to do less (no spoken punctuation needed, no commands to
remember, nothing to go back and fix). Demos show someone thinking aloud, never someone reciting.

**Two audiences, two doors.**

- **Coders** can install today (one Terminal line). They are persuaded by evidence: a benchmark that includes the
  rows we lose, a privacy test, readable code. They are reached on GitHub, Hacker News and Reddit.
- **Everyone else** cannot install today. They need a download button, an icon, a window they can look at, and
  updates that happen by themselves. They are persuaded by a 15-second video. They are reached on Instagram, and
  they are holding a phone when they see it, while the app is for a Mac.

That gives the order: **L0** make it presentable, **L1** launch to coders (free, soon), **L2** open the door for
everyone (needs the one paid item, decision LQ1), **L3** Instagram, **L4** keep the loop turning.

## 2. Rules for all of it

- Every public claim links to a test or a measured number. If it can't be measured, it isn't said.
- No ad spend. The only money in this plan is Apple's $99 a year (LQ1).
- Colin posts, or approves, every post, listing and account. The executor drafts. No fake accounts, no asking
  people to upvote, no bought stars or followers.
- Drafts of posts and reel scripts live in `~/work/larynx-launch/` (not in this repo) until they are published.
- His dictation never appears in a demo. Demo sentences are written for the demo and recorded in a clean macOS
  user account or the capture window, so nothing private is on screen.
- Other products: facts with a source and a date, behaviour only, never their code. GPL apps: ideas only.
- Nothing is launched on a claim that failed its own test. If L0.5 shows Larynx losing a row, the row is published
  and the message changes.

## 3. Decisions for Colin

| # | Decision | Recommendation | Why |
| --- | --- | --- | --- |
| LQ1 | Apple Developer Program, $99 a year (PLAN-v1 Q1, answered "not yet" on Nov 11) | **Pay it when L1 is posted**, so the download exists before the Instagram reels do. Ask Apple for the free D-U-N-S number for the company now: enrolling as the company puts its name on the app instead of a personal name, and the number can take days to weeks. | Without it there is no one-click install. Homebrew stopped carrying apps that fail Apple's Gatekeeper check (Sept 2026), so the free route for non-coders is gone. Every Instagram viewer who isn't a coder hits a Terminal window and leaves. |
| LQ2 | Move the repo to a GitHub organization named for the project (`larynx-app` was unclaimed on Nov 13) | **Yes, before L1.** Free, ten minutes, old links redirect. | Links in posts last forever; the address is part of the first impression. |
| LQ3 | The name | **Keep "Larynx".** Say "Larynx dictation" in titles. | The only clash found is an archived text-to-speech project and its Python package. |
| LQ4 | Which Instagram account posts the reels | **The existing one, as a series**, unless that account is promised to one look or project. | A new account starts at zero reach. |
| LQ5 | Three outside testers: people with an Apple Silicon Mac, one coder and two who aren't | **Yes, during L0.** | Watching one stranger install teaches more than another week of rules. It is also what PLAN-v1 R8 still needs. |
| LQ6 | About 15 minutes recording demo sentences in his own voice (L0.2), and a little more per reel | **Yes.** It is a voice product; a synthetic voice in the demo would undercut it. | |
| LQ7 | Signing in to the paid cloud app for a measured head-to-head (PLAN-v1 Q4) | **Not for launch.** Compare with the dictation built into the Mac and with the free open-source apps. | Everyone already has the built-in one, so it is the comparison an average person understands. |

Nothing in L0 waits on LQ1. L0.6 and the links in L1 wait on LQ2.

## L0. Ready to be seen (no spend)

**L0.1 App icon.** There is none: the bundle's Info.plist names no icon file. Design one in the pill's glass style
(a waveform reads at 16 px), as an `.icns` in the bundle, a favicon and the repo's social preview image.
Done when: Finder, the Dock while Settings is open, the setup window, the README and a link pasted into a chat all
show it.

**L0.2 The 20-second demo, with his real voice.** One written thought, said the way people think out loud, that
shows everything in one breath: a filler, a stutter, a false start, a change of mind, a number, a name from the
dictionary. Screen plus sound, captions burned in
(most people watch muted, so the text appearing on screen is the demo). Cuts: the full 20 s for the landing page
and README, a 6 s loop as the GIF, a vertical version as the first reel.
Done when: someone who has never heard of Larynx can say what it does after one muted viewing.

**L0.3 README for strangers.** First screen: the line, the demo, three numbers, install. Second screen: "Why
Larynx when others exist?" as an honest table (from L0.5, with the rows we lose). Move build internals (word-list
notices, pipeline notes) into `docs/`. Until PLAN-v1 F1 measures them, say "English is the measured language; 24
more run but are not measured yet" instead of "25 languages". Add **Uninstall**: one command that removes the app,
its data, models and settings. Being easy to remove is part of being trusted.

**L0.4 A repo people can join.** `CONTRIBUTING.md` (build, test, and how a cleanup rule gets added: the failing
case goes into `tests/cases.json` first), `SECURITY.md`, Discussions on, five real "good first issue" issues (for
example filler-word lists for another language), a short public `ROADMAP.md`, and the internal working files
(`HANDOFF.md`, `PLAN-next.md`, `MASTER-PLAN.md`) moved under `docs/dev/`.

**L0.5 Compare with what people actually use.** One bounded session to find out what can be measured fairly:

1. The Mac's own on-device speech API on the same audio files as our sets (no extra software; label it exactly as
   that, since it is not the same as the keyboard's dictation button).
2. A new public set, `messy`: 40 written sentences with fillers, stutters, false starts and spoken numbers, in
   synthetic voices, scored on **edits needed** (words a person would still have to fix) as well as word errors.
   This is the number that carries the line in section 1.
3. The free open-source apps: only if the same audio can be fed to them without installing a system audio driver.
   If not, publish a feature table with sources and dates, and leave app-against-app to PLAN-v1 F2.

Downloading another app to test needs Colin's OK first (name, source, size), as always.
Done when: `docs/BENCHMARKS.md` has the table, the script reproduces it, and the rows we lose are in it.

**L0.6 Homebrew tap for coders** (after LQ2). A `homebrew-larynx` repo whose formula builds from source, so
`brew install larynx-app/larynx/larynx` works. Homebrew's main cask list has a popularity bar and needs a signed
app, so that comes in L2. Done when: CI installs from the tap on a clean runner.

**L0.7 The first five minutes.** Today: a few minutes of building, a 600 MB model download, then one to three
minutes while the model compiles for the Neural Engine, then three permissions. Every one of those is a place to
give up. Each wait gets a progress bar with plain words and time remaining; each permission gets one sentence on
why it is needed and what Larynx cannot see, with a link to the privacy proof. Then the three testers (LQ5)
install with nobody helping; each stumble becomes an issue.
Done when: all three reach a first dictation without asking a question.

**L0.8 History window** (PLAN-v1 R5, moved first). A dictation app with nothing to look at feels like nothing is
there. Search, copy, paste again, play the audio when kept, "this was wrong".

**L0.9 Small things a stranger expects.** Menu: **Send Feedback…** (opens a GitHub issue with the version and
macOS filled in, never any dictated text), **Check for Updates…** (opens the releases page until L2.2), and an
About panel with the version, the licences and the model credits.

**L0.10 Landing page** on GitHub Pages, one screen: the line, the demo, the install button, three proofs each
linking to its test, and a short FAQ (Is it really free? Why does it need Accessibility? Does it work offline?
Intel Macs? Windows?). Numbers are pulled from the same files as the README so the two cannot drift.
**Built for a phone first:** Instagram visitors are on a phone and the app is for a Mac, so the main button on a
phone is "Send this to my Mac" (share sheet, copy link, mail it to myself).
Done when: it loads in under a second on a phone and the phone-to-Mac path takes two taps.

**L0.11 "Works with your AI tools" page** (`docs/AGENTS.md`): dictating into coding agents and terminals, the MCP
server with a copy-paste setup, `larynx serve`, CLI examples, and one short clip of a spoken prompt landing in a
coding agent. This is the coders' reel 8 and a section of the Hacker News post.

**L0.12 Counting without telemetry.** GitHub keeps traffic for 14 days, so a weekly script saves views, referrers,
clones, stars and release downloads to `~/work/larynx-launch/metrics.csv`. The app itself never reports anything.

**L0.13 Licences.** Confirm each speech model's licence allows what Larynx does with it, and that credits are in
the About panel and the README.

**Gate for L0:** three outside installs done; icon, demo, page exist; every claim on the README's first two
screens links to its evidence.

## L1. Launch to coders (free)

The executor drafts each item into `~/work/larynx-launch/`; Colin posts. One channel a day, so he can answer:
answering comments in the first hours matters more than the post.

1. **FluidAudio showcase.** A pull request adding Larynx to the list of apps built on it (their README invites
   this). Quiet, permanent, and exactly the right readers.
2. **Show HN.** Title along the lines of "Show HN: Larynx, offline Mac dictation with a test that proves nothing
   leaves your Mac". The post says why another one exists, shows the privacy test, links the benchmark including
   lost rows, and lists what is missing. A weekday morning, US Eastern, with three hours free for replies.
3. **Reddit**, each with its own angle and each community's self-promotion rules read first: r/macapps (what it is,
   that it is free, that he wrote it), r/LocalLLaMA (Neural Engine, the models, the benchmark), a coding-agent
   community (talking to agents, MCP).
4. **Listings:** OpenAlternative, AlternativeTo, the open-source Mac app lists, MCP server directories. These rank
   for "open source dictation Mac" searches and keep sending people for years.
5. **One write-up** on the Pages site: what a few hundred of his own timed dictations showed, why rules beat a
   language model for cleanup speed, and how the privacy test works. This is the piece other developers share.

**Read the signal two weeks after the Hacker News post:** about 200 stars, 20 issues or install reports from
strangers, and 3 outside pull requests or well-made issues would mean the message lands. Under 50 stars means the
message is wrong, not the product: lead with the cleanup demo instead of privacy and try the next channel.

**The duty that comes with it:** issues answered within a day, an install failure fixed and released within two,
reporters thanked in the CHANGELOG. For a new project, being answered quickly is the feature people remember.

## L2. The door for everyone (needs LQ1)

- **L2.1 Signed, notarized download** (PLAN-v1 D5): a DMG built by a GitHub Actions release workflow from a tag.
  Colin does the certificate steps himself from written instructions; the keys live in GitHub secrets he adds.
  Changing the signing identity makes macOS ask him for the three permissions once more: tell him before.
- **L2.2 Updates by themselves** with Sparkle, the update feed on the Pages site.
- **L2.3 Homebrew cask** in the tap; the main Homebrew list once the project clears its popularity bar.
- **L2.4 The landing page button becomes Download.**
- **L2.5 Clean-account test:** download to first dictation in under two minutes, not counting the model download.
- **L2.6 Product Hunt**, and r/macapps again now that there is something to click.

## L3. Instagram (the same videos go to YouTube Shorts and TikTok)

One idea per reel. The first two seconds show the result: text appearing as he talks. His real voice, captions
burned in, an end card that says "Free. Link in bio." No other product's logo; the comparisons are "the dictation
built into your Mac" and a yearly price shown with its source and date.

| # | First two seconds | What happens | Rests on | For |
| --- | --- | --- | --- | --- |
| 1 | "I turned off my Wi-Fi." | He dictates a paragraph; it lands at once | `tests/privacy.py` | everyone |
| 2 | "I don't dictate. I think out loud." | Split screen: the messy thought as he said it, the clean text it typed | `tests/cases.json` | everyone |
| 3 | "This costs $144 a year. Mine is free." | The price with its source, then the MIT licence | licence | everyone |
| 4 | "Typing or talking?" | The same 60-word message typed, then spoken, on a timer | measured on the day | everyone |
| 5 | "Your Mac's dictation, and mine." | The same sentence through both | L0.5 (skip if it isn't a clear win) | everyone |
| 6 | "It never loses what you said." | A paste fails on purpose; history has it | `tests/live.py` | everyone |
| 7 | "It learns your name." | Fix a word once; it is right from then on | learning tests | everyone |
| 8 | "I talk to my AI all day." | A spoken prompt lands in a coding agent, hands-free | L0.11 | coders |
| 9 | "Here is the test that proves it." | Network denied in a sandbox; it still types; a web request fails | `tests/privacy.py --prove` | coders |
| 10 | "I built this in a week with AI. Here is what broke." | The story, with real numbers | git history | builders |

Reels 8 to 10 can go out during L1. Reels 1 to 7 wait for the L2 download: sending non-coders to a Terminal line
spends their attention on a wall. If LQ1 stays "no", they go out anyway with "free, one line to install", and the
plan expects few installs from them.

Scripts and shot lists are drafted in `~/work/larynx-launch/reels/`. Colin records screen and voice; editing and
scheduling follow whatever pipeline and calendar the account already uses, and never override it.
**Measure:** taps on the profile link, then page views with an Instagram referrer, then downloads. Saves and
shares say more than likes.

## L4. Keep the loop turning

- A release most weeks with a changelog a person can read; each release is one post ("this week Larynx learned…").
- Every miss a user reports becomes a permanent test case, and the reply to them says so.
- The benchmark is rerun monthly, other apps' new versions included.
- After four weeks of data, decide where the next multiplier is: Windows (PLAN-v1 W) reaches the most new people;
  screen context (PLAN-v1 C) is the largest accuracy win left.

## 6. Order of work

For the executor, one at a time, reporting and continuing as usual:

1. L0.8 history window (PLAN-v1 R5), then L0.1 icon, L0.9 small things.
2. L0.2 demo (needs LQ6: write the sentence and the recording steps for Colin first), L0.3 README, L0.4 repo.
3. L0.7 first five minutes, L0.10 landing page, L0.11 agents page, L0.12 counting, L0.13 licences.
4. L0.5 comparison (may change the README table and reel 5).
5. After LQ2: move the repo, L0.6 tap, fix every link. Then the L0 gate with the three testers (LQ5).
6. L1 drafts, one per channel, for Colin to post. From here PLAN-v1 R6 and section C continue between issues.
7. After LQ1: L2 in order, then L3.

**What needs Colin, in one place:** LQ1 to LQ7 above; 15 minutes of recording; naming three testers; creating the
GitHub organization; posting (or approving) each launch item; the Apple enrolment and certificate steps.

## Status (the executor keeps this current)

| Task | State | Notes / evidence |
| --- | --- | --- |
| L0.8 | built Nov 13 | PLAN-v1 R5 row. Picture in the README. |
| L0.1 | built Nov 13 (Colin left the pick to the planner: "Night") | `scripts/make-icon.swift` draws it (voice bars ending in a text cursor, dark glass tile, blue cursor; three fatter bars up to 64 px) and writes `packaging/Larynx.icns`, `docs/images/icon.png` and `docs/images/social-preview.png`. `make-app.sh` puts it in the bundle; `tests/install.py` checks it. Left: Colin uploads the social preview in the repo settings (no API for it); favicon comes with L0.10. |
| L0.9 | built Nov 13 (not clicked through live) | Menu: Send Feedback…, Check for Updates…, About Larynx. `Links.swift` holds the repo address in one place for LQ2. The About credits point to the README for each model's licence until L0.13 checks them. |
| L0.2 | sentence and recording steps written Nov 13 (`~/work/larynx-launch/demo.md`); waits on Colin's recording (LQ6) | The sentence was checked through the cleanup as text. Found on the way: "Tuesday, actually no, Wednesday" keeps both days (only "no" and "no wait" are correction cues); a rule for "actually no" goes through shadow first. |
| L0.3 | first pass Nov 13; second pass after L0.2 and L0.5 | Tagline and "Why Larynx" (the five edges, each with its evidence) above the cloud table; "English is the measured language"; Uninstall (`scripts/uninstall.sh`: lists, asks, `--keep-data`, `--dry-run`; checked by `tests/install.py`, 11 checks); internals moved to `docs/ARCHITECTURE.md`; privacy and install tests in the Testing table. Still to do: the demo on the first screen (L0.2), the comparison rows (L0.5). |
| L0.4 | done Nov 13 | `CONTRIBUTING.md` (how a rule gets added: the case first), `SECURITY.md`, `ROADMAP.md`, working plans moved to `docs/dev/`. With Colin's OK (Nov 13): Discussions and private vulnerability reporting are on, and five starter issues are open (#1 "actually no" as a change of mind, #2 50/50 and 24/7, #3 VoiceOver labels in the History window, #4 filler words in Spanish, German and French, #5 docs/APPS.md), each checked against the build first. |
| L0.5 to L0.7, L0.10 to L0.13 | not started (planned Nov 13) | |
| L1 | not started | |
| L2 | waits on LQ1 | |
| L3 | reels 8 to 10 after L0.11; 1 to 7 after L2 | |
| L4 | not started | |
