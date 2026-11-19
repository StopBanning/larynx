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

## Real voice: the golden set (Nov 11, commit 7bae93b)

Recordings of the author's own dictations (everyday mic and room) with what was meant to be typed, kept only on
that Mac (`larynx golden`, PLAN-v1 B3). Unlike the sets above, this runs the whole pipeline (dictionary, vocabulary,
cleanup rules; AI rewrite off) and scores the typed text. Numbers only; the clips and their text never leave the Mac.

| Engine | WER | Punctuation F1 | Names | p50 | p90 |
| --- | --- | --- | --- | --- | --- |
| ultra | 0.58% | 99.3 | 76.2% | 53 ms | 89 ms |
| unified | 2.67% | 84.8 | 71.4% | 53 ms | 103 ms |
| parakeet | 2.67% | 88.4 | 61.9% | 72 ms | 132 ms |
| bark3 | 2.79% | 78.2 | 57.1% | 73 ms | 205 ms |
| clean | 3.48% | 81.9 | 52.4% | 87 ms | 135 ms |

48 clips, 290 s. **Read this with care:** every reference so far was checked by an assistant against the
conversation and the four speech models, starting from what Ultra typed (fixing what was known to be wrong:
"Compaq" → "compact", "Robus" → "to Opus", "clod" → "Claude", "doc" → "Dock", stumbles left in). That
favours Ultra, especially on punctuation, so this baseline is a regression gate for the default engine (no change
may raise its golden WER), not yet a fair comparison between engines. References from the author's own fixes (edits to a
pasted dictation and repeats with a word changed are now recorded automatically) will replace that bias as they
accumulate; the target is 100 clips.

## Real voice, picked at random (PLAN-v1 R4, Nov 12, commit 7180b94)

The golden set above leans toward dictations that went wrong (they were picked because something needed fixing).
This set is 57 dictations drawn at random from two days of daily use, a third each short (under 5 s), medium and
long (over 15 s): 678 s of audio, about 1,900 words, mostly messages to an AI assistant. Same full pipeline, same
privacy: numbers only. `python3 bench/run.py --sets random`. Spoken spellings count as the same word here (wanna /
want to, 'cause / because, alright / all right).

| Engine | WER | Punctuation F1 | Names | p50 | p90 |
| --- | --- | --- | --- | --- | --- |
| ultra | 0.87% | 97.6 | 71.2% | 48 ms | 128 ms |
| parakeet | 1.49% | 86.5 | 69.2% | 46 ms | 125 ms |
| unified | 1.85% | 73.2 | 65.4% | 54 ms | 136 ms |
| bark3 | 3.24% | 76.3 | 44.2% | 47 ms | 127 ms |
| clean | 4.78% | 79.4 | 59.6% | 52 ms | 214 ms |

**How the references were made, and what that means.** Every downloaded engine transcribed each clip verbatim
(`bench/prelabel.py`); all five agreed word for word on 10 of 60, three or more on 33. An assistant then wrote what
was meant from the five versions, the typed text and the conversation around it: fillers, stutters and cut-off word
fragments out, everything else as said; where engines disagreed, the majority unless the sentence showed otherwise
(3 such spots went against Ultra). 3 clips nobody could settle (foreign words read aloud, a name every engine spelled
differently) were left out. Nobody listened: a word all five engines got wrong the same way is invisible here, and
the house style follows Larynx's cleanup, which helps the default engine on punctuation. So the ranking is solid,
the absolute numbers are a floor. The author's own labels (`larynx golden label`) would replace these.

**What Ultra still gets wrong** (12 spots in 57 dictations; examples are made up, of the same kind):

| Kind | Spots | Fix |
| --- | --- | --- |
| Cut-off word left in ("it was defin- really good") | 4 | Cleanup: not yet safe to remove; R6 |
| A homophone where the right word was on screen ("real" for "reel") | 2 | Screen context (C3, in shadow) |
| Stutter kept ("that that") | 2 | "that that" can be meant; left alone |
| Misheard word | 2 | Speech model |
| Cleanup removed a word (a "like"; a phrase said three times cut to two) | 2 | The second fixed in 7180b94 |

## Against what a Mac already has (PLAN-launch L0.5, Nov 13 to 14)

The same audio through three systems. `python3 bench/compare.py` reproduces it (the audio is made by macOS voices on
your Mac; nothing is downloaded).

- **Larynx**: Parakeet Ultra and the cleanup rules, AI rewrite off, so the result is the same on every Mac and in
  every app (the rewrite only runs in apps for people, on Macs with Apple Intelligence).
- **Larynx, no cleanup**: the same speech model, verbatim.
- **Apple's on-device speech**: the `SpeechTranscriber` that macOS 26 gives every app (`bench/apple_transcribe.swift`),
  on the same files, with no download and no permission prompt. It is not the Dictation key on the keyboard: that
  model was not installed on this Mac, so it is not measured here.

Two sets:

- **Messy** (`bench/messy.json`): 40 sentences written for this, with fillers, stutters, false starts and spoken
  numbers, each said by three macOS voices (120 clips). Scored on **edits needed**: the words a person would still
  change to get from the output to what was meant. This is the number behind the promise of text that needs no fixing.
- **Jargon**: the bench's names-and-terms sentences (1,002 words), scored on word errors against the words said.

**Run 1, held out (Nov 13, commit before 439a292).** The messy set was written after the rules and had never been
used to tune them.

| System | Messy: edits needed | Fillers | Stutters | False starts | Numbers | Mixed | Jargon: word errors |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Larynx | **11.9%** | **2.0%** | **9.2%** | **49.3%** | **5.0%** | **2.6%** | **8.8%** |
| Larynx, no cleanup | 21.0% | 13.3% | 14.4% | 53.3% | 5.0% | 29.4% | 8.8% |
| Apple on-device | 20.0% | 10.4% | 11.3% | 54.7% | 7.8% | 26.8% | 18.5% |

The row we lost: **false starts**. Half the words still needed fixing ("Send it to Maria, no, send it to Priya" came
out whole), no better than Apple. Stutters were also weak: any doubled word outside a short list stayed ("add add").

**What changed (commits 439a292, a8e2787):** spoken corrections ("no", "no wait", "sorry", "I mean", "actually")
are applied when the words after the cue restart something said just before or replace a word of the same kind; any
word said exactly twice is a stutter unless the double is meant. Both were read against every one of 923 real
dictations before they were turned on, and each wrong change became an exclusion.

**Run 2 (Nov 14, after the fixes).** This run is **not held out**: the fixes were found by reading run 1's misses on
this same set, so it shows the gaps closing, not how Larynx does on sentences it has never seen. A fresh held-out set
is the next step. One sentence was also reworded between the runs (number 7, a filler sentence).

| System | Messy: edits needed | Fillers | Stutters | False starts | Numbers | Mixed | Jargon: word errors |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Larynx | **7.4%** | **2.0%** | **7.2%** | **24.7%** | **5.0%** | **2.6%** | **8.8%** |
| Larynx, no cleanup | 21.0% | 13.1% | 14.4% | 53.3% | 5.0% | 29.4% | 8.8% |
| Apple on-device | 19.9% | 10.3% | 11.3% | 54.7% | 7.8% | 26.8% | 18.5% |

What is still left, read clip by clip: the speech model mishears some stutters before the rules see them ("the the
printer" heard as "that the printer", "we we move" as "we remove"); "that that" stays by design (it is often meant);
"café" comes out as "cafe"; a cue with no comma before it is not seen ("meet at the actually let's meet at the
library"); and "never mind" cancelling the sentence before it is not handled. Results: `bench/results/compare-2026-11-13.json`
(run 1) and `compare-2026-11-14.json` (run 2), with every output.

**Run 3, held out again (Nov 16, commit 0676db9).** Forty new sentences (`bench/messy2.json`), written after run 2's
fixes and never used to tune them, same five kinds and the same three voices. This is the honest number for sentences
Larynx has not seen:

| System | Messy 2: edits needed | Fillers | Stutters | False starts | Numbers | Mixed |
| --- | --- | --- | --- | --- | --- | --- |
| Larynx | **11.8%** | **4.3%** | **5.6%** | **47.6%** | **0.0%** | **14.4%** |
| Larynx, no cleanup | 23.9% | 13.7% | 17.3% | 66.7% | 0.0% | 40.9% |
| Apple on-device | 21.7% | 10.3% | 9.9% | 71.4% | 1.7% | 35.6% |

About half the edits Apple's text needs, but false starts were still the row lost: run 2's fixes had only caught the
shapes in the first set. The misses, read clip by clip: a short swap after a small word ("to Denver, sorry, to
Boulder", "the first, sorry, the fifth"), a one-word swap ("blue, no wait, green"), and the speech model ending the
sentence before the cue ("at seven. No, let's leave at eight"). Also "Tell, tell Nina", "more more", a leading "Hum,"
for "hmm", and "eight thirty" written as "8.30".

**What changed (this commit):** each of those, read against all 1,561 real dictations before turning on. The first
version changed 9 of them and 4 were wrong ("I mean" adding to a sentence rather than correcting it, and meant
repeats like "Testing, testing"), so a cue after a full stop must be "no", "sorry", "I mean" or "no wait" and repeat
the first words, and a repeat with a comma only counts opening a sentence. After that, 2 changed, both real
corrections. "Actually" after a full stop still starts a new thought and is left.

**Run 4 (Nov 16, after the fixes), not held out** for either set: Messy 2 at **3.3%** (false starts 4.0%), and the
first set at **6.9%** (run 2: 7.4%), so nothing it had right got worse. Apple and the uncleaned model are unchanged.
The next held-out check needs a third set. Results: `compare-2026-11-16-messy2.json` (run 3) and
`compare-2026-11-16-messy-messy2.json` (run 4).

**Run 5, held out (Nov 18, commit 711d3cb).** A third set of forty (`bench/messy3.json`), written after run 4's fixes
without rereading the rules, same five kinds, mix, voices and scoring. Two sentences were reworded and the whole set
run again before publishing (they happened to share four words in a row with the author's own dictations, which never
go in the repo); nothing was changed to improve the score:

| System | Messy 3: edits needed | Fillers | Stutters | False starts | Numbers | Mixed |
| --- | --- | --- | --- | --- | --- | --- |
| Larynx | **7.5%** | **9.3%** | **3.4%** | **17.8%** | **0.0%** | **7.6%** |
| Larynx, no cleanup | 27.7% | 20.0% | 18.4% | 76.3% | 0.0% | 35.4% |
| Apple on-device | 24.3% | 13.3% | 10.9% | 77.0% | 0.6% | 32.6% |

About a third of the edits Apple's text needs. False starts, the row lost in runs 1 and 3, fell from 47.6% to 17.8% on
sentences the fixes never saw. Read clip by clip, the 61 edits are of three kinds:

- **How the set was written, not a mistake** (20 edits): the expected text says "the fourteenth" and "the eleventh"
  where Larynx writes "the 14th" and "the 11th", "wifi" where it writes "Wi-Fi", and "neighbor's" where the British
  and Australian voices come out as "neighbour's". The expected text was left as written, so these still count.
- **The speech model mishearing** (14): "the the" heard as "that the", "spare" as "spear", "we we" as "we re", "our our" as "our
  hour" and "release", one garbled clause ("Hooded on the company card"), "Elena" as "Eleanor".
- **Cleanup misses** (27): a correction across a full stop that repeats the verb, not the first words ("The store
  opens at nine. No, it opens at ten on Sundays", 15 edits); a repeat split by a full stop after a leading "Ah" ("Ah,
  the dentist. The dentist can see you", 7); "uh" and "hmm" heard as "Ah,", "Eh," or "Ham," at the start (5). Not counted, since
  punctuation isn't scored: a comma left where a filler was taken out ("We should, leave").

Results: `compare-2026-11-18-messy3.json`.

**Run 6 (Nov 18, after the fixes), not held out.** Of the three cleanup misses, only one shape was fixed: a restart
that names the subject with a pronoun and repeats the verb ("The store opens at nine. No, it opens at ten on Sundays"
becomes "The store opens at ten on Sundays"), plus "Ham," read as "hmm". The other two were left on purpose: every
leading "Ah," in the author's 2,443 real dictations was meant ("Ah, I see", "Ah, okay"), and so was every short phrase
said twice across a full stop (the kind of "Not yet. Not yet, anyway" a speaker means), so removing them would be wrong far more often
than right. Both fixes changed none of the 2,443 real dictations. Messy 3 at **5.5%** (false starts **6.7%**); the
first two sets unchanged at 6.9% and 3.3%. Results: `compare-2026-11-18-messy3-fixed.json` and
`compare-2026-11-18-messy-messy2.json`. The next held-out check needs a fourth set.

## A set made by other people: DisfluencySpeech (Nov 18)

All three messy sets above were written by us and read by macOS voices. To check against something we didn't write,
the same three systems ran on the 250 test clips of [DisfluencySpeech](https://huggingface.co/datasets/amaai-lab/DisfluencySpeech)
(Wang et al., 2024, [arXiv 2406.08820](https://arxiv.org/abs/2406.08820), Apache-2.0): one human speaker reading
Switchboard phone-call transcripts aloud with every "uh", repeat and restart kept in. Its transcript A is every word
said; its transcript C has the fillers, discourse markers ("well", "you know"), edit terms ("I mean") and restarts
taken out. C is the "meant" here. No rule was tuned on it. `python3 bench/disfluency.py` fetches it (70 MB, to
scratch), then `python3 bench/compare.py --sets disfluency`. Clips are tagged by the first thing their Switchboard
annotation holds: a restart (122 clips), a filler (42), a discourse marker or edit term (43), or nothing (43).

| System | Edits needed (against C) | restarts | fillers | discourse | nothing to remove | Word errors (against A) |
| --- | --- | --- | --- | --- | --- | --- |
| Larynx | **10.9%** | 14.8% | 8.1% | 11.8% | 3.3% | 7.9% |
| No cleanup (same speech model) | 16.1% | 24.6% | 12.7% | 11.6% | 3.0% | **2.9%** |
| Apple SpeechTranscriber | 13.9% | 20.6% | 9.1% | 12.4% | 3.7% | 6.5% |

**What it shows.**
- Larynx leads, by less than on our own sets (10.9% against 13.9%, where messy 3 was 7.5% against 24.3%). Our
  sets are heavy on spelled-out false starts like "no, the medium", which Apple doesn't touch. Phone talk has fewer.
- The speech model alone gets 97.1% of the words said right, from a human voice it was never tuned on. Apple's
  number against A is higher only because Apple drops some fillers itself.
- **Most of what Larynx leaves is a style the set removes and Larynx keeps:** "you know" (41 times), a leading
  "well" (36), "I mean" when it isn't a correction (11) and "oh" (11). Those four make up about 100 of Larynx's 526
  edits. Larynx keeps them on purpose for now: they're meant often enough in dictation, and C removes every one.
  Its discourse row (11.8%) is the same as no cleanup (11.6%).
- Cleanup made 7 of 250 clips worse than the raw model. Most are the set's own choices: C keeps a trailing "and"
  or "but" (Larynx drops it) and keeps "like" when Switchboard didn't mark it as a filler ("the baby is like 17
  months"). One was a real miss: a doubled "has, has" at a clause boundary was taken as a stutter.

Results: `compare-2026-11-18-disfluency.json`.

**After the fixes (Nov 19), no longer held out.** Three changes came from reading those misses. They are tuned on
this set now, so the new numbers aren't a clean test the way the first run was.
- "you know" as a filler goes in every style: between commas, opening a sentence or a clause with a comma after it,
  in mid-sentence with a comma after it, and as a tag at the end. It stays where it's the verb ("if you know, tell
  me", "the people that you know", "as you know", "I bet you know"), and wherever no comma follows ("just so you
  know he called", "you know what she said"). Where it sat between two thoughts, one comma stays.
- The professional style also drops a leading "Well," (and "Well" before a new clause's subject; "Well done" stays).
  It already dropped "Oh," and "I mean" as a filler, so this set's professional row is new too.
- "has has" counts as a meant double ("everybody who has has a ticket").

Read against all 2,490 of the author's real dictations before turning on: casual changed 33, professional 36. Every
change removed a filler "you know" or a professional "Well,", and none was wrong. The first version of the rule ran
two thoughts together ("keep sanding we can paint"), so the comma rule above was added.

| System | Edits needed (against C) | restarts | fillers | discourse | nothing to remove |
| --- | --- | --- | --- | --- | --- |
| Larynx (casual) | **8.3%** (was 10.9%) | 11.6% | 6.4% | 7.1% | 3.2% |
| Larynx (professional) | **7.5%** | 10.7% | 5.4% | 5.0% | 4.1% |
| Apple SpeechTranscriber | 13.9% | 20.6% | 9.1% | 12.4% | 3.7% |

The professional row is a little worse on clips with nothing to remove (4.1%), because it drops openers like "Yeah,"
and "So" that the set keeps. Our three messy sets didn't change (6.9%, 3.3%, 5.5% casual). Results:
`compare-2026-11-19-disfluency.json` and `compare-2026-11-19-messy-messy2-messy3.json`.

## Accents: real conversational English from many first languages (Nov 14)

The sets above are one voice (the author's) and macOS voices. This one is real people: 144 clips from the test split
of EdAcc, the Edinburgh International Accents of English Corpus (CC BY-SA 4.0), six from each of 24 accent labels so
the common ones do not swamp the rest. `python3 bench/accents.py` takes the same seeded sample; `python3
bench/compare.py --sets accents` and `python3 bench/run.py --engines ultra,parakeet,unified --sets accents` score it.
The speech is unscripted conversation, much harder than dictation: even Mainstream US English is 17% here.

Word errors against EdAcc's transcripts, speech model only (the references keep every "um" and repeated word, so the
cleanup, which removes them, is not scored here; read clip by clip, its removals were right, and the one wrong one,
"told you, you know" losing a "you", is fixed):

| Accent | Larynx (Ultra) | Apple on-device |
| --- | --- | --- |
| Bulgarian | 13.1% | **11.9%** |
| Catalan | 17.1% | **16.4%** |
| Chinese | **13.8%** | 19.3% |
| Eastern European | **10.3%** | 11.5% |
| European | **7.4%** | 9.8% |
| French | **13.0%** | 14.8% |
| Ghanaian English | **21.7%** | **21.7%** |
| Indian English | **20.0%** | 21.7% |
| Indonesian | **10.2%** | 14.8% |
| Irish English | **9.7%** | 19.4% |
| Israeli | **25.0%** | 26.2% |
| Italian | **13.0%** | 15.3% |
| Jamaican English | **23.9%** | 26.9% |
| Kenyan English | **15.9%** | 20.5% |
| Latin American | **6.1%** | 14.0% |
| Lithuanian | **17.5%** | 23.8% |
| Mainstream US English | **17.2%** | 25.0% |
| Nigerian English | **11.9%** | 16.3% |
| Romanian | **19.1%** | 25.2% |
| Scottish English | **27.9%** | **27.9%** |
| Southern British English | **13.4%** | 15.8% |
| Spanish | **21.9%** | 26.7% |
| Vietnamese | 27.6% | **26.7%** |
| Not given | **8.9%** | 19.0% |
| **All 144 clips** | **15.7%** | 19.3% |

Larynx's own models on the same clips: **Ultra 15.9%** (the default), Parakeet v3 17.2%, Parakeet Unified 19.5%, so
the default is already the best of them for accents. Six clips per accent is about 100 words each: a single accent's
number moves a few points with a different sample, so read the table for patterns (Scottish, Vietnamese, Israeli and
Jamaican English are hardest for both), not for close races. Results: `bench/results/compare-2026-11-14-accents.json`
and `bench-2026-11-14-9ce6642.json`.

## The other apps (facts from their own pages, read Nov 13, 2026)

Feeding the same audio to the other apps needs a virtual audio driver, so they are compared on what they say about
themselves instead. App-against-app on the same audio is PLAN-v1 F2.

| App | Licence | Price | Offline | Speech engine | Cleanup | Stars (Nov 13) |
| --- | --- | --- | --- | --- | --- | --- |
| Larynx | MIT | Free, no limits | Yes, always | Parakeet Ultra (Neural Engine) | Rules, instant; optional on-device AI rewrite | (this repo) |
| [Handy](https://github.com/cjpais/Handy) | MIT | Free | Yes | Whisper, Parakeet v3 | Not stated | 38,697 |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | GPL-3.0 | Paid build $25 to $49 one-time; free from source | Yes | Parakeet, WhisperKit | AI enhancement; cloud optional | 7,118 |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | GPL-3.0 (its local AI runtime is closed) | Free | Yes | Parakeet, Nemotron, Whisper, Apple Speech and more | Optional AI: cloud, or a closed local model | 13,014 |
| [OpenWhispr](https://github.com/OpenWhispr/openwhispr) | MIT | Free local; cloud 2,000 words a week free, Pro $80 a year | Optional | Whisper, Parakeet, cloud | AI step, local or cloud | 11,520 |
| [Wispr Flow](https://wisprflow.ai) | Proprietary | Free tier with a weekly word cap; Pro $12 to $15 a month | Not stated | Not stated | Fillers, punctuation, corrections; where it runs is not stated | n/a |
| macOS Dictation | Proprietary | Free | Depends on the Mac and language | Not stated | Punctuation; no filler removal mentioned | n/a |

"Not stated" means the app's own pages do not say. Stars are from GitHub's API on Nov 13.

## Second opinion on doubtful words (PLAN-v1 B4, Nov 11)

The speech model's per-word confidence (lowest token confidence in the word) against what was really said, on the
golden set with Parakeet Ultra: 842 right words, 17 wrong.

| Flag words under | Wrong words caught | Right words flagged |
| --- | --- | --- |
| 0.4 | 2 of 17 | 1 of 842 (0.1%) |
| 0.5 | 2 | 8 (1.0%) |
| 0.6 | 3 | 26 (3.1%) |
| 0.7 | 5 | 40 (4.8%) |
| 0.9 | 6 | 96 (11.4%) |

The two it catches at 0.4 are real mishearings ("Robus" 0.34, "Presume" 0.36); "Compaq" was 0.51. Most of the
rest were heard with high confidence ("clod" 0.95, "doc" 0.96), so no confidence threshold finds them: they need
context (milestone C).

**Swapping in a second engine where Ultra was unsure: no-go.** Simulated on golden + jargon + noise: where Ultra
had a word under the threshold (or one the macOS spell checker doesn't know) and the second engine was surer by a
margin about known words, take the second engine's words for that stretch only. Best setting (Unified, under 0.4,
margin 0.2): golden 1.63% → 1.51% (one swap), jargon 8.78% → 8.78%, noise10 11.08% → 11.23%, noise5 16.02% → 15.72%.
Bark Clean as the second engine: within ±0.3 points everywhere. The bar was 10% fewer errors; this is noise, at
the cost of a second model in memory. Real misses are either shared by every engine ("Two opus", "Presume") or
heard confidently ("clod", "doc").

**Shipped instead:** words under 0.4, or under 0.8 when no dictionary knows them (lowercase only), are flagged:
the dictation is marked `doubtful` in history and the pill says "Not sure about “…”" for 2 s (`doubtHint`).
Nothing in the text changes. `larynx golden candidates` lists doubtful dictations as needing a reference.

### Third opinion from a big model: LFM3-Audio-2B (Nov 11): no-go

Liquid AI's 2B audio language model through FluidAudio (Core ML build, int8, speech recognition only), on the same
clips, raw output against the references:

| Set | LFM3-Audio-2B | Parakeet Ultra | LFM3 p50 / p90 |
| --- | --- | --- | --- |
| golden (48) | 4.30% | 1.63% | 479 / 1291 ms |
| jargon (120) | 10.28% | 8.78% | 246 / 290 ms |
| noise10 (80) | 13.47% | 11.08% | 229 / 267 ms |
| noise5 (80) | 24.40% | 16.02% | 229 / 274 ms |

(Golden favours Ultra, whose text the references started from; jargon and noise are neutral, and it loses there
too.) Of the author's known mishearings it fixed "Compaq" → "compact" and "clod" → "Claude", but not "Robus", "Two
opus", "Presume" (→ "To zoom") or "doc". The rule was to keep it only if it fixes a third of the doubtful rows
within 1 s; it fixed none of them. First load took 12 minutes (download plus GPU compile, ~3 GB of cache); peak use
fits in memory. Not kept; files removed.
