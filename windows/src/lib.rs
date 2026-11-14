//! Larynx for Windows. `larynx.exe` is the app (tray icon, talk key, pill); `larynx-cli.exe` runs the same code
//! with a console, for these tools:
//!
//!   larynx transcribe <file.wav>...       print what the model hears, with timings
//!   larynx bench <manifest.json>          latency and accuracy, whole-file and streamed, as JSON lines
//!   larynx cleanup-check <cases.json>     run tests/cases.json through the Swift cleanup library
//!   larynx clean <mode> <text>            clean one sentence the way a dictation would be
//!   larynx setup                          download the speech model (about 670 MB)
//!
//! Common options: --model <dir>  --provider auto|cpu|directml  --fp32  --threads N

mod stream;
mod text;
mod wav;

#[cfg(feature = "asr")]
mod asr;
#[cfg(feature = "asr")]
mod engine;
#[cfg(feature = "asr")]
mod bench;

#[cfg(all(windows, feature = "asr"))]
mod win;

use std::path::PathBuf;

pub struct Args {
    pub positional: Vec<String>,
    pub flags: std::collections::HashMap<String, String>,
}

impl Args {
    fn parse() -> Args {
        let mut positional = Vec::new();
        let mut flags = std::collections::HashMap::new();
        let mut it = std::env::args().skip(1).peekable();
        while let Some(a) = it.next() {
            if let Some(name) = a.strip_prefix("--") {
                let takes_value = matches!(
                    name,
                    "model" | "provider" | "threads" | "feed" | "log" | "key" | "out" | "mode" | "app" | "expect" | "reject"
                );
                let value = if takes_value { it.next().unwrap_or_default() } else { "1".into() };
                flags.insert(name.to_string(), value);
            } else {
                positional.push(a);
            }
        }
        Args { positional, flags }
    }
    pub fn flag(&self, name: &str) -> Option<&str> {
        self.flags.get(name).map(String::as_str)
    }
    pub fn has(&self, name: &str) -> bool {
        self.flags.contains_key(name)
    }
}

/// %LOCALAPPDATA%\Larynx (or ~/.larynx elsewhere): models and logs.
pub fn data_dir() -> PathBuf {
    if let Ok(p) = std::env::var("LARYNX_DATA_DIR") {
        return PathBuf::from(p);
    }
    if let Ok(p) = std::env::var("LOCALAPPDATA") {
        return PathBuf::from(p).join("Larynx");
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into())).join(".larynx")
}

pub fn model_dir(args: &Args) -> PathBuf {
    args.flag("model").map(PathBuf::from).unwrap_or_else(|| data_dir().join("models").join("parakeet-tdt-0.6b-v3-onnx"))
}

pub const MODEL_URL: &str = "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/";
pub const MODEL_FILES_INT8: &[&str] =
    &["nemo128.onnx", "vocab.txt", "config.json", "decoder_joint-model.int8.onnx", "encoder-model.int8.onnx"];

fn load_cleanup() -> Result<text::Cleanup, String> {
    let path = text::find_library().ok_or_else(|| format!("{} not found next to larynx", text::library_name()))?;
    text::Cleanup::load(&path)
}

/// Runs a command line (`app` is what an empty command means: the GUI app, or usage for the console tool).
pub fn entry(app: bool) {
    let _ = app; // only the Windows app uses it
    let args = Args::parse();
    let command = args.positional.first().cloned().unwrap_or_default();
    let result = match command.as_str() {
        "cleanup-check" => cleanup_check(&args),
        "clean" => clean_one(&args),
        "setup" => setup(&args),
        #[cfg(feature = "asr")]
        "transcribe" => bench::transcribe(&args),
        #[cfg(feature = "asr")]
        "bench" => bench::bench(&args),
        #[cfg(all(windows, feature = "asr"))]
        "run" => win::app::run(&args),
        #[cfg(all(windows, feature = "asr"))]
        "" if app => win::app::run(&args),
        #[cfg(all(windows, feature = "asr"))]
        "e2e" => win::e2e::run(&args),
        _ => Err(format!("unknown command {command:?}; see the top of windows/src/lib.rs")),
    };
    if let Err(e) = result {
        eprintln!("larynx: {e}");
        std::process::exit(1);
    }
}

fn cleanup_check(args: &Args) -> Result<(), String> {
    let cases = args.positional.get(1).ok_or("usage: larynx cleanup-check tests/cases.json")?;
    let lib = load_cleanup()?;
    let (passed, failures) = text::conformance(&lib, std::path::Path::new(cases))?;
    println!("{{\"passed\": {passed}, \"failed\": {}}}", failures.len());
    for f in &failures {
        println!("FAIL {f}");
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!("{} cleanup cases failed", failures.len()))
    }
}

fn clean_one(args: &Args) -> Result<(), String> {
    let mode = args.positional.get(1).ok_or("usage: larynx clean <mode> <text>")?;
    let text = args.positional[2..].join(" ");
    let lib = load_cleanup()?;
    let out = lib.clean(&text, &text::Options { mode: mode.clone(), style: "casual".into(), ..Default::default() });
    println!("{}", out.text);
    Ok(())
}

/// Downloads the int8 model with Windows' own curl.exe (or any curl), resuming partial files.
pub fn setup(args: &Args) -> Result<(), String> {
    let dir = model_dir(args);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    for f in MODEL_FILES_INT8 {
        let path = dir.join(f);
        if path.exists() && path.metadata().map(|m| m.len() > 0).unwrap_or(false) {
            continue;
        }
        let part = dir.join(format!("{f}.part"));
        println!("downloading {f}");
        let status = std::process::Command::new("curl")
            .args(["-fL", "--retry", "3", "-C", "-", "-o"])
            .arg(&part)
            .arg(format!("{MODEL_URL}{f}"))
            .status()
            .map_err(|e| format!("curl: {e}"))?;
        if !status.success() {
            return Err(format!("download of {f} failed"));
        }
        std::fs::rename(&part, &path).map_err(|e| e.to_string())?;
    }
    println!("model ready in {}", dir.display());
    Ok(())
}
