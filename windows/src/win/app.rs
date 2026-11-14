//! The app: a tray icon, the talk key, and a small state machine.
//!
//!   idle --key down--> listening (pill shows the waveform and the words as they come)
//!   listening --key up--> finishing (on a worker thread: last piece of speech, cleanup, paste, check)
//!   listening --another key / a tap--> cancelled
//!
//! The UI thread only ever does quick things (ticks every 33 ms, repaints), so the pill keeps moving while the
//! worker waits on the model or the target app.

use super::audio::Recorder;
use super::focus::{self, Target, Uia};
use super::hotkey::{self, KeyEvent};
use super::insert::{self, Delivery};
use super::pill::{Mode, Pill};
use super::tray::{self, Tray};
use crate::asr::{default_threads, Parakeet, Provider};
use crate::engine::{Dictation, Engine};
use crate::stream::Config;
use crate::text::{self, Cleanup, Options};
use crate::{data_dir, model_dir, wav, Args};
use std::cell::RefCell;
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::core::w;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::*;

const WAKE: u32 = WM_APP + 1;
const FINISHED: u32 = WM_APP + 2;
const READY: u32 = WM_APP + 4;
const TICK: usize = 1;
const HIDE: usize = 2;

/// JSON-lines log: timings always; the dictated words only with --log (tests), never by default.
struct Log {
    file: Option<std::fs::File>,
    words: bool,
}

impl Log {
    fn write(&mut self, v: serde_json::Value) {
        let mut v = v;
        if let Some(o) = v.as_object_mut() {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
            o.insert("t".into(), serde_json::json!(now));
            if !self.words {
                for k in ["raw", "text"] {
                    if o.contains_key(k) {
                        o.insert(k.into(), serde_json::json!("(not logged)"));
                    }
                }
            }
        }
        if let Some(f) = &mut self.file {
            let _ = writeln!(f, "{v}");
            let _ = f.flush();
        }
    }
}

struct Listening {
    dictation: Dictation,
    started: Instant,
    target: Option<Target>,
    mode: &'static str,
}

enum Phase {
    Idle,
    Listening(Box<Listening>),
    Finishing,
}

struct Finished {
    raw: String,
    text: String,
    asr_ms: f64,
    clean_ms: f64,
    paste_sent_ms: f64,
    confirmed_ms: Option<f64>,
    delivery: Delivery,
    tail_seconds: f32,
    segments: usize,
    previews: usize,
    seconds: f32,
    error: Option<String>,
}

struct FinishJob {
    dictation: Dictation,
    key_up: Instant,
    target: Option<Target>,
    mode: &'static str,
    seconds: f32,
}

struct App {
    hwnd: HWND,
    pill: Pill,
    tray: Tray,
    keys: Receiver<KeyEvent>,
    recorder: Recorder,
    engine: Option<Arc<Mutex<Engine>>>,
    finisher: Option<Sender<FinishJob>>,
    finished: Receiver<Finished>,
    finished_tx: Sender<Finished>,
    phase: Phase,
    log: Log,
    key_name: &'static str,
    provider: String,
    last_text: String,
    last_latency: Option<f64>,
    status: String,
    taskbar_created: u32,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

fn with_app(f: impl FnOnce(&mut App)) {
    APP.with(|a| {
        if let Ok(mut a) = a.try_borrow_mut() {
            if let Some(app) = a.as_mut() {
                f(app);
            }
        }
    });
}

fn is_taskbar_created(msg: u32) -> bool {
    let mut hit = false;
    APP.with(|a| {
        if let Ok(a) = a.try_borrow() {
            hit = a.as_ref().is_some_and(|x| x.taskbar_created == msg);
        }
    });
    hit
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WAKE => with_app(|a| a.on_keys()),
        FINISHED => with_app(|a| a.on_finished()),
        WM_TIMER if wparam.0 == TICK => with_app(|a| a.on_tick()),
        WM_TIMER if wparam.0 == HIDE => with_app(|a| {
            unsafe {
                let _ = KillTimer(Some(a.hwnd), HIDE);
            }
            if matches!(a.phase, Phase::Idle) {
                a.pill.hide();
            }
        }),
        tray::CALLBACK => {
            let event = (lparam.0 & 0xFFFF) as u32;
            if event == WM_RBUTTONUP || event == WM_LBUTTONUP {
                with_app(|a| a.show_menu());
            }
        }
        WM_COMMAND => match wparam.0 & 0xFFFF {
            tray::ID_QUIT => unsafe { PostQuitMessage(0) },
            tray::ID_COPY_LAST => with_app(|a| {
                if !a.last_text.is_empty() {
                    insert::copy_only(&a.last_text);
                }
            }),
            tray::ID_OPEN_LOGS => {
                let dir: Vec<u16> = data_dir().to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect();
                unsafe {
                    ShellExecuteW(None, w!("open"), windows::core::PCWSTR(dir.as_ptr()), None, None, SW_SHOWNORMAL);
                }
            }
            _ => {}
        },
        m if m >= 0xC000 && is_taskbar_created(m) => with_app(|a| a.tray.readd()),
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}

impl App {
    fn status_lines(&self) -> Vec<String> {
        let mut v = vec![format!("Hold {} to talk", self.key_name), self.status.clone()];
        if let Some(ms) = self.last_latency {
            v.push(format!("Last dictation: {:.2} s after you let go", ms / 1000.0));
        }
        v
    }

    fn show_menu(&self) {
        self.tray.menu(self.hwnd, &self.status_lines());
    }

    fn on_keys(&mut self) {
        while let Ok(k) = self.keys.try_recv() {
            match k {
                KeyEvent::Down(at) => self.start(at),
                KeyEvent::Up(at) => self.stop(at),
                KeyEvent::Cancel => self.cancel("another key was pressed"),
            }
        }
    }

    fn start(&mut self, at: Instant) {
        if !matches!(self.phase, Phase::Idle) {
            return;
        }
        let Some(engine) = self.engine.clone() else {
            let status = self.status.clone();
            self.pill.update(|s| s.mode = Mode::Problem(status));
            self.pill.show_at(None, None);
            self.schedule_hide(2500);
            return;
        };
        let target = focus::current();
        let exe = target.and_then(|t| focus::exe_path(t.pid)).unwrap_or_default();
        let mode = text::mode_for_exe(&exe);
        let app_name = std::path::Path::new(&exe).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let buffer = self.recorder.begin();
        let dictation = Dictation::new(&mut engine.lock().unwrap(), buffer, Config::default());
        self.log.write(serde_json::json!({"event": "key_down", "app": app_name, "mode": mode, "since_key_ms": at.elapsed().as_secs_f64() * 1000.0}));
        // Above the caret when the app reports one, else above the focused field, else above the taskbar.
        let anchor = target.and_then(|t| t.caret).or_else(|| Uia::new().and_then(|u| u.focused().bounds));
        self.pill.update(|s| {
            s.mode = Mode::Listening;
            s.words.clear();
            s.app = app_name.clone();
            s.levels.iter_mut().for_each(|l| *l = 0.0);
        });
        self.pill.show_at(anchor, target.map(|t| t.window));
        unsafe {
            let _ = KillTimer(Some(self.hwnd), HIDE);
            SetTimer(Some(self.hwnd), TICK, 33, None);
        }
        self.phase = Phase::Listening(Box::new(Listening { dictation, started: at, target, mode }));
    }

    fn on_tick(&mut self) {
        let level = self.recorder.level();
        match &mut self.phase {
            Phase::Listening(l) => {
                let words = match &self.engine {
                    Some(e) => l.dictation.tick(&mut e.lock().unwrap()),
                    None => String::new(),
                };
                self.pill.update(|s| {
                    s.levels.remove(0);
                    s.levels.push(level);
                    s.words = words;
                });
            }
            Phase::Finishing => self.pill.repaint(),
            Phase::Idle => unsafe {
                let _ = KillTimer(Some(self.hwnd), TICK);
            },
        }
    }

    fn stop(&mut self, at: Instant) {
        let Phase::Listening(l) = std::mem::replace(&mut self.phase, Phase::Idle) else { return };
        self.recorder.end();
        let held = at.duration_since(l.started);
        if held < Duration::from_millis(250) {
            // A tap, not a dictation.
            l.dictation.cancel();
            self.pill.hide();
            self.log.write(serde_json::json!({"event": "tap"}));
            return;
        }
        self.log.write(serde_json::json!({"event": "key_up", "held_s": held.as_secs_f64()}));
        self.pill.update(|s| s.mode = Mode::Thinking);
        self.phase = Phase::Finishing;
        if let Some(tx) = &self.finisher {
            let _ = tx.send(FinishJob { dictation: l.dictation, key_up: at, target: l.target, mode: l.mode, seconds: held.as_secs_f32() });
        }
    }

    fn cancel(&mut self, why: &str) {
        if let Phase::Listening(l) = std::mem::replace(&mut self.phase, Phase::Idle) {
            self.recorder.end();
            l.dictation.cancel();
            self.pill.hide();
            self.log.write(serde_json::json!({"event": "cancel", "why": why}));
        }
    }

    fn schedule_hide(&self, ms: u32) {
        unsafe {
            SetTimer(Some(self.hwnd), HIDE, ms, None);
        }
    }

    fn on_finished(&mut self) {
        while let Ok(f) = self.finished.try_recv() {
            self.phase = Phase::Idle;
            let total = f.asr_ms + f.clean_ms + f.paste_sent_ms;
            self.log.write(serde_json::json!({
                "event": "dictation", "raw": f.raw, "text": f.text, "delivery": f.delivery, "error": f.error,
                "seconds": f.seconds, "asr_after_key_up_ms": f.asr_ms, "clean_ms": f.clean_ms,
                "key_up_to_paste_ms": total, "key_up_to_confirmed_ms": f.confirmed_ms.map(|c| f.asr_ms + f.clean_ms + c),
                "tail_seconds": f.tail_seconds, "segments": f.segments, "previews": f.previews, "provider": self.provider,
            }));
            if f.error.is_none() && !f.text.is_empty() {
                self.last_text = f.text.clone();
                self.last_latency = Some(total);
            }
            let (mode, hold) = match (&f.error, &f.delivery) {
                (Some(e), _) => (Mode::Problem(e.clone()), 2500),
                (None, _) if f.text.is_empty() => (Mode::Problem("Didn't hear anything".into()), 1500),
                (None, Delivery::Inserted | Delivery::InsertedBy(_)) => (Mode::Done(f.text.clone()), 700),
                (None, Delivery::PastedAndCopied(_)) => (Mode::Done(format!("{}  (also on the clipboard)", f.text)), 1500),
                (None, Delivery::Copied(why)) => (Mode::Problem(format!("Copied, press Ctrl+V ({why})")), 3000),
            };
            self.pill.update(|s| s.mode = mode);
            self.schedule_hide(hold);
        }
    }

    fn on_ready(&mut self, result: Result<(Engine, Option<Cleanup>, Vec<serde_json::Value>, f64), String>) {
        match result {
            Ok((engine, cleanup, notes, load_ms)) => {
                for n in notes {
                    self.log.write(n);
                }
                self.provider = engine.provider.to_string();
                self.status = format!(
                    "Speech: Parakeet v3 on {}{}",
                    if engine.provider == "directml" { "the GPU (DirectML)" } else { "the CPU" },
                    if cleanup.is_some() { "" } else { " (cleanup library missing)" }
                );
                self.log.write(serde_json::json!({"event": "ready", "provider": engine.provider, "load_ms": load_ms, "cleanup": cleanup.is_some(), "model": engine.describe}));
                let engine = Arc::new(Mutex::new(engine));
                self.finisher = Some(start_finisher(engine.clone(), cleanup, self.finished_tx.clone(), self.hwnd));
                self.engine = Some(engine);
                self.tray.set(&format!("Larynx: hold {} to talk", self.key_name), true);
            }
            Err(e) => {
                self.status = format!("Speech model unavailable: {e}");
                self.log.write(serde_json::json!({"event": "error", "error": e}));
                self.tray.set(&format!("Larynx: {}", self.status), false);
            }
        }
    }
}

/// The worker that finishes dictations: last piece of speech, cleanup, paste, check. Owns UI Automation and the
/// cleanup library, so neither is set up per dictation.
fn start_finisher(engine: Arc<Mutex<Engine>>, cleanup: Option<Cleanup>, out: Sender<Finished>, hwnd: HWND) -> Sender<FinishJob> {
    let (tx, rx) = channel::<FinishJob>();
    let hwnd_raw = hwnd.0 as isize;
    std::thread::Builder::new()
        .name("larynx-finish".into())
        .spawn(move || {
            let uia = Uia::new();
            for job in rx {
                let outcome = job.dictation.finish(&mut engine.lock().unwrap());
                let asr_ms = job.key_up.elapsed().as_secs_f64() * 1000.0;
                let mut f = Finished {
                    raw: String::new(),
                    text: String::new(),
                    asr_ms,
                    clean_ms: 0.0,
                    paste_sent_ms: 0.0,
                    confirmed_ms: None,
                    delivery: Delivery::Copied("nothing to insert".into()),
                    tail_seconds: 0.0,
                    segments: 0,
                    previews: 0,
                    seconds: job.seconds,
                    error: None,
                };
                match outcome {
                    Err(e) => f.error = Some(format!("Speech failed: {e}")),
                    Ok(o) => {
                        f.raw = o.text.clone();
                        f.tail_seconds = o.tail_seconds;
                        f.segments = o.segments;
                        f.previews = o.previews;
                        let t = Instant::now();
                        f.text = match &cleanup {
                            Some(c) if !o.text.is_empty() => {
                                c.clean(&o.text, &Options { mode: job.mode.into(), style: "casual".into(), ..Default::default() }).text
                            }
                            _ => o.text.clone(),
                        };
                        f.clean_ms = t.elapsed().as_secs_f64() * 1000.0;
                        if !f.text.is_empty() {
                            let r = insert::deliver(&f.text, job.target, &uia);
                            f.paste_sent_ms = r.paste_sent_ms;
                            f.confirmed_ms = r.confirmed_ms;
                            f.delivery = r.delivery;
                        }
                    }
                }
                if out.send(f).is_err() {
                    break;
                }
                unsafe {
                    let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), FINISHED, WPARAM(0), LPARAM(0));
                }
            }
        })
        .expect("finisher thread");
    tx
}

/// Loads the model on the chosen provider. "auto" tries DirectML and the CPU on a few seconds of sound and keeps
/// the faster, remembering the choice in provider.txt.
fn load_engine(args: &Args, notes: &mut Vec<serde_json::Value>) -> Result<Engine, String> {
    let dir = model_dir(args);
    let threads = args.flag("threads").and_then(|t| t.parse().ok()).unwrap_or_else(default_threads);
    let choice_file = data_dir().join("provider.txt");
    let wanted = args
        .flag("provider")
        .map(str::to_string)
        .or_else(|| std::fs::read_to_string(&choice_file).ok())
        .unwrap_or_else(|| "auto".into());
    let probe: Vec<f32> = (0..wav::RATE as usize * 4).map(|i| ((i as f32 * 0.031).sin() + (i as f32 * 0.0007).sin()) * 0.05).collect();
    let time = |m: Parakeet| -> (Engine, f64) {
        let mut e = Engine::start(m);
        let _ = e.transcribe_all(&probe); // warm-up
        let t = Instant::now();
        let _ = e.transcribe_all(&probe);
        (e, t.elapsed().as_secs_f64() * 1000.0)
    };
    if let Some(p) = Provider::parse(wanted.trim()) {
        let t = Instant::now();
        let m = Parakeet::load(&dir, p, !args.has("fp32"), threads)?;
        let (e, ms) = time(m);
        notes.push(serde_json::json!({"event": "provider", "provider": p.name(), "load_ms": t.elapsed().as_secs_f64() * 1000.0, "probe_4s_ms": ms}));
        return Ok(e);
    }
    let mut best: Option<(Engine, f64)> = None;
    for p in [Provider::DirectML, Provider::Cpu] {
        match Parakeet::load(&dir, p, !args.has("fp32"), threads) {
            Ok(m) => {
                let (e, ms) = time(m);
                notes.push(serde_json::json!({"event": "provider", "provider": p.name(), "probe_4s_ms": ms}));
                if best.as_ref().is_none_or(|b| ms < b.1) {
                    best = Some((e, ms));
                }
            }
            Err(e) => notes.push(serde_json::json!({"event": "provider", "provider": p.name(), "error": e})),
        }
    }
    let (engine, _) = best.ok_or("the speech model could not be loaded")?;
    let _ = std::fs::create_dir_all(data_dir());
    let _ = std::fs::write(&choice_file, engine.provider);
    Ok(engine)
}

type Loaded = Result<(Engine, Option<Cleanup>, Vec<serde_json::Value>, f64), String>;

pub fn run(args: &Args) -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        // One Larynx at a time.
        let _mutex = CreateMutexW(None, true, w!("Local\\LarynxDictation"));
        if windows::Win32::Foundation::GetLastError() == windows::Win32::Foundation::ERROR_ALREADY_EXISTS {
            return Err("Larynx is already running".into());
        }
    }
    let _ = std::fs::create_dir_all(data_dir());
    let log_path: PathBuf = args.flag("log").map(PathBuf::from).unwrap_or_else(|| data_dir().join("larynx.log"));
    let log = Log { file: std::fs::OpenOptions::new().create(true).append(true).open(&log_path).ok(), words: args.has("log") };
    let vk = args.flag("key").and_then(hotkey::parse_key).unwrap_or(0xA3);
    let feed = match args.flag("feed") {
        Some(p) => Some(wav::read(std::path::Path::new(p))?),
        None => None,
    };

    let hwnd = unsafe {
        let instance = GetModuleHandleW(None).map_err(|e| e.to_string())?;
        let class = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(proc),
            hInstance: instance.into(),
            lpszClassName: w!("LarynxApp"),
            ..Default::default()
        };
        RegisterClassExW(&class);
        CreateWindowExW(WINDOW_EX_STYLE(0), w!("LarynxApp"), w!("Larynx"), WS_OVERLAPPED, 0, 0, 0, 0, None, None, Some(instance.into()), None)
            .map_err(|e| e.to_string())?
    };
    let taskbar_created = unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) };
    let pill = Pill::create()?;
    let tray = Tray::add(hwnd, "Larynx: loading the speech model");

    let (key_tx, keys) = channel();
    let hwnd_raw = hwnd.0 as isize;
    hotkey::start(
        vk,
        key_tx,
        Box::new(move || unsafe {
            let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), WAKE, WPARAM(0), LPARAM(0));
        }),
    )?;

    let (finished_tx, finished) = channel();
    let app = App {
        hwnd,
        pill,
        tray,
        keys,
        recorder: Recorder::new(feed),
        engine: None,
        finisher: None,
        finished,
        finished_tx,
        phase: Phase::Idle,
        log,
        key_name: hotkey::key_name(vk),
        provider: String::new(),
        last_text: String::new(),
        last_latency: None,
        status: "Loading the speech model".into(),
        taskbar_created,
    };
    APP.with(|a| *a.borrow_mut() = Some(app));

    // Load the model and the cleanup library off the UI thread; the tray says so meanwhile.
    let (ready_tx, ready_rx) = channel::<Loaded>();
    {
        let flags = args.flags.clone();
        std::thread::spawn(move || {
            let args = Args { positional: vec![], flags };
            let t = Instant::now();
            if !model_dir(&args).join("vocab.txt").exists() {
                let _ = crate::setup(&args);
            }
            let mut notes = Vec::new();
            let result = load_engine(&args, &mut notes).map(|e| {
                let cleanup = text::find_library().and_then(|p| Cleanup::load(&p).ok());
                (e, cleanup, notes, t.elapsed().as_secs_f64() * 1000.0)
            });
            let _ = ready_tx.send(result);
            unsafe {
                let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), READY, WPARAM(0), LPARAM(0));
            }
        });
    }

    let mut msg = MSG::default();
    unsafe {
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.message == READY {
                if let Ok(result) = ready_rx.try_recv() {
                    with_app(|a| a.on_ready(result));
                }
                continue;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    APP.with(|a| *a.borrow_mut() = None);
    Ok(())
}
