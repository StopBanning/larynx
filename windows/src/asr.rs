//! Speech to text: NVIDIA Parakeet TDT 0.6B v3 (the Mac's default model family) as ONNX, run by ONNX Runtime.
//!
//! Model files are the community ONNX export `istupakov/parakeet-tdt-0.6b-v3-onnx` (CC-BY-4.0, like the model):
//! `nemo128.onnx` (log-mel features), `encoder-model[.int8].onnx`, `decoder_joint-model[.int8].onnx`, `vocab.txt`.
//! The greedy TDT decoding follows the published algorithm (and onnx-asr's MIT implementation of it).
//!
//! Where it runs: the encoder (almost all of the work) on DirectML when asked and a DirectX 12 GPU is there, else on
//! the CPU. The decoder is a tiny LSTM called once per token, so it always runs on the CPU, where a call costs
//! microseconds instead of a GPU round trip.

use crate::stream::Token;
use ort::session::{builder::GraphOptimizationLevel, RunOptions, Session};
use ort::value::Tensor;
use std::path::Path;
use std::time::Instant;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Cpu,
    DirectML,
}

impl Provider {
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "cpu" => Some(Provider::Cpu),
            "directml" | "dml" | "gpu" => Some(Provider::DirectML),
            _ => None,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Provider::Cpu => "cpu",
            Provider::DirectML => "directml",
        }
    }
}

pub struct Parakeet {
    pre: Session,
    enc: Session,
    dec: Session,
    vocab: Vec<String>,
    blank: usize,
    state1: (usize, usize),
    state2: (usize, usize),
    targets_i64: bool,
    pub provider: Provider,
    pub quantized: bool,
}

/// Timing of one transcription (ms).
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct Timing {
    pub features: f64,
    pub encoder: f64,
    pub decoder: f64,
    pub total: f64,
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

pub fn default_threads() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8)
}

impl Parakeet {
    /// Loads the model from `dir`. `quantized` picks the int8 files (smaller, faster on CPUs).
    pub fn load(dir: &Path, provider: Provider, quantized: bool, threads: usize) -> Result<Self, String> {
        let env = ort::init().with_name("larynx").build().map_err(err)?;
        let suffix = if quantized { ".int8" } else { "" };
        let cpu = |path: &Path| -> Result<Session, String> {
            Session::builder(&env)
                .map_err(err)?
                .with_optimization_level(GraphOptimizationLevel::Level3)
                .map_err(err)?
                .with_intra_threads(threads)
                .map_err(err)?
                .commit_from_file(path)
                .map_err(|e| format!("{}: {e}", path.display()))
        };
        let pre = cpu(&dir.join("nemo128.onnx"))?;
        let enc_path = dir.join(format!("encoder-model{suffix}.onnx"));
        let enc = match provider {
            Provider::Cpu => cpu(&enc_path)?,
            Provider::DirectML => {
                #[cfg(windows)]
                {
                    use ort::ep;
                    // DirectML wants these two off (ONNX Runtime's DirectML notes).
                    Session::builder(&env)
                        .map_err(err)?
                        .with_optimization_level(GraphOptimizationLevel::Level3)
                        .map_err(err)?
                        .with_memory_pattern(false)
                        .map_err(err)?
                        .with_parallel_execution(false)
                        .map_err(err)?
                        .with_execution_providers([ep::DirectML::default().build().error_on_failure()])
                        .map_err(err)?
                        .commit_from_file(&enc_path)
                        .map_err(|e| format!("{} on DirectML: {e}", enc_path.display()))?
                }
                #[cfg(not(windows))]
                {
                    return Err("DirectML is Windows only".into());
                }
            }
        };
        let dec = cpu(&dir.join(format!("decoder_joint-model{suffix}.onnx")))?;

        let vocab_text = std::fs::read_to_string(dir.join("vocab.txt")).map_err(err)?;
        let mut vocab: Vec<(usize, String)> = vocab_text
            .lines()
            .filter_map(|l| {
                let (piece, id) = l.rsplit_once(' ')?;
                Some((id.trim().parse().ok()?, piece.to_string()))
            })
            .collect();
        vocab.sort_by_key(|v| v.0);
        let vocab: Vec<String> = vocab.into_iter().map(|v| v.1).collect();
        let blank = vocab.iter().position(|p| p == "<blk>").unwrap_or(vocab.len() - 1);

        let shape_of = |s: &Session, name: &str, fallback: (usize, usize)| -> (usize, usize) {
            s.inputs()
                .iter()
                .find(|i| i.name() == name)
                .and_then(|i| i.dtype().tensor_shape().map(|sh| sh.to_vec()))
                .filter(|d| d.len() == 3 && d[0] > 0 && d[2] > 0)
                .map(|d| (d[0] as usize, d[2] as usize))
                .unwrap_or(fallback)
        };
        let state1 = shape_of(&dec, "input_states_1", (2, 640));
        let state2 = shape_of(&dec, "input_states_2", (2, 640));
        let targets_i64 = dec
            .inputs()
            .iter()
            .find(|i| i.name() == "targets")
            .and_then(|i| i.dtype().tensor_type())
            .is_some_and(|t| t == ort::value::TensorElementType::Int64);
        Ok(Parakeet { pre, enc, dec, vocab, blank, state1, state2, targets_i64, provider, quantized })
    }

    /// Describes the model's inputs and outputs, for the log.
    pub fn describe(&self) -> String {
        let io = |s: &Session| {
            let i: Vec<String> = s.inputs().iter().map(|o| format!("{}:{:?}", o.name(), o.dtype().tensor_shape().map(|x| x.to_vec()))).collect();
            let o: Vec<String> = s.outputs().iter().map(|o| format!("{}:{:?}", o.name(), o.dtype().tensor_shape().map(|x| x.to_vec()))).collect();
            format!("in [{}] out [{}]", i.join(", "), o.join(", "))
        };
        format!(
            "features {}; encoder {}; decoder {}; vocab {} (blank {}), states {:?}/{:?}",
            io(&self.pre),
            io(&self.enc),
            io(&self.dec),
            self.vocab.len(),
            self.blank,
            self.state1,
            self.state2
        )
    }

    /// Transcribes 16 kHz mono audio. `cancel` can stop it early (another thread calls `terminate()` on it).
    pub fn transcribe(&mut self, audio: &[f32], cancel: Option<&RunOptions>) -> Result<(Vec<Token>, Timing), String> {
        let started = Instant::now();
        let mut timing = Timing::default();
        if audio.len() < 1600 {
            return Ok((Vec::new(), timing));
        }
        // 1. Log-mel features.
        let t = Instant::now();
        let wave = Tensor::from_array(([1usize, audio.len()], audio.to_vec())).map_err(err)?;
        let lens = Tensor::from_array(([1usize], vec![audio.len() as i64])).map_err(err)?;
        let (features, feat_shape, feat_len) = {
            let out = self.pre.run(ort::inputs!["waveforms" => wave, "waveforms_lens" => lens]).map_err(err)?;
            let (shape, data) = out["features"].try_extract_tensor::<f32>().map_err(err)?;
            let (_, l) = out["features_lens"].try_extract_tensor::<i64>().map_err(err)?;
            (data.to_vec(), shape.to_vec(), l[0])
        };
        timing.features = ms(t);

        // 2. Encoder.
        let t = Instant::now();
        let feats = Tensor::from_array((feat_shape.iter().map(|&d| d as usize).collect::<Vec<_>>(), features)).map_err(err)?;
        let flen = Tensor::from_array(([1usize], vec![feat_len])).map_err(err)?;
        let inputs = ort::inputs!["audio_signal" => feats, "length" => flen];
        let (enc, dims, enc_len) = {
            let out = match cancel {
                Some(opts) => self.enc.run_with_options(inputs, opts).map_err(err)?,
                None => self.enc.run(inputs).map_err(err)?,
            };
            let (shape, data) = out["outputs"].try_extract_tensor::<f32>().map_err(err)?;
            let (_, l) = out["encoded_lengths"].try_extract_tensor::<i64>().map_err(err)?;
            (data.to_vec(), shape.to_vec(), l[0] as usize)
        };
        timing.encoder = ms(t);
        if dims.len() != 3 {
            return Err(format!("unexpected encoder output shape {dims:?}"));
        }
        let (d, frames) = (dims[1] as usize, dims[2] as usize);
        let enc_len = enc_len.min(frames);

        // 3. Greedy TDT decoding: at each frame, the joint gives a token and how many frames to skip.
        let t = Instant::now();
        let mut s1 = vec![0f32; self.state1.0 * self.state1.1];
        let mut s2 = vec![0f32; self.state2.0 * self.state2.1];
        let mut tokens: Vec<Token> = Vec::new();
        let mut last = self.blank;
        let mut frame = 0usize;
        let mut emitted = 0;
        let vocab_size = self.vocab.len();
        let mut column = vec![0f32; d];
        while frame < enc_len {
            for (k, c) in column.iter_mut().enumerate() {
                *c = enc[k * frames + frame];
            }
            let enc_in = Tensor::from_array(([1usize, d, 1], column.clone())).map_err(err)?;
            let st1 = Tensor::from_array(([self.state1.0, 1, self.state1.1], s1.clone())).map_err(err)?;
            let st2 = Tensor::from_array(([self.state2.0, 1, self.state2.1], s2.clone())).map_err(err)?;
            let (logits, n1, n2) = {
                let out = if self.targets_i64 {
                    let tg = Tensor::from_array(([1usize, 1], vec![last as i64])).map_err(err)?;
                    let tl = Tensor::from_array(([1usize], vec![1i64])).map_err(err)?;
                    self.dec.run(ort::inputs![
                        "encoder_outputs" => enc_in, "targets" => tg, "target_length" => tl,
                        "input_states_1" => st1, "input_states_2" => st2
                    ])
                } else {
                    let tg = Tensor::from_array(([1usize, 1], vec![last as i32])).map_err(err)?;
                    let tl = Tensor::from_array(([1usize], vec![1i32])).map_err(err)?;
                    self.dec.run(ort::inputs![
                        "encoder_outputs" => enc_in, "targets" => tg, "target_length" => tl,
                        "input_states_1" => st1, "input_states_2" => st2
                    ])
                }
                .map_err(err)?;
                let (_, l) = out["outputs"].try_extract_tensor::<f32>().map_err(err)?;
                let (_, a) = out["output_states_1"].try_extract_tensor::<f32>().map_err(err)?;
                let (_, b) = out["output_states_2"].try_extract_tensor::<f32>().map_err(err)?;
                (l.to_vec(), a.to_vec(), b.to_vec())
            };
            let argmax = |v: &[f32]| v.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1)).map(|x| x.0).unwrap_or(0);
            let token = argmax(&logits[..vocab_size.min(logits.len())]);
            let step = if logits.len() > vocab_size { argmax(&logits[vocab_size..]) } else { 0 };
            if token != self.blank {
                s1 = n1;
                s2 = n2;
                last = token;
                tokens.push(Token { piece: self.vocab[token].clone(), time: frame as f32 * 0.08 });
                emitted += 1;
            }
            if step > 0 {
                frame += step;
                emitted = 0;
            } else if token == self.blank || emitted >= 10 {
                frame += 1;
                emitted = 0;
            }
        }
        timing.decoder = ms(t);
        timing.total = ms(started);
        Ok((tokens, timing))
    }
}
