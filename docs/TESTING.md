# Testing

Every claim in the README has a test or a benchmark behind it. This is the full list, with the latest result
of each.

| Suite | What it checks | Latest |
| --- | --- | --- |
| `swift test` | 118 tests: every cleanup rule against `tests/cases.json`, 100 sentences that must not change in 3 modes, numbers, fitting the field, the rewrite guard, the pipeline, settings (each one documented), history, crash spool, privacy rules, self-learning, word confidence, meeting notes, the microphone surviving an audio engine error, reused patterns giving Foundation's exact results | all pass (Nov 27) |
| `python3 tests/suite.py --rewrite auto` | About 40 messy sentences spoken by 5 macOS voices at 2 speeds, transcribed and scored, plus a 26-case benchmark for the on-device AI rewrite | Nov 11: rules 73/73, rewrite 26/26, spoken 281/300 with Parakeet Ultra (most misses are the speech model mishearing a synthetic voice) |
| `python3 tests/protocol.py` | The `serve` and MCP wire formats stay compatible | pass |
| `python3 tests/agents.py` | The examples in [docs/AGENTS.md](AGENTS.md): AI mode, the four MCP tools, the professional style, and your real dictionary untouched | 10/10 (Nov 13) |
| `scripts/when-idle.sh python3 tests/live.py` | A recording goes through the real listen and paste path into Larynx's own capture window only (never another app), once you're idle and the screen is unlocked; your clipboard and history are left as they were | 4/4 (Nov 11): verified paste 238 ms; dropped paste inserted once by the fallback; space after a finished sentence; space and lowercase mid-sentence |
| `python3 bench/latency.py` | The speed gate, run before each release: 50 clips through the full pipeline; fails over 150 ms median or 350 ms at the 90th percentile | 80 ms median, 144 ms p90 (Nov 12) |
| `python3 tests/history.py` | Kills a dictation mid-transcription; the next launch must recover it word for word | pass |
| `scripts/when-idle.sh python3 tests/privacy.py --prove` | Speech to text three ways inside a sandbox that denies every network connection; then a deliberate web request under the same sandbox, which must fail | 4/4 (Nov 12) |
| `python3 tests/metrics.py` | The launch metrics script (`scripts/metrics.py`, GitHub's own counts, no telemetry): counts add up and a day is never counted twice. Offline | 7/7 (Nov 13) |
| `python3 tests/site.py` | The landing page (`site/`, built by `scripts/make-site.py`): its numbers match this README and BENCHMARKS, the first load stays under 300 KB, and every link into the repo works | 9/9 (Nov 13) |
| `python3 tests/install.py` | The installer into an empty home folder, signed ad hoc as on someone else's Mac: the bundle, its signature, icon and resources, the binary runs, no data left behind; then the uninstall leaves that home clean. Also runs in CI on a clean Mac | 11/11 (Nov 13) |
| CI `portable.yml` | The text engine builds and passes its tests on Windows and Linux; Parakeet runs on a Windows CPU | pass |
| CI `windows.yml` | The Windows prototype (`windows/`): the cleanup cases through `larynx-text.exe`, then hold Right Ctrl in Notepad, speak (a recording played in real time), let go, and the cleaned words arrive with the focus and the clipboard unchanged; latency and streaming accuracy on synthetic speech | pass |

Spoken-suite detail (Parakeet Ultra, AI rewrite on where it would run, Nov 11):

| Area | Pass |
| --- | --- |
| Fillers | 75/80 |
| Repeats | 55/60 |
| False starts | 10/10 (harder ones: 10/20) |
| Self-corrections | 29/40 (0/40 without the rewrite layer; Bark Clean scored 38/40) |
| Trailing off | 8/10 |
| Verbal tics | 30/30 |
| Must not change | 111/120 |
| Real-world messages | 30/30 |

Nearly every remaining miss is the speech model mishearing a synthetic voice (hummus as "Hamas", Priya as "prio",
"uh-huh" as "aha"). Still open: dropping a spoken preamble ("The thing is, what I mean is, ...") is left alone on
purpose. NeMo inverse text normalization was tried for numbers and rejected: it turned "two thirty and it costs"
into "32 it costs".
