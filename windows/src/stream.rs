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

/// How far past each side of a cut a segment keeps words (s). Two transcriptions of the same audio place a word at
/// slightly different times, so a word near a cut could be claimed by both segments or by neither. Keeping a margin
/// on both sides means no word is lost; `join` then removes the words the two pieces have in common.
pub const MARGIN: f32 = 0.6;

/// The tokens of a transcription of [ctx_start, ctx_end) that belong to [start, end), give or take `MARGIN`.
pub fn keep_inside(tokens: &[Token], cut: &Cut) -> Vec<Token> {
    let offset = cut.ctx_start as f32 / RATE as f32;
    let lo = if cut.start == 0 { 0.0 } else { cut.start as f32 / RATE as f32 - MARGIN };
    let hi = if cut.end == cut.ctx_end { f32::INFINITY } else { cut.end as f32 / RATE as f32 + MARGIN };
    let mut kept: Vec<Token> = Vec::new();
    let mut last_kept = false;
    for (i, t) in tokens.iter().enumerate() {
        let at = t.time + offset;
        // A word's pieces and the punctuation after it stay with the word's first piece.
        let continues = i > 0 && !t.piece.starts_with('\u{2581}');
        let keep = if continues { last_kept } else { at >= lo && at < hi };
        if keep {
            kept.push(t.clone());
        }
        last_kept = keep;
    }
    kept
}

/// Turns SentencePiece pieces into text: ▁ starts a word; no space before punctuation.
pub fn detokenize(tokens: &[Token]) -> String {
    let raw: String = tokens.iter().map(|t| t.piece.replace('\u{2581}', " ")).collect();
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    for (i, ch) in chars.iter().enumerate() {
        if ch.is_whitespace() {
            let next_is_word = chars.get(i + 1).is_some_and(|c| c.is_alphanumeric());
            if out.is_empty() || !next_is_word || out.ends_with(' ') {
                continue;
            }
            out.push(' ');
        } else {
            out.push(*ch);
        }
    }
    out.trim().to_string()
}

fn norm(word: &str) -> String {
    word.chars().filter(|c| c.is_alphanumeric() || *c == '\'').flat_map(char::to_lowercase).collect()
}

/// Joins segment texts. Neighbouring pieces overlap by up to a second or so (see `MARGIN`): the longest run of
/// words that ends one piece and starts the next is kept once, in the first piece's spelling.
pub fn join(parts: &[String]) -> String {
    let mut words: Vec<String> = Vec::new();
    for part in parts {
        let next: Vec<&str> = part.split_whitespace().collect();
        if next.is_empty() {
            continue;
        }
        let most = words.len().min(next.len()).min(12);
        let overlap = (1..=most)
            .rev()
            .find(|&k| (0..k).all(|i| norm(&words[words.len() - k + i]) == norm(next[i]) && !norm(next[i]).is_empty()))
            .unwrap_or(0);
        words.extend(next[overlap..].iter().map(|w| w.to_string()));
    }
    words.join(" ")
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
    fn keeps_tokens_inside_with_a_margin_and_whole_words() {
        // Context starts at 1.0 s; the segment is [2.0, 4.0), kept with a 0.6 s margin: [1.4, 4.6).
        let cut = Cut { start: secs(2.0), end: secs(4.0), ctx_start: secs(1.0), ctx_end: secs(5.5) };
        let tokens = vec![
            tok("\u{2581}said", 0.2),
            tok("\u{2581}Please", 1.1),
            tok("\u{2581}se", 2.9),
            tok("nd", 3.7), // past the margin: stays with its word
            tok(".", 3.7),
            tok("\u{2581}And", 3.8),
        ];
        let kept = keep_inside(&tokens, &cut);
        assert_eq!(detokenize(&kept), "Please send.");
    }

    #[test]
    fn join_drops_the_overlap_once() {
        let parts = vec![
            "I looked at the draft this morning. The".to_string(),
            "morning. The first section reads well, but".to_string(),
            "but the numbers do not match.".to_string(),
        ];
        assert_eq!(join(&parts), "I looked at the draft this morning. The first section reads well, but the numbers do not match.");
        // No overlap: just joined.
        assert_eq!(join(&["Hello there.".into(), "How are you?".into()]), "Hello there. How are you?");
        // A capital after a period in the next piece doesn't stop the match; the first piece's spelling wins.
        assert_eq!(join(&["we should, so".into(), "So I moved it.".into()]), "we should, so I moved it.");
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
