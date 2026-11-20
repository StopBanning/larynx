//! Larynx for Windows. `larynx.exe` is the app (tray icon, talk key, pill); `larynx-cli.exe` runs the same code
//! with a console, for these tools:
//!
//!   larynx transcribe <file.wav>...       print what the model hears, with timings
//!   larynx bench <manifest.json>          latency and accuracy, whole-file and streamed, as JSON lines
//!   larynx cleanup-check <cases.json>     run tests/cases.json through the Swift cleanup library
//!   larynx clean <mode> <text>            clean one sentence the way a dictation would be
//!   larynx setup                          download the speech model (about 670 MB)
//!   larynx meeting <you.wav> [them.wav]   transcribe a meeting (you, and the call), write its notes, save its page
//!   larynx meeting-notes <meeting.json>   write the notes for a meeting already transcribed (--save keeps them)
//!   larynx set-claude-key                 read the Anthropic API key from standard input into Credential Manager
//!
//! Common options: --model <dir>  --provider auto|cpu|directml  --fp32  --threads N

pub mod credential;
pub mod meeting;
pub mod report;
mod room;
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
                    "model" | "provider" | "threads" | "feed" | "feed-call" | "log" | "key" | "out" | "mode" | "app" | "expect" | "reject" | "dir" | "claude" | "room" | "dpi"
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
        "meeting-notes" => meeting_notes(&args),
        "set-claude-key" => set_claude_key(),
        #[cfg(feature = "asr")]
        "meeting" => bench::meeting(&args),
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
        #[cfg(all(windows, feature = "asr"))]
        "e2e-meeting" => win::e2e::run_meeting(&args),
        #[cfg(all(windows, feature = "asr"))]
        "e2e-welcome" => win::e2e::run_welcome(&args),
        #[cfg(all(windows, feature = "asr"))]
        "e2e-meeting-devices" => win::e2e_devices::run(&args),
        _ => Err(format!("unknown command {command:?}; see the top of windows/src/lib.rs")),
    };
    if let Err(e) = result {
        eprintln!("larynx: {e}");
        std::process::exit(1);
    }
}

/// Notes for a meeting already transcribed (a saved meeting's JSON). Prints the notes; `--save` stores the meeting
/// with them and prints the page's path.
fn meeting_notes(args: &Args) -> Result<(), String> {
    let path = args.positional.get(1).ok_or("usage: larynx meeting-notes <meeting.json> [--save]")?;
    let mut m = meeting::load(std::path::Path::new(path))?;
    let notes = meeting::notes_by_claude(&m, meeting::claude_code_path().as_deref(), credential::claude_key().as_deref(), &meeting::curl_post, &meeting::sleep_seconds)
        .map_err(|e| e.to_string())?;
    println!("{}", serde_json::to_string_pretty(&notes).map_err(|e| e.to_string())?);
    if args.has("save") {
        m.notes = Some(notes);
        println!("{}", meeting::save(&m, &meeting_email())?.display());
    }
    Ok(())
}

/// The address "Email this to me" fills in: `LARYNX_MEETING_EMAIL`, else <data dir>\meetings\email.txt.
pub fn meeting_email() -> String {
    std::env::var("LARYNX_MEETING_EMAIL")
        .ok()
        .or_else(|| std::fs::read_to_string(meeting::folder().join("email.txt")).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn set_claude_key() -> Result<(), String> {
    let mut key = String::new();
    std::io::stdin().read_line(&mut key).map_err(|e| e.to_string())?;
    credential::save(key.trim())?;
    println!("{}", if key.trim().is_empty() { "Claude key removed." } else { "Claude key saved. Meeting notes will be written by Claude." });
    Ok(())
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

/// The int8 model's files and their sizes in bytes (Hugging Face, Nov 2026), for the progress bar.
pub const MODEL_SIZES_INT8: &[u64] = &[139_764, 93_939, 97, 18_202_004, 652_183_999];

/// Every model file is there and not empty. (Checking one file was not enough: a download cut off after the small
/// files left a model that looked present and couldn't load, on every start after.)
pub fn model_ready(dir: &std::path::Path) -> bool {
    MODEL_FILES_INT8.iter().all(|f| dir.join(f).metadata().map(|m| m.len() > 0).unwrap_or(false))
}

/// Downloads the int8 model with Windows' own curl.exe (or any curl), resuming partial files. `progress` is called
/// a few times a second with (bytes so far, bytes in all). No console window opens, even from the tray app.
pub fn download_model(args: &Args, progress: &dyn Fn(u64, u64)) -> Result<(), String> {
    let dir = model_dir(args);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let total: u64 = MODEL_SIZES_INT8.iter().sum();
    let size = |p: &std::path::Path| p.metadata().map(|m| m.len()).unwrap_or(0);
    let mut finished = 0u64;
    for f in MODEL_FILES_INT8 {
        let path = dir.join(f);
        if size(&path) > 0 {
            finished += size(&path);
            progress(finished.min(total), total);
            continue;
        }
        let part = dir.join(format!("{f}.part"));
        let mut cmd = std::process::Command::new("curl");
        cmd.args(["-fsSL", "--retry", "5", "--retry-delay", "2", "--connect-timeout", "20", "-C", "-", "-o"])
            .arg(&part)
            .arg(format!("{MODEL_URL}{f}"))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn().map_err(|e| format!("couldn't start curl: {e}"))?;
        let status = loop {
            if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
                break s;
            }
            progress((finished + size(&part)).min(total), total);
            std::thread::sleep(std::time::Duration::from_millis(250));
        };
        if !status.success() {
            let mut err = String::new();
            if let Some(mut e) = child.stderr.take() {
                use std::io::Read;
                let _ = e.read_to_string(&mut err);
            }
            return Err(format!("download of {f} failed: {}", err.trim()));
        }
        std::fs::rename(&part, &path).map_err(|e| e.to_string())?;
        finished += size(&path);
        progress(finished.min(total), total);
    }
    Ok(())
}

/// `larynx setup`: downloads the model, printing every 10%.
pub fn setup(args: &Args) -> Result<(), String> {
    let last = std::cell::Cell::new(u64::MAX);
    download_model(args, &|done, total| {
        let tenth = done * 10 / total.max(1);
        if tenth != last.get() {
            last.set(tenth);
            println!("downloading the speech model: {} of {} MB", done / 1_000_000, total / 1_000_000);
        }
    })?;
    println!("model ready in {}", model_dir(args).display());
    Ok(())
}
