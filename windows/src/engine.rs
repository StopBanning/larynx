//! The speech worker and one dictation's streaming state.
//!
//! One thread owns the model. While you talk, the dictation sends it finished segments (cut at pauses) and, when it
//! is idle, a preview of the words since the last cut for the pill. At key-up the preview in flight is stopped, the
//! audio after the last cut is sent, and the text is the segments joined in order.

use crate::asr::{Parakeet, Timing};
use crate::stream::{self, Config, Cut, Segmenter};
use ort::session::RunOptions;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

enum Kind {
    Segment(usize),
    Preview,
    Final,
    Whole,
}

struct Job {
    generation: u64,
    kind: Kind,
    cut: Cut,
    audio: Vec<f32>,
    cancel: Option<Arc<RunOptions>>,
}

struct Done {
    generation: u64,
    kind: Kind,
    text: Result<String, String>,
    timing: Timing,
}

pub struct Engine {
    jobs: Sender<Job>,
    done: Receiver<Done>,
    generation: u64,
    pub provider: &'static str,
    pub describe: String,
}

impl Engine {
    pub fn start(mut model: Parakeet) -> Engine {
        let (jobs, job_rx) = channel::<Job>();
        let (done_tx, done) = channel::<Done>();
        let provider = model.provider.name();
        let describe = model.describe();
        std::thread::Builder::new()
            .name("larynx-asr".into())
            .spawn(move || {
                for job in job_rx {
                    let (text, timing) = match model.transcribe(&job.audio, job.cancel.as_deref()) {
                        Ok((tokens, timing)) => {
                            let kept = stream::keep_inside(&tokens, &job.cut);
                            (Ok(stream::detokenize(&kept)), timing)
                        }
                        Err(e) => (Err(e), Timing::default()),
                    };
                    if done_tx.send(Done { generation: job.generation, kind: job.kind, text, timing }).is_err() {
                        break;
                    }
                }
            })
            .expect("speech thread");
        Engine { jobs, done, generation: 0, provider, describe }
    }

    /// Transcribes a whole recording at once (no streaming). For `transcribe` and the benchmark.
    pub fn transcribe_all(&mut self, audio: &[f32]) -> Result<(String, Timing), String> {
        self.generation += 1;
        let cut = Cut { start: 0, end: audio.len(), ctx_start: 0, ctx_end: audio.len() };
        self.jobs
            .send(Job { generation: self.generation, kind: Kind::Whole, cut, audio: audio.to_vec(), cancel: None })
            .map_err(|e| e.to_string())?;
        loop {
            let d = self.done.recv().map_err(|e| e.to_string())?;
            if d.generation == self.generation {
                return d.text.map(|t| (t, d.timing));
            }
        }
    }
}

/// What a dictation produced, with where the time went after key-up.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Outcome {
    pub text: String,
    /// Key-up to text ready (ms): waiting for segments still running plus the last piece.
    pub after_key_up_ms: f64,
    /// Seconds of audio left to transcribe at key-up.
    pub tail_seconds: f32,
    pub segments: usize,
    pub previews: usize,
    pub final_timing: Timing,
}

pub struct Dictation<'e> {
    engine: &'e mut Engine,
    generation: u64,
    seg: Segmenter,
    parts: Vec<Option<String>>,
    preview: Option<Arc<RunOptions>>,
    preview_text: String,
    last_preview: Instant,
    previews: usize,
    pub audio: Arc<Mutex<Vec<f32>>>,
    /// Show words while talking (costs CPU; off for a pure latency run).
    pub live_preview: bool,
}

impl<'e> Dictation<'e> {
    pub fn new(engine: &'e mut Engine, audio: Arc<Mutex<Vec<f32>>>, cfg: Config) -> Self {
        engine.generation += 1;
        let generation = engine.generation;
        Dictation {
            engine,
            generation,
            seg: Segmenter::new(cfg),
            parts: Vec::new(),
            preview: None,
            preview_text: String::new(),
            last_preview: Instant::now(),
            previews: 0,
            audio,
            live_preview: true,
        }
    }

    fn send(&mut self, kind: Kind, cut: Cut, cancel: Option<Arc<RunOptions>>) {
        let audio = {
            let a = self.audio.lock().unwrap();
            a[cut.ctx_start..cut.ctx_end.min(a.len())].to_vec()
        };
        let _ = self.engine.jobs.send(Job { generation: self.generation, kind, cut, audio, cancel });
    }

    fn take_done(&mut self, d: Done) {
        if d.generation != self.generation {
            return;
        }
        match d.kind {
            Kind::Segment(i) => self.parts[i] = Some(d.text.unwrap_or_default()),
            Kind::Preview => {
                self.preview = None;
                if let Ok(t) = d.text {
                    self.preview_text = t;
                }
            }
            _ => {}
        }
    }

    /// Call every 50-100 ms while recording. Returns the words so far, for the pill.
    pub fn tick(&mut self) -> String {
        while let Ok(d) = self.engine.done.try_recv() {
            self.take_done(d);
        }
        let len = self.audio.lock().unwrap().len();
        loop {
            let cut = {
                let a = self.audio.lock().unwrap();
                self.seg.next_cut(&a)
            };
            let Some(cut) = cut else { break };
            self.parts.push(None);
            let i = self.parts.len() - 1;
            self.send(Kind::Segment(i), cut, None);
            self.preview_text.clear();
        }
        let segments_busy = self.parts.iter().any(Option::is_none);
        if self.live_preview && self.preview.is_none() && !segments_busy && self.last_preview.elapsed() > Duration::from_millis(400) {
            let tail = self.seg.tail(&self.audio.lock().unwrap()[..len]);
            let seconds = (tail.end - tail.start) as f32 / stream::RATE as f32;
            if (0.5..=12.0).contains(&seconds) {
                if let Ok(opts) = RunOptions::new() {
                    let opts = Arc::new(opts);
                    self.preview = Some(opts.clone());
                    self.previews += 1;
                    self.last_preview = Instant::now();
                    self.send(Kind::Preview, tail, Some(opts));
                }
            }
        }
        let mut done: Vec<String> = self.parts.iter().map_while(|p| p.clone()).collect();
        done.push(self.preview_text.clone());
        stream::join(&done)
    }

    /// Key-up: stop any preview, transcribe what's left, and join everything in order.
    pub fn finish(mut self) -> Result<Outcome, String> {
        let key_up = Instant::now();
        if let Some(p) = self.preview.take() {
            let _ = p.terminate();
        }
        let tail = self.seg.tail(&self.audio.lock().unwrap());
        let tail_seconds = (tail.end - tail.start) as f32 / stream::RATE as f32;
        self.send(Kind::Final, tail, None);
        let mut final_text: Option<String> = None;
        let mut final_timing = Timing::default();
        while final_text.is_none() || self.parts.iter().any(Option::is_none) {
            match self.engine.done.recv_timeout(Duration::from_secs(30)) {
                Ok(d) if d.generation == self.generation => {
                    if let Kind::Final = d.kind {
                        final_timing = d.timing;
                        final_text = Some(d.text?);
                    } else {
                        self.take_done(d);
                    }
                }
                Ok(_) => {}
                Err(RecvTimeoutError::Timeout) => return Err("speech took over 30 s".into()),
                Err(e) => return Err(e.to_string()),
            }
        }
        let mut all: Vec<String> = self.parts.iter().map(|p| p.clone().unwrap_or_default()).collect();
        all.push(final_text.unwrap_or_default());
        Ok(Outcome {
            text: stream::join(&all),
            after_key_up_ms: key_up.elapsed().as_secs_f64() * 1000.0,
            tail_seconds,
            segments: self.parts.len(),
            previews: self.previews,
            final_timing,
        })
    }

    /// Throws the dictation away (cancelled): stops the preview; late results are ignored by generation.
    pub fn cancel(mut self) {
        if let Some(p) = self.preview.take() {
            let _ = p.terminate();
        }
    }
}

/// Plays a recording into `audio` at real-time speed, in 20 ms pieces, as a microphone would. Returns when done.
pub fn feed_realtime(samples: &[f32], audio: &Arc<Mutex<Vec<f32>>>, stop: &std::sync::atomic::AtomicBool) {
    let start = Instant::now();
    let chunk = stream::RATE / 50;
    for (i, piece) in samples.chunks(chunk).enumerate() {
        if stop.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        let due = Duration::from_secs_f64((i * chunk) as f64 / stream::RATE as f64);
        if let Some(wait) = due.checked_sub(start.elapsed()) {
            std::thread::sleep(wait);
        }
        audio.lock().unwrap().extend_from_slice(piece);
    }
}
