//! `transcribe` and `bench`: what the model hears, and how long the wait after key-up is.

use crate::asr::{default_threads, Parakeet, Provider};
use crate::engine::{feed_realtime, Dictation, Engine};
use crate::stream::{self, Config};
use crate::{model_dir, wav, Args};
use std::path::Path;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Instant;

pub fn load_engine(args: &Args, provider: Provider) -> Result<(Engine, f64), String> {
    let threads = args.flag("threads").and_then(|t| t.parse().ok()).unwrap_or_else(default_threads);
    let t = Instant::now();
    let model = Parakeet::load(&model_dir(args), provider, !args.has("fp32"), threads)?;
    let load_ms = t.elapsed().as_secs_f64() * 1000.0;
    let mut engine = Engine::start(model);
    // One warm-up run: the first call allocates and (on DirectML) compiles shaders.
    let warm: Vec<f32> = (0..wav::RATE as usize * 2).map(|i| (i as f32 * 0.01).sin() * 0.01).collect();
    let _ = engine.transcribe_all(&warm);
    Ok((engine, load_ms))
}

pub fn provider(args: &Args) -> Result<Provider, String> {
    match args.flag("provider").unwrap_or("cpu") {
        "auto" => Ok(Provider::Cpu),
        p => Provider::parse(p).ok_or_else(|| format!("unknown provider {p}")),
    }
}

pub fn transcribe(args: &Args) -> Result<(), String> {
    let files = &args.positional[1..];
    if files.is_empty() {
        return Err("usage: larynx transcribe <file.wav>...".into());
    }
    let (mut engine, load_ms) = load_engine(args, provider(args)?)?;
    eprintln!("model loaded in {load_ms:.0} ms on {}: {}", engine.provider, engine.describe);
    for f in files {
        let audio = wav::read(Path::new(f))?;
        let seconds = audio.len() as f64 / wav::RATE as f64;
        let (text, timing) = engine.transcribe_all(&audio)?;
        println!(
            "{}",
            serde_json::json!({"file": f, "text": text, "seconds": seconds, "ms": timing.total, "rtf": timing.total / 1000.0 / seconds,
                "features_ms": timing.features, "encoder_ms": timing.encoder, "decoder_ms": timing.decoder, "provider": engine.provider})
        );
    }
    Ok(())
}

/// The manifest is a JSON list of {"wav": path, "text": what was said}. For each file: the whole-file time (median of
/// 3) and accuracy, then a streamed run played in real time with the key let go as the audio ends.
pub fn bench(args: &Args) -> Result<(), String> {
    let manifest_path = args.positional.get(1).ok_or("usage: larynx bench <manifest.json>")?;
    let manifest: Vec<serde_json::Value> =
        serde_json::from_str(&std::fs::read_to_string(manifest_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let base = Path::new(manifest_path).parent().unwrap_or(Path::new("."));
    let provider = provider(args)?;
    let (mut engine, load_ms) = load_engine(args, provider)?;
    println!("{}", serde_json::json!({"event": "loaded", "provider": engine.provider, "load_ms": load_ms, "threads": args.flag("threads"), "fp32": args.has("fp32")}));
    let mut out = Vec::new();
    for item in &manifest {
        let path = base.join(item["wav"].as_str().ok_or("manifest item without wav")?);
        let reference = item["text"].as_str().unwrap_or_default();
        let audio = wav::read(&path)?;
        let seconds = audio.len() as f64 / wav::RATE as f64;
        let mut times = Vec::new();
        let mut whole_text = String::new();
        for _ in 0..3 {
            let t = Instant::now();
            let (text, _) = engine.transcribe_all(&audio)?;
            times.push(t.elapsed().as_secs_f64() * 1000.0);
            whole_text = text;
        }
        times.sort_by(f64::total_cmp);
        let whole_ms = times[1];

        let streamed = if args.has("no-stream") { None } else { Some(stream_once(&mut engine, &audio, !args.has("no-preview"))?) };
        let row = serde_json::json!({
            "event": "file", "wav": item["wav"], "seconds": seconds, "provider": engine.provider,
            "whole_ms": whole_ms, "whole_rtf": whole_ms / 1000.0 / seconds, "whole_wer": stream::wer(reference, &whole_text),
            "whole_text": whole_text,
            "stream_after_key_up_ms": streamed.as_ref().map(|s| s.after_key_up_ms),
            "stream_tail_seconds": streamed.as_ref().map(|s| s.tail_seconds),
            "stream_segments": streamed.as_ref().map(|s| s.segments),
            "stream_previews": streamed.as_ref().map(|s| s.previews),
            "stream_wer": streamed.as_ref().map(|s| stream::wer(reference, &s.text)),
            "stream_text": streamed.as_ref().map(|s| s.text.clone()),
            "reference": reference,
        });
        println!("{row}");
        out.push(row);
    }
    if let Some(path) = args.flag("out") {
        std::fs::write(path, serde_json::to_string_pretty(&out).unwrap()).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Plays `audio` in real time into a dictation, ticking like the app does, and lets go of the key at the end.
pub fn stream_once(engine: &mut Engine, audio: &[f32], preview: bool) -> Result<crate::engine::Outcome, String> {
    let buffer = Arc::new(Mutex::new(Vec::with_capacity(audio.len())));
    let stop = Arc::new(AtomicBool::new(false));
    let feeder = {
        let (buffer, stop, samples) = (buffer.clone(), stop.clone(), audio.to_vec());
        std::thread::spawn(move || feed_realtime(&samples, &buffer, &stop))
    };
    let mut d = Dictation::new(engine, buffer.clone(), Config::default());
    d.live_preview = preview;
    while !feeder.is_finished() {
        d.tick(engine);
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    let _ = feeder.join();
    d.finish(engine)
}
