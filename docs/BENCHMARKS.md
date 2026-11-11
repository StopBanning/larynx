# Benchmarks

Speech models measured with `python3 bench/run.py` (audio from `bench/make_sets.py`, kept in `~/work/scratch/larynx-bench`).
Speech model only: cleanup, vocabulary and AI rewrite off. Apple M6, 16 GB, macOS 27.2. Nov 11, 2026, commit c4808c2.
Raw numbers: `bench/results/bench-2026-11-11-c4808c2.json`.

Word error rate (lower is better):

| Model | jargon (120) | noise 10 dB (80) | noise 5 dB (80) | whisper (40) | LibriSpeech clean (300) | LibriSpeech other (300) | long 60-120 s (10) | names spelled right | p90 latency, short clips |
|---|---|---|---|---|---|---|---|---|---|
| `clean` Bark 3.0 Clean (default until v0.5) | 15.57 | 18.41 | 24.10 | 44.01 | 2.38 | 4.26 | 2.20 | 26% | 38 ms |
| `parakeet` Parakeet TDT v3 | 8.68 | 13.92 | 20.21 | 34.43 | 2.25 | 3.86 | 2.43 | 52% | 46 ms |
| `bark3` Bark 3.0 (verbatim) | 15.87 | 18.41 | 25.90 | 39.82 | 2.72 | 4.71 | 2.65 | 5% | 33 ms |
| `ultra` Parakeet Ultra (default) | 8.78 | **11.08** | **16.02** | 33.53 | 1.92 | 3.65 | 2.26 | 54% | 41 ms |
| `unified` Parakeet Unified | **7.98** | 11.68 | 16.92 | **29.64** | **1.82** | **3.06** | 3.78 | **56%** | 54 ms |

Punctuation F1 on the punctuated sets: clean 73-75, parakeet 83-100, ultra 81-100, unified 76-86, bark3 11-37.

**Decision rule (master plan 1.4):** lowest mean WER over jargon + noise + LibriSpeech other, if its cleanup-suite
score is within 2 points of Bark Clean's (264/300), p90 latency on short clips is at most 200 ms, and punctuation F1
is not lower than Bark Clean's. Means: ultra 9.88, unified 9.91, parakeet 11.67, clean 15.59, bark3 16.22. Ultra and
Unified both pass latency and punctuation. **Cleanup gate (Nov 11):** spoken cleanup suite (`bench/results/suite-ultra.log`, `suite-unified.log`):
Bark Clean 264/300, Ultra 257/300, Unified 252/300. Both miss the 2-point bar, almost entirely on **false starts
(0/10 vs 10/10)** and repeats, which Bark Clean removes inside the model. Ultra keeps more sentences intact (must
not change 111/120 vs 95/120). **Decision: the default stays Bark Clean for now.** To switch, the tidy rules must
remove false starts and repeats from a verbatim model's output until Ultra reaches 262+ (the plan's route when a
verbatim engine wins on accuracy), or try the consensus pass (Clean's cleanup + Ultra's words).

**Rerun after new tidy rules (Nov 11, commit 4dc1e0b):** false starts ("I went to the, I drove" -> "I drove"),
2-3 word repeats, mid-sentence "er/ah/eh" and "Aye, I" are now removed by rules, so a verbatim model no longer needs
to do it. Spoken cleanup suite, text rules 59/59 on both runs (`bench/results/suite2-ultra.log`, `suite2-clean.log`):

| Model | Spoken cleanup (300) | Before the new rules |
|---|---|---|
| Parakeet Ultra | **272** | 257 |
| Bark 3.0 Clean | 264 | 264 |

Ultra now beats Bark Clean on cleanup as well as accuracy, and Bark Clean did not regress. **Decision: the default
is Parakeet Ultra from v0.5.0.** Bark Clean stays in the Speech Model menu and is the second-chance model when Ultra
hears nothing. Ultra's remaining cleanup misses are false starts (10/20) and self-corrections (29/40): next plan, A2.
