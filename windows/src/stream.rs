//! Transcribing while you talk, so letting go only has to finish the last few seconds.
//!
//! The recording is cut at pauses into segments. Each segment is transcribed with some audio on both sides of it
//! (left and right context, so the model hears whole sentences and doesn't end every segment with a period), and
//! only the tokens whose time falls inside the segment are kept. At key-up, only the audio after the last cut is
//! left to transcribe.

pub const RATE: usize = 16_000;
const FRAME: usize = 320; // 20 ms

#[derive(Clone, Copy, Debug)]
pub struct Config {
    /// Shortest segment worth cutting off (s).
    pub min_segment: f32,
    /// A pause at least this long is a place to cut (s).
    pub min_pause: f32,
    /// Audio after a cut that must exist before the segment is sent, as right context (s).
    pub right_context: f32,
    /// Audio before a segment given to the model as left context (s).
    pub left_context: f32,
    /// With no pause, force a cut once this much audio is waiting (s).
    pub max_pending: f32,
}

impl Default for Config {
    fn default() -> Self {
        Config { min_segment: 2.0, min_pause: 0.24, right_context: 1.0, left_context: 1.5, max_pending: 10.0 }
    }
}

/// A piece of the recording to transcribe: keep the tokens in [start, end), feed the model [ctx_start, ctx_end).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cut {
    pub start: usize,
    pub end: usize,
    pub ctx_start: usize,
    pub ctx_end: usize,
}

pub struct Segmenter {
    pub cfg: Config,
    pub committed: usize,
}

fn secs(s: f32) -> usize {
    (s * RATE as f32) as usize
}

pub fn frame_rms(audio: &[f32]) -> Vec<f32> {
    audio.chunks(FRAME).map(|f| (f.iter().map(|x| x * x).sum::<f32>() / f.len() as f32).sqrt()).collect()
}

impl Segmenter {
    pub fn new(cfg: Config) -> Self {
        Segmenter { cfg, committed: 0 }
    }

    /// The next segment that can be sent, if any. Call as audio grows; each returned cut advances `committed`.
    pub fn next_cut(&mut self, audio: &[f32]) -> Option<Cut> {
        let c = &self.cfg;
        let start = self.committed;
        let latest = audio.len().checked_sub(secs(c.right_context))?;
        if latest < start + secs(c.min_segment) {
            return None;
        }
        let rms = frame_rms(&audio[start..]);
        let threshold = silence_threshold(&frame_rms(audio));
        let first = secs(c.min_segment) / FRAME;
        let last = (latest - start) / FRAME;
        let need = (secs(c.min_pause) / FRAME).max(1);
        let mut run = 0;
        let mut cut = None;
        for i in first..rms.len() {
            if rms[i] < threshold {
                run += 1;
            } else {
                if run >= need {
                    let mid = start + (i - run / 2) * FRAME;
                    if mid <= latest {
                        cut = Some(mid);
                    }
                    break;
                }
                run = 0;
            }
        }
        if cut.is_none() && run >= need {
            // Still silent at the end of what we have: cut in the middle of the pause so far, if there's context after.
            let mid = start + (rms.len() - run / 2) * FRAME;
            if mid <= latest {
                cut = Some(mid);
            }
        }
        if cut.is_none() && audio.len() - start > secs(c.max_pending) {
            // No pause for a long time: cut at the quietest frame in the back part of what's waiting.
            let from = (secs(c.max_pending) * 6 / 10) / FRAME;
            let quietest = (from..=last.min(rms.len().saturating_sub(1)))
                .min_by(|&a, &b| rms[a].partial_cmp(&rms[b]).unwrap_or(std::cmp::Ordering::Equal))?;
            cut = Some(start + quietest * FRAME + FRAME / 2);
        }
        let end = cut?;
        if end <= start {
            return None;
        }
        self.committed = end;
        Some(Cut {
            start,
            end,
            ctx_start: start.saturating_sub(secs(c.left_context)),
            ctx_end: (end + secs(c.right_context)).min(audio.len()),
        })
    }

    /// What's left at key-up: everything after the last cut, with left context.
    pub fn tail(&self, audio: &[f32]) -> Cut {
        Cut {
            start: self.committed,
            end: audio.len(),
            ctx_start: self.committed.saturating_sub(secs(self.cfg.left_context)),
            ctx_end: audio.len(),
        }
    }
}

/// Speech is loud, pauses are quiet: a level a bit above the quiet end of this recording, never below a floor.
pub fn silence_threshold(rms: &[f32]) -> f32 {
    if rms.is_empty() {
        return 0.01;
    }
    let mut sorted: Vec<f32> = rms.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let floor = sorted[sorted.len() / 10];
    let loud = sorted[sorted.len() * 9 / 10];
    (floor * 3.0).max(loud * 0.08).clamp(0.004, 0.05)
}

/// A token the model emitted, with where it was in the audio it was given (s).
#[derive(Clone, Debug)]
pub struct Token {
    pub piece: String,
    pub time: f32,
}

/// How far before its cut a segment keeps words (s). That audio is in the middle of what the model heard for this
/// segment (its left context), so the words there are reliable; the previous segment also has them, and `merge`
/// keeps them once.
pub const MARGIN_BEFORE: f32 = 1.0;
/// How far past its cut a segment keeps words (s). Small: words near the end of what the model heard are the least
/// reliable, and the next segment hears them well.
pub const MARGIN_AFTER: f32 = 0.35;

/// A word with when it started, in seconds from the start of the recording.
#[derive(Clone, Debug, PartialEq, serde::Serialize)]
pub struct Word {
    pub text: String,
    pub time: f32,
}

/// Turns the tokens of a transcription of [ctx_start, ctx_end) into the words that belong to [start, end), give or
/// take the margins. Times become seconds from the start of the recording.
pub fn keep_inside(tokens: &[Token], cut: &Cut) -> Vec<Word> {
    let offset = cut.ctx_start as f32 / RATE as f32;
    let lo = if cut.start == 0 { f32::NEG_INFINITY } else { cut.start as f32 / RATE as f32 - MARGIN_BEFORE };
    let hi = if cut.end == cut.ctx_end { f32::INFINITY } else { cut.end as f32 / RATE as f32 + MARGIN_AFTER };
    let mut words: Vec<Word> = Vec::new();
    let mut in_word = false;
    for (i, t) in tokens.iter().enumerate() {
        let at = t.time + offset;
        let starts_word = i == 0 || t.piece.starts_with('\u{2581}');
        let piece = t.piece.replace('\u{2581}', "");
        if starts_word {
            in_word = at >= lo && at < hi;
            if in_word && !piece.is_empty() {
                words.push(Word { text: piece, time: at });
            } else if in_word {
                words.push(Word { text: String::new(), time: at });
            }
        } else if in_word {
            // The rest of a word, or the punctuation after it.
            if let Some(w) = words.last_mut() {
                w.text.push_str(&piece);
            }
        }
    }
    words.retain(|w| !w.text.is_empty());
    words
}

fn norm(word: &str) -> String {
    word.chars().filter(|c| c.is_alphanumeric() || *c == '\'').flat_map(char::to_lowercase).collect()
}

/// How many words two runs of the same length share, position by position.
fn shared(a: &[Word], b: &[Word]) -> usize {
    a.iter()
        .zip(b)
        .filter(|(x, y)| {
            let (x, y) = (norm(&x.text), norm(&y.text));
            !x.is_empty() && x == y
        })
        .count()
}

/// Where the next piece lines up with the end of what we have: (words of ours it covers, words of its own before
/// that). The longest run wins; a run of three or more may have one misheard word; up to three extra words at the
/// start of the next piece are allowed (words we missed), but only for runs of two or more.
fn seam(out: &[Word], next: &[Word]) -> Option<(usize, usize)> {
    let most = out.len().min(next.len()).min(16);
    for k in (1..=most).rev() {
        for j in 0..=3usize {
            if j + k > next.len() || (j > 0 && k < 2) {
                continue;
            }
            let n = shared(&out[out.len() - k..], &next[j..j + k]);
            let ok = if k <= 2 { n == k } else { n + 1 >= k && n * 10 >= k * 7 };
            if ok {
                return Some((k, j));
            }
        }
    }
    None
}

/// Joins segments (each with where its cut started, in seconds). Neighbours overlap around each cut, so the next
/// piece normally repeats the last words we have. Where it lines up (see `seam`), the overlap is taken from the next
/// piece, which heard those words in the middle of its audio rather than at the end. Where it doesn't, nothing we
/// already have is dropped: only the next piece's words that come after ours (by time) are added.
pub fn merge(pieces: &[(f32, Vec<Word>)]) -> String {
    let mut out: Vec<Word> = Vec::new();
    for (_, next) in pieces {
        if next.is_empty() {
            continue;
        }
        if out.is_empty() {
            out.extend(next.iter().cloned());
            continue;
        }
        match seam(&out, next) {
            Some((k, _)) => {
                out.truncate(out.len() - k);
                out.extend(next.iter().cloned());
            }
            None => {
                let last = out.last().map(|w| w.time).unwrap_or(f32::NEG_INFINITY);
                // Two transcriptions place the same word up to ~0.15 s apart.
                out.extend(next.iter().filter(|w| w.time > last + 0.15).cloned());
            }
        }
    }
    out.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ")
}

/// Turns SentencePiece pieces into text: ▁ starts a word; no space before punctuation.
pub fn detokenize(tokens: &[Token]) -> String {
    let cut = Cut { start: 0, end: usize::MAX, ctx_start: 0, ctx_end: usize::MAX };
    merge(&[(0.0, keep_inside(tokens, &cut))])
}

/// Joins texts with single spaces.
pub fn join(parts: &[String]) -> String {
    parts.iter().map(|s| s.trim()).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
}

/// Word error rate after lowercasing and dropping punctuation: how far `hyp` is from `reference`.
pub fn wer(reference: &str, hyp: &str) -> f32 {
    let norm = |s: &str| -> Vec<String> {
        s.to_lowercase()
            .chars()
            .map(|c| if c.is_alphanumeric() || c == '\'' { c } else { ' ' })
            .collect::<String>()
            .split_whitespace()
            .map(str::to_string)
            .collect()
    };
    let (r, h) = (norm(reference), norm(hyp));
    if r.is_empty() {
        return if h.is_empty() { 0.0 } else { 1.0 };
    }
    let mut prev: Vec<usize> = (0..=h.len()).collect();
    for i in 1..=r.len() {
        let mut cur = vec![i; h.len() + 1];
        for j in 1..=h.len() {
            let sub = prev[j - 1] + usize::from(r[i - 1] != h[j - 1]);
            cur[j] = sub.min(prev[j] + 1).min(cur[j - 1] + 1);
        }
        prev = cur;
    }
    prev[h.len()] as f32 / r.len() as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    fn speech(s: f32) -> Vec<f32> {
        (0..secs(s)).map(|i| (i as f32 * 0.07).sin() * 0.3).collect()
    }
    fn pause(s: f32) -> Vec<f32> {
        vec![0.0005; secs(s)]
    }

    #[test]
    fn cuts_at_pauses_with_context() {
        let mut audio = speech(2.5);
        audio.extend(pause(0.5));
        audio.extend(speech(1.5));
        let mut seg = Segmenter::new(Config::default());
        let cut = seg.next_cut(&audio).expect("a cut");
        let at = cut.end as f32 / RATE as f32;
        assert!((2.6..2.9).contains(&at), "cut at {at}");
        assert_eq!(cut.start, 0);
        assert_eq!(cut.ctx_end, (cut.end + secs(1.0)).min(audio.len()));
        assert!(seg.next_cut(&audio).is_none());
        assert_eq!(seg.tail(&audio).start, cut.end);
        assert_eq!(seg.tail(&audio).ctx_start, cut.end - secs(1.5));
    }

    #[test]
    fn waits_for_right_context() {
        let mut audio = speech(2.5);
        audio.extend(pause(0.5));
        let mut seg = Segmenter::new(Config::default());
        assert!(seg.next_cut(&audio).is_none(), "no right context yet");
    }

    #[test]
    fn forces_a_cut_without_pauses() {
        let audio = speech(12.0);
        let mut seg = Segmenter::new(Config::default());
        let cut = seg.next_cut(&audio).expect("forced cut");
        assert!(cut.end > secs(5.0) && cut.end <= secs(11.0));
    }

    #[test]
    fn short_speech_is_left_for_key_up() {
        let mut audio = speech(1.0);
        audio.extend(pause(2.0));
        let mut seg = Segmenter::new(Config::default());
        // The only pause starts before min_segment: the cut lands in it, after min_segment.
        if let Some(cut) = seg.next_cut(&audio) {
            assert!(cut.end >= secs(2.0));
        }
    }

    fn tok(p: &str, t: f32) -> Token {
        Token { piece: p.into(), time: t }
    }

    #[test]
    fn keeps_words_inside_with_margins() {
        // The model heard [0, 5); the segment is [2.0, 4.0), kept from 1.0 s to 4.35 s.
        let cut = Cut { start: secs(2.0), end: secs(4.0), ctx_start: 0, ctx_end: secs(5.0) };
        let tokens = vec![
            tok("\u{2581}said", 0.5),
            tok("\u{2581}Please", 2.1),
            tok("\u{2581}se", 3.9),
            tok("nd", 4.4), // past the margin: stays with its word
            tok(".", 4.4),
            tok("\u{2581}And", 4.4),
        ];
        let words = keep_inside(&tokens, &cut);
        assert_eq!(words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["Please", "send."]);
        assert!((words[0].time - 2.1).abs() < 1e-4);
    }

        fn w(text: &str, time: f32) -> Word {
        Word { text: text.into(), time }
    }

    #[test]
    fn merge_keeps_shared_words_once() {
        let pieces = vec![
            (0.0, vec![w("I", 0.1), w("looked", 0.3), w("at", 0.6), w("it.", 0.8), w("The", 1.3)]),
            (1.2, vec![w("it.", 0.8), w("The", 1.3), w("first", 1.5), w("part", 1.8)]),
        ];
        assert_eq!(merge(&pieces), "I looked at it. The first part");
    }

    #[test]
    fn merge_lines_up_a_piece_that_starts_with_a_word_we_missed() {
        // The case CI found: one piece lost "in town."; the next starts with "town." before the words both have.
        let pieces = vec![
            (8.76, vec![w("and", 10.78), w("have", 10.94), w("dinner", 11.18)]),
            (10.9, vec![w("On", 12.84), w("Sunday", 13.0)]),
            (13.02, vec![w("town.", 12.16), w("On", 12.88), w("Sunday", 13.12), w("we", 13.68), w("pack", 13.92)]),
        ];
        assert_eq!(merge(&pieces), "and have dinner town. On Sunday we pack");
    }

    #[test]
    fn merge_falls_back_to_times_when_pieces_disagree() {
        // The first piece heard its last word badly ("install"); the second heard it well, before its cut.
        let pieces = vec![
            (0.0, vec![w("because", 0.2), w("the", 0.6), w("install", 0.8)]),
            (1.0, vec![w("the", 0.6), w("installer", 0.8), w("needs", 1.2), w("testing.", 1.5)]),
        ];
        // No shared run at the seam: nothing already kept is dropped; only later words are added.
        assert_eq!(merge(&pieces), "because the install needs testing.");
        // With a shared run, the later piece's version is kept once.
        let pieces = vec![(0.0, vec![w("so", 0.2), w("we", 0.4)]), (0.5, vec![w("so", 0.2), w("we", 0.4), w("moved", 0.7)])];
        assert_eq!(merge(&pieces), "so we moved");
        // A misheard word inside a longer shared run still lines up; the later piece's words win.
        let pieces = vec![
            (0.0, vec![w("the", 0.1), w("hardware", 0.3), w("order,", 0.6), w("which", 0.9), w("has", 1.1), w("not", 1.2), w("shifted.", 1.4)]),
            (1.0, vec![w("order,", 0.6), w("which", 0.9), w("has", 1.1), w("not", 1.2), w("shipped", 1.4), w("yet.", 1.7)]),
        ];
        assert_eq!(merge(&pieces), "the hardware order, which has not shipped yet.");
    }

    #[test]
    fn detokenize_spacing() {
        let t = vec![tok("\u{2581}Hello", 0.0), tok(",", 0.1), tok("\u{2581}wor", 0.2), tok("ld", 0.3), tok("!", 0.4)];
        assert_eq!(detokenize(&t), "Hello, world!");
        assert_eq!(join(&["Hello there.".into(), "".into(), " How are you?".into()]), "Hello there. How are you?");
    }

    #[test]
    fn word_error_rate() {
        assert_eq!(wer("Please send the report tomorrow.", "please send the report tomorrow"), 0.0);
        assert!((wer("a b c d", "a x c") - 0.5).abs() < 1e-6);
    }
}

#[cfg(test)]
mod replay {
    use super::*;

    /// Re-merges the pieces a CI benchmark recorded (`LARYNX_PIECES=bench-cpu.json`), to try a merge change
    /// without running the model again.
    #[test]
    fn replay_recorded_pieces() {
        let Ok(path) = std::env::var("LARYNX_PIECES") else { return };
        let rows: Vec<serde_json::Value> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        for r in rows {
            let Some(pieces) = r["stream_pieces"].as_array() else { continue };
            let pieces: Vec<(f32, Vec<Word>)> = pieces
                .iter()
                .map(|p| {
                    let words = p[1].as_array().unwrap().iter().map(|w| Word { text: w["text"].as_str().unwrap().into(), time: w["time"].as_f64().unwrap() as f32 }).collect();
                    (p[0].as_f64().unwrap() as f32, words)
                })
                .collect();
            let text = merge(&pieces);
            let reference = r["reference"].as_str().unwrap();
            println!("{} stream {:.3} (was {:.3}) whole {:.3}\n  {}", r["wav"], wer(reference, &text), r["stream_wer"].as_f64().unwrap(), r["whole_wer"].as_f64().unwrap(), text);
        }
    }
}
